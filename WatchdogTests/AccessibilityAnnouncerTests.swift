import Combine
import Darwin
import Foundation
import XCTest
@testable import Watchdog

@MainActor
final class AccessibilityAnnouncerTests: XCTestCase {
    func testAnnouncesActionFeedbackChanges() {
        let monitor = makeMonitor()
        var announced: [String] = []
        let announcer = AccessibilityAnnouncer(monitor: monitor, announce: { announced.append($0) })

        monitor.undo(unmatchedSuspendEntry())

        XCTAssertEqual(
            announced,
            ["되돌릴 수 없습니다: 이미 재개됐거나 종료된 프로세스입니다"]
        )
        _ = announcer
    }

    func testSuppressesDuplicateAnnouncementWithinOneSecond() {
        let monitor = makeMonitor()
        var announced: [String] = []
        var now = Date(timeIntervalSince1970: 1_000)
        let announcer = AccessibilityAnnouncer(
            monitor: monitor,
            now: { now },
            announce: { announced.append($0) }
        )
        let entry = unmatchedSuspendEntry()

        monitor.undo(entry)
        now = now.addingTimeInterval(0.4)
        monitor.undo(entry)

        XCTAssertEqual(announced.count, 1)

        now = now.addingTimeInterval(0.7)
        monitor.undo(entry)

        XCTAssertEqual(announced.count, 2)
        XCTAssertEqual(
            Set(announced),
            ["되돌릴 수 없습니다: 이미 재개됐거나 종료된 프로세스입니다"]
        )
        _ = announcer
    }

    private func makeMonitor() -> ProcessMonitor {
        let suiteName = "dev.justn.watchdog.tests.ax"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "notificationsEnabled")
        return ProcessMonitor(defaults: defaults, notificationRequestSender: { _ in })
    }

    private func unmatchedSuspendEntry() -> ActionJournalEntry {
        ActionJournalEntry(
            id: UUID(),
            at: Date(),
            source: .app,
            action: .suspend,
            pid: 71_001,
            startTimeMicroseconds: 9_071_001,
            userID: getuid(),
            executablePath: "/usr/local/bin/claude",
            displayName: "claude",
            outcome: "suspended"
        )
    }
}
