import Foundation

enum OrphanClassifier {
    static func classify(_ snapshots: [ProcessSnapshot]) -> [ProcessSnapshot] {
        // ps output crosses a process boundary; tolerate malformed duplicate
        // PIDs instead of crashing the menu bar app.
        let rawByPID = Dictionary(
            snapshots.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let annotated = snapshots.map { annotateConfidence($0, byPID: rawByPID) }
        let byPID = Dictionary(
            annotated.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var lineage = AgentLineage(byPID: byPID)
        return annotated.map { snapshot in
            var updated = snapshot
            // System daemons and apps routinely keep a cwd under /var/folders;
            // only a session-like process left behind in a temp dir is a leftover.
            if snapshot.parentPID <= 1,
               [.agent, .service, .other].contains(snapshot.kind),
               LaunchPath.isTemporaryLaunch(of: snapshot) {
                updated.orphanReason = .temporaryLaunchPath
            } else if snapshot.kind == .agent {
                updated.orphanReason = orphanReason(snapshot, in: byPID)
            }
            if snapshot.kind != .agent {
                updated.agentAncestor = lineage.ancestor(of: snapshot)
            }
            return updated
        }
    }

    /// Finds the nearest agent or service above a non-agent process, so a
    /// runaway build, test run, or MCP server is attributed to the session
    /// that started it. Siblings share ancestors, so each answer is computed once.
    private struct AgentLineage {
        let byPID: [Int32: ProcessSnapshot]
        private var roots: [Int32: String] = [:]
        private var memo: [Int32: AgentAncestor?] = [:]

        init(byPID: [Int32: ProcessSnapshot]) {
            self.byPID = byPID
            // A terminal multiplexer or agent host (herdr, tmux, brgr) is a
            // service too, but the shells it spawns are not its session.
            for (pid, snapshot) in byPID
            where (snapshot.kind == .agent || snapshot.kind == .service)
                && snapshot.agentConfidence != .suspected
                && !isSessionHost(snapshot) {
                roots[pid] = snapshot.agentName
                    ?? URL(fileURLWithPath: snapshot.executablePath).lastPathComponent
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
                if let name = roots[currentPID] {
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

            // A sub-agent started by a live agent/service (or by a host that
            // runs agents headless) belongs to that session.
            if isSessionHost(ancestor) || ancestor.kind == .agent || ancestor.kind == .service {
                return nil
            }

            currentPID = ancestor.parentPID
            depth += 1
        }

        return snapshot.tty == "??" ? .detachedSession : nil
    }

    static func isSessionHost(_ snapshot: ProcessSnapshot) -> Bool {
        AgentCatalog.isSessionHost(snapshot)
    }

    private static func annotateConfidence(
        _ snapshot: ProcessSnapshot,
        byPID: [Int32: ProcessSnapshot]
    ) -> ProcessSnapshot {
        var updated = snapshot
        if AgentCatalog.agentName(command: snapshot.executablePath, launchScript: snapshot.launchScript) != nil {
            updated.agentConfidence = .known
            return updated
        }
        if let name = suspectedAgentName(snapshot, byPID: byPID) {
            updated.classifiedAgentName = name
            updated.agentConfidence = .suspected
            updated.classifiedKind = .agent
        }
        return updated
    }

    private static func suspectedAgentName(
        _ snapshot: ProcessSnapshot,
        byPID: [Int32: ProcessSnapshot]
    ) -> String? {
        guard AgentCatalog.isInterpreter(snapshot.executablePath) else { return nil }
        guard snapshot.tty != "??" else { return nil }
        guard let script = snapshot.launchScript, isSuspectedInstallPath(script) else { return nil }
        let name = AgentCatalog.scriptBaseName(script)
        guard !name.isEmpty, !AgentCatalog.active.isIgnored(name) else { return nil }
        guard let parent = byPID[snapshot.parentPID] else { return nil }
        if isSessionHost(parent) { return name }
        guard isShell(parent), let grandparent = byPID[parent.parentPID], isSessionHost(grandparent) else {
            return nil
        }
        return name
    }

    private static func isShell(_ snapshot: ProcessSnapshot) -> Bool {
        let path = snapshot.executablePath.lowercased()
        let name = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
        return name == "zsh" || name == "bash" || name == "sh" || name == "fish"
            || path.hasSuffix("/bin/zsh") || path.hasSuffix("/bin/bash") || path.hasSuffix("/bin/sh")
    }

    /// Interpreter scripts installed under typical agent-CLI locations.
    static func isSuspectedInstallPath(_ path: String) -> Bool {
        let lowered = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        if lowered.contains("node_modules/.bin/") { return true }

        let home = NSHomeDirectory().replacingOccurrences(of: "\\", with: "/").lowercased()
        let expanded: String
        if lowered == "~" {
            expanded = home
        } else if lowered.hasPrefix("~/") {
            expanded = home + String(lowered.dropFirst(1))
        } else {
            expanded = lowered
        }

        if expanded.contains("/.npm/_npx/")
            || expanded.contains("/.local/share/")
            || expanded.contains("/.cache/") {
            return true
        }

        func matchesHiddenBin(_ absolute: String) -> Bool {
            let prefix = home.hasSuffix("/") ? home : home + "/"
            guard absolute.hasPrefix(prefix) else { return false }
            let rest = absolute.dropFirst(prefix.count)
            guard rest.hasPrefix(".") else { return false }
            let parts = rest.split(separator: "/", omittingEmptySubsequences: true)
            return parts.count >= 2 && parts[1] == "bin"
        }
        if matchesHiddenBin(expanded) { return true }
        if lowered.hasPrefix("~/.") {
            let parts = lowered.dropFirst(2).split(separator: "/", omittingEmptySubsequences: true)
            return parts.count >= 2 && parts[1] == "bin"
        }
        return false
    }
}
