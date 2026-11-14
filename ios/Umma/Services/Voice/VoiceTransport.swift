import Foundation
import Observation

/// Speech in plus voice out, for one voice session. Free (on-device) and Paid (server) tiers
/// plug in here; `VoiceSession` owns the state machine on top.
///
/// Contract:
/// - `start(onEvent:)` opens the mic and reports events on the main actor until `stop()`.
///   Events after `stop()` are ignored by the session (generation-checked), so a transport
///   may deliver a late one without harm.
/// - `setInputPaused(true)` stops feeding audio to recognition (paused means not listening).
/// - `flushHypothesis()` drops the in-flight partial, so words heard while Umma speaks never merge
///   into the user's next segment.
/// - `speak` returns when the utterance finishes or `stopSpeaking()` cuts it off.
@MainActor
protocol VoiceTransport: AnyObject {
    var tier: VoiceTier { get }
    var isAvailable: Bool { get }
    /// The honest input name for the voice bar. Never "glasses mic" without verified HFP.
    var inputLabel: String { get }
    /// A visible note about this transport (e.g. why Paid fell back to on-device voice).
    var notice: String? { get }

    func start(onEvent: @escaping @MainActor @Sendable (VoiceTransportEvent) -> Void) async throws
    func stop()
    func setInputPaused(_ paused: Bool)
    func flushHypothesis()
    func speak(_ text: String) async
    func stopSpeaking()
}

/// Paid tier until brief 012 PR 2 lands: delegates everything to the Free transport and says so.
@MainActor
final class PaidVoiceTransport: VoiceTransport {
    static let fallbackNotice = "Server voice isn't ready yet, so voice runs on this iPhone."

    let tier: VoiceTier = .free
    private let fallback: any VoiceTransport

    init(fallback: any VoiceTransport) {
        self.fallback = fallback
    }

    var isAvailable: Bool { fallback.isAvailable }
    var inputLabel: String { fallback.inputLabel }
    var notice: String? { Self.fallbackNotice }

    func start(onEvent: @escaping @MainActor @Sendable (VoiceTransportEvent) -> Void) async throws {
        try await fallback.start(onEvent: onEvent)
    }

    func stop() { fallback.stop() }
    func setInputPaused(_ paused: Bool) { fallback.setInputPaused(paused) }
    func flushHypothesis() { fallback.flushHypothesis() }
    func speak(_ text: String) async { await fallback.speak(text) }
    func stopSpeaking() { fallback.stopSpeaking() }
}

/// Settings → Voice. "Run voice on this iPhone" keeps a Paid account on the Free pipeline.
@MainActor
@Observable
final class VoiceSettings {
    static let runOnDeviceKey = "voice.runOnDevice"

    private let defaults: UserDefaults

    var runOnDevice: Bool {
        didSet { defaults.set(runOnDevice, forKey: Self.runOnDeviceKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        runOnDevice = defaults.bool(forKey: Self.runOnDeviceKey)
    }
}

enum VoiceTierChoice {
    /// Paid only when the server says so and the user hasn't asked for on-device voice. A missing
    /// entitlement (older server, cached user) is Free.
    static func tier(entitlement: User.Entitlement?, runOnDevice: Bool) -> VoiceTier {
        entitlement == .paid && !runOnDevice ? .paid : .free
    }

    @MainActor
    static func transport(entitlement: User.Entitlement?,
                          runOnDevice: Bool,
                          makeFree: () -> any VoiceTransport) -> any VoiceTransport {
        switch tier(entitlement: entitlement, runOnDevice: runOnDevice) {
        case .free: makeFree()
        case .paid: PaidVoiceTransport(fallback: makeFree())
        }
    }
}
