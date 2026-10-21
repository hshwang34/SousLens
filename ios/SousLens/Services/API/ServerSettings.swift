import Foundation
import Observation

/// Where the backend lives. Persisted in `UserDefaults`; the simulator defaults to the Mac's
/// localhost, a physical device starts empty so the tester is prompted for the Mac's LAN IP.
protocol BaseURLProviding: Sendable {
    var baseURL: URL? { get }
    var baseURLString: String { get }
}

/// `UserDefaults` is documented thread-safe but not marked `Sendable`; reads happen on any task.
struct UserDefaultsBaseURLProvider: BaseURLProviding, @unchecked Sendable {
    static let key = "serverBaseURL"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var baseURLString: String {
        let stored = defaults.string(forKey: Self.key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? ServerSettings.platformDefault : stored
    }

    var baseURL: URL? {
        ServerSettings.validate(baseURLString)
    }
}

/// Fixed provider for tests and previews.
struct StaticBaseURLProvider: BaseURLProviding {
    let baseURL: URL?
    var baseURLString: String { baseURL?.absoluteString ?? "" }
}

@MainActor
@Observable
final class ServerSettings {
    #if targetEnvironment(simulator)
    nonisolated static let platformDefault = "http://localhost:8000"
    #else
    nonisolated static let platformDefault = ""
    #endif

    private let defaults: UserDefaults

    /// Fired after the *effective* base URL changes (not on every keystroke — the settings screen
    /// edits a draft and commits on Save). `AppEnvironment` uses it to sign out and drop caches.
    var onEffectiveBaseURLChanged: ((_ oldValue: String, _ newValue: String) -> Void)?

    /// Committed text. Empty means "use platform default".
    var baseURLText: String {
        didSet {
            guard baseURLText != oldValue else { return }
            defaults.set(baseURLText, forKey: UserDefaultsBaseURLProvider.key)
            let before = Self.effective(oldValue)
            let after = effectiveBaseURLString
            if before != after {
                onEffectiveBaseURLChanged?(before, after)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.baseURLText = defaults.string(forKey: UserDefaultsBaseURLProvider.key) ?? Self.platformDefault
    }

    var effectiveBaseURLString: String { Self.effective(baseURLText) }

    nonisolated static func effective(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? platformDefault : trimmed
    }

    var isValid: Bool { Self.validate(effectiveBaseURLString) != nil }

    var isConfigured: Bool { !effectiveBaseURLString.isEmpty }

    func resetToDefault() {
        baseURLText = Self.platformDefault
    }

    /// Accepts only http(s) URLs with a host; strips a trailing slash.
    nonisolated static func validate(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url
    }
}
