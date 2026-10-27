import Darwin
import Foundation

enum ProcessControlError: LocalizedError, Sendable {
    case authorizationInvalid
    case authorizationExpired
    case authorizationCapacityReached
    case staleObservation
    case protectedProcess
    case processChanged
    case identityLookupFailed
    case signalFailed(signal: Int32, code: Int32, message: String)
    /// The confirmation was already completed or cancelled.
    case confirmationNotPending
    /// The confirmation stayed open longer than its validity window.
    case confirmationExpired
    /// A newer observation replaced the one the action was authorized against.
    case observationRefreshed
    /// The user chose to ignore this process; controls are disabled for it.
    case processIgnored
    /// The suspension could not be written to the ledger, so no SIGSTOP was
    /// sent: a stop Watchdog cannot remember is one it could never undo.
    case ledgerUnavailable(String)
    /// A multi-signal plan stopped after some signals were already delivered.
    indirect case partiallyApplied(delivered: [Int32], failure: ProcessControlError)

    var errorDescription: String? {
        switch self {
        case .authorizationInvalid: return "이 작업의 승인이 없거나 이미 사용되었습니다."
        case .authorizationExpired: return "작업 승인이 만료되었습니다."
        case .authorizationCapacityReached: return "대기 중인 작업 승인이 너무 많습니다."
        case .staleObservation: return "프로세스 정보가 최신 상태가 아니어서 작업을 취소했습니다."
        case .protectedProcess: return "보호된 프로세스는 Watchdog에서 제어할 수 없습니다."
        case .processChanged: return "프로세스가 종료되었거나 다른 프로세스로 바뀌어 작업을 취소했습니다."
        case .identityLookupFailed: return "프로세스 상태를 안전하게 확인할 수 없습니다."
        case let .signalFailed(signal, code, message):
            return "시그널 \(signal) 전송 실패(\(code)): \(message)"
        case .confirmationNotPending: return "이 확인 요청은 이미 처리되었거나 취소되었습니다."
        case .confirmationExpired: return "확인 시간이 지나 작업을 취소했습니다. 다시 시도하세요."
        case .observationRefreshed: return "작업 중 프로세스 정보가 갱신되어 취소했습니다. 다시 시도하세요."
        case .processIgnored: return "무시 중인 프로세스는 제어할 수 없습니다. 무시를 해제한 뒤 다시 시도하세요."
        case let .ledgerUnavailable(reason): return "정지 기록을 저장할 수 없어 일시 정지하지 않았습니다: \(reason)"
        case let .partiallyApplied(delivered, failure):
            let names = delivered.map(ProcessControlError.signalName).joined(separator: ", ")
            return "\(names) 전송 후 중단됨: \(failure.errorDescription ?? "알 수 없는 오류")"
        }
    }

    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGSTOP: return "SIGSTOP"
        case SIGCONT: return "SIGCONT"
        case SIGTERM: return "SIGTERM"
        case SIGKILL: return "SIGKILL"
        default: return "시그널 \(signal)"
        }
    }
}

enum ProcessControlAction: Hashable, Sendable {
    case suspend
    case resume
    case terminate
    case forceQuit

    var isDestructive: Bool { self == .terminate || self == .forceQuit }
}

struct ProcessActionNonce: Hashable, Sendable {
    fileprivate let value: UUID
}

struct AuthorizedProcessAction: Sendable {
    fileprivate let action: ProcessControlAction
    fileprivate let identity: ProcessIdentity
    let observationGeneration: UInt64
    fileprivate let expiresAt: ContinuousClock.Instant
}

