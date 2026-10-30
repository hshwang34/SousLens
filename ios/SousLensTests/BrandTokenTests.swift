import UIKit
import XCTest
@testable import SousLens

/// Brief 006: the Mise token table is AA in every appearance, and the asset catalog matches it.
final class BrandTokenTests: XCTestCase {
    private let traits: [MisePalette.Appearance: UITraitCollection] = [
        .light: UITraitCollection(userInterfaceStyle: .light),
        .dark: UITraitCollection(userInterfaceStyle: .dark),
        .lightHighContrast: UITraitCollection(userInterfaceStyle: .light).modifyingTraits { $0.accessibilityContrast = .high },
        .darkHighContrast: UITraitCollection(userInterfaceStyle: .dark).modifyingTraits { $0.accessibilityContrast = .high },
    ]

    func testEveryTextPairIsAAInEveryAppearance() throws {
        XCTAssertFalse(MisePalette.textPairs.isEmpty)
        for (foreground, background) in MisePalette.textPairs {
            let fg = try XCTUnwrap(MisePalette.token(foreground), "unknown token \(foreground)")
            let bg = try XCTUnwrap(MisePalette.token(background), "unknown token \(background)")
            for appearance in MisePalette.Appearance.allCases {
                let ratio = MisePalette.contrastRatio(MisePalette.hex(fg, appearance), MisePalette.hex(bg, appearance))
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(foreground) on \(background), \(appearance): \(String(format: "%.2f", ratio)):1")
            }
        }
    }

    func testIncreaseContrastIsAtLeastAAA() throws {
        for (foreground, background) in MisePalette.textPairs {
            let fg = try XCTUnwrap(MisePalette.token(foreground))
            let bg = try XCTUnwrap(MisePalette.token(background))
            for appearance in [MisePalette.Appearance.lightHighContrast, .darkHighContrast] {
                let ratio = MisePalette.contrastRatio(MisePalette.hex(fg, appearance), MisePalette.hex(bg, appearance))
                XCTAssertGreaterThanOrEqual(ratio, 7, "\(foreground) on \(background), \(appearance)")
            }
        }
    }

