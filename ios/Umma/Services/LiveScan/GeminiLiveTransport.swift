import Foundation
import os

/// The WebSocket calls `GeminiLiveTransport` uses. `URLSessionWebSocketTask` conforms; tests inject
/// a scripted socket so nothing touches the network.
protocol LiveSocket: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    var closeReason: Data? { get }
}

extension URLSessionWebSocketTask: LiveSocket {}

/// Gemini Live over a WebSocket with an ephemeral token (brief 016 PR 5).
///
/// Video frames, a silent audio keep-alive every second, and a text nudge every
/// `nudgeEveryFrames` frames (the spike found video alone never triggers a turn). Model audio and
/// transcripts are never decoded or played. The session closes itself at `maxSessionSeconds`.
/// Always call `close()` when done.
///
/// Outgoing messages go through one sender task with two lanes: tool responses are never dropped
/// and go first; media (video, keep-alive audio, nudges) keeps only the newest
/// `maxMediaBacklog` messages, so a network stall never sends a burst of stale frames.
///
/// Frame throttling is owned by the camera frame stream (brief 016 PR 4, `frameMaxFps`). The check
/// here is only a safety cap with a wide jitter tolerance, so it never halves the real frame rate.
@MainActor
final class GeminiLiveTransport: LiveScanTransport {
    typealias SocketFactory = @MainActor (URLRequest) -> any LiveSocket

    let events: AsyncStream<LiveScanEvent>
    private let continuation: AsyncStream<LiveScanEvent>.Continuation
    private let makeSocket: SocketFactory
    private let clock: any VoiceClock
    private let logger = Logger(subsystem: "com.umma.ios", category: "livescan")

    private enum State { case idle, connecting, open, closed }
    private var state = State.idle
    private var socket: (any LiveSocket)?
    private var priorityLane: [String] = []
    private var mediaLane: [String] = []
    private var senderWakeup: CheckedContinuation<Void, Never>?
    private(set) var droppedMedia = 0
    private var tasks: [Task<Void, Never>] = []
    private var token: LiveScanToken?
    private var openedAtMs: Int64 = 0
    private var lastFrameMs: Int64?
    private(set) var framesSent = 0

    /// Camera timestamps jitter; a frame up to this early still counts as on time.
    private static let frameToleranceMs: Int64 = 250
    static let maxMediaBacklog = 2
    private static let markers = ["toolCall", "goAway", "setupComplete"].map { Data($0.utf8) }

    private let setupTimeout: Duration
    private let closeCodeGrace: Duration
    private var setupTimedOut = false

    init(clock: any VoiceClock = SystemVoiceClock(),
         setupTimeout: Duration = .seconds(10),
         closeCodeGrace: Duration = .milliseconds(100),
         makeSocket: @escaping SocketFactory = { URLSession.shared.webSocketTask(with: $0) }) {
        (events, continuation) = AsyncStream.makeStream(of: LiveScanEvent.self)
        self.clock = clock
        self.setupTimeout = setupTimeout
        self.closeCodeGrace = closeCodeGrace
        self.makeSocket = makeSocket
    }

    var queuedMediaCount: Int { mediaLane.count }

    func connect(token: LiveScanToken) async throws {
        guard state == .idle else { throw LiveScanError.alreadyConnected }
        guard token.newSessionExpiresAt > Date() else { throw LiveScanError.tokenExpired }
        guard let model = LiveScanWire.modelPath(token.model) else { throw LiveScanError.invalidModel }
        state = .connecting
        self.token = token
        let socket = makeSocket(LiveScanWire.request(token: token))
        self.socket = socket
        socket.resume()
        // The socket may open and never answer; cancelling it makes `receive` throw.
        let timeout = Task { [weak self, setupTimeout] in
            try? await Task.sleep(for: setupTimeout)
            guard !Task.isCancelled, let self, self.state == .connecting else { return }
            self.setupTimedOut = true
            socket.cancel(with: .normalClosure, reason: nil)
        }
        defer { timeout.cancel() }
        do {
            try await socket.send(.string(LiveScanWire.setup(modelPath: model)))
            while true {
                let message = try await socket.receive()
                if Self.decodeIfRelevant(Self.payload(message))?.setupComplete != nil { break }
            }
        } catch {
            let reason = setupTimedOut ? "timed out" : error.localizedDescription
            logger.error("live scan setup failed: \(reason, privacy: .public)")
            teardown()
            continuation.finish()
            throw LiveScanError.setupFailed(reason)
        }
        guard state == .connecting else {
            throw LiveScanError.setupFailed("Closed during setup.")
        }
        state = .open
        openedAtMs = clock.nowMs
        logger.info("live scan open model=\(model, privacy: .public) limit=\(token.maxSessionSeconds)s")
        startSender(socket)
        startReceiver(socket)
        clock.startTicking(everyMs: 1000) { [weak self] in self?.tick() }
    }

