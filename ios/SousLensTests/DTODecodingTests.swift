import Foundation
import XCTest
@testable import SousLens

/// `recipe_detail.json` is a verbatim copy of the backend's `fixtures/expected_outputs/recipe_detail.json`.
final class DTODecodingTests: XCTestCase {
    func testRecipeDetailDecodesEveryField() throws {
        let detail = try Fixtures.decode(RecipeDetail.self, from: "recipe_detail")

        XCTAssertEqual(detail.schemaVersion, "1.0")
        XCTAssertEqual(detail.recipeId.uuidString.lowercased(), "a185d1a4-2726-57b9-9b17-069262cbf492")
        XCTAssertEqual(detail.recipeVersionId.uuidString.lowercased(), "02b20f6c-d644-58b4-b2be-086967191684")
        XCTAssertEqual(detail.versionNumber, 2)
        XCTAssertEqual(detail.slug, "gochujang-chicken-thighs")
        XCTAssertEqual(detail.title, "Gochujang Chicken Thighs")
        XCTAssertTrue(try XCTUnwrap(detail.summary).hasPrefix("Sticky, smoky-sweet"))
        XCTAssertEqual(detail.tags, ["korean", "chicken", "weeknight", "spicy"])
        XCTAssertEqual(detail.creator.id.uuidString.lowercased(), "f692d3b2-4d37-5232-8bdb-8c1b083bdf1e")
        XCTAssertEqual(detail.creator.displayName, "SousLens Kitchen")
        XCTAssertEqual(detail.servings, 4)
        XCTAssertEqual(detail.prepMinutes, 15)
        XCTAssertEqual(detail.cookMinutes, 20)
        XCTAssertNil(detail.coverImageUrl)
        XCTAssertNil(detail.coverImageURL)
        XCTAssertEqual(detail.creatorNotes.count, 2)
        XCTAssertEqual(detail.dietaryWarnings, [
            "Contains soy and sesame.",
            "Most gochujang and soy sauce contain wheat; check labels if avoiding gluten.",
        ])
        XCTAssertEqual(detail.publishedAt, try XCTUnwrap(ISO8601Flexible.parse("2026-10-15T00:00:00Z")))
    }

