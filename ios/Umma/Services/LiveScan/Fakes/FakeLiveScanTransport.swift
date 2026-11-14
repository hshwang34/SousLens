import Foundation

/// Replays scripted `add_item` reports. Used by tests, and by demo mode (`demo: true` tokens:
/// `AI_PROVIDER=mock` or over a cap) where the screen labels the items "Demo mode".
@MainActor
final class FakeLiveScanTransport: LiveScanTransport {
    struct Step: Sendable, Equatable {
        var delay: Duration
        var name: String
        var kind: String?
        var confidence: LiveScanConfidence
    }

    struct Response: Equatable {
        let callID: String
        let name: String
        let status: String
        let canonical: String?
    }

    /// About one item every 1.5 s, with a repeat ("soy sauce") and two unsure items.
    static let demoScript: [Step] = [
        Step(delay: .seconds(2), name: "eggs", kind: "dairy", confidence: .high),
        Step(delay: .milliseconds(1500), name: "soy sauce", kind: "sauce", confidence: .high),
        Step(delay: .milliseconds(1500), name: "scallions", kind: "produce", confidence: .high),
        Step(delay: .milliseconds(1500), name: "gochujang", kind: "sauce", confidence: .medium),
        Step(delay: .milliseconds(1500), name: "soy sauce", kind: "sauce", confidence: .high),
        Step(delay: .milliseconds(1500), name: "butter", kind: "dairy", confidence: .high),
        Step(delay: .milliseconds(1500), name: "ginger", kind: "produce", confidence: .low),
        Step(delay: .milliseconds(1500), name: "rice", kind: "grain", confidence: .high),
    ]

    let events: AsyncStream<LiveScanEvent>
    private let continuation: AsyncStream<LiveScanEvent>.Continuation
    private let script: [Step]
    private var player: Task<Void, Never>?
    private var didEnd = false
    var connectError: Error?

    private(set) var connectedToken: LiveScanToken?
    private(set) var isOpen = false
    private(set) var framesSent = 0
    private(set) var responses: [Response] = []

    init(script: [Step]) {
        self.script = script
        (events, continuation) = AsyncStream.makeStream(of: LiveScanEvent.self)
    }

    func connect(token: LiveScanToken) async throws {
        guard connectedToken == nil, !didEnd else { throw LiveScanError.alreadyConnected }
        if let connectError { throw connectError }
        connectedToken = token
        isOpen = true
        let script = script
        let continuation = continuation
        player = Task {
            for (index, step) in script.enumerated() {
                try? await Task.sleep(for: step.delay)
                if Task.isCancelled { return }
                continuation.yield(.itemReported(callID: "demo-\(index)", name: step.name,
                                                 kind: step.kind, confidence: step.confidence))
            }
        }
    }

    func send(frame jpeg: Data) {
        if isOpen { framesSent += 1 }
    }

    func respond(callID: String, name: String, status: String, canonical: String?) {
        guard isOpen else { return }
        responses.append(Response(callID: callID, name: name, status: status, canonical: canonical))
    }

    /// Ends the session as the real transport would (tests use `.sessionLimit`, `.server`).
    func end(_ reason: LiveScanCloseReason) {
        guard !didEnd else { return }
        didEnd = true
        isOpen = false
        player?.cancel()
        continuation.yield(.closed(reason))
        continuation.finish()
    }

    func emit(_ event: LiveScanEvent) {
        continuation.yield(event)
    }

    func close() {
        end(.client)
    }
}
