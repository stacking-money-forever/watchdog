import Foundation

enum SessionAggregator {
    /// Groups classified snapshots into one session per agent or service root.
    /// Members are non-root processes whose nearest `agentAncestor` is that root.
    static func sessions(from snapshots: [ProcessSnapshot]) -> [AgentSession] {
        var membersByRoot: [Int32: [ProcessSnapshot]] = [:]
        var roots: [ProcessSnapshot] = []
        roots.reserveCapacity(snapshots.count)

        for snapshot in snapshots {
            // A session host (herdr, tmux, brgr) is never a session of its own;
            // AgentLineage does not attribute anything to it either.
            if snapshot.kind == .agent || snapshot.kind == .service,
               snapshot.agentConfidence != .suspected,
               !OrphanClassifier.isSessionHost(snapshot) {
                roots.append(snapshot)
            } else if let ancestorPID = snapshot.agentAncestor?.pid {
                membersByRoot[ancestorPID, default: []].append(snapshot)
            }
        }

        var sessions: [AgentSession] = []
        sessions.reserveCapacity(roots.count)
        for root in roots {
            var members = membersByRoot[root.id] ?? []
            members.sort { $0.id < $1.id }
            let identities = members.map(\.identity)
            let cpu = finiteCPU(root.cpuPercent) + members.reduce(0) { $0 + finiteCPU($1.cpuPercent) }
            let memory = root.residentBytes &+ members.reduce(UInt64(0)) { $0 &+ $1.residentBytes }
            let basename = URL(fileURLWithPath: root.executablePath).lastPathComponent
            let name = root.agentName ?? (basename.isEmpty ? root.executablePath : basename)
            sessions.append(
                AgentSession(
                    id: root.identity,
                    rootPID: root.id,
                    name: name,
                    kind: root.kind,
                    workingDirectory: root.workingDirectory,
                    projectName: root.projectName,
                    members: identities,
                    memberCount: identities.count,
                    cpuPercent: cpu,
                    residentBytes: memory,
                    isSuspended: root.isSuspended,
                    elapsed: root.elapsed
                )
            )
        }

        sessions.sort {
            let left = $0.cpuPercent.isFinite ? $0.cpuPercent.rounded() : 0
            let right = $1.cpuPercent.isFinite ? $1.cpuPercent.rounded() : 0
            if left != right { return left > right }
            return $0.rootPID < $1.rootPID
        }
        return sessions
    }

    private static func finiteCPU(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }
}
