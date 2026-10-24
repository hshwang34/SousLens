import Foundation
import XCTest
@testable import SousLens

@MainActor
final class AssistantViewModelTests: XCTestCase {
    private func makeModel(service: FakeCookingService, session: TestBox<CookingSession?>,
                           audio: FakeAudioOutput = FakeAudioOutput()) -> AssistantViewModel {
        AssistantViewModel(sessionId: CookingFixtures.sessionUUID, service: service, audio: audio,
                           currentSession: { session.value })
    }

    func testAskSendsCurrentRevisionAndShowsBadgesAndSegments() async throws {
        let service = FakeCookingService()
        service.askHandler = { _, revision in try CookingFixtures.decode(AskResponse.self, CookingFixtures.askJSON(revision: revision)) }
        let session = TestBox<CookingSession?>(try CookingFixtures.session(stepIndex: 0, revision: 4))
        let model = makeModel(service: service, session: session)
        model.query = "  what does this step mean?  "
        await model.ask()
        XCTAssertEqual(service.calls.last, .ask("what does this step mean?", 4))
        XCTAssertEqual(model.query, "", "cleared after an answer")
        let turn = try XCTUnwrap(model.turns.first)
        XCTAssertEqual(model.badges(for: turn).map(\.text), ["Step 1", "Creator note"])
        XCTAssertEqual(turn.segments.map(\.heading), [nil, "My suggestion"])
        XCTAssertTrue(turn.segments[0].text.hasPrefix("The recipe says"))
        XCTAssertFalse(model.isStale(turn))
        XCTAssertEqual(turn.response.uncertainty.uncertaintyText, "Low uncertainty")
    }

    func testStaleBadgeFromServerOrWhenTheStepMoved() async throws {
        let service = FakeCookingService()
        let stale = TestBox(false)
        service.askHandler = { _, revision in try CookingFixtures.decode(AskResponse.self, CookingFixtures.askJSON(revision: revision, stale: stale.value)) }
        let session = TestBox<CookingSession?>(try CookingFixtures.session(stepIndex: 0, revision: 1))
        let model = makeModel(service: service, session: session)
        stale.value = true
        model.query = "q1"
        await model.ask()
        XCTAssertTrue(model.isStale(model.turns[0]), "server said stale")

        stale.value = false
        model.query = "q2"
        await model.ask()
        XCTAssertFalse(model.isStale(model.turns[1]))
        session.value = try CookingFixtures.session(stepIndex: 1, revision: 2)
        XCTAssertTrue(model.isStale(model.turns[1]), "Based on previous step once the step moved")
    }

