import Foundation

/// Recognises coding-agent CLIs from what a process was launched as.
///
/// Native installs show the agent's own name as argv[0] (`claude`, `omp`).
/// npm/pip installs run under an interpreter, so argv[0] is `node` or
/// `python3` and the agent is only visible in the script argument
/// (`node …/@google/gemini-cli/bundle/gemini.js`).
enum AgentCatalog {
    /// Executable (or script) base names that are coding agents.
    static let commandNames: Set<String> = [
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
    ]

    /// Package directories whose entry script names something generic
    /// (`cli.js`, `index.js`), mapped to the agent they belong to.
    private static let packageMarkers: [(marker: String, name: String)] = [
        ("/@anthropic-ai/claude-code/", "claude"),
        ("/@openai/codex/", "codex"),
        ("/@google/gemini-cli/", "gemini"),
        ("/@mariozechner/pi-coding-agent/", "pi"),
        ("/@qwen-code/qwen-code/", "qwen"),
        ("/opencode-ai/", "opencode"),
        ("/@sourcegraph/amp/", "amp"),
        ("/@github/copilot/", "copilot"),
        ("/cursor-agent/", "cursor-agent"),
    ]

    private static let interpreterNames: Set<String> = [
        "node", "bun", "deno", "tsx", "python", "python3",
    ]

    static func isInterpreter(_ command: String) -> Bool {
        let name = baseName(command)
        if interpreterNames.contains(name) { return true }
        // python3.12, python3.13, …
        return name.hasPrefix("python3.") && name.dropFirst("python3.".count).allSatisfy(\.isNumber)
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

    /// The agent's name, or nil when the process is not a known coding agent.
    static func agentName(command: String, launchScript: String?) -> String? {
        // Checked first: framework Python (Apple's and Homebrew's) runs as
        // `…/Python.app/Contents/MacOS/Python`, which is not an app process.
        if isInterpreter(command) {
            return launchScript.flatMap(interpretedAgentName)
        }
        // Anything else inside an app bundle belongs to that app: the desktop
        // app itself (`Claude.app/Contents/MacOS/Claude`) or a backend it
        // manages (`ChatGPT.app/Contents/Resources/codex`), not a CLI session.
        if command.lowercased().contains(".app/contents/") {
            return nil
        }
        let name = baseName(command)
        return commandNames.contains(name) ? name : nil
    }

    private static func interpretedAgentName(_ launchScript: String) -> String? {
        let lowercaseScript = launchScript.lowercased()
        for (marker, agent) in packageMarkers where lowercaseScript.contains(marker) {
            return agent
        }
        var scriptName = baseName(launchScript)
        for suffix in [".js", ".mjs", ".cjs", ".ts", ".py"] where scriptName.hasSuffix(suffix) {
            scriptName.removeLast(suffix.count)
            break
        }
        // `python3 -m aider.main` names a module path.
        if let module = scriptName.split(separator: ".").first {
            scriptName = String(module)
        }
        return commandNames.contains(scriptName) ? scriptName : nil
    }

    private static func baseName(_ path: String) -> String {
        let name = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
        return name.lowercased()
    }
}
