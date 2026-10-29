import Darwin
import Foundation

enum ProcessKind: String, Equatable, Sendable {
    case agent
    case service
    case browserRenderer
    case application
    case system
    case other
}

struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let startTimeMicroseconds: UInt64
    let userID: UInt32
}

struct ObservationToken: Sendable {
    let generation: UInt64
    let instant: ContinuousClock.Instant
}

enum ObservationFreshness: String, Sendable {
    case current
    case stale
    case unavailable
}

enum AlertReason: Hashable, Sendable {
    case sustainedCPU(percent: Double)
    case sustainedMemory(bytes: UInt64)
    case orphan(OrphanReason)

    var text: String {
        switch self {
        case let .sustainedCPU(percent):
            return "CPU \(Int(percent))% 이상이 지속됨"
        case let .sustainedMemory(bytes):
            return "메모리 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)) 이상이 지속됨"
        case let .orphan(reason):
            return reason.localizedDescription
        }
    }
}

struct ProcessActionability: Sendable {
    let identity: ProcessIdentity
    let observation: ObservationToken?
    let freshness: ObservationFreshness
    let isIgnored: Bool
    let isProtected: Bool

    var canAct: Bool {
        observation != nil && freshness == .current && !isIgnored && !isProtected
    }
}

enum OrphanReason: String, Sendable {
    case reparentedToLaunchd
    case missingParent
    case cyclicLineage
    case detachedSession
    case temporaryLaunchPath

    var localizedDescription: String {
        switch self {
        case .reparentedToLaunchd:
            return "부모 프로세스가 launchd로 바뀌었습니다"
        case .missingParent:
            return "부모 프로세스를 찾을 수 없습니다"
        case .cyclicLineage:
            return "비정상적인 부모 계보가 감지됐습니다"
        case .detachedSession:
            return "연결된 터미널 세션을 찾을 수 없습니다"
        case .temporaryLaunchPath:
            return "임시 폴더에서 시작된 채 남아 있습니다"
        }
    }
}

struct ProcessSnapshot: Identifiable, Equatable, Sendable {
    let id: Int32
    let parentPID: Int32
    let processGroupID: Int32
    let userID: UInt32
    let tty: String
    var cpuPercent: Double
    var residentBytes: UInt64
    var state: String
    let elapsed: String
    let executablePath: String
    var startTimeMicroseconds: UInt64 = 0
    var workingDirectory: String?
    var worktreeState: WorktreeState?
    var orphanReason: OrphanReason? = nil
    /// For an interpreter process (`node`, `python3`), the script or module
    /// it runs; that is where an npm/pip-installed agent shows its name.
    var launchScript: String? = nil
    /// First positional after argv[0] (or after the interpreter script).
    var launchSubcommand: String? = nil
    /// The nearest coding agent this process descends from, when it is not
    /// an agent itself: a build, test run, or MCP server the agent started.
    var agentAncestor: AgentAncestor? = nil

    var identity: ProcessIdentity {
        ProcessIdentity(
            pid: id,
            startTimeMicroseconds: startTimeMicroseconds,
            userID: userID
        )
    }

    var suspectedOrphan: Bool {
        orphanReason != nil
    }

    var displayName: String {
        if executablePath.contains("Google Chrome Helper (Renderer)") {
            return "Chrome 렌더러"
        }

        if executablePath.contains("Google Chrome Helper") {
            return "Chrome 도우미"
        }

        if let appName = rendererAppName {
            return "\(appName) 렌더러"
        }

        if let agentName {
            return agentName
        }

        let name = URL(fileURLWithPath: executablePath).lastPathComponent
        return name.isEmpty ? executablePath : name
    }

    /// The coding agent this process is, if any.
    var agentName: String? {
        AgentCatalog.agentName(command: executablePath, launchScript: launchScript)
    }

    /// `Aside Helper (Renderer)` → `Aside`: a Chromium/Electron renderer.
    private var rendererAppName: String? {
        let name = URL(fileURLWithPath: executablePath).lastPathComponent
        guard let range = name.range(of: " Helper (Renderer)") else { return nil }
        let appName = String(name[..<range.lowerBound])
        return appName.isEmpty ? nil : appName
    }

    var kind: ProcessKind {
        let lowercasePath = executablePath.lowercased()

        if executablePath.contains("Helper (Renderer)") {
            return .browserRenderer
        }

        if lowercasePath.hasPrefix("/system/")
            || lowercasePath.hasPrefix("/usr/libexec/")
            || lowercasePath.hasPrefix("/sbin/")
            || lowercasePath.hasPrefix("/usr/sbin/") {
            return .system
        }

        if isService {
            return .service
        }

        if agentName != nil {
            return .agent
        }

        if lowercasePath.contains(".app/contents/") {
            return .application
        }

        return .other
    }

    /// A resident server: known agent server subcommand, or a headless
    /// (ppid ≤ 1, no TTY) process that was not started from a temp path.
    var isService: Bool {
        if agentName != nil,
           let subcommand = launchSubcommand,
           AgentCatalog.serviceSubcommands.contains(subcommand) {
            return true
        }

        guard parentPID <= 1, tty == "??" else { return false }

        let lowercasePath = executablePath.lowercased()
        if executablePath.contains("Helper (Renderer)") { return false }
        if lowercasePath.hasPrefix("/system/")
            || lowercasePath.hasPrefix("/usr/libexec/")
            || lowercasePath.hasPrefix("/sbin/")
            || lowercasePath.hasPrefix("/usr/sbin/") {
            return false
        }
        // Framework Pythons live in `Python.app/Contents/MacOS/Python`.
        // Those are interpreters, not app processes.
        if lowercasePath.contains(".app/contents/"), !AgentCatalog.isInterpreter(executablePath) {
            return false
        }

        // A named agent reparented to launchd with no TTY is a daemon, even
        // when it was launched from a temp path (then it is also an orphan).
        if agentName != nil { return true }

        if LaunchPath.isTemporaryLaunch(of: self) { return false }
        return true
    }

    /// The project folder name: the process's own working directory, or for
    /// a process an agent started, that agent's.
    var projectName: String? {
        guard let workingDirectory = workingDirectory ?? agentAncestor?.workingDirectory,
              !workingDirectory.isEmpty,
              workingDirectory != "/"
        else {
            return nil
        }

        let name = URL(fileURLWithPath: workingDirectory).lastPathComponent
        return name.isEmpty ? nil : name
    }

    var isSuspended: Bool {
        state.contains("T")
    }

    var isProtected: Bool {
        let lowercasePath = executablePath.lowercased()
        return id <= 1
            || id == getpid()
            || startTimeMicroseconds == 0
            || userID != getuid()
            || lowercasePath.hasPrefix("/system/")
            || lowercasePath.hasPrefix("/usr/libexec/")
            || lowercasePath.hasPrefix("/usr/sbin/")
            || lowercasePath.hasPrefix("/sbin/")
    }

    var canControl: Bool {
        !isProtected
    }
}

struct AgentAncestor: Equatable, Sendable {
    let pid: Int32
    let name: String
    var workingDirectory: String?
}
