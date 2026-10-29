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
        XCTAssertTrue(version.waitForExistence(timeout: 2))

        let copyright = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '2026 justn-hyeok' OR value CONTAINS '2026 justn-hyeok'")
        ).firstMatch
        XCTAssertTrue(copyright.exists)
    }

    @MainActor
    func testSearchShowsNoMatchState() {
        let app = launch(arguments: ["--ui-test-fixture"])
        defer { app.terminate() }
        let searchField = app.textFields["watchdog.search"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        searchField.click()
        searchField.typeText("fixture-with-no-matching-process")

        XCTAssertTrue(app.staticTexts["검색 결과가 없습니다"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["다른 프로세스 이름, PID 또는 프로젝트를 검색해보세요."].exists)
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
        XCTAssertEqual(suspend.label, "프로세스 일시 정지")
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
        let agentsScope = app.radioButtons["에이전트"]
        XCTAssertTrue(agentsScope.waitForExistence(timeout: 2))
        agentsScope.click()
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
        let scope = app.radioButtons["전체"]
        XCTAssertTrue(scope.waitForExistence(timeout: 5))
        scope.click()

        let first = app.descendants(matching: .any)["process.71001.9071001.row"]
        let second = app.descendants(matching: .any)["process.71002.9071002.row"]
        XCTAssertTrue(first.waitForExistence(timeout: 6))
        XCTAssertTrue(second.waitForExistence(timeout: 2))

        let initialOrder = first.frame.minY < second.frame.minY
        func firstRowIsBusy() -> Bool { first.staticTexts["90%"].exists }
        let initiallyBusy = firstRowIsBusy()
        var sawRefresh = false
        for _ in 0..<14 {
            Thread.sleep(forTimeInterval: 0.5)
            XCTAssertEqual(first.frame.minY < second.frame.minY, initialOrder, "rows traded places while shown")
            if firstRowIsBusy() != initiallyBusy { sawRefresh = true }
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
    private func openActionMenu(in app: XCUIApplication) {
        let actions = app.descendants(matching: .any)["\(actionableProcess).actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        XCTAssertTrue(actions.isEnabled)
        actions.click()
        XCTAssertTrue(app.menuItems["종료…"].waitForExistence(timeout: 2))
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
