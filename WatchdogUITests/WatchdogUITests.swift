import XCTest

final class WatchdogUITests: XCTestCase {
    private let actionableProcess = "process.71001.9071001"

    @MainActor
    func testShippingAppShowsHeaderAndTextualAlertReasons() {
        let app = launch(arguments: ["--ui-test-fixture"])
        defer { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        let header = app.staticTexts["Watchdog"]
        XCTAssertTrue(header.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["CPU 높음"].exists)
        XCTAssertTrue(app.staticTexts["메모리 높음"].exists)
        XCTAssertTrue(app.staticTexts["고아 의심"].exists)

        let row = app.descendants(matching: .any)["\(actionableProcess).row"]
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        XCTAssertTrue(row.label.contains("claude"))
        let projectMetadata = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'watchdog-fixture' OR value CONTAINS 'watchdog-fixture'")
        ).firstMatch
        XCTAssertTrue(projectMetadata.exists)
        XCTAssertTrue(app.staticTexts["연결된 터미널 세션을 찾을 수 없습니다"].exists)
    }

    @MainActor
    func testAboutPanelShowsVersionAndCopyright() {
        let app = launch(arguments: ["--ui-test-fixture"])
        defer { app.terminate() }

        let aboutButton = app.buttons["watchdog.about"]
        XCTAssertTrue(aboutButton.waitForExistence(timeout: 5))
        aboutButton.click()

        // The test bundle shares MARKETING_VERSION with the app; never hard-code
        // the release number here.
        let expected = Bundle(for: Self.self)
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let version = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", expected, expected)
        ).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 5))

        let copyright = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '2026 justn-hyeok' OR value CONTAINS '2026 justn-hyeok'")
        ).firstMatch
        XCTAssertTrue(copyright.exists)
    }

    @MainActor
    func testStaleFixtureDisablesControlsAndExplainsWhy() {
        let app = launch(arguments: ["--ui-test-stale-fixture"])
        defer { app.terminate() }

        let row = app.descendants(matching: .any)["\(actionableProcess).row"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("claude"))
        XCTAssertTrue(app.staticTexts["관찰 정보가 오래되어 새로고침 후 제어할 수 있습니다"].exists)

        let suspend = app.descendants(matching: .any)["\(actionableProcess).suspend"]
        XCTAssertTrue(suspend.exists)
        XCTAssertEqual(suspend.label, "세션 일시 정지")
        XCTAssertFalse(suspend.isEnabled)

        let actions = app.descendants(matching: .any)["\(actionableProcess).actions"]
        XCTAssertTrue(actions.exists)
        XCTAssertFalse(actions.isEnabled)
    }

    @MainActor
    func testAuthoritativeOutcomeWordingDoesNotClaimExit() {
        let app = launch(arguments: ["--ui-test-outcome-fixture"])
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["종료 여부를 확인하지 못함"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["종료 확인됨"].exists)
    }

    @MainActor
    func testIgnoreShowsRecoveryControl() {
        let app = launch(arguments: ["--ui-test-fixture"])
        defer { app.terminate() }
        openActionMenu(in: app)
        XCTAssertTrue(app.menuItems["종료할 때까지 무시"].waitForExistence(timeout: 2))
        app.menuItems["종료할 때까지 무시"].click()
        XCTAssertTrue(app.staticTexts["무시 중"].waitForExistence(timeout: 2))

        let undoIgnore = app.buttons["\(actionableProcess).undo-ignore"]
        XCTAssertTrue(undoIgnore.waitForExistence(timeout: 2))
    }

    @MainActor
    func testExitedAndStillRunningOutcomeWording() {
        var app = launch(arguments: ["--ui-test-exited-fixture"])
        XCTAssertTrue(app.staticTexts["종료 확인됨"].waitForExistence(timeout: 5))
        app.terminate()

        app = launch(arguments: ["--ui-test-still-running-fixture"])
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["신호 후에도 실행 중"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["종료 확인됨"].exists)
    }

    @MainActor
    func testTerminateConfirmationCanBeReachedAndCancelledWithoutSendingSignal() {
        let app = launch(arguments: ["--ui-test-fixture"])
        defer { app.terminate() }
        openActionMenu(in: app)
        let terminate = app.menuItems["\(actionableProcess).terminate"]
        XCTAssertTrue(terminate.waitForExistence(timeout: 2))
        terminate.click()

        let title = app.staticTexts["프로세스를 종료할까요?"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["watchdog.destructive-confirmation.confirm"].exists)
        app.windows.firstMatch.buttons["취소"].click()
        XCTAssertTrue(title.waitForNonExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '신호를 전달했습니다'")).firstMatch.exists)
    }

    @MainActor
    func testForceQuitHasSeparateStrongerConfirmationAndCanBeCancelled() {
        let app = launch(arguments: ["--ui-test-fixture"])
        defer { app.terminate() }
        openActionMenu(in: app)
        let forceQuit = app.menuItems["\(actionableProcess).force-quit"]
        XCTAssertTrue(forceQuit.waitForExistence(timeout: 2))
        forceQuit.click()

        let title = app.staticTexts["프로세스를 강제 종료할까요?"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["watchdog.destructive-confirmation.confirm"].exists)
        app.windows.firstMatch.buttons["취소"].click()
        XCTAssertTrue(title.waitForNonExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '신호를 전달했습니다'")).firstMatch.exists)
    }

    /// The CPU ranking of the two fixture rows swaps on every 2 s sample. While
    /// the list is on screen the rows must not trade places, otherwise a click
    /// aimed at one row can land on the other.
    @MainActor
    func testRowsHoldPositionWhileRankingChanges() {
        let app = launch(arguments: ["--ui-test-reorder-fixture"])
        defer { app.terminate() }

        let first = app.descendants(matching: .any)["process.71001.9071001.row"]
        let second = app.descendants(matching: .any)["process.71002.9071002.row"]
        XCTAssertTrue(first.waitForExistence(timeout: 6))
        XCTAssertTrue(second.waitForExistence(timeout: 2))

        let initialOrder = first.frame.minY < second.frame.minY
        func secondRowIsBusy() -> Bool { second.staticTexts["90%"].exists }
        let initiallyBusy = secondRowIsBusy()
        var sawRefresh = false
        for _ in 0..<14 {
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertEqual(first.frame.minY < second.frame.minY, initialOrder, "rows traded places while shown")
            if secondRowIsBusy() != initiallyBusy { sawRefresh = true }
        }
        XCTAssertTrue(sawRefresh, "the fixture must actually refresh, or the test proves nothing")
    }

    @MainActor
    func testMainWindowShowsSixSidebarSectionsAndRoutes() {
        let app = launch(arguments: ["--ui-test-window-fixture"])
        defer { app.terminate() }

        let window = app.descendants(matching: .any)["watchdog.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))

        let sections = ["overview", "sessions", "processes", "journal", "rules", "settings"]
        for section in sections {
            let item = app.descendants(matching: .any)["watchdog.sidebar.\(section)"]
            XCTAssertTrue(item.waitForExistence(timeout: 2), "missing sidebar \(section)")
            item.click()
            let detail = app.descendants(matching: .any)["watchdog.window.detail.\(section)"]
            XCTAssertTrue(detail.waitForExistence(timeout: 2), "missing detail \(section)")
        }
    }

    @MainActor
    func testJournalSectionListsEntriesAndUndoStates() {
        let app = launch(arguments: ["--ui-test-window-fixture"])
        defer { app.terminate() }

        let window = app.descendants(matching: .any)["watchdog.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))

        let sidebar = app.descendants(matching: .any)["watchdog.sidebar.journal"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 2))
        sidebar.click()

        let autoID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAA1"
        let cliID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAA2"
        let resumeID = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAA3"

        let autoRow = app.descendants(matching: .any)["journal.\(autoID).row"]
        let cliRow = app.descendants(matching: .any)["journal.\(cliID).row"]
        let resumeRow = app.descendants(matching: .any)["journal.\(resumeID).row"]
        XCTAssertTrue(autoRow.waitForExistence(timeout: 5))
        XCTAssertTrue(cliRow.exists)
        XCTAssertTrue(resumeRow.exists)

        let autoUndo = app.descendants(matching: .any)["journal.\(autoID).undo"]
        let cliUndo = app.descendants(matching: .any)["journal.\(cliID).undo"]
        let resumeUndo = app.descendants(matching: .any)["journal.\(resumeID).undo"]
        XCTAssertTrue(autoUndo.waitForExistence(timeout: 2))
        XCTAssertTrue(autoUndo.isEnabled)
        XCTAssertTrue(cliUndo.exists)
        XCTAssertFalse(cliUndo.isEnabled)
        XCTAssertTrue(resumeUndo.exists)
        XCTAssertFalse(resumeUndo.isEnabled)

        XCTAssertTrue(app.descendants(matching: .any)["watchdog.journal.export"].exists)
    }

    @MainActor
    func testRulesAndSettingsSectionsShowControls() {
        let app = launch(arguments: ["--ui-test-window-fixture"])
        defer { app.terminate() }

        let window = app.descendants(matching: .any)["watchdog.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))

        let rulesSidebar = app.descendants(matching: .any)["watchdog.sidebar.rules"]
        XCTAssertTrue(rulesSidebar.waitForExistence(timeout: 2))
        rulesSidebar.click()
        XCTAssertTrue(app.descendants(matching: .any)["watchdog.rules.cpu"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["watchdog.rules.auto-suspend"].exists)

        let settingsSidebar = app.descendants(matching: .any)["watchdog.sidebar.settings"]
        XCTAssertTrue(settingsSidebar.waitForExistence(timeout: 2))
        settingsSidebar.click()
        XCTAssertTrue(app.descendants(matching: .any)["watchdog.settings.login"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.descendants(matching: .any)["watchdog.settings.notifications"].exists)

        let expected = Bundle(for: Self.self)
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let version = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", expected, expected)
        ).firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 2))
    }

    @MainActor
    func testPopoverShowsSessionsStatusLineAndRecentActions() {
        let app = launch(arguments: ["--ui-test-fixture"])
        defer { app.terminate() }

        let status = app.descendants(matching: .any)["watchdog.status-line"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("주의") || app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '주의' OR value CONTAINS '주의'")
        ).firstMatch.exists)

        let row = app.descendants(matching: .any)["process.71001.9071001.row"]
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        XCTAssertTrue(row.label.contains("자식"), "session row should name member count: \(row.label)")
        XCTAssertTrue(
            row.label.contains("퍼센트") || row.label.contains("%") || row.label.contains("CPU"),
            "session row should include CPU total: \(row.label)"
        )

        let expand = app.descendants(matching: .any)["process.71001.9071001.expand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 2))
        expand.click()
        let member = app.descendants(matching: .any)["process.71003.9071003.row"]
        XCTAssertTrue(member.waitForExistence(timeout: 2))

        XCTAssertTrue(app.staticTexts["아직 조치가 없습니다"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testProcessesSectionSearchFilterAndNoMatch() {
        let app = launch(arguments: ["--ui-test-window-fixture"])
        defer { app.terminate() }

        let window = app.descendants(matching: .any)["watchdog.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))

        let sidebar = app.descendants(matching: .any)["watchdog.sidebar.processes"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 2))
        sidebar.click()

        let first = app.descendants(matching: .any)["process.71001.9071001.row"]
        let second = app.descendants(matching: .any)["process.71002.9071002.row"]
        let make = app.descendants(matching: .any)["process.71003.9071003.row"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.exists)
        XCTAssertTrue(make.exists)

        let field = app.textFields["watchdog.processes.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 2))
        focusSearchField(field)
        field.typeText("fixture-with-no-matching-process")

        let empty = app.descendants(matching: .any)["watchdog.processes.empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["검색 결과가 없습니다"].exists)

        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        if first.waitForExistence(timeout: 1) == false {
            DistributedNotificationCenter.default().post(
                name: Notification.Name("dev.justn.watchdog.uitest.clear-search"),
                object: nil
            )
        }
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(make.waitForExistence(timeout: 2))

        let agentFilter = app.descendants(matching: .any)["watchdog.processes.filter.agents"]
        if agentFilter.waitForExistence(timeout: 2) {
            agentFilter.click()
        } else if app.radioButtons["에이전트"].exists {
            app.radioButtons["에이전트"].click()
        }
        DistributedNotificationCenter.default().post(
            name: Notification.Name("dev.justn.watchdog.uitest.select-agents-filter"),
            object: nil
        )
        XCTAssertTrue(make.waitForNonExistence(timeout: 5), "agent filter should hide the make child")
        XCTAssertTrue(first.waitForExistence(timeout: 2))
        XCTAssertTrue(second.exists)
        XCTAssertFalse(make.exists)
    }

    @MainActor
    func testSessionsSectionListsSessionsAndMembers() {
        let app = launch(arguments: ["--ui-test-window-fixture"])
        defer { app.terminate() }

        let window = app.descendants(matching: .any)["watchdog.window"]
        XCTAssertTrue(window.waitForExistence(timeout: 8))

        let sidebar = app.descendants(matching: .any)["watchdog.sidebar.sessions"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 2))
        sidebar.click()

        let firstSession = app.descendants(matching: .any)["session.71001.9071001.row"]
        let secondSession = app.descendants(matching: .any)["session.71002.9071002.row"]
        XCTAssertTrue(firstSession.waitForExistence(timeout: 5))
        XCTAssertTrue(secondSession.exists)

        expandSessionRow(firstSession, in: app)
        let member = app.descendants(matching: .any)["process.71003.9071003.row"]
        XCTAssertTrue(member.waitForExistence(timeout: 5), "member row should appear after expanding the session")

        firstSession.click()
        let detail = app.descendants(matching: .any)["watchdog.sessions.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 2))
        let token = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '9071001' OR value CONTAINS '9071001'")
        ).firstMatch
        XCTAssertTrue(token.waitForExistence(timeout: 2), "detail should include the start-time token")

        let suspend = app.descendants(matching: .any)["session.71001.9071001.suspend"]
        XCTAssertTrue(suspend.waitForExistence(timeout: 2))
        XCTAssertTrue(suspend.isEnabled)

        firstSession.rightClick()
        let terminate = app.menuItems["종료…"]
        XCTAssertTrue(terminate.waitForExistence(timeout: 3))
        terminate.click()

        let confirmation = app.descendants(matching: .any)["watchdog.destructive-confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["프로세스를 종료할까요?"].exists)
        app.windows.firstMatch.buttons["취소"].click()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '신호를 전달했습니다'")).firstMatch.exists)
    }

    @MainActor
    func testPopoverHasOpenWindowButton() {
        let app = launch(arguments: ["--ui-test-fixture"])
        defer { app.terminate() }

        let button = app.buttons["watchdog.open-window"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(button.label, "창 열기")
        // The fixture hosts WatchdogMenuView in a titled NSWindow, not the
        // MenuBarExtra popover. Clicking here can open the SwiftUI Window, but
        // status-item / multi-window focus is the unstable part this fixture
        // exists to avoid — assert the control itself, not the handoff.
    }

    @MainActor
    private func searchFieldHasFocus(_ field: XCUIElement) -> Bool {
        NSPredicate(format: "hasKeyboardFocus == YES").evaluate(with: field)
    }

    @MainActor
    private func focusSearchField(_ field: XCUIElement) {
        field.click()
        if searchFieldHasFocus(field) { return }
        Thread.sleep(forTimeInterval: 0.3)
        field.click()
        XCTAssertTrue(searchFieldHasFocus(field), "search field did not take keyboard focus after retry")
    }

    @MainActor
    private func expandSessionRow(_ row: XCUIElement, in app: XCUIApplication) {
        let member = app.descendants(matching: .any)["process.71003.9071003.row"]
        if member.exists { return }

        row.click()
        let triangles = app.disclosureTriangles
        if triangles.firstMatch.waitForExistence(timeout: 1) {
            triangles.firstMatch.click()
            if member.waitForExistence(timeout: 2) { return }
        }

        row.click()
        row.typeKey(.rightArrow, modifierFlags: [])
        if member.waitForExistence(timeout: 2) { return }

        row.click()
        row.typeKey(.return, modifierFlags: [])
        _ = member.waitForExistence(timeout: 2)
    }

    @MainActor
    private func openActionMenu(in app: XCUIApplication) {
        let actions = app.descendants(matching: .any)["\(actionableProcess).actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        XCTAssertTrue(actions.isEnabled)
        let terminate = app.menuItems["종료…"]
        for attempt in 0..<3 {
            actions.click()
            if terminate.waitForExistence(timeout: 2) { return }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.3) }
        }
        XCTAssertTrue(terminate.waitForExistence(timeout: 1))
    }

    @MainActor
    private func launch(arguments: [String]) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }
}
