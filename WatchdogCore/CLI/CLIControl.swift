import Darwin
import Foundation
import OSLog

/// `pid:startMicroseconds:uid` — the exact process a CLI action targets.
/// A PID alone is reusable; the start time makes the token single-process.
struct IdentityToken: Hashable, Sendable, CustomStringConvertible {
    let identity: ProcessIdentity

    init(_ identity: ProcessIdentity) {
        self.identity = identity
    }

    init?(parsing text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let pid = Int32(parts[0]), pid > 0,
              let start = UInt64(parts[1]),
              let uid = UInt32(parts[2])
        else { return nil }
        identity = ProcessIdentity(pid: pid, startTimeMicroseconds: start, userID: uid)
    }

    var description: String {
        "\(identity.pid):\(identity.startTimeMicroseconds):\(identity.userID)"
    }
}

/// What the user typed to name a target.
enum CLITarget: Equatable, Sendable {
    case token(IdentityToken)
    case pid(Int32)

    init?(parsing text: String) {
        if let token = IdentityToken(parsing: text) {
            self = .token(token)
        } else if let pid = Int32(text), pid > 0 {
            self = .pid(pid)
        } else {
            return nil
        }
    }

    var pid: Int32 {
        switch self {
        case let .token(token): return token.identity.pid
        case let .pid(pid): return pid
        }
    }
}

enum CLIAction: String, CaseIterable, Sendable {
    case suspend
    case resume
    case terminate
    case forceQuit = "force-quit"

    var controlAction: ProcessControlAction {
        switch self {
        case .suspend: return .suspend
        case .resume: return .resume
        case .terminate: return .terminate
        case .forceQuit: return .forceQuit
        }
    }

    /// Destructive actions cannot be undone: blocked without `--force`, and
    /// they only accept a full identity token.
    var isDestructive: Bool { controlAction.isDestructive }

    var signalSummary: String {
        switch self {
        case .suspend: return "SIGSTOP (되돌릴 수 있음: resume으로 재개)"
        case .resume: return "SIGCONT"
        case .terminate: return "SIGTERM (정지 상태면 SIGCONT 후 SIGTERM). 프로세스가 정리 후 종료할 기회를 가짐"
        case .forceQuit: return "SIGKILL. 즉시 종료되며 저장하지 않은 작업·잠금 파일·자식 프로세스가 정리되지 않을 수 있음"
        }
    }
}

/// Why a target is refused. None of these can be overridden with `--force`:
/// `--force` accepts the consequences for *this* process, it cannot make an
/// unverifiable or different process the right target.
enum CLIRefusal: Equatable, Sendable {
    case notFound
    case identityMismatch(live: ProcessIdentity)
    case launchd
    case watchdogItself
    case otherUser(uid: UInt32)
    case systemPath(String)
    case unverifiableStartTime
    case lookupFailed

    var message: String {
        switch self {
        case .notFound:
            return "해당 PID의 프로세스가 없습니다."
        case let .identityMismatch(live):
            return "PID가 다른 프로세스로 바뀌었습니다(현재 \(IdentityToken(live))). 토큰을 다시 확인하세요."
        case .launchd:
            return "PID 1(launchd)은 제어할 수 없습니다."
        case .watchdogItself:
            return "Watchdog 자신은 제어할 수 없습니다."
        case let .otherUser(uid):
            return "다른 사용자(uid \(uid))의 프로세스는 제어할 수 없습니다."
        case let .systemPath(path):
            return "시스템 경로의 프로세스는 제어할 수 없습니다: \(path)"
        case .unverifiableStartTime:
            return "시작 시각을 확인할 수 없어 PID 재사용을 배제할 수 없습니다."
        case .lookupFailed:
            return "프로세스 상태를 안전하게 확인할 수 없습니다."
        }
    }
}

enum CLIDecision: Equatable, Sendable {
    /// Proceed; print the warnings first.
    case allow(warnings: [String])
    /// Destructive action without `--force`: print the dry run, send nothing.
    case blocked(dryRun: String)
    /// Safety contract refusal; `--force` does not apply.
    case refused(CLIRefusal)
    /// Wrong invocation (e.g. a bare PID for a destructive action).
    case usage(String)

    var exitCode: Int32 {
        switch self {
        case .allow: return CLIExitCode.success
        case .blocked: return CLIExitCode.blocked
        case .refused: return CLIExitCode.refused
        case .usage: return CLIExitCode.usage
        }
    }
}

enum CLIExitCode {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    static let blocked: Int32 = 3
    static let refused: Int32 = 4
}