    func send(frame jpeg: Data) {
        guard state == .open, let token else { return }
        let now = clock.nowMs
        let fps = token.frameMaxFps > 0 ? token.frameMaxFps : 1
        let minGapMs = Int64(1000 / fps) - Self.frameToleranceMs
        if let lastFrameMs, now - lastFrameMs < minGapMs { return }
        lastFrameMs = now
        enqueueMedia(LiveScanWire.video(jpeg: jpeg))
        framesSent += 1
        if token.nudgeEveryFrames > 0, framesSent % token.nudgeEveryFrames == 0 {
            enqueueMedia(LiveScanWire.text(token.nudgeText))
        }
    }

    func respond(callID: String, name: String, status: String, canonical: String?) {
        guard state == .open else { return }
        priorityLane.append(LiveScanWire.toolResponse(callID: callID, name: name, status: status, canonical: canonical))
        wakeSender()
    }

    func close() {
        finish(.client)
    }

    // MARK: - Internals

    private func tick() {
        guard state == .open, let token else { return }
        if clock.nowMs - openedAtMs >= Int64(token.maxSessionSeconds) * 1000 {
            finish(.sessionLimit)
            return
        }
        enqueueMedia(LiveScanWire.audio(pcm: LiveScanWire.silentSecond))
    }

    private func enqueueMedia(_ text: String) {
        mediaLane.append(text)
        if mediaLane.count > Self.maxMediaBacklog {
            mediaLane.removeFirst(mediaLane.count - Self.maxMediaBacklog)
            droppedMedia += 1
        }
        wakeSender()
    }

    private func wakeSender() {
        senderWakeup?.resume()
        senderWakeup = nil
    }

    private func nextOutgoing() -> String? {
        if !priorityLane.isEmpty { return priorityLane.removeFirst() }
        if !mediaLane.isEmpty { return mediaLane.removeFirst() }
        return nil
    }

    private func startSender(_ socket: any LiveSocket) {
        tasks.append(Task { [weak self] in
            while let self, self.state == .open {
                guard let text = self.nextOutgoing() else {
                    await withCheckedContinuation { self.senderWakeup = $0 }
                    continue
                }
                do {
                    try await socket.send(.string(text))
                } catch {
                    await self.connectionFailed("send", error)
                    return
                }
            }
        })
    }

    private func startReceiver(_ socket: any LiveSocket) {
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await socket.receive()
                } catch {
                    await self?.connectionFailed("receive", error)
                    return
                }
                guard let self else { return }
                self.handle(message)
            }
        })
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard state == .open, let decoded = Self.decodeIfRelevant(Self.payload(message)) else { return }
        if decoded.goAway != nil {
            continuation.yield(.goAway)
        }
        for call in decoded.toolCall?.functionCalls ?? [] {
            guard let id = call.id else { continue }
            let name = call.name ?? ""
            let itemName = call.args?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard name == "add_item", !itemName.isEmpty else {
                // Answer anyway so the model never waits on a call we can't use.
                respond(callID: id, name: name, status: "ignored", canonical: nil)
                continue
            }
            continuation.yield(.itemReported(callID: id, name: itemName, kind: call.args?.kind,
                                             confidence: LiveScanConfidence(raw: call.args?.confidence)))
        }
    }

    private func connectionFailed(_ direction: String, _ error: Error) async {
        guard state == .open, let socket else { return }
        var code = socket.closeCode
        if code == .invalid {
            // The close frame (e.g. 1008 token expired) can land just after `receive` throws.
            try? await Task.sleep(for: closeCodeGrace)
            guard state == .open else { return }
            code = socket.closeCode
        }
        if code == .invalid {
            logger.error("live scan \(direction, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            continuation.yield(.error(error.localizedDescription))
            finish(.connectionLost)
        } else {
            let reason = socket.closeReason.map { String(decoding: $0, as: UTF8.self) }
            logger.info("live scan closed by server code=\(code.rawValue)")
            finish(.server(code: code.rawValue, reason: reason))
        }
    }

    private func finish(_ reason: LiveScanCloseReason) {
        guard state != .closed else { return }
        let wasOpen = state == .open
        teardown()
        if wasOpen || reason == .client {
            continuation.yield(.closed(reason))
        }
        continuation.finish()
    }

    private func teardown() {
        state = .closed
        clock.stopTicking()
        priorityLane = []
        mediaLane = []
        wakeSender()
        tasks.forEach { $0.cancel() }
        tasks = []
        socket?.cancel(with: .normalClosure, reason: nil)
        token = nil
    }

    /// Model audio arrives as large JSON chunks; don't parse them on the main actor.
    static func decodeIfRelevant(_ data: Data) -> LiveScanWire.ServerMessage? {
        guard markers.contains(where: { data.range(of: $0) != nil }) else { return nil }
        return LiveScanWire.decode(data)
    }

    private static func payload(_ message: URLSessionWebSocketTask.Message) -> Data {
        switch message {
        case .string(let text): Data(text.utf8)
        case .data(let data): data
        @unknown default: Data()
        }
    }
}
