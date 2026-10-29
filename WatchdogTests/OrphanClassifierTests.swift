import Darwin
import XCTest
@testable import Watchdog

final class OrphanClassifierTests: XCTestCase {
    override func tearDown() {
        AgentCatalog.resetToBuiltIn()
        super.tearDown()
    }

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
        let agent = snapshot(pid: 103, parent: 1, name: "/Users/test/.local/bin/gjc", tty: "ttys001")

        XCTAssertEqual(try classified(agent.id, in: [agent]).kind, .agent)
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
        let detachedShell = snapshot(pid: 104, parent: 1, name: "/bin/zsh", tty: "ttys009")
        XCTAssertEqual(
            try classified(detachedAgent.id, in: [detachedAgent, detachedShell]).orphanReason,
            .detachedSession
        )

        let attachedAgent = snapshot(pid: 203, parent: 204, name: "/Users/test/.local/bin/gjc", tty: "ttys009")
        let attachedShell = snapshot(pid: 204, parent: 1, name: "/bin/zsh", tty: "ttys009")
        XCTAssertNil(try classified(attachedAgent.id, in: [attachedAgent, attachedShell]).orphanReason)
    }

    func testSystemDaemonWithTemporaryWorkingDirectoryIsNotLeftover() throws {
        // privatecloudcomputed and IMTransferAgent keep a cwd under /var/folders.
        var daemon = snapshot(pid: 105, parent: 1, name: "/System/Library/PrivateFrameworks/PCC.framework/privatecloudcomputed")
        daemon.workingDirectory = "/private/var/folders/zz/T/com.apple.pcc"
        var app = snapshot(pid: 106, parent: 1, name: "/Applications/Foo.app/Contents/MacOS/Foo")
        app.workingDirectory = "/private/var/folders/zz/T/foo"

        XCTAssertEqual(try classified(daemon.id, in: [daemon, app]).kind, .system)
        XCTAssertNil(try classified(daemon.id, in: [daemon, app]).orphanReason)
        XCTAssertEqual(try classified(app.id, in: [daemon, app]).kind, .application)
        XCTAssertNil(try classified(app.id, in: [daemon, app]).orphanReason)
    }

    func testResidentHeadlessProcessIsServiceNotOrphan() throws {
        let ordinary = snapshot(pid: 103, parent: 1, name: "/usr/local/bin/worker")

        let result = try classified(ordinary.id, in: [ordinary])

        XCTAssertEqual(result.kind, .service)
        XCTAssertNil(result.orphanReason)
        XCTAssertFalse(result.suspectedOrphan)
    }

    func testDuplicatePIDLinesDoNotCrashAndStayClassified() throws {
        let first = snapshot(pid: 103, parent: 1, name: "/Users/test/.local/bin/gjc", tty: "ttys001")
        let duplicate = snapshot(pid: 103, parent: 1, name: "/Users/test/.local/bin/gjc", tty: "ttys001")

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

    func testOpencodeServeUnderLaunchdIsServiceNotOrphan() throws {
        var serve = snapshot(pid: 200, parent: 1, name: "/opt/homebrew/bin/opencode")
        serve.launchSubcommand = "serve"

        let result = try classified(serve.id, in: [serve])

        XCTAssertEqual(result.kind, .service)
        XCTAssertEqual(result.agentName, "opencode")
        XCTAssertNil(result.orphanReason)
    }

    func testCodexAppServerDaemonIsServiceRootForListenChild() throws {
        var daemon = snapshot(pid: 300, parent: 1, name: "/Users/test/.codex/bin/codex")
        daemon.launchSubcommand = "app-server"
        var listen = snapshot(pid: 301, parent: 300, name: "/Users/test/.codex/bin/codex")
        listen.launchSubcommand = "app-server"

        let child = try classified(listen.id, in: [daemon, listen])
        let parent = try classified(daemon.id, in: [daemon, listen])

        XCTAssertEqual(parent.kind, .service)
        XCTAssertEqual(child.kind, .service)
        XCTAssertNil(parent.orphanReason)
        XCTAssertNil(child.orphanReason)
        XCTAssertEqual(child.agentAncestor?.pid, daemon.id)
        XCTAssertEqual(child.agentAncestor?.name, "codex")
    }

    func testTempWaitScriptUnderLaunchdIsOtherOrphan() throws {
        var wait = snapshot(pid: 400, parent: 1, name: "/bin/sh")
        wait.launchScript = "/private/var/folders/x/T/.tmpAB/scripts/wait"

        let result = try classified(wait.id, in: [wait])

        XCTAssertEqual(result.kind, .other)
        XCTAssertEqual(result.orphanReason, .temporaryLaunchPath)
    }

    func testTempPathCodexIsServiceOrphan() throws {
        var leftover = snapshot(
            pid: 401,
            parent: 1,
            name: "/private/tmp/claude-501/scratch/codex"
        )
        leftover.launchSubcommand = "app-server"

        let result = try classified(leftover.id, in: [leftover])

        XCTAssertEqual(result.kind, .service)
        XCTAssertEqual(result.agentName, "codex")
        XCTAssertEqual(result.orphanReason, .temporaryLaunchPath)
    }

    func testTempWorkingDirectoryBrgrIsOrphan() throws {
        var notify = snapshot(
            pid: 402,
            parent: 1,
            name: "/Users/test/Library/Application Support/brgr/bin/brgr"
        )
        notify.workingDirectory = "/private/var/folders/x/T/.tmpX"

        let result = try classified(notify.id, in: [notify])

        XCTAssertEqual(result.kind, .other)
        XCTAssertEqual(result.orphanReason, .temporaryLaunchPath)
    }

    func testAppTranslocationIsApplicationNotOrphan() throws {
        let app = snapshot(
            pid: 403,
            parent: 1,
            name: "/private/var/folders/x/T/AppTranslocation/E7E2/d/Foo.app/Contents/MacOS/Foo"
        )

        let result = try classified(app.id, in: [app])

        XCTAssertEqual(result.kind, .application)
        XCTAssertNil(result.orphanReason)
    }

    func testBunServerUnderClaudeIsStillOtherViaClaude() throws {
        let agent = snapshot(pid: 500, parent: 80, name: "claude", tty: "ttys001")
        let child = snapshot(pid: 501, parent: 500, name: "/opt/homebrew/bin/bun", tty: "ttys001")
        var server = child
        server.launchScript = "/Users/test/project/server.ts"

        let result = try classified(server.id, in: [agent, server])

        XCTAssertEqual(result.kind, .other)
        XCTAssertEqual(result.agentAncestor, AgentAncestor(pid: 500, name: "claude", workingDirectory: nil))
        XCTAssertNil(result.orphanReason)
    }

    func testFrameworkPythonHttpServerIsService() throws {
        var server = snapshot(
            pid: 610,
            parent: 1,
            name: "/Library/Developer/Python.app/Contents/MacOS/Python"
        )
        server.launchScript = "http.server"

        let result = try classified(server.id, in: [server])

        XCTAssertEqual(result.kind, .service)
        XCTAssertNil(result.orphanReason)
    }

    func testSuspectedInterpreterUnderHostedShell() throws {
        let herdr = snapshot(pid: 10, parent: 1, name: "/opt/homebrew/opt/herdr/bin/herdr")
        let shell = snapshot(pid: 11, parent: 10, name: "/bin/zsh", tty: "ttys001")
        var node = snapshot(pid: 12, parent: 11, name: "/usr/local/bin/node", tty: "ttys001")
        node.launchScript = "~/.npm/_npx/abc/node_modules/.bin/newagent"

        let result = try classified(node.id, in: [herdr, shell, node])

        XCTAssertEqual(result.kind, .agent)
        XCTAssertEqual(result.agentConfidence, .suspected)
        XCTAssertEqual(result.agentName, "newagent")
        XCTAssertFalse(MonitorEngine.isAutoSuspendEligible(result))
        let sessions = SessionAggregator.sessions(from: OrphanClassifier.classify([herdr, shell, node]))
        XCTAssertFalse(sessions.contains { $0.rootPID == node.id })
    }

    func testSuspectedRequiresTTY() throws {
        let herdr = snapshot(pid: 10, parent: 1, name: "/opt/homebrew/opt/herdr/bin/herdr")
        let shell = snapshot(pid: 11, parent: 10, name: "/bin/zsh")
        var node = snapshot(pid: 12, parent: 11, name: "/usr/local/bin/node")
        node.launchScript = "~/.npm/_npx/abc/node_modules/.bin/newagent"

        let result = try classified(node.id, in: [herdr, shell, node])
        XCTAssertNotEqual(result.agentConfidence, .suspected)
        XCTAssertNil(result.agentName)
        XCTAssertNotEqual(result.kind, .agent)
    }

    func testSuspectedRequiresHostedParentChain() throws {
        let launchd = snapshot(pid: 1, parent: 0, name: "/sbin/launchd")
        let shell = snapshot(pid: 11, parent: 1, name: "/bin/zsh", tty: "ttys001")
        var node = snapshot(pid: 12, parent: 11, name: "/usr/local/bin/node", tty: "ttys001")
        node.launchScript = "~/.npm/_npx/abc/node_modules/.bin/newagent"

        let result = try classified(node.id, in: [launchd, shell, node])
        XCTAssertNotEqual(result.agentConfidence, .suspected)
        XCTAssertNotEqual(result.kind, .agent)
    }

    func testSuspectedHonoursIgnoreNames() throws {
        AgentCatalog.activate(rules: AgentRules(ignoreNames: ["newagent"]))
        defer { AgentCatalog.resetToBuiltIn() }
        let herdr = snapshot(pid: 10, parent: 1, name: "/opt/homebrew/opt/herdr/bin/herdr")
        let shell = snapshot(pid: 11, parent: 10, name: "/bin/zsh", tty: "ttys001")
        var node = snapshot(pid: 12, parent: 11, name: "/usr/local/bin/node", tty: "ttys001")
        node.launchScript = "~/.npm/_npx/abc/node_modules/.bin/newagent"

        let result = try classified(node.id, in: [herdr, shell, node])
        XCTAssertNotEqual(result.agentConfidence, .suspected)
        XCTAssertNil(result.agentName)
    }

    func testClaudeWithTTYUnderLaunchdStaysAgentOrphan() throws {
        let agent = snapshot(pid: 600, parent: 1, name: "claude", tty: "ttys001")

        let result = try classified(agent.id, in: [agent])

        XCTAssertEqual(result.kind, .agent)
        XCTAssertEqual(result.orphanReason, .reparentedToLaunchd)
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
