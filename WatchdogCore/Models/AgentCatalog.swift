import Foundation
import os

/// Recognises coding-agent CLIs from what a process was launched as.
///
/// Native installs show the agent's own name as argv[0] (`claude`, `omp`).
/// npm/pip installs run under an interpreter, so argv[0] is `node` or
/// `python3` and the agent is only visible in the script argument
/// (`node …/@google/gemini-cli/bundle/gemini.js`).
struct AgentCatalog: Sendable {
    /// Executable (or script) base names that are coding agents.
    let commandNames: Set<String>
    /// Package directories whose entry script names something generic
    /// (`cli.js`, `index.js`), mapped to the agent they belong to.
    let packageMarkers: [(marker: String, name: String)]
    /// Subcommands that mean the process is a resident server, not a session.
    let serviceSubcommands: Set<String>
    let sessionHostMarkers: [String]
    let ignoreNames: Set<String>
    private let interpreterNames: Set<String>

    static let builtIn = AgentCatalog(
        commandNames: [
            "aider",
            "amp",
            "claude",
            "codex",
            "copilot",
            "crush",
            "cursor-agent",
            "droid",
            "gemini",
            "gjc",
            "goose",
            "kimi",
            "omp",
            "opencode",
            "pi",
            "qwen",
        ],
        packageMarkers: [
            ("/@anthropic-ai/claude-code/", "claude"),
            ("/@openai/codex/", "codex"),
            ("/@google/gemini-cli/", "gemini"),
            ("/@mariozechner/pi-coding-agent/", "pi"),
            ("/@qwen-code/qwen-code/", "qwen"),
            ("/opencode-ai/", "opencode"),
            ("/@sourcegraph/amp/", "amp"),
            ("/@github/copilot/", "copilot"),
            ("/cursor-agent/", "cursor-agent"),
        ],
        serviceSubcommands: [
            "serve", "server", "app-server", "daemon", "worker-server",
        ],
        sessionHostMarkers: [
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
        ],
        ignoreNames: [],
        interpreterNames: [
            "node", "bun", "deno", "tsx", "python", "python3",
        ]
    )

    private static let lock = OSAllocatedUnfairLock(initialState: AgentCatalog.builtIn)

    static var active: AgentCatalog {
        lock.withLock { $0 }
    }

    static var commandNames: Set<String> { active.commandNames }
    static var serviceSubcommands: Set<String> { active.serviceSubcommands }

    static func activate(rules: AgentRules) {
        lock.withLock { $0 = AgentCatalog(builtIn: .builtIn, merging: rules) }
    }

    static func resetToBuiltIn() {
        lock.withLock { $0 = .builtIn }
    }

    init(builtIn: AgentCatalog, merging rules: AgentRules) {
        var names = builtIn.commandNames
        for name in rules.agentNames where !name.isEmpty {
            names.insert(Self.baseName(name))
        }
        let ignored = Set(rules.ignoreNames.filter { !$0.isEmpty }.map(Self.baseName))
        names.subtract(ignored)
        commandNames = names
        ignoreNames = ignored
        interpreterNames = builtIn.interpreterNames
        var markers = builtIn.packageMarkers
        for marker in rules.packageMarkers where !marker.marker.isEmpty && !marker.agent.isEmpty {
            markers.append((marker.marker.lowercased(), Self.baseName(marker.agent)))
        }
        packageMarkers = markers.filter { !ignored.contains($0.name) }
        var subcommands = builtIn.serviceSubcommands
        for value in rules.serviceSubcommands where !value.isEmpty {
            subcommands.insert(value.lowercased())
        }
        serviceSubcommands = subcommands
        sessionHostMarkers = builtIn.sessionHostMarkers + rules.sessionHosts
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
    }

