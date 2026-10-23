import XCTest

/// End-to-end smoke against a LIVE local backend (not part of `make ios-check`).
///
/// Run with `make ios-smoke`: it starts from a fresh install, signs in with the two-step dev flow
/// by reading the one-time code from the backend's log file (path in `SOUSLENS_SMOKE_LOG`,
/// passed by xcodebuild as `TEST_RUNNER_SOUSLENS_SMOKE_LOG`), then exercises the app.
/// - `testSignInWithLoggedCodeAndOpenSeededRecipe`: PRD §16 Slice 0 gate.
/// - `testAuthorPublishAndSave`: brief 003 — create a draft from Profile, fill title / one
///   ingredient / one step, publish (with confirmation), find it in Explore, save it, see it in Saved.
/// - `testTypeIntoPantryAndCheckFit`: brief 004 — Pantry → Speak → Type instead → Find items →
///   review → Add, then the seeded recipe's Check my pantry shows the match and what's left.
@MainActor
final class SmokeSignInAndBrowseTests: XCTestCase {
    private let browseEmail = "smoke@souslens.dev"
    private let authorEmail = "smoke-author@souslens.dev"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Slice 0

    func testSignInWithLoggedCodeAndOpenSeededRecipe() throws {
        let app = try launchSignedIn(email: browseEmail)

        // Explore shows the seeded recipe from the live API. Search for it: recipes published by
        // earlier smoke runs sort above the seed and can push it off-screen.
        searchExplore(app, for: "Gochujang")
        let card = app.staticTexts["Gochujang Chicken Thighs"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "Explore did not list the seeded recipe")
        attach(app, "3-explore")
        card.tap()

        // Recipe detail renders attribution + the §13.4 provenance label
        XCTAssertTrue(
            app.staticTexts["Creator instructions"].firstMatch.waitForExistence(timeout: 10),
            "recipe detail did not show the creator-instructions label"
        )
        XCTAssertTrue(app.staticTexts["by SousLens Kitchen"].firstMatch.exists)
        attach(app, "4-detail")
    }

    // MARK: - Brief 003

