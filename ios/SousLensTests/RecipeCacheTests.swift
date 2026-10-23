import Foundation
import XCTest
@testable import SousLens

final class RecipeCacheTests: XCTestCase {
    private var directory: URL = FileManager.default.temporaryDirectory
        .appending(path: "RecipeCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTrip() throws {
        let cache = RecipeCache(directory: directory)
        XCTAssertNil(cache.load())

        let page = try Fixtures.decode(RecipePage.self, from: "recipes_list")
        try cache.save(page.items)

        let loaded = try XCTUnwrap(cache.load())
        XCTAssertEqual(loaded.items, page.items)
        XCTAssertLessThan(abs(loaded.savedAt.timeIntervalSinceNow), 5)

        try cache.clear()
        XCTAssertNil(cache.load())
        try cache.clear()
    }

    func testCorruptFileLoadsAsNil() throws {
        let cache = RecipeCache(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: cache.fileURL)
        XCTAssertNil(cache.load())
    }
}
