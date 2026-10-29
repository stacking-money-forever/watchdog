import AppKit
import Combine
import Foundation
import OSLog
import UserNotifications

enum ProcessScope: String, CaseIterable, Identifiable {
    case attention = "주의 필요"
    case agents = "에이전트"
    case all = "전체"

    var id: String { rawValue }
}

struct ActionFeedback: Identifiable, Equatable {
    enum Kind {
        case success
        case error
    }

    let id = UUID()
    let kind: Kind
    let message: String
}

struct DestructiveActionConfirmationRequest: Sendable {
    fileprivate let id: UUID
    fileprivate let action: ProcessControlAction
    fileprivate let identity: ProcessIdentity
    fileprivate let requestedAt: ContinuousClock.Instant
}

private struct NotificationCooldownKey: Hashable {
    let identity: ProcessIdentity
    let reason: AlertReason
}

@MainActor
final class ProcessMonitor: ObservableObject {
    @Published private(set) var processes: [ProcessSnapshot] = []
    @Published private(set) var hotProcesses: Set<ProcessIdentity> = [] {
        didSet { updateAlertCount() }
    }
    @Published private(set) var highMemoryProcesses: Set<ProcessIdentity> = [] {
        didSet { updateAlertCount() }
    }
    @Published private(set) var systemCPUPercent: Double = 0
    @Published private(set) var systemMemory: SystemMemorySnapshot?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var samplingError: String?
    @Published private(set) var actionFeedback: ActionFeedback?
    @Published private(set) var actionOutcomes: [ProcessIdentity: ProcessActionOutcome] = [:]
    @Published private(set) var notificationAuthorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var isRefreshing = false
    @Published var autoSuspendEnabled: Bool {
        didSet {
            defaults.set(autoSuspendEnabled, forKey: Keys.autoSuspendEnabled)
        }
    }
    @Published var autoSuspendScope: MonitorSettings.AutoSuspendScope {
        didSet {
            defaults.set(autoSuspendScope.rawValue, forKey: Keys.autoSuspendScope)
        }
    }

    @Published var threshold: Double {
        didSet {
            let canonical = Self.normalizedCPU(threshold)
            if threshold != canonical { threshold = canonical }
            defaults.set(canonical, forKey: Keys.threshold)
        }
    }
    @Published var sustainedDuration: Double {
        didSet {
            let canonical = Self.normalizedDuration(sustainedDuration)
            if sustainedDuration != canonical { sustainedDuration = canonical }
            defaults.set(canonical, forKey: Keys.sustainedDuration)
        }
    }
    @Published var memoryThresholdGB: Double {
        didSet {
            let canonical = Self.normalizedMemory(memoryThresholdGB)
            if memoryThresholdGB != canonical { memoryThresholdGB = canonical }
            defaults.set(canonical, forKey: Keys.memoryThresholdGB)
        }
    }
    @Published var notificationsEnabled: Bool {
        didSet {
            defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
            if notificationsEnabled {
                requestNotificationPermission()
            } else {
                pendingCPUNotifications.removeAll(keepingCapacity: true)
                pendingMemoryNotifications.removeAll(keepingCapacity: true)
            }
        }
    }

    /// Processes Watchdog itself stopped and that are still stopped.
    @Published private(set) var watchdogSuspended: [SuspensionRecord] = []
    @Published var rulesStatus: AgentRules.LoadResult = .absent(AgentRules.standardURL())

    /// True while the menu is on screen. Rows then keep their positions across
    /// refreshes so a click can never land on a process that moved under the
    /// pointer; the list is fully re-sorted the next time the menu opens.
    var isPresented = false {
        didSet {
            if !isPresented, oldValue {
                processes = MonitorEngine.displayOrder(processes)
            } else if isPresented, !oldValue {
                // Worktree state is display-only and skipped while closed.
                let snapshots = processes
                Task { [weak self] in await self?.resolveWorktreeStates(snapshots: snapshots) }
            }
        }
    }

    private let defaults: UserDefaults
    private let sampler: any ProcessSampling
    private let ledger: SuspensionLedger
    private let journal: ActionJournal
    private let workingDirectoryResolver: WorkingDirectoryResolver
    private let worktreeResolver: WorktreeStateResolver
    private let authorization: ProcessActionAuthorizationActor
    private let controller: ProcessController
    private let notificationRequestSender: (UNNotificationRequest) -> Void
    private let clock = ContinuousClock()
    private var engine = MonitorEngine()
    private var refreshTask: Task<Void, Never>?
    private var refreshInFlight = false
    private var observation: ObservationToken?
    private var generation: UInt64 = 0
    private var notificationCooldowns: [NotificationCooldownKey: ContinuousClock.Instant] = [:]
    private var pendingCPUNotifications: [ProcessSnapshot] = []
    private var pendingMemoryNotifications: [ProcessSnapshot] = []
    private var actionOutcomeRecordedAt: [ProcessIdentity: ContinuousClock.Instant] = [:]
    private var pendingConfirmations: [UUID: ContinuousClock.Instant] = [:]
    private var terminationPollTasks: [ProcessIdentity: (id: UUID, task: Task<Void, Never>)] = [:]
    private var pendingJournalIDs: [ProcessIdentity: UUID] = [:]

    private static let log = Logger(subsystem: "dev.justn.watchdog", category: "journal")

