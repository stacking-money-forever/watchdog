import Darwin
import XCTest
@testable import Watchdog

final class CLIJSONContractTests: XCTestCase {
    func testContractEnumsMatchSchemaBothWays() throws {
        let schema = try loadSchema()
        assertEqual(schema.stringSet("processKind"), CLIJSONContract.ProcessKind.allCases.map(\.rawValue), "processKind")
        assertEqual(schema.stringSet("orphanReason"), CLIJSONContract.OrphanReason.allCases.map(\.rawValue), "orphanReason")
        assertEqual(schema.stringSet("alertReasonKind"), CLIJSONContract.AlertReasonKind.allCases.map(\.rawValue), "alertReasonKind")
        assertEqual(schema.stringSet("processActionOutcome"), CLIJSONContract.ActionOutcome.allCases.map(\.rawValue), "processActionOutcome")
        assertEqual(schema.stringSet("journalSource"), CLIJSONContract.JournalSource.allCases.map(\.rawValue), "journalSource")
        assertEqual(schema.stringSet("journalAction"), CLIJSONContract.JournalAction.allCases.map(\.rawValue), "journalAction")
        assertEqual(schema.stringSet("autoSuspendScope"), CLIJSONContract.AutoSuspendScope.allCases.map(\.rawValue), "autoSuspendScope")
        assertEqual(schema.stringSet("agentConfidence"), CLIJSONContract.AgentConfidence.allCases.map(\.rawValue), "agentConfidence")
        assertEqual(schema.stringSet("watchEventType"), CLIJSONContract.WatchEventType.allCases.map(\.rawValue), "watchEventType")
        assertEqual(schema.stringSet("listScope"), CLIJSONContract.ListScope.allCases.map(\.rawValue), "listScope")
        assertEqual(schema.stringSet("listFlags"), CLIJSONContract.ListFlag.allFixed, "listFlags")
        assertEqual(schema.stringSet("sessionFlags"), CLIJSONContract.SessionFlag.allFixed, "sessionFlags")
        assertEqual(schema.stringSet("stoppedSource"), CLIJSONContract.StoppedSource.allCases.map(\.rawValue), "stoppedSource")
        assertEqual(schema.stringSet("controlAction"), CLIJSONContract.ControlAction.allCases.map(\.rawValue), "controlAction")
        assertEqual(schema.stringSet("controlResult"), CLIJSONContract.ControlResult.allCases.map(\.rawValue), "controlResult")
        assertEqual(schema.stringSet("stoppedResumeResult"), CLIJSONContract.StoppedResumeResult.allCases.map(\.rawValue), "stoppedResumeResult")
        XCTAssertEqual(schema.string("processActionOutcomeFailedPrefix"), CLIJSONContract.ActionOutcome.failedPrefix)
        XCTAssertEqual(schema.string("listFlagViaPrefix"), CLIJSONContract.ListFlag.viaPrefix)
        XCTAssertEqual(schema.string("auditMissingKind"), CLIJSONContract.auditMissingKind)
        XCTAssertEqual(
            CLIJSONContract.ListFlag.via(name: "claude", pid: 4123),
            "via:claude#4123"
        )
    }

    func testDomainRawValuesMatchContract() {
        assertEqual(Set(ProcessKind.allCases.map(\.rawValue)), Set(CLIJSONContract.ProcessKind.allCases.map(\.rawValue)), "ProcessKind")
        assertEqual(Set(OrphanReason.allCases.map(\.rawValue)), Set(CLIJSONContract.OrphanReason.allCases.map(\.rawValue)), "OrphanReason")
        assertEqual(Set(AgentConfidence.allCases.map(\.rawValue)), Set(CLIJSONContract.AgentConfidence.allCases.map(\.rawValue)), "AgentConfidence")
        assertEqual(
            Set(MonitorSettings.AutoSuspendScope.allCases.map(\.rawValue)),
            Set(CLIJSONContract.AutoSuspendScope.allCases.map(\.rawValue)),
            "AutoSuspendScope"
        )
        assertEqual(
            Set(SuspensionRecord.Source.allCases.map(\.rawValue)),
            Set(CLIJSONContract.StoppedSource.allCases.map(\.rawValue)),
            "StoppedSource"
        )
        assertEqual(
            Set(ActionJournalEntry.Source.allCases.map(\.rawValue)),
            Set(CLIJSONContract.JournalSource.allCases.map(\.rawValue)),
            "JournalSource"
        )
        assertEqual(
            Set(ActionJournalEntry.ActionKind.allCases.map(\.rawValue)),
            Set(CLIJSONContract.JournalAction.allCases.map(\.rawValue)),
            "JournalAction"
        )
        assertEqual(
            Set(CLIAction.allCases.map(\.cliJSONValue)),
            Set(CLIJSONContract.ControlAction.allCases.map(\.rawValue)),
            "ControlAction"
        )
        XCTAssertEqual(ProcessKind.agent.cliJSONValue, CLIJSONContract.ProcessKind.agent.rawValue)
        XCTAssertEqual(
            CLIJSONContract.outcomeString(.failed("boom")),
            CLIJSONContract.ActionOutcome.failedPrefix + "boom"
        )
        XCTAssertEqual(
            CLIJSONContract.alertReasonKind(.orphan(.missingParent)),
            CLIJSONContract.AlertReasonKind.orphan.rawValue
        )
    }

