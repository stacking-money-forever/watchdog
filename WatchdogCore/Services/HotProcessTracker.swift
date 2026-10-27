import Foundation

struct HotProcessTracker {
    private var base: SustainedProcessTracker<Double>

    init(continuityGap: Duration = .seconds(5)) {
        base = SustainedProcessTracker(continuityGap: continuityGap)
    }

    mutating func reset() {
        base.reset()
    }

    mutating func update(
        snapshots: [ProcessSnapshot],
        threshold: Double,
        releaseFraction: Double = 1,
        sustainedFor duration: TimeInterval,
        ignoredProcesses: Set<ProcessIdentity>,
        at instant: ContinuousClock.Instant
    ) -> Set<ProcessIdentity> {
        base.update(
            snapshots: snapshots,
            metric: { $0.cpuPercent },
            threshold: threshold,
            releaseThreshold: threshold * min(max(releaseFraction, 0), 1),
            sustainedFor: duration,
            ignoredProcesses: ignoredProcesses,
            at: instant
        )
    }
}
