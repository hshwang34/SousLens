import Foundation

/// Which physical input is active. PRD §6.1: always show the user which input they are using.
enum CaptureSourceKind: String, Sendable, CaseIterable {
    case phone
    case glasses

    var displayName: String {
        switch self {
        case .phone: return "iPhone"
        case .glasses: return "Glasses"
        }
    }
}

struct CapturedFrame: Sendable, Equatable {
    let jpegData: Data
    let capturedAt: Date
}

struct TranscriptChunk: Sendable, Equatable {
    let text: String
    let isFinal: Bool
    let receivedAt: Date
}

enum CaptureError: Error, Equatable, LocalizedError {
    /// Hardware missing (simulator) or the feature flag is off.
    case unavailable(CaptureSourceKind, reason: String)
    /// User denied or restricted the permission; `explainer` is the copy to show.
    case permissionDenied(permission: String, explainer: String)
    case notRunning
    /// `stopPreview()` / `stop()` won the race against a still-starting session.
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let kind, let reason):
            return "\(kind.displayName) input is unavailable: \(reason)"
        case .permissionDenied(_, let explainer):
            return explainer
        case .notRunning:
            return "Start the preview before capturing a frame."
        case .cancelled:
            return "Stopped before it finished starting."
        case .failed(let message):
            return message
        }
    }
}

/// Tracks which start attempt is current. `stop()` always bumps it, so a start that resumes from an
/// `await` (permission prompt, session configuration) can tell it was superseded and give up.
struct CaptureStartGate: Sendable, Equatable {
    private(set) var generation = 0

    /// Begin a new attempt; the returned token is compared after every await.
    mutating func begin() -> Int {
        generation += 1
        return generation
    }

    /// Invalidate any attempt in flight.
    mutating func supersede() {
        generation += 1
    }

    func isCurrent(_ token: Int) -> Bool {
        token == generation
    }
}

/// Keeps block-based `NotificationCenter` observers alive and removes them when the owner dies
/// (block observers are not auto-removed). Nonisolated so it can be released from any deinit.
final class NotificationObserverBag: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []

    func add(_ token: NSObjectProtocol) {
        lock.withLock { tokens.append(token) }
    }

    func removeAll() {
        let removed = lock.withLock { () -> [NSObjectProtocol] in
            let current = tokens
            tokens.removeAll()
            return current
        }
        removed.forEach(NotificationCenter.default.removeObserver)
    }

    deinit {
        removeAll()
    }
}

/// Per-adapter feature flags (UserDefaults-backed; default on). Off → the fake adapter is injected.
struct CaptureFeatureFlags: Sendable, Equatable {
    var phoneCamera: Bool
    var phoneSpeech: Bool
    var systemAudio: Bool

    static let allOn = CaptureFeatureFlags(phoneCamera: true, phoneSpeech: true, systemAudio: true)

    enum Key {
        static let phoneCamera = "feature.capture.phoneCamera"
        static let phoneSpeech = "feature.capture.phoneSpeech"
        static let systemAudio = "feature.capture.systemAudio"
    }

    static func load(from defaults: UserDefaults = .standard) -> CaptureFeatureFlags {
        func flag(_ key: String) -> Bool {
            defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
        }
        return CaptureFeatureFlags(
            phoneCamera: flag(Key.phoneCamera),
            phoneSpeech: flag(Key.phoneSpeech),
            systemAudio: flag(Key.systemAudio)
        )
    }
}