    func testProposedActionRequiresATap() async throws {
        let service = FakeCookingService()
        service.askHandler = { _, revision in
            try CookingFixtures.decode(AskResponse.self, CookingFixtures.askJSON(revision: revision, proposed: #"{"command":"next","step_index":null,"timer":null}"#))
        }
        let session = TestBox<CookingSession?>(try CookingFixtures.session())
        let model = makeModel(service: service, session: session)
        let sent = TestBox<[ProposedAction]>([])
        model.onProposal = { action in sent.value.append(action); return true }
        model.query = "should I move on?"
        await model.ask()
        XCTAssertTrue(sent.value.isEmpty, "an answer never changes state on its own")
        XCTAssertTrue(service.commands.isEmpty)
        let turn = try XCTUnwrap(model.turns.first)
        XCTAssertEqual(model.proposalTitle(for: turn), "Go to next step?")
        await model.acceptProposal(turnId: turn.id)
        XCTAssertEqual(sent.value.map(\.command), [.next])
        XCTAssertNil(model.proposalTitle(for: model.turns[0]), "used once")
    }

    func testStaleProposalIsNotOffered() async throws {
        let service = FakeCookingService()
        service.askHandler = { _, revision in
            try CookingFixtures.decode(AskResponse.self, CookingFixtures.askJSON(revision: revision, proposed: #"{"command":"next"}"#))
        }
        let session = TestBox<CookingSession?>(try CookingFixtures.session())
        let model = makeModel(service: service, session: session)
        model.query = "q"
        await model.ask()
        session.value = try CookingFixtures.session(stepIndex: 1, revision: 2)
        XCTAssertNil(model.proposalTitle(for: model.turns[0]))
    }

    func testReadAloudOnlyOnTapAndRateLimitCopy() async throws {
        let service = FakeCookingService()
        service.askHandler = { _, revision in try CookingFixtures.decode(AskResponse.self, CookingFixtures.askJSON(revision: revision)) }
        let audio = FakeAudioOutput()
        let model = makeModel(service: service, session: TestBox(try CookingFixtures.session()), audio: audio)
        model.query = "q"
        await model.ask()
        XCTAssertTrue(audio.spoken.isEmpty, "answers are not spoken unasked")
        await model.readAloud(turnId: model.turns[0].id)
        XCTAssertEqual(audio.spoken, [model.turns[0].response.answerText])

        service.askHandler = { _, _ in throw try CookingFixtures.apiError(status: 429, code: "RATE_LIMITED") }
        model.query = "again"
        await model.ask()
        XCTAssertTrue(model.errorMessage?.contains("asked a lot") ?? false)
        XCTAssertEqual(model.query, "again", "the question is kept")
    }

    func testQueryIsCappedAt500AndSafetyNoticeIsKept() async throws {
        let service = FakeCookingService()
        service.askHandler = { _, revision in
            try CookingFixtures.decode(AskResponse.self, CookingFixtures.askJSON(revision: revision, safety: #""Use a thermometer: 165°F / 74°C.""#))
        }
        let model = makeModel(service: service, session: TestBox(try CookingFixtures.session()))
        model.query = String(repeating: "a", count: 600)
        XCTAssertEqual(model.query.count, 500)
        model.query = "is this chicken done?"
        await model.ask()
        XCTAssertEqual(model.turns.first?.response.safetyNotice, "Use a thermometer: 165°F / 74°C.")
    }
}

@MainActor
final class SubstitutionSheetViewModelTests: XCTestCase {
    func testSuggestionsCarryLabelsConfidenceRisksAndAllergyWarning() async throws {
        let service = FakeCookingService()
        service.suggestHandler = { _, _ in try CookingFixtures.decode(SubstitutionResult.self, CookingFixtures.substitutionsJSON) }
        let model = SubstitutionSheetViewModel(recipeVersionId: CookingFixtures.versionUUID, ingredientRef: "ing-8",
                                               ingredientName: "rice vinegar", service: service)
        await model.load()
        guard case .suggestions(let cards) = model.phase else { return XCTFail("expected suggestions, got \(model.phase)") }
        XCTAssertEqual(cards.map(\.label), ["Common swap", "AI suggested adaptation"])
        XCTAssertEqual(cards[0].confidence, "High confidence")
        XCTAssertEqual(cards[0].amount, "1 tbsp lemon juice + 1/2 tsp sugar")
        XCTAssertEqual(cards[0].flavor, "Slightly more citrusy.")
        XCTAssertEqual(cards[0].texture, "No change.")
        XCTAssertEqual(cards[0].risks, ["A little sharper; add the sugar."])
        XCTAssertNil(cards[0].allergyWarning)
        XCTAssertNotNil(cards[1].allergyWarning)
        XCTAssertEqual(cards[0].changesSteps, 1)
        XCTAssertFalse(cards.contains { $0.accessibilityLabel.localizedCaseInsensitiveContains("safe for you") })
    }

    func testCannotSubstituteShowsReasonAndSafetyNotice() async throws {
        let service = FakeCookingService()
        service.suggestHandler = { _, _ in try CookingFixtures.decode(SubstitutionResult.self, CookingFixtures.cannotSubstituteJSON) }
        let model = SubstitutionSheetViewModel(recipeVersionId: CookingFixtures.versionUUID, ingredientRef: "ing-1",
                                               ingredientName: "chicken", service: service)
        await model.load()
        XCTAssertEqual(model.phase, .noSwap(reason: "The chicken is the dish; there’s no swap we can stand behind."))
        XCTAssertEqual(model.safetyNotice, "This recipe contains sesame, one of your allergies.")
        XCTAssertNil(model.approve(suggestionId: UUID()), "nothing to approve")
    }

    func testEmptySuggestionsWithoutReasonStillSaysNoSwap() async throws {
        let service = FakeCookingService()
        service.suggestHandler = { _, _ in
            try CookingFixtures.decode(SubstitutionResult.self, """
            {"recipe_version_id":"\(CookingFixtures.versionId)","ingredient_ref":"ing-2","target_ingredient":"gochujang",
             "suggestions":[],"cannot_substitute":false,"reason":null,"safety_notice":null}
            """)
        }
        let model = SubstitutionSheetViewModel(recipeVersionId: CookingFixtures.versionUUID, ingredientRef: "ing-2",
                                               ingredientName: "gochujang", service: service)
        await model.load()
        XCTAssertEqual(model.phase, .noSwap(reason: SubstitutionSheetViewModel.fallbackNoSwapReason))
    }

    func testApproveReturnsSwapWithSuggestionId() async throws {
        let service = FakeCookingService()
        service.suggestHandler = { _, _ in try CookingFixtures.decode(SubstitutionResult.self, CookingFixtures.substitutionsJSON) }
        let model = SubstitutionSheetViewModel(recipeVersionId: CookingFixtures.versionUUID, ingredientRef: "ing-8",
                                               ingredientName: "rice vinegar", service: service)
        await model.load()
        let swap = try XCTUnwrap(model.approve(suggestionId: try XCTUnwrap(UUID(uuidString: CookingFixtures.suggestionAiId))))
        XCTAssertEqual(swap.label, "AI suggested adaptation")
        XCTAssertEqual(swap.input, .suggestion(try XCTUnwrap(UUID(uuidString: CookingFixtures.suggestionAiId)), ingredientRef: "ing-8"))
    }
}

/// Fit-screen swaps: approve / revert / variation / Start cooking.
@MainActor
final class PantryFitSwapTests: XCTestCase {
    private func makeModel(cooking: FakeCookingService?) async throws -> PantryFitViewModel {
        let pantry = FakePantryService()
        let fit = try PantryFixtures.decode(PantryFit.self, PantryFixtures.fitJSON)
        pantry.fitHandler = { _ in fit }
        let model = PantryFitViewModel(recipeVersionId: fit.recipeVersionId, recipeTitle: "T", service: pantry, cooking: cooking)
        await model.load()
        return model
    }

    private func ruleSwap(ref: String = "ing-4", name: String = "soy sauce") throws -> ApprovedSwap {
        let result = try CookingFixtures.decode(SubstitutionResult.self, CookingFixtures.substitutionsJSON)
        return ApprovedSwap(ingredientName: name, suggestion: result.suggestions[0], ingredientRef: ref)
    }

    func testMissingAndUncertainRowsOfferFindASwap() async throws {
        let model = try await makeModel(cooking: FakeCookingService())
        let missing = try XCTUnwrap(model.sections.first { $0.kind == .missing }?.rows.first)
        XCTAssertEqual(missing.actions, [.findSwap, .addToPantry])
        XCTAssertEqual(missing.actions.first?.title, "Find a swap")
        let uncertain = try XCTUnwrap(model.sections.first { $0.kind == .uncertain }?.rows.first)
        XCTAssertTrue(uncertain.actions.contains(.findSwap))
        let optional = try XCTUnwrap(model.sections.first { $0.kind == .optional }?.rows.first)
        XCTAssertFalse(optional.actions.contains(.findSwap), "optional lines can just be skipped")
        let available = try XCTUnwrap(model.sections.first { $0.kind == .available }?.rows.first)
        XCTAssertFalse(available.actions.contains(.findSwap))
    }

    func testApproveShowsSwapOnRowAndRevertRemovesIt() async throws {
        let model = try await makeModel(cooking: FakeCookingService())
        model.approve(try ruleSwap())
        let row = try XCTUnwrap(model.sections.first { $0.kind == .missing }?.rows.first)
        XCTAssertEqual(row.swap?.candidate, "lemon juice + a pinch of sugar")
        XCTAssertEqual(row.actions.first, .undoSwap)
        XCTAssertTrue(row.accessibilityLabel.contains("Common swap"))
        model.revertSwap(ingredientRef: "ing-4")
        XCTAssertNil(model.sections.first { $0.kind == .missing }?.rows.first?.swap)
        XCTAssertTrue(model.approvedSwapList.isEmpty)
    }

    func testStartCookingSendsApprovedSwapsOnly() async throws {
        let cooking = FakeCookingService()
        cooking.createHandler = { _, _ in try CookingFixtures.session(status: "created", revision: 0) }
        let model = try await makeModel(cooking: cooking)
        model.approve(try ruleSwap())
        model.approve(try ruleSwap(ref: "ing-3", name: "eggs"))
        model.revertSwap(ingredientRef: "ing-3")
        let session = await model.startCooking()
        XCTAssertEqual(session?.status, .created)
        guard case .create(let version, let adaptations) = try XCTUnwrap(cooking.calls.last) else { return XCTFail("no create") }
        XCTAssertEqual(version, model.recipeVersionId)
        XCTAssertEqual(adaptations, [.suggestion(try XCTUnwrap(UUID(uuidString: CookingFixtures.suggestionRuleId)), ingredientRef: "ing-4")])
    }

    func testStartFailureIsShownAndNothingOpens() async throws {
        let cooking = FakeCookingService()
        cooking.createHandler = { _, _ in throw APIError.unreachable(baseURL: "x", underlying: "offline") }
        let model = try await makeModel(cooking: cooking)
        let session = await model.startCooking()
        XCTAssertNil(session)
        XCTAssertNotNil(model.startError)
    }

    func testUseMyChangesFromLastTimeIsAnExplicitTap() async throws {
        let cooking = FakeCookingService()
        cooking.variationHandler = { _ in
            try CookingFixtures.decode(PrivateVariation.self, """
            {"adaptations":[{"ingredient_ref":"ing-4","original":"soy sauce","replacement":"tamari","ratio_or_amount":"2 tbsp","source":"rule","reason":"saved"}],
             "saved_at":"2026-10-22T11:00:00Z"}
            """)
        }
        let model = try await makeModel(cooking: cooking)
        await model.loadVariation()
        XCTAssertTrue(model.canUseVariation)
        XCTAssertTrue(model.approvedSwapList.isEmpty, "nothing applied until the tap")
        model.useVariation()
        XCTAssertEqual(model.approvedSwapList.map(\.candidate), ["tamari"])
        XCTAssertEqual(model.approvedSwapList.first?.ingredientName, "soy sauce")
        XCTAssertFalse(model.canUseVariation)
    }

    func testNoVariationHidesTheOffer() async throws {
        let model = try await makeModel(cooking: FakeCookingService())
        await model.loadVariation()
        XCTAssertFalse(model.canUseVariation)
    }
}

@MainActor
final class PreferencesViewModelTests: XCTestCase {
    func testAddCleansAndSavesThenServerNormalisationWins() async throws {
        let service = FakeCookingService()
        service.updatePreferencesHandler = { prefs in
            FoodPreferences(allergies: prefs.allergies.map { $0 == "Peanuts" ? "peanut" : $0 }, avoid: prefs.avoid)
        }
        let model = PreferencesViewModel(service: service)
        await model.load()
        model.allergyDraft = "  Peanuts\n"
        XCTAssertTrue(model.canAdd(.allergies))
        await model.add(.allergies)
        XCTAssertEqual(service.calls.last, .updatePreferences(.init(allergies: ["Peanuts"], avoid: [])))
        XCTAssertEqual(model.entries(.allergies), ["peanut"])
        XCTAssertEqual(model.allergyDraft, "")
        model.allergyDraft = "PEANUT"
        XCTAssertFalse(model.canAdd(.allergies), "case-insensitive duplicate")
    }

    func testRemoveAndRollbackOnFailure() async throws {
        let service = FakeCookingService()
        service.preferencesHandler = { FoodPreferences(allergies: ["shellfish"], avoid: ["cilantro"]) }
        let model = PreferencesViewModel(service: service)
        await model.load()
        service.updatePreferencesHandler = { _ in throw APIError.unreachable(baseURL: "x", underlying: "offline") }
        await model.remove(.avoid, at: 0)
        XCTAssertEqual(model.entries(.avoid), ["cilantro"], "rolled back")
        XCTAssertNotNil(model.saveError)
        service.updatePreferencesHandler = { $0 }
        await model.remove(.avoid, at: 0)
        XCTAssertEqual(model.entries(.avoid), [])
        XCTAssertEqual(model.entries(.allergies), ["shellfish"])
    }

    func testLimitsAndHonestCopy() {
        let model = PreferencesViewModel(service: FakeCookingService())
        model.avoidDraft = String(repeating: "x", count: 80)
        XCTAssertEqual(model.avoidDraft.count, PreferencesViewModel.maxLength)
        XCTAssertEqual(PreferencesViewModel.clean("a\u{0007}b \n c"), "a b c")
        let copy = [PreferencesViewModel.disclaimer] + PreferencesViewModel.Kind.allCases.map(\.explanation)
        for text in copy {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("safe for you"), text)
        }
        XCTAssertTrue(PreferencesViewModel.Kind.allergies.explanation.contains("never suggested"))
        XCTAssertTrue(PreferencesViewModel.Kind.avoid.explanation.contains("preference"))
    }
}

final class CookingFormattingTests: XCTestCase {
    func testDurationsAndCountdown() {
        XCTAssertEqual(CookingFormatting.shortDuration(600), "10-min")
        XCTAssertEqual(CookingFormatting.shortDuration(90), "1-min 30-sec")
        XCTAssertEqual(CookingFormatting.shortDuration(45), "45-sec")
        XCTAssertEqual(CookingFormatting.shortDuration(3600), "1-hr")
        XCTAssertEqual(CookingFormatting.countdown(3723), "1:02:03")
        XCTAssertEqual(CookingFormatting.countdown(-5), "0:00")
    }
}
