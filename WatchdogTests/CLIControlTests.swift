import Darwin
import XCTest
@testable import Watchdog

/// `--force` danger policy and the CLI control pipeline.
final class CLIControlTests: XCTestCase {
    private let me = getuid()

    // MARK: - Tokens

    func testIdentityTokenRoundTripsAndRejectsMalformedInput() {
        let identity = ProcessIdentity(pid: 4_123, startTimeMicroseconds: 1_761_483_670_123_456, userID: 501)
        let token = IdentityToken(identity)
        XCTAssertEqual(token.description, "4123:1761483670123456:501")
        XCTAssertEqual(IdentityToken(parsing: token.description)?.identity, identity)
        for bad in ["", "4123", "4123:1", "a:b:c", "0:1:2", "-5:1:2", "1:2:3:4", "4123::501"] {
            XCTAssertNil(IdentityToken(parsing: bad), bad)
        }
        XCTAssertEqual(CLITarget(parsing: "4123"), .pid(4_123))
        XCTAssertNil(CLITarget(parsing: "claude"))
    }

    // MARK: - Policy

    func testDestructiveActionsRequireTokenAndForce() {
        let live = agent(pid: 5_000)
        let token = CLITarget.token(IdentityToken(live.identity))
        for action in [CLIAction.terminate, .forceQuit] {
            guard case .usage = CLIPolicy.evaluate(action: action, target: .pid(5_000), live: live, force: true) else {
                return XCTFail("\(action) must refuse a bare PID")
            }
            guard case let .blocked(dryRun) = CLIPolicy.evaluate(action: action, target: token, live: live, force: false) else {
                return XCTFail("\(action) must be blocked without --force")
            }
            XCTAssertTrue(dryRun.contains(token.pid.description))
            XCTAssertEqual(CLIPolicy.evaluate(action: action, target: token, live: live, force: false).exitCode, CLIExitCode.blocked)
            XCTAssertEqual(CLIPolicy.evaluate(action: action, target: token, live: live, force: true), .allow(warnings: []))
        }
    }

    func testReversibleActionsRunButWarnForNonAgents() {
        let app = snapshot(pid: 5_001, path: "/Applications/Xcode.app/Contents/MacOS/Xcode")
        guard case let .allow(warnings) = CLIPolicy.evaluate(action: .suspend, target: .pid(5_001), live: app, force: false) else {
            return XCTFail("suspend must run")
        }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(CLIPolicy.evaluate(action: .suspend, target: .pid(5_001), live: app, force: true), .allow(warnings: []))
        XCTAssertEqual(CLIPolicy.evaluate(action: .suspend, target: .pid(5_002), live: agent(pid: 5_002), force: false), .allow(warnings: []))
    }