enum CLIPolicy {
    static func evaluate(
        action: CLIAction,
        target: CLITarget,
        live: ProcessSnapshot?,
        force: Bool,
        currentUserID: UInt32 = getuid(),
        currentPID: Int32 = getpid()
    ) -> CLIDecision {
        if action.isDestructive, case .pid = target {
            return .usage(
                "\(action.rawValue)은(는) PID만으로 실행할 수 없습니다. `watchdog-cli list`의 TOKEN(pid:start:uid)을 사용하세요."
            )
        }
        if let refusal = refusal(target: target, live: live, currentUserID: currentUserID, currentPID: currentPID) {
            return .refused(refusal)
        }
        guard let live else { return .refused(.notFound) }

        if action.isDestructive && !force {
            return .blocked(dryRun: dryRun(action: action, live: live))
        }

        var warnings: [String] = []
        if !force {
            switch action {
            case .suspend:
                if live.kind != .agent {
                    warnings.append(
                        "\(live.displayName)은(는) 코딩 에이전트가 아닙니다(\(live.kind.rawValue)). 앱을 정지하면 응답하지 않게 됩니다. resume으로 되돌릴 수 있습니다."
                    )
                }
                if live.isSuspended {
                    warnings.append("이미 정지된 프로세스입니다.")
                }
            case .resume:
                if !live.isSuspended {
                    warnings.append("정지된 프로세스가 아닙니다. SIGCONT는 아무 효과가 없습니다.")
                }
            case .terminate, .forceQuit:
                break
            }
        }
        return .allow(warnings: warnings)
    }

    static func refusal(
        target: CLITarget,
        live: ProcessSnapshot?,
        currentUserID: UInt32,
        currentPID: Int32
    ) -> CLIRefusal? {
        let pid = target.pid
        if pid <= 1 { return .launchd }
        if pid == currentPID { return .watchdogItself }
        guard let live else { return .notFound }
        if case let .token(token) = target, token.identity != live.identity {
            return .identityMismatch(live: live.identity)
        }
        if live.userID != currentUserID || live.userID == 0 { return .otherUser(uid: live.userID) }
        if live.startTimeMicroseconds == 0 { return .unverifiableStartTime }
        let path = live.executablePath.lowercased()
        if ["/system/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains(where: path.hasPrefix) {
            return .systemPath(live.executablePath)
        }
        return nil
    }

    static func dryRun(action: CLIAction, live: ProcessSnapshot) -> String {
        """
        차단됨: \(action.rawValue)은(는) 되돌릴 수 없는 동작이라 --force가 필요합니다.
        대상: \(live.displayName) · PID \(live.id) · TOKEN \(IdentityToken(live.identity))
        경로: \(live.executablePath)
        보낼 신호: \(action.signalSummary)
        실행하려면 같은 명령에 --force를 붙이세요.
        """
    }
}

/// Result of one CLI control action, after the post-action verification.
struct CLIActionReport: Sendable {
    let action: CLIAction
    let token: IdentityToken
    let name: String
    let outcome: ProcessActionOutcome
    let warnings: [String]
}

/// Executes a CLI action through the same safety pipeline as the app: a fresh
/// observation, a single-use authorization bound to that observation's
/// generation and the exact identity, live re-validation before every signal,
/// the shared suspension ledger, and verified termination.
struct CLIControl: Sendable {
    typealias Lister = @Sendable () throws -> [RawProcessRow]
    typealias Sleeper = @Sendable (Duration) async -> Void

    let lister: Lister
    let controller: ProcessController
    let ledger: SuspensionLedger
    let journal: ActionJournal
    let sleep: Sleeper
    let terminationPollAttempts: Int

    private static let log = Logger(subsystem: "dev.justn.watchdog", category: "journal")

    init(
        lister: @escaping Lister = { try LibprocProcessLister.list() },
        controller: ProcessController = ProcessController(),
        ledger: SuspensionLedger = .standard(),
        journal: ActionJournal = .standard(),
        sleep: @escaping Sleeper = { try? await Task.sleep(for: $0) },
        terminationPollAttempts: Int = 20
    ) {
        self.lister = lister
        self.controller = controller
        self.ledger = ledger
        self.journal = journal
        self.sleep = sleep
        self.terminationPollAttempts = terminationPollAttempts
    }

    func observe(_ pid: Int32) throws -> ProcessSnapshot? {
        OrphanClassifier.classify(try lister().map(\.snapshot)).first { $0.id == pid }
    }

    enum Result: Sendable {
        case decided(CLIDecision)
        case performed(CLIActionReport)
        case failed(ProcessControlError, refused: Bool)
    }

