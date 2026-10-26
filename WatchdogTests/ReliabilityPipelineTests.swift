import Darwin
import XCTest
@testable import Watchdog

/// End-to-end refresh pipeline, suspension ledger, libproc sampling, and the
/// failure-reporting paths that the earlier preview-only tests never drove.
@MainActor
final class ReliabilityPipelineTests: XCTestCase {
    // MARK: - Refresh pipeline

    func testRefreshPublishesSampleAndEnablesControls() async {
        let process = agent(pid: 8_001, cpu: 10)
        let sampler = ScriptedSampler([.success([process])])
        let monitor = makeMonitor(sampler: sampler)

        await monitor.refresh()

        XCTAssertEqual(monitor.processes.map(\.id), [process.id])
        XCTAssertNil(monitor.samplingError)
        XCTAssertTrue(monitor.actionability(of: process).canAct)
    }

    func testSamplingFailureDisablesControlsAndResetsAlerts() async {
        let process = agent(pid: 8_002, cpu: 300)
        let sampler = ScriptedSampler([
            .success([process]),
            .failure,
        ])
        let monitor = makeMonitor(sampler: sampler)
        monitor.sustainedDuration = 2

        await monitor.refresh()
        await monitor.refresh()

        XCTAssertNotNil(monitor.samplingError)
        XCTAssertFalse(monitor.actionability(of: process).canAct)
        XCTAssertTrue(monitor.hotProcesses.isEmpty)
    }

    func testAutoSuspendThroughRefreshRecordsLedgerAndStaysInAttention() async throws {
        let signals = SignalLog()
        let process = agent(pid: 8_003, cpu: 300)
        let stopped = agent(pid: 8_003, cpu: 0, state: "T")
        let ledger = SuspensionLedger.inMemory()
        let facts = FactsBox(process)
        let sampler = ScriptedSampler([.success([process]), .success([process]), .success([stopped])])
        let monitor = makeMonitor(
            sampler: sampler,
            ledger: ledger,
            controller: controller(facts: facts, signals: signals)
        )
        monitor.sustainedDuration = 2
        monitor.autoSuspendEnabled = true

        await monitor.refresh()
        try await Task.sleep(for: .milliseconds(2_100))
        await monitor.refresh()

        XCTAssertEqual(signals.values.map(\.signal), [SIGSTOP])
        XCTAssertEqual(ledger.all().map(\.identity), [process.identity])
        XCTAssertEqual(ledger.all().first?.source, .auto)

        facts.set(stopped)
        await monitor.refresh()
        XCTAssertTrue(monitor.hotProcesses.isEmpty)
        XCTAssertEqual(monitor.visibleProcesses(scope: .attention, search: "").map(\.id), [process.id])
        XCTAssertTrue(monitor.isSuspendedByWatchdog(stopped))
    }

    func testManualResumeClearsLedgerAndIsRemembered() async throws {
        let signals = SignalLog()
        let stopped = agent(pid: 8_004, cpu: 0, state: "T")
        let ledger = SuspensionLedger.inMemory()
        try ledger.record(
            SuspensionRecord(identity: stopped.identity, executablePath: stopped.executablePath, suspendedAt: Date(), source: .auto)
        )
        let monitor = makeMonitor(
            sampler: ScriptedSampler([.success([stopped])]),
            ledger: ledger,
            controller: controller(facts: FactsBox(stopped), signals: signals)
        )
        await monitor.refresh()

        monitor.resume(stopped)
        for _ in 0..<50 where !ledger.all().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(signals.values.map(\.signal), [SIGCONT])
        XCTAssertTrue(ledger.all().isEmpty)
        XCTAssertEqual(monitor.actionOutcomes[stopped.identity], .resumed)
    }

