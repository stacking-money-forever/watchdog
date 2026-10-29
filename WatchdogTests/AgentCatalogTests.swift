import Darwin
import XCTest
@testable import Watchdog

final class AgentCatalogTests: XCTestCase {
    func testNativeAgentsAreRecognisedByCommandName() {
        for command in ["claude", "/Users/test/.local/bin/omp", "/Users/test/.amp/bin/amp", "/opt/homebrew/Caskroom/copilot-cli/1.0/copilot", "opencode", "cursor-agent"] {
            XCTAssertNotNil(AgentCatalog.agentName(command: command, launchScript: nil), command)
        }
        XCTAssertNil(AgentCatalog.agentName(command: "/Users/test/.local/bin/brgr", launchScript: nil))
        XCTAssertNil(AgentCatalog.agentName(command: "node", launchScript: nil))
    }

    func testDesktopAppMainExecutableIsNotTheCLIAgent() {
        XCTAssertNil(AgentCatalog.agentName(command: "/Applications/Claude.app/Contents/MacOS/Claude", launchScript: nil))
        XCTAssertNil(AgentCatalog.agentName(command: "/Applications/ChatGPT.app/Contents/Resources/codex", launchScript: nil))
    }

    func testInterpreterAgentsAreRecognisedByPackage() {
        let cases: [(String, String, String)] = [
            ("node", "/n/lib/node_modules/@google/gemini-cli/bundle/gemini.js", "gemini"),
            ("node", "/n/lib/node_modules/@mariozechner/pi-coding-agent/dist/cli.js", "pi"),
            ("node", "/n/lib/node_modules/@openai/codex/bin/codex.js", "codex"),
            ("node", "/n/lib/node_modules/@anthropic-ai/claude-code/cli.js", "claude"),
            ("/opt/homebrew/bin/bun", "/x/bin/omp.ts", "omp"),
            ("python3.12", "/u/.local/bin/aider", "aider"),
            ("python3", "aider.main", "aider"),
            ("/opt/homebrew/Cellar/python@3.14/3.14.0/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python", "/u/.local/bin/aider", "aider"),
        ]
        for (command, script, expected) in cases {
            XCTAssertEqual(AgentCatalog.agentName(command: command, launchScript: script), expected, script)
        }
        XCTAssertNil(AgentCatalog.agentName(command: "node", launchScript: "/x/node_modules/vitest/vitest.mjs"))
        XCTAssertNil(AgentCatalog.agentName(command: "/bin/zsh", launchScript: "/x/gemini.js"))
    }

    func testLaunchScriptSkipsOptions() {
        XCTAssertEqual(AgentCatalog.launchScript(arguments: ["--use-system-ca", "/x/index.js", "--yolo"]), "/x/index.js")
        XCTAssertEqual(AgentCatalog.launchScript(arguments: ["-m", "aider", "--model"]), "aider")
        XCTAssertEqual(AgentCatalog.launchScript(arguments: ["run", "/x/omp.ts"]), "/x/omp.ts")
        XCTAssertNil(AgentCatalog.launchScript(arguments: ["--version"]))
        XCTAssertTrue(AgentCatalog.isInterpreter("/usr/bin/python3.13"))
        XCTAssertFalse(AgentCatalog.isInterpreter("python3.x"))
    }

    func testProcArgumentsParseNameAndInterpreterScript() throws {
        let node = try XCTUnwrap(parse(argv: ["node", "--use-system-ca", "/n/@google/gemini-cli/bundle/gemini.js", "-p", "hi"]))
        XCTAssertEqual(node, LaunchCommand(name: "node", script: "/n/@google/gemini-cli/bundle/gemini.js", subcommand: nil))

        let native = try XCTUnwrap(parse(argv: ["claude", "--resume", "abc"]))
        XCTAssertEqual(native, LaunchCommand(name: "claude", script: nil, subcommand: nil))

        XCTAssertNil(parse(argv: []))
    }

