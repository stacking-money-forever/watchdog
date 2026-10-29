import Darwin
import Foundation

// watchdog-cli — verification front end for WatchdogCore. It drives the same
// sampling, detection, authorization, and control code the menu bar app ships.

let usageText = """
사용법: watchdog-cli <명령> [옵션]

조회 (안전):
  list [--scope attention|agents|all] [--search 텍스트] [--interval 초] [--json]
      CPU%를 계산하려고 두 번 샘플링합니다(기본 1초 간격). TOKEN은 제어 명령에 씁니다.
  sessions [--interval 초] [--json]
      에이전트·서비스 세션(루트와 가장 가까운 자손)의 CPU·메모리 합계를 보여 줍니다. 지속 판정은 watch.
  inspect <TOKEN|PID> [--json]
      한 프로세스의 신원, 상태, 작업 디렉터리, 워크트리 상태를 보여 줍니다.
  watch [--interval 초] [--count N] [--duration 초] [--cpu %] [--sustain 초] [--memory GB]
        [--auto-suspend] [--json]
      앱과 같은 감지 엔진으로 지속 감시하며 경고 이벤트를 출력합니다. Ctrl-C로 끝냅니다.
  stopped [--resume-all] [--json]
      Watchdog(앱·CLI)이 일시 정지한 채 멈춰 있는 프로세스를 보여 줍니다.
  doctor [--json]
      샘플링 비용과 환경을 진단합니다.
  rules show [--json]
      사용자 규칙 파일 경로와 적용 내용, 검증 경고를 보여 줍니다.
  rules validate [FILE]
      규칙 파일을 읽어 검증합니다. 문제가 있으면 종료 코드 1입니다.
  rules init
      표준 경로에 예시 규칙 파일을 만듭니다. 이미 있으면 거부합니다.
  snapshot [--out FILE]
      현재 프로세스 목록을 분류 정확도 픽스처와 같은 JSON으로 저장합니다. --out이 없으면 표준 출력입니다.
  audit FIXTURE [--labels FILE] [--json]
      저장된 스냅샷을 분류합니다. 라벨이 있으면 필드별 일치·불일치 보고서를 냅니다.

제어:
  suspend <TOKEN|PID> [--force]     SIGSTOP. 되돌릴 수 있음. 에이전트가 아니면 경고합니다.
  resume <TOKEN|PID>                SIGCONT.
  terminate <TOKEN> [--force]       SIGTERM. --force 없이는 차단되고 무엇을 할지만 출력합니다.
  force-quit <TOKEN> [--force]      SIGKILL. --force 없이는 차단됩니다.

  TOKEN은 pid:시작시각(µs):uid 입니다. terminate·force-quit은 PID만으로 실행할 수 없습니다.
  --force는 되돌릴 수 없는 동작을 하겠다는 확인일 뿐입니다. PID 1, Watchdog 자신,
  다른 사용자, 시스템 경로, 신원 불일치·확인 불가 대상은 --force로도 거부됩니다.

종료 코드: 0 성공 · 1 실패 · 2 사용법 오류 · 3 --force 필요(차단) · 4 안전 계약상 거부
"""

// MARK: - Arguments

struct Arguments {
    var command: String?
    var positionals: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    static let valueOptions: Set<String> = [
        "--scope", "--search", "--interval", "--count", "--duration", "--cpu", "--sustain", "--memory",
        "--out", "--labels",
    ]
    static let knownFlags: Set<String> = ["--json", "--force", "--auto-suspend", "--resume-all", "--help", "-h", "--version"]

    init(_ raw: [String]) throws {
        var iterator = raw.makeIterator()
        while let argument = iterator.next() {
            if Self.valueOptions.contains(argument) {
                guard let value = iterator.next() else {
                    throw CLIUsageError("\(argument)에 값이 필요합니다.")
                }
                options[argument] = value
            } else if argument.hasPrefix("-") {
                guard Self.knownFlags.contains(argument) else {
                    throw CLIUsageError("알 수 없는 옵션: \(argument)")
                }
                flags.insert(argument)
            } else if command == nil {
                command = argument
            } else {
                positionals.append(argument)
            }
        }
    }

    var json: Bool { flags.contains("--json") }
    var force: Bool { flags.contains("--force") }

    func double(_ name: String, default value: Double, range: ClosedRange<Double>) throws -> Double {
        guard let text = options[name] else { return value }
        guard let parsed = Double(text), parsed.isFinite, range.contains(parsed) else {
            throw CLIUsageError("\(name) 값은 \(range.lowerBound)…\(range.upperBound) 범위의 숫자여야 합니다.")
        }
        return parsed
    }
}

struct CLIUsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Output helpers

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func emitJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

func memoryText(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
}

func pad(_ text: String, _ width: Int) -> String {
    let count = text.count
    if count >= width { return String(text.prefix(width)) }
    return text + String(repeating: " ", count: width - count)
}

func inspectKindText(_ process: ProcessSnapshot) -> String {
    if process.agentConfidence == .suspected { return "에이전트(추정)" }
    if process.kind == .service { return "서비스" }
    return process.kind.rawValue
}

func activateUserRules() -> AgentRules.LoadResult {
    let loaded = AgentRules.load(from: AgentRules.standardURL())
    switch loaded {
    case let .loaded(rules, _):
        AgentCatalog.activate(rules: rules)
    case .absent, .invalid:
        AgentCatalog.resetToBuiltIn()
    }
    return loaded
}

