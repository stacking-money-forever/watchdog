import Darwin
import XCTest
@testable import Watchdog

final class ActionJournalTests: XCTestCase {
    func testAppendThenRecentIsNewestFirst() throws {
        let journal = ActionJournal.inMemory()
        let first = entry(pid: 1, outcome: "suspended")
        let second = entry(pid: 2, outcome: "resumed")
        try journal.append(first)
        try journal.append(second)

        XCTAssertEqual(journal.all().map(\.id), [first.id, second.id])
        XCTAssertEqual(journal.recent(limit: 1).map(\.id), [second.id])
        XCTAssertEqual(journal.recent(limit: 2).map(\.id), [second.id, first.id])
    }

    func testCorruptLinesAreSkipped() throws {
        let url = temporaryJournalURL()
        defer { removeJournal(url) }
        let good = entry(pid: 11, outcome: "suspended")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var payload = Data("{not json\n".utf8)
        payload.append(try encoder.encode(good))
        payload.append(0x0A)
        payload.append(contentsOf: "{\"id\":1}\n".utf8)
        try payload.write(to: url)

        let journal = ActionJournal(fileURL: url)
        XCTAssertEqual(journal.all().map(\.id), [good.id])
        XCTAssertEqual(journal.recent(limit: 5).map(\.id), [good.id])
    }

    func testRollingKeepsNewestTwoThousandLines() throws {
        let url = temporaryJournalURL()
        defer { removeJournal(url) }
        let journal = ActionJournal(fileURL: url)
        var ids: [UUID] = []
        ids.reserveCapacity(ActionJournal.compactThreshold + 1)
        for index in 0...ActionJournal.compactThreshold {
            let item = entry(pid: Int32(index + 1), outcome: "suspended")
            ids.append(item.id)
            try journal.append(item)
        }

        let remaining = journal.all()
        XCTAssertEqual(remaining.count, ActionJournal.compactKeep)
        XCTAssertEqual(remaining.map(\.id), Array(ids.suffix(ActionJournal.compactKeep)))
        XCTAssertEqual(physicalLineCount(url), ActionJournal.compactKeep)
        XCTAssertNil(remaining.first { $0.id == ids[0] })
    }