    init(
        defaults: UserDefaults = .standard,
        sampler: any ProcessSampling = ProcessSampler(),
        ledger: SuspensionLedger = .inMemory(),
        journal: ActionJournal = .inMemory(),
        authorization: ProcessActionAuthorizationActor = ProcessActionAuthorizationActor(),
        controller: ProcessController = ProcessController(),
        workingDirectoryResolver: WorkingDirectoryResolver = WorkingDirectoryResolver(),
        worktreeResolver: WorktreeStateResolver = WorktreeStateResolver(),
        notificationRequestSender: @escaping (UNNotificationRequest) -> Void = {
            UNUserNotificationCenter.current().add($0)
        }
    ) {
        self.defaults = defaults
        self.sampler = sampler
        self.ledger = ledger
        self.journal = journal
        self.authorization = authorization
        self.controller = controller
        self.workingDirectoryResolver = workingDirectoryResolver
        self.worktreeResolver = worktreeResolver
        self.notificationRequestSender = notificationRequestSender
        let settings = MonitorSettings(defaults: defaults)
        threshold = settings.cpuThreshold
        sustainedDuration = settings.sustainedDuration
        memoryThresholdGB = settings.memoryThresholdGB
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        autoSuspendEnabled = settings.autoSuspendEnabled
        autoSuspendScope = settings.autoSuspendScope
        defaults.set(threshold, forKey: Keys.threshold)
        defaults.set(sustainedDuration, forKey: Keys.sustainedDuration)
        defaults.set(memoryThresholdGB, forKey: Keys.memoryThresholdGB)
    }

    /// Orphans are informational: a detached-but-healthy agent must not keep
    /// the menu bar badge lit. Only live CPU/memory pressure counts as an alert.
    /// Stored and only written when it changes, so the menu bar label is
    /// not re-rendered on every sample.
    @Published private(set) var alertCount = 0

    private func updateAlertCount() {
        let count = hotProcesses.union(highMemoryProcesses).count
        if count != alertCount { alertCount = count }
    }


    var settings: MonitorSettings {
        MonitorSettings(
            cpuThreshold: threshold,
            sustainedDuration: sustainedDuration,
            memoryThresholdGB: memoryThresholdGB,
            autoSuspendEnabled: autoSuspendEnabled,
            autoSuspendScope: autoSuspendScope
        )
    }

    func start() {
        guard refreshTask == nil else { return }
        requestNotificationPermission()
        reconcileLedger()

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// A refresh the user asked for; only this one shows the spinner.
    func refreshNow() async {
        guard !refreshInFlight else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await refresh()
    }

    func refresh() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }

