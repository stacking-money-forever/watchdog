import Foundation

/// Detection settings shared by the menu bar app and the CLI. Values are
/// normalized on every read so corrupted defaults can never produce an
/// infinite, negative, or absurd threshold.
struct MonitorSettings: Equatable, Sendable {
    static let defaultsSuiteName = "dev.justn.watchdog"

    enum Keys {
        static let threshold = "threshold"
        static let sustainedDuration = "sustainedDuration"
        static let memoryThresholdGB = "memoryThresholdGB"
        static let notificationsEnabled = "notificationsEnabled"
        static let autoSuspendEnabled = "autoSuspendEnabled"
    }

    /// Below-threshold samples keep existing CPU evidence while they stay at or
    /// above this fraction of the threshold.
    static let cpuReleaseFraction = 0.8
    /// Same band for memory; resident size moves slowly, so the band is tighter.
    static let memoryReleaseFraction = 0.9

    var cpuThreshold: Double
    var sustainedDuration: Double
    var memoryThresholdGB: Double
    var autoSuspendEnabled: Bool

    init(
        cpuThreshold: Double = 100,
        sustainedDuration: Double = 20,
        memoryThresholdGB: Double = 2,
        autoSuspendEnabled: Bool = false
    ) {
        self.cpuThreshold = Self.normalizedCPU(cpuThreshold)
        self.sustainedDuration = Self.normalizedDuration(sustainedDuration)
        self.memoryThresholdGB = Self.normalizedMemory(memoryThresholdGB)
        self.autoSuspendEnabled = autoSuspendEnabled
    }

    init(defaults: UserDefaults) {
        self.init(
            cpuThreshold: defaults.object(forKey: Keys.threshold) as? Double ?? 100,
            sustainedDuration: defaults.object(forKey: Keys.sustainedDuration) as? Double ?? 20,
            memoryThresholdGB: defaults.object(forKey: Keys.memoryThresholdGB) as? Double ?? 2,
            autoSuspendEnabled: defaults.object(forKey: Keys.autoSuspendEnabled) as? Bool ?? false
        )
    }

    var memoryThresholdBytes: UInt64 {
        UInt64(memoryThresholdGB * 1_024 * 1_024 * 1_024)
    }

    static func normalizedCPU(_ value: Double) -> Double {
        guard value.isFinite else { return 100 }
        return min(max(value, 1), 1_000)
    }

    static func normalizedDuration(_ value: Double) -> Double {
        guard value.isFinite else { return 20 }
        return min(max(value, 2), 300)
    }

    static func normalizedMemory(_ value: Double) -> Double {
        guard value.isFinite else { return 2 }
        return min(max(value, 0.1), 1_024)
    }
}

/// Result of feeding one successful sample into the engine.
struct MonitorUpdate: Sendable {
    /// Classified snapshots in a stable display order.
    let processes: [ProcessSnapshot]
    let hot: Set<ProcessIdentity>
    let highMemory: Set<ProcessIdentity>
    let newlyHot: Set<ProcessIdentity>
    let newlyHighMemory: Set<ProcessIdentity>
    /// Processes that auto-suspend may stop now (only when enabled).
    let autoSuspendCandidates: [ProcessSnapshot]
    /// Agent/service session totals. Empty when the caller did not ingest
    /// through `MonitorEngine` (preview helpers keep the process-only path).
    let sessions: [AgentSession]
    let hotSessions: Set<ProcessIdentity>
    let highMemorySessions: Set<ProcessIdentity>

    init(
        processes: [ProcessSnapshot],
        hot: Set<ProcessIdentity>,
        highMemory: Set<ProcessIdentity>,
        newlyHot: Set<ProcessIdentity>,
        newlyHighMemory: Set<ProcessIdentity>,
        autoSuspendCandidates: [ProcessSnapshot],
        sessions: [AgentSession] = [],
        hotSessions: Set<ProcessIdentity> = [],
        highMemorySessions: Set<ProcessIdentity> = []
    ) {
        self.processes = processes
        self.hot = hot
        self.highMemory = highMemory
        self.newlyHot = newlyHot
        self.newlyHighMemory = newlyHighMemory
        self.autoSuspendCandidates = autoSuspendCandidates
        self.sessions = sessions
        self.hotSessions = hotSessions
        self.highMemorySessions = highMemorySessions
    }
}

/// The UI-free detection state machine: orphan classification, sustained
/// CPU/memory evidence with hysteresis, ignore/undo, and the auto-suspend
/// policy. `ProcessMonitor` and `watchdog-cli watch` both drive it, so the
/// behaviour verified through the CLI is the behaviour the app ships.
struct MonitorEngine: Sendable {
    private(set) var hot: Set<ProcessIdentity> = []
    private(set) var highMemory: Set<ProcessIdentity> = []
    private(set) var ignored: Set<ProcessIdentity> = []
    /// Processes the user resumed by hand. Auto-suspend must respect that
    /// decision instead of stopping the process again a window later.
    private(set) var userResumed: Set<ProcessIdentity> = []