actor ProcessActionAuthorizationActor {
    private struct Record: Sendable {
        let action: ProcessControlAction
        let identity: ProcessIdentity
        let generation: UInt64
        let expiresAt: ContinuousClock.Instant
    }

    private let capacity: Int
    private let consumeHook: (@Sendable () async -> Void)?
    private var records: [ProcessActionNonce: Record] = [:]

    init(
        capacity: Int = 256,
        consumeHook: (@Sendable () async -> Void)? = nil
    ) {
        self.capacity = max(1, min(capacity, 256))
        self.consumeHook = consumeHook
    }

    func mint(
        action: ProcessControlAction,
        identity: ProcessIdentity,
        observation: ObservationToken,
        at mintInstant: ContinuousClock.Instant
    ) throws -> ProcessActionNonce {
        pruneExpired(at: mintInstant)
        guard records.count < capacity else {
            throw ProcessControlError.authorizationCapacityReached
        }
        let observationExpiry = observation.instant.advanced(by: .seconds(5))
        let mintExpiry = mintInstant.advanced(by: .seconds(3))
        guard mintInstant < observationExpiry else {
            throw ProcessControlError.authorizationExpired
        }
        let nonce = ProcessActionNonce(value: UUID())
        records[nonce] = Record(
            action: action,
            identity: identity,
            generation: observation.generation,
            expiresAt: min(observationExpiry, mintExpiry)
        )
        return nonce
    }

    func consume(
        _ nonce: ProcessActionNonce,
        action: ProcessControlAction,
        identity: ProcessIdentity,
        currentGeneration: UInt64,
        at instant: ContinuousClock.Instant
    ) async throws -> AuthorizedProcessAction {
        pruneExpired(at: instant, preserving: nonce)
        guard let record = records.removeValue(forKey: nonce) else {
            throw ProcessControlError.authorizationInvalid
        }
        guard instant < record.expiresAt else {
            throw ProcessControlError.authorizationExpired
        }
        guard record.action == action,
              record.identity == identity,
              record.generation == currentGeneration
        else {
            throw ProcessControlError.authorizationInvalid
        }
        await consumeHook?()
        return AuthorizedProcessAction(
            action: record.action,
            identity: record.identity,
            observationGeneration: record.generation,
            expiresAt: record.expiresAt
        )
    }

    func invalidateAll() {
        records.removeAll(keepingCapacity: true)
    }

    private func pruneExpired(
        at instant: ContinuousClock.Instant,
        preserving nonce: ProcessActionNonce? = nil
    ) {
        records = records.filter { key, record in
            key == nonce || instant < record.expiresAt
        }
    }
}

struct ProcessController: Sendable {
    typealias FactsReader = @Sendable (Int32) -> LiveProcessLookup
    typealias SignalSender = @Sendable (Int32, Int32) -> Int32

    private let factsReader: FactsReader
    private let signalSender: SignalSender
    private let currentUserID: @Sendable () -> UInt32
    private let currentPID: @Sendable () -> Int32
    private let now: @Sendable () -> ContinuousClock.Instant

    init(
        factsReader: @escaping FactsReader = ProcessMetricsReader.liveFacts,
        signalSender: @escaping SignalSender = { Darwin.kill($0, $1) },
        currentUserID: @escaping @Sendable () -> UInt32 = { getuid() },
        currentPID: @escaping @Sendable () -> Int32 = { getpid() },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.factsReader = factsReader
        self.signalSender = signalSender
        self.currentUserID = currentUserID
        self.currentPID = currentPID
        self.now = now
    }

    func lookup(pid: Int32) -> LiveProcessLookup {
        factsReader(pid)
    }