func rulesStatusLine(_ loaded: AgentRules.LoadResult) -> String {
    switch loaded {
    case let .loaded(rules, _):
        return "\(rules.appliedCount)개 규칙 적용"
    case .absent:
        return "없음"
    case let .invalid(_, reason):
        return "손상(\(reason))"
    }
}

struct ProcessRecord: Encodable {
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
        kind = process.kind.rawValue
        state = process.state
        suspended = process.isSuspended
        cpuPercent = (process.cpuPercent * 10).rounded() / 10
        residentBytes = process.residentBytes
        tty = process.tty
        elapsed = process.elapsed
        orphanReason = process.orphanReason?.rawValue
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

struct SessionRecord: Encodable {
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
        kind = session.kind.rawValue
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

struct SessionAlertEvent: Encodable {
    let event: String
    let token: String
    let name: String
    let cpuPercent: Double
    let memberCount: Int
}

func appSettings() -> MonitorSettings {
    MonitorSettings(defaults: UserDefaults(suiteName: MonitorSettings.defaultsSuiteName) ?? .standard)
}

/// Two samples so CPU% is an interval delta, like the app's second refresh.
func sampleWithCPU(interval: Double) async throws -> [ProcessSnapshot] {
    let sampler = ProcessSampler()
    _ = try await sampler.sample()
    try await Task.sleep(for: .milliseconds(Int(interval * 1_000)))
    let sample = try await sampler.sample()
    var processes = sample.processes
    // Temporary-path orphans need cwd (and leftover `/bin/sh $TMPDIR/…`
    // scripts need it on the first list). Only ppid ≤ 1 is cheap enough:
    // those are the processes the rule inspects.
    for index in processes.indices where processes[index].parentPID <= 1 && processes[index].workingDirectory == nil {
        processes[index].workingDirectory = WorkingDirectoryResolver.currentDirectory(pid: processes[index].id)
    }
    return OrphanClassifier.classify(processes)
}

// MARK: - Commands

func runList(_ arguments: Arguments) async throws -> Int32 {
    let scope = arguments.options["--scope"] ?? "attention"
    guard ["attention", "agents", "all"].contains(scope) else {
        throw CLIUsageError("--scope는 attention, agents, all 중 하나입니다.")
    }
    let interval = try arguments.double("--interval", default: 1, range: 0.2...10)
    let settings = appSettings()
    var processes = MonitorEngine.displayOrder(try await sampleWithCPU(interval: interval))
    let stopped = Set((try? SuspensionLedger.standard().reconcile())?.map(\.identity) ?? [])

    func flags(_ process: ProcessSnapshot) -> [String] {
        var flags: [String] = []
        if process.cpuPercent >= settings.cpuThreshold { flags.append("cpu") }
        if process.residentBytes >= settings.memoryThresholdBytes { flags.append("memory") }
        if process.suspectedOrphan { flags.append("orphan") }
        if process.agentConfidence == .suspected { flags.append("suspected") }
        if let ancestor = process.agentAncestor { flags.append("via:\(ancestor.name)#\(ancestor.pid)") }
        if stopped.contains(process.identity) { flags.append("stopped-by-watchdog") }
        if process.isProtected { flags.append("protected") }
        return flags
    }

    switch scope {
    case "attention":
        processes = processes.filter {
            !$0.isProtected
                && ($0.cpuPercent >= settings.cpuThreshold
                    || $0.residentBytes >= settings.memoryThresholdBytes
                    || stopped.contains($0.identity))
        }
    case "agents":
        processes = processes.filter { $0.kind == .agent || ($0.kind == .service && $0.agentName != nil) }
    default:
        break
    }
    if let search = arguments.options["--search"]?.lowercased(), !search.isEmpty {
        processes = processes.filter {
            $0.displayName.lowercased().contains(search)
                || $0.executablePath.lowercased().contains(search)
                || ($0.launchScript?.lowercased().contains(search) ?? false)
                || String($0.id) == search
        }
    }
    var agentDirectories: [Int32: String?] = [:]
    func agentDirectory(_ pid: Int32) -> String? {
        if let cached = agentDirectories[pid] { return cached }
        let directory = WorkingDirectoryResolver.currentDirectory(pid: pid)
        agentDirectories[pid] = directory
        return directory
    }
    for index in processes.indices {
        if processes[index].kind == .agent {
            processes[index].workingDirectory = agentDirectory(processes[index].id)
        } else if let pid = processes[index].agentAncestor?.pid {
            processes[index].agentAncestor?.workingDirectory = agentDirectory(pid)
        }
    }

    if arguments.json {
        emitJSON(processes.map { ProcessRecord($0, flags: flags($0), watchdogSuspended: stopped.contains($0.identity)) })
        return CLIExitCode.success
    }
    if scope == "attention" {
        print("기준: CPU \(Int(settings.cpuThreshold))% · 메모리 \(memoryText(settings.memoryThresholdBytes)) (순간값. 지속 판정은 watch)")
    }
    if processes.isEmpty {
        print("해당하는 프로세스가 없습니다.")
        return CLIExitCode.success
    }
    print(pad("TOKEN", 30) + pad("CPU%", 8) + pad("MEM", 10) + pad("ST", 4) + pad("KIND", 16) + pad("NAME", 24) + "FLAGS / PROJECT")
    for process in processes {
        let project = process.projectName.map { "· \($0)" } ?? ""
        print(
            pad(IdentityToken(process.identity).description, 30)
                + pad(String(format: "%.1f", process.cpuPercent), 8)
                + pad(memoryText(process.residentBytes), 10)
                + pad(process.state, 4)
                + pad(process.kind.rawValue, 16)
                + pad(process.displayName, 24)
                + ([flags(process).joined(separator: ","), project].filter { !$0.isEmpty }.joined(separator: " "))
        )
    }
    return CLIExitCode.success
}

func runSessions(_ arguments: Arguments) async throws -> Int32 {
    let interval = try arguments.double("--interval", default: 1, range: 0.2...10)
    var processes = try await sampleWithCPU(interval: interval)
    var agentDirectories: [Int32: String?] = [:]
    func agentDirectory(_ pid: Int32) -> String? {
        if let cached = agentDirectories[pid] { return cached }
        let directory = WorkingDirectoryResolver.currentDirectory(pid: pid)
        agentDirectories[pid] = directory
        return directory
    }
    for index in processes.indices where processes[index].kind == .agent || processes[index].kind == .service {
        if processes[index].workingDirectory == nil {
            processes[index].workingDirectory = agentDirectory(processes[index].id)
        }
    }
    let byIdentity = Dictionary(processes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
    // Other users' daemons and memberless system services are not sessions
    // anyone will act on; keep the list to this user's agents and services
    // that run an agent or have started something.
    let sessions = SessionAggregator.sessions(from: processes).filter { session in
        guard session.id.userID == getuid() else { return false }
        if session.kind == .agent { return true }
        return session.memberCount > 0 || byIdentity[session.id]?.agentName != nil
    }
    if arguments.json {
        emitJSON(sessions.map(SessionRecord.init))
        return CLIExitCode.success
    }
    if sessions.isEmpty {
        print("해당하는 세션이 없습니다.")
        return CLIExitCode.success
    }
    print(pad("TOKEN", 30) + pad("CPU%", 8) + pad("MEM", 10) + pad("N", 4) + pad("KIND", 10) + pad("NAME", 24) + pad("PROJECT", 16) + "FLAGS")
    for session in sessions {
        var flags: [String] = []
        if session.isSuspended { flags.append("suspended") }
        if byIdentity[session.id]?.suspectedOrphan == true { flags.append("orphan") }
        if byIdentity[session.id]?.agentConfidence == .suspected { flags.append("suspected") }
        if session.kind == .service { flags.append("service") }
        print(
            pad(IdentityToken(session.id).description, 30)
                + pad(String(format: "%.1f", session.cpuPercent), 8)
                + pad(memoryText(session.residentBytes), 10)
                + pad(String(session.memberCount), 4)
                + pad(session.kind.rawValue, 10)
                + pad(session.name, 24)
                + pad(String((session.projectName ?? "").prefix(15)), 16)
                + flags.joined(separator: ",")
        )
    }
    return CLIExitCode.success
}

func runInspect(_ arguments: Arguments) async throws -> Int32 {
    guard let text = arguments.positionals.first, let target = CLITarget(parsing: text) else {
        throw CLIUsageError("inspect에는 TOKEN 또는 PID가 필요합니다.")
    }
    let processes = try await sampleWithCPU(interval: 0.5)
    guard var process = processes.first(where: { $0.id == target.pid }) else {
        printError(CLIRefusal.notFound.message)
        return CLIExitCode.failure
    }
    if case let .token(token) = target, token.identity != process.identity {
        printError(CLIRefusal.identityMismatch(live: process.identity).message)
        return CLIExitCode.refused
    }
    process.workingDirectory = WorkingDirectoryResolver.currentDirectory(pid: process.id)
    if let directory = process.workingDirectory, directory != "/" {
        process.worktreeState = await WorktreeStateResolver.lookup(
            path: directory,
            runner: { try await CommandRunner.run($0, arguments: $1, deadline: $2) },
            deadline: .seconds(2)
        )
    }
    let ledgerStopped = (try? SuspensionLedger.standard().reconcile())?.contains { $0.identity == process.identity } ?? false
    let refusal = CLIPolicy.refusal(target: .token(IdentityToken(process.identity)), live: process, currentUserID: getuid(), currentPID: getpid())
    if arguments.json {
        emitJSON(ProcessRecord(process, flags: refusal.map { [$0.message] } ?? [], watchdogSuspended: ledgerStopped))
        return CLIExitCode.success
    }
    let lines: [(String, String)] = [
        ("TOKEN", IdentityToken(process.identity).description),
        ("이름", process.displayName),
        ("경로(argv0)", process.executablePath),
        ("실행 스크립트", process.launchScript ?? "-"),
        ("종류", inspectKindText(process)),
        ("PID / PPID / PGID", "\(process.id) / \(process.parentPID) / \(process.processGroupID)"),
        ("UID", "\(process.userID)"),
        ("상태", process.state + (process.isSuspended ? " (정지됨)" : "")),
        ("실행 시간", process.elapsed),
        ("TTY", process.tty),
        ("CPU", String(format: "%.1f%%", process.cpuPercent)),
        ("메모리", memoryText(process.residentBytes)),
        ("고아 의심", process.orphanReason?.localizedDescription ?? "아님"),
        ("시작한 에이전트", process.agentAncestor.map { "\($0.name) (PID \($0.pid))" } ?? "-"),
        ("작업 디렉터리", process.workingDirectory ?? "확인 불가"),
        ("워크트리", process.worktreeState.map { [$0.verdict.localizedDescription, $0.detail].compactMap { $0 }.joined(separator: " · ") } ?? "-"),
        ("Watchdog이 정지함", ledgerStopped ? "예" : "아니오"),
        ("제어 가능", refusal.map { "아니오: \($0.message)" } ?? "예"),
    ]
    for (key, value) in lines {
        print(pad(key, 18) + value)
    }
    return CLIExitCode.success
}

func runControl(_ action: CLIAction, _ arguments: Arguments) async throws -> Int32 {
    guard arguments.positionals.count == 1, let target = CLITarget(parsing: arguments.positionals[0]) else {
        throw CLIUsageError("\(action.rawValue)에는 대상 하나(TOKEN\(action.isDestructive ? "" : " 또는 PID"))가 필요합니다.")
    }
    let control = CLIControl()
    let result = try await control.run(action, target: target, force: arguments.force)
    switch result {
    case let .decided(decision):
        switch decision {
        case .allow:
            return CLIExitCode.success
        case let .blocked(dryRun):
            printError(dryRun)
        case let .refused(refusal):
            printError("거부됨(--force로도 불가): \(refusal.message)")
        case let .usage(message):
            printError(message)
        }
        if arguments.json {
            emitJSON(["result": decision.exitCode == CLIExitCode.blocked ? "blocked" : decision.exitCode == CLIExitCode.refused ? "refused" : "usage"])
        }
        return decision.exitCode
    case let .failed(error, refused):
        printError((refused ? "거부됨: " : "실패: ") + (error.errorDescription ?? "\(error)"))
        if arguments.json { emitJSON(["result": refused ? "refused" : "failed", "error": error.errorDescription ?? ""]) }
        return refused ? CLIExitCode.refused : CLIExitCode.failure
    case let .performed(report):
        for warning in report.warnings {
            printError("경고: \(warning)")
        }
        if arguments.json {
            emitJSON([
                "result": report.outcome.isError ? "unverified" : "ok",
                "action": report.action.rawValue,
                "token": report.token.description,
                "name": report.name,
                "outcome": report.outcome.localizedDescription,
            ])
        } else {
            print("\(report.action.rawValue): \(report.name) (\(report.token)) → \(report.outcome.localizedDescription)")
        }
        return report.outcome.isError ? CLIExitCode.failure : CLIExitCode.success
    }
}

func runStopped(_ arguments: Arguments) async throws -> Int32 {
    let ledger = SuspensionLedger.standard()
    let records = try ledger.reconcile()
    if arguments.flags.contains("--resume-all") {
        struct ResumeResult: Encodable {
            let token: String
            let name: String
            let result: String
            let message: String
        }
        var failures = 0
        var results: [ResumeResult] = []
        let control = CLIControl(ledger: ledger)
        for record in records {
            let token = IdentityToken(record.identity).description
            let result = try await control.run(.resume, target: .token(IdentityToken(record.identity)), force: true)
            switch result {
            case let .performed(report):
                if report.outcome.isError { failures += 1 }
                results.append(.init(token: token, name: report.name, result: report.outcome.isError ? "failed" : "resumed", message: report.outcome.localizedDescription))
                if !arguments.json { print("resume: \(report.name) (\(report.token)) → \(report.outcome.localizedDescription)") }
            case let .failed(error, _):
                failures += 1
                let message = error.errorDescription ?? "\(error)"
                results.append(.init(token: token, name: record.displayName, result: "failed", message: message))
                if !arguments.json { printError("실패: \(record.displayName) (\(token)): \(message)") }
            case let .decided(decision):
                failures += 1
                results.append(.init(token: token, name: record.displayName, result: "skipped", message: "\(decision)"))
                if !arguments.json { printError("건너뜀: \(record.displayName): \(decision)") }
            }
        }
        if arguments.json {
            emitJSON(results)
        } else if records.isEmpty {
            print("Watchdog이 정지한 프로세스가 없습니다.")
        }
        return failures == 0 ? CLIExitCode.success : CLIExitCode.failure
    }
    if arguments.json {
        struct StoppedRecord: Encodable {
            let token: String
            let name: String
            let path: String
            let suspendedAt: Date
            let source: String
        }
        emitJSON(records.map {
            StoppedRecord(
                token: IdentityToken($0.identity).description,
                name: $0.displayName,
                path: $0.executablePath,
                suspendedAt: $0.suspendedAt,
                source: $0.source.rawValue
            )
        })
        return CLIExitCode.success
    }
    if records.isEmpty {
        print("Watchdog이 정지한 프로세스가 없습니다.")
        return CLIExitCode.success
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print(pad("TOKEN", 30) + pad("NAME", 24) + pad("SOURCE", 8) + "SUSPENDED AT")
    for record in records {
        print(
            pad(IdentityToken(record.identity).description, 30)
                + pad(record.displayName, 24)
                + pad(record.source.rawValue, 8)
                + formatter.string(from: record.suspendedAt)
        )
    }
    print("\n재개: watchdog-cli resume <TOKEN> 또는 watchdog-cli stopped --resume-all")
    return CLIExitCode.success
}

// MARK: - watch

struct WatchEvent: Encodable {
    let time: Date
    let type: String
    let token: String?
    let name: String?
    let detail: String?
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    var isSet: Bool { lock.withLock { stopped } }
    func set() { lock.withLock { stopped = true } }
}

func runWatch(_ arguments: Arguments) async throws -> Int32 {
    var settings = appSettings()
    settings.cpuThreshold = MonitorSettings.normalizedCPU(try arguments.double("--cpu", default: settings.cpuThreshold, range: 1...1_000))
    settings.sustainedDuration = MonitorSettings.normalizedDuration(try arguments.double("--sustain", default: settings.sustainedDuration, range: 2...300))
    settings.memoryThresholdGB = MonitorSettings.normalizedMemory(try arguments.double("--memory", default: settings.memoryThresholdGB, range: 0.1...1_024))
    // Auto-suspend never inherits the app setting; the CLI only stops
    // processes when explicitly asked.
    settings.autoSuspendEnabled = arguments.flags.contains("--auto-suspend")
    let interval = try arguments.double("--interval", default: 2, range: 0.5...60)
    var maximumTicks: Int?
    if let text = arguments.options["--count"] {
        guard let count = Int(text), count >= 1 else {
            throw CLIUsageError("--count 값은 1 이상의 정수여야 합니다.")
        }
        maximumTicks = count
    }
    let duration = try arguments.double("--duration", default: 0, range: 0...86_400)

    let stop = StopFlag()
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    interrupt.setEventHandler { stop.set() }
    interrupt.resume()

    func emit(_ type: String, _ process: ProcessSnapshot? = nil, _ detail: String? = nil) {
        if arguments.json {
            emitJSON(
                WatchEvent(
                    time: Date(),
                    type: type,
                    token: process.map { IdentityToken($0.identity).description },
                    name: process?.displayName,
                    detail: detail
                )
            )
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            var line = "[\(formatter.string(from: Date()))] \(type)"
            if let process { line += " \(process.displayName) (\(IdentityToken(process.identity)))" }
            if let detail { line += " · \(detail)" }
            print(line)
        }
        fflush(stdout)
    }

    emit(
        "watch.start",
        nil,
        "CPU \(Int(settings.cpuThreshold))% · 메모리 \(memoryText(settings.memoryThresholdBytes)) · 지속 \(Int(settings.sustainedDuration))초 · 자동 정지 \(settings.autoSuspendEnabled ? "켬" : "끔")"
    )
    let sampler = ProcessSampler()
    let control = CLIControl()
    var engine = MonitorEngine(continuityGap: .milliseconds(Int(max(5, interval * 2.5) * 1_000)))
    let clock = ContinuousClock()
    let started = clock.now
    var ticks = 0
    var previousHot: Set<ProcessIdentity> = []
    var previousHighMemory: Set<ProcessIdentity> = []
    var previousHotSessions: Set<ProcessIdentity> = []
    var previousHighMemorySessions: Set<ProcessIdentity> = []
    var autoSuspended: Set<ProcessIdentity> = []
    var failures = 0

    while !stop.isSet {
        if let maximumTicks, ticks >= maximumTicks { break }
        if duration > 0, started.duration(to: clock.now) >= .milliseconds(Int(duration * 1_000)) { break }
        ticks += 1
        do {
            let sample = try await sampler.sample()
            // A process this run stopped that is running again was resumed by
            // the user (app, `fg`, `watchdog-cli resume`); like the app, do not
            // stop it again.
            let sampled = Dictionary(sample.processes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
            for identity in autoSuspended {
                guard let process = sampled[identity] else {
                    autoSuspended.remove(identity)
                    continue
                }
                if !process.isSuspended {
                    engine.recordUserResume(identity)
                    autoSuspended.remove(identity)
                    emit("resumed.by-user", process, "자동 정지 대상에서 제외")
                }
            }
            let update = engine.ingest(sample.processes, settings: settings, at: clock.now)
            let byIdentity = Dictionary(update.processes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
            for identity in update.newlyHot {
                if let process = byIdentity[identity] {
                    emit("alert.cpu", process, String(format: "CPU %.0f%% ≥ %.0f%% 지속", process.cpuPercent, settings.cpuThreshold))
                }
            }
            for identity in update.newlyHighMemory {
                if let process = byIdentity[identity] {
                    emit("alert.memory", process, "메모리 \(memoryText(process.residentBytes)) 지속")
                }
            }
            for identity in previousHot.subtracting(update.hot) {
                emit("cleared.cpu", byIdentity[identity], byIdentity[identity] == nil ? "PID \(identity.pid) 종료됨" : nil)
            }
            for identity in previousHighMemory.subtracting(update.highMemory) {
                emit("cleared.memory", byIdentity[identity], byIdentity[identity] == nil ? "PID \(identity.pid) 종료됨" : nil)
            }
            let sessionsByID = Dictionary(update.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            func emitSession(_ event: String, _ session: AgentSession) {
                if arguments.json {
                    emitJSON(
                        SessionAlertEvent(
                            event: event,
                            token: IdentityToken(session.id).description,
                            name: session.name,
                            cpuPercent: (session.cpuPercent * 10).rounded() / 10,
                            memberCount: session.memberCount
                        )
                    )
                } else {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm:ss"
                    print(
                        "[\(formatter.string(from: Date()))] \(event) \(session.name) (\(IdentityToken(session.id))) · CPU \(Int(session.cpuPercent.rounded()))% · 멤버 \(session.memberCount)"
                    )
                }
                fflush(stdout)
            }
            for identity in update.hotSessions.subtracting(previousHotSessions) {
                if let session = sessionsByID[identity] {
                    emitSession("session-hot", session)
                }
            }
            for identity in update.highMemorySessions.subtracting(previousHighMemorySessions) {
                if let session = sessionsByID[identity] {
                    emitSession("session-high-memory", session)
                }
            }
            previousHot = update.hot
            previousHighMemory = update.highMemory
            previousHotSessions = update.hotSessions
            previousHighMemorySessions = update.highMemorySessions
            for candidate in update.autoSuspendCandidates {
                switch try await control.run(.suspend, target: .token(IdentityToken(candidate.identity)), force: true) {
                case let .performed(report):
                    autoSuspended.insert(candidate.identity)
                    emit("auto-suspend", candidate, report.outcome.localizedDescription)
                case let .failed(error, _):
                    emit("auto-suspend.failed", candidate, error.errorDescription)
                case let .decided(decision):
                    emit("auto-suspend.skipped", candidate, "\(decision)")
                }
            }
            if !arguments.json, ticks == 1 {
                emit("sample", nil, "\(update.processes.count)개 프로세스 관찰")
            }
        } catch {
            failures += 1
            engine.samplingFailed()
            previousHot = []
            previousHighMemory = []
            previousHotSessions = []
            previousHighMemorySessions = []
            emit("sample.failed", nil, error.localizedDescription)
        }
        let deadline = clock.now.advanced(by: .milliseconds(Int(interval * 1_000)))
        while !stop.isSet, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    interrupt.cancel()
    emit("watch.end", nil, "\(ticks)회 샘플 · 실패 \(failures)회")
    return failures == 0 ? CLIExitCode.success : CLIExitCode.failure
}

// MARK: - doctor

func runDoctor(_ arguments: Arguments) async throws -> Int32 {
    struct Report: Encodable {
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
    let clock = ContinuousClock()
    let settings = appSettings()
    let ledgerURL = ProcessInfo.processInfo.environment[SuspensionLedger.pathEnvironmentKey]
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Watchdog/suspensions.json").path ?? "?"
    var report = Report(
        ledgerPath: ledgerURL,
        settings: [
            "cpuThreshold": settings.cpuThreshold,
            "sustainedDuration": settings.sustainedDuration,
            "memoryThresholdGB": settings.memoryThresholdGB,
        ],
        autoSuspendEnabled: settings.autoSuspendEnabled,
        appRunning: false,
        loginItemOptedOut: false,
        rulesPath: AgentRules.standardURL().path,
        rulesStatus: ""
    )
    let rulesLoad = AgentRules.load(from: AgentRules.standardURL())
    report.rulesStatus = rulesStatusLine(rulesLoad)
    if case let .invalid(_, reason) = rulesLoad {
        report.problems.append("사용자 규칙 손상: \(reason)")
    }
    // The app records what SMAppService last told it; the CLI cannot ask on
    // the app's behalf (the status is resolved for the calling process).
    let appDefaults = UserDefaults(suiteName: MonitorSettings.defaultsSuiteName) ?? .standard
    report.loginItemStatus = appDefaults.string(forKey: "launchAtLogin.lastStatus")
    report.loginItemOptedOut = appDefaults.bool(forKey: "launchAtLogin.userOptedOut")
    report.loginItemLastError = appDefaults.string(forKey: "launchAtLogin.lastError")
    var rows: [RawProcessRow] = []
    // First run is cold; the next two reuse the argv cache the app keeps
    // between samples.
    let cache = CommandNameCache()
    for _ in 0..<3 {
        let start = clock.now
        rows = try LibprocProcessLister.list(cache: cache)
        let elapsed = start.duration(to: clock.now)
        report.libprocMilliseconds.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000)
    }
    let psStart = clock.now
    if (try? await ProcessSampler.psRows(runner: { try await CommandRunner.run($0, arguments: $1, deadline: $2) })) != nil {
        let elapsed = psStart.duration(to: clock.now)
        report.psMilliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1_000
    } else {
        report.problems.append("/bin/ps 비교 샘플 실패")
    }
    let snapshots = rows.map(\.snapshot)
    report.processCount = snapshots.count
    report.ownProcessCount = snapshots.filter { $0.userID == getuid() }.count
    let agents = snapshots.filter { $0.kind == .agent && $0.userID == getuid() }
    report.agentCount = agents.count
    report.agentsWithWorkingDirectory = agents.filter { WorkingDirectoryResolver.currentDirectory(pid: $0.id) != nil }.count
    report.ledgerEntries = (try? SuspensionLedger.standard().reconcile().count) ?? 0
    report.appRunning = snapshots.contains { $0.executablePath.hasSuffix("Watchdog.app/Contents/MacOS/Watchdog") }
    if report.agentCount > report.agentsWithWorkingDirectory {
        report.problems.append("작업 디렉터리를 읽지 못한 에이전트 \(report.agentCount - report.agentsWithWorkingDirectory)개")
    }
    if report.appRunning, !report.loginItemOptedOut,
       let status = report.loginItemStatus, status != "enabled" {
        report.problems.append(status == "requiresApproval"
            ? "로그인 항목 승인 필요 (시스템 설정 → 일반 → 로그인 항목)"
            : "로그인 항목에 등록되지 않음 (\(status)\(report.loginItemLastError.map { ", \($0)" } ?? ""))")
    }
    if report.ledgerEntries > 0 {
        report.problems.append("Watchdog이 정지한 채 멈춘 프로세스 \(report.ledgerEntries)개 (watchdog-cli stopped)")
    }

    if arguments.json {
        emitJSON(report)
        return CLIExitCode.success
    }
    let libproc = report.libprocMilliseconds.map { String(format: "%.1f", $0) }.joined(separator: " / ")
    print("샘플링(커널 직접)  \(libproc) ms (첫 회 cold, 이후 캐시)")
    print("/bin/ps 비교       \(report.psMilliseconds.map { String(format: "%.1f ms", $0) } ?? "실패")")
    print("프로세스           전체 \(report.processCount) · 내 소유 \(report.ownProcessCount) · 에이전트 \(report.agentCount) (cwd 확인 \(report.agentsWithWorkingDirectory))")
    print("앱 설정            CPU \(Int(settings.cpuThreshold))% · 지속 \(Int(settings.sustainedDuration))초 · 메모리 \(settings.memoryThresholdGB)GB · 자동 정지 \(settings.autoSuspendEnabled ? "켬" : "끔")")
    print("앱 실행 중         \(report.appRunning ? "예" : "아니오")")
    let loginLine: String
    if report.loginItemOptedOut {
        loginLine = "끔 (사용자가 끔)"
    } else {
        switch report.loginItemStatus {
        case "enabled": loginLine = "켜짐"
        case "requiresApproval": loginLine = "승인 필요"
        case .some(let status): loginLine = "등록 안 됨 (\(status))"
        case nil: loginLine = "알 수 없음 (앱이 아직 기록하지 않음)"
        }
    }
    print("로그인 시 실행     \(loginLine)")
    print("정지 기록          \(report.ledgerEntries)개 · \(report.ledgerPath)")
    print("사용자 규칙        \(report.rulesStatus) · \(report.rulesPath)")
    print(report.problems.isEmpty ? "문제 없음" : "확인 필요:\n" + report.problems.map { "  - \($0)" }.joined(separator: "\n"))
    return CLIExitCode.success
}

// MARK: - snapshot / audit

func runSnapshot(_ arguments: Arguments) throws -> Int32 {
    let home = NSHomeDirectory()
    let listed = try LibprocProcessLister.list()
    var argumentReader = ArgumentReader()
    let fixture = ProcessFixture(
        capturedAt: ProcessFixture.capturedAtNow(),
        uid: getuid(),
        rows: listed.map { raw in
            let snapshot = raw.snapshot
            let args = argumentReader.arguments(pid: snapshot.id).map {
                ProcessFixture.collapsingHome($0, home: home)
            }
            var cwd: String?
            if snapshot.kind == .agent {
                cwd = WorkingDirectoryResolver.currentDirectory(pid: snapshot.id).map {
                    ProcessFixture.collapsingHome($0, home: home)
                }
            }
            return ProcessFixture.Row(
                pid: snapshot.id,
                ppid: snapshot.parentPID,
                pgid: snapshot.processGroupID,
                uid: snapshot.userID,
                tty: snapshot.tty,
                state: snapshot.state,
                elapsed: snapshot.elapsed,
                path: ProcessFixture.collapsingHome(snapshot.executablePath, home: home),
                args: args,
                cwd: cwd
            )
        }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(fixture)
    guard let text = String(data: data, encoding: .utf8) else {
        throw CLIUsageError("스냅샷 JSON을 인코딩하지 못했습니다.")
    }
    if let path = arguments.options["--out"] {
        try text.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    } else {
        print(text)
    }
    return CLIExitCode.success
}

func runRules(_ arguments: Arguments) throws -> Int32 {
    guard let subcommand = arguments.positionals.first else {
        throw CLIUsageError("rules에는 show, validate, init 중 하나가 필요합니다.")
    }
    switch subcommand {
    case "show": return try runRulesShow(arguments)
    case "validate": return try runRulesValidate(arguments)
    case "init": return try runRulesInit()
    default:
        throw CLIUsageError("알 수 없는 rules 명령: \(subcommand)")
    }
}

func runRulesShow(_ arguments: Arguments) throws -> Int32 {
    let url = AgentRules.standardURL()
    let loaded = AgentRules.load(from: url)
    let rules: AgentRules?
    let issues: [String]
    switch loaded {
    case let .loaded(value, _):
        rules = value
        issues = value.validationIssues()
    case .absent, .invalid:
        rules = nil
        issues = []
    }
    if arguments.json {
        struct Report: Encodable {
            let path: String
            let status: String
            let reason: String?
            let rules: AgentRules?
            let validationIssues: [String]
            let appliedCount: Int
        }
        let reason: String?
        if case let .invalid(_, text) = loaded { reason = text } else { reason = nil }
        emitJSON(
            Report(
                path: url.path,
                status: rulesStatusLine(loaded),
                reason: reason,
                rules: rules,
                validationIssues: issues,
                appliedCount: rules?.appliedCount ?? 0
            )
        )
        return CLIExitCode.success
    }
    print("경로                \(url.path)")
    print("상태                \(rulesStatusLine(loaded))")
    if case let .invalid(_, reason) = loaded {
        print("이유                \(reason)")
    }
    if let rules {
        print("agentNames          \(rules.agentNames.isEmpty ? "-" : rules.agentNames.joined(separator: ", "))")
        print("packageMarkers      \(rules.packageMarkers.isEmpty ? "-" : rules.packageMarkers.map { "\($0.marker) → \($0.agent)" }.joined(separator: ", "))")
        print("serviceSubcommands  \(rules.serviceSubcommands.isEmpty ? "-" : rules.serviceSubcommands.joined(separator: ", "))")
        print("sessionHosts        \(rules.sessionHosts.isEmpty ? "-" : rules.sessionHosts.joined(separator: ", "))")
        print("ignoreNames         \(rules.ignoreNames.isEmpty ? "-" : rules.ignoreNames.joined(separator: ", "))")
    }
    if issues.isEmpty {
        print("검증                문제 없음")
    } else {
        print("검증 경고:")
        for issue in issues {
            print("  - \(issue)")
        }
    }
    return CLIExitCode.success
}

func runRulesValidate(_ arguments: Arguments) throws -> Int32 {
    let url: URL
    if arguments.positionals.count >= 2 {
        url = URL(fileURLWithPath: arguments.positionals[1])
    } else {
        url = AgentRules.standardURL()
    }
    let loaded = AgentRules.load(from: url)
    switch loaded {
    case let .loaded(rules, _):
        let issues = rules.validationIssues()
        if issues.isEmpty {
            print("유효함: \(url.path)")
            return CLIExitCode.success
        }
        printError("검증 실패: \(url.path)")
        for issue in issues {
            printError("  - \(issue)")
        }
        return CLIExitCode.failure
    case .absent:
        printError("파일이 없습니다: \(url.path)")
        return CLIExitCode.failure
    case let .invalid(_, reason):
        printError("손상: \(url.path)")
        printError(reason)
        return CLIExitCode.failure
    }
}

func runRulesInit() throws -> Int32 {
    let url = AgentRules.standardURL()
    if FileManager.default.fileExists(atPath: url.path) {
        printError("이미 있습니다: \(url.path)")
        return CLIExitCode.failure
    }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let example: [String: Any] = [
        "_comment": "Watchdog 사용자 규칙. agentNames에 없는 에이전트 CLI 이름을 추가합니다.",
        "agentNames": ["my-agent"],
        "packageMarkers": [["marker": "/@example/my-agent/", "agent": "my-agent"]],
        "serviceSubcommands": [] as [String],
        "sessionHosts": [] as [String],
        "ignoreNames": [] as [String],
    ]
    let data = try JSONSerialization.data(withJSONObject: example, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
    print("만들었습니다: \(url.path)")
    return CLIExitCode.success
}

func runAudit(_ arguments: Arguments) throws -> Int32 {
    guard let path = arguments.positionals.first else {
        throw CLIUsageError("audit에는 픽스처 파일이 필요합니다.")
    }
    let fixtureURL = URL(fileURLWithPath: path)
    let fixture = try JSONDecoder().decode(ProcessFixture.self, from: Data(contentsOf: fixtureURL))

    if let labelsPath = arguments.options["--labels"] {
        let labels = try JSONDecoder().decode(
            ProcessLabelFile.self,
            from: Data(contentsOf: URL(fileURLWithPath: labelsPath))
        )
        let report = ClassifierAudit.audit(fixture: fixture, labels: labels.labels)
        if arguments.json {
            emitJSON(report)
        } else {
            print(report.render())
        }
        return report.untoleratedMismatchCount == 0 ? CLIExitCode.success : CLIExitCode.failure
    }

    let summary = ClassifierAudit.summarize(ClassifierAudit.classify(fixture))
    if arguments.json {
        emitJSON(summary)
    } else {
        print(summary.render())
    }
    return CLIExitCode.success
}

// MARK: - Entry point

func main() async -> Int32 {
    _ = activateUserRules()
    do {
        let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
        if arguments.flags.contains("--version") {
            print("watchdog-cli \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")")
            return CLIExitCode.success
        }
        guard let command = arguments.command, !arguments.flags.contains("--help"), !arguments.flags.contains("-h") else {
            print(usageText)
            return arguments.command == nil && arguments.flags.isEmpty ? CLIExitCode.usage : CLIExitCode.success
        }
        switch command {
        case "list": return try await runList(arguments)
        case "sessions": return try await runSessions(arguments)
        case "inspect": return try await runInspect(arguments)
        case "watch": return try await runWatch(arguments)
        case "stopped": return try await runStopped(arguments)
        case "doctor": return try await runDoctor(arguments)
        case "snapshot": return try runSnapshot(arguments)
        case "audit": return try runAudit(arguments)
        case "rules": return try runRules(arguments)
        case "help": print(usageText); return CLIExitCode.success
        default:
            if let action = CLIAction(rawValue: command) {
                return try await runControl(action, arguments)
            }
            throw CLIUsageError("알 수 없는 명령: \(command)")
        }
    } catch let error as CLIUsageError {
        printError(error.message)
        printError("도움말: watchdog-cli help")
        return CLIExitCode.usage
    } catch {
        printError("실패: \(error.localizedDescription)")
        return CLIExitCode.failure
    }
}

exit(await main())
