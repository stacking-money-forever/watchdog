import Foundation

/// Shared accumulation logic for processes that stay above a threshold for a
/// sustained period. Evidence resets after a sampling failure (missing
/// snapshot), a sample below the release threshold, an ignored process, or an
/// observation gap longer than `continuityGap`.
///
/// Entering requires `metric >= threshold`; once evidence exists it is kept
/// while `metric >= releaseThreshold`. The band stops a process hovering at
/// the threshold (a single-threaded busy loop measures 97–100%) from flapping
/// in and out and never accumulating a sustained window.
struct SustainedProcessTracker<Metric: Comparable> {
    private struct State {
        var since: ContinuousClock.Instant
        var lastSeen: ContinuousClock.Instant
    }

    private var states: [ProcessIdentity: State] = [:]
    let continuityGap: Duration

    init(continuityGap: Duration = .seconds(5)) {
        self.continuityGap = continuityGap
    }

    mutating func reset() {
        states.removeAll(keepingCapacity: true)
    }

    mutating func update(
        snapshots: [ProcessSnapshot],
        metric: (ProcessSnapshot) -> Metric,
        threshold: Metric,
        releaseThreshold: Metric? = nil,
        sustainedFor duration: TimeInterval,
        ignoredProcesses: Set<ProcessIdentity>,
        at instant: ContinuousClock.Instant
    ) -> Set<ProcessIdentity> {
        let liveIdentities = Set(snapshots.map(\.identity))
        states = states.filter { liveIdentities.contains($0.key) }

        var sustainedProcesses: Set<ProcessIdentity> = []

        let release = min(releaseThreshold ?? threshold, threshold)
        for snapshot in snapshots {
            let value = metric(snapshot)
            let isTracked = states[snapshot.identity] != nil
            guard snapshot.canControl,
                  !ignoredProcesses.contains(snapshot.identity),
                  value >= threshold || (isTracked && value >= release)
            else {
                states.removeValue(forKey: snapshot.identity)
                continue
            }

            let state: State
            if var existing = states[snapshot.identity] {
                let gap = existing.lastSeen.duration(to: instant)
                if gap < .zero || gap > continuityGap {
                    state = State(since: instant, lastSeen: instant)
                } else {
                    existing.lastSeen = instant
                    state = existing
                }
            } else {
                state = State(since: instant, lastSeen: instant)
            }
            states[snapshot.identity] = state

            if state.since.duration(to: instant) >= .seconds(duration) {
                sustainedProcesses.insert(snapshot.identity)
            }
        }

        return sustainedProcesses
    }
}
