import Darwin
import XCTest
@testable import Watchdog

@MainActor
final class JournalPresentationTests: XCTestCase {
    func testSourceLabels() {
        XCTAssertEqual(JournalPresentation.sourceLabel(.app), "앱")
        XCTAssertEqual(JournalPresentation.sourceLabel(.auto), "자동")
        XCTAssertEqual(JournalPresentation.sourceLabel(.cli), "CLI")
    }

    func testActionLabels() {
        XCTAssertEqual(JournalPresentation.actionLabel(.suspend), "일시 정지")
        XCTAssertEqual(JournalPresentation.actionLabel(.resume), "재개")
        XCTAssertEqual(JournalPresentation.actionLabel(.terminate), "종료")
        XCTAssertEqual(JournalPresentation.actionLabel(.forceQuit), "강제 종료")
    }

    func testOutcomeLabels() {
        XCTAssertEqual(JournalPresentation.outcomeLabel("suspended"), "멈춤")
        XCTAssertEqual(JournalPresentation.outcomeLabel("resumed"), "재개됨")
        XCTAssertEqual(JournalPresentation.outcomeLabel("awaitingExit"), "종료 대기")
        XCTAssertEqual(JournalPresentation.outcomeLabel("exited"), "종료됨")
        XCTAssertEqual(JournalPresentation.outcomeLabel("stillRunning"), "아직 실행 중")
        XCTAssertEqual(JournalPresentation.outcomeLabel("identityChanged"), "다른 프로세스로 바뀜")
        XCTAssertEqual(JournalPresentation.outcomeLabel("verificationFailed"), "확인 실패")
        XCTAssertEqual(JournalPresentation.outcomeLabel("signalDelivered"), "신호 전달됨")
        XCTAssertEqual(JournalPresentation.outcomeLabel("failed:권한 없음"), "실패: 권한 없음")
        XCTAssertEqual(
            JournalPresentation.outcomeLabel(ActionJournalEntry.outcomeString(.failed("pipe"))),
            "실패: pipe"
        )
    }

    func testUndoTargetWhenStillSuspended() throws {
        let process = snapshot(pid: 8_001)
        let monitor = makeMonitor(process: process)
        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        let entry = suspendEntry(process: process, outcome: "suspended")
        monitor.loadJournalDisplayPreview(
            entries: [entry],
            suspended: [record(process)]
        )

        XCTAssertEqual(monitor.undoTarget(for: entry)?.identity, process.identity)
    }

    func testUndoTargetNilWhenAlreadyResumed() throws {
        let process = snapshot(pid: 8_002)
        let monitor = makeMonitor(process: process)
        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        let suspend = suspendEntry(process: process, outcome: "suspended")
        let resume = ActionJournalEntry(
            source: .app,
            action: .resume,
            pid: process.id,
            startTimeMicroseconds: process.startTimeMicroseconds,
            userID: process.userID,
            executablePath: process.executablePath,
            displayName: process.displayName,
            outcome: "resumed",
            undoOf: suspend.id
        )
        monitor.loadJournalDisplayPreview(
            entries: [suspend, resume],
            suspended: [record(process)]
        )

        XCTAssertNil(monitor.undoTarget(for: suspend))
        XCTAssertNil(monitor.undoTarget(for: resume))
    }

    func testUndoTargetNilWhenMissingFromLedger() throws {
        let process = snapshot(pid: 8_003)
        let monitor = makeMonitor(process: process)
        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        let entry = suspendEntry(process: process, outcome: "suspended")
        monitor.loadJournalDisplayPreview(entries: [entry], suspended: [])

        XCTAssertNil(monitor.undoTarget(for: entry))
    }

    func testUndoTargetNilWhenProcessMissingFromList() throws {
        let process = snapshot(pid: 8_004)
        let other = snapshot(pid: 8_005)
        let monitor = makeMonitor(process: process)
        monitor.loadActionablePreview(processes: [other], hotProcesses: [], updatedAt: Date())
        let entry = suspendEntry(process: process, outcome: "suspended")
        monitor.loadJournalDisplayPreview(
            entries: [entry],
            suspended: [record(process)]
        )

        XCTAssertNil(monitor.undoTarget(for: entry))
    }

    private func makeMonitor(process: ProcessSnapshot) -> ProcessMonitor {
        let defaults = UserDefaults(suiteName: "dev.justn.watchdog.tests.journal-presentation")!
        defaults.removePersistentDomain(forName: "dev.justn.watchdog.tests.journal-presentation")
        defaults.set(false, forKey: "notificationsEnabled")
        return ProcessMonitor(
            defaults: defaults,
            ledger: .inMemory(),
            journal: .inMemory(),
            controller: ProcessController(
                factsReader: { _ in
                    .found(
                        LiveProcessFacts(
                            identity: process.identity,
                            executablePath: process.executablePath,
                            isSuspended: process.isSuspended
                        )
                    )
                },
                signalSender: { _, _ in 0 }
            ),
            notificationRequestSender: { _ in }
        )
    }

    private func snapshot(pid: Int32) -> ProcessSnapshot {
        ProcessSnapshot(
            id: pid,
            parentPID: 2,
            processGroupID: pid,
            userID: getuid(),
            tty: "ttys001",
            cpuPercent: 12,
            residentBytes: 0,
            state: "T",
            elapsed: "00:10",
            executablePath: "/usr/local/bin/claude",
            startTimeMicroseconds: UInt64(pid) * 1_000_000,
            workingDirectory: nil
        )
    }

    private func suspendEntry(process: ProcessSnapshot, outcome: String) -> ActionJournalEntry {
        ActionJournalEntry(
            source: .auto,
            action: .suspend,
            pid: process.id,
            startTimeMicroseconds: process.startTimeMicroseconds,
            userID: process.userID,
            executablePath: process.executablePath,
            displayName: process.displayName,
            reason: "CPU 184% 지속 25초",
            outcome: outcome
        )
    }

    private func record(_ process: ProcessSnapshot) -> SuspensionRecord {
        SuspensionRecord(
            identity: process.identity,
            executablePath: process.executablePath,
            suspendedAt: Date(),
            source: .auto
        )
    }
}