    func testResumeAllUsesFreshObservationAndClearsLedger() async throws {
        let signals = SignalLog()
        let stopped = agent(pid: 8_005, cpu: 0, state: "T")
        let ledger = SuspensionLedger.inMemory()
        try ledger.record(
            SuspensionRecord(identity: stopped.identity, executablePath: stopped.executablePath, suspendedAt: Date(), source: .manual)
        )
        let facts = FactsBox(stopped)
        let running = agent(pid: 8_005)
        let monitor = makeMonitor(
            sampler: ScriptedSampler([.success([stopped])]),
            ledger: ledger,
            controller: controller(facts: facts, signals: signals, onSignal: { facts.set(running) })
        )

        let result = await monitor.resumeAllWatchdogSuspended()

        XCTAssertEqual(result.resumed, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(signals.values.map(\.signal), [SIGCONT])
        XCTAssertTrue(ledger.all().isEmpty)
    }

    func testDestructiveConfirmationReportsExpiryAndGoneProcessDistinctly() async throws {
        let process = agent(pid: 8_006)
        let monitor = makeMonitor(
            sampler: ScriptedSampler([.success([process]), .success([])]),
            controller: controller(facts: FactsBox(process), signals: SignalLog())
        )
        await monitor.refresh()
        let request = try monitor.destructiveActionRequest(.terminate, for: process)
        XCTAssertTrue(monitor.isConfirmationValid(request))

        await monitor.refresh()
        XCTAssertFalse(monitor.isConfirmationValid(request))
        do {
            try await monitor.completeDestructiveConfirmation(request)
            XCTFail("A confirmation for a vanished process must not complete")
        } catch ProcessControlError.processChanged {
        }
    }

    func testIgnoredProcessReportsIgnoredInsteadOfStale() async {
        let process = agent(pid: 8_007)
        let monitor = makeMonitor(sampler: ScriptedSampler([.success([process])]))
        await monitor.refresh()
        monitor.ignoreUntilExit(process)
        XCTAssertThrowsError(try monitor.destructiveActionRequest(.terminate, for: process)) {
            guard case ProcessControlError.processIgnored = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    // MARK: - Termination verdicts

    func testZombieCountsAsExitedAndFailureIsNotFinal() {
        let identity = agent(pid: 8_010).identity
        let zombie = LiveProcessFacts(identity: identity, executablePath: "", isSuspended: false, isZombie: true)
        XCTAssertEqual(TerminationVerdict.outcome(for: .found(zombie), identity: identity), .exited)
        XCTAssertEqual(TerminationVerdict.outcome(for: .failed, identity: identity), .verificationFailed)
    }

    func testTerminationPollRetriesTransientLookupFailure() async throws {
        let process = agent(pid: 8_011)
        let calls = CallCounter()
        let controller = ProcessController(
            factsReader: { _ in
                // First poll fails mid-exit, the next one finds it gone.
                calls.next() == 1 ? .failed : .absent
            },
            signalSender: { _, _ in 0 }
        )
        let monitor = ProcessMonitor(defaults: makeDefaults(), controller: controller, notificationRequestSender: { _ in })
        monitor.loadActionablePreview(processes: [process], hotProcesses: [], updatedAt: Date())
        monitor.startTerminationPollPreview(for: process.identity)
        for _ in 0..<40 where monitor.actionOutcomes[process.identity] != .exited {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(monitor.actionOutcomes[process.identity], .exited)
    }

    // MARK: - Controller partial application

    func testContinueThenAbortIsReportedAsPartiallyApplied() async throws {
        let process = agent(pid: 8_020, state: "T")
        let changed = ProcessIdentity(pid: process.id, startTimeMicroseconds: 1, userID: process.userID)
        let reads = CallCounter()
        let controller = ProcessController(
            factsReader: { _ in
                // plan check, SIGCONT check, then the identity changes before SIGTERM
                reads.next() <= 2
                    ? .found(LiveProcessFacts(identity: process.identity, executablePath: process.executablePath, isSuspended: true))
                    : .found(LiveProcessFacts(identity: changed, executablePath: process.executablePath, isSuspended: false))
            },
            signalSender: { _, _ in 0 }
        )
        let authorization = ProcessActionAuthorizationActor()
        let instant = ContinuousClock().now
        let nonce = try await authorization.mint(
            action: .terminate,
            identity: process.identity,
            observation: ObservationToken(generation: 1, instant: instant),
            at: instant
        )
        let authorized = try await authorization.consume(nonce, action: .terminate, identity: process.identity, currentGeneration: 1, at: instant)
        XCTAssertThrowsError(try controller.execute(authorized, currentGeneration: 1)) { error in
            guard case let ProcessControlError.partiallyApplied(delivered, failure) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(delivered, [SIGCONT])
            guard case .processChanged = failure else { return XCTFail("Unexpected failure: \(failure)") }
        }
    }

    // MARK: - Ledger

    func testLedgerPersistsAcrossInstancesAndReconciles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("suspensions.json")
        let stopped = agent(pid: 8_030, state: "T")
        let gone = agent(pid: 8_031, state: "T")
        let resumedElsewhere = agent(pid: 8_032)
        let replaced = agent(pid: 8_033, state: "T")

        let writer = SuspensionLedger(fileURL: url)
        for process in [stopped, gone, resumedElsewhere, replaced] {
            try writer.record(
                SuspensionRecord(identity: process.identity, executablePath: process.executablePath, suspendedAt: Date(), source: .cli)
            )
        }

        let reader = SuspensionLedger(fileURL: url)
        XCTAssertEqual(reader.all().count, 4)
        let remaining = try reader.reconcile { pid in
            switch pid {
            case stopped.id:
                return .found(LiveProcessFacts(identity: stopped.identity, executablePath: stopped.executablePath, isSuspended: true))
            case resumedElsewhere.id:
                return .found(LiveProcessFacts(identity: resumedElsewhere.identity, executablePath: "", isSuspended: false))
            case replaced.id:
                return .found(
                    LiveProcessFacts(
                        identity: ProcessIdentity(pid: replaced.id, startTimeMicroseconds: 7, userID: replaced.userID),
                        executablePath: "",
                        isSuspended: true
                    )
                )
            default:
                return .absent
            }
        }
        XCTAssertEqual(remaining.map(\.identity), [stopped.identity])
        XCTAssertEqual(SuspensionLedger(fileURL: url).all().map(\.identity), [stopped.identity])
    }

    func testLedgerSurvivesCorruptFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("suspensions.json")
        try Data("{not json".utf8).write(to: url)
        let ledger = SuspensionLedger(fileURL: url)
        XCTAssertEqual(ledger.all(), [])
        let process = agent(pid: 8_040, state: "T")
        try ledger.record(SuspensionRecord(identity: process.identity, executablePath: "x", suspendedAt: Date(), source: .manual))
        XCTAssertEqual(ledger.all().count, 1)
    }

    // MARK: - Live libproc sampling

    func testLibprocListingMatchesPsForStableProcesses() async throws {
        let rows = try LibprocProcessLister.list()
        let psRows = try await ProcessSampler.psRows { executable, arguments, deadline in
            try await CommandRunner.run(executable, arguments: arguments, deadline: deadline)
        }
        let libproc = Dictionary(rows.map { ($0.snapshot.id, $0.snapshot) }, uniquingKeysWith: { first, _ in first })
        var compared = 0
        var mismatches: [String] = []
        for ps in psRows.map(\.snapshot) where ps.state.first != "Z" {
            guard let mine = libproc[ps.id], mine.startTimeMicroseconds == ps.startTimeMicroseconds || ps.startTimeMicroseconds == 0 else {
                continue
            }
            compared += 1
            // The two enumerations are not atomic: a process can exec,
            // reparent, or stop between them. Count disagreements instead of
            // failing on one, but require near-total agreement.
            if mine.parentPID != ps.parentPID { mismatches.append("\(ps.id) ppid \(ps.parentPID)≠\(mine.parentPID)") }
            if mine.userID != ps.userID { mismatches.append("\(ps.id) uid \(ps.userID)≠\(mine.userID)") }
            if mine.tty != ps.tty { mismatches.append("\(ps.id) tty \(ps.tty)≠\(mine.tty)") }
            if mine.isSuspended != ps.isSuspended { mismatches.append("\(ps.id) stopped \(ps.state)≠\(mine.state)") }
            // Names drive agent and session-host classification, which only
            // matters for this user's processes. For other users ps prints an
            // unresolved launch path or short name where libproc returns the
            // resolved path (and ps mangles non-ASCII paths); both are
            // protected regardless.
            if ps.userID == getuid(), mine.executablePath != ps.executablePath {
                mismatches.append("\(ps.id) comm ps=\(ps.executablePath) libproc=\(mine.executablePath)")
            }
        }
        XCTAssertGreaterThan(compared, 20)
        XCTAssertLessThanOrEqual(mismatches.count, max(3, compared / 100), mismatches.joined(separator: "\n"))

        // Coverage: other users' and root's processes must be enumerated too;
        // orphan classification walks through root-owned ancestors such as
        // `login`. A per-process libproc read silently drops them.
        let psPIDs = Set(psRows.map(\.snapshot).filter { $0.state.first != "Z" }.map(\.id))
        let missing = psPIDs.subtracting(libproc.keys)
        XCTAssertLessThanOrEqual(missing.count, max(3, psPIDs.count / 50), "missing PIDs: \(missing.sorted().prefix(20))")
        XCTAssertNotNil(libproc[1], "launchd (root) must be enumerated")
        XCTAssertTrue(rows.contains { $0.snapshot.userID == 0 }, "root-owned processes must be enumerated")
    }

    func testLibprocSeesCurrentProcessWithWorkingDirectory() throws {
        let rows = try LibprocProcessLister.list()
        let me = try XCTUnwrap(rows.first { $0.snapshot.id == getpid() })
        XCTAssertEqual(me.snapshot.userID, getuid())
        XCTAssertGreaterThan(me.snapshot.startTimeMicroseconds, 0)
        XCTAssertNotNil(me.totalCPUTimeNanoseconds)
        XCTAssertEqual(
            WorkingDirectoryResolver.currentDirectory(pid: getpid()),
            FileManager.default.currentDirectoryPath
        )
    }

    func testMachTicksConvertToNanoseconds() {
        // Apple Silicon timebase 125/3: 24 ticks = 1 µs.
        XCTAssertEqual(MachTime.nanoseconds(fromTicks: 24_000_000, numer: 125, denom: 3), 1_000_000_000)
        XCTAssertEqual(MachTime.nanoseconds(fromTicks: 1_000, numer: 1, denom: 1), 1_000)
        XCTAssertEqual(MachTime.nanoseconds(fromTicks: .max, numer: 125, denom: 3), .max)
    }

    func testBusyThreadMeasuresNearFullCore() async throws {
        let stop = BusyFlag()
        let thread = Thread {
            var counter: UInt64 = 0
            while !stop.isSet { counter &+= 1 }
            _ = counter
        }
        thread.start()
        defer { stop.set() }
        let sampler = ProcessSampler()
        _ = try await sampler.sample()
        try await Task.sleep(for: .milliseconds(1_000))
        let sample = try await sampler.sample()
        let me = try XCTUnwrap(sample.processes.first { $0.id == getpid() })
        // One spinning thread is ~100% of a core. Before the tick conversion
        // this read ~2.4% on Apple Silicon and CPU alerts never fired.
        XCTAssertGreaterThan(me.cpuPercent, 60, "measured \(me.cpuPercent)%")
        XCTAssertLessThan(me.cpuPercent, 400, "measured \(me.cpuPercent)%")
    }

    func testElapsedTextMatchesPsFormat() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(LibprocProcessLister.elapsedText(startSeconds: 1_000_000 - 65, now: now), "01:05")
        XCTAssertEqual(LibprocProcessLister.elapsedText(startSeconds: 1_000_000 - 3_725, now: now), "01:02:05")
        XCTAssertEqual(LibprocProcessLister.elapsedText(startSeconds: 1_000_000 - 90_061, now: now), "1-01:01:01")
    }

    // MARK: - Worktree probes

    func testWorktreeProbeNeverTakesIndexLockAndDoesNotCacheTransientFailure() async {
        let calls = ArgumentLog()
        let resolver = WorktreeStateResolver(
            policy: .init(
                maximumConcurrentLookups: 1,
                lookupDeadline: .milliseconds(100),
                cacheCapacity: 4,
                positiveTTL: .seconds(120),
                negativeTTL: .seconds(60),
                transientTTL: .zero
            ),
            runner: { _, arguments, _ in
                calls.append(arguments)
                throw CommandRunnerError.timedOut(executable: "/usr/bin/git")
            }
        )
        let results = ArgumentLog()
        await resolver.resolve(["/tmp"]) { _, state in
            results.append([state?.isTransient == true ? "transient" : "verdict"])
        }
        await resolver.drainForTesting()
        await resolver.resolve(["/tmp"]) { _, _ in }
        await resolver.drainForTesting()

        XCTAssertEqual(calls.values.count, 2, "a transient failure must be retried, not cached")
        XCTAssertEqual(Array(calls.values.first?.prefix(3) ?? []), ["--no-optional-locks", "-c", "core.fsmonitor=false"])
        XCTAssertEqual(results.values, [["transient"]])
    }

    // MARK: - Helpers

    private func makeMonitor(
        sampler: ScriptedSampler,
        ledger: SuspensionLedger = .inMemory(),
        controller: ProcessController = ProcessController(factsReader: { _ in .failed }, signalSender: { _, _ in 0 })
    ) -> ProcessMonitor {
        ProcessMonitor(
            defaults: makeDefaults(),
            sampler: sampler,
            ledger: ledger,
            controller: controller,
            notificationRequestSender: { _ in }
        )
    }

    private func controller(
        facts: FactsBox,
        signals: SignalLog,
        onSignal: (@Sendable () -> Void)? = nil
    ) -> ProcessController {
        ProcessController(
            factsReader: { _ in
                let process = facts.value
                return .found(
                    LiveProcessFacts(
                        identity: process.identity,
                        executablePath: process.executablePath,
                        isSuspended: process.isSuspended
                    )
                )
            },
            signalSender: { pid, signal in
                signals.record(pid: pid, signal: signal)
                onSignal?()
                return 0
            }
        )
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "dev.justn.watchdog.tests.\(UUID().uuidString)")!
        defaults.set(false, forKey: "notificationsEnabled")
        return defaults
    }

