import Foundation

enum OrphanClassifier {
    static func classify(_ snapshots: [ProcessSnapshot]) -> [ProcessSnapshot] {
        // ps output crosses a process boundary; tolerate malformed duplicate
        // PIDs instead of crashing the menu bar app.
        let byPID = Dictionary(
            snapshots.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var lineage = AgentLineage(byPID: byPID)
        return snapshots.map { snapshot in
            var updated = snapshot
            if snapshot.kind == .agent {
                updated.orphanReason = orphanReason(snapshot, in: byPID)
            } else {
                updated.agentAncestor = lineage.ancestor(of: snapshot)
            }
            return updated
        }
    }

    /// Finds the nearest agent above a non-agent process, so a runaway build
    /// or test run is attributed to the agent (and project) that started it.
    /// Siblings share ancestors, so each process's answer is computed once.
    private struct AgentLineage {
        let byPID: [Int32: ProcessSnapshot]
        private var agents: [Int32: String] = [:]
        private var memo: [Int32: AgentAncestor?] = [:]

        init(byPID: [Int32: ProcessSnapshot]) {
            self.byPID = byPID
            for (pid, snapshot) in byPID where snapshot.kind == .agent {
                agents[pid] = snapshot.agentName
            }
        }

        mutating func ancestor(of snapshot: ProcessSnapshot) -> AgentAncestor? {
            var chain: [Int32] = []
            var currentPID = snapshot.parentPID
            var result: AgentAncestor?
            while true {
                if let known = memo[currentPID] {
                    result = known
                    break
                }
                guard currentPID > 1, chain.count < 24, !chain.contains(currentPID),
                      currentPID != snapshot.id,
                      let ancestor = byPID[currentPID]
                else { break }
                if let name = agents[currentPID] {
                    result = AgentAncestor(pid: currentPID, name: name, workingDirectory: ancestor.workingDirectory)
                    break
                }
                chain.append(currentPID)
                // An agent's tree ends at its session host; anything above it
                // is the terminal or app, not an agent.
                if isSessionHost(ancestor) { break }
                currentPID = ancestor.parentPID
            }
            // Every process walked through has the same nearest agent above it.
            for pid in chain { memo[pid] = .some(result) }
            return result
        }
    }

    private static func orphanReason(
        _ snapshot: ProcessSnapshot,
        in byPID: [Int32: ProcessSnapshot]
    ) -> OrphanReason? {
        if snapshot.parentPID <= 1 {
            return .reparentedToLaunchd
        }

        var currentPID = snapshot.parentPID
        var visited: Set<Int32> = [snapshot.id]
        var depth = 0

        while currentPID > 1, depth < 24 {
            guard !visited.contains(currentPID) else { return .cyclicLineage }
            visited.insert(currentPID)

            guard let ancestor = byPID[currentPID] else {
                return .missingParent
            }

            // A sub-agent started by a live agent (or by a host that runs
            // agents headless) belongs to that session.
            if isSessionHost(ancestor) || ancestor.kind == .agent {
                return nil
            }

            currentPID = ancestor.parentPID
            depth += 1
        }

        return snapshot.tty == "??" ? .detachedSession : nil
    }

    private static func isSessionHost(_ snapshot: ProcessSnapshot) -> Bool {
        let value = snapshot.executablePath.lowercased()
        return [
            "orca helper",
            "terminal.app",
            "iterm",
            "wezterm",
            "alacritty",
            "kitty.app",
            "/tmux",
            "/zellij",
            "muxy",
            "visual studio code",
            "vscode",
            "code helper",
            "electron",
            "herdr",
            "ghostty",
            "warp",
            "cmux",
            "superset",
            "zed.app",
            "cursor.app",
            "codex.app",
            "claude.app",
            "conductor.app",
            "jetbrains",
            "intellij",
            "webstorm",
            "pycharm",
            "goland",
            "phpstorm",
            "android studio",
            "/screen",
            "/brgr",
        ].contains { value.contains($0) }
    }
}
