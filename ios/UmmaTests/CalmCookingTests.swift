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
        // Collapsed, the row shows the first allergy line AND the first food-safety line: a
        // food-safety line is never hidden only because allergy lines sort first.
        XCTAssertEqual(notices.leadNotices.map(\.text), ["Check the label: May contain sulfites.", "Raw poultry: wash your hands."])
        XCTAssertEqual(notices.collapsedCount, 3)
        XCTAssertEqual(notices.moreText, "+3 more")
        XCTAssertEqual(notices.notes.map(\.kind), [.creatorNote, .lookFor])
        XCTAssertEqual(notices.notesChipText, "2 notes")
        // VoiceOver hears every notice even while the row is collapsed.
        let spoken = try? XCTUnwrap(notices.accessibilityLabel)
        for notice in notices.inline {
            XCTAssertTrue(spoken?.contains("Safety warning: \(notice.text)") == true, notice.text)
        }
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
        // Only clearly culinary tips with no safety signal fold.
        let mayFold = [
            "Add a pinch of sugar to soften the edge.", "Burns faster in the pan.",
            "Burns quickly in hot oil; add it with liquid, not to a dry hot pan.",
            "Not an exact match.", "Start tasting 2 minutes early.", "The dish will taste plainer.",
            "Not a true equivalent; the dish will taste noticeably different.",
            "Where garlic is the star (garlic pasta) the dish will taste very different.",
        ]
        // Not on the tip allow-list (or a tip that names an allergen): inline, the safe default.
        let unknownStaysInline = [
            "Canned tomatoes are often salted; reduce added salt.", "Drain it; sauerkraut is milder and saltier.",
            "Fresh rice clumps; break it up well and don't crowd the pan.", "Fry in an extra 1 tsp oil.",
            "Not a true equivalent: gochujang is a fermented chili-rice paste and nothing replicates it exactly.",
            "Taste and add salt; it is far less salty than soy sauce.", "Much hotter; start with half.",
        ]
        for line in mustBeInline + unknownStaysInline { XCTAssertTrue(CookingNotices.isSafetyLine(line), line) }
        for line in mayFold { XCTAssertFalse(CookingNotices.isSafetyLine(line), line) }
        XCTAssertTrue(CookingNotices.mentionsAllergen("Contains soy."))
        XCTAssertFalse(CookingNotices.mentionsAllergen("Contains alcohol."), "alcohol is safety, not an allergen")
    }

    func testReviewerSafetyPhrasesStayInline() {
        let phrases = [
            "Contains anchovies.", "Raw egg in this swap.", "Risk of cross-contamination.",
            "Reheat until steaming hot.", "Refrigerate within 2 hours.", "Cook to 165 F", "74 C",
            "Don\u{2019}t use for canning.", "Don't use for canning.", "Avoid for infants.",
            "Not suitable for pregnant people.",
        ]
        for phrase in phrases {
            XCTAssertTrue(CookingNotices.hasSafetySignal(phrase), phrase)
            XCTAssertTrue(CookingNotices.isSafetyLine(phrase), phrase)
            let notices = CookingNotices.make(stepWarnings: [], cautions: [SwapCaution(risks: [phrase])],
                                              creatorNote: nil, successCues: [])
            XCTAssertEqual(notices.inline.map(\.text), [phrase], phrase)
            XCTAssertTrue(notices.notes.isEmpty, phrase)
        }
    }

    func testUnknownPhraseStaysInline() {
        let notices = CookingNotices.make(stepWarnings: [], cautions: [SwapCaution(risks: ["Behaves differently under pressure."])],
                                          creatorNote: nil, successCues: [])
        XCTAssertEqual(notices.inline.map(\.text), ["Behaves differently under pressure."])
        XCTAssertNil(notices.notesChipText)
    }

    func testATipThatAlsoCarriesASafetySignalStaysInline() {
        for line in ["A little sweeter; contains egg.", "Slightly saltier, and keep raw chicken apart.",
                     "Tastes sharper; never use for canning.", "Colour goes pink at 63 C."] {
            XCTAssertFalse(CookingNotices.isFoldableTip(line), line)
        }
        XCTAssertTrue(CookingNotices.isFoldableTip("A little sharper."))
        XCTAssertTrue(CookingNotices.isFoldableTip("Slightly sweeter."))
    }

    func testTwoAllergyLinesDoNotHideTheFoodSafetyLine() {
        let notices = CookingNotices.make(
            stepWarnings: ["Cook chicken to 74 C."],
            cautions: [SwapCaution(allergyWarning: "contains sesame", risks: ["Contains soy."])],
            creatorNote: nil, successCues: [])
        XCTAssertEqual(notices.inline.map(\.kind), [.allergy, .allergy, .safety])
        XCTAssertEqual(notices.leadNotices.map(\.text), ["Check the label: contains sesame", "Cook chicken to 74 C."])
        XCTAssertEqual(notices.moreText, "+1 more")
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