    func testEncodableFieldsMatchSchema() throws {
        let schema = try loadSchema()
        var process = ProcessSnapshot(
            id: 4123,
            parentPID: 1,
            processGroupID: 4123,
            userID: getuid(),
            tty: "ttys001",
            cpuPercent: 12.3,
            residentBytes: 1_048_576,
            state: "S",
            elapsed: "01:02",
            executablePath: "/usr/local/bin/claude",
            startTimeMicroseconds: 1_761_483_670_123_456,
            workingDirectory: "/tmp/project",
            orphanReason: .reparentedToLaunchd,
            launchScript: "/usr/lib/node_modules/claude/cli.js",
            agentAncestor: AgentAncestor(pid: 99, name: "claude", workingDirectory: "/tmp/project")
        )
        process.worktreeState = WorktreeState(path: "/tmp/project", verdict: .clean, detail: "main")
        try assertFields(ProcessRecord(process, flags: [CLIJSONContract.ListFlag.orphan], watchdogSuspended: false), schema, "ProcessRecord")

        let session = AgentSession(
            id: process.identity,
            rootPID: process.id,
            name: process.displayName,
            kind: .agent,
            workingDirectory: process.workingDirectory,
            projectName: "project",
            members: [ProcessIdentity(pid: 4124, startTimeMicroseconds: 1, userID: getuid())],
            memberCount: 1,
            cpuPercent: 12.3,
            residentBytes: 1_048_576,
            isSuspended: false,
            elapsed: "01:02"
        )
        try assertFields(SessionRecord(session), schema, "SessionRecord")
        try assertFields(
            WatchEvent(
                time: Date(),
                type: CLIJSONContract.WatchEventType.watchStart.rawValue,
                token: "4123:1:501",
                name: "claude",
                detail: "start"
            ),
            schema,
            "WatchEvent"
        )
        try assertFields(
            SessionAlertEvent(
                event: CLIJSONContract.WatchEventType.sessionHot.rawValue,
                token: "1:2:3",
                name: "claude",
                cpuPercent: 180,
                memberCount: 2
            ),
            schema,
            "SessionAlertEvent"
        )
        try assertFields(
            CLIStoppedRecord(
                token: "1:2:3",
                name: "helper",
                path: "/tmp/helper",
                suspendedAt: Date(),
                source: CLIJSONContract.StoppedSource.cli.rawValue,
                groupID: "4123:1:501"
            ),
            schema,
            "CLIStoppedRecord"
        )
        try assertFields(
            CLIStoppedResumeRecord(
                token: "1:2:3",
                name: "helper",
                result: CLIJSONContract.StoppedResumeResult.resumed.rawValue,
                message: "재개됨"
            ),
            schema,
            "CLIStoppedResumeRecord"
        )
        try assertFields(
            CLIDoctorReport(
                psMilliseconds: 12,
                ledgerPath: "/tmp/ledger.json",
                settings: ["cpuThreshold": 100, "sustainedDuration": 20, "memoryThresholdGB": 2],
                autoSuspendEnabled: false,
                appRunning: false,
                loginItemStatus: "enabled",
                loginItemOptedOut: false,
                loginItemLastError: "none",
                rulesPath: "/tmp/rules.json",
                rulesStatus: "없음"
            ),
            schema,
            "CLIDoctorReport"
        )
        try assertFields(
            CLIRulesShowReport(
                path: "/tmp/rules.json",
                status: "없음",
                reason: "손상",
                rules: AgentRules(),
                validationIssues: [],
                appliedCount: 0
            ),
            schema,
            "CLIRulesShowReport"
        )
        let entry = ActionJournalEntry(
            id: UUID(),
            at: Date(),
            source: .cli,
            action: .suspend,
            pid: 4123,
            startTimeMicroseconds: 1,
            userID: getuid(),
            executablePath: "/usr/local/bin/claude",
            displayName: "claude",
            workingDirectory: "/tmp/project",
            reason: "CPU",
            outcome: CLIJSONContract.ActionOutcome.suspended.rawValue,
            undoOf: UUID()
        )
        try assertFields(entry, schema, "ActionJournalEntry")
        try assertFields(
            AuditReport(
                snapshotCount: 0,
                labeledCount: 0,
                kind: AuditReport.FieldCounts(),
                agentName: AuditReport.FieldCounts(),
                sessionRoot: AuditReport.FieldCounts(),
                orphan: AuditReport.FieldCounts(),
                orphanReason: AuditReport.FieldCounts(),
                kindConfusion: [:],
                mismatches: [],
                toleratedMismatchCount: 0,
                untoleratedMismatchCount: 0
            ),
            schema,
            "AuditReport"
        )
        try assertFields(AuditReport.FieldCounts(), schema, "AuditFieldCounts")
        try assertFields(
            AuditReport.Mismatch(pid: 1, field: "kind", expected: "agent", actual: "other", note: "miss", tolerated: false),
            schema,
            "AuditMismatch"
        )
        try assertFields(
            ClassificationSummary(
                snapshotCount: 1,
                kinds: [CLIJSONContract.ProcessKind.agent.rawValue: 1],
                agents: [ClassificationSummary.AgentRow(pid: 1, agentName: "claude", workingDirectory: nil)],
                orphans: [ClassificationSummary.OrphanRow(pid: 2, path: "/bin/sh", orphanReason: nil)]
            ),
            schema,
            "ClassificationSummary"
        )
        try assertFields(
            ClassificationSummary.AgentRow(pid: 1, agentName: "claude", workingDirectory: "/tmp/project"),
            schema,
            "ClassificationAgentRow"
        )
        try assertFields(
            ClassificationSummary.OrphanRow(pid: 2, path: "/bin/sh", orphanReason: CLIJSONContract.OrphanReason.missingParent.rawValue),
            schema,
            "ClassificationOrphanRow"
        )
        try assertFields(AgentRules(), schema, "AgentRules")
        try assertFields(PackageMarker(marker: "/@x/", agent: "x"), schema, "PackageMarker")
    }