        do {
            let sample = try await sampler.sample()
            apply(sample)
            await workingDirectoryResolver.resolve(
                processes,
                generation: generation
            ) { [weak self] result in
                await self?.mergeWorkingDirectory(result)
            }
            await autoSuspend(lastUpdate)
            if isPresented {
                await resolveWorktreeStates(snapshots: processes)
            }
        } catch {
            samplingFailed(error)
            await authorization.invalidateAll()
            await workingDirectoryResolver.cancel(generation: generation)
        }
    }

    private var lastUpdate: MonitorUpdate?

    /// Publishes one successful sample in a single main-actor turn so the UI
    /// never renders a half-applied observation.
    private func apply(_ sample: ProcessSample) {
        let increment = generation.addingReportingOverflow(1)
        guard !increment.overflow else {
            samplingFailed(ProcessControlError.staleObservation)
            return
        }
        generation = increment.partialValue
        let token = ObservationToken(generation: generation, instant: clock.now)
        observation = token

        let update = engine.ingest(sample.processes, settings: settings, at: token.instant)
        lastUpdate = update
        let liveIdentities = Set(update.processes.map(\.identity))
        pruneNotificationCooldowns(liveIdentities: liveIdentities, at: token.instant)
        pruneActionOutcomes(at: token.instant)

        processes = isPresented
            ? Self.positionStable(update.processes, previous: processes)
            : update.processes
        if hotProcesses != update.hot { hotProcesses = update.hot }
        if highMemoryProcesses != update.highMemory { highMemoryProcesses = update.highMemory }
        if let systemCPUPercent = sample.systemCPUPercent, systemCPUPercent != self.systemCPUPercent {
            self.systemCPUPercent = systemCPUPercent
        }
        if systemMemory != sample.systemMemory { systemMemory = sample.systemMemory }
        lastUpdated = Date()
        if samplingError != nil { samplingError = nil }
        refreshWatchdogSuspended(liveProcesses: update.processes)

        if notificationsEnabled, notificationAuthorization != .denied {
            prunePendingNotifications(
                hotIdentities: update.hot,
                highMemoryIdentities: update.highMemory
            )
            enqueueCPUNotifications(for: update.processes.filter { update.newlyHot.contains($0.identity) })
            enqueueMemoryNotifications(for: update.processes.filter { update.newlyHighMemory.contains($0.identity) })
            sendPendingNotifications(at: token.instant)
        }
    }

    /// Keeps rows that are still alive in their previous positions and
    /// appends newcomers (in display order) at the end.
    static func positionStable(
        _ next: [ProcessSnapshot],
        previous: [ProcessSnapshot]
    ) -> [ProcessSnapshot] {
        guard !previous.isEmpty else { return next }
        let byIdentity = Dictionary(next.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<ProcessIdentity> = []
        var result: [ProcessSnapshot] = []
        result.reserveCapacity(next.count)
        for old in previous {
            if let updated = byIdentity[old.identity], seen.insert(old.identity).inserted {
                result.append(updated)
            }
        }
        for process in next where seen.insert(process.identity).inserted {
            result.append(process)
        }
        return result
    }

    /// Re-reads notification permission without prompting; used when the
    /// menu opens so a change made in System Settings shows immediately.
    func refreshNotificationAuthorization() {
        Task { [weak self] in
            let status = await Self.notificationAuthorizationStatus(from: UNUserNotificationCenter.current())
            self?.notificationAuthorization = status
        }
    }

    private func samplingFailed(_ error: Error) {
        samplingError = error.localizedDescription
        observation = nil
        lastUpdate = nil
        engine.samplingFailed()
        hotProcesses.removeAll()
        highMemoryProcesses.removeAll()
        pendingCPUNotifications.removeAll(keepingCapacity: true)
        pendingMemoryNotifications.removeAll(keepingCapacity: true)
        pendingConfirmations.removeAll(keepingCapacity: true)
    }

    func visibleProcesses(scope: ProcessScope, search: String) -> [ProcessSnapshot] {
        let scoped: [ProcessSnapshot]

        switch scope {
        case .attention:
            // A process Watchdog stopped stays here with its resume control,
            // even though its CPU dropped to zero the moment it stopped.
            let stopped = Set(watchdogSuspended.map(\.identity))
            scoped = processes.filter {
                !engine.ignored.contains($0.identity)
                    && (hotProcesses.contains($0.identity)
                    || highMemoryProcesses.contains($0.identity)
                    || stopped.contains($0.identity))
            }
        case .agents:
            scoped = processes.filter { $0.kind == .agent || ($0.kind == .service && $0.agentName != nil) }
        case .all:
            scoped = processes
        }

        let filtered: [ProcessSnapshot]
        if search.isEmpty {
            filtered = scoped
        } else {
            let query = search.lowercased()
            filtered = scoped.filter {
                $0.displayName.lowercased().contains(query)
                    || $0.executablePath.lowercased().contains(query)
                    || ($0.launchScript?.lowercased().contains(query) ?? false)
                    || ($0.workingDirectory?.lowercased().contains(query) ?? false)
                    || ($0.agentAncestor?.name.contains(query) ?? false)
                    || String($0.id).contains(query)
            }
        }

        return scope == .all ? Array(filtered.prefix(60)) : filtered
    }

    func isHot(_ process: ProcessSnapshot) -> Bool {
        hotProcesses.contains(process.identity)
    }

    func isHighMemory(_ process: ProcessSnapshot) -> Bool {
        highMemoryProcesses.contains(process.identity)
    }

    func isIgnored(_ process: ProcessSnapshot) -> Bool {
        engine.ignored.contains(process.identity)
    }

    func isSuspendedByWatchdog(_ process: ProcessSnapshot) -> Bool {
        watchdogSuspended.contains { $0.identity == process.identity }
    }

    func alertReasons(for process: ProcessSnapshot) -> [AlertReason] {
        guard !isIgnored(process) else { return [] }
        var reasons: [AlertReason] = []
        if isHot(process) {
            reasons.append(.sustainedCPU(percent: threshold))
        }
        if isHighMemory(process) {
            reasons.append(.sustainedMemory(bytes: settings.memoryThresholdBytes))
        }
        if let orphanReason = process.orphanReason {
            reasons.append(.orphan(orphanReason))
        }
        return reasons
    }

    func actionability(of process: ProcessSnapshot) -> ProcessActionability {
        let freshness: ObservationFreshness
        if let observation {
            freshness = observation.instant.duration(to: clock.now) < .seconds(5) ? .current : .stale
        } else {
            freshness = .unavailable
        }
        return ProcessActionability(
            identity: process.identity,
            observation: observation,
            freshness: freshness,
            isIgnored: isIgnored(process),
            isProtected: process.isProtected
        )
    }

    func suspend(_ process: ProcessSnapshot) {
        performImmediate(.suspend, process: process, success: "일시 정지: \(process.displayName)")
    }

    func resume(_ process: ProcessSnapshot) {
        Task {
            do {
                let companions = ledger.groupCompanions(of: process.identity)
                do {
                    try await performAction(.resume, process: process, source: .manual, journalSource: .app)
                } catch ProcessControlError.observationRefreshed {
                    guard let fresh = processes.first(where: { $0.identity == process.identity }) else {
                        throw ProcessControlError.processChanged
                    }
                    try await performAction(.resume, process: fresh, source: .manual, journalSource: .app)
                }
                var extra = 0
                for record in companions {
                    guard let member = processes.first(where: { $0.identity == record.identity }) else {
                        continue
                    }
                    do {
                        try await performAction(
                            .resume,
                            process: member,
                            source: record.source,
                            journalSource: .app
                        )
                        extra += 1
                    } catch {
                        recordActionOutcome(.failed(error.localizedDescription), for: member.identity)
                    }
                }
                let message = extra > 0
                    ? "재개: \(process.displayName) · 세션 멤버 \(extra)개"
                    : "재개: \(process.displayName)"
                showFeedback(.init(kind: .success, message: message))
            } catch {
                recordActionOutcome(.failed(error.localizedDescription), for: process.identity)
                showFeedback(.init(kind: .error, message: error.localizedDescription))
            }
        }
    }

    /// Whether a confirmation can still complete. The view dismisses a
    /// confirmation that has expired or whose process is gone instead of
    /// leaving a dialog that can only fail.
    func isConfirmationValid(_ request: DestructiveActionConfirmationRequest) -> Bool {
        pendingConfirmations[request.id] == request.requestedAt
            && clock.now < request.requestedAt.advanced(by: Self.confirmationValidity)
            && processes.contains(where: { $0.identity == request.identity })
    }

    static let confirmationValidity: Duration = .seconds(30)

    func destructiveActionRequest(
        _ action: ProcessControlAction,
        for process: ProcessSnapshot
    ) throws -> DestructiveActionConfirmationRequest {
        guard action.isDestructive else { throw ProcessControlError.authorizationInvalid }
        try requireActionable(process, for: action)
        let requestedAt = clock.now
        pendingConfirmations = pendingConfirmations.filter {
            requestedAt < $0.value.advanced(by: Self.confirmationValidity)
        }
        guard pendingConfirmations.count < 256 else {
            throw ProcessControlError.authorizationCapacityReached
        }
        let request = DestructiveActionConfirmationRequest(
            id: UUID(),
            action: action,
            identity: process.identity,
            requestedAt: requestedAt
        )
        pendingConfirmations[request.id] = requestedAt
        return request
    }

    func completeDestructiveConfirmation(
        _ request: DestructiveActionConfirmationRequest
    ) async throws {
        guard pendingConfirmations.removeValue(forKey: request.id) == request.requestedAt,
              request.action.isDestructive
        else {
            throw ProcessControlError.confirmationNotPending
        }
        guard clock.now < request.requestedAt.advanced(by: Self.confirmationValidity) else {
            throw ProcessControlError.confirmationExpired
        }
        guard let process = processes.first(where: { $0.identity == request.identity }) else {
            throw ProcessControlError.processChanged
        }
        let observation = try requireActionable(process, for: request.action)
        let nonce = try await authorization.mint(
            action: request.action,
            identity: request.identity,
            observation: observation,
            at: clock.now
        )
        try await consumeAction(
            nonce,
            action: request.action,
            process: process,
            mintedGeneration: observation.generation
        )
    }

    func cancelDestructiveConfirmation(
        _ request: DestructiveActionConfirmationRequest
    ) {
        guard pendingConfirmations[request.id] == request.requestedAt else { return }
        pendingConfirmations.removeValue(forKey: request.id)
    }

    func ignoreUntilExit(_ process: ProcessSnapshot) {
        switch engine.ignore(process.identity) {
        case .capacityReached:
            showFeedback(.init(kind: .error, message: "무시 목록이 가득 찼습니다"))
        case .ignored:
            hotProcesses = engine.hot
            highMemoryProcesses = engine.highMemory
            showFeedback(.init(kind: .success, message: "이 프로세스는 종료할 때까지 무시합니다"))
        }
    }

    /// Auto-suspend is reversible by design: SIGSTOP halts runaway CPU and
    /// token consumption without ever killing work. Only coding agents newly
    /// flagged for sustained CPU are targeted (never memory-only, never apps),
    /// a process the user resumed by hand is left alone, and every signal goes
    /// through the same authorization pipeline as manual actions.
    private func autoSuspend(_ update: MonitorUpdate?) async {
        guard autoSuspendEnabled, let update else { return }
        if !update.autoSuspendGroups.isEmpty {
            for group in update.autoSuspendGroups {
                guard let root = update.processes.first(where: { $0.identity == group.root }) else {
                    continue
                }
                let groupID = IdentityToken(group.root).description
                let reason = sessionAutoSuspendReason(for: group.root, in: update)
                let targets = [root] + group.members
                var succeeded = 0
                for snapshot in targets {
                    do {
                        try await performAction(
                            .suspend,
                            process: snapshot,
                            source: .auto,
                            journalSource: .auto,
                            reason: reason,
                            groupID: groupID
                        )
                        succeeded += 1
                    } catch {
                        recordActionOutcome(.failed(error.localizedDescription), for: snapshot.identity)
                    }
                }
                showFeedback(
                    .init(
                        kind: succeeded > 0 ? .success : .error,
                        message: "세션 일시 정지: \(root.displayName) · 멤버 \(targets.count)개 중 \(succeeded)개"
                    )
                )
            }
            return
        }
        for snapshot in update.autoSuspendCandidates {
            do {
                try await performAction(
                    .suspend,
                    process: snapshot,
                    source: .auto,
                    journalSource: .auto,
                    reason: autoSuspendReason(for: snapshot)
                )
                showFeedback(
                    .init(kind: .success, message: "자동 일시 정지: \(snapshot.displayName) (CPU 임계값 지속 초과)")
                )
            } catch {
                recordActionOutcome(.failed(error.localizedDescription), for: snapshot.identity)
            }
        }
    }

    func undoIgnore(_ process: ProcessSnapshot) {
        guard engine.undoIgnore(process.identity) else { return }
        hotProcesses = engine.hot
        highMemoryProcesses = engine.highMemory
        showFeedback(.init(kind: .success, message: "이 프로세스를 다시 감시합니다"))
    }

    /// Resumes every process Watchdog stopped that is still stopped. Used when
    /// the app quits so nothing is left frozen behind it.
    func resumeAllWatchdogSuspended() async -> (resumed: Int, failed: Int) {
        // Take a fresh observation so every resume goes through the normal
        // single-use authorization bound to a real sample generation.
        await refresh()
        reconcileLedger()
        var resumed = 0
        var failed = 0
        var handled: Set<ProcessIdentity> = []
        for record in watchdogSuspended {
            guard !handled.contains(record.identity) else { continue }
            let batch: [SuspensionRecord]
            if let groupID = record.groupID,
               IdentityToken(record.identity).description == groupID {
                let companions = ledger.records(inGroup: groupID).filter { $0.identity != record.identity }
                batch = [record] + companions
            } else {
                batch = [record]
            }
            for item in batch {
                handled.insert(item.identity)
                guard let process = processes.first(where: { $0.identity == item.identity }) else {
                    failed += 1
                    continue
                }
                do {
                    try await performAction(
                        .resume,
                        process: process,
                        source: item.source,
                        journalSource: .app
                    )
                    resumed += 1
                } catch {
                    failed += 1
                }
            }
        }
        reconcileLedger()
        return (resumed, failed)
    }

    func reconcileLedger() {
        let controller = controller
        watchdogSuspended = (try? ledger.reconcile(lookup: { controller.lookup(pid: $0) })) ?? ledger.all()
    }

    private func refreshWatchdogSuspended(liveProcesses: [ProcessSnapshot]) {
        // Cheap per-sample reconciliation against the sample itself; the full
        // live lookup runs on start and after actions.
        let records = ledger.all()
        guard !records.isEmpty else {
            if !watchdogSuspended.isEmpty { watchdogSuspended = [] }
            return
        }
        let live = Dictionary(
            liveProcesses.map { ($0.identity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var retained: [SuspensionRecord] = []
        for record in records {
            if let process = live[record.identity], process.isSuspended {
                retained.append(record)
                continue
            }
            // The sample was taken off the main actor and may predate a
            // suspend that finished while it ran (here or from the CLI).
            // Trusting it would drop a fresh record and leave the process
            // frozen but forgotten, so confirm with a live lookup first.
            let current = controller.lookup(pid: record.identity.pid)
            if case let .found(facts) = current, facts.identity == record.identity, facts.isSuspended {
                retained.append(record)
                continue
            }
            if case .failed = current {
                retained.append(record)
                continue
            }
            // The CLI writes its record just before sending SIGSTOP; a lookup
            // in between still sees the process running.
            if record.source == .cli, Date().timeIntervalSince(record.suspendedAt) < 5 {
                retained.append(record)
                continue
            }
            _ = try? ledger.remove(record.identity)
            if case let .found(facts) = current, facts.identity == record.identity {
                // Someone continued it outside this app (the CLI, a
                // terminal `fg`, `kill -CONT`): treat that as the user's
                // decision so auto-suspend does not stop it again.
                engine.recordUserResume(record.identity)
            }
        }
        if retained != watchdogSuspended { watchdogSuspended = retained }
    }

    /// Ask the worktree resolver about each agent's project directory. Only
    /// paths that look like a git worktree (`…/<repo>/…` pattern) are probed;
    /// results merge back generation-safely.
    private func resolveWorktreeStates(snapshots: [ProcessSnapshot]) async {
        let candidates = snapshots.filter {
            $0.kind == .agent
                && $0.workingDirectory != nil
                && $0.workingDirectory != "/"
        }
        guard !candidates.isEmpty else { return }
        let generation = observation?.generation ?? generation
        await worktreeResolver.resolve(candidates.map(\.workingDirectory!)) { [weak self] path, state in
            Task { @MainActor [weak self] in
                self?.mergeWorktreeState(path: path, state: state, generation: generation)
            }
        }
    }

    private func mergeWorktreeState(
        path: String,
        state: WorktreeState?,
        generation: UInt64
    ) {
        guard observation?.generation == generation else { return }
        for index in processes.indices
        where processes[index].workingDirectory == path && processes[index].worktreeState != state {
            processes[index].worktreeState = state
            engine.recordWorktreeState(state, for: processes[index].identity)
        }
    }
#if DEBUG
    func loadStalePreview(
        processes: [ProcessSnapshot],
        hotProcesses: Set<ProcessIdentity>,
        highMemoryProcesses: Set<ProcessIdentity> = [],
        updatedAt: Date
    ) {
        generation &+= 1
        observation = ObservationToken(
            generation: generation,
            instant: clock.now.advanced(by: .seconds(-6))
        )
        loadPreview(
            processes: processes,
            hotProcesses: hotProcesses,
            highMemoryProcesses: highMemoryProcesses,
            updatedAt: updatedAt
        )
    }

    func loadActionablePreview(
        processes: [ProcessSnapshot],
        hotProcesses: Set<ProcessIdentity>,
        highMemoryProcesses: Set<ProcessIdentity> = [],
        updatedAt: Date
    ) {
        generation &+= 1
        observation = ObservationToken(generation: generation, instant: clock.now)
        loadPreview(
            processes: processes,
            hotProcesses: hotProcesses,
            highMemoryProcesses: highMemoryProcesses,
            updatedAt: updatedAt
        )
    }

    func refreshActionablePreviewObservation() {
        generation &+= 1
        observation = ObservationToken(generation: generation, instant: clock.now)
    }

    func loadPreview(
        processes: [ProcessSnapshot],
        hotProcesses: Set<ProcessIdentity>,
        highMemoryProcesses: Set<ProcessIdentity> = [],
        updatedAt: Date
    ) {
        self.processes = processes
        engine.loadPreview(hot: hotProcesses, highMemory: highMemoryProcesses)
        self.hotProcesses = engine.hot
        self.highMemoryProcesses = engine.highMemory
        systemCPUPercent = 37
        systemMemory = SystemMemorySnapshot(
            totalBytes: 48 * 1_024 * 1_024 * 1_024,
            usedBytes: 44 * 1_024 * 1_024 * 1_024,
            compressedBytes: 6 * 1_024 * 1_024 * 1_024,
            swapUsedBytes: 12 * 1_024 * 1_024 * 1_024,
            swapTotalBytes: 16 * 1_024 * 1_024 * 1_024,
            pressureLevel: .normal
        )
        lastUpdated = updatedAt
        samplingError = nil
    }

    var previewGeneration: UInt64 { generation }

    func mergeWorkingDirectoryPreview(_ result: WorkingDirectoryResult) {
        mergeWorkingDirectory(result)
    }

    func setActionOutcomePreview(_ outcome: ProcessActionOutcome, for process: ProcessSnapshot) {
        recordActionOutcome(outcome, for: process.identity)
    }

    func refreshAutoSuspendPreview(
        hot: Set<ProcessIdentity>,
        highMemory: Set<ProcessIdentity>,
        snapshots: [ProcessSnapshot],
        autoSuspendGroups: [AutoSuspendGroup] = [],
        sessions: [AgentSession] = []
    ) async {
        guard autoSuspendEnabled else { return }
        let candidates = autoSuspendGroups.isEmpty
            ? snapshots.filter {
                hot.contains($0.identity)
                    && MonitorEngine.isAutoSuspendEligible($0)
                    && !engine.userResumed.contains($0.identity)
            }
            : []
        await autoSuspend(
            MonitorUpdate(
                processes: snapshots,
                hot: hot,
                highMemory: highMemory,
                newlyHot: hot,
                newlyHighMemory: highMemory,
                autoSuspendCandidates: candidates,
                sessions: sessions,
                autoSuspendGroups: autoSuspendGroups
            )
        )
    }

    func applySamplePreview(_ sample: ProcessSample) {
        apply(sample)
    }

    var ledgerPreview: SuspensionLedger { ledger }
    var journalPreview: ActionJournal { journal }

    func pruneActionOutcomesPreview(at instant: ContinuousClock.Instant) {
        pruneActionOutcomes(at: instant)
    }

    func reserveNotificationPreview(
        identity: ProcessIdentity,
        reason: AlertReason,
        at instant: ContinuousClock.Instant
    ) -> Bool {
        reserveNotification(identity: identity, reason: reason, at: instant)
    }

    var notificationCooldownCountPreview: Int { notificationCooldowns.count }
    var pendingCPUNotificationCountPreview: Int { pendingCPUNotifications.count }
    var pendingMemoryNotificationCountPreview: Int { pendingMemoryNotifications.count }

    func enqueueCPUNotificationsPreview(_ snapshots: [ProcessSnapshot]) {
        enqueueCPUNotifications(for: snapshots)
    }

    func enqueueMemoryNotificationsPreview(_ snapshots: [ProcessSnapshot]) {
        enqueueMemoryNotifications(for: snapshots)
    }

    func sendPendingNotificationsPreview(at instant: ContinuousClock.Instant) {
        sendPendingNotifications(at: instant)
    }

    func hasNotificationCooldownPreview(identity: ProcessIdentity, reason: AlertReason) -> Bool {
        notificationCooldowns[NotificationCooldownKey(identity: identity, reason: reason)] != nil
    }

    var terminationPollCountPreview: Int { terminationPollTasks.count }

    func startTerminationPollPreview(for identity: ProcessIdentity) {
        pollTerminationOutcome(for: identity)
    }
#endif

    /// Throws the specific reason a process cannot be acted on right now.
    @discardableResult
    private func requireActionable(
        _ process: ProcessSnapshot,
        for action: ProcessControlAction
    ) throws -> ObservationToken {
        guard processes.contains(where: { $0.identity == process.identity }) else {
            throw ProcessControlError.processChanged
        }
        let state = actionability(of: process)
        // Ignoring hides alerts; it must never keep a process frozen. Resume
        // only restores a process, so it stays allowed for ignored rows.
        if state.isIgnored, action != .resume { throw ProcessControlError.processIgnored }
        if state.isProtected { throw ProcessControlError.protectedProcess }
        guard state.freshness == .current, let observation = state.observation else {
            throw ProcessControlError.staleObservation
        }
        return observation
    }

    /// Mint, consume, and execute one non-destructive action, then record it.
    private func performAction(
        _ action: ProcessControlAction,
        process: ProcessSnapshot,
        source: SuspensionRecord.Source,
        journalSource: ActionJournalEntry.Source,
        reason: String? = nil,
        groupID: String? = nil
    ) async throws {
        guard !action.isDestructive else { throw ProcessControlError.authorizationInvalid }
        let observation = try requireActionable(process, for: action)
        let nonce = try await authorization.mint(
            action: action,
            identity: process.identity,
            observation: observation,
            at: clock.now
        )
        try await consumeAction(
            nonce,
            action: action,
            process: process,
            mintedGeneration: observation.generation,
            source: source,
            journalSource: journalSource,
            reason: reason,
            groupID: groupID
        )
    }

    func consumeAction(
        _ nonce: ProcessActionNonce,
        action: ProcessControlAction,
        process: ProcessSnapshot,
        mintedGeneration: UInt64,
        source: SuspensionRecord.Source = .manual,
        journalSource: ActionJournalEntry.Source = .app,
        reason: String? = nil,
        groupID: String? = nil
    ) async throws {
        let observation = try requireActionable(process, for: action)
        // A sample landed between minting and consuming. Say so instead of
        // reporting a consumed approval.
        guard observation.generation == mintedGeneration else {
            throw ProcessControlError.observationRefreshed
        }
        let authorized = try await authorization.consume(
            nonce,
            action: action,
            identity: process.identity,
            currentGeneration: observation.generation,
            at: clock.now
        )
        guard let currentObservation = self.observation,
              currentObservation.generation == authorized.observationGeneration
        else {
            throw ProcessControlError.observationRefreshed
        }
        try requireActionable(process, for: action)
        if action == .suspend {
            // Write ahead: a stop Watchdog cannot remember is one it could
            // never offer to undo, so refuse rather than stop.
            do {
                try ledger.record(
                    SuspensionRecord(
                        identity: process.identity,
                        executablePath: process.executablePath,
                        suspendedAt: Date(),
                        source: source,
                        groupID: groupID
                    )
                )
            } catch {
                throw ProcessControlError.ledgerUnavailable(error.localizedDescription)
            }
        }
        do {
            try controller.execute(
                authorized,
                currentGeneration: currentObservation.generation
            )
        } catch let ProcessControlError.partiallyApplied(delivered, failure) where delivered.contains(SIGCONT) {
            // A stopped process was continued but not terminated: it is
            // running again and no longer Watchdog-suspended.
            _ = try? ledger.remove(process.identity)
            reconcileLedger()
            recordJournal(
                id: UUID(),
                action: action,
                process: process,
                source: journalSource,
                reason: reason,
                outcome: .failed(ProcessControlError.partiallyApplied(delivered: delivered, failure: failure).localizedDescription)
            )
            throw ProcessControlError.partiallyApplied(delivered: delivered, failure: failure)
        } catch {
            if action == .suspend {
                _ = try? ledger.remove(process.identity)
                watchdogSuspended = ledger.all()
            }
            if let controlError = error as? ProcessControlError, controlError.didSendSignal {
                recordJournal(
                    id: UUID(),
                    action: action,
                    process: process,
                    source: journalSource,
                    reason: reason,
                    outcome: .failed(error.localizedDescription)
                )
            }
            throw error
        }

        reflectLiveState(of: process.identity)

        let journalID = UUID()
        switch action {
        case .suspend:
            recordActionOutcome(.suspended, for: process.identity)
            recordJournal(
                id: journalID,
                action: action,
                process: process,
                source: journalSource,
                reason: reason,
                outcome: .suspended
            )
        case .resume:
            _ = try? ledger.remove(process.identity)
            engine.recordUserResume(process.identity)
            recordActionOutcome(.resumed, for: process.identity)
            recordJournal(
                id: journalID,
                action: action,
                process: process,
                source: journalSource,
                reason: reason,
                outcome: .resumed,
                undoOf: lastSuspendJournalID(for: process.identity)
            )
        case .terminate, .forceQuit:
            _ = try? ledger.remove(process.identity)
            recordActionOutcome(.awaitingExit, for: process.identity)
            recordJournal(
                id: journalID,
                action: action,
                process: process,
                source: journalSource,
                reason: reason,
                outcome: .awaitingExit
            )
            pendingJournalIDs[process.identity] = journalID
            pollTerminationOutcome(for: process.identity)
        }
        watchdogSuspended = ledger.all()
    }

    /// Updates the row from a live lookup right after a signal, so the
    /// pause/play control flips immediately instead of a sample later.
    private func reflectLiveState(of identity: ProcessIdentity) {
        guard case let .found(facts) = controller.lookup(pid: identity.pid),
              facts.identity == identity,
              let index = processes.firstIndex(where: { $0.identity == identity })
        else { return }
        let stopped = processes[index].isSuspended
        if facts.isSuspended && !stopped {
            processes[index].state = "T"
        } else if !facts.isSuspended && stopped {
            processes[index].state = processes[index].state.replacingOccurrences(of: "T", with: "S")
        }
    }

    private func performImmediate(
        _ action: ProcessControlAction,
        process: ProcessSnapshot,
        success message: String
    ) {
        Task {
            do {
                do {
                    try await performAction(action, process: process, source: .manual, journalSource: .app)
                } catch ProcessControlError.observationRefreshed {
                    // Non-destructive and reversible: one retry against the
                    // fresh observation (a new single-use authorization).
                    guard let fresh = processes.first(where: { $0.identity == process.identity }) else {
                        throw ProcessControlError.processChanged
                    }
                    try await performAction(action, process: fresh, source: .manual, journalSource: .app)
                }
                showFeedback(.init(kind: .success, message: message))
            } catch {
                recordActionOutcome(.failed(error.localizedDescription), for: process.identity)
                showFeedback(.init(kind: .error, message: error.localizedDescription))
            }
        }
    }

    private func mergeWorkingDirectory(_ result: WorkingDirectoryResult) {
        guard observation?.generation == result.generation,
              let index = processes.firstIndex(where: { $0.identity == result.identity })
        else {
            return
        }
        // The resolver answers from its cache every sample; the engine
        // already carried the value forward, so an unchanged answer must not
        // publish again or start another worktree lookup.
        guard processes[index].workingDirectory != result.workingDirectory else { return }
        processes[index].workingDirectory = result.workingDirectory
        engine.recordWorkingDirectory(result.workingDirectory, for: result.identity)
        guard isPresented else { return }
        let snapshot = processes[index]
        Task { [weak self] in
            await self?.resolveWorktreeStates(snapshots: [snapshot])
        }
    }

    private func pollTerminationOutcome(for identity: ProcessIdentity) {
        terminationPollTasks[identity]?.task.cancel()
        let pollID = UUID()
        let controller = controller
        let task = Task { [weak self] in
            defer { self?.finishTerminationPoll(identity: identity, id: pollID) }
            for attempt in 0..<20 {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                let lookup = await Task.detached(priority: .utility) {
                    controller.lookup(pid: identity.pid)
                }.value
                guard !Task.isCancelled else { return }
                let outcome = Self.terminationOutcome(for: lookup, identity: identity)
                // One failed lookup mid-exit is not a verdict; keep polling and
                // only report the failure if the budget runs out on it.
                if let outcome, outcome != .verificationFailed {
                    self.recordActionOutcome(outcome, for: identity)
                    self.finishJournalTermination(identity: identity, outcome: outcome)
                    return
                }
                if attempt == 19 {
                    let settled = outcome ?? .stillRunning
                    self.recordActionOutcome(settled, for: identity)
                    self.finishJournalTermination(identity: identity, outcome: settled)
                }
            }
        }
        terminationPollTasks[identity] = (pollID, task)
    }

    static func terminationOutcome(
        for lookup: LiveProcessLookup,
        identity: ProcessIdentity
    ) -> ProcessActionOutcome? {
        TerminationVerdict.outcome(for: lookup, identity: identity)
    }

    private func finishTerminationPoll(identity: ProcessIdentity, id: UUID) {
        guard terminationPollTasks[identity]?.id == id else { return }
        terminationPollTasks[identity] = nil
    }

    private func autoSuspendReason(for process: ProcessSnapshot) -> String {
        "CPU \(Int(process.cpuPercent.rounded()))% 지속 \(Int(sustainedDuration.rounded()))초"
    }

    private func sessionAutoSuspendReason(for root: ProcessIdentity, in update: MonitorUpdate) -> String {
        let cpu = update.sessions.first { $0.id == root }?.cpuPercent
            ?? update.processes.first { $0.identity == root }?.cpuPercent
            ?? 0
        return "세션 합계 CPU \(Int(cpu.rounded()))% 지속 \(Int(sustainedDuration.rounded()))초"
    }

    private func lastSuspendJournalID(for identity: ProcessIdentity) -> UUID? {
        journal.all().last {
            $0.pid == identity.pid
                && $0.startTimeMicroseconds == identity.startTimeMicroseconds
                && $0.userID == identity.userID
                && $0.action == .suspend
        }?.id
    }

    private func finishJournalTermination(identity: ProcessIdentity, outcome: ProcessActionOutcome) {
        guard let id = pendingJournalIDs.removeValue(forKey: identity) else { return }
        do {
            try journal.update(id: id, outcome: ActionJournalEntry.outcomeString(outcome))
        } catch {
            Self.log.error("ActionJournal update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recordJournal(
        id: UUID,
        action: ProcessControlAction,
        process: ProcessSnapshot,
        source: ActionJournalEntry.Source,
        reason: String?,
        outcome: ProcessActionOutcome,
        undoOf: UUID? = nil
    ) {
        let entry = ActionJournalEntry(
            id: id,
            source: source,
            action: action,
            process: process,
            reason: reason,
            outcome: outcome,
            undoOf: undoOf
        )
        do {
            try journal.append(entry)
        } catch {
            Self.log.error("ActionJournal append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func recordActionOutcome(
        _ outcome: ProcessActionOutcome,
        for identity: ProcessIdentity
    ) {
        let recordedAt = clock.now
        actionOutcomes[identity] = outcome
        actionOutcomeRecordedAt[identity] = recordedAt
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard self?.actionOutcomeRecordedAt[identity] == recordedAt else { return }
            self?.actionOutcomeRecordedAt[identity] = nil
            self?.actionOutcomes[identity] = nil
        }
    }

    private func pruneActionOutcomes(at instant: ContinuousClock.Instant) {
        let retained = actionOutcomeRecordedAt.filter {
            $0.value.duration(to: instant) < .seconds(30)
        }
        actionOutcomeRecordedAt = retained
        actionOutcomes = actionOutcomes.filter { retained[$0.key] != nil }
    }

    private func showFeedback(_ feedback: ActionFeedback) {
        actionFeedback = feedback
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard self?.actionFeedback?.id == feedback.id else { return }
            self?.actionFeedback = nil
        }
    }

    /// `UNNotificationSettings` is not `Sendable`, so read the authorization
    /// status in a nonisolated context and hand only the `Sendable` enum back to
    /// the main actor. Reading the settings object directly on the main actor
    /// compiles on newer toolchains but is rejected as a non-Sendable result
    /// sent from a nonisolated context by the one the release workflow uses.
    private nonisolated static func notificationAuthorizationStatus(
        from center: UNUserNotificationCenter
    ) async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    private func requestNotificationPermission() {
        let shouldRequestAuthorization = notificationsEnabled
        Task { [weak self] in
            let center = UNUserNotificationCenter.current()
            if shouldRequestAuthorization {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let authorizationStatus = await Self.notificationAuthorizationStatus(from: center)
            self?.notificationAuthorization = authorizationStatus
        }
    }

    private func sendCPUNotifications(
        for snapshots: [ProcessSnapshot],
        at instant: ContinuousClock.Instant
    ) {
        for snapshot in snapshots {
            let reason = AlertReason.sustainedCPU(percent: threshold)
            guard reserveNotification(identity: snapshot.identity, reason: reason, at: instant) else {
                continue
            }
            let content = UNMutableNotificationContent()
            content.title = "\(snapshot.displayName)의 CPU 사용량이 높습니다"
            content.body = "PID \(snapshot.id) · CPU \(Int(threshold))%를 계속 초과하고 있습니다"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "watchdog-hot-\(snapshot.id)-\(snapshot.startTimeMicroseconds)",
                content: content,
                trigger: nil
            )
            notificationRequestSender(request)
        }
    }

    private func sendMemoryNotifications(
        for snapshots: [ProcessSnapshot],
        at instant: ContinuousClock.Instant
    ) {
        for snapshot in snapshots {
            let reason = AlertReason.sustainedMemory(bytes: settings.memoryThresholdBytes)
            guard reserveNotification(identity: snapshot.identity, reason: reason, at: instant) else {
                continue
            }
            let content = UNMutableNotificationContent()
            content.title = "\(snapshot.displayName)의 메모리 사용량이 높습니다"
            let current = WatchdogFormatters.memory.string(fromByteCount: Int64(snapshot.residentBytes))
            content.body = "PID \(snapshot.id) · 현재 \(current) · 제한 \(memoryThresholdGB.formatted(.number.precision(.fractionLength(1))))GB"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "watchdog-memory-\(snapshot.id)-\(snapshot.startTimeMicroseconds)",
                content: content,
                trigger: nil
            )
            notificationRequestSender(request)
        }
    }

    private func enqueueCPUNotifications(for snapshots: [ProcessSnapshot]) {
        var queuedIdentities = Set(pendingCPUNotifications.map(\.identity))
        for snapshot in snapshots where !queuedIdentities.contains(snapshot.identity) {
            guard pendingNotificationCount < 512 else { return }
            pendingCPUNotifications.append(snapshot)
            queuedIdentities.insert(snapshot.identity)
        }
    }

    private func enqueueMemoryNotifications(for snapshots: [ProcessSnapshot]) {
        var queuedIdentities = Set(pendingMemoryNotifications.map(\.identity))
        for snapshot in snapshots where !queuedIdentities.contains(snapshot.identity) {
            guard pendingNotificationCount < 512 else { return }
            pendingMemoryNotifications.append(snapshot)
            queuedIdentities.insert(snapshot.identity)
        }
    }

    private var pendingNotificationCount: Int {
        pendingCPUNotifications.count + pendingMemoryNotifications.count
    }

    private func sendPendingNotifications(at instant: ContinuousClock.Instant) {
        let cpuBatch = Array(pendingCPUNotifications.prefix(3))
        pendingCPUNotifications.removeFirst(cpuBatch.count)
        sendCPUNotifications(for: cpuBatch, at: instant)

        let memoryBatch = Array(pendingMemoryNotifications.prefix(3))
        pendingMemoryNotifications.removeFirst(memoryBatch.count)
        sendMemoryNotifications(for: memoryBatch, at: instant)
    }

    private func prunePendingNotifications(
        hotIdentities: Set<ProcessIdentity>,
        highMemoryIdentities: Set<ProcessIdentity>
    ) {
        pendingCPUNotifications.removeAll { !hotIdentities.contains($0.identity) }
        pendingMemoryNotifications.removeAll { !highMemoryIdentities.contains($0.identity) }
    }

    private func reserveNotification(
        identity: ProcessIdentity,
        reason: AlertReason,
        at instant: ContinuousClock.Instant
    ) -> Bool {
        let key = NotificationCooldownKey(identity: identity, reason: reason)
        if let sentAt = notificationCooldowns[key],
           sentAt.duration(to: instant) < .seconds(600) {
            return false
        }
        guard notificationCooldowns[key] != nil || notificationCooldowns.count < 512 else {
            return false
        }
        notificationCooldowns[key] = instant
        return true
    }

    private func pruneNotificationCooldowns(
        liveIdentities: Set<ProcessIdentity>,
        at instant: ContinuousClock.Instant
    ) {
        notificationCooldowns = notificationCooldowns.filter { key, sentAt in
            liveIdentities.contains(key.identity)
                && sentAt.duration(to: instant) < .seconds(600)
        }
    }

    private typealias Keys = MonitorSettings.Keys

    private static func normalizedCPU(_ value: Double) -> Double {
        MonitorSettings.normalizedCPU(value)
    }

    private static func normalizedDuration(_ value: Double) -> Double {
        MonitorSettings.normalizedDuration(value)
    }

    private static func normalizedMemory(_ value: Double) -> Double {
        MonitorSettings.normalizedMemory(value)
    }
}
