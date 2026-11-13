import Foundation
import XCTest
@testable import Umma

final class DeepLinkTests: XCTestCase {
    private let id = UUID(uuidString: "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")!

    func testParsesCustomSchemeAndUniversalLink() throws {
        XCTAssertEqual(DeepLink.parse(URL(string: "umma://recipe/a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")!), .recipe(id))
        XCTAssertEqual(DeepLink.parse(URL(string: "https://umma.app/r/a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")!), .recipe(id))
        XCTAssertEqual(DeepLink.parse(URL(string: "https://umma.app/r/a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d/")!), .recipe(id))
        XCTAssertNil(DeepLink.parse(URL(string: "https://www.umma.app/r/a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")!),
                     "only the host in the associated-domains entitlement")
        XCTAssertEqual(DeepLink.parse(URL(string: "UMMA://recipe/A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D")!), .recipe(id), "scheme and UUID are case-insensitive")
        XCTAssertEqual(DeepLink.parse(URL(string: "https://umma.app/r/a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d?utm=share")!), .recipe(id), "query is ignored")
    }

    func testRejectsEverythingElse() {
        for raw in [
            "https://umma.app/recipes/a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
            "https://umma.app/r/not-a-uuid",
            "https://umma.app/r/",
            "https://umma.app/r/a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d/extra",
            "https://evil.example/r/a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
            "http://umma.app/r/a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
            "umma://pantry/a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
            "umma://recipe/",
            "umma://recipe/a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d/steps",
            "mailto:hi@umma.app",
        ] {
            XCTAssertNil(DeepLink.parse(URL(string: raw)!), raw)
        }
    }

    func testShareLinkBuildersRoundTripThroughParser() {
        XCTAssertEqual(ShareLinks.universal(recipeId: id).absoluteString, "https://umma.app/r/a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")
        XCTAssertEqual(ShareLinks.custom(recipeId: id).absoluteString, "umma://recipe/a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d")
        XCTAssertEqual(DeepLink.parse(ShareLinks.universal(recipeId: id)), .recipe(id))
        XCTAssertEqual(DeepLink.parse(ShareLinks.custom(recipeId: id)), .recipe(id))
    }

    @MainActor
    func testOpenURLSwitchesToExploreAndPushesRecipeFromAnyTab() async {
        let environment = AppEnvironment.preview(signedIn: true)
        await environment.auth.restore()   // preview token + no cached user → stays signed-in only if /me works; force below
        environment.forceSignedInForTests()
        environment.selectedTab = .pantry
        environment.exploreRoutes = [.recipe(id: UUID(), card: nil)]

        let link = environment.open(url: ShareLinks.custom(recipeId: id))
        XCTAssertEqual(link, .recipe(id))
        XCTAssertEqual(environment.selectedTab, .explore)
        XCTAssertEqual(environment.exploreRoutes, [.recipe(id: id, card: nil)], "replaces the stack so Back returns to Explore")
        XCTAssertNil(environment.pendingDeepLink)

        XCTAssertNil(environment.open(url: URL(string: "https://example.com")!))
        XCTAssertEqual(environment.selectedTab, .explore, "unknown URLs change nothing")
    }

    @MainActor
    func testLinkWhileSignedOutIsAppliedAfterSignIn() async {
        let environment = AppEnvironment.preview(signedIn: false)
        await environment.auth.restore()
        XCTAssertFalse(environment.auth.isSignedIn)
        environment.selectedTab = .saved

        environment.open(url: ShareLinks.universal(recipeId: id))
        XCTAssertEqual(environment.pendingDeepLink, .recipe(id))
        XCTAssertEqual(environment.selectedTab, .saved, "nothing navigates until there is a session")
        XCTAssertTrue(environment.exploreRoutes.isEmpty)

        environment.forceSignedInForTests()
        environment.applyPendingDeepLink()
        XCTAssertNil(environment.pendingDeepLink)
        XCTAssertEqual(environment.selectedTab, .explore)
        XCTAssertEqual(environment.exploreRoutes, [.recipe(id: id, card: nil)])
    }
}
