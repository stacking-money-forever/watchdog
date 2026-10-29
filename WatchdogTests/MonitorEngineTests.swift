import Darwin
import XCTest
@testable import Watchdog

/// Detection state machine shared by the app and the CLI.
final class MonitorEngineTests: XCTestCase {
    private let settings = MonitorSettings(
        cpuThreshold: 100,
        sustainedDuration: 4,
        memoryThresholdGB: 1,
        autoSuspendEnabled: true
    )

    func testSingleThreadedRunawayHoveringBelowThresholdStillBecomesSustained() {
        var engine = MonitorEngine()
        let start = ContinuousClock().now
        // One sample at 100% enters; later samples at 97–99% stay inside the
        // release band instead of resetting the evidence.
        let readings: [Double] = [100, 98, 97, 99, 98]
        var update: MonitorUpdate?
        for (index, cpu) in readings.enumerated() {
            update = engine.ingest(
                [agent(pid: 9_001, cpu: cpu)],
                settings: settings,
                at: start.advanced(by: .seconds(index * 2))
            )
        }
        XCTAssertEqual(update?.hot, [agent(pid: 9_001).identity])
    }

    func testSlowSamplingNeedsAWiderContinuityGap() {
        // `watch --interval 10`: with the default 5 s gap every sample looked
        // like a break in evidence and nothing ever alerted.
        let start = ContinuousClock().now
        func hotAfterThreeSamples(_ engine: inout MonitorEngine) -> Set<ProcessIdentity> {
            var update: MonitorUpdate?
            for index in 0..<3 {
                update = engine.ingest(
                    [agent(pid: 9_050, cpu: 200)],
                    settings: settings,
                    at: start.advanced(by: .seconds(index * 10))
                )
            }
            return update?.hot ?? []
        }
        var narrow = MonitorEngine()
        XCTAssertTrue(hotAfterThreeSamples(&narrow).isEmpty)
        var wide = MonitorEngine(continuityGap: .seconds(25))
        XCTAssertEqual(hotAfterThreeSamples(&wide), [agent(pid: 9_050).identity])
    }

    func testDropBelowReleaseBandClearsEvidence() {
        var engine = MonitorEngine()
        let start = ContinuousClock().now
        _ = engine.ingest([agent(pid: 9_002, cpu: 150)], settings: settings, at: start)
        _ = engine.ingest([agent(pid: 9_002, cpu: 50)], settings: settings, at: start.advanced(by: .seconds(2)))
        let update = engine.ingest(
            [agent(pid: 9_002, cpu: 150)],
            settings: settings,
            at: start.advanced(by: .seconds(6))
        )
        XCTAssertTrue(update.hot.isEmpty)
    }

    func testAutoSuspendTargetsOnlyAgentsFlaggedForCPU() {
        var engine = MonitorEngine()
        let start = ContinuousClock().now
        let cpuAgent = agent(pid: 9_010, cpu: 180)
        let memoryAgent = agent(pid: 9_011, cpu: 1, memoryGB: 3)
        let cpuApp = snapshot(pid: 9_012, path: "/Applications/Xcode.app/Contents/MacOS/Xcode", cpu: 300)
        let all = [cpuAgent, memoryAgent, cpuApp]

        _ = engine.ingest(all, settings: settings, at: start)
        let update = engine.ingest(all, settings: settings, at: start.advanced(by: .seconds(4)))

        XCTAssertEqual(update.hot, [cpuAgent.identity, cpuApp.identity])
        XCTAssertEqual(update.highMemory, [memoryAgent.identity])
        XCTAssertEqual(update.autoSuspendCandidates.map(\.id), [cpuAgent.id])
    }

    func testUserResumedProcessIsNeverAutoSuspendedAgain() {
        var engine = MonitorEngine()
        let start = ContinuousClock().now
        let process = agent(pid: 9_020, cpu: 180)
        _ = engine.ingest([process], settings: settings, at: start)
        var update = engine.ingest([process], settings: settings, at: start.advanced(by: .seconds(4)))
        XCTAssertEqual(update.autoSuspendCandidates.map(\.id), [process.id])

        // Stopped: CPU drops to zero and the flag clears.
        _ = engine.ingest([agent(pid: 9_020, cpu: 0, state: "T")], settings: settings, at: start.advanced(by: .seconds(6)))
        engine.recordUserResume(process.identity)

        // After the user resumes it, it runs hot again for a full window.
        _ = engine.ingest([process], settings: settings, at: start.advanced(by: .seconds(8)))
        update = engine.ingest([process], settings: settings, at: start.advanced(by: .seconds(12)))
        XCTAssertEqual(update.hot, [process.identity])
        XCTAssertTrue(update.autoSuspendCandidates.isEmpty)
    }

    func testUndoIgnoreRestoresFlagThatSurvivesTheNextSample() {
        var engine = MonitorEngine()
        let start = ContinuousClock().now
        let process = agent(pid: 9_030, cpu: 180)
        _ = engine.ingest([process], settings: settings, at: start)
        _ = engine.ingest([process], settings: settings, at: start.advanced(by: .seconds(4)))
        XCTAssertEqual(engine.ignore(process.identity), .ignored)
        var update = engine.ingest([process], settings: settings, at: start.advanced(by: .seconds(6)))
        XCTAssertTrue(update.hot.isEmpty)

        XCTAssertTrue(engine.undoIgnore(process.identity))
        XCTAssertEqual(engine.hot, [process.identity])
        update = engine.ingest([process], settings: settings, at: start.advanced(by: .seconds(8)))
        XCTAssertEqual(update.hot, [process.identity])
    }

