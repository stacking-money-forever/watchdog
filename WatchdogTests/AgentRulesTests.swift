import Darwin
import XCTest
@testable import Watchdog

final class AgentRulesTests: XCTestCase {
    private var temporaryFiles: [URL] = []

    override func tearDown() {
        AgentCatalog.resetToBuiltIn()
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles.removeAll()
        super.tearDown()
    }

    func testLoadAbsent() {
        let url = uniqueURL()
        let result = AgentRules.load(from: url)
        XCTAssertEqual(result, .absent(url))
    }

    func testLoadValidAndIgnoresUnknownKeys() throws {
        let url = uniqueURL()
        let json = """
        {
          "_comment": "ok",
          "agentNames": ["fakeagent"],
          "unknown": 1,
          "packageMarkers": [{"marker": "/@x/y/", "agent": "fakeagent"}]
        }
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        guard case let .loaded(rules, loadedURL) = AgentRules.load(from: url) else {
            return XCTFail("expected loaded")
        }
        XCTAssertEqual(loadedURL, url)
        XCTAssertEqual(rules.agentNames, ["fakeagent"])
        XCTAssertEqual(rules.packageMarkers, [PackageMarker(marker: "/@x/y/", agent: "fakeagent")])
        XCTAssertEqual(rules.serviceSubcommands, [])
        XCTAssertEqual(rules.sessionHosts, [])
        XCTAssertEqual(rules.ignoreNames, [])
    }

    func testLoadInvalidKeepsDefaultRules() throws {
        let url = uniqueURL()
        try "{".write(to: url, atomically: true, encoding: .utf8)
        guard case let .invalid(invalidURL, reason) = AgentRules.load(from: url) else {
            return XCTFail("expected invalid")
        }
        XCTAssertEqual(invalidURL, url)
        XCTAssertFalse(reason.isEmpty)
        AgentCatalog.activate(rules: AgentRules())
        XCTAssertEqual(AgentCatalog.agentName(command: "claude", launchScript: nil), "claude")
        XCTAssertNil(AgentCatalog.agentName(command: "fakeagent", launchScript: nil))
    }

    func testValidationIssues() {
        let rules = AgentRules(
            agentNames: ["", "my agent", "foo/bar", "dup", "dup", "pi"],
            ignoreNames: ["pi"]
        )
        let issues = rules.validationIssues()
        XCTAssertTrue(issues.contains { $0.contains("빈 문자열") })
        XCTAssertTrue(issues.contains { $0.contains("공백") })
        XCTAssertTrue(issues.contains { $0.contains("/") })
        XCTAssertTrue(issues.contains { $0.contains("중복") })
        XCTAssertTrue(issues.contains { $0.contains("충돌") })
    }

    func testMergeAddsNamesAndHostsAndHonoursIgnore() {
        let rules = AgentRules(
            agentNames: ["fakeagent"],
            sessionHosts: ["customhost"],
            ignoreNames: ["pi"]
        )
        let catalog = AgentCatalog(builtIn: .builtIn, merging: rules)
        XCTAssertEqual(catalog.agentName(command: "fakeagent", launchScript: nil), "fakeagent")
        XCTAssertNil(catalog.agentName(command: "pi", launchScript: nil))
        XCTAssertEqual(catalog.agentName(command: "claude", launchScript: nil), "claude")
        XCTAssertTrue(
            catalog.isSessionHost(
                snapshot(path: "/opt/customhost/bin/customhost")
            )
        )
    }

    func testRulesPathOverride() {
        let url = uniqueURL()
        let environment = [AgentRules.fileEnvironmentKey: url.path]
        XCTAssertEqual(AgentRules.standardURL(environment: environment), url)
    }

    private func uniqueURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchdog-rules-\(UUID().uuidString).json")
        temporaryFiles.append(url)
        return url
    }

    private func snapshot(path: String) -> ProcessSnapshot {
        ProcessSnapshot(
            id: 1,
            parentPID: 1,
            processGroupID: 1,
            userID: getuid(),
            tty: "??",
            cpuPercent: 0,
            residentBytes: 0,
            state: "S",
            elapsed: "00:01",
            executablePath: path,
            startTimeMicroseconds: 1_000
        )
    }
}