    func run(_ action: CLIAction, target: CLITarget, force: Bool) async throws -> Result {
        let clock = ContinuousClock()
        let live = try observe(target.pid)
        let observation = ObservationToken(generation: 1, instant: clock.now)
        let decision = CLIPolicy.evaluate(action: action, target: target, live: live, force: force)
        guard case let .allow(warnings) = decision, let live else {
            return .decided(decision)
        }

        let authorization = ProcessActionAuthorizationActor()
        // A process that was already stopped (Ctrl-Z, another tool) is not
        // Watchdog's to resume later, so it gets no ledger record.
        let recordsSuspension = action == .suspend && !live.isSuspended
        var wroteAhead = false
        do {
            let nonce = try await authorization.mint(
                action: action.controlAction,
                identity: live.identity,
                observation: observation,
                at: clock.now
            )
            let authorized = try await authorization.consume(
                nonce,
                action: action.controlAction,
                identity: live.identity,
                currentGeneration: observation.generation,
                at: clock.now
            )
            if recordsSuspension {
                // Write ahead: if the stop cannot be remembered, do not stop.
                do {
                    try ledger.record(
                        SuspensionRecord(
                            identity: live.identity,
                            executablePath: live.executablePath,
                            suspendedAt: Date(),
                            source: .cli
                        )
                    )
                } catch {
                    throw ProcessControlError.ledgerUnavailable(error.localizedDescription)
                }
                wroteAhead = true
            }
            try controller.execute(authorized, currentGeneration: observation.generation)
        } catch let error as ProcessControlError {
            if wroteAhead {
                _ = try? ledger.remove(live.identity)
            }
            if case let .partiallyApplied(delivered, _) = error, delivered.contains(SIGCONT) {
                _ = try? ledger.remove(live.identity)
            }
            if error.didSendSignal {
                recordJournal(action: action, live: live, outcome: .failed(error.localizedDescription))
            }
            return .failed(error, refused: Self.isRefusal(error))
        }

        let outcome: ProcessActionOutcome
        switch action {
        case .suspend:
            outcome = verifyState(live.identity, expectStopped: true) ? .suspended : .signalDelivered
        case .resume:
            _ = try? ledger.remove(live.identity)
            outcome = verifyState(live.identity, expectStopped: false) ? .resumed : .signalDelivered
        case .terminate, .forceQuit:
            _ = try? ledger.remove(live.identity)
            outcome = await awaitTermination(live.identity)
        }
        recordJournal(action: action, live: live, outcome: outcome)
        return .performed(
            CLIActionReport(
                action: action,
                token: IdentityToken(live.identity),
                name: live.displayName,
                outcome: outcome,
                warnings: warnings
            )
        )
    }

    /// Polls until the exact process is gone. A single failed lookup mid-exit
    /// is retried; only a failure on the last attempt is reported.
    func awaitTermination(_ identity: ProcessIdentity) async -> ProcessActionOutcome {
        var last: ProcessActionOutcome?
        for _ in 0..<max(1, terminationPollAttempts) {
            await sleep(.milliseconds(500))
            last = TerminationVerdict.outcome(for: controller.lookup(pid: identity.pid), identity: identity)
            if let last, last != .verificationFailed {
                return last
            }
        }
        return last ?? .stillRunning
    }

    private func verifyState(_ identity: ProcessIdentity, expectStopped: Bool) -> Bool {
        guard case let .found(facts) = controller.lookup(pid: identity.pid),
              facts.identity == identity
        else { return false }
        return facts.isSuspended == expectStopped
    }

    static func isRefusal(_ error: ProcessControlError) -> Bool {
        switch error {
        case .protectedProcess, .processChanged, .identityLookupFailed:
            return true
        case let .partiallyApplied(_, failure):
            return isRefusal(failure)
        default:
            return false
        }
    }

    private func recordJournal(
        action: CLIAction,
        live: ProcessSnapshot,
        outcome: ProcessActionOutcome
    ) {
        let undoOf: UUID?
        if action == .resume {
            undoOf = journal.all().last {
                $0.pid == live.id
                    && $0.startTimeMicroseconds == live.startTimeMicroseconds
                    && $0.action == .suspend
            }?.id
        } else {
            undoOf = nil
        }
        let entry = ActionJournalEntry(
            source: .cli,
            action: action.controlAction,
            process: live,
            outcome: outcome,
            undoOf: undoOf
        )
        do {
            try journal.append(entry)
        } catch {
            Self.log.error("ActionJournal append failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
