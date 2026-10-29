import XCTest

final class WindowOverviewUITests: XCTestCase {
    @MainActor
    func testOverviewShowsStatusCountsAndRecentActions() {
        let app = launch(arguments: ["--ui-test-window-fixture"])
        defer { app.terminate() }

        let window = app.descendants(matching: .any)["watchdog.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))

        let overview = app.descendants(matching: .any)["watchdog.window.detail.overview"]
        XCTAssertTrue(overview.waitForExistence(timeout: 5))

        let status = app.descendants(matching: .any)["watchdog.overview.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        let attention = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '주의' OR value CONTAINS '주의'")
        ).firstMatch
        XCTAssertTrue(attention.waitForExistence(timeout: 2), "overview status should mention 주의")

        let sessionsButton = app.descendants(matching: .any)["watchdog.overview.sessions-button"]
        XCTAssertTrue(sessionsButton.waitForExistence(timeout: 2))
        sessionsButton.click()

        let sessions = app.descendants(matching: .any)["watchdog.window.detail.sessions"]
        XCTAssertTrue(sessions.waitForExistence(timeout: 5))

        let sidebar = app.descendants(matching: .any)["watchdog.sidebar.overview"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 2))
        sidebar.click()
        XCTAssertTrue(overview.waitForExistence(timeout: 5))

        let newestID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAA3"
        let newest = app.descendants(matching: .any)["overview.journal.\(newestID).row"]
        XCTAssertTrue(newest.waitForExistence(timeout: 5), "newest fixture journal entry should be visible")
    }

    @MainActor
    func testRulesShowsScopePickerAndRulesFileSection() {
        let app = launch(arguments: ["--ui-test-window-fixture"])
        defer { app.terminate() }

        let window = app.descendants(matching: .any)["watchdog.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))

        let rulesSidebar = app.descendants(matching: .any)["watchdog.sidebar.rules"]
        XCTAssertTrue(rulesSidebar.waitForExistence(timeout: 2))
        rulesSidebar.click()

        let rules = app.descendants(matching: .any)["watchdog.window.detail.rules"]
        XCTAssertTrue(rules.waitForExistence(timeout: 5))

        let scope = app.descendants(matching: .any)["watchdog.rules.auto-suspend-scope"]
        XCTAssertTrue(scope.waitForExistence(timeout: 2))
        XCTAssertFalse(scope.isEnabled, "scope picker must be disabled while auto-suspend is off")

        let fileStatus = app.descendants(matching: .any)["watchdog.rules.file.status"]
        XCTAssertTrue(fileStatus.waitForExistence(timeout: 2))
        let absent = app.staticTexts.matching(
            NSPredicate(format: "identifier == 'watchdog.rules.file.status' AND (label == '없음' OR value == '없음')")
        ).firstMatch
        XCTAssertTrue(
            absent.waitForExistence(timeout: 2) || fileStatus.label.contains("없음") || fileStatus.value as? String == "없음",
            "rules file status should be 없음; label=\(fileStatus.label) value=\(fileStatus.value ?? "")"
        )
    }

    @MainActor
    private func launch(arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = arguments
        let isolated = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-ui-rules-\(UUID().uuidString).json")
        app.launchEnvironment["WATCHDOG_RULES_PATH"] = isolated.path
        app.launchEnvironment["WATCHDOG_DISABLE_LOGIN_ITEM"] = "1"
        app.launch()
        return app
    }
}
