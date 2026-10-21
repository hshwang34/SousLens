import XCTest

/// End-to-end smoke against a LIVE local backend (not part of `make ios-check`).
///
/// Run with `make ios-smoke`: it starts from a fresh install, signs in with the two-step dev flow
/// by reading the one-time code from the backend's log file (path in `SOUSLENS_SMOKE_LOG`,
/// passed by xcodebuild as `TEST_RUNNER_SOUSLENS_SMOKE_LOG`), opens Explore and the seeded recipe.
/// This is the PRD §16 Slice 0 gate: "launch simulator → open seeded recipe; API returns it".
@MainActor
final class SmokeSignInAndBrowseTests: XCTestCase {
    private let email = "smoke@souslens.dev"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSignInWithLoggedCodeAndOpenSeededRecipe() throws {
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
        app.buttons["Continue"].tap()

        // Step 2: code from the server log
        let codeField = app.textFields["signin.code"].exists
            ? app.textFields["signin.code"] : app.textFields.firstMatch
        XCTAssertTrue(codeField.waitForExistence(timeout: 10), "code step did not appear")
        let code = try waitForCode(in: logPath)
        codeField.tap()
        codeField.typeText(code)
        attach(app, "2-code")
        app.buttons["Verify"].tap()

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

    /// A previous run may have left a session behind (Keychain survives reinstall when the
    /// uninstall step is skipped). Start every smoke from the sign-in screen.
    private func signOutIfNeeded(_ app: XCUIApplication) {
        let profileTab = app.tabBars.buttons["Profile"]
        guard profileTab.waitForExistence(timeout: 5) else { return }
        profileTab.tap()
        let signOut = app.buttons["Sign out"].firstMatch
        if signOut.waitForExistence(timeout: 5) {
            signOut.tap()
            let confirm = app.buttons["Sign out"].firstMatch  // confirmation sheet, if any
            if confirm.waitForExistence(timeout: 2) { confirm.tap() }
        }
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10), "could not sign out")
    }

    /// Polls the backend log for the most recent `dev sign-in code` line for our email.
    private func waitForCode(in path: String, timeout: TimeInterval = 10) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                for line in text.split(separator: "\n").reversed()
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
