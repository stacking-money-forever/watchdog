import Foundation

struct MemoryProcessTracker {
    private var base: SustainedProcessTracker<UInt64>

    init(continuityGap: Duration = .seconds(5)) {
        base = SustainedProcessTracker(continuityGap: continuityGap)
    }

    mutating func reset() {
        base.reset()
    }

    mutating func update(
        snapshots: [ProcessSnapshot],
        thresholdBytes: UInt64,
        releaseFraction: Double = 1,
        sustainedFor duration: TimeInterval,
        ignoredProcesses: Set<ProcessIdentity>,
        at instant: ContinuousClock.Instant
    ) -> Set<ProcessIdentity> {
        base.update(
            snapshots: snapshots,
            metric: { $0.residentBytes },
            threshold: thresholdBytes,
            releaseThreshold: UInt64(Double(thresholdBytes) * min(max(releaseFraction, 0), 1)),
            sustainedFor: duration,
            ignoredProcesses: ignoredProcesses,
            at: instant
        )
    }
}