    func execute(
        _ authorization: AuthorizedProcessAction,
        currentGeneration: UInt64
    ) throws {
        guard authorization.observationGeneration == currentGeneration else {
            throw ProcessControlError.staleObservation
        }
        guard now() < authorization.expiresAt else {
            throw ProcessControlError.authorizationExpired
        }

        let first = try validatedFacts(for: authorization.identity)
        let signals = Self.signalPlan(for: authorization.action, isSuspended: first.isSuspended)
        var delivered: [Int32] = []
        do {
            for signal in signals {
                guard now() < authorization.expiresAt else {
                    throw ProcessControlError.authorizationExpired
                }
                _ = try validatedFacts(for: authorization.identity)

                // macOS provides no atomic identity-check-and-signal operation. Full live facts
                // are checked immediately before each signal to minimize the irreducible TOCTOU.
                guard signalSender(authorization.identity.pid, signal) == 0 else {
                    let code = errno
                    throw ProcessControlError.signalFailed(
                        signal: signal,
                        code: code,
                        message: String(cString: strerror(code))
                    )
                }
                delivered.append(signal)
            }
        } catch let error as ProcessControlError where !delivered.isEmpty {
            // Never let a half-applied plan read as a plain failure: a stopped
            // process that was continued but not terminated is running again.
            throw ProcessControlError.partiallyApplied(delivered: delivered, failure: error)
        }
    }

    private func validatedFacts(for identity: ProcessIdentity) throws -> LiveProcessFacts {
        guard identity.pid > 1,
              identity.pid != currentPID(),
              identity.startTimeMicroseconds != 0,
              identity.userID != 0,
              identity.userID == currentUserID()
        else {
            throw ProcessControlError.protectedProcess
        }
        switch factsReader(identity.pid) {
        case let .found(facts):
            guard facts.identity == identity, !facts.isZombie else {
                throw ProcessControlError.processChanged
            }
            guard facts.identity.userID != 0,
                  facts.identity.userID == currentUserID(),
                  facts.identity.startTimeMicroseconds != 0,
                  !facts.isSystemPath
            else { throw ProcessControlError.protectedProcess }
            return facts
        case .absent:
            throw ProcessControlError.processChanged
        case .failed:
            throw ProcessControlError.identityLookupFailed
        }
    }

    static func signalPlan(for action: ProcessControlAction, isSuspended: Bool) -> [Int32] {
        switch action {
        case .suspend: return [SIGSTOP]
        case .resume: return [SIGCONT]
        case .terminate: return isSuspended ? [SIGCONT, SIGTERM] : [SIGTERM]
        case .forceQuit: return [SIGKILL]
        }
    }
}

/// What Watchdog knows about the result of the last action on a process.
enum ProcessActionOutcome: Equatable, Sendable {
    case signalDelivered
    case suspended
    case resumed
    case awaitingExit
    case exited
    case stillRunning
    case identityChanged
    case verificationFailed
    case failed(String)

    var localizedDescription: String {
        switch self {
        case .signalDelivered: return "신호 전달됨 · 실행 상태는 별도 확인 필요"
        case .suspended: return "일시 정지됨 · 재개할 때까지 멈춰 있음"
        case .resumed: return "재개됨"
        case .awaitingExit: return "신호 전달됨 · 종료 확인 중"
        case .exited: return "종료 확인됨"
        case .stillRunning: return "신호 후에도 실행 중"
        case .identityChanged: return "PID가 다른 프로세스로 바뀜"
        case .verificationFailed: return "종료 여부를 확인하지 못함"
        case let .failed(message): return "작업 실패: \(message)"
        }
    }

    var isError: Bool {
        switch self {
        case .stillRunning, .identityChanged, .verificationFailed, .failed: return true
        case .signalDelivered, .suspended, .resumed, .awaitingExit, .exited: return false
        }
    }
}

/// Classifies one post-termination liveness lookup. `nil` means the exact
/// process is still running. A lookup failure is reported as
/// `.verificationFailed`; pollers should retry before settling on it.
enum TerminationVerdict {
    static func outcome(
        for lookup: LiveProcessLookup,
        identity: ProcessIdentity
    ) -> ProcessActionOutcome? {
        switch lookup {
        case .absent: return .exited
        case let .found(facts) where facts.identity != identity: return .identityChanged
        case let .found(facts) where facts.isZombie: return .exited
        case .failed: return .verificationFailed
        case .found: return nil
        }
    }
}
