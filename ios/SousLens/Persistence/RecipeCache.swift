import Foundation

/// Snapshot of the last recipe list, so Explore can show cards when the backend is unreachable.
struct CachedRecipeList: Codable, Sendable, Equatable {
    let items: [RecipeCard]
    let savedAt: Date
}

protocol RecipeCaching: Sendable {
    func load() -> CachedRecipeList?
    func save(_ items: [RecipeCard]) throws
    func clear() throws
}

/// JSON file in Application Support. Only the unfiltered first page is cached; search results are not.
struct RecipeCache: RecipeCaching {
    let fileURL: URL

    init(directory: URL? = nil, fileName: String = "recipes.json") {
        let base = directory ?? Self.defaultDirectory()
        self.fileURL = base.appending(path: fileName)
    }

    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appending(path: "SousLens", directoryHint: .isDirectory)
    }

    func load() -> CachedRecipeList? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONCoding.makeDecoder().decode(CachedRecipeList.self, from: data)
    }

    func save(_ items: [RecipeCard]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = CachedRecipeList(items: items, savedAt: Date())
        let data = try JSONCoding.makeEncoder().encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
