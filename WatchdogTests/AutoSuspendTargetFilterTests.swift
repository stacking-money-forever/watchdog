import Darwin
import XCTest
@testable import Watchdog

final class AutoSuspendTargetFilterTests: XCTestCase {
    func testAgentCandidatesOutsideOnlyAreDroppedAndDescendantsStay() {
        let root = snapshot(pid: 6_001, path: "/usr/local/bin/claude", parent: 600)
        let child = snapshot(pid: 6_002, path: "/usr/bin/yes", parent: 6_001)
        let outsider = snapshot(pid: 6_003, path: "/usr/local/bin/codex", parent: 600)
        let update = MonitorUpdate(
            processes: [root, child, outsider],
            hot: [root.identity, outsider.identity, child.identity],
            highMemory: [],
            newlyHot: [root.identity, outsider.identity, child.identity],
            newlyHighMemory: [],
            autoSuspendCandidates: [root, child, outsider]
        )

        let byRoot = AutoSuspendTargetFilter.restrict(update, to: [.pid(root.id)])
        XCTAssertEqual(Set(byRoot.autoSuspendCandidates.map(\.id)), [root.id, child.id])

        let byToken = AutoSuspendTargetFilter.restrict(
            update,
            to: [.token(IdentityToken(root.identity))]
        )
        XCTAssertEqual(Set(byToken.autoSuspendCandidates.map(\.id)), [root.id, child.id])
    }

    func testSessionGroupRequiresRootInOnlyAndKeepsOnlyDescendants() {
        let root = snapshot(pid: 6_010, path: "/usr/local/bin/claude", parent: 600)
        let child = snapshot(pid: 6_011, path: "/usr/bin/yes", parent: 6_010)
        let outsider = snapshot(pid: 6_012, path: "/usr/bin/yes", parent: 1)
        let group = AutoSuspendGroup(root: root.identity, members: [child, outsider])
        let update = MonitorUpdate(
            processes: [root, child, outsider],
            hot: [],
            highMemory: [],
            newlyHot: [],
            newlyHighMemory: [],
            autoSuspendCandidates: [],
            autoSuspendGroups: [group]
        )

        let namedRoot = AutoSuspendTargetFilter.restrict(update, to: [.pid(root.id)])
        XCTAssertEqual(namedRoot.autoSuspendGroups.count, 1)
        XCTAssertEqual(namedRoot.autoSuspendGroups.first?.members.map(\.id), [child.id])

        let namedChildOnly = AutoSuspendTargetFilter.restrict(update, to: [.pid(child.id)])
        XCTAssertTrue(namedChildOnly.autoSuspendGroups.isEmpty)
        XCTAssertTrue(namedChildOnly.autoSuspendCandidates.isEmpty)
    }

    private func snapshot(pid: Int32, path: String, parent: Int32) -> ProcessSnapshot {
        ProcessSnapshot(
            id: pid,
            parentPID: parent,
            processGroupID: pid,
            userID: getuid(),
            tty: "ttys001",
            cpuPercent: 50,
            residentBytes: 0,
            state: "R",
            elapsed: "00:10",
            executablePath: path,
            startTimeMicroseconds: UInt64(pid) * 1_000_000
        )
    }
}
