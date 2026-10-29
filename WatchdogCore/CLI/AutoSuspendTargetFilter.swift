import Foundation

/// Restricts auto-suspend targets to an explicit `--only` list and that
/// list's descendants. Session groups additionally require the session root
/// itself to be named; a descendant-only match must not stop an unnamed root
/// or anyone outside its tree.
enum AutoSuspendTargetFilter {
    static func matches(_ snapshot: ProcessSnapshot, selectors: [CLITarget]) -> Bool {
        selectors.contains { selector in
            switch selector {
            case let .pid(pid):
                return snapshot.id == pid
            case let .token(token):
                return snapshot.identity == token.identity
            }
        }
    }

    static func allowedPIDs(
        selectors: [CLITarget],
        processes: [ProcessSnapshot]
    ) -> Set<Int32> {
        guard !selectors.isEmpty else {
            return Set(processes.map(\.id))
        }
        let seeds = Set(processes.filter { matches($0, selectors: selectors) }.map(\.id))
        guard !seeds.isEmpty else { return [] }
        let byPID = Dictionary(
            processes.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var allowed = seeds
        for process in processes where !allowed.contains(process.id) {
            if MonitorEngine.reachesAncestor(from: process.parentPID, ancestorSet: seeds, byPID: byPID) {
                allowed.insert(process.id)
            }
        }
        return allowed
    }

    static func restrict(_ update: MonitorUpdate, to selectors: [CLITarget]) -> MonitorUpdate {
        guard !selectors.isEmpty else { return update }
        let allowed = allowedPIDs(selectors: selectors, processes: update.processes)
        let candidates = update.autoSuspendCandidates.filter { allowed.contains($0.id) }
        let groups = update.autoSuspendGroups.compactMap { group -> AutoSuspendGroup? in
            guard let root = update.processes.first(where: { $0.identity == group.root }),
                  matches(root, selectors: selectors)
            else { return nil }
            let members = group.members.filter { member in
                member.id != root.id
                    && allowed.contains(member.id)
                    && MonitorEngine.reachesAncestor(
                        from: member.parentPID,
                        ancestor: root.id,
                        byPID: Dictionary(
                            update.processes.map { ($0.id, $0) },
                            uniquingKeysWith: { first, _ in first }
                        )
                    )
            }
            return AutoSuspendGroup(root: group.root, members: members)
        }
        return MonitorUpdate(
            processes: update.processes,
            hot: update.hot,
            highMemory: update.highMemory,
            newlyHot: update.newlyHot,
            newlyHighMemory: update.newlyHighMemory,
            autoSuspendCandidates: candidates,
            sessions: update.sessions,
            hotSessions: update.hotSessions,
            highMemorySessions: update.highMemorySessions,
            newlyHotSessions: update.newlyHotSessions,
            autoSuspendGroups: groups
        )
    }
}

extension MonitorEngine {
    static func reachesAncestor(
        from startPID: Int32,
        ancestorSet: Set<Int32>,
        byPID: [Int32: ProcessSnapshot],
        limit: Int = 24
    ) -> Bool {
        var pid = startPID
        var hops = 0
        var seen: Set<Int32> = []
        while pid > 1, hops < limit, seen.insert(pid).inserted {
            if ancestorSet.contains(pid) { return true }
            guard let node = byPID[pid] else { return false }
            pid = node.parentPID
            hops += 1
        }
        return ancestorSet.contains(pid)
    }
}
