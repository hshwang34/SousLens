import Foundation

/// Last canonical Session seen from the server, so the cooking screen can show it read-only when
/// offline ("Reconnect to continue"). It is a display copy only; nothing is ever advanced from it.
protocol SessionCaching: Sendable {
    func load() -> CookingSession?
    func save(_ session: CookingSession) throws
    func clear() throws
}

struct SessionCache: SessionCaching {
    let fileURL: URL

    init(directory: URL? = nil, fileName: String = "current-session.json") {
        let base = directory ?? RecipeCache.defaultDirectory()
        fileURL = base.appending(path: fileName)
    }

    func load() -> CookingSession? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONCoding.makeDecoder().decode(CookingSession.self, from: data)
    }

    func save(_ session: CookingSession) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONCoding.makeEncoder().encode(session)
        // Private session data: protected while the device is locked.
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// Memory-only cache (previews, tests).
final class InMemorySessionCache: SessionCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CookingSession?

    init(_ session: CookingSession? = nil) { stored = session }

    func load() -> CookingSession? { lock.withLock { stored } }
    func save(_ session: CookingSession) throws { lock.withLock { stored = session } }
    func clear() throws { lock.withLock { stored = nil } }
}