    func testSafetyRefusalsCannotBeForced() {
        let mismatched = agent(pid: 5_010)
        let staleToken = CLITarget.token(
            IdentityToken(ProcessIdentity(pid: 5_010, startTimeMicroseconds: 1, userID: me))
        )
        var otherUser = agent(pid: 5_011)
        otherUser = ProcessSnapshot(
            id: otherUser.id, parentPID: 1, processGroupID: otherUser.id, userID: me &+ 1, tty: "??",
            cpuPercent: 0, residentBytes: 0, state: "R", elapsed: "00:01",
            executablePath: otherUser.executablePath, startTimeMicroseconds: 9
        )
        let system = snapshot(pid: 5_012, path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock")
        let unverifiable = ProcessSnapshot(
            id: 5_013, parentPID: 1, processGroupID: 5_013, userID: me, tty: "??",
            cpuPercent: 0, residentBytes: 0, state: "R", elapsed: "00:01",
            executablePath: "/usr/local/bin/claude", startTimeMicroseconds: 0
        )

        let cases: [(CLITarget, ProcessSnapshot?, CLIRefusal)] = [
            (.pid(1), nil, .launchd),
            (.pid(getpid()), nil, .watchdogItself),
            (.pid(5_099), nil, .notFound),
            (staleToken, mismatched, .identityMismatch(live: mismatched.identity)),
            (.pid(5_011), otherUser, .otherUser(uid: me &+ 1)),
            (.pid(5_012), system, .systemPath(system.executablePath)),
            (.pid(5_013), unverifiable, .unverifiableStartTime),
        ]
        for (target, live, refusal) in cases {
            for action in CLIAction.allCases {
                let resolvedTarget: CLITarget
                if action.isDestructive, case let .pid(pid) = target {
                    resolvedTarget = .token(
                        IdentityToken(live?.identity ?? ProcessIdentity(pid: pid, startTimeMicroseconds: 5, userID: me))
                    )
                } else {
                    resolvedTarget = target
                }
                let decision = CLIPolicy.evaluate(action: action, target: resolvedTarget, live: live, force: true)
                XCTAssertEqual(decision, .refused(refusal), "\(action) \(target)")
                XCTAssertEqual(decision.exitCode, CLIExitCode.refused)
            }
        }
    }

    // MARK: - Control pipeline

    func testSuspendRecordsLedgerAndVerifiesStoppedState() async throws {
        let process = agent(pid: 5_100)
        let world = FakeWorld(process)
        let ledger = SuspensionLedger.inMemory()
        let control = world.control(ledger: ledger)

        let result = try await control.run(.suspend, target: .token(IdentityToken(process.identity)), force: false)

        guard case let .performed(report) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(report.outcome, .suspended)
        XCTAssertEqual(world.signals, [SIGSTOP])
        XCTAssertEqual(ledger.all().map(\.identity), [process.identity])
        XCTAssertEqual(ledger.all().first?.source, .cli)

        let resumed = try await control.run(.resume, target: .pid(process.id), force: false)
        guard case let .performed(resumeReport) = resumed else { return XCTFail("\(resumed)") }
        XCTAssertEqual(resumeReport.outcome, .resumed)
        XCTAssertEqual(world.signals, [SIGSTOP, SIGCONT])
        XCTAssertTrue(ledger.all().isEmpty)
    }

    func testBlockedTerminateSendsNothing() async throws {
        let process = agent(pid: 5_101)
        let world = FakeWorld(process)
        let result = try await world.control().run(.terminate, target: .token(IdentityToken(process.identity)), force: false)
        guard case .decided(.blocked) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(world.signals.isEmpty)
    }

    func testForcedTerminateVerifiesExit() async throws {
        let process = agent(pid: 5_102)
        let world = FakeWorld(process, exitsOn: SIGTERM)
        let result = try await world.control().run(.terminate, target: .token(IdentityToken(process.identity)), force: true)
        guard case let .performed(report) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(world.signals, [SIGTERM])
        XCTAssertEqual(report.outcome, .exited)
    }

    func testTerminateIgnoredBySIGTERMReportsStillRunning() async throws {
        let process = agent(pid: 5_103)
        let world = FakeWorld(process)
        let result = try await world.control(pollAttempts: 3).run(.terminate, target: .token(IdentityToken(process.identity)), force: true)
        guard case let .performed(report) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(report.outcome, .stillRunning)
        XCTAssertTrue(report.outcome.isError)
    }

    func testPIDReuseBetweenListAndActionIsRefused() async throws {
        let original = agent(pid: 5_104)
        let reused = ProcessSnapshot(
            id: original.id, parentPID: 600, processGroupID: original.id, userID: me, tty: "ttys001",
            cpuPercent: 0, residentBytes: 0, state: "R", elapsed: "00:01",
            executablePath: "/Applications/Slack.app/Contents/MacOS/Slack", startTimeMicroseconds: original.startTimeMicroseconds + 99
        )
        let world = FakeWorld(reused)
        let result = try await world.control().run(.forceQuit, target: .token(IdentityToken(original.identity)), force: true)
        guard case .decided(.refused(.identityMismatch)) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(world.signals.isEmpty)
    }

    func testIdentityChangeAfterObservationIsRefusedByController() async throws {
        let process = agent(pid: 5_105)
        let world = FakeWorld(process)
        world.replaceLiveIdentityBeforeSignal = true
        let result = try await world.control().run(.suspend, target: .token(IdentityToken(process.identity)), force: false)
        guard case let .failed(error, refused) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(refused)
        guard case .processChanged = error else { return XCTFail("\(error)") }
        XCTAssertTrue(world.signals.isEmpty)
    }

    // MARK: - Helpers

    private func agent(pid: Int32) -> ProcessSnapshot {
        snapshot(pid: pid, path: "/usr/local/bin/claude")
    }

    private func snapshot(pid: Int32, path: String) -> ProcessSnapshot {
        ProcessSnapshot(
            id: pid,
            parentPID: 600,
            processGroupID: pid,
            userID: getuid(),
            tty: "ttys001",
            cpuPercent: 0,
            residentBytes: 0,
            state: "R",
            elapsed: "00:10",
            executablePath: path,
            startTimeMicroseconds: UInt64(pid) * 1_000_000
        )
    }
}

/// A one-process world whose state reacts to signals.
private final class FakeWorld: @unchecked Sendable {
    private let lock = NSLock()
    private var process: ProcessSnapshot
    private var stopped = false
    private var exited = false
    private var sent: [Int32] = []
    private let exitSignal: Int32?
    var replaceLiveIdentityBeforeSignal = false

    init(_ process: ProcessSnapshot, exitsOn exitSignal: Int32? = nil) {
        self.process = process
        self.exitSignal = exitSignal
    }

    var signals: [Int32] { lock.withLock { sent } }

    func control(ledger: SuspensionLedger = .inMemory(), pollAttempts: Int = 4) -> CLIControl {
        CLIControl(
            lister: { [self] in
                lock.withLock { exited ? [] : [RawProcessRow(snapshot: process, totalCPUTimeNanoseconds: 0)] }
            },
            controller: ProcessController(
                factsReader: { [self] _ in lookup() },
                signalSender: { [self] _, signal in
                    lock.withLock {
                        sent.append(signal)
                        if signal == SIGSTOP { stopped = true }
                        if signal == SIGCONT { stopped = false }
                        if signal == exitSignal || signal == SIGKILL { exited = true }
                    }
                    return 0
                }
            ),
            ledger: ledger,
            sleep: { _ in },
            terminationPollAttempts: pollAttempts
        )
    }

    private func lookup() -> LiveProcessLookup {
        lock.withLock {
            if exited { return .absent }
            var identity = process.identity
            if replaceLiveIdentityBeforeSignal {
                identity = ProcessIdentity(pid: identity.pid, startTimeMicroseconds: identity.startTimeMicroseconds + 1, userID: identity.userID)
            }
            return .found(LiveProcessFacts(identity: identity, executablePath: process.executablePath, isSuspended: stopped))
        }
    }
}
