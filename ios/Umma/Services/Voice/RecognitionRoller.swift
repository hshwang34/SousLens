import Foundation

/// The pure bookkeeping behind continuous on-device recognition.
///
/// Apple ends a recognition task after about a minute, and the on-device recognizer only marks a
/// result final when its audio ends. So the transport *rolls*: it opens a new task, points the
/// mic at it, then ends the old task's audio. The old task finalizes the words it already heard,
/// and nothing is lost. Rolling at a pause after speech also turns hypotheses into final segments.
///
/// Every task remembers where it started in transport audio time, so its result timestamps
/// (seconds since the task's own start) re-stamp onto one continuous clock.
struct RecognitionRoller: Sendable {
    struct Config: Sendable, Equatable {
        /// Roll at the next pause once a task is this old.
        var softTaskMs: Int64 = 40_000
        /// Roll even mid-speech at this age, before Apple's ~60 s limit cuts it.
        var hardTaskMs: Int64 = 55_000
        /// Silence after speech that finalizes the current hypothesis.
        var pauseFinalizeMs: Int64 = 800
    }

    /// One word/segment of a result, as `SFTranscriptionSegment` reports it.
    struct Piece: Sendable, Equatable {
        var timestamp: TimeInterval
        var duration: TimeInterval
    }

    let config: Config
    private(set) var currentTask = 0
    private var origins: [Int: Int64] = [:]
    /// Retired tasks still owed a final, with their last partial text as a fallback.
    private var retiring: [Int: String] = [:]
    private var discarded: Set<Int> = []
    private var currentText = ""

    init(config: Config = .init()) {
        self.config = config
    }

    /// Opens a task that starts at `audioMs` (transport audio time). Returns its id.
    mutating func beginTask(atAudioMs audioMs: Int64) -> Int {
        currentTask += 1
        origins[currentTask] = audioMs
        currentText = ""
        return currentTask
    }

    /// Retire the current task (the caller ends its audio), optionally dropping whatever it heard.
    mutating func retireCurrent(discard: Bool) {
        guard origins[currentTask] != nil else { return }
        if discard {
            discarded.insert(currentTask)
        } else {
            retiring[currentTask] = currentText
        }
        currentText = ""
    }

    var hasHypothesis: Bool { !currentText.isEmpty }

    /// Whether to roll now. `silentForMs` is how long the voice-activity detector has heard silence.
    func shouldRoll(audioMs: Int64, silentForMs: Int64) -> Bool {
        guard let origin = origins[currentTask] else { return false }
        let age = audioMs - origin
        if age >= config.hardTaskMs { return true }
        if hasHypothesis, silentForMs >= config.pauseFinalizeMs { return true }
        return age >= config.softTaskMs && silentForMs >= config.pauseFinalizeMs
    }

    /// Maps a recognizer callback to a transport event, or `nil` when it should be dropped.
    /// Partials only come from the current task; a retired task contributes exactly one final.
    mutating func result(task: Int, text: String, isFinal: Bool, pieces: [Piece]) -> VoiceTransportEvent? {
        if discarded.contains(task) {
            if isFinal { forget(task) }
            return nil
        }
        guard let origin = origins[task] else { return nil }
        let (start, end) = Self.span(pieces, origin: origin)
        if task == currentTask {
            if isFinal {
                currentText = ""
                origins[task] = nil
                return text.isEmpty ? nil : .transcript(text: text, isFinal: true, startMs: start, endMs: end)
            }
            currentText = text
            return text.isEmpty ? nil : .transcript(text: text, isFinal: false, startMs: start, endMs: end)
        }
        guard retiring[task] != nil else { return nil }
        if isFinal {
            retiring[task] = nil
            origins[task] = nil
            return text.isEmpty ? nil : .transcript(text: text, isFinal: true, startMs: start, endMs: end)
        }
        retiring[task] = text
        return nil
    }

    /// The task ended without a final (error, cancel, "no speech"): its last partial becomes the
    /// final, so a roll never drops words.
    mutating func taskEnded(_ task: Int) -> VoiceTransportEvent? {
        defer {
            origins[task] = nil
            retiring[task] = nil
            discarded.remove(task)
        }
        if discarded.contains(task) { return nil }
        let text = task == currentTask ? currentText : (retiring[task] ?? "")
        if task == currentTask { currentText = "" }
        return text.isEmpty ? nil : .transcript(text: text, isFinal: true)
    }

    /// Number of tasks still tracked (tests: nothing leaks over a long session).
    var trackedTaskCount: Int { Set(origins.keys).union(retiring.keys).union(discarded).count }

    private mutating func forget(_ task: Int) {
        origins[task] = nil
        retiring[task] = nil
        discarded.remove(task)
    }

    /// Word timings are seconds since the task started; partials often report zeros, so a span
    /// is only returned when the recognizer actually timed the words.
    static func span(_ pieces: [Piece], origin: Int64) -> (Int64?, Int64?) {
        guard let first = pieces.first, let last = pieces.last, last.timestamp + last.duration > 0 else {
            return (nil, nil)
        }
        let start = origin + Int64((first.timestamp * 1000).rounded())
        let end = origin + Int64(((last.timestamp + last.duration) * 1000).rounded())
        return (start, end)
    }
}

/// Speech / silence from audio levels, with hysteresis and an adaptive noise floor so a humming
/// extractor fan doesn't read as someone talking.
struct VoiceActivityDetector: Sendable {
    struct Config: Sendable, Equatable {
        /// Speech must sit this far above the noise floor…
        var marginDb: Float = 12
        /// …and above this absolute level.
        var minSpeechDb: Float = -50
        /// Loud for this long → speech starts.
        var attackMs: Int64 = 120
        /// Quiet for this long → speech ends.
        var releaseMs: Int64 = 350
    }

    let config: Config
    private(set) var isSpeech = false
    private(set) var noiseFloorDb: Float = -60
    private(set) var lastSpeechAtMs: Int64?
    private var candidateSinceMs: Int64?

    init(config: Config = .init()) {
        self.config = config
    }

    /// Feed one buffer's RMS level. Returns the new state when it changes.
    mutating func process(levelDb: Float, atMs: Int64) -> Bool? {
        let loud = levelDb >= max(config.minSpeechDb, noiseFloorDb + config.marginDb)
        // The floor drops fast, rises slowly, and slowest while loud: a steady fan becomes the
        // floor in a few seconds, while speech (which keeps pausing) never does.
        let rate: Float = levelDb < noiseFloorDb ? 0.3 : (loud ? 0.005 : 0.02)
        noiseFloorDb += (levelDb - noiseFloorDb) * rate
        if isSpeech, loud { lastSpeechAtMs = atMs }
        guard loud != isSpeech else {
            candidateSinceMs = nil
            return nil
        }
        let since = candidateSinceMs ?? atMs
        candidateSinceMs = since
        guard atMs - since >= (loud ? config.attackMs : config.releaseMs) else { return nil }
        isSpeech = loud
        candidateSinceMs = nil
        if loud { lastSpeechAtMs = atMs }
        return isSpeech
    }

    /// Milliseconds of silence at `atMs` (0 while speaking or before any speech).
    func silentFor(atMs: Int64) -> Int64 {
        guard !isSpeech, let last = lastSpeechAtMs else { return isSpeech ? 0 : atMs }
        return max(0, atMs - last)
    }

    /// RMS level of float samples in dBFS (−160 for silence).
    static func levelDb(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return -160 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        return rms > 0 ? max(-160, 20 * log10(rms)) : -160
    }
}
