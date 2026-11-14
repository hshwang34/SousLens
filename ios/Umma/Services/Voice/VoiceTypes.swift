import Foundation

/// Brief 012: where the voice pipeline runs. Free is on the iPhone (Apple speech + voice); Paid
/// streams to our server (brief 012 PR 2).
enum VoiceTier: String, Sendable, Equatable {
    case free
    case paid
}

/// What the voice session is doing. The voice bar renders this; consumers (cooking, recipe
/// capture) drive `thinking` and `speaking`.
enum VoiceState: Equatable, Sendable {
    case idle
    case starting
    case listening
    /// Speech detected, a hypothesis may be in flight.
    case userSpeaking
    /// A consumer is working on a reply (agent turn, extraction).
    case thinking
    /// Umma is talking; the mic transcript is gated so it never hears itself.
    case speaking
    case paused
    case ended(VoiceEndReason)

    var isActive: Bool {
        switch self {
        case .idle, .ended: false
        default: true
        }
    }
}

enum VoiceEndReason: Equatable, Sendable {
    /// The Stop button or `stop()`.
    case stopped
    /// The user said "stop".
    case stopCommand
    /// No speech for `VoiceSessionConfig.silenceTimeoutMs`.
    case silenceTimeout
    case failed(String)
}

enum VoiceSpeaker: String, Sendable, Equatable {
    case user
    case assistant
}

/// One caption line. Times are milliseconds since the session started (the session clock).
struct VoiceSegment: Equatable, Sendable, Identifiable {
    let id: Int
    let speaker: VoiceSpeaker
    let text: String
    let startMs: Int64
    let endMs: Int64
    let isFinal: Bool
}

/// What a transport reports. Transcript offsets are wall-clock milliseconds since the
/// transport's `start` returned (paused time included), so the session adds its own start
/// offset to put them on the session clock; `nil` means "now".
enum VoiceTransportEvent: Equatable, Sendable {
    case transcript(text: String, isFinal: Bool, startMs: Int64? = nil, endMs: Int64? = nil)
    /// On-device voice activity (audio level or VAD), independent of recognition.
    case voiceActivity(Bool)
    /// The input route changed; `label` is the honest source name ("iPhone mic").
    case inputChanged(label: String)
    /// An audio-session interruption (a call, Siri) began or ended.
    case interruption(began: Bool)
    case failed(String)
}

/// Things the session reports to its consumer, in order.
enum VoiceSessionEvent: Equatable, Sendable {
    /// A final user segment, timestamped on the session clock.
    case userSegment(VoiceSegment)
    /// Silence reached `pauseThresholdMs` after the user spoke (once per silence span).
    case pause(silenceMs: Int64)
    case ended(VoiceEndReason)
}

struct VoiceSessionConfig: Equatable, Sendable {
    /// End after this much silence; `nil` never ends on silence (recipe capture, 30–45 min).
    var silenceTimeoutMs: Int64? = 10 * 60 * 1000
    /// Silence that counts as a pause (brief 014 asks after about 1.5 s).
    var pauseThresholdMs: Int64 = 1500
    /// After Umma stops talking, transcripts are still dropped for this long (room echo tail).
    var echoTailMs: Int64 = 400
    /// After a pause, the final for words already heard is still accepted this long.
    var pauseFinalGraceMs: Int64 = 1500
    var tickIntervalMs: Int64 = 250
    /// Caption lines kept per speaker side for the voice bar.
    var captionLimit = 3
}

/// The few commands the core itself acts on. Everything else is the consumer's business, so
/// "stop asking" (brief 014) is deliberately not a stop.
enum VoiceCommand: Equatable, Sendable {
    case stop

    static func parse(_ text: String) -> VoiceCommand? {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let stops: Set<String> = ["stop", "stop listening", "stop voice mode", "end voice mode", "umma stop"]
        return stops.contains(words) ? .stop : nil
    }
}
