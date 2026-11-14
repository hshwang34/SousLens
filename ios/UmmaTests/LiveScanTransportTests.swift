import Foundation
import XCTest
@testable import Umma

/// Scripted `LiveSocket`: records what the transport sends, replays what the server would say.
final class ScriptedLiveSocket: LiveSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [URLSessionWebSocketTask.Message] = []
    private var waiters: [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] = []
    private var _sent: [String] = []
    private var _closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    private var _closeReason: Data?
    private var ended = false
    private var _cancelled = false
    enum SetupReply { case complete, reject, silent }
    /// Answer the setup message with `setupComplete` (default), a server close, or nothing.
    var setupReply = SetupReply.complete
    /// While set, every non-setup `send` suspends until `releaseSends()` (a network stall).
    private var stalled = false
    private var stalledSends: [CheckedContinuation<Void, Never>] = []

    func stallSends() { lock.withLock { stalled = true } }

    func releaseSends() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            stalled = false
            defer { stalledSends = [] }
            return stalledSends
        }
        pending.forEach { $0.resume() }
    }

    var sent: [String] { lock.withLock { _sent } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    var closeCode: URLSessionWebSocketTask.CloseCode { lock.withLock { _closeCode } }
    var closeReason: Data? { lock.withLock { _closeReason } }

    func resume() {}

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard case .string(let text) = message else { return }
        let isSetup = lock.withLock { () -> Bool in
            _sent.append(text)
            return text.contains("\"setup\"")
        }
        if isSetup {
            switch setupReply {
            case .complete: push(#"{"setupComplete":{}}"#)
            case .reject: serverClose(code: .policyViolation, reason: "bad token")
            case .silent: break
            }
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wait = lock.withLock { () -> Bool in
                if stalled { stalledSends.append(continuation); return true }
                return false
            }
            if !wait { continuation.resume() }
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<URLSessionWebSocketTask.Message, Error>? = lock.withLock {
                if !queue.isEmpty { return .success(queue.removeFirst()) }
                if ended { return .failure(URLError(.networkConnectionLost)) }
                waiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock { _cancelled = true }
        end()
    }

    /// Delivered as a binary frame, the way the Live API sends JSON.
    func push(_ json: String) {
        let message = URLSessionWebSocketTask.Message.data(Data(json.utf8))
        let waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>? = lock.withLock {
            if waiters.isEmpty { queue.append(message); return nil }
            return waiters.removeFirst()
        }
        waiter?.resume(returning: message)
    }

    func serverClose(code: URLSessionWebSocketTask.CloseCode, reason: String) {
        lock.withLock {
            _closeCode = code
            _closeReason = Data(reason.utf8)
        }
        end()
    }

    func drop() { end() }

    /// The receive fails first; the close code becomes readable a moment later.
    func serverCloseLate(code: URLSessionWebSocketTask.CloseCode, reason: String, after delay: Duration) {
        end()
        Task {
            try? await Task.sleep(for: delay)
            self.lock.withLock {
                self._closeCode = code
                self._closeReason = Data(reason.utf8)
            }
        }
    }

    private func end() {
        let pending = lock.withLock { () -> [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] in
            ended = true
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume(throwing: URLError(.networkConnectionLost)) }
    }
}

/// Drains an event stream on the main actor; `next()` waits up to 2 s for the next event.
@MainActor
final class EventLog {
    private var received: [LiveScanEvent] = []
    private var finished = false
    private var consumed = 0

    init(_ stream: AsyncStream<LiveScanEvent>) {
        Task { @MainActor in
            for await event in stream { self.received.append(event) }
            self.finished = true
        }
    }

    func next() async -> LiveScanEvent? {
        for _ in 0..<400 where consumed >= received.count && !finished {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard consumed < received.count else { return nil }
        consumed += 1
        return received[consumed - 1]
    }
}

enum LiveScanFixtures {
    static func token(demo: Bool = false, maxSessionSeconds: Int = 120, nudgeEveryFrames: Int = 3,
                      frameMaxFps: Double = 1, newSessionExpiresAt: Date = .distantFuture) -> LiveScanToken {
        LiveScanToken(token: "auth_tokens/secret-abc", model: "gemini-3.8-live", expiresAt: .distantFuture,
                      newSessionExpiresAt: newSessionExpiresAt, maxSessionSeconds: maxSessionSeconds,
                      nudgeText: "Report any new items now visible.", nudgeEveryFrames: nudgeEveryFrames,
                      frameMaxFps: frameMaxFps, demo: demo)
    }

    static let tokenJSON = """
    {"token":"auth_tokens/secret-abc","model":"gemini-3.8-live","expires_at":"2026-11-13T10:03:00Z",
     "new_session_expires_at":"2026-11-13T10:01:00.5Z","max_session_seconds":120,
     "nudge_text":"Report any new items now visible.","nudge_every_frames":5,"frame_max_fps":1,"demo":false}
    """

    // Literal output of google-genai 1.x `live.py` (v1alpha, ephemeral token), captured from the SDK.
    static let sdkSetup = #"{"setup": {"model": "models/gemini-3.8-live"}}"#
    static let sdkVideo = #"{"realtime_input": {"video": {"data": "_9hqcGc=", "mime_type": "image/jpeg"}}}"#
    static let sdkAudio = #"{"realtime_input": {"audio": {"data": "AAAAAA==", "mime_type": "audio/pcm;rate=16000"}}}"#
    static let sdkText = #"{"realtime_input": {"text": "Report any new items now visible."}}"#
    static let sdkToolResponse = #"{"tool_response": {"functionResponses": [{"scheduling": "SILENT", "id": "fc1", "name": "add_item", "response": {"status": "new", "canonical_name": "soy sauce"}}]}}"#
}

private func jsonObject(_ text: String) throws -> NSDictionary {
    try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
}

@MainActor
final class LiveScanWireTests: XCTestCase {
    func testClientMessagesMatchTheSDK() throws {
        XCTAssertEqual(try jsonObject(LiveScanWire.setup(modelPath: "models/gemini-3.8-live")), try jsonObject(LiveScanFixtures.sdkSetup))
        XCTAssertEqual(try jsonObject(LiveScanWire.video(jpeg: Data([0xFF, 0xD8]) + Data("jpg".utf8))), try jsonObject(LiveScanFixtures.sdkVideo))
        XCTAssertEqual(try jsonObject(LiveScanWire.audio(pcm: Data(count: 4))), try jsonObject(LiveScanFixtures.sdkAudio))
        XCTAssertEqual(try jsonObject(LiveScanWire.text("Report any new items now visible.")), try jsonObject(LiveScanFixtures.sdkText))
        XCTAssertEqual(try jsonObject(LiveScanWire.toolResponse(callID: "fc1", name: "add_item", status: "new", canonical: "soy sauce")),
                       try jsonObject(LiveScanFixtures.sdkToolResponse))
        let noCanonical = try jsonObject(LiveScanWire.toolResponse(callID: "fc2", name: "add_item", status: "already_in_basket", canonical: nil))
        XCTAssertEqual(noCanonical.value(forKeyPath: "tool_response.functionResponses.response.status") as? [String], ["already_in_basket"])
    }

    func testModelPathAndRequest() {
        XCTAssertEqual(LiveScanWire.modelPath("gemini-3.8-live"), "models/gemini-3.8-live")
        XCTAssertEqual(LiveScanWire.modelPath("models/gemini-3.8-live"), "models/gemini-3.8-live")
        XCTAssertNil(LiveScanWire.modelPath("  "))
        let request = LiveScanWire.request(token: LiveScanFixtures.token())
        XCTAssertEqual(request.url?.absoluteString,
                       "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContentConstrained")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Token auth_tokens/secret-abc")
        XCTAssertFalse(request.url?.absoluteString.contains("secret") ?? true, "the token never goes in the URL")
        XCTAssertEqual(LiveScanWire.silentSecond.count, 32_000, "1 s of 16 kHz 16-bit mono")
    }

    func testTokenDecodesAndRedacts() throws {
        let token = try JSONCoding.makeDecoder().decode(LiveScanToken.self, from: Data(LiveScanFixtures.tokenJSON.utf8))
        XCTAssertEqual(token.model, "gemini-3.8-live")
        XCTAssertEqual(token.nudgeEveryFrames, 5)
        XCTAssertEqual(token.frameMaxFps, 1)
        XCTAssertEqual(token.maxSessionSeconds, 120)
        XCTAssertEqual(token.newSessionExpiresAt, ISO8601Flexible.parse("2026-11-13T10:01:00.5Z"))
        XCTAssertFalse(token.demo)
        XCTAssertFalse(String(describing: token).contains("secret"))
        XCTAssertFalse(String(reflecting: token).contains("secret"))
    }

    func testDemoTokenSelectsTheFake() {
        XCTAssertTrue(LiveScanTransports.make(for: LiveScanFixtures.token(demo: true)) is FakeLiveScanTransport)
        XCTAssertTrue(LiveScanTransports.make(for: LiveScanFixtures.token(demo: false)) is GeminiLiveTransport)
    }
}

@MainActor
final class GeminiLiveTransportTests: XCTestCase {
    private var socket: ScriptedLiveSocket!
    private var clock: FakeVoiceClock!
    private var requests: [URLRequest] = []

    override func setUp() async throws {
        socket = ScriptedLiveSocket()
        clock = FakeVoiceClock()
        requests = []
    }

    private func makeTransport() -> GeminiLiveTransport {
        GeminiLiveTransport(clock: clock) { [unowned self] request in
            self.requests.append(request)
            return self.socket
        }
    }

    private func waitForSent(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where socket.sent.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(socket.sent.count, count, "sent: \(socket.sent)", file: file, line: line)
    }


    private func kinds(_ sent: [String]) -> [String] {
        sent.map { text in
            if text.contains("\"setup\"") { return "setup" }
            if text.contains("\"video\"") { return "video" }
            if text.contains("\"audio\"") { return "audio" }
            if text.contains("\"text\"") { return "text" }
            if text.contains("\"tool_response\"") { return "tool" }
            return "?"
        }
    }

    func testConnectSendsModelOnlySetupWithTheTokenHeader() async throws {
        let transport = makeTransport()
        try await transport.connect(token: LiveScanFixtures.token())
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Token auth_tokens/secret-abc")
        XCTAssertEqual(try jsonObject(socket.sent[0]), try jsonObject(LiveScanFixtures.sdkSetup))
        XCTAssertTrue(clock.isTicking)
        transport.close()
    }

    func testToolCallsBecomeItemsAndAudioIsIgnored() async throws {
        let transport = makeTransport()
        let events = EventLog(transport.events)
        try await transport.connect(token: LiveScanFixtures.token())
        socket.push(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm","data":"AAAA"}}]}}}"#)
        socket.push(#"""
        {"toolCall":{"functionCalls":[
          {"id":"c1","name":"add_item","args":{"name":" soy sauce ","kind":"sauce","confidence":"high"}},
          {"id":"c2","name":"add_item","args":{"name":"ginger","confidence":"MEDIUM"}},
          {"id":"c3","name":"add_item","args":{"name":"thing","confidence":"sure"}},
          {"id":"c4","name":"lookup","args":{}}]}}
        """#)
        let first = await events.next()
        let second = await events.next()
        let third = await events.next()
        XCTAssertEqual(first, .itemReported(callID: "c1", name: "soy sauce", kind: "sauce", confidence: .high))
        XCTAssertEqual(second, .itemReported(callID: "c2", name: "ginger", kind: nil, confidence: .medium))
        XCTAssertEqual(third, .itemReported(callID: "c3", name: "thing", kind: nil, confidence: .unknown))
        await waitForSent(2)
        let ignored = try jsonObject(socket.sent[1])
        XCTAssertEqual(ignored.value(forKeyPath: "tool_response.functionResponses.id") as? [String], ["c4"],
                       "an unknown tool is answered so the model never waits")
        transport.close()
        let received1 = await events.next()
        XCTAssertEqual(received1, .closed(.client))
        let received2 = await events.next()
        XCTAssertNil(received2, "the stream finishes after .closed")
    }

    func testRespondSendsASilentToolResponse() async throws {
        let transport = makeTransport()
        try await transport.connect(token: LiveScanFixtures.token())
        transport.respond(callID: "fc1", name: "add_item", status: "new", canonical: "soy sauce")
        await waitForSent(2)
        XCTAssertEqual(try jsonObject(socket.sent[1]), try jsonObject(LiveScanFixtures.sdkToolResponse))
        transport.close()
    }

    func testFramesAreRateLimitedAndNudged() async throws {
        let transport = makeTransport()
        try await transport.connect(token: LiveScanFixtures.token(nudgeEveryFrames: 2, frameMaxFps: 1))
        let jpeg = Data([0xFF, 0xD8, 0xFF])
        // Let the sender drain between steps, as it does at 1 fps; a backlog would drop media.
        transport.send(frame: jpeg)               // t=0 sent
        await waitForSent(2)
        clock.advance(byMs: 500)
        transport.send(frame: jpeg)               // t=500 dropped
        await waitForSent(3)
        clock.advance(byMs: 300)
        transport.send(frame: jpeg)               // t=800 sent (within the 250 ms jitter tolerance) → nudge
        await waitForSent(6)
        clock.advance(byMs: 1000)
        transport.send(frame: jpeg)               // t=1800 sent
        XCTAssertEqual(transport.framesSent, 3)
        // FakeVoiceClock ticks once per advance, so three keep-alive audio chunks are interleaved.
        await waitForSent(8)
        XCTAssertEqual(kinds(socket.sent).filter { $0 != "audio" }, ["setup", "video", "video", "text", "video"])
        XCTAssertEqual(kinds(socket.sent).filter { $0 == "audio" }.count, 3)
        let nudge = try XCTUnwrap(socket.sent.first { kinds([$0]) == ["text"] })
        XCTAssertEqual(try jsonObject(nudge), try jsonObject(LiveScanFixtures.sdkText))
        transport.close()
    }

    func testSilentAudioEverySecondAndTheSessionLimitCloses() async throws {
        let transport = makeTransport()
        let events = EventLog(transport.events)
        try await transport.connect(token: LiveScanFixtures.token(maxSessionSeconds: 3))
        clock.advance(byMs: 2000)
        await waitForSent(3)
        XCTAssertEqual(kinds(socket.sent), ["setup", "audio", "audio"])
        clock.advance(byMs: 1000)
        let received3 = await events.next()
        XCTAssertEqual(received3, .closed(.sessionLimit))
        let received4 = await events.next()
        XCTAssertNil(received4)
        XCTAssertTrue(socket.cancelled)
        XCTAssertFalse(clock.isTicking)
        transport.send(frame: Data([1]))
        XCTAssertEqual(transport.framesSent, 0, "nothing is sent after close")
    }

    func testSetupTimesOutWhenTheServerNeverAnswers() async throws {
        socket.setupReply = .silent
        let transport = GeminiLiveTransport(clock: clock, setupTimeout: .milliseconds(100)) { [unowned self] _ in self.socket }
        do {
            try await transport.connect(token: LiveScanFixtures.token())
            XCTFail("a silent server must not hang connect")
        } catch {
            XCTAssertEqual(error as? LiveScanError, .setupFailed("timed out"))
        }
        XCTAssertTrue(socket.cancelled)
        XCTAssertFalse(clock.isTicking)
    }

    func testStalledNetworkKeepsMediaBoundedAndToolResponsesInOrder() async throws {
        let transport = makeTransport()
        try await transport.connect(token: LiveScanFixtures.token(nudgeEveryFrames: 0))
        socket.stallSends()
        let jpeg = Data([0xFF, 0xD8])
        transport.send(frame: jpeg)               // picked up by the sender, stuck in flight
        await waitForSent(2)
        for _ in 0..<20 {
            clock.advance(byMs: 1000)             // also queues a keep-alive each tick
            transport.send(frame: jpeg)
        }
        transport.respond(callID: "a", name: "add_item", status: "new", canonical: "eggs")
        transport.respond(callID: "b", name: "add_item", status: "already_in_basket", canonical: "eggs")
        transport.respond(callID: "c", name: "add_item", status: "new", canonical: "rice")
        XCTAssertLessThanOrEqual(transport.queuedMediaCount, GeminiLiveTransport.maxMediaBacklog)
        XCTAssertGreaterThan(transport.droppedMedia, 30, "stale frames and keep-alives are dropped, not queued")
        socket.releaseSends()
        await waitForSent(2 + 3 + GeminiLiveTransport.maxMediaBacklog)
        let afterStall = Array(socket.sent.dropFirst(2))
        XCTAssertEqual(kinds(afterStall), ["tool", "tool", "tool", "audio", "video"], "tool responses jump the media queue")
        let ids = try afterStall.prefix(3).map { try jsonObject($0).value(forKeyPath: "tool_response.functionResponses.id") as? [String] }
        XCTAssertEqual(ids, [["a"], ["b"], ["c"]])
        transport.close()
    }

    func testEveryCallIsAnsweredEvenWithBadArgs() async throws {
        let transport = makeTransport()
        let events = EventLog(transport.events)
        try await transport.connect(token: LiveScanFixtures.token())
        socket.push(#"""
        {"toolCall":{"functionCalls":[
          {"id":"x1","name":"add_item","args":{"name":42,"confidence":"high"}},
          {"id":"x2","name":"add_item","args":"oops"},
          {"id":"x3","name":7},
          {"id":"x4","name":"add_item","args":{"name":"eggs","confidence":5,"kind":["dairy"]}}]}}
        """#)
        let item = await events.next()
        XCTAssertEqual(item, .itemReported(callID: "x4", name: "eggs", kind: nil, confidence: .unknown))
        await waitForSent(4)
        let answered = try socket.sent.dropFirst().map { text -> String? in
            let ids = try jsonObject(text).value(forKeyPath: "tool_response.functionResponses.id") as? [String]
            return ids?.first
        }
        XCTAssertEqual(answered, ["x1", "x2", "x3"], "unusable calls are answered 'ignored', none dropped")
        XCTAssertTrue(socket.sent.dropFirst().allSatisfy { $0.contains("\"ignored\"") })
        transport.close()
    }

    func testOnlyRelevantServerMessagesAreParsed() {
        let audio = Data(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"AAAA"}}]}}}"#.utf8)
        XCTAssertNil(GeminiLiveTransport.decodeIfRelevant(audio), "model audio is skipped without a JSON parse")
        XCTAssertNotNil(GeminiLiveTransport.decodeIfRelevant(Data(#"{"goAway":{}}"#.utf8))?.goAway)
        XCTAssertNotNil(GeminiLiveTransport.decodeIfRelevant(Data(#"{"setupComplete":{}}"#.utf8))?.setupComplete)
    }

    func testLateCloseCodeIsReportedAsAServerClose() async throws {
        let transport = makeTransport()
        let events = EventLog(transport.events)
        try await transport.connect(token: LiveScanFixtures.token())
        socket.serverCloseLate(code: .policyViolation, reason: "token expired", after: .milliseconds(20))
        let received = await events.next()
        XCTAssertEqual(received, .closed(.server(code: 1008, reason: "token expired")))
    }

    func testGoAwaySurfaces() async throws {
        let transport = makeTransport()
        let events = EventLog(transport.events)
        try await transport.connect(token: LiveScanFixtures.token())
        socket.push(#"{"goAway":{"timeLeft":"5s"}}"#)
        let received5 = await events.next()
        XCTAssertEqual(received5, .goAway)
        transport.close()
    }

    func testServerCloseAndDroppedConnectionSurface() async throws {
        let transport = makeTransport()
        let events = EventLog(transport.events)
        try await transport.connect(token: LiveScanFixtures.token())
        socket.serverClose(code: .goingAway, reason: "session over")
        let received6 = await events.next()
        XCTAssertEqual(received6, .closed(.server(code: 1001, reason: "session over")))

        socket = ScriptedLiveSocket()
        let second = makeTransport()
        let secondEvents = EventLog(second.events)
        try await second.connect(token: LiveScanFixtures.token())
        socket.drop()
        guard case .error = await secondEvents.next() else { return XCTFail("expected .error first") }
        let received7 = await secondEvents.next()
        XCTAssertEqual(received7, .closed(.connectionLost))
    }

    func testConnectRejectsExpiredTokensAndFailedSetup() async throws {
        let expired = makeTransport()
        do {
            try await expired.connect(token: LiveScanFixtures.token(newSessionExpiresAt: Date(timeIntervalSinceNow: -1)))
            XCTFail("expired token must not connect")
        } catch {
            XCTAssertEqual(error as? LiveScanError, .tokenExpired)
        }
        XCTAssertTrue(requests.isEmpty, "no socket opened for an expired token")

        socket.setupReply = .reject
        let rejected = makeTransport()
        do {
            try await rejected.connect(token: LiveScanFixtures.token())
            XCTFail("setup failure must throw")
        } catch {
            guard case .setupFailed = error as? LiveScanError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(socket.cancelled)
        XCTAssertFalse(clock.isTicking)
        do {
            try await rejected.connect(token: LiveScanFixtures.token())
            XCTFail("a transport is single-use")
        } catch {
            XCTAssertEqual(error as? LiveScanError, .alreadyConnected)
        }
    }
}

@MainActor
final class FakeLiveScanTransportTests: XCTestCase {
    func testReplaysTheScriptIncludingARepeat() async throws {
        let script = FakeLiveScanTransport.demoScript.map { step in
            FakeLiveScanTransport.Step(delay: .zero, name: step.name, kind: step.kind, confidence: step.confidence)
        }
        let transport = FakeLiveScanTransport(script: script)
        let events = EventLog(transport.events)
        try await transport.connect(token: LiveScanFixtures.token(demo: true))
        var names: [String] = []
        for _ in script {
            guard case .itemReported(let id, let name, _, _) = await events.next() else { return XCTFail("expected an item") }
            names.append(name)
            transport.respond(callID: id, name: "add_item", status: names.dropLast().contains(name) ? "already_in_basket" : "new", canonical: name)
        }
        XCTAssertEqual(names, FakeLiveScanTransport.demoScript.map(\.name))
        XCTAssertGreaterThan(names.count, Set(names).count, "the demo script includes a repeat")
        XCTAssertEqual(transport.responses.filter { $0.status == "already_in_basket" }.map(\.canonical), ["soy sauce"])
        transport.send(frame: Data([1]))
        XCTAssertEqual(transport.framesSent, 1)
        transport.close()
        let received8 = await events.next()
        XCTAssertEqual(received8, .closed(.client))
        let received9 = await events.next()
        XCTAssertNil(received9)
        transport.close()
        XCTAssertFalse(transport.isOpen)
    }

    func testEndingWithSessionLimit() async throws {
        let transport = FakeLiveScanTransport(script: [])
        let events = EventLog(transport.events)
        try await transport.connect(token: LiveScanFixtures.token(demo: true))
        transport.end(.sessionLimit)
        let received10 = await events.next()
        XCTAssertEqual(received10, .closed(.sessionLimit))
    }
}

final class LiveScanAPIClientTests: XCTestCase {
    func testLiveTokenPostsAndDecodes() async throws {
        StubURLProtocol.install { request in
            guard request.httpMethod == "POST", request.url?.path == "/v1/ai/live-token" else {
                return (.stub(request, status: 404), Data())
            }
            return (.stub(request, status: 200), Data(LiveScanFixtures.tokenJSON.utf8))
        }
        let client = APIClient(session: StubURLProtocol.makeSession(),
                               baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://stub.test:8000")),
                               tokenProvider: InMemoryTokenStore(token: "tok"))
        let token = try await client.liveScanToken()
        XCTAssertEqual(token.token, "auth_tokens/secret-abc")
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }
}