    nonisolated private func agent(pid: Int32, cpu: Double = 0, state: String = "R") -> ProcessSnapshot {
        ProcessSnapshot(
            id: pid,
            parentPID: 600,
            processGroupID: pid,
            userID: getuid(),
            tty: "ttys001",
            cpuPercent: cpu,
            residentBytes: 0,
            state: state,
            elapsed: "00:10",
            executablePath: "/usr/local/bin/claude",
            startTimeMicroseconds: UInt64(pid) * 1_000_000
        )
    }
}

/// Returns scripted samples in order, repeating the last one.
private actor ScriptedSampler: ProcessSampling {
    enum Step {
        case success([ProcessSnapshot])
        case failure
    }

    private var steps: [Step]

    init(_ steps: [Step]) {
        self.steps = steps
    }

    func sample() async throws -> ProcessSample {
        let step = steps.count > 1 ? steps.removeFirst() : steps[0]
        switch step {
        case let .success(processes):
            return ProcessSample(processes: processes, systemCPUPercent: 10, systemMemory: nil)
        case .failure:
            throw CommandRunnerError.timedOut(executable: "sampler")
        }
    }
}

private final class BusyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isSet: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
}

private final class FactsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: ProcessSnapshot

    init(_ process: ProcessSnapshot) { self.process = process }
    var value: ProcessSnapshot { lock.withLock { process } }
    func set(_ process: ProcessSnapshot) { lock.withLock { self.process = process } }
}

private final class SignalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(pid: Int32, signal: Int32)] = []

    var values: [(pid: Int32, signal: Int32)] { lock.withLock { storage } }
    func record(pid: Int32, signal: Int32) { lock.withLock { storage.append((pid, signal)) } }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int { lock.withLock { count += 1; return count } }
}

private final class ArgumentLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String]] = []

    var values: [[String]] { lock.withLock { storage } }
    func append(_ value: [String]) { lock.withLock { storage.append(value) } }
}
