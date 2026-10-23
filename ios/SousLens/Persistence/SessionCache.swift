import Foundation

/// Who a cached session belongs to: the signed-in user on a given server.
struct SessionOwner: Codable, Sendable, Hashable {
    let userId: UUID
    let server: String
}

/// Last canonical Session seen from the server, so the cooking screen can show it read-only when
/// offline ("Reconnect to continue"). It is a display copy only; nothing is ever advanced from it.
///
/// The copy is stamped with its owner (user id + server). `load(for:)` returns it only to that
/// same owner and deletes it for anyone else, so one account never sees another's session.
protocol SessionCaching: Sendable {
    func load(for owner: SessionOwner) -> CookingSession?
    func save(_ session: CookingSession, owner: SessionOwner) throws
    func clear() throws
}

/// On-disk envelope.
struct CachedSession: Codable, Sendable, Equatable {
    let owner: SessionOwner
    let session: CookingSession
}

struct SessionCache: SessionCaching {
    let fileURL: URL

    init(directory: URL? = nil, fileName: String = "current-session.json") {
        let base = directory ?? RecipeCache.defaultDirectory()
        fileURL = base.appending(path: fileName)
    }

    func load(for owner: SessionOwner) -> CookingSession? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let cached = try? JSONCoding.makeDecoder().decode(CachedSession.self, from: data), cached.owner == owner else {
            // Unreadable, or someone else's: never shown, and not kept around either.
            try? clear()
            return nil
        }
        return cached.session
    }

    func save(_ session: CookingSession, owner: SessionOwner) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONCoding.makeEncoder().encode(CachedSession(owner: owner, session: session))
        // Private session data: protected while the device is locked.
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        // A transient display copy: never in iCloud / iTunes backups.
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}

/// Memory-only cache (previews, tests) with the same owner rule.
final class InMemorySessionCache: SessionCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CachedSession?

    init(_ cached: CachedSession? = nil) { stored = cached }

    var raw: CachedSession? { lock.withLock { stored } }

    func load(for owner: SessionOwner) -> CookingSession? {
        lock.withLock {
            guard let stored else { return nil }
            guard stored.owner == owner else {
                self.stored = nil
                return nil
            }
            return stored.session
        }
    }

    func save(_ session: CookingSession, owner: SessionOwner) throws {
        lock.withLock { stored = CachedSession(owner: owner, session: session) }
    }

    func clear() throws { lock.withLock { stored = nil } }
}
