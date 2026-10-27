import Darwin
import XCTest
@testable import Watchdog

final class OrphanClassifierTests: XCTestCase {
    func testAgentUnderSessionHostHasNoOrphanReason() throws {
        let orca = snapshot(pid: 100, parent: 1, name: "/Applications/Orca.app/Contents/Frameworks/Orca Helper.app/Contents/MacOS/Orca Helper")
        let login = snapshot(pid: 101, parent: 100, name: "/usr/bin/login")
        let shell = snapshot(pid: 102, parent: 101, name: "/bin/zsh")
        let agent = snapshot(pid: 103, parent: 102, name: "/Users/test/.local/bin/gjc", tty: "ttys009")

        let result = try classified(agent.id, in: [orca, login, shell, agent])

        XCTAssertNil(result.orphanReason)
        XCTAssertFalse(result.suspectedOrphan)
    }

    func testReparentedAgentHasExactLaunchdReason() throws {
        let agent = snapshot(pid: 103, parent: 1, name: "/Users/test/.local/bin/gjc")

        XCTAssertEqual(try classified(agent.id, in: [agent]).orphanReason, .reparentedToLaunchd)
    }

    func testMissingParentHasExactReason() throws {
        let agent = snapshot(pid: 103, parent: 999, name: "/Users/test/.local/bin/gjc")

        XCTAssertEqual(try classified(agent.id, in: [agent]).orphanReason, .missingParent)
    }

    func testCycleHasExactReason() throws {
        let agent = snapshot(pid: 103, parent: 104, name: "/Users/test/.local/bin/gjc")
        let ancestor = snapshot(pid: 104, parent: 103, name: "/bin/zsh")

        XCTAssertEqual(try classified(agent.id, in: [agent, ancestor]).orphanReason, .cyclicLineage)
    }

    func testDetachedLineageHasExactReasonButAttachedTTYDoesNot() throws {
        let detachedAgent = snapshot(pid: 103, parent: 104, name: "/Users/test/.local/bin/gjc")
        let detachedShell = snapshot(pid: 104, parent: 1, name: "/bin/zsh")
        XCTAssertEqual(
            try classified(detachedAgent.id, in: [detachedAgent, detachedShell]).orphanReason,
            .detachedSession
        )

        let attachedAgent = snapshot(pid: 203, parent: 204, name: "/Users/test/.local/bin/gjc", tty: "ttys009")
        let attachedShell = snapshot(pid: 204, parent: 1, name: "/bin/zsh", tty: "ttys009")
        XCTAssertNil(try classified(attachedAgent.id, in: [attachedAgent, attachedShell]).orphanReason)
    }

    func testNonAgentIsNeverClassifiedAsOrphan() throws {
        let ordinary = snapshot(pid: 103, parent: 1, name: "/usr/local/bin/worker")

        let result = try classified(ordinary.id, in: [ordinary])

        XCTAssertEqual(result.kind, .other)
        XCTAssertNil(result.orphanReason)
        XCTAssertFalse(result.suspectedOrphan)
    }

    func testDuplicatePIDLinesDoNotCrashAndStayClassified() throws {
        let first = snapshot(pid: 103, parent: 1, name: "/Users/test/.local/bin/gjc")
        let duplicate = snapshot(pid: 103, parent: 1, name: "/Users/test/.local/bin/gjc")

        let result = try classified(103, in: [first, duplicate])

        XCTAssertEqual(result.orphanReason, .reparentedToLaunchd)
        XCTAssertEqual(OrphanClassifier.classify([first, duplicate]).count, 2)
    }

    func testProcessStartedByAgentIsAttributedToIt() throws {
        let herdr = snapshot(pid: 100, parent: 1, name: "/opt/homebrew/opt/herdr/bin/herdr")
        let agent = snapshot(pid: 101, parent: 100, name: "claude", tty: "ttys001")
        let shell = snapshot(pid: 102, parent: 101, name: "/bin/zsh", tty: "ttys001")
        let test = snapshot(pid: 103, parent: 102, name: "node", tty: "ttys001")

        let result = try classified(test.id, in: [herdr, agent, shell, test])

        XCTAssertEqual(result.agentAncestor, AgentAncestor(pid: 101, name: "claude", workingDirectory: nil))
        XCTAssertNil(try classified(herdr.id, in: [herdr, agent, shell, test]).agentAncestor)
        XCTAssertNil(try classified(agent.id, in: [herdr, agent, shell, test]).agentAncestor)
    }

    func testAttributionStopsAtSessionHost() throws {
        let agent = snapshot(pid: 100, parent: 1, name: "claude")
        let terminal = snapshot(pid: 101, parent: 100, name: "/Applications/Ghostty.app/Contents/MacOS/ghostty")
        let shell = snapshot(pid: 102, parent: 101, name: "/bin/zsh")

        XCTAssertNil(try classified(shell.id, in: [agent, terminal, shell]).agentAncestor)
    }

    func testSubagentOfLiveAgentIsNotOrphan() throws {
        let parent = snapshot(pid: 100, parent: 1, name: "claude")
        let shell = snapshot(pid: 101, parent: 100, name: "/bin/zsh")
        let subagent = snapshot(pid: 102, parent: 101, name: "/Users/test/.local/bin/omp")

        let result = try classified(subagent.id, in: [parent, shell, subagent])

        XCTAssertEqual(result.kind, .agent)
        XCTAssertNil(result.orphanReason)
    }

    func testAgentRunByHeadlessSupervisorOrDesktopHostIsNotOrphan() throws {
        for host in [
            "/Users/test/.local/bin/brgr",
            "/Applications/Codex.app/Contents/MacOS/Codex",
            "/Applications/cmux.app/Contents/MacOS/cmux",
        ] {
            let supervisor = snapshot(pid: 100, parent: 1, name: host)
            let agent = snapshot(pid: 101, parent: 100, name: "codex")
            XCTAssertNil(try classified(agent.id, in: [supervisor, agent]).orphanReason, host)
        }
    }

    private func classified(_ pid: Int32, in snapshots: [ProcessSnapshot]) throws -> ProcessSnapshot {
        try XCTUnwrap(OrphanClassifier.classify(snapshots).first { $0.id == pid })
    }

    private func snapshot(
        pid: Int32,
        parent: Int32,
        name: String,
        tty: String = "??"
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            id: pid,
            parentPID: parent,
            processGroupID: pid,
            userID: getuid(),
            tty: tty,
            cpuPercent: 0,
            residentBytes: 0,
            state: "S",
            elapsed: "00:01",
            executablePath: name,
            startTimeMicroseconds: UInt64(pid) * 1_000_000,
            workingDirectory: nil
        )
    }
}