    func testSnapshotClassifiesInterpreterAgentAndNamesIt() {
        var snapshot = Self.snapshot("node")
        snapshot.launchScript = "/n/@google/gemini-cli/bundle/gemini.js"
        XCTAssertEqual(snapshot.kind, .agent)
        XCTAssertEqual(snapshot.displayName, "gemini")
        XCTAssertEqual(Self.snapshot("node").kind, .other)
    }

    func testElectronRenderersAreRenderers() {
        let aside = Self.snapshot("/Applications/Aside.app/Contents/Frameworks/Aside Framework.framework/Helpers/Aside Helper (Renderer).app/Contents/MacOS/Aside Helper (Renderer)")
        XCTAssertEqual(aside.kind, .browserRenderer)
        XCTAssertEqual(aside.displayName, "Aside 렌더러")
        let chrome = Self.snapshot("/Applications/Google Chrome.app/Contents/Frameworks/x/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)")
        XCTAssertEqual(chrome.displayName, "Chrome 렌더러")
    }

    func testProjectFallsBackToAgentWorkingDirectory() {
        var child = Self.snapshot("node")
        child.agentAncestor = AgentAncestor(pid: 9, name: "claude", workingDirectory: "/Users/test/dev/shop")
        XCTAssertEqual(child.projectName, "shop")
        child.workingDirectory = "/Users/test/dev/shop/web"
        XCTAssertEqual(child.projectName, "web")
    }

    func testLaunchSubcommandSkipsFlagsAndInterpreterModule() {
        XCTAssertEqual(AgentCatalog.launchSubcommand(arguments: ["codex", "app-server", "daemon"]), "app-server")
        XCTAssertEqual(
            AgentCatalog.launchSubcommand(arguments: ["node", "/n/index.js", "worker-server"]),
            "worker-server"
        )
        XCTAssertEqual(AgentCatalog.launchSubcommand(arguments: ["opencode", "serve", "--service"]), "serve")
        XCTAssertNil(AgentCatalog.launchSubcommand(arguments: ["python3", "-m", "http.server"]))
        XCTAssertNil(AgentCatalog.launchSubcommand(arguments: ["claude", "--resume", "x"]))
    }

    func testSleepingProcessIsReportedAsSleeping() {
        XCTAssertEqual(LibprocProcessLister.stateLetter(UInt32(SRUN), runningThreads: 0), "S")
        XCTAssertEqual(LibprocProcessLister.stateLetter(UInt32(SRUN), runningThreads: 2), "R")
        XCTAssertEqual(LibprocProcessLister.stateLetter(UInt32(SRUN), runningThreads: nil), "R")
        XCTAssertEqual(LibprocProcessLister.stateLetter(UInt32(SSTOP), runningThreads: 0), "T")
    }

    func testEngineGivesDescendantsTheAgentsCarriedDirectory() {
        var engine = MonitorEngine()
        let agent = Self.snapshot("claude", pid: 10, parent: 1)
        let child = Self.snapshot("node", pid: 11, parent: 10)
        engine.recordWorkingDirectory("/Users/test/dev/shop", for: agent.identity)

        let update = engine.ingest([agent, child], settings: MonitorSettings(), at: ContinuousClock().now)

        XCTAssertEqual(update.processes.first { $0.id == 11 }?.projectName, "shop")
    }

    private func parse(argv: [String]) -> LaunchCommand? {
        var bytes = withUnsafeBytes(of: Int32(argv.count)) { Array($0) }
        bytes += Array("/exec/path".utf8) + [0, 0, 0]
        for argument in argv { bytes += Array(argument.utf8) + [0] }
        return bytes.withUnsafeBytes { ArgumentReader.parse($0) }
    }

    private static func snapshot(_ command: String, pid: Int32 = 50, parent: Int32 = 10) -> ProcessSnapshot {
        ProcessSnapshot(
            id: pid,
            parentPID: parent,
            processGroupID: pid,
            userID: getuid(),
            tty: "??",
            cpuPercent: 0,
            residentBytes: 0,
            state: "S",
            elapsed: "00:01",
            executablePath: command,
            startTimeMicroseconds: UInt64(pid) * 1_000_000
        )
    }
}