    func testContrastFormulaMatchesWCAGReferences() {
        XCTAssertEqual(MisePalette.contrastRatio(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(MisePalette.contrastRatio(0xFFFFFF, 0xFFFFFF), 1, accuracy: 0.001)
        // Brief 006 engineering note: white on herb green is 6.4:1.
        XCTAssertEqual(MisePalette.contrastRatio(0xFFFFFF, 0x2F6B3A), 6.4, accuracy: 0.05)
    }

    func testAssetCatalogMatchesTokenTable() throws {
        for token in MisePalette.tokens {
            for appearance in MisePalette.Appearance.allCases {
                let trait = try XCTUnwrap(traits[appearance])
                let color = try XCTUnwrap(UIColor(named: token.name, in: .main, compatibleWith: trait),
                                          "asset \(token.name) missing")
                XCTAssertEqual(Self.hex(color.resolvedColor(with: trait)), MisePalette.hex(token, appearance),
                               "\(token.name) \(appearance) drifted from MisePalette")
            }
        }
    }

    private static func hex(_ color: UIColor) -> UInt32 {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}

/// Brief 006: Explore's fit chip and filter chips.
final class ExploreFitTests: XCTestCase {
    func testChipCountsRequiredLinesOnly() throws {
        let fit = try PantryFixtures.decode(PantryFit.self, PantryFixtures.fitJSON)
        let summary = CardFitSummary(fit: fit)
        // 4 required lines (the optional one is ignored); 2 available.
        XCTAssertEqual(summary.requiredCount, 4)
        XCTAssertEqual(summary.availableCount, 2)
        XCTAssertFalse(summary.hasEverything)
        XCTAssertEqual(summary.chipText, "You have 2 of 4")
    }

    func testEverythingOnlyWhenNothingRequiredIsMissingOrUncertain() throws {
        let fit = try PantryFixtures.decode(PantryFit.self, PantryFixtures.canMakeFitJSON)
        let summary = CardFitSummary(fit: fit)
        XCTAssertTrue(summary.hasEverything)
        XCTAssertEqual(summary.chipText, "You have all 1")
    }

    func testNoChipWhenNothingMatches() throws {
        let json = PantryFixtures.fitJSON.replacingOccurrences(of: #""status":"available""#, with: #""status":"missing""#)
        let summary = CardFitSummary(fit: try PantryFixtures.decode(PantryFit.self, json))
        XCTAssertEqual(summary.availableCount, 0)
        XCTAssertNil(summary.chipText, "an empty pantry must not paint 0 of N on every card")
    }

    func testFilterChipsAndFiltering() throws {
        let korean = card(title: "Kimchi Fried Rice", tags: ["korean", "weeknight"])
        let noodles = card(title: "Gochujang Noodles", tags: ["korean"])
        let toast = card(title: "Garlic Toast", tags: ["snack"])
        let cards = [korean, noodles, toast]

        let chips = ExploreFilter.chips(for: cards)
        XCTAssertEqual(chips.prefix(3), [.all, .canMakeNow, .tag("korean")], "most common tag first")
        XCTAssertEqual(ExploreFilter.canMakeNow.title, "Can make now")

        XCTAssertEqual(ExploreFilter.all.apply(to: cards, fits: [:]), cards)
        XCTAssertEqual(ExploreFilter.tag("korean").apply(to: cards, fits: [:]), [korean, noodles])

        let everything = CardFitSummary(fit: try PantryFixtures.decode(PantryFit.self, PantryFixtures.canMakeFitJSON))
        let partial = CardFitSummary(fit: try PantryFixtures.decode(PantryFit.self, PantryFixtures.fitJSON))
        let fits = [korean.recipeVersionId: everything, noodles.recipeVersionId: partial]
        XCTAssertEqual(ExploreFilter.canMakeNow.apply(to: cards, fits: fits), [korean],
                       "a partial or unknown fit is never 'can make now'")
    }

    func testFitLoaderSkipsFailuresAndRefetchesOnlyOnChange() async throws {
        let fit = try PantryFixtures.decode(PantryFit.self, PantryFixtures.fitJSON)
        let good = UUID()
        let bad = UUID()
        let calls = CallCounter()
        let loader = await ExploreFitLoader { id in
            calls.increment()
            if id == bad { throw APIError.cancelled }
            return fit
        }
        await loader.load(versionIds: [good, bad], pantryRevision: 0)
        let fits = await loader.fits
        XCTAssertEqual(Set(fits.keys), [good])
        XCTAssertEqual(calls.value, 2)

        await loader.load(versionIds: [good, bad], pantryRevision: 0)
        XCTAssertEqual(calls.value, 2, "same cards, same pantry: no refetch")
        await loader.load(versionIds: [good, bad], pantryRevision: 1)
        XCTAssertEqual(calls.value, 4, "pantry changed: refetch")
    }

    func testCancelledLoadRetriesOnTheNextCall() async throws {
        let fit = try PantryFixtures.decode(PantryFit.self, PantryFixtures.fitJSON)
        let id = UUID()
        let calls = CallCounter()
        let loader = await ExploreFitLoader { _ in
            // The first request hangs until cancelled; later ones answer at once.
            if calls.incrementAndGet() == 1 { try await Task.sleep(for: .seconds(30)) }
            return fit
        }
        // Cancelled mid-load (the user opened a recipe): nothing counts as loaded.
        let task = Task { await loader.load(versionIds: [id], pantryRevision: 0) }
        while calls.value == 0 { await Task.yield() }
        task.cancel()
        await task.value
        let afterCancel = await loader.fits
        XCTAssertTrue(afterCancel.isEmpty)

        // Coming back with the same cards and pantry loads again instead of keeping empty chips.
        await loader.load(versionIds: [id], pantryRevision: 0)
        XCTAssertEqual(calls.value, 2, "same key after a cancel must refetch")
        let loaded = await loader.fits
        XCTAssertEqual(Set(loaded.keys), [id])
    }

    func testAllFailedLoadRetries() async throws {
        let calls = CallCounter()
        let loader = await ExploreFitLoader { _ in
            calls.increment()
            throw APIError.cancelled
        }
        let id = UUID()
        await loader.load(versionIds: [id], pantryRevision: 0)
        await loader.load(versionIds: [id], pantryRevision: 0)
        XCTAssertEqual(calls.value, 2, "a load where every fit failed is retried")
    }

    func testFitLoaderCapsConcurrency() async throws {
        let fit = try PantryFixtures.decode(PantryFit.self, PantryFixtures.fitJSON)
        let gauge = ConcurrencyGauge()
        let loader = await ExploreFitLoader { _ in
            gauge.enter()
            try await Task.sleep(for: .milliseconds(20))
            gauge.leave()
            return fit
        }
        let ids = (0..<20).map { _ in UUID() }
        await loader.load(versionIds: ids, pantryRevision: 0)
        let count = await loader.fits.count
        XCTAssertEqual(count, 20)
        XCTAssertLessThanOrEqual(gauge.peak, ExploreFitLoader.maxConcurrent)
    }

    private func card(title: String, tags: [String]) -> RecipeCard {
        RecipeCard(recipeId: UUID(), slug: title.lowercased(), title: title, summary: nil, tags: tags,
                   creator: Creator(id: UUID(), displayName: "Test Cook"), servings: 2, prepMinutes: 5,
                   cookMinutes: 10, coverImageUrl: nil, publishedAt: Date(timeIntervalSince1970: 0),
                   recipeVersionId: UUID(), versionNumber: 1)
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
    func incrementAndGet() -> Int { lock.withLock { count += 1; return count } }
}

private final class ConcurrencyGauge: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var maximum = 0
    var peak: Int { lock.withLock { maximum } }
    func enter() { lock.withLock { current += 1; maximum = max(maximum, current) } }
    func leave() { lock.withLock { current -= 1 } }
}
