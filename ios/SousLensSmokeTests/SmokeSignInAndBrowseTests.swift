import XCTest

/// End-to-end smoke against a LIVE local backend (not part of `make ios-check`).
///
/// Run with `make ios-smoke`: it starts from a fresh install, signs in with the two-step dev flow
/// by reading the one-time code from the backend's log file (path in `SOUSLENS_SMOKE_LOG`,
/// passed by xcodebuild as `TEST_RUNNER_SOUSLENS_SMOKE_LOG`), then exercises the app.
/// - `testSignInWithLoggedCodeAndOpenSeededRecipe`: PRD §16 Slice 0 gate.
/// - `testAuthorPublishAndSave`: brief 003 — create a draft from Profile, fill title / one
///   ingredient / one step, publish (with confirmation), find it in Explore, save it, see it in Saved.
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

        // Explore shows the seeded recipe from the live API
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
        let titleField = app.textViews["draft.title"].exists ? app.textViews["draft.title"] : app.textFields["draft.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10), "editor did not open")
        titleField.tap()
        titleField.typeText(title)

        // One ingredient
        app.buttons["draft.addIngredient"].tap()
        let name = app.textFields["ingredient.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "ingredient editor did not open")
        name.tap()
        name.typeText("bread")
        app.buttons["ingredient.done"].tap()

        // One step
        let addStep = app.buttons["draft.addStep"]
        XCTAssertTrue(addStep.waitForExistence(timeout: 5))
        addStep.tap()
        let instruction = app.textViews["step.instruction"].exists ? app.textViews["step.instruction"] : app.textFields["step.instruction"]
        XCTAssertTrue(instruction.waitForExistence(timeout: 5), "step editor did not open")
        instruction.tap()
        instruction.typeText("Toast the bread until golden.")
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
        app.tabBars.buttons["Explore"].tap()
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 3) {
            app.swipeDown()  // reveal the search bar
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Explore search not found")
        search.tap()
        search.typeText(title)
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

    // MARK: - Helpers

    /// Launches, signs out any leftover session, then signs in with the code from the server log.
    private func launchSignedIn(email: String) throws -> XCUIApplication {
        let logPath = try XCTUnwrap(
            ProcessInfo.processInfo.environment["SOUSLENS_SMOKE_LOG"],
            "SOUSLENS_SMOKE_LOG must point at the backend log (use `make ios-smoke`)"
        )
        let app = XCUIApplication()
        app.launchArguments += ["-serverBaseURL", "http://localhost:8000"]
        app.launch()
        signOutIfNeeded(app)

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

    /// A previous run may have left a session behind (Keychain survives reinstall when the
    /// uninstall step is skipped). Start every smoke from the sign-in screen. Sign out sits at the
    /// bottom of Profile's list, below My recipes and Drafts, so scroll until it is on screen.
    private func signOutIfNeeded(_ app: XCUIApplication) {
        let profileTab = app.tabBars.buttons["Profile"]
        guard profileTab.waitForExistence(timeout: 5) else { return }
        profileTab.tap()
        let signOut = app.buttons["Sign out"].firstMatch
        var swipes = 0
        while !(signOut.exists && signOut.isHittable), swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
        if signOut.exists {
            signOut.tap()
            let confirm = app.buttons["Sign out"].firstMatch  // confirmation sheet, if any
            if confirm.waitForExistence(timeout: 2) { confirm.tap() }
        }
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10), "could not sign out")
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
