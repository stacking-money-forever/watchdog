import Darwin
import Foundation

// watchdog-cli — verification front end for WatchdogCore. It drives the same
// sampling, detection, authorization, and control code the menu bar app ships.

let usageText = """
사용법: watchdog-cli <명령> [옵션]

조회 (안전):
  list [--scope attention|agents|all] [--search 텍스트] [--interval 초] [--json]
      CPU%를 계산하려고 두 번 샘플링합니다(기본 1초 간격). TOKEN은 제어 명령에 씁니다.
  inspect <TOKEN|PID> [--json]
      한 프로세스의 신원, 상태, 작업 디렉터리, 워크트리 상태를 보여 줍니다.
  watch [--interval 초] [--count N] [--duration 초] [--cpu %] [--sustain 초] [--memory GB]
        [--auto-suspend] [--json]
      앱과 같은 감지 엔진으로 지속 감시하며 경고 이벤트를 출력합니다. Ctrl-C로 끝냅니다.
  stopped [--resume-all] [--json]
      Watchdog(앱·CLI)이 일시 정지한 채 멈춰 있는 프로세스를 보여 줍니다.
  doctor [--json]
      샘플링 비용과 환경을 진단합니다.

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
        workingDirectory = process.workingDirectory
        worktree = process.worktreeState.map { state in
            [state.verdict.localizedDescription, state.detail].compactMap { $0 }.joined(separator: " · ")
        }
        controllable = !process.isProtected
        self.watchdogSuspended = watchdogSuspended
        self.flags = flags
    }
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
    return OrphanClassifier.classify(sample.processes)
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
        processes = processes.filter { $0.kind == .agent }
    default:
        break
    }
    if let search = arguments.options["--search"]?.lowercased(), !search.isEmpty {
        processes = processes.filter {
            $0.displayName.lowercased().contains(search)
                || $0.executablePath.lowercased().contains(search)
                || String($0.id) == search
        }
    }
    for index in processes.indices where processes[index].kind == .agent {
        processes[index].workingDirectory = WorkingDirectoryResolver.currentDirectory(pid: processes[index].id)
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
        ("종류", process.kind.rawValue),
        ("PID / PPID / PGID", "\(process.id) / \(process.parentPID) / \(process.processGroupID)"),
        ("UID", "\(process.userID)"),
        ("상태", process.state + (process.isSuspended ? " (정지됨)" : "")),
        ("실행 시간", process.elapsed),
        ("TTY", process.tty),
        ("CPU", String(format: "%.1f%%", process.cpuPercent)),
        ("메모리", memoryText(process.residentBytes)),
        ("고아 의심", process.orphanReason?.localizedDescription ?? "아님"),
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
        var failures = 0
        let control = CLIControl(ledger: ledger)
        for record in records {
            let result = try await control.run(.resume, target: .token(IdentityToken(record.identity)), force: true)
            switch result {
            case let .performed(report):
                print("resume: \(report.name) (\(report.token)) → \(report.outcome.localizedDescription)")
                if report.outcome.isError { failures += 1 }
            case let .failed(error, _):
                failures += 1
                printError("실패: \(record.displayName) (\(IdentityToken(record.identity))): \(error.errorDescription ?? "\(error)")")
            case let .decided(decision):
                failures += 1
                printError("건너뜀: \(record.displayName): \(decision)")
            }
        }
        if records.isEmpty { print("Watchdog이 정지한 프로세스가 없습니다.") }
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
    let maximumTicks = arguments.options["--count"].flatMap(Int.init)
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
    var engine = MonitorEngine()
    let clock = ContinuousClock()
    let started = clock.now
    var ticks = 0
    var previousHot: Set<ProcessIdentity> = []
    var previousHighMemory: Set<ProcessIdentity> = []
    var failures = 0

    while !stop.isSet {
        if let maximumTicks, ticks >= maximumTicks { break }
        if duration > 0, started.duration(to: clock.now) >= .milliseconds(Int(duration * 1_000)) { break }
        ticks += 1
        do {
            let sample = try await sampler.sample()
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
            previousHot = update.hot
            previousHighMemory = update.highMemory
            for candidate in update.autoSuspendCandidates {
                switch try await control.run(.suspend, target: .token(IdentityToken(candidate.identity)), force: true) {
                case let .performed(report):
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
        appRunning: false
    )
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
    print("정지 기록          \(report.ledgerEntries)개 · \(report.ledgerPath)")
    print(report.problems.isEmpty ? "문제 없음" : "확인 필요:\n" + report.problems.map { "  - \($0)" }.joined(separator: "\n"))
    return CLIExitCode.success
}

// MARK: - Entry point

func main() async -> Int32 {
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
        case "inspect": return try await runInspect(arguments)
        case "watch": return try await runWatch(arguments)
        case "stopped": return try await runStopped(arguments)
        case "doctor": return try await runDoctor(arguments)
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