    private var hotTracker: HotProcessTracker
    private var memoryTracker: MemoryProcessTracker
    private var sessionHotTracker: HotProcessTracker
    private var sessionMemoryTracker: MemoryProcessTracker

    /// `continuityGap` is the longest gap between samples that still counts
    /// as continuous evidence. It must exceed the sampling interval, or a
    /// slow sampler (e.g. `watch --interval 10`) resets every tick and never
    /// alerts.
    init(continuityGap: Duration = .seconds(5)) {
        hotTracker = HotProcessTracker(continuityGap: continuityGap)
        memoryTracker = MemoryProcessTracker(continuityGap: continuityGap)
        sessionHotTracker = HotProcessTracker(continuityGap: continuityGap)
        sessionMemoryTracker = MemoryProcessTracker(continuityGap: continuityGap)
    }
    /// Evidence (unmasked) from the previous sample. Ignoring masks the output
    /// without discarding evidence, so undo restores a flag that survives the
    /// next sample.
    private var rawHot: Set<ProcessIdentity> = []
    private var rawHighMemory: Set<ProcessIdentity> = []
    private var rawHotSessions: Set<ProcessIdentity> = []
    private var rawHighMemorySessions: Set<ProcessIdentity> = []
    private(set) var hotSessions: Set<ProcessIdentity> = []
    private(set) var highMemorySessions: Set<ProcessIdentity> = []
    private var enrichment: [ProcessIdentity: Enrichment] = [:]

    private struct Enrichment: Sendable {
        var workingDirectory: String?
        var worktreeState: WorktreeState?
    }

    static let ignoreCapacity = 512