    func testUpdateReplacesOnlyMatchingLine() throws {
        let url = temporaryJournalURL()
        defer { removeJournal(url) }
        let journal = ActionJournal(fileURL: url)
        let first = entry(action: .terminate, pid: 21, outcome: "awaitingExit")
        let second = entry(action: .suspend, pid: 22, outcome: "suspended")
        try journal.append(first)
        try journal.append(second)

        try journal.update(id: first.id, outcome: "exited")

        let entries = journal.all()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].id, first.id)
        XCTAssertEqual(entries[0].outcome, "exited")
        XCTAssertEqual(entries[1].id, second.id)
        XCTAssertEqual(entries[1].outcome, "suspended")
        XCTAssertEqual(entries[1].action, .suspend)
    }

    func testStandardUsesEnvironmentOverride() throws {
        let url = temporaryJournalURL()
        defer { removeJournal(url) }
        let journal = ActionJournal.standard(
            environment: [ActionJournal.pathEnvironmentKey: url.path]
        )
        let item = entry(pid: 31, outcome: "resumed")
        try journal.append(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(journal.recent(limit: 1).first?.id, item.id)
        XCTAssertEqual(journal.recent(limit: 1).first?.source, .cli)
    }

    func testTwoInstancesInterleavedAppendsStayValidJSONL() throws {
        let url = temporaryJournalURL()
        defer { removeJournal(url) }
        let failures = FailureLog()

        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let journal = ActionJournal(fileURL: url)
            for step in 0..<200 {
                let item = entry(pid: Int32(index * 1_000 + step + 1), outcome: "suspended")
                do {
                    try journal.append(item)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
        }

        XCTAssertTrue(failures.values.isEmpty, failures.values.joined(separator: "; "))
        XCTAssertEqual(physicalLineCount(url), 400)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 400)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in lines {
            let data = Data(line.utf8)
            XCTAssertNoThrow(try decoder.decode(ActionJournalEntry.self, from: data))
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        }
        XCTAssertEqual(ActionJournal(fileURL: url).all().count, 400)
    }

    @MainActor
    func testAutoSuspendWritesAutoSourceAndCPUReason() async throws {
        let signals = SignalRecorder()
        let process = snapshot(pid: 9_001, name: "/usr/local/bin/claude", cpu: 184)
        let journal = ActionJournal.inMemory()
        let monitor = ProcessMonitor(
            defaults: makeDefaults(),
            journal: journal,
            controller: makeController(signals: signals, facts: process)
        )
        monitor.autoSuspendEnabled = true
        monitor.sustainedDuration = 25

        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        await monitor.refreshAutoSuspendPreview(
            hot: [process.identity],
            highMemory: [],
            snapshots: [process]
        )

        XCTAssertEqual(signals.values.count, 1)
        let entries = journal.all()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.source, .auto)
        XCTAssertEqual(entries.first?.action, .suspend)
        XCTAssertEqual(entries.first?.outcome, "suspended")
        XCTAssertTrue(entries.first?.reason?.contains("CPU") == true, entries.first?.reason ?? "")
    }

    @MainActor
    func testManualSuspendThenResumeWritesTwoAppEntries() async throws {
        let signals = SignalRecorder()
        let process = snapshot(pid: 9_002, name: "/usr/local/bin/claude", cpu: 12)
        let journal = ActionJournal.inMemory()
        let monitor = ProcessMonitor(
            defaults: makeDefaults(),
            journal: journal,
            controller: makeController(signals: signals, facts: process)
        )

        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        monitor.suspend(process)
        await waitUntil { journal.all().count == 1 }

        monitor.resume(process)
        await waitUntil { journal.all().count == 2 }

        let entries = journal.all()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.source), [.app, .app])
        XCTAssertEqual(entries.map(\.action), [.suspend, .resume])
        XCTAssertEqual(entries.map(\.outcome), ["suspended", "resumed"])
        XCTAssertEqual(entries[1].undoOf, entries[0].id)
        XCTAssertEqual(signals.values.map(\.signal), [SIGSTOP, SIGCONT])
    }

    // MARK: - Helpers

    private func entry(
        action: ActionJournalEntry.ActionKind = .suspend,
        pid: Int32,
        outcome: String
    ) -> ActionJournalEntry {
        ActionJournalEntry(
            source: .cli,
            action: action,
            pid: pid,
            startTimeMicroseconds: UInt64(pid) * 1_000,
            userID: 501,
            executablePath: "/bin/sleep",
            displayName: "sleep",
            workingDirectory: nil,
            reason: nil,
            outcome: outcome,
            undoOf: nil
        )
    }

    private func temporaryJournalURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-journal-\(UUID().uuidString).jsonl")
    }

    private func removeJournal(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("lock"))
    }

    private func physicalLineCount(_ url: URL) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(whereSeparator: \.isNewline).count
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: () -> Bool
    ) async {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while !predicate(), ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func makeController(
        signals: SignalRecorder,
        facts process: ProcessSnapshot
    ) -> ProcessController {
        ProcessController(
            factsReader: { _ in
                .found(
                    LiveProcessFacts(
                        identity: process.identity,
                        executablePath: process.executablePath,
                        isSuspended: process.isSuspended
                    )
                )
            },
            signalSender: { pid, signal in
                signals.record(pid: pid, signal: signal)
                return 0
            }
        )
    }

    @MainActor
    private func makeDefaults() -> UserDefaults {
        let suiteName = "dev.justn.watchdog.tests.journal"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "notificationsEnabled")
        return defaults
    }

    @MainActor
    private func snapshot(
        pid: Int32,
        name: String,
        cpu: Double = 0,
        state: String = "R"
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            id: pid,
            parentPID: 2,
            processGroupID: pid,
            userID: getuid(),
            tty: "ttys001",
            cpuPercent: cpu,
            residentBytes: 0,
            state: state,
            elapsed: "00:10",
            executablePath: name,
            startTimeMicroseconds: UInt64(pid) * 1_000_000,
            workingDirectory: nil
        )
    }
}

private final class FailureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ message: String) {
        lock.withLock { storage.append(message) }
    }
}

private final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(pid: Int32, signal: Int32)] = []

    var values: [(pid: Int32, signal: Int32)] {
        lock.withLock { storage }
    }

    func record(pid: Int32, signal: Int32) {
        lock.withLock {
            storage.append((pid: pid, signal: signal))
        }
    }
}
