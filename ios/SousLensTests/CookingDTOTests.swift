import Foundation
import XCTest
@testable import SousLens

/// Brief 005 DTO decoding (every contract shape, incl. error details).
final class CookingDTOTests: XCTestCase {
    func testSessionDecodesEveryContractField() throws {
        let session = try CookingFixtures.decode(CookingSession.self, CookingFixtures.sessionJSON(
            stepIndex: 2, revision: 3,
            timers: [.init(targetAt: "2026-10-23T10:15:00Z")],
            outcome: #"{"result":"didnt_work","saved_changes":true}"#))
        XCTAssertEqual(session.id, CookingFixtures.sessionUUID)
        XCTAssertEqual(session.recipeVersionId, CookingFixtures.versionUUID)
        XCTAssertEqual(session.status, .active)
        XCTAssertEqual(session.stepIndex, 2)
        XCTAssertEqual(session.stepsCount, 7)
        XCTAssertEqual(session.revision, 3)
        XCTAssertEqual(session.recipe.title, "Gochujang Chicken Thighs")
        XCTAssertEqual(session.adaptations.first?.source, .rule)
        XCTAssertEqual(session.adaptations.first?.displayLabel, "Common swap")
        XCTAssertEqual(session.adaptations.first?.ratioOrAmount, "1 tbsp lemon juice + 1/2 tsp sugar")
        XCTAssertEqual(session.steps.count, 7)
        XCTAssertTrue(session.steps[0].adapted)
        XCTAssertEqual(session.steps[0].adaptationIds, [UUID(uuidString: CookingFixtures.adaptationId)])
        XCTAssertNotEqual(session.steps[0].instruction, session.steps[0].originalInstruction)
        XCTAssertEqual(session.steps[2].suggestedTimer, SuggestedTimer(label: "Simmer", durationSeconds: 600))
        XCTAssertEqual(session.timers.first?.targetAt, ISO8601Flexible.parse("2026-10-23T10:15:00Z"))
        XCTAssertEqual(session.timers.first?.status, .running)
        XCTAssertEqual(session.timers.first?.stepIndex, 2)
        XCTAssertEqual(session.outcome, SessionOutcome(result: .didntWork, savedChanges: true))
        XCTAssertEqual(session.pantrySnapshot.first?.normalizedName, "gochujang")
        XCTAssertNotNil(session.startedAt)
        XCTAssertNil(session.endedAt)
        XCTAssertEqual(session.currentStep?.stepId, "step-3")
        XCTAssertEqual(session.currentRecipeStep?.id, "step-3")
    }

    func testAiAdaptationIsNeverLabelledAsCommonSwap() throws {
        let session = try CookingFixtures.session(source: "ai")
        XCTAssertEqual(session.adaptations.first?.displayLabel, "AI suggested adaptation")
        let unknown = try JSONCoding.makeDecoder().decode([SwapSource].self, from: Data(#"["crowd"]"#.utf8))
        XCTAssertEqual(unknown, [.ai], "an unknown source is labelled conservatively as AI")
    }

    func testUnknownStatusesDecodeConservatively() throws {
        let status = try JSONCoding.makeDecoder().decode([SessionStatus].self, from: Data(#"["archived"]"#.utf8))
        XCTAssertEqual(status, [.abandoned], "an unreadable status is treated as ended")
        let timer = try JSONCoding.makeDecoder().decode([TimerStatus].self, from: Data(#"["snoozed"]"#.utf8))
        XCTAssertEqual(timer, [.cancelled])
    }

    func testSessionRoundTripsThroughTheCacheEncoding() throws {
        let session = try CookingFixtures.session(stepIndex: 3, revision: 5, timers: [.init(targetAt: "2026-10-23T10:15:00Z")])
        let data = try JSONCoding.makeEncoder().encode(session)
        let decoded = try JSONCoding.makeDecoder().decode(CookingSession.self, from: data)
        // The cache encoder writes whole-second dates; everything the screen renders survives.
        XCTAssertEqual(decoded.id, session.id)
        XCTAssertEqual(decoded.stepIndex, session.stepIndex)
        XCTAssertEqual(decoded.revision, session.revision)
        XCTAssertEqual(decoded.steps, session.steps)
        XCTAssertEqual(decoded.adaptations, session.adaptations)
        XCTAssertEqual(decoded.timers, session.timers)
        XCTAssertEqual(decoded.recipe.steps, session.recipe.steps)
    }

    func testSummaryAndActiveListDecode() throws {
        let page = try CookingFixtures.decode(ItemsResponse<SessionSummary>.self, #"{"items":["# + CookingFixtures.summaryJSON() + "]}")
        XCTAssertEqual(page.items.first?.title, "Gochujang Chicken Thighs")
        XCTAssertEqual(page.items.first?.stepIndex, 2)
        XCTAssertEqual(page.items.first?.status, .active)
    }

    func testSubstitutionResponseDecodes() throws {
        let result = try CookingFixtures.decode(SubstitutionResult.self, CookingFixtures.substitutionsJSON)
        XCTAssertEqual(result.targetIngredient, "rice vinegar")
        XCTAssertFalse(result.cannotSubstitute)
        XCTAssertEqual(result.suggestions.count, 2)
        let rule = result.suggestions[0]
        XCTAssertEqual(rule.source, .rule)
        XCTAssertEqual(rule.kind, "close_equivalent")
        XCTAssertEqual(rule.confidence, .high)
        XCTAssertEqual(rule.adjustedSteps, [AdjustedStep(stepId: "step-1", instruction: "…lemon juice…")])
        XCTAssertEqual(rule.risks, ["A little sharper; add the sugar."])
        XCTAssertNil(rule.allergyWarning)
        XCTAssertTrue(rule.requiresUserConfirmation)
        XCTAssertNotNil(result.suggestions[1].allergyWarning)
    }

    func testCannotSubstituteDecodes() throws {
        let result = try CookingFixtures.decode(SubstitutionResult.self, CookingFixtures.cannotSubstituteJSON)
        XCTAssertTrue(result.cannotSubstitute)
        XCTAssertTrue(result.suggestions.isEmpty)
        XCTAssertNotNil(result.reason)
        XCTAssertNotNil(result.safetyNotice)
    }

    func testAskResponseDecodesIncludingProposal() throws {
        let response = try CookingFixtures.decode(AskResponse.self, CookingFixtures.askJSON(
            revision: 4, stale: true, proposed: #"{"command":"next","step_index":null,"timer":null}"#, safety: #""Use a thermometer.""#))
        XCTAssertEqual(response.groundedSessionRevision, 4)
        XCTAssertTrue(response.stale)
        XCTAssertEqual(response.uncertainty, .low)
        XCTAssertEqual(response.grounding.first, GroundingRef(type: "recipe_step", id: "step-1"))
        XCTAssertEqual(response.proposedAction?.command, .next)
        XCTAssertTrue(response.requiresConfirmation)
        XCTAssertEqual(response.safetyNotice, "Use a thermometer.")
    }

    func testUnknownProposedCommandIsDropped() throws {
        let response = try CookingFixtures.decode(AskResponse.self, CookingFixtures.askJSON(proposed: #"{"command":"delete_everything"}"#))
        XCTAssertNil(response.proposedAction, "a proposal the app can't read is never guessed at")
    }

    func testPreferencesAndVariationDecode() throws {
        let prefs = try CookingFixtures.decode(FoodPreferences.self, #"{"allergies":["peanut"],"avoid":["cilantro"],"updated_at":null}"#)
        XCTAssertEqual(prefs.allergies, ["peanut"])
        XCTAssertEqual(prefs.avoid, ["cilantro"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONCoding.makeEncoder().encode(prefs.update)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["allergies", "avoid"])
        let variation = try CookingFixtures.decode(PrivateVariation.self, """
        {"adaptations":[{"id":"\(CookingFixtures.adaptationId)","ingredient_ref":"ing-8","original":"rice vinegar",
          "replacement":"lemon juice","ratio_or_amount":"1 tbsp","source":"rule","label":"Common swap","reason":"r","approved_at":"2026-10-23T10:00:00Z"}],
         "saved_at":"2026-10-23T11:00:00Z"}
        """)
        XCTAssertEqual(variation.adaptations.first?.input,
                       AdaptationInput(ingredientRef: "ing-8", replacement: "lemon juice", ratioOrAmount: "1 tbsp", source: .rule, reason: "r"))
    }

    // MARK: Error details

    func testStateConflictCarriesLatestSession() throws {
        let latest = try CookingFixtures.sessionJSON(stepIndex: 4, revision: 9)
        let error = try CookingFixtures.conflict(latest: latest)
        XCTAssertTrue(error.isStateConflict)
        XCTAssertEqual(error.latestSession?.stepIndex, 4)
        XCTAssertEqual(error.latestSession?.revision, 9)
    }

    func testInvalidTransitionCarriesLatestSession() throws {
        let error = try CookingFixtures.conflict(latest: CookingFixtures.sessionJSON(stepIndex: 6, revision: 7), code: "INVALID_TRANSITION")
        XCTAssertTrue(error.isInvalidTransition)
        XCTAssertFalse(error.isStateConflict)
        XCTAssertEqual(error.latestSession?.stepIndex, 6)
    }

    func testConfirmationRequiredAndRateLimit() throws {
        let unconfirmed = try CookingFixtures.apiError(status: 422, code: "CONFIRMATION_REQUIRED")
        XCTAssertTrue(unconfirmed.isConfirmationRequired)
        XCTAssertNil(unconfirmed.latestSession)
        let limited = try CookingFixtures.apiError(status: 429, code: "RATE_LIMITED")
        XCTAssertTrue(limited.isRateLimited)
    }
}

/// Request shapes through the `URLProtocol` stub.
final class CookingAPIClientTests: XCTestCase {
    private func makeClient() -> APIClient {
        APIClient(session: StubURLProtocol.makeSession(),
                  baseURLProvider: StaticBaseURLProvider(baseURL: URL(string: "http://stub.test:8000")),
                  tokenProvider: InMemoryTokenStore(token: "tok"))
    }

    private func route(_ table: [String: (Int, String)]) {
        StubURLProtocol.install { request in
            let key = "\(request.httpMethod ?? "") \(request.url?.path ?? "")"
            guard let (status, body) = table[key] else {
                return (.stub(request, status: 404), Data(CookingFixtures.errorJSON(code: "NOT_FOUND", message: "no route \(key)").utf8))
            }
            return (.stub(request, status: status), Data(body.utf8))
        }
    }

    private var sessionPath: String { "/v1/sessions/\(CookingFixtures.sessionId)" }

    func testCommandSendsIdempotencyKeyAndConfirmedBody() async throws {
        route(["POST \(sessionPath)/commands": (200, try CookingFixtures.sessionJSON(stepIndex: 1, revision: 2))])
        var command = SessionCommand.confirmed(.next, revision: 1)
        command.stepIndex = nil
        let session = try await makeClient().sendCommand(sessionId: CookingFixtures.sessionUUID, command, idempotencyKey: "abc-123")
        XCTAssertEqual(session.stepIndex, 1)
        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "abc-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let body = try request.jsonBody()
        XCTAssertEqual(body["command"] as? String, "next")
        XCTAssertEqual(body["expected_revision"] as? Int, 1)
        XCTAssertEqual(body["user_confirmed"] as? Bool, true)
        XCTAssertEqual(body["client_source"] as? String, "ios_button")
        XCTAssertNil(body["step_index"], "absent optionals are omitted")
    }

    func testTimerAndCompleteBodies() async throws {
        route(["POST \(sessionPath)/commands": (200, try CookingFixtures.sessionJSON())])
        var timer = SessionCommand.confirmed(.startTimer, revision: 3)
        timer.timer = TimerRequest(label: "Simmer", durationSeconds: 600)
        _ = try await makeClient().sendCommand(sessionId: CookingFixtures.sessionUUID, timer, idempotencyKey: "k1")
        let timerBody = try XCTUnwrap(StubURLProtocol.requests.last).jsonBody()
        let timerJSON = try XCTUnwrap(timerBody["timer"] as? [String: Any])
        XCTAssertEqual(timerJSON["label"] as? String, "Simmer")
        XCTAssertEqual(timerJSON["duration_seconds"] as? Int, 600)

        var complete = SessionCommand.confirmed(.complete, revision: 4)
        complete.outcome = OutcomeInput(result: .didntWork, saveChanges: true)
        _ = try await makeClient().sendCommand(sessionId: CookingFixtures.sessionUUID, complete, idempotencyKey: "k2")
        let completeBody = try XCTUnwrap(StubURLProtocol.requests.last).jsonBody()
        let outcome = try XCTUnwrap(completeBody["outcome"] as? [String: Any])
        XCTAssertEqual(outcome["result"] as? String, "didnt_work")
        XCTAssertEqual(outcome["save_changes"] as? Bool, true)
    }

    func testStateConflictSurfacesLatestSessionThroughTheClient() async throws {
        let latest = try CookingFixtures.sessionJSON(stepIndex: 3, revision: 8)
        route(["POST \(sessionPath)/commands": (409, CookingFixtures.errorJSON(code: "STATE_CONFLICT", message: "stale", details: #"{"session":\#(latest)}"#))])
        do {
            _ = try await makeClient().sendCommand(sessionId: CookingFixtures.sessionUUID, .confirmed(.next, revision: 1), idempotencyKey: "k")
            XCTFail("expected 409")
        } catch let error as APIError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.latestSession?.stepIndex, 3)
        }
    }

    func testCreateSessionSuggestAskNotesAndPreferencesPaths() async throws {
        route([
            "POST /v1/sessions": (201, try CookingFixtures.sessionJSON(status: "created", revision: 0)),
            "GET /v1/sessions": (200, #"{"items":["# + CookingFixtures.summaryJSON() + "]}"),
            "POST /v1/substitutions/suggest": (200, CookingFixtures.substitutionsJSON),
            "POST \(sessionPath)/ask": (200, CookingFixtures.askJSON()),
            "POST \(sessionPath)/notes": (201, #"{"id":"\#(CookingFixtures.timerId)","text":"tasty","created_at":"2026-10-23T11:00:00Z"}"#),
            "GET /v1/me/preferences": (200, #"{"allergies":[],"avoid":[],"updated_at":null}"#),
            "PUT /v1/me/preferences": (200, #"{"allergies":["peanut"],"avoid":[],"updated_at":"2026-10-23T11:00:00Z"}"#),
            "DELETE \(sessionPath)": (204, ""),
        ])
        let client = makeClient()
        let created = try await client.createSession(recipeVersionId: CookingFixtures.versionUUID, adaptations: [
            .suggestion(try XCTUnwrap(UUID(uuidString: CookingFixtures.suggestionRuleId)), ingredientRef: "ing-8"),
            AdaptationInput(ingredientRef: "ing-3", replacement: "tamari", ratioOrAmount: "2 tbsp", source: .rule, reason: "saved"),
        ])
        XCTAssertEqual(created.status, .created)
        let createBody = try XCTUnwrap(StubURLProtocol.requests.last).jsonBody()
        XCTAssertEqual((createBody["recipe_version_id"] as? String)?.lowercased(), CookingFixtures.versionId)
        let adaptations = try XCTUnwrap(createBody["adaptations"] as? [[String: Any]])
        XCTAssertEqual((adaptations[0]["suggestion_id"] as? String)?.lowercased(), CookingFixtures.suggestionRuleId)
        XCTAssertEqual(adaptations[0]["ingredient_ref"] as? String, "ing-8")
        XCTAssertNil(adaptations[0]["replacement"])
        XCTAssertEqual(adaptations[1]["replacement"] as? String, "tamari")
        XCTAssertEqual(adaptations[1]["source"] as? String, "rule")

        let active = try await client.activeSessions()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.query, "status=active")

        let swaps = try await client.suggestSubstitutions(recipeVersionId: CookingFixtures.versionUUID, ingredientRef: "ing-8")
        XCTAssertEqual(swaps.suggestions.count, 2)
        XCTAssertEqual(try XCTUnwrap(StubURLProtocol.requests.last).jsonBody()["ingredient_ref"] as? String, "ing-8")

        let answer = try await client.ask(sessionId: CookingFixtures.sessionUUID, query: "what?", groundedRevision: 4)
        XCTAssertEqual(answer.groundedSessionRevision, 1)
        let askBody = try XCTUnwrap(StubURLProtocol.requests.last).jsonBody()
        XCTAssertEqual(askBody["query"] as? String, "what?")
        XCTAssertEqual(askBody["grounded_revision"] as? Int, 4)

        let note = try await client.addNote(sessionId: CookingFixtures.sessionUUID, text: "tasty", idempotencyKey: "note-1")
        XCTAssertEqual(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Idempotency-Key"), "note-1")
        XCTAssertEqual(note.text, "tasty")

        _ = try await client.preferences()
        let saved = try await client.updatePreferences(FoodPreferences(allergies: ["peanuts"]))
        XCTAssertEqual(saved.allergies, ["peanut"], "the server's normalised list wins")
        XCTAssertEqual(StubURLProtocol.requests.last?.httpMethod, "PUT")

        try await client.deleteSession(id: CookingFixtures.sessionUUID)
        XCTAssertEqual(StubURLProtocol.requests.last?.httpMethod, "DELETE")
    }

    func testMyVariation404IsNil() async throws {
        route([:])
        let variation = try await makeClient().myVariation(recipeVersionId: CookingFixtures.versionUUID)
        XCTAssertNil(variation)
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.path, "/v1/recipe-versions/\(CookingFixtures.versionId)/my-variation")
    }

    func testAsk429IsRateLimited() async throws {
        route(["POST \(sessionPath)/ask": (429, CookingFixtures.errorJSON(code: "RATE_LIMITED", message: "Slow down"))])
        do {
            _ = try await makeClient().ask(sessionId: CookingFixtures.sessionUUID, query: "q", groundedRevision: 1)
            XCTFail("expected 429")
        } catch let error as APIError {
            XCTAssertTrue(error.isRateLimited)
        }
    }
}
