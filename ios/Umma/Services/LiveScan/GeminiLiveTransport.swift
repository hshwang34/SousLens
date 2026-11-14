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
/// Always call `close()` when done; outgoing messages are sent in order by one sender task.
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
    private var outbox: AsyncStream<String>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var token: LiveScanToken?
    private var openedAtMs: Int64 = 0
    private var lastFrameMs: Int64?
    private(set) var framesSent = 0

    /// Camera timestamps jitter; a frame up to this early still counts as on time.
    private static let frameToleranceMs: Int64 = 50

    init(clock: any VoiceClock = SystemVoiceClock(),
         makeSocket: @escaping SocketFactory = { URLSession.shared.webSocketTask(with: $0) }) {
        (events, continuation) = AsyncStream.makeStream(of: LiveScanEvent.self)
        self.clock = clock
        self.makeSocket = makeSocket
    }

    func connect(token: LiveScanToken) async throws {
        guard state == .idle else { throw LiveScanError.alreadyConnected }
        guard token.newSessionExpiresAt > Date() else { throw LiveScanError.tokenExpired }
        guard let model = LiveScanWire.modelPath(token.model) else { throw LiveScanError.invalidModel }
        state = .connecting
        self.token = token
        let socket = makeSocket(LiveScanWire.request(token: token))
        self.socket = socket
        socket.resume()
        do {
            try await socket.send(.string(LiveScanWire.setup(modelPath: model)))
            while true {
                let message = try await socket.receive()
                if LiveScanWire.decode(Self.payload(message))?.setupComplete != nil { break }
            }
        } catch {
            logger.error("live scan setup failed: \(error.localizedDescription, privacy: .public)")
            teardown()
            continuation.finish()
            throw LiveScanError.setupFailed(error.localizedDescription)
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
        outbox?.yield(LiveScanWire.video(jpeg: jpeg))
        framesSent += 1
        if token.nudgeEveryFrames > 0, framesSent % token.nudgeEveryFrames == 0 {
            outbox?.yield(LiveScanWire.text(token.nudgeText))
        }
    }

    func respond(callID: String, name: String, status: String, canonical: String?) {
        guard state == .open else { return }
        outbox?.yield(LiveScanWire.toolResponse(callID: callID, name: name, status: status, canonical: canonical))
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
        outbox?.yield(LiveScanWire.audio(pcm: LiveScanWire.silentSecond))
    }

    private func startSender(_ socket: any LiveSocket) {
        let (stream, outbox) = AsyncStream.makeStream(of: String.self)
        self.outbox = outbox
        tasks.append(Task { [weak self] in
            for await text in stream {
                do {
                    try await socket.send(.string(text))
                } catch {
                    self?.connectionFailed("send", error)
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
                    self?.connectionFailed("receive", error)
                    return
                }
                guard let self else { return }
                self.handle(message)
            }
        })
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard state == .open, let decoded = LiveScanWire.decode(Self.payload(message)) else { return }
        if decoded.goAway != nil {
            continuation.yield(.goAway)
        }
        for call in decoded.toolCall?.functionCalls ?? [] {
            guard let id = call.id, let name = call.name else { continue }
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

    private func connectionFailed(_ direction: String, _ error: Error) {
        guard state == .open, let socket else { return }
        let code = socket.closeCode
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
        outbox?.finish()
        outbox = nil
        tasks.forEach { $0.cancel() }
        tasks = []
        socket?.cancel(with: .normalClosure, reason: nil)
        token = nil
    }

    private static func payload(_ message: URLSessionWebSocketTask.Message) -> Data {
        switch message {
        case .string(let text): Data(text.utf8)
        case .data(let data): data
        @unknown default: Data()
        }
    }
}
