import Darwin
import Foundation

/// Machine-readable CLI `--json` strings. Values are the historical rawValues;
/// new names may be added, existing names must not change.
enum CLIJSONContract {
    static let schemaRelativePath = "docs/cli-json.schema.json"
    static let defaultJournalLimit = 50
    static let auditMissingKind = "missing"

    enum ExitCode {
        static let success: Int32 = 0
        static let failure: Int32 = 1
        static let usage: Int32 = 2
        static let blocked: Int32 = 3
        static let refused: Int32 = 4

        static let all: [(name: String, value: Int32)] = [
            ("success", success),
            ("failure", failure),
            ("usage", usage),
            ("blocked", blocked),
            ("refused", refused),
        ]
    }

    enum ProcessKind: String, CaseIterable, Sendable {
        case agent
        case service
        case browserRenderer
        case application
        case system
        case other
    }

    enum OrphanReason: String, CaseIterable, Sendable {
        case reparentedToLaunchd
        case missingParent
        case cyclicLineage
        case detachedSession
        case temporaryLaunchPath
    }

    enum AlertReasonKind: String, CaseIterable, Sendable {
        case sustainedCPU
        case sustainedMemory
        case orphan
    }

    enum ActionOutcome: String, CaseIterable, Sendable {
        case signalDelivered
        case suspended
        case resumed
        case awaitingExit
        case exited
        case stillRunning
        case identityChanged
        case verificationFailed

        static let failedPrefix = "failed:"
    }

    enum JournalSource: String, CaseIterable, Sendable {
        case app
        case auto
        case cli
    }

    enum JournalAction: String, CaseIterable, Sendable {
        case suspend
        case resume
        case terminate
        case forceQuit
    }

    enum AutoSuspendScope: String, CaseIterable, Sendable {
        case agent
        case session
    }

    enum AgentConfidence: String, CaseIterable, Sendable {
        case known
        case suspected
    }

    enum WatchEventType: String, CaseIterable, Sendable {
        case watchStart = "watch.start"
        case autoSuspendRestrict = "auto-suspend.restrict"
        case resumedByUser = "resumed.by-user"
        case alertCPU = "alert.cpu"
        case alertMemory = "alert.memory"
        case clearedCPU = "cleared.cpu"
        case clearedMemory = "cleared.memory"
        case sessionHot = "session-hot"
        case sessionHighMemory = "session-high-memory"
        case autoSuspend = "auto-suspend"
        case autoSuspendFailed = "auto-suspend.failed"
        case autoSuspendSkipped = "auto-suspend.skipped"
        case sample = "sample"
        case sampleFailed = "sample.failed"
        case watchEnd = "watch.end"
    }

    enum ListScope: String, CaseIterable, Sendable {
        case attention
        case agents
        case all
    }

    enum ListFlag {
        static let cpu = "cpu"
        static let memory = "memory"
        static let orphan = "orphan"
        static let suspected = "suspected"
        static let stoppedByWatchdog = "stopped-by-watchdog"
        static let protected = "protected"
        static let viaPrefix = "via:"

        static let allFixed: [String] = [
            cpu, memory, orphan, suspected, stoppedByWatchdog, protected,
        ]

        static func via(name: String, pid: Int32) -> String {
            "via:\(name)#\(pid)"
        }
    }

    enum SessionFlag {
        static let suspended = "suspended"
        static let orphan = ListFlag.orphan
        static let suspected = ListFlag.suspected
        static let service = "service"

        static let allFixed: [String] = [suspended, orphan, suspected, service]
    }

    enum StoppedSource: String, CaseIterable, Sendable {
        case auto
        case manual
        case cli
    }

    enum ControlAction: String, CaseIterable, Sendable {
        case suspend
        case resume
        case terminate
        case forceQuit = "force-quit"
    }

    enum ControlResult: String, CaseIterable, Sendable {
        case ok
        case unverified
        case blocked
        case refused
        case usage
        case failed
    }

    enum StoppedResumeResult: String, CaseIterable, Sendable {
        case resumed
        case failed
        case skipped
    }

