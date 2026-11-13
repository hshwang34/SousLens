import Foundation
import XCTest
@testable import Umma

/// Brief 013 Part C: the calm cooking screen. Safety and allergy notices stay inline under the
/// step (one compact row), swap tips / the creator note / look-for cues fold into the notes chip,
/// and the Adapted / Show original switch moves to the ⋯ menu behind a small header indicator.
@MainActor
final class CalmCookingTests: XCTestCase {
    private var service: FakeCookingService!
    private var oracle: FakeOracle!
    private var audio: FakeAudioOutput!
    private let clock = ISO8601Flexible.parse("2026-10-23T10:00:00Z")!

    override func setUp() async throws {
        service = FakeCookingService()
        audio = FakeAudioOutput()
        let fixed = clock
        oracle = FakeOracle(now: { fixed })
        let oracle = oracle!
        service.sessionHandler = { _ in try oracle.current() }
        service.commandHandler = { command, key in try oracle.apply(command, key: key) }
    }

    private func makeModel(cautions: [String: SwapCaution] = [:]) -> CookingViewModel {
        CookingViewModel(sessionId: CookingFixtures.sessionUUID, service: service, audio: audio,
                         swapCautions: cautions, now: { [unowned self] in self.clock })
    }

    // MARK: The screenshot case (mise-20): lemon juice for rice vinegar

    func testLemonJuiceSwapShowsOneSafetyLineAndTwoNotes() {
        let notices = CookingNotices.make(
            stepWarnings: [],
            cautions: [SwapCaution(risks: ["Add a pinch of sugar to soften the edge.",
                                           "Do not use in pickling, canning or any preserved recipe: acidity differs and lemon juice is not standardised.",
                                           "Not an exact match."])],
            creatorNote: nil, successCues: [])
        XCTAssertEqual(notices.inline.map(\.text),
                       ["Do not use in pickling, canning or any preserved recipe: acidity differs and lemon juice is not standardised."],
                       "the food-safety line stays inline, word for word")
        XCTAssertEqual(notices.inline.map(\.kind), [.safety])
        XCTAssertEqual(notices.notes.map(\.text), ["Add a pinch of sugar to soften the edge.", "Not an exact match."])
        XCTAssertEqual(notices.notesChipText, "2 notes")
        XCTAssertNil(notices.moreText, "a single notice needs no expander")
    }

    func testOrderingAllergyFirstThenStepWarningsThenSwapSafety() {
        let notices = CookingNotices.make(
            stepWarnings: ["Raw poultry: wash your hands."],
            cautions: [SwapCaution(allergyWarning: "May contain sulfites.",
                                   risks: ["Cooks faster and dries out. Still cook to 165°F (74°C) on an instant-read thermometer; time alone does not show it is done.",
                                           "Contains soy."],
                                   safetyNotice: "You listed sesame.")],
            creatorNote: "I marinate it all day.", successCues: ["Glossy marinade"])
        XCTAssertEqual(notices.inline.map(\.text), [
            "Check the label: May contain sulfites.",
            "Contains soy.",
            "Raw poultry: wash your hands.",
            "You listed sesame.",
            "Cooks faster and dries out. Still cook to 165°F (74°C) on an instant-read thermometer; time alone does not show it is done.",
        ])
        XCTAssertEqual(notices.leadNotice?.kind, .allergy)
        XCTAssertTrue(notices.leadsWithAllergy)
        XCTAssertEqual(notices.collapsedCount, 4)
        XCTAssertEqual(notices.moreText, "+4 more")
        XCTAssertEqual(notices.notes.map(\.kind), [.creatorNote, .lookFor])
        XCTAssertEqual(notices.notesChipText, "2 notes")
        // VoiceOver hears every notice even while the row is collapsed.
        let spoken = try? XCTUnwrap(notices.accessibilityLabel)
        for notice in notices.inline { XCTAssertTrue(spoken?.contains(notice.text) == true, notice.text) }
    }