    private init(
        commandNames: Set<String>,
        packageMarkers: [(marker: String, name: String)],
        serviceSubcommands: Set<String>,
        sessionHostMarkers: [String],
        ignoreNames: Set<String>,
        interpreterNames: Set<String>
    ) {
        self.commandNames = commandNames
        self.packageMarkers = packageMarkers
        self.serviceSubcommands = serviceSubcommands
        self.sessionHostMarkers = sessionHostMarkers
        self.ignoreNames = ignoreNames
        self.interpreterNames = interpreterNames
    }

    func isInterpreter(_ command: String) -> Bool {
        let name = Self.baseName(command)
        if interpreterNames.contains(name) { return true }
        return name.hasPrefix("python3.") && name.dropFirst("python3.".count).allSatisfy(\.isNumber)
    }

    func isSessionHost(_ snapshot: ProcessSnapshot) -> Bool {
        let value = snapshot.executablePath.lowercased()
        return sessionHostMarkers.contains { value.contains($0) }
    }

    func isIgnored(_ name: String) -> Bool {
        ignoreNames.contains(Self.baseName(name))
    }

    /// The agent's name, or nil when the process is not a known coding agent.
    func agentName(command: String, launchScript: String?) -> String? {
        if isInterpreter(command) {
            return launchScript.flatMap(interpretedAgentName)
        }
        if command.lowercased().contains(".app/contents/") {
            return nil
        }
        let name = Self.baseName(command)
        if ignoreNames.contains(name) { return nil }
        return commandNames.contains(name) ? name : nil
    }

    private func interpretedAgentName(_ launchScript: String) -> String? {
        let lowercaseScript = launchScript.lowercased()
        for (marker, agent) in packageMarkers where lowercaseScript.contains(marker) {
            if ignoreNames.contains(agent) { continue }
            return agent
        }
        let scriptName = Self.scriptBaseName(launchScript)
        if ignoreNames.contains(scriptName) { return nil }
        return commandNames.contains(scriptName) ? scriptName : nil
    }

    static func isInterpreter(_ command: String) -> Bool {
        active.isInterpreter(command)
    }

    static func isSessionHost(_ snapshot: ProcessSnapshot) -> Bool {
        active.isSessionHost(snapshot)
    }

    static func agentName(command: String, launchScript: String?) -> String? {
        active.agentName(command: command, launchScript: launchScript)
    }

    /// The script or module an interpreter runs: the first argument that is
    /// not an option (`node --use-system-ca /x/index.js` → `/x/index.js`),
    /// or the module after `-m` (`python3 -m aider` → `aider`).
    static func launchScript(arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-m", index + 1 < arguments.count {
                return arguments[index + 1]
            }
            if argument == "run" || argument.hasPrefix("-") {
                index += 1
                continue
            }
            return argument
        }
        return nil
    }

    /// The first positional after argv[0], or after the interpreter script.
    /// Flags do not count: `claude --resume x` has no subcommand. `-m module`
    /// (as in `python3 -m http.server`) is not a subcommand either.
    static func launchSubcommand(arguments: [String]) -> String? {
        guard let command = arguments.first else { return nil }
        let rest = Array(arguments.dropFirst())
        if isInterpreter(command) {
            var index = 0
            while index < rest.count {
                let argument = rest[index]
                if argument == "-m" { return nil }
                if argument == "run" || argument.hasPrefix("-") {
                    index += 1
                    continue
                }
                guard index + 1 < rest.count else { return nil }
                let next = rest[index + 1]
                return next.hasPrefix("-") ? nil : next
            }
            return nil
        }
        guard let next = rest.first else { return nil }
        return next.hasPrefix("-") ? nil : next
    }

    static func scriptBaseName(_ launchScript: String) -> String {
        var scriptName = baseName(launchScript)
        for suffix in [".js", ".mjs", ".cjs", ".ts", ".py"] where scriptName.hasSuffix(suffix) {
            scriptName.removeLast(suffix.count)
            break
        }
        if let module = scriptName.split(separator: ".").first {
            scriptName = String(module)
        }
        return scriptName
    }

    static func baseName(_ path: String) -> String {
        let name = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
        return name.lowercased()
    }
}