    mutating func ingest(
        _ rawSnapshots: [ProcessSnapshot],
        settings: MonitorSettings,
        at instant: ContinuousClock.Instant
    ) -> MonitorUpdate {
        var snapshots = rawSnapshots
        let liveIdentities = Set(snapshots.map(\.identity))

        // A full enumeration that no longer contains an identity means that
        // exact process is gone (identity includes its start time).
        ignored.formIntersection(liveIdentities)
        userResumed.formIntersection(liveIdentities)
        enrichment = enrichment.filter { liveIdentities.contains($0.key) }

        // Working directory participates in temporary-path orphan detection,
        // so carry it before classification. Worktree badges are display-only
        // and merge afterwards.
        for index in snapshots.indices {
            guard let carried = enrichment[snapshots[index].identity] else { continue }
            if snapshots[index].workingDirectory == nil {
                snapshots[index].workingDirectory = carried.workingDirectory
            }
        }
        snapshots = OrphanClassifier.classify(snapshots)
        for index in snapshots.indices {
            guard let carried = enrichment[snapshots[index].identity] else { continue }
            if snapshots[index].worktreeState == nil,
               carried.worktreeState?.path == snapshots[index].workingDirectory {
                snapshots[index].worktreeState = carried.worktreeState
            }
        }
        // Give descendants their agent's (carried) working directory so they
        // show its project. Service roots are session roots too.
        let agentDirectories = Dictionary(
            snapshots.lazy.filter { $0.kind == .agent || $0.kind == .service }
                .map { ($0.id, $0.workingDirectory) },
            uniquingKeysWith: { first, _ in first }
        )
        for index in snapshots.indices {
            guard let pid = snapshots[index].agentAncestor?.pid,
                  let directory = agentDirectories[pid] ?? nil
            else { continue }
            snapshots[index].agentAncestor?.workingDirectory = directory
        }

        rawHot = hotTracker.update(
            snapshots: snapshots,
            threshold: settings.cpuThreshold,
            releaseFraction: MonitorSettings.cpuReleaseFraction,
            sustainedFor: settings.sustainedDuration,
            ignoredProcesses: [],
            at: instant
        )
        rawHighMemory = memoryTracker.update(
            snapshots: snapshots,
            thresholdBytes: settings.memoryThresholdBytes,
            releaseFraction: MonitorSettings.memoryReleaseFraction,
            sustainedFor: settings.sustainedDuration,
            ignoredProcesses: [],
            at: instant
        )

        let sessions = SessionAggregator.sessions(from: snapshots)
        let byIdentity = Dictionary(
            snapshots.map { ($0.identity, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let sessionSnapshots: [ProcessSnapshot] = sessions.compactMap { session in
            guard var root = byIdentity[session.id] else { return nil }
            root.cpuPercent = session.cpuPercent
            root.residentBytes = session.residentBytes
            return root
        }
        rawHotSessions = sessionHotTracker.update(
            snapshots: sessionSnapshots,
            threshold: settings.cpuThreshold,
            releaseFraction: MonitorSettings.cpuReleaseFraction,
            sustainedFor: settings.sustainedDuration,
            ignoredProcesses: [],
            at: instant
        )
        rawHighMemorySessions = sessionMemoryTracker.update(
            snapshots: sessionSnapshots,
            thresholdBytes: settings.memoryThresholdBytes,
            releaseFraction: MonitorSettings.memoryReleaseFraction,
            sustainedFor: settings.sustainedDuration,
            ignoredProcesses: [],
            at: instant
        )

        let previousHot = hot
        let previousHighMemory = highMemory
        hot = rawHot.subtracting(ignored)
        highMemory = rawHighMemory.subtracting(ignored)
        hotSessions = rawHotSessions.subtracting(ignored)
        highMemorySessions = rawHighMemorySessions.subtracting(ignored)
        let newlyHot = hot.subtracting(previousHot)
        let newlyHighMemory = highMemory.subtracting(previousHighMemory)

        let candidates: [ProcessSnapshot]
        if settings.autoSuspendEnabled {
            candidates = snapshots.filter {
                newlyHot.contains($0.identity) && Self.isAutoSuspendEligible($0)
                    && !userResumed.contains($0.identity)
            }
        } else {
            candidates = []
        }

        return MonitorUpdate(
            processes: Self.displayOrder(snapshots),
            hot: hot,
            highMemory: highMemory,
            newlyHot: newlyHot,
            newlyHighMemory: newlyHighMemory,
            autoSuspendCandidates: candidates,
            sessions: sessions,
            hotSessions: hotSessions,
            highMemorySessions: highMemorySessions
        )
    }

    /// The safety contract resets evidence when a sample fails.
    mutating func samplingFailed() {
        hotTracker.reset()
        memoryTracker.reset()
        sessionHotTracker.reset()
        sessionMemoryTracker.reset()
        rawHot.removeAll()
        rawHighMemory.removeAll()
        rawHotSessions.removeAll()
        rawHighMemorySessions.removeAll()
        hot.removeAll()
        highMemory.removeAll()
        hotSessions.removeAll()
        highMemorySessions.removeAll()
    }

    /// Auto-suspend only stops a coding agent whose CPU stayed high. Memory
    /// alone never qualifies: SIGSTOP frees no memory, and it would freeze
    /// ordinary apps (Xcode, browsers) above the memory threshold.
    /// Services stay resident by design (launchd daemons, `serve`/`app-server`);
    /// never auto-stop them.
    static func isAutoSuspendEligible(_ snapshot: ProcessSnapshot) -> Bool {
        snapshot.kind == .agent && !snapshot.isProtected && !snapshot.isSuspended
    }

    /// Stable order: orphans first, then CPU (bucketed to whole percent so
    /// sampling noise does not reshuffle rows), then PID.
    static func displayOrder(_ snapshots: [ProcessSnapshot]) -> [ProcessSnapshot] {
        snapshots.sorted {
            if $0.suspectedOrphan != $1.suspectedOrphan {
                return $0.suspectedOrphan
            }
            let left = $0.cpuPercent.isFinite ? $0.cpuPercent.rounded() : 0
            let right = $1.cpuPercent.isFinite ? $1.cpuPercent.rounded() : 0
            if left != right { return left > right }
            return $0.id < $1.id
        }
    }

    // MARK: - User decisions

    enum IgnoreResult: Equatable, Sendable {
        case ignored
        case capacityReached
    }

    mutating func ignore(_ identity: ProcessIdentity) -> IgnoreResult {
        guard ignored.contains(identity) || ignored.count < Self.ignoreCapacity else {
            return .capacityReached
        }
        ignored.insert(identity)
        hot.remove(identity)
        highMemory.remove(identity)
        hotSessions.remove(identity)
        highMemorySessions.remove(identity)
        return .ignored
    }

    /// Returns false when the identity was not ignored.
    @discardableResult
    mutating func undoIgnore(_ identity: ProcessIdentity) -> Bool {
        guard ignored.remove(identity) != nil else { return false }
        if rawHot.contains(identity) { hot.insert(identity) }
        if rawHighMemory.contains(identity) { highMemory.insert(identity) }
        if rawHotSessions.contains(identity) { hotSessions.insert(identity) }
        if rawHighMemorySessions.contains(identity) { highMemorySessions.insert(identity) }
        return true
    }

    mutating func recordUserResume(_ identity: ProcessIdentity) {
        userResumed.insert(identity)
    }

    // MARK: - Enrichment

    mutating func recordWorkingDirectory(_ directory: String?, for identity: ProcessIdentity) {
        var entry = enrichment[identity] ?? Enrichment()
        if entry.workingDirectory != directory {
            entry.worktreeState = nil
        }
        entry.workingDirectory = directory
        enrichment[identity] = entry
    }

    mutating func recordWorktreeState(_ state: WorktreeState?, for identity: ProcessIdentity) {
        guard var entry = enrichment[identity],
              entry.workingDirectory == state?.path || state == nil
        else { return }
        entry.worktreeState = state
        enrichment[identity] = entry
    }

#if DEBUG
    /// Test hook mirroring a preview load: replaces the published sets.
    mutating func loadPreview(hot: Set<ProcessIdentity>, highMemory: Set<ProcessIdentity>) {
        self.hot = hot.subtracting(ignored)
        self.highMemory = highMemory.subtracting(ignored)
        rawHot = hot
        rawHighMemory = highMemory
    }
#endif
}