    func testIgnoreIsDroppedWhenTheExactProcessIsGone() {
        var engine = MonitorEngine()
        let start = ContinuousClock().now
        let process = agent(pid: 9_031, cpu: 1)
        _ = engine.ingest([process], settings: settings, at: start)
        _ = engine.ignore(process.identity)
        _ = engine.ingest([], settings: settings, at: start.advanced(by: .seconds(2)))
        XCTAssertTrue(engine.ignored.isEmpty)
    }

    func testWorkingDirectoryAndWorktreeCarryAcrossSamples() {
        var engine = MonitorEngine()
        let start = ContinuousClock().now
        let process = agent(pid: 9_040, cpu: 1)
        _ = engine.ingest([process], settings: settings, at: start)
        engine.recordWorkingDirectory("/tmp/project", for: process.identity)
        let state = WorktreeState(path: "/tmp/project", verdict: .clean, detail: "main")
        engine.recordWorktreeState(state, for: process.identity)

        let update = engine.ingest([process], settings: settings, at: start.advanced(by: .seconds(2)))
        XCTAssertEqual(update.processes.first?.workingDirectory, "/tmp/project")
        XCTAssertEqual(update.processes.first?.worktreeState, state)
    }

    func testDisplayOrderIsStableUnderSamplingNoise() {
        let first = agent(pid: 9_051, cpu: 12.2)
        let second = agent(pid: 9_050, cpu: 11.9)
        let ordered = MonitorEngine.displayOrder([first, second])
        // Both round to 12%; PID breaks the tie instead of noise.
        XCTAssertEqual(ordered.map(\.id), [9_050, 9_051])
    }

    func testCarriedTemporaryWorkingDirectoryMarksOrphanOnNextSample() {
        var engine = MonitorEngine()
        let start = ContinuousClock().now
        let process = snapshot(
            pid: 9_070,
            path: "/Users/test/Library/Application Support/brgr/bin/brgr",
            parent: 1,
            tty: "??"
        )

        let first = engine.ingest([process], settings: settings, at: start)
        XCTAssertNil(first.processes.first?.orphanReason)

        engine.recordWorkingDirectory("/private/var/folders/x/T/.tmpX", for: process.identity)
        let second = engine.ingest([process], settings: settings, at: start.advanced(by: .seconds(2)))
        XCTAssertEqual(second.processes.first?.orphanReason, .temporaryLaunchPath)
        XCTAssertEqual(second.processes.first?.kind, .other)
    }

    func testSessionSumCrossesThresholdWhileNoProcessIsHot() {
        var engine = MonitorEngine()
        let start = ContinuousClock().now
        let root = agent(pid: 9_080, cpu: 10)
        let childA = snapshot(pid: 9_081, path: "/usr/bin/make", cpu: 50, parent: 9_080)
        let childB = snapshot(pid: 9_082, path: "/usr/bin/make", cpu: 50, parent: 9_080)
        let tree = [root, childA, childB]

        _ = engine.ingest(tree, settings: settings, at: start)
        let update = engine.ingest(tree, settings: settings, at: start.advanced(by: .seconds(4)))

        XCTAssertEqual(update.hotSessions, [root.identity])
        XCTAssertTrue(update.hot.isEmpty)
        XCTAssertEqual(update.sessions.first { $0.id == root.identity }?.cpuPercent, 110)

        engine.samplingFailed()
        XCTAssertTrue(engine.hotSessions.isEmpty)
        let afterFailure = engine.ingest(tree, settings: settings, at: start.advanced(by: .seconds(6)))
        XCTAssertTrue(afterFailure.hotSessions.isEmpty)
        XCTAssertTrue(afterFailure.hot.isEmpty)
    }

    func testSamplingFailureResetsEvidencePerSafetyContract() {
        var engine = MonitorEngine()
        let start = ContinuousClock().now
        let process = agent(pid: 9_060, cpu: 180)
        _ = engine.ingest([process], settings: settings, at: start)
        _ = engine.ingest([process], settings: settings, at: start.advanced(by: .seconds(4)))
        engine.samplingFailed()
        XCTAssertTrue(engine.hot.isEmpty)
        let update = engine.ingest([process], settings: settings, at: start.advanced(by: .seconds(6)))
        XCTAssertTrue(update.hot.isEmpty)
    }

    // MARK: - Helpers

    private func agent(pid: Int32, cpu: Double = 0, memoryGB: UInt64 = 0, state: String = "R") -> ProcessSnapshot {
        snapshot(pid: pid, path: "/usr/local/bin/claude", cpu: cpu, memoryGB: memoryGB, state: state)
    }

    private func snapshot(
        pid: Int32,
        path: String,
        cpu: Double = 0,
        memoryGB: UInt64 = 0,
        state: String = "R",
        parent: Int32 = 600,
        tty: String = "ttys001"
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            id: pid,
            parentPID: parent,
            processGroupID: pid,
            userID: getuid(),
            tty: tty,
            cpuPercent: cpu,
            residentBytes: memoryGB * 1_024 * 1_024 * 1_024,
            state: state,
            elapsed: "00:10",
            executablePath: path,
            startTimeMicroseconds: UInt64(pid) * 1_000_000
        )
    }
}
