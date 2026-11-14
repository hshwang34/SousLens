import Foundation

/// `POST /v1/ai/live-token` (brief 016 PR 2). A single-use Gemini Live token locked on the server
/// to the model, instructions and `add_item` tool. The phone never holds a provider key.
struct LiveScanToken: Decodable, Sendable, Equatable {
    /// `auth_tokens/...`. Secret: never log it (`description` redacts it).
    let token: String
    let model: String
    let expiresAt: Date
    /// The session must open before this.
    let newSessionExpiresAt: Date
    let maxSessionSeconds: Int
    let nudgeText: String
    let nudgeEveryFrames: Int
    let frameMaxFps: Double
    /// Mock provider or over a cap: replay the demo script, never auto-save.
    let demo: Bool
}

extension LiveScanToken: CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "LiveScanToken(model: \(model), demo: \(demo), token: <redacted>)" }
    var debugDescription: String { description }
}

enum LiveScanConfidence: String, Sendable, Equatable {
    case high, medium, low, unknown

    init(raw: String?) {
        self = raw.flatMap { LiveScanConfidence(rawValue: $0.lowercased()) } ?? .unknown
    }
}

enum LiveScanCloseReason: Sendable, Equatable {
    /// `maxSessionSeconds` reached; the caller rotates to a fresh token and session.
    case sessionLimit
    /// `close()` was called.
    case client
    /// The server closed the socket.
    case server(code: Int, reason: String?)
    /// The connection dropped without a close frame.
    case connectionLost
}

enum LiveScanError: Error, Sendable, Equatable {
    case alreadyConnected
    case tokenExpired
    case invalidModel
    case setupFailed(String)
}

enum LiveScanEvent: Sendable, Equatable {
    /// One `add_item` tool call. Answer it with `respond(callID:...)`.
    case itemReported(callID: String, name: String, kind: String?, confidence: LiveScanConfidence)
    /// The server will close soon; rotate.
    case goAway
    /// Always the last event of a session.
    case closed(LiveScanCloseReason)
    case error(String)
}

/// One Live scan session. Make a new transport per session (rotation = close, mint, connect).
///
/// - `connect` returns once the server confirmed setup. Throws on an expired token or failed setup.
/// - `send(frame:)` drops frames over `frameMaxFps`; a text nudge follows every `nudgeEveryFrames`th
///   sent frame. Frames are sent and forgotten, never stored.
/// - `events` finishes after `.closed`.
@MainActor
protocol LiveScanTransport: AnyObject {
    var events: AsyncStream<LiveScanEvent> { get }
    func connect(token: LiveScanToken) async throws
    func send(frame jpeg: Data)
    func respond(callID: String, name: String, status: String, canonical: String?)
    func close()
}

enum LiveScanTransports {
    /// `demo` tokens never reach Gemini: they replay the scripted demo items.
    @MainActor
    static func make(for token: LiveScanToken) -> any LiveScanTransport {
        token.demo ? FakeLiveScanTransport(script: FakeLiveScanTransport.demoScript) : GeminiLiveTransport()
    }
}

protocol LiveScanService: Sendable {
    /// Reserves the scan's worst-case cost, then mints the token. Over a cap → demo or an error.
    func liveScanToken() async throws -> LiveScanToken
}

extension APIClient: LiveScanService {
    func liveScanToken() async throws -> LiveScanToken {
        try await send(.post("/v1/ai/live-token", body: Self.emptyObject))
    }
}
