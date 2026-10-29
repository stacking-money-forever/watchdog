import Darwin
import XCTest
@testable import Watchdog

final class SessionAggregatorTests: XCTestCase {
    func testAgentWithChildrenAndGrandchildSumsMembers() {
        let root = agent(pid: 100, cpu: 10, memory: 1_000)
        let childA = worker(pid: 110, parent: 100, cpu: 20, memory: 200)
        let childB = worker(pid: 120, parent: 100, cpu: 30, memory: 300)
        let grandchild = worker(pid: 130, parent: 110, cpu: 40, memory: 400)

        let sessions = SessionAggregator.sessions(
            from: OrphanClassifier.classify([root, childA, childB, grandchild])
        )

        XCTAssertEqual(sessions.count, 1)
        let session = sessions[0]
        XCTAssertEqual(session.rootPID, 100)
        XCTAssertEqual(session.name, "claude")
        XCTAssertEqual(session.kind, .agent)
        XCTAssertEqual(session.memberCount, 3)
        XCTAssertEqual(session.members.map(\.pid), [110, 120, 130])
        XCTAssertEqual(session.cpuPercent, 100)
        XCTAssertEqual(session.residentBytes, 1_900)
        XCTAssertEqual(session.elapsed, "00:10")
        XCTAssertFalse(session.isSuspended)
    }

    func testNestedAgentIsItsOwnSessionAndIsExcludedFromParent() {
        let parent = agent(pid: 200, cpu: 5, memory: 100)
        let parentChild = worker(pid: 201, parent: 200, cpu: 7, memory: 10)
        let nested = agent(pid: 210, path: "/usr/local/bin/codex", parent: 200, cpu: 80, memory: 800)
        let nestedChild = worker(pid: 211, parent: 210, cpu: 40, memory: 40)

        let sessions = SessionAggregator.sessions(
            from: OrphanClassifier.classify([parent, parentChild, nested, nestedChild])
        )

        XCTAssertEqual(sessions.map(\.rootPID).sorted(), [200, 210])
        let parentSession = sessions.first { $0.rootPID == 200 }
        let nestedSession = sessions.first { $0.rootPID == 210 }
        XCTAssertEqual(parentSession?.memberCount, 1)
        XCTAssertEqual(parentSession?.members.map(\.pid), [201])
        XCTAssertEqual(parentSession?.cpuPercent, 12)
        XCTAssertEqual(parentSession?.residentBytes, 110)
        XCTAssertEqual(nestedSession?.kind, .agent)
        XCTAssertEqual(nestedSession?.memberCount, 1)
        XCTAssertEqual(nestedSession?.members.map(\.pid), [211])
        XCTAssertEqual(nestedSession?.cpuPercent, 120)
        XCTAssertEqual(nestedSession?.residentBytes, 840)
    }

    func testServiceRootIncludesMCPChild() {
        var serve = snapshot(
            pid: 300,
            path: "/opt/homebrew/bin/opencode",
            cpu: 3,
            memory: 50_000,
            parent: 1,
            tty: "??"
        )
        serve.launchSubcommand = "serve"
        let mcp = worker(pid: 301, parent: 300, cpu: 12, memory: 4_000)

        let sessions = SessionAggregator.sessions(from: OrphanClassifier.classify([serve, mcp]))

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].kind, .service)
        XCTAssertEqual(sessions[0].name, "opencode")
        XCTAssertEqual(sessions[0].memberCount, 1)
        XCTAssertEqual(sessions[0].members.map(\.pid), [301])
        XCTAssertEqual(sessions[0].cpuPercent, 15)
        XCTAssertEqual(sessions[0].residentBytes, 54_000)
    }

    func testSortsByRoundedCPUThenRootPID() {
        let lowPID = agent(pid: 10, cpu: 10.4)
        let highCPU = agent(pid: 30, path: "/usr/local/bin/codex", cpu: 10.6)
        let highPID = agent(pid: 20, path: "/usr/local/bin/gemini", cpu: 10.2)

        let sessions = SessionAggregator.sessions(from: [lowPID, highCPU, highPID])

        XCTAssertEqual(sessions.map(\.rootPID), [30, 10, 20])
    }

    func testNonFiniteCPUCountsAsZero() {
        let root = agent(pid: 400, cpu: .nan, memory: 10)
        let child = worker(pid: 401, parent: 400, cpu: .infinity, memory: 5)

        let sessions = SessionAggregator.sessions(from: OrphanClassifier.classify([root, child]))

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].cpuPercent, 0)
        XCTAssertEqual(sessions[0].memberCount, 1)
        XCTAssertEqual(sessions[0].residentBytes, 15)
    }

    func testSessionHostIsNotASessionRoot() {
        // herdr is a resident service and the parent of every terminal shell,
        // but those shells are not "the herdr session".
        let herdr = snapshot(pid: 100, path: "/opt/homebrew/opt/herdr/bin/herdr", cpu: 0, parent: 1, tty: "??")
        let shell = snapshot(pid: 101, path: "/bin/zsh", cpu: 0, parent: 100)
        let agent = snapshot(pid: 102, path: "/usr/local/bin/claude", cpu: 10, parent: 101)
        let build = worker(pid: 103, parent: 102, cpu: 20)

        let sessions = SessionAggregator.sessions(from: OrphanClassifier.classify([herdr, shell, agent, build]))

        XCTAssertEqual(sessions.map { $0.rootPID }, [102])
        XCTAssertEqual(sessions.first?.members.map { $0.pid }, [103])
    }

    private func agent(
        pid: Int32,
        path: String = "/usr/local/bin/claude",
        parent: Int32 = 600,
        cpu: Double = 0,
        memory: UInt64 = 0
    ) -> ProcessSnapshot {
        snapshot(pid: pid, path: path, cpu: cpu, memory: memory, parent: parent)
    }

    private func worker(
        pid: Int32,
        parent: Int32,
        cpu: Double = 0,
        memory: UInt64 = 0
    ) -> ProcessSnapshot {
        snapshot(pid: pid, path: "/usr/bin/make", cpu: cpu, memory: memory, parent: parent)
    }

    private func snapshot(
        pid: Int32,
        path: String,
        cpu: Double = 0,
        memory: UInt64 = 0,
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
            residentBytes: memory,
            state: state,
            elapsed: "00:10",
            executablePath: path,
            startTimeMicroseconds: UInt64(pid) * 1_000_000
        )
    }
}
