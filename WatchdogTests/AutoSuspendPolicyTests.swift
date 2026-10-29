import Darwin
import XCTest
@testable import Watchdog

/// Tests for the auto-suspend policy: only newly flagged processes are
/// SIGSTOPed, suspended or protected ones are skipped, and every signal goes
/// through the standard authorization pipeline.
@MainActor
final class AutoSuspendPolicyTests: XCTestCase {
    func testAutoSuspendSendsSIGSTOPToNewlyHotProcessWhenEnabled() async throws {
        let signals = SignalRecorder()
        let process = snapshot(pid: 7_001, name: "/usr/local/bin/claude", cpu: 180)
        let controller = makeController(signals: signals, facts: process)
        let monitor = ProcessMonitor(defaults: makeDefaults(), controller: controller)
        monitor.autoSuspendEnabled = true

        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        await monitor.refreshAutoSuspendPreview(
            hot: [process.identity],
            highMemory: [],
            snapshots: [process]
        )

        let recorded = signals.values
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.pid, process.id)
        XCTAssertEqual(recorded.first?.signal, SIGSTOP)
    }

    func testAutoSuspendDisabledSendsNoSignals() async throws {
        let signals = SignalRecorder()
        let process = snapshot(pid: 7_002, name: "/usr/local/bin/claude", cpu: 180)
        let controller = makeController(signals: signals, facts: process)
        let monitor = ProcessMonitor(defaults: makeDefaults(), controller: controller)
        monitor.autoSuspendEnabled = false

        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        await monitor.refreshAutoSuspendPreview(
            hot: [process.identity],
            highMemory: [],
            snapshots: [process]
        )

        let recorded = signals.values
        XCTAssertTrue(recorded.isEmpty)
    }

    func testAutoSuspendSkipsProtectedProcesses() async throws {
        let signals = SignalRecorder()
        // System-path processes are protected and must never be signaled.
        let process = snapshot(pid: 7_003, name: "/usr/sbin/systemd-helper", cpu: 180)
        let controller = makeController(signals: signals, facts: process)
        let monitor = ProcessMonitor(defaults: makeDefaults(), controller: controller)
        monitor.autoSuspendEnabled = true

        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        await monitor.refreshAutoSuspendPreview(
            hot: [process.identity],
            highMemory: [],
            snapshots: [process]
        )

        let recorded = signals.values
        XCTAssertTrue(recorded.isEmpty)
    }

    func testAutoSuspendSkipsAlreadySuspendedProcesses() async throws {
        let signals = SignalRecorder()
        let process = snapshot(pid: 7_004, name: "/usr/local/bin/claude", cpu: 180, state: "T")
        let controller = makeController(signals: signals, facts: process)
        let monitor = ProcessMonitor(defaults: makeDefaults(), controller: controller)
        monitor.autoSuspendEnabled = true

        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        await monitor.refreshAutoSuspendPreview(
            hot: [process.identity],
            highMemory: [],
            snapshots: [process]
        )

        let recorded = signals.values
        XCTAssertTrue(recorded.isEmpty)
    }

    func testSessionGroupStopsRootThenMembersAndRecordsGroupID() async throws {
        let signals = SignalRecorder()
        let root = snapshot(pid: 7_010, name: "/usr/local/bin/claude", cpu: 10)
        let childA = snapshot(pid: 7_011, name: "/usr/bin/yes", cpu: 50)
        let childB = snapshot(pid: 7_012, name: "/usr/bin/yes", cpu: 50)
        let ledger = SuspensionLedger.inMemory()
        let controller = makeController(signals: signals, processes: [root, childA, childB])
        let monitor = ProcessMonitor(defaults: makeDefaults(), ledger: ledger, controller: controller)
        monitor.autoSuspendEnabled = true
        monitor.autoSuspendScope = .session

        let snapshots = [root, childA, childB]
        monitor.loadActionablePreview(processes: snapshots, hotProcesses: [], updatedAt: Date())
        await monitor.refreshAutoSuspendPreview(
            hot: [],
            highMemory: [],
            snapshots: snapshots,
            autoSuspendGroups: [
                AutoSuspendGroup(root: root.identity, members: [childA, childB])
            ],
            sessions: [
                AgentSession(
                    id: root.identity,
                    rootPID: root.id,
                    name: "claude",
                    kind: .agent,
                    workingDirectory: nil,
                    projectName: nil,
                    members: [childA.identity, childB.identity],
                    memberCount: 2,
                    cpuPercent: 110,
                    residentBytes: 0,
                    isSuspended: false,
                    elapsed: "00:10"
                )
            ]
        )

        XCTAssertEqual(signals.values.map(\.pid), [root.id, childA.id, childB.id])
        XCTAssertEqual(signals.values.map(\.signal), [SIGSTOP, SIGSTOP, SIGSTOP])
        let groupID = IdentityToken(root.identity).description
        XCTAssertEqual(Set(ledger.all().map(\.groupID)), [groupID])
        XCTAssertEqual(ledger.all().count, 3)
    }

    func testResumingSessionRootResumesGroupedMembers() async throws {
        let signals = SignalRecorder()
        let root = snapshot(pid: 7_020, name: "/usr/local/bin/claude", state: "T")
        let childA = snapshot(pid: 7_021, name: "/usr/bin/yes", state: "T")
        let childB = snapshot(pid: 7_022, name: "/usr/bin/yes", state: "T")
        let ledger = SuspensionLedger.inMemory()
        let groupID = IdentityToken(root.identity).description
        for process in [root, childA, childB] {
            try ledger.record(
                SuspensionRecord(
                    identity: process.identity,
                    executablePath: process.executablePath,
                    suspendedAt: Date(),
                    source: .auto,
                    groupID: groupID
                )
            )
        }
        let controller = makeController(signals: signals, processes: [root, childA, childB])
        let monitor = ProcessMonitor(defaults: makeDefaults(), ledger: ledger, controller: controller)
        monitor.loadActionablePreview(processes: [root, childA, childB], hotProcesses: [], updatedAt: Date())

        monitor.resume(root)
        for _ in 0..<50 where ledger.all().count > 0 {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(signals.values.map(\.signal), [SIGCONT, SIGCONT, SIGCONT])
        XCTAssertEqual(Set(signals.values.map(\.pid)), [root.id, childA.id, childB.id])
        XCTAssertTrue(ledger.all().isEmpty)
    }

    func testAutoSuspendedProcessRemainsReachableForManualResume() async throws {
        let signals = SignalRecorder()
        let running = snapshot(pid: 7_005, name: "/usr/local/bin/claude", cpu: 180)
        let controller = makeController(signals: signals, facts: running)
        let monitor = ProcessMonitor(defaults: makeDefaults(), controller: controller)
        monitor.autoSuspendEnabled = true

        monitor.loadActionablePreview(processes: [running], hotProcesses: [], updatedAt: Date())
        await monitor.refreshAutoSuspendPreview(
            hot: [running.identity],
            highMemory: [],
            snapshots: [running]
        )

        let suspended = snapshot(pid: running.id, name: running.executablePath, state: "T")
        monitor.loadActionablePreview(processes: [suspended], hotProcesses: [], updatedAt: Date())

        XCTAssertEqual(monitor.visibleProcesses(scope: .all, search: ""), [suspended])
        XCTAssertTrue(monitor.actionability(of: suspended).canAct)
    }

    // MARK: - Helpers

    private func makeController(
        signals: SignalRecorder,
        facts process: ProcessSnapshot
    ) -> ProcessController {
        makeController(signals: signals, processes: [process])
    }

    private func makeController(
        signals: SignalRecorder,
        processes: [ProcessSnapshot]
    ) -> ProcessController {
        let box = ProcessFactsBox(processes)
        return ProcessController(
            factsReader: { pid in box.lookup(pid) },
            signalSender: { pid, signal in
                signals.record(pid: pid, signal: signal)
                box.apply(pid: pid, signal: signal)
                return 0
            }
        )
    }

    private func makeDefaults() -> UserDefaults {
        // One fixed suite, cleared per test: a per-test UUID suite leaves a plist
        // in ~/Library/Preferences on every run. XCTest runs these serially.
        let suiteName = "dev.justn.watchdog.tests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(false, forKey: "notificationsEnabled")
        return defaults
    }

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

private final class ProcessFactsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Int32: ProcessSnapshot]
    private var stopped: [Int32: Bool]

    init(_ processes: [ProcessSnapshot]) {
        self.processes = Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) })
        stopped = Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0.isSuspended) })
    }

    func lookup(_ pid: Int32) -> LiveProcessLookup {
        lock.withLock {
            guard let process = processes[pid] else { return .absent }
            return .found(
                LiveProcessFacts(
                    identity: process.identity,
                    executablePath: process.executablePath,
                    isSuspended: stopped[pid] ?? process.isSuspended
                )
            )
        }
    }

    func apply(pid: Int32, signal: Int32) {
        lock.withLock {
            if signal == SIGSTOP { stopped[pid] = true }
            if signal == SIGCONT { stopped[pid] = false }
        }
    }
}