    func testEveryVettedRiskIsSortedSafely() throws {
        // Every risk line in the vetted swap rules: allergy and food-safety lines stay inline.
        let mustBeInline = [
            "Contains alcohol.", "Contains coconut.", "Contains honey: not for babies under 1 year old.",
            "Contains milk (butter).", "Contains milk.", "Contains sulfites.", "Contains soy.",
            "Contains peanut. Refined peanut oil is lower-risk, but cold-pressed is not. Do not use with any peanut allergy.",
            "Contains sesame, same allergen as the original.",
            "Cooked rice must not sit at room temperature more than 1 hour. Use it straight away, or chill within 1 hour and reheat until piping hot.",
            "Cooks faster and dries out. Still cook to 165°F (74°C) on an instant-read thermometer; time alone does not show it is done.",
            "Do not use in pickling, canning or any preserved recipe: acidity differs and lemon juice is not standardised.",
            "Labelled soy-free; check the label.", "Miso contains soy and some contains barley; check the label.",
            "Miso contains soy; check the label.",
            "Seasoning-level only; do not use in baking or preserving, where sugar affects structure and safety.",
            "Some gluten-free pasta contains corn, soy or egg; check the label.",
            "Still soy. Most tamari is wheat-free but not all; check the label.",
        ]
        let mayFold = [
            "Add a pinch of sugar to soften the edge.", "Burns faster in the pan.",
            "Burns quickly in hot oil; add it with liquid, not to a dry hot pan.",
            "Canned tomatoes are often salted; reduce added salt.", "Drain it; sauerkraut is milder and saltier.",
            "Fresh rice clumps; break it up well and don't crowd the pan.", "Fry in an extra 1 tsp oil.",
            "Not a true equivalent: gochujang is a fermented chili-rice paste and nothing replicates it exactly.",
            "Not an exact match.", "Start tasting 2 minutes early.",
            "Taste and add salt; it is far less salty than soy sauce.", "The dish will taste plainer.",
        ]
        for line in mustBeInline { XCTAssertTrue(CookingNotices.isSafetyLine(line), line) }
        for line in mayFold { XCTAssertFalse(CookingNotices.isSafetyLine(line), line) }
        XCTAssertTrue(CookingNotices.mentionsAllergen("Contains soy."))
        XCTAssertFalse(CookingNotices.mentionsAllergen("Contains alcohol."), "alcohol is safety, not an allergen")
    }

    func testDuplicatesCollapseAndANoticeOutranksANote() {
        let notices = CookingNotices.make(stepWarnings: ["Keep raw chicken apart.", "Keep raw chicken apart."],
                                          cautions: [SwapCaution(risks: ["Not an exact match.", "Not an exact match."])],
                                          creatorNote: "  ", successCues: ["Keep raw chicken apart."])
        XCTAssertEqual(notices.inline.map(\.text), ["Keep raw chicken apart."])
        XCTAssertEqual(notices.notes.map(\.text), ["Not an exact match."])
        XCTAssertEqual(notices.notesChipText, "1 note")
    }

    func testNoNoticesMeansNoRowAndNoChip() {
        let notices = CookingNotices.make(stepWarnings: [], cautions: [], creatorNote: nil, successCues: [])
        XCTAssertEqual(notices, .empty)
        XCTAssertNil(notices.leadNotice)
        XCTAssertNil(notices.notesChipText)
        XCTAssertNil(notices.accessibilityLabel)
    }

    // MARK: Through the view model

    func testAdaptedStepFoldsRisksAndKeepsSafetyInline() async throws {
        let model = makeModel(cautions: ["ing-8": SwapCaution(
            allergyWarning: "contains sulfites", risks: ["Not an exact match."], safetyNotice: "Recipe contains sesame.")])
        await model.load()
        XCTAssertEqual(model.notices.inline.map(\.text), ["Check the label: contains sulfites", "Recipe contains sesame."])
        XCTAssertEqual(model.notices.notes.map(\.text), ["Not an exact match.", "Marinade is glossy and uniform with no streaks of honey or paste"])
        XCTAssertEqual(model.notices.notesChipText, "2 notes")
        XCTAssertEqual(model.adaptedIndicator?.text, "Adapted")
        XCTAssertEqual(model.adaptedIndicator?.accessibilityLabel, "Adapted · Common swap")
        XCTAssertEqual(model.adaptedIndicator?.menuToggleTitle, "Show original step")
    }

    func testShowOriginalFlipsTheIndicatorAndResetsOnTheNextStep() async throws {
        let model = makeModel()
        await model.load()
        model.showOriginal = true
        XCTAssertEqual(model.adaptedIndicator?.text, "Original")
        XCTAssertEqual(model.adaptedIndicator?.menuToggleTitle, "Show adapted step")
        XCTAssertTrue(model.instructionText?.contains("rice vinegar") == true, "the step shows the recipe as written")
        await model.next()
        XCTAssertNil(model.adaptedIndicator, "step 2 is not adapted")
        XCTAssertFalse(model.showOriginal)
    }

    func testStepWarningsStayInlineAndCreatorNoteFolds() async throws {
        let model = makeModel()
        await model.load()
        await model.next()   // step 2: raw-poultry warning, a cue and a creator note
        XCTAssertEqual(model.notices.inline.count, 1)
        XCTAssertTrue(model.notices.inline[0].text.hasPrefix("Raw poultry:"))
        XCTAssertEqual(model.notices.notes.map(\.kind), [.creatorNote, .lookFor])
        XCTAssertNil(model.adaptedIndicator)
    }

    func testAIAdaptationIndicatorNamesTheSource() {
        XCTAssertEqual(AdaptedIndicator.make(sourceLabel: "AI suggested adaptation", showingOriginal: false)?.accessibilityLabel,
                       "Adapted · AI suggested adaptation")
        XCTAssertNil(AdaptedIndicator.make(sourceLabel: nil, showingOriginal: true))
    }
}