    func testExitCodeConstantsMatchSchema() throws {
        let schema = try loadSchema()
        let codes = schema.object("exitCodes")
        for (name, value) in CLIJSONContract.ExitCode.all {
            XCTAssertEqual((codes[name] as? Int).map(Int32.init), value, name)
        }
        XCTAssertEqual(CLIExitCode.success, CLIJSONContract.ExitCode.success)
        XCTAssertEqual(CLIExitCode.failure, CLIJSONContract.ExitCode.failure)
        XCTAssertEqual(CLIExitCode.usage, CLIJSONContract.ExitCode.usage)
        XCTAssertEqual(CLIExitCode.blocked, CLIJSONContract.ExitCode.blocked)
        XCTAssertEqual(CLIExitCode.refused, CLIJSONContract.ExitCode.refused)
        XCTAssertEqual(codes.count, CLIJSONContract.ExitCode.all.count)
    }

    // MARK: - Helpers

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func loadSchema() throws -> [String: Any] {
        let url = repoRoot().appendingPathComponent(CLIJSONContract.schemaRelativePath)
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw NSError(domain: "CLIJSONContractTests", code: 1)
        }
        return dictionary
    }

    private func assertFields<T: Encodable>(_ value: T, _ schema: [String: Any], _ name: String) throws {
        let expected = schema.fieldSet(name)
        let actual = try encodeKeys(value)
        XCTAssertEqual(actual, expected, name)
    }

    private func encodeKeys<T: Encodable>(_ value: T) throws -> Set<String> {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw NSError(domain: "CLIJSONContractTests", code: 2)
        }
        return Set(dictionary.keys)
    }

    private func assertEqual(_ left: Set<String>, _ right: [String], _ label: String) {
        XCTAssertEqual(left, Set(right), label)
    }

    private func assertEqual(_ left: Set<String>, _ right: Set<String>, _ label: String) {
        XCTAssertEqual(left, right, label)
    }
}

private extension Dictionary where Key == String, Value == Any {
    func stringSet(_ key: String) -> Set<String> {
        Set((self[key] as? [String]) ?? [])
    }

    func string(_ key: String) -> String {
        self[key] as? String ?? ""
    }

    func object(_ key: String) -> [String: Any] {
        self[key] as? [String: Any] ?? [:]
    }

    func fieldSet(_ name: String) -> Set<String> {
        let fields = self["fields"] as? [String: Any] ?? [:]
        return Set((fields[name] as? [String]) ?? [])
    }
}
