import Darwin
import XCTest
@testable import Watchdog

final class SuspensionLedgerTests: XCTestCase {
    private let uid = getuid()

    func testGroupIDIsStoredAndQueried() throws {
        let ledger = SuspensionLedger.inMemory()
        let root = identity(pid: 4_001)
        let child = identity(pid: 4_002)
        let groupID = IdentityToken(root).description
        try ledger.record(
            SuspensionRecord(
                identity: root,
                executablePath: "/usr/local/bin/claude",
                suspendedAt: Date(timeIntervalSince1970: 1),
                source: .auto,
                groupID: groupID
            )
        )
        try ledger.record(
            SuspensionRecord(
                identity: child,
                executablePath: "/usr/bin/yes",
                suspendedAt: Date(timeIntervalSince1970: 2),
                source: .auto,
                groupID: groupID
            )
        )
        try ledger.record(
            SuspensionRecord(
                identity: identity(pid: 4_099),
                executablePath: "/bin/sleep",
                suspendedAt: Date(timeIntervalSince1970: 3),
                source: .cli
            )
        )

        XCTAssertEqual(ledger.records(inGroup: groupID).map(\.identity), [root, child])
        XCTAssertEqual(ledger.groupCompanions(of: root).map(\.identity), [child])
        XCTAssertTrue(ledger.groupCompanions(of: child).isEmpty)
    }

    func testRemoveGroupDropsEveryMember() throws {
        let ledger = SuspensionLedger.inMemory()
        let root = identity(pid: 4_010)
        let groupID = IdentityToken(root).description
        try ledger.record(
            SuspensionRecord(
                identity: root,
                executablePath: "/usr/local/bin/claude",
                suspendedAt: Date(),
                source: .auto,
                groupID: groupID
            )
        )
        try ledger.record(
            SuspensionRecord(
                identity: identity(pid: 4_011),
                executablePath: "/usr/bin/yes",
                suspendedAt: Date(),
                source: .auto,
                groupID: groupID
            )
        )
        try ledger.record(
            SuspensionRecord(
                identity: identity(pid: 4_012),
                executablePath: "/bin/sleep",
                suspendedAt: Date(),
                source: .cli
            )
        )
        _ = try ledger.removeGroup(groupID)
        XCTAssertEqual(ledger.all().map(\.pid), [4_012])
    }

    func testLegacyFileLoadsWithoutGroupID() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-ledger-group-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("suspensions.json")
        let json = """
        [{"executablePath":"/usr/local/bin/claude","pid":40120,"source":"cli","startTimeMicroseconds":40120000000,"suspendedAt":"2026-01-01T00:00:00Z","userID":\(uid)}]
        """
        try Data(json.utf8).write(to: url)
        let ledger = SuspensionLedger(fileURL: url)
        XCTAssertEqual(ledger.all().count, 1)
        XCTAssertNil(ledger.all().first?.groupID)
        XCTAssertEqual(ledger.all().first?.pid, 40_120)
    }

    private func identity(pid: Int32) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTimeMicroseconds: UInt64(pid) * 1_000_000, userID: uid)
    }
}