    func testExtraTopLevelCreatorIdIsIgnored() throws {
        let raw = try Fixtures.data("recipe_detail")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertNotNil(object["creator_id"], "fixture must carry creator_id")
        let detail = try JSONCoding.makeDecoder().decode(RecipeDetail.self, from: raw)
        XCTAssertEqual(detail.creator.displayName, "SousLens Kitchen")

        // Cards: the real list response carries no creator_id, but a future one might.
        let page = try JSONCoding.makeDecoder().decode(RecipePage.self, from: Data(Self.cardJSON(extra: #""creator_id":"f692d3b2-4d37-5232-8bdb-8c1b083bdf1e","future":{"a":1},"#).utf8))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(page.items[0].creator.displayName, "Mina Park")
    }

    /// One-card page in the backend's shape, with `extra` spliced in before `recipe_id`.
    private static func cardJSON(extra: String = "", summary: String = #""Overnight oats, no cooking.""#, cover: String = #""https://example.test/media/oats.jpg""#) -> String {
        """
        {"items":[{\(extra)"recipe_id":"a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d","slug":"overnight-oats","title":"Overnight Oats","summary":\(summary),
         "tags":["breakfast"],"creator":{"id":"c1a2b3c4-d5e6-4f70-8a9b-0c1d2e3f4a5b","display_name":"Mina Park"},"servings":1,"prep_minutes":5,"cook_minutes":null,
         "cover_image_url":\(cover),"published_at":"2026-10-16T18:00:00+00:00","recipe_version_id":"b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e","version_number":2}],
         "next_cursor":"eyJhZnRlciI6MX0"}
        """
    }

    func testIngredientsIncludingNulls() throws {
        let detail = try Fixtures.decode(RecipeDetail.self, from: "recipe_detail")
        XCTAssertEqual(detail.ingredients.count, 12)

        let thighs = try XCTUnwrap(detail.ingredients.first { $0.id == "ing-1" })
        XCTAssertEqual(thighs.quantity, 2.0)
        XCTAssertEqual(thighs.unit, "lb")
        XCTAssertFalse(thighs.optional)
        XCTAssertEqual(thighs.preparation, "trimmed and cut into 2-inch pieces")
        XCTAssertNil(thighs.notes)

        let gochujang = try XCTUnwrap(detail.ingredients.first { $0.id == "ing-2" })
        XCTAssertNil(gochujang.preparation)
        XCTAssertEqual(gochujang.notes, "Korean red chili paste; heat varies by brand")

        let scallion = try XCTUnwrap(detail.ingredients.first { $0.id == "ing-10" })
        XCTAssertEqual(scallion.quantity, 2)
        XCTAssertNil(scallion.unit)
        XCTAssertFalse(scallion.optional)

        let sesame = try XCTUnwrap(detail.ingredients.first { $0.id == "ing-11" })
        XCTAssertTrue(sesame.optional)
        XCTAssertEqual(sesame.unit, "tsp")

        let rice = try XCTUnwrap(detail.ingredients.first { $0.id == "ing-12" })
        XCTAssertTrue(rice.optional)
        XCTAssertEqual(rice.notes, "for serving")
    }

    func testStepsCuesWarningsAndProvenance() throws {
        let detail = try Fixtures.decode(RecipeDetail.self, from: "recipe_detail")
        XCTAssertEqual(detail.steps.count, 7)
        XCTAssertEqual(detail.orderedSteps.map(\.order), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertTrue(detail.steps.allSatisfy { $0.evidenceOrigin == .creatorAuthored })
        XCTAssertEqual(detail.headerProvenanceLabel, "Creator instructions")

        let marinate = try XCTUnwrap(detail.steps.first { $0.id == "step-2" })
        XCTAssertEqual(marinate.ingredientRefs, ["ing-1"])
        XCTAssertEqual(marinate.estimatedMinutes, 20)
        XCTAssertEqual(marinate.successCues, ["Every piece is evenly red with no bare patches"])
        XCTAssertEqual(marinate.warnings.count, 1)
        XCTAssertTrue(try XCTUnwrap(marinate.warnings.first).hasPrefix("Raw poultry"))
        XCTAssertTrue(try XCTUnwrap(marinate.creatorNote).hasPrefix("I mix this in the morning"))
        XCTAssertNil(marinate.provenanceLabel)

        let sear = try XCTUnwrap(detail.steps.first { $0.id == "step-4" })
        XCTAssertEqual(sear.successCues.count, 2)
        XCTAssertEqual(sear.warnings, ["The honey and gochujang burn fast: if the pan smokes heavily, lower the heat rather than pushing through."])
        XCTAssertNil(sear.creatorNote)

        let doneness = try XCTUnwrap(detail.steps.first { $0.id == "step-5" })
        XCTAssertTrue(doneness.warnings.contains { $0.contains("165°F (74°C)") })

        let serve = try XCTUnwrap(detail.steps.first { $0.id == "step-7" })
        XCTAssertEqual(serve.ingredientRefs, ["ing-10", "ing-11", "ing-12"])
        XCTAssertTrue(serve.warnings.isEmpty)
        XCTAssertNil(serve.creatorNote)
        XCTAssertNil(serve.sourceClipId)
        XCTAssertNil(serve.sourceStartMs)
        XCTAssertNil(serve.sourceEndMs)
    }

    func testStepSourceClipFieldsDecodeWhenPresent() throws {
        let json = """
        {"id":"s","order":0,"instruction":"Sear.","ingredient_refs":[],"estimated_minutes":4,"success_cues":[],"warnings":[],
         "creator_note":null,"source_clip_id":"clip-2","source_start_ms":20000,"source_end_ms":95000,"evidence_origin":"creator_reviewed"}
        """
        let step = try JSONCoding.makeDecoder().decode(RecipeStep.self, from: Data(json.utf8))
        XCTAssertEqual(step.sourceClipId, "clip-2")
        XCTAssertEqual(step.sourceStartMs, 20000)
        XCTAssertEqual(step.sourceEndMs, 95000)
        XCTAssertEqual(step.evidenceOrigin, .creatorReviewed)
        XCTAssertEqual(step.provenanceLabel, "AI-extracted, creator-verified")
    }

    func testAllOptionalFieldsNullDecode() throws {
        let json = """
        {"schema_version":"1.0","recipe_id":"7f3a1c2e-9b4d-4e6f-8a1b-2c3d4e5f6a7b","recipe_version_id":"0d9e8f7a-6b5c-4d3e-9f2a-1b0c9d8e7f6a",
         "version_number":1,"slug":"s","title":"T","summary":"S","tags":[],"creator":{"id":"c1a2b3c4-d5e6-4f70-8a9b-0c1d2e3f4a5b","display_name":"C"},
         "servings":2,"prep_minutes":null,"cook_minutes":null,"cover_image_url":null,
         "ingredients":[{"id":"i","name":"salt","quantity":null,"unit":null,"optional":false,"preparation":null,"notes":null}],
         "steps":[{"id":"s1","order":0,"instruction":"Do","ingredient_refs":[],"estimated_minutes":null,"success_cues":[],"warnings":[],
                   "creator_note":null,"source_clip_id":null,"source_start_ms":null,"source_end_ms":null,"evidence_origin":"creator_authored"}],
         "creator_notes":[],"dietary_warnings":[],"published_at":"2026-10-15T09:30:00+00:00","creator_id":"x","future_field":{"a":1}}
        """
        let detail = try JSONCoding.makeDecoder().decode(RecipeDetail.self, from: Data(json.utf8))
        XCTAssertNil(detail.prepMinutes)
        XCTAssertNil(detail.cookMinutes)
        XCTAssertNil(detail.coverImageURL)
        XCTAssertNil(detail.ingredients[0].quantity)
        XCTAssertNil(detail.steps[0].estimatedMinutes)
        XCTAssertNil(RecipeFormatting.totalTime(prep: detail.prepMinutes, cook: detail.cookMinutes))
    }

    // MARK: - EvidenceOrigin (PRD §13.4)

    func testUnknownEvidenceOriginDoesNotBreakWholeDecode() throws {
        var text = String(decoding: try Fixtures.data("recipe_detail"), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"evidence_origin\": \"creator_authored\"", with: "\"evidence_origin\": \"community_sourced\"")
        XCTAssertTrue(text.contains("community_sourced"), "replacement must hit the fixture")
        let detail = try JSONCoding.makeDecoder().decode(RecipeDetail.self, from: Data(text.utf8))
        XCTAssertEqual(detail.steps.count, 7)
        XCTAssertTrue(detail.steps.allSatisfy { $0.evidenceOrigin == .unknown })
        XCTAssertEqual(detail.headerProvenanceLabel, "AI-extracted", "unknown provenance is labelled conservatively")
        XCTAssertEqual(detail.steps[0].provenanceLabel, "AI-extracted")
    }

    func testEvidenceOriginLabels() throws {
        XCTAssertEqual(EvidenceOrigin.creatorAuthored.label, "Creator instructions")
        XCTAssertEqual(EvidenceOrigin.creatorReviewed.label, "AI-extracted, creator-verified")
        XCTAssertEqual(EvidenceOrigin.aiExtracted.label, "AI-extracted")
        XCTAssertEqual(EvidenceOrigin.unknown.label, "AI-extracted")
        XCTAssertNotEqual(EvidenceOrigin.unknown.label, "Creator instructions")
        XCTAssertEqual(EvidenceOrigin.allCases.count, 4)

        for (raw, expected) in [("creator_authored", EvidenceOrigin.creatorAuthored),
                                ("creator_reviewed", .creatorReviewed),
                                ("ai_extracted", .aiExtracted),
                                ("whatever_v2", .unknown)] {
            let decoded = try JSONCoding.makeDecoder().decode([EvidenceOrigin].self, from: Data("[\"\(raw)\"]".utf8))
            XCTAssertEqual(decoded, [expected], raw)
        }
    }

    // MARK: - Step row / header presentation (what the detail screen actually renders)

    func testStepRowShowsProvenancePillOnlyForNonCreatorAuthoredSteps() throws {
        func step(_ origin: String, minutes: String = "4", note: String = "null") throws -> RecipeStep {
            let json = """
            {"id":"s","order":0,"instruction":"Sear the chicken.","ingredient_refs":[],"estimated_minutes":\(minutes),
             "success_cues":["Deep crust"],"warnings":["Hot oil"],"creator_note":\(note),"source_clip_id":null,"source_start_ms":null,
             "source_end_ms":null,"evidence_origin":"\(origin)"}
            """
            return try JSONCoding.makeDecoder().decode(RecipeStep.self, from: Data(json.utf8))
        }
        let authored = StepRowPresentation(number: 1, step: try step("creator_authored"))
        XCTAssertNil(authored.provenancePill)
        XCTAssertEqual(authored.pills, ["About 4 min"])
        XCTAssertEqual(authored.numberText, "1")
        XCTAssertEqual(authored.instruction, "Sear the chicken.")
        XCTAssertEqual(authored.successCues, ["Deep crust"])
        XCTAssertEqual(authored.warnings, ["Hot oil"])
        XCTAssertNil(authored.creatorNoteText)
        XCTAssertEqual(authored.accessibilityLabel, "Step 1")

        let reviewed = StepRowPresentation(number: 2, step: try step("creator_reviewed", note: #""Use a hot pan.""#))
        XCTAssertEqual(reviewed.provenancePill, "AI-extracted, creator-verified")
        XCTAssertEqual(reviewed.pills, ["About 4 min", "AI-extracted, creator-verified"])
        XCTAssertEqual(reviewed.creatorNoteText, "Creator note: Use a hot pan.")

        let extracted = StepRowPresentation(number: 3, step: try step("ai_extracted", minutes: "null"))
        XCTAssertEqual(extracted.provenancePill, "AI-extracted")
        XCTAssertEqual(extracted.pills, ["AI-extracted"], "no time pill when the estimate is null")

        let unknown = StepRowPresentation(number: 4, step: try step("something_new"))
        XCTAssertEqual(unknown.provenancePill, "AI-extracted")
    }

    func testStepsHeaderPillFollowsRecipeProvenance() throws {
        let fixture = try Fixtures.decode(RecipeDetail.self, from: "recipe_detail")
        let header = StepsHeaderPresentation(detail: fixture)
        XCTAssertEqual(header.title, "Steps")
        XCTAssertEqual(header.provenancePill, "Creator instructions")

        var text = String(decoding: try Fixtures.data("recipe_detail"), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"evidence_origin\": \"creator_authored\"", with: "\"evidence_origin\": \"creator_reviewed\"")
        let reviewed = try JSONCoding.makeDecoder().decode(RecipeDetail.self, from: Data(text.utf8))
        XCTAssertEqual(StepsHeaderPresentation(detail: reviewed).provenancePill, "AI-extracted, creator-verified")
        XCTAssertTrue(reviewed.orderedSteps.allSatisfy { StepRowPresentation(number: 1, step: $0).provenancePill == "AI-extracted, creator-verified" })
    }

    func testHeaderProvenanceUsesLeastCreatorAuthoredOrigin() throws {
        func detail(_ origins: [String]) throws -> RecipeDetail {
            let steps = origins.enumerated().map { index, origin in
                """
                {"id":"s\(index)","order":\(index),"instruction":"x","ingredient_refs":[],"estimated_minutes":null,"success_cues":[],"warnings":[],
                 "creator_note":null,"source_clip_id":null,"source_start_ms":null,"source_end_ms":null,"evidence_origin":"\(origin)"}
                """
            }.joined(separator: ",")
            let json = """
            {"schema_version":"1.0","recipe_id":"7f3a1c2e-9b4d-4e6f-8a1b-2c3d4e5f6a7b","recipe_version_id":"0d9e8f7a-6b5c-4d3e-9f2a-1b0c9d8e7f6a",
             "version_number":1,"slug":"s","title":"T","summary":"S","tags":[],"creator":{"id":"c1a2b3c4-d5e6-4f70-8a9b-0c1d2e3f4a5b","display_name":"C"},
             "servings":2,"prep_minutes":null,"cook_minutes":null,"cover_image_url":null,"ingredients":[],"steps":[\(steps)],
             "creator_notes":[],"dietary_warnings":[],"published_at":"2026-10-15T00:00:00Z"}
            """
            return try JSONCoding.makeDecoder().decode(RecipeDetail.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try detail(["creator_authored", "creator_authored"]).headerProvenanceLabel, "Creator instructions")
        XCTAssertEqual(try detail(["creator_authored", "creator_reviewed"]).headerProvenanceLabel, "AI-extracted, creator-verified")
        XCTAssertEqual(try detail(["creator_reviewed", "ai_extracted"]).headerProvenanceLabel, "AI-extracted")
        XCTAssertEqual(try detail(["creator_authored", "mystery"]).headerProvenanceLabel, "AI-extracted")
    }

    // MARK: - List, auth, health

    /// `recipes_list.json` is the backend's real `GET /v1/recipes` response (one seeded recipe).
    func testRecipeListDecodes() throws {
        let page = try Fixtures.decode(RecipePage.self, from: "recipes_list")
        XCTAssertEqual(page.items.count, 1)
        XCTAssertNil(page.nextCursor)

        let card = page.items[0]
        XCTAssertEqual(card.id, card.recipeId)
        XCTAssertEqual(card.recipeId.uuidString.lowercased(), "a185d1a4-2726-57b9-9b17-069262cbf492")
        XCTAssertEqual(card.recipeVersionId.uuidString.lowercased(), "02b20f6c-d644-58b4-b2be-086967191684")
        XCTAssertEqual(card.slug, "gochujang-chicken-thighs")
        XCTAssertEqual(card.title, "Gochujang Chicken Thighs")
        XCTAssertTrue(try XCTUnwrap(card.summary).hasPrefix("Sticky, smoky-sweet"))
        XCTAssertEqual(card.tags, ["korean", "chicken", "weeknight", "spicy"])
        XCTAssertEqual(card.creator.displayName, "SousLens Kitchen")
        XCTAssertEqual(card.servings, 4)
        XCTAssertEqual(card.versionNumber, 2)
        XCTAssertEqual(card.prepMinutes, 15)
        XCTAssertEqual(card.cookMinutes, 20)
        XCTAssertNil(card.coverImageURL)
        XCTAssertEqual(card.publishedAt, try XCTUnwrap(ISO8601Flexible.parse("2026-10-15T00:00:00Z")))
    }

    func testRecipeCardOptionalFieldsAndOffsetDate() throws {
        let page = try JSONCoding.makeDecoder().decode(RecipePage.self, from: Data(Self.cardJSON().utf8))
        XCTAssertEqual(page.nextCursor, "eyJhZnRlciI6MX0")
        let card = page.items[0]
        XCTAssertNil(card.cookMinutes)
        XCTAssertEqual(card.coverImageURL, URL(string: "https://example.test/media/oats.jpg"))
        XCTAssertEqual(card.versionNumber, 2)
        // "+00:00" offset form.
        XCTAssertEqual(card.publishedAt, try XCTUnwrap(ISO8601Flexible.parse("2026-10-16T18:00:00Z")))
    }

    func testNullSummaryDecodesForCardAndDetail() throws {
        let page = try JSONCoding.makeDecoder().decode(RecipePage.self, from: Data(Self.cardJSON(summary: "null", cover: "null").utf8))
        XCTAssertNil(page.items[0].summary)
        XCTAssertNil(page.items[0].coverImageURL)

        var text = String(decoding: try Fixtures.data("recipe_detail"), as: UTF8.self)
        let range = try XCTUnwrap(text.range(of: #""summary": "[^"]*""#, options: .regularExpression))
        text.replaceSubrange(range, with: #""summary": null"#)
        let detail = try JSONCoding.makeDecoder().decode(RecipeDetail.self, from: Data(text.utf8))
        XCTAssertNil(detail.summary)
        XCTAssertEqual(detail.title, "Gochujang Chicken Thighs")
    }

    func testRecipeCardRoundTripsThroughEncoder() throws {
        let page = try Fixtures.decode(RecipePage.self, from: "recipes_list")
        let data = try JSONCoding.makeEncoder().encode(page)
        let again = try JSONCoding.makeDecoder().decode(RecipePage.self, from: data)
        XCTAssertEqual(again, page)
    }

    func testUserAndAuthResponseDecode() throws {
        let json = """
        {"access_token":"abc.def.ghi","token_type":"bearer","user":{"id":"c1a2b3c4-d5e6-4f70-8a9b-0c1d2e3f4a5b","display_name":"Mina","preference_units":"metric","created_at":"2026-10-01T00:00:00Z"}}
        """
        let response = try JSONCoding.makeDecoder().decode(AuthResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.accessToken, "abc.def.ghi")
        XCTAssertEqual(response.tokenType, "bearer")
        XCTAssertEqual(response.user.displayName, "Mina")
        XCTAssertEqual(response.user.preferenceUnits, .metric)
    }

    func testDevLoginChallengeDecodes() throws {
        let challenge = try JSONCoding.makeDecoder().decode(DevLoginChallenge.self, from: Data(AuthFixtures.challengeJSON.utf8))
        XCTAssertEqual(challenge.challengeId, "chal-1")
        XCTAssertEqual(challenge.expiresInSeconds, 600)
        XCTAssertEqual(challenge.hint, "Check the server log for your sign-in code.")
        XCTAssertEqual(challenge.expiresAt.timeIntervalSince(challenge.receivedAt), 600, accuracy: 0.001)
        // `hint` is optional on the wire.
        let bare = try JSONCoding.makeDecoder().decode(DevLoginChallenge.self, from: Data(#"{"challenge_id":"c","expires_in_seconds":1}"#.utf8))
        XCTAssertNil(bare.hint)
    }

    func testHealthDecodes() throws {
        let json = #"{"status":"ok","version":"0.1.0","ai_provider":"mock"}"#
        let health = try JSONCoding.makeDecoder().decode(HealthResponse.self, from: Data(json.utf8))
        XCTAssertEqual(health, HealthResponse(status: "ok", version: "0.1.0", aiProvider: "mock"))
    }

    func testFlexibleDateParsing() {
        XCTAssertNotNil(ISO8601Flexible.parse("2026-10-15T00:00:00Z"))
        XCTAssertNotNil(ISO8601Flexible.parse("2026-10-15T00:00:00.5Z"))
        XCTAssertNotNil(ISO8601Flexible.parse("2026-10-15T00:00:00.123456Z"))
        XCTAssertNotNil(ISO8601Flexible.parse("2026-10-15T00:00:00+00:00"))
        XCTAssertNotNil(ISO8601Flexible.parse("2026-10-15T00:00:00.123456+00:00"))
        XCTAssertNotNil(ISO8601Flexible.parse("2026-10-15T00:00:00"))
        XCTAssertNil(ISO8601Flexible.parse("yesterday"))
    }

    func testQuantityFormatting() {
        XCTAssertEqual(RecipeFormatting.quantity(1.5, unit: "lb"), "1½ lb")
        XCTAssertEqual(RecipeFormatting.quantity(0.25, unit: "tsp"), "¼ tsp")
        XCTAssertEqual(RecipeFormatting.quantity(3, unit: "tbsp"), "3 tbsp")
        XCTAssertEqual(RecipeFormatting.quantity(2, unit: nil), "2")
        XCTAssertNil(RecipeFormatting.quantity(nil, unit: nil))
        XCTAssertEqual(RecipeFormatting.totalTime(prep: 15, cook: 25), "40 min")
        XCTAssertEqual(RecipeFormatting.totalTime(prep: 30, cook: 60), "1 hr 30 min")
        XCTAssertNil(RecipeFormatting.totalTime(prep: nil, cook: nil))
    }
}