    func testAuthorPublishAndSave() throws {
        let app = try launchSignedIn(email: authorEmail)
        let title = "Smoke Garlic Toast \(Int(Date().timeIntervalSince1970))"

        // Profile → Create recipe
        app.tabBars.buttons["Profile"].tap()
        let create = app.buttons["profile.createRecipe"]
        XCTAssertTrue(create.waitForExistence(timeout: 10), "Profile has no Create recipe")
        create.tap()

        // Title
        // Type-agnostic: a vertical-axis TextField may surface as a text view or a text field.
        let titleField = app.descendants(matching: .any)["draft.title"].firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 10), "editor did not open")
        type(title, into: titleField, in: app)

        // One ingredient
        app.buttons["draft.addIngredient"].tap()
        let name = app.textFields["ingredient.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "ingredient editor did not open")
        type("bread", into: name, in: app)
        app.buttons["ingredient.done"].tap()

        // One step
        let addStep = app.buttons["draft.addStep"]
        XCTAssertTrue(addStep.waitForExistence(timeout: 5))
        addStep.tap()
        let instruction = app.descendants(matching: .any)["step.instruction"].firstMatch
        XCTAssertTrue(instruction.waitForExistence(timeout: 5), "step editor did not open")
        type("Toast the bread until golden.", into: instruction, in: app)
        app.buttons["step.done"].tap()
        attach(app, "5-draft")

        // Autosave → server validation says publishable → Publish enables
        let publish = app.buttons["draft.publish"]
        XCTAssertTrue(publish.waitForExistence(timeout: 5))
        XCTAssertTrue(wait(for: publish, enabled: true, timeout: 15), "Publish never became enabled (autosave/validation)")
        publish.tap()

        // Explicit confirmation
        let confirm = app.buttons["publish.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "no publish confirmation")
        XCTAssertTrue(app.staticTexts["Publish version 1?"].exists)
        attach(app, "6-confirm")
        confirm.tap()

        // Success screen with share link
        XCTAssertTrue(app.staticTexts["Published version 1"].waitForExistence(timeout: 15), "publish did not succeed")
        XCTAssertTrue(app.buttons["published.share"].exists)
        attach(app, "7-published")
        app.buttons["published.done"].tap()

        // Explore: search by title (REC-02) and open it
        searchExplore(app, for: title)
        let card = app.staticTexts[title].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "published recipe not found in Explore")
        attach(app, "8-explore")
        card.tap()

        // Save on the detail screen
        let save = app.buttons["recipe.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: save, enabled: true, timeout: 10))
        save.tap()
        XCTAssertTrue(app.buttons["Unsave"].waitForExistence(timeout: 10), "save did not stick")
        attach(app, "9-saved-detail")

        // Saved tab lists it
        app.tabBars.buttons["Saved"].tap()
        XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 15), "saved recipe missing from Saved")
        attach(app, "10-saved-tab")
    }

    // MARK: - Brief 004

    func testTypeIntoPantryAndCheckFit() throws {
        // A fresh account per run, so the pantry starts empty and no duplicate prompt appears.
        let app = try launchSignedIn(email: "smoke-pantry-\(Int(Date().timeIntervalSince1970))@souslens.dev")

        // Pantry → Speak. The simulator has no speech recognizer, so the sheet may already be in
        // typing mode; tap "Type instead" when it is offered.
        app.tabBars.buttons["Pantry"].tap()
        let speak = app.buttons["pantry.speak"]
        XCTAssertTrue(speak.waitForExistence(timeout: 10), "Pantry has no Speak button")
        speak.tap()
        let typeInstead = app.buttons["speak.typeInstead"]
        if typeInstead.waitForExistence(timeout: 3) { typeInstead.tap() }
        let transcript = app.descendants(matching: .any)["speak.transcript"].firstMatch
        XCTAssertTrue(transcript.waitForExistence(timeout: 5), "no transcript field")
        type("chicken thighs, two onions, 3 tbsp gochujang and honey", into: transcript, in: app)
        attach(app, "11-pantry-typed")

        let findItems = app.buttons["speak.findItems"]
        XCTAssertTrue(wait(for: findItems, enabled: true, timeout: 5))
        findItems.tap()

        // Scan review: candidates, then an explicit confirm.
        let confirm = app.buttons["review.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15), "Scan review did not open")
        attach(app, "12-review")
        // Defensive: if the backend flags a duplicate anyway, answer it explicitly (never silent).
        for merge in app.buttons.matching(identifier: "review.merge").allElementsBoundByIndex where merge.isHittable {
            merge.tap()
        }
        scrollUntilHittable(confirm, in: app)
        XCTAssertTrue(wait(for: confirm, enabled: true, timeout: 5), "Confirm stayed disabled")
        confirm.tap()

        // Back on the pantry list with the new rows.
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pantry.row").firstMatch.waitForExistence(timeout: 15),
                      "pantry did not list the added items")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'pantry.row' AND label CONTAINS[c] 'gochujang'")).firstMatch.exists,
                      "gochujang not in the pantry")
        attach(app, "13-pantry-list")

        // Explore → seeded recipe → Check my pantry.
        searchExplore(app, for: "Gochujang")
        let card = app.staticTexts["Gochujang Chicken Thighs"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), "Explore did not list the seeded recipe")
        card.tap()
        let check = app.buttons["recipe.checkPantry"]
        XCTAssertTrue(check.waitForExistence(timeout: 10), "no Check my pantry button")
        scrollUntilHittable(check, in: app)
        XCTAssertTrue(wait(for: check, enabled: true, timeout: 10))
        check.tap()

        XCTAssertTrue(app.staticTexts["fit.headline"].waitForExistence(timeout: 15), "Pantry fit did not load")
        attach(app, "14-fit")
        // "3 tbsp gochujang" meets the recipe's 3 tbsp, so it must be Available (FIT-01/02).
        // Chicken thighs and onions were said without the recipe's amounts → Uncertain, not Missing.
        let gochujang = NSPredicate(format: "label CONTAINS[c] 'gochujang'")
        let available = collect(in: app, identifiers: ["fit.available"], matching: gochujang)
        XCTAssertFalse(available.isEmpty, "gochujang (3 tbsp in pantry) is not shown as Available")
        XCTAssertTrue(collect(in: app, identifiers: ["fit.missing"], matching: gochujang).isEmpty, "gochujang listed as Missing")
        let leftover = collect(in: app, identifiers: ["fit.missing", "fit.uncertain"], matching: NSPredicate(value: true))
        XCTAssertFalse(leftover.isEmpty, "expected something Missing or Uncertain (soy sauce, garlic, …)")
        attach(app, "15-fit-scrolled")
    }

    // MARK: - Helpers

    /// Launches, signs out any leftover session, then signs in with the code from the server log.
    private func launchSignedIn(email: String) throws -> XCUIApplication {
        let logPath = try XCTUnwrap(
            ProcessInfo.processInfo.environment["SOUSLENS_SMOKE_LOG"],
            "SOUSLENS_SMOKE_LOG must point at the backend log (use `make ios-smoke`)"
        )
        let app = XCUIApplication()
        // `-auth.hasLaunched NO` overrides that UserDefaults key for this launch only, so the app
        // takes its fresh-install path and discards any session a previous run left behind.
        app.launchArguments += ["-serverBaseURL", "http://localhost:8000", "-auth.hasLaunched", "NO"]
        app.launch()

        // Step 1: email
        let emailField = app.textFields.firstMatch
        XCTAssertTrue(emailField.waitForExistence(timeout: 10), "sign-in screen did not appear")
        emailField.tap()
        emailField.typeText(email)
        attach(app, "1-email")
        let logOffset = logLineCount(logPath)
        app.buttons["Continue"].tap()

        // Step 2: code from the server log (only lines written after Continue, so a code from an
        // earlier run or the other test is never reused)
        let codeField = app.textFields["signin.code"].exists
            ? app.textFields["signin.code"] : app.textFields.firstMatch
        XCTAssertTrue(codeField.waitForExistence(timeout: 10), "code step did not appear")
        let code = try waitForCode(in: logPath, email: email, afterLine: logOffset)
        codeField.tap()
        codeField.typeText(code)
        attach(app, "2-code")
        app.buttons["Verify"].tap()
        XCTAssertTrue(app.tabBars.buttons["Explore"].waitForExistence(timeout: 15), "sign-in did not complete")
        return app
    }

    /// Explore's search bar collapses under the large title once the list scrolls; pull it back.
    private func searchExplore(_ app: XCUIApplication, for text: String) {
        app.tabBars.buttons["Explore"].tap()
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 3) { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Explore search not found")
        type(text, into: search, in: app)
    }

    /// Fields inside a sheet that is still animating in can ignore the first tap, and typeText
    /// then fails with "neither element nor any descendant has keyboard focus". Tap, wait for the
    /// keyboard, retap once near the field's leading edge if needed, then type.
    private func type(_ text: String, into field: XCUIElement, in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        for attempt in 0..<3 {
            if attempt == 0 {
                field.tap()
            } else {
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
            }
            if keyboard.waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(keyboard.exists, "keyboard never appeared for \(field.identifier)")
        field.typeText(text)
    }

    /// Lists are lazy: swipe up until the element can be tapped (or give up after a few tries).
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
    }

    /// Labels of every element with one of `identifiers` matching `predicate`, scrolling the
    /// (lazy) list down a few screens so off-screen sections are seen too.
    private func collect(in app: XCUIApplication, identifiers: [String], matching predicate: NSPredicate, screens: Int = 4) -> Set<String> {
        var labels = Set<String>()
        for screen in 0..<screens {
            for identifier in identifiers {
                let query = app.descendants(matching: .any).matching(identifier: identifier).matching(predicate)
                for element in query.allElementsBoundByIndex where element.exists {
                    labels.insert(element.label)
                }
            }
            if screen < screens - 1 { app.swipeUp() }
        }
        for _ in 0..<(screens - 1) { app.swipeDown() }
        return labels
    }

    private func wait(for element: XCUIElement, enabled: Bool, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "isEnabled == %@", NSNumber(value: enabled))
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    private func logLineCount(_ path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// Polls the backend log for a `dev sign-in code` line for `email` written after `afterLine`.
    private func waitForCode(in path: String, email: String, afterLine: Int, timeout: TimeInterval = 10) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                for line in lines.dropFirst(max(0, afterLine - 1)).reversed()
                where line.contains("dev sign-in code") && line.contains(email) {
                    if let data = line.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let code = json["code"] as? String, code.count == 6 {
                        return code
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw XCTSkip("no sign-in code for \(email) appeared in \(path) within \(timeout)s")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "smoke-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