    static func outcomeString(_ outcome: ProcessActionOutcome) -> String {
        switch outcome {
        case .signalDelivered: return ActionOutcome.signalDelivered.rawValue
        case .suspended: return ActionOutcome.suspended.rawValue
        case .resumed: return ActionOutcome.resumed.rawValue
        case .awaitingExit: return ActionOutcome.awaitingExit.rawValue
        case .exited: return ActionOutcome.exited.rawValue
        case .stillRunning: return ActionOutcome.stillRunning.rawValue
        case .identityChanged: return ActionOutcome.identityChanged.rawValue
        case .verificationFailed: return ActionOutcome.verificationFailed.rawValue
        case let .failed(message): return ActionOutcome.failedPrefix + message
        }
    }

    static func alertReasonKind(_ reason: AlertReason) -> String {
        switch reason {
        case .sustainedCPU: return AlertReasonKind.sustainedCPU.rawValue
        case .sustainedMemory: return AlertReasonKind.sustainedMemory.rawValue
        case .orphan: return AlertReasonKind.orphan.rawValue
        }
    }
}

extension ProcessKind {
    var cliJSONValue: String {
        switch self {
        case .agent: return CLIJSONContract.ProcessKind.agent.rawValue
        case .service: return CLIJSONContract.ProcessKind.service.rawValue
        case .browserRenderer: return CLIJSONContract.ProcessKind.browserRenderer.rawValue
        case .application: return CLIJSONContract.ProcessKind.application.rawValue
        case .system: return CLIJSONContract.ProcessKind.system.rawValue
        case .other: return CLIJSONContract.ProcessKind.other.rawValue
        }
    }
}

extension OrphanReason {
    var cliJSONValue: String {
        switch self {
        case .reparentedToLaunchd: return CLIJSONContract.OrphanReason.reparentedToLaunchd.rawValue
        case .missingParent: return CLIJSONContract.OrphanReason.missingParent.rawValue
        case .cyclicLineage: return CLIJSONContract.OrphanReason.cyclicLineage.rawValue
        case .detachedSession: return CLIJSONContract.OrphanReason.detachedSession.rawValue
        case .temporaryLaunchPath: return CLIJSONContract.OrphanReason.temporaryLaunchPath.rawValue
        }
    }
}

extension AgentConfidence {
    var cliJSONValue: String {
        switch self {
        case .known: return CLIJSONContract.AgentConfidence.known.rawValue
        case .suspected: return CLIJSONContract.AgentConfidence.suspected.rawValue
        }
    }
}

extension MonitorSettings.AutoSuspendScope {
    var cliJSONValue: String {
        switch self {
        case .agent: return CLIJSONContract.AutoSuspendScope.agent.rawValue
        case .session: return CLIJSONContract.AutoSuspendScope.session.rawValue
        }
    }
}

extension SuspensionRecord.Source {
    var cliJSONValue: String {
        switch self {
        case .auto: return CLIJSONContract.StoppedSource.auto.rawValue
        case .manual: return CLIJSONContract.StoppedSource.manual.rawValue
        case .cli: return CLIJSONContract.StoppedSource.cli.rawValue
        }
    }
}

extension ActionJournalEntry.Source {
    var cliJSONValue: String {
        switch self {
        case .app: return CLIJSONContract.JournalSource.app.rawValue
        case .auto: return CLIJSONContract.JournalSource.auto.rawValue
        case .cli: return CLIJSONContract.JournalSource.cli.rawValue
        }
    }
}

extension ActionJournalEntry.ActionKind {
    var cliJSONValue: String {
        switch self {
        case .suspend: return CLIJSONContract.JournalAction.suspend.rawValue
        case .resume: return CLIJSONContract.JournalAction.resume.rawValue
        case .terminate: return CLIJSONContract.JournalAction.terminate.rawValue
        case .forceQuit: return CLIJSONContract.JournalAction.forceQuit.rawValue
        }
    }
}

// MARK: - JSON records

