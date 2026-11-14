import Foundation

/// What the voice bar shows for one moment of a `VoiceSession` (brief 012). Pure, so tests assert
/// the copy, captions and controls without inspecting views.
struct VoiceBarPresentation: Equatable {
    enum Mode: Equatable {
        case starting, listening, hearing, thinking, speaking, paused, ended
    }

    struct Line: Identifiable, Equatable {
        let id: String
        let speaker: VoiceSpeaker
        let text: String
        let isPartial: Bool

        var speakerLabel: String { speaker == .user ? "You" : "Umma" }
        var accessibilityLabel: String { "\(speakerLabel)\(isPartial ? ", still talking" : ""): \(text)" }
    }

    let mode: Mode
    let statusText: String
    let symbolName: String
    /// The mic line (PRD §6.1: always name the input). It only claims a live mic while the
    /// session is actually listening; paused or starting reads "Mic off".
    struct Input: Equatable {
        let text: String
        let symbolName: String
        let accessibilityLabel: String
        let isLive: Bool
    }

    let input: Input?
    /// Newest last; both sides interleaved by time, then the user's in-flight words.
    let lines: [Line]
    let notice: String?
    let endedText: String?
    let showsPauseToggle: Bool
    let pauseToggleTitle: String
    let pauseToggleSymbol: String
    let showsStop: Bool

    /// What VoiceOver hears (politely) when the mode changes.
    var announcement: String {
        switch mode {
        case .ended: endedText ?? statusText
        default: statusText
        }
    }

    init(state: VoiceState,
         userCaptions: [VoiceSegment],
         assistantCaptions: [VoiceSegment],
         partial: VoiceSegment?,
         inputLabel: String,
         notice: String?,
         lineLimit: Int = 3) {
        switch state {
        case .idle, .ended: mode = .ended
        case .starting: mode = .starting
        case .listening: mode = .listening
        case .userSpeaking: mode = .hearing
        case .thinking: mode = .thinking
        case .speaking: mode = .speaking
        case .paused: mode = .paused
        }
        statusText = Self.status(mode)
        symbolName = Self.symbol(mode)
        switch mode {
        case .ended:
            input = nil
        case .paused:
            input = Input(text: "Mic off (paused)", symbolName: "mic.slash.fill",
                          accessibilityLabel: "Microphone off while paused", isLive: false)
        case .starting:
            input = Input(text: "Mic off (starting)", symbolName: "mic.slash.fill",
                          accessibilityLabel: "Microphone not on yet", isLive: false)
        default:
            input = Input(text: "Mic: \(inputLabel)", symbolName: "mic.fill",
                          accessibilityLabel: "Listening through \(inputLabel)", isLive: true)
        }
        self.notice = notice
        endedText = Self.endedText(state)

        let finals = (userCaptions + assistantCaptions)
            .sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
            .map { Line(id: "\($0.speaker.rawValue)-\($0.id)", speaker: $0.speaker, text: $0.text, isPartial: false) }
        let live = partial.map { [Line(id: "partial", speaker: .user, text: $0.text, isPartial: true)] } ?? []
        lines = Array((finals + live).suffix(max(lineLimit, 0)))

        let isLive = mode != .ended
        showsPauseToggle = isLive && mode != .starting
        pauseToggleTitle = mode == .paused ? "Resume" : "Pause"
        pauseToggleSymbol = mode == .paused ? "play.fill" : "pause.fill"
        showsStop = isLive
    }

    @MainActor
    init(session: VoiceSession, lineLimit: Int = 3) {
        self.init(state: session.state,
                  userCaptions: session.userCaptions,
                  assistantCaptions: session.assistantCaptions,
                  partial: session.partial,
                  inputLabel: session.inputLabel,
                  notice: session.notice,
                  lineLimit: lineLimit)
    }

    private static func status(_ mode: Mode) -> String {
        switch mode {
        case .starting: "Starting voice…"
        case .listening: "Listening"
        case .hearing: "Hearing you"
        case .thinking: "Thinking…"
        case .speaking: "Umma is speaking"
        case .paused: "Paused. Not listening"
        case .ended: "Voice is off"
        }
    }

    private static func symbol(_ mode: Mode) -> String {
        switch mode {
        case .starting, .listening: "waveform"
        case .hearing: "waveform.badge.mic"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        case .paused: "pause.circle"
        case .ended: "mic.slash"
        }
    }

    private static func endedText(_ state: VoiceState) -> String? {
        guard case .ended(let reason) = state else { return nil }
        switch reason {
        case .stopped, .stopCommand: return "Voice is off."
        case .silenceTimeout: return "Voice turned off after a long quiet stretch."
        case .failed(let message): return "Voice stopped: \(message)"
        }
    }
}