struct ProcessRecord: Encodable, Equatable, Sendable {
    let token: String
    let pid: Int32
    let parentPID: Int32
    let userID: UInt32
    let name: String
    let path: String
    let kind: String
    let state: String
    let suspended: Bool
    let cpuPercent: Double
    let residentBytes: UInt64
    let tty: String
    let elapsed: String
    let orphanReason: String?
    let launchScript: String?
    let agentAncestorPID: Int32?
    let agentAncestorName: String?
    let workingDirectory: String?
    let worktree: String?
    let controllable: Bool
    let watchdogSuspended: Bool
    let flags: [String]

    init(_ process: ProcessSnapshot, flags: [String], watchdogSuspended: Bool) {
        token = IdentityToken(process.identity).description
        pid = process.id
        parentPID = process.parentPID
        userID = process.userID
        name = process.displayName
        path = process.executablePath
        kind = process.kind.cliJSONValue
        state = process.state
        suspended = process.isSuspended
        cpuPercent = (process.cpuPercent * 10).rounded() / 10
        residentBytes = process.residentBytes
        tty = process.tty
        elapsed = process.elapsed
        orphanReason = process.orphanReason?.cliJSONValue
        launchScript = process.launchScript
        agentAncestorPID = process.agentAncestor?.pid
        agentAncestorName = process.agentAncestor?.name
        workingDirectory = process.workingDirectory
        worktree = process.worktreeState.map { state in
            [state.verdict.localizedDescription, state.detail].compactMap { $0 }.joined(separator: " · ")
        }
        controllable = !process.isProtected
        self.watchdogSuspended = watchdogSuspended
        self.flags = flags
    }
}

struct SessionRecord: Encodable, Equatable, Sendable {
    let id: String
    let rootPID: Int32
    let name: String
    let kind: String
    let workingDirectory: String?
    let projectName: String?
    let members: [Int32]
    let memberCount: Int
    let cpuPercent: Double
    let residentBytes: UInt64
    let isSuspended: Bool
    let elapsed: String

    init(_ session: AgentSession) {
        id = IdentityToken(session.id).description
        rootPID = session.rootPID
        name = session.name
        kind = session.kind.cliJSONValue
        workingDirectory = session.workingDirectory
        projectName = session.projectName
        members = session.members.map(\.pid)
        memberCount = session.memberCount
        cpuPercent = session.cpuPercent
        residentBytes = session.residentBytes
        isSuspended = session.isSuspended
        elapsed = session.elapsed
    }
}

struct SessionAlertEvent: Encodable, Equatable, Sendable {
    let event: String
    let token: String
    let name: String
    let cpuPercent: Double
    let memberCount: Int
}

struct WatchEvent: Encodable, Equatable, Sendable {
    let time: Date
    let type: String
    let token: String?
    let name: String?
    let detail: String?
}

struct CLIStoppedRecord: Encodable, Equatable, Sendable {
    let token: String
    let name: String
    let path: String
    let suspendedAt: Date
    let source: String
    let groupID: String?
}

struct CLIStoppedResumeRecord: Encodable, Equatable, Sendable {
    let token: String
    let name: String
    let result: String
    let message: String
}

struct CLIDoctorReport: Encodable, Equatable, Sendable {
    var libprocMilliseconds: [Double] = []
    var psMilliseconds: Double?
    var processCount = 0
    var ownProcessCount = 0
    var agentCount = 0
    var agentsWithWorkingDirectory = 0
    var ledgerPath: String
    var ledgerEntries = 0
    var settings: [String: Double]
    var autoSuspendEnabled: Bool
    var appRunning: Bool
    var loginItemStatus: String?
    var loginItemOptedOut: Bool
    var loginItemLastError: String?
    var rulesPath: String
    var rulesStatus: String
    var problems: [String] = []
}

struct CLIRulesShowReport: Encodable, Equatable, Sendable {
    let path: String
    let status: String
    let reason: String?
    let rules: AgentRules?
    let validationIssues: [String]
    let appliedCount: Int
}
