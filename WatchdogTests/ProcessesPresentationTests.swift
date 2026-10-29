import Darwin
import XCTest
@testable import Watchdog

final class ProcessesPresentationTests: XCTestCase {
    func testAgentFilterKeepsAgentsAndHidesMakeChild() {
        let claude = snapshot(pid: 71_001, path: "/usr/local/bin/claude", cpu: 184)
        let codex = snapshot(pid: 71_002, path: "/usr/local/bin/codex", cpu: 12)
        var make = snapshot(pid: 71_003, path: "/usr/bin/make", cpu: 8)
        make.agentAncestor = AgentAncestor(pid: 71_001, name: "claude", workingDirectory: "/tmp/watchdog-fixture")

        let visible = ProcessesPresentation.displayed(
            processes: [claude, codex, make],
            search: "",
            filter: .agents,
            sort: .cpu,
            attention: emptyAttention
        )

        XCTAssertEqual(visible.map(\.id), [71_001, 71_002])
    }

    func testSearchMatchesNamePidProjectScriptAndAncestor() {
        var scripted = snapshot(pid: 80_002, path: "/usr/local/bin/node", cpu: 4)
        scripted.launchScript = "/tmp/run-agent.mjs"
        var child = snapshot(pid: 80_003, path: "/usr/bin/make", cpu: 2)
        child.agentAncestor = AgentAncestor(pid: 80_001, name: "codex-ancestor", workingDirectory: "/tmp/shop")
        let named = snapshot(
            pid: 80_001,
            path: "/usr/local/bin/claude",
            cpu: 10,
            workingDirectory: "/tmp/watchdog-fixture"
        )

        XCTAssertEqual(
            ProcessesPresentation.displayed(
                processes: [named, scripted, child],
                search: "claude",
                filter: .all,
                sort: .pid,
                attention: emptyAttention
            ).map(\.id),
            [80_001]
        )
        XCTAssertEqual(
            ProcessesPresentation.displayed(
                processes: [named, scripted, child],
                search: "80002",
                filter: .all,
                sort: .pid,
                attention: emptyAttention
            ).map(\.id),
            [80_002]
        )
        XCTAssertEqual(
            ProcessesPresentation.displayed(
                processes: [named, scripted, child],
                search: "watchdog-fixture",
                filter: .all,
                sort: .pid,
                attention: emptyAttention
            ).map(\.id),
            [80_001]
        )
        XCTAssertEqual(
            ProcessesPresentation.displayed(
                processes: [named, scripted, child],
                search: "run-agent.mjs",
                filter: .all,
                sort: .pid,
                attention: emptyAttention
            ).map(\.id),
            [80_002]
        )
        XCTAssertEqual(
            ProcessesPresentation.displayed(
                processes: [named, scripted, child],
                search: "codex-ancestor",
                filter: .all,
                sort: .pid,
                attention: emptyAttention
            ).map(\.id),
            [80_003]
        )
    }

    func testKindFiltersIncludeAndExcludeExpectedProcesses() {
        let agent = snapshot(pid: 1, path: "/usr/local/bin/claude")
        let service = snapshot(pid: 2, path: "/opt/homebrew/bin/ollama", parent: 1, tty: "??")
        let app = snapshot(pid: 3, path: "/Applications/Safari.app/Contents/MacOS/Safari")
        let system = snapshot(pid: 4, path: "/usr/libexec/logd")
        var orphan = snapshot(pid: 5, path: "/usr/local/bin/leftover")
        orphan.orphanReason = .temporaryLaunchPath

        XCTAssertEqual(ids(.service, [agent, service, app, system, orphan]), [2])
        XCTAssertEqual(ids(.application, [agent, service, app, system, orphan]), [3])
        XCTAssertEqual(ids(.system, [agent, service, app, system, orphan]), [4])
        XCTAssertEqual(ids(.orphan, [agent, service, app, system, orphan]), [5])
    }

    func testAttentionFilterUsesHotMemoryStoppedAndIgnored() {
        let hot = snapshot(pid: 10, path: "/usr/local/bin/claude", cpu: 180)
        let memory = snapshot(pid: 11, path: "/usr/local/bin/codex", cpu: 4)
        let stopped = snapshot(pid: 12, path: "/usr/local/bin/gjc", cpu: 0, state: "T")
        let ignored = snapshot(pid: 13, path: "/usr/local/bin/claude", cpu: 200)
        let quiet = snapshot(pid: 14, path: "/usr/bin/make", cpu: 1)
        let attention = ProcessesPresentation.AttentionContext(
            hot: [hot.identity, ignored.identity],
            highMemory: [memory.identity],
            watchdogStopped: [stopped.identity],
            ignored: [ignored.identity]
        )

        let visible = ProcessesPresentation.displayed(
            processes: [hot, memory, stopped, ignored, quiet],
            search: "",
            filter: .attention,
            sort: .pid,
            attention: attention
        )
        XCTAssertEqual(visible.map(\.id), [10, 11, 12])
    }

    func testCPUSortIsStableForEqualValues() {
        let first = snapshot(pid: 21, path: "/usr/local/bin/a", cpu: 50)
        let second = snapshot(pid: 22, path: "/usr/local/bin/b", cpu: 50)
        let hottest = snapshot(pid: 23, path: "/usr/local/bin/c", cpu: 90)

        let visible = ProcessesPresentation.sorted([first, second, hottest], by: .cpu)
        XCTAssertEqual(visible.map(\.id), [23, 21, 22])
    }

    func testMemoryNameAndPIDSort() {
        let low = snapshot(pid: 32, path: "/usr/local/bin/zeta", cpu: 1, memory: 10)
        let high = snapshot(pid: 31, path: "/usr/local/bin/alpha", cpu: 1, memory: 99)

        XCTAssertEqual(ProcessesPresentation.sorted([low, high], by: .memory).map(\.id), [31, 32])
        XCTAssertEqual(ProcessesPresentation.sorted([low, high], by: .name).map(\.id), [31, 32])
        XCTAssertEqual(ProcessesPresentation.sorted([low, high], by: .pid).map(\.id), [31, 32])
    }

    func testEmptyCopyForSearchAndFilters() {
        XCTAssertEqual(
            ProcessesPresentation.emptyTitle(search: "fixture-with-no-matching-process", filter: .all),
            "검색 결과가 없습니다"
        )
        XCTAssertEqual(
            ProcessesPresentation.emptyMessage(search: "x", filter: .all),
            "다른 프로세스 이름, PID 또는 프로젝트를 검색해보세요."
        )
        XCTAssertEqual(ProcessesPresentation.emptyTitle(search: "", filter: .attention), "확인할 프로세스가 없습니다")
        XCTAssertEqual(ProcessesPresentation.emptyTitle(search: "", filter: .agents), "에이전트 프로세스가 없습니다")
        XCTAssertEqual(ProcessesPresentation.emptyTitle(search: "", filter: .all), "일치하는 프로세스가 없습니다")
    }

    func testFilterAndSort1200SnapshotsCompletesWithin50ms() {
        let processes: [ProcessSnapshot] = (0..<1_200).map { index in
            snapshot(
                pid: Int32(40_000 + index),
                path: index.isMultiple(of: 17) ? "/usr/local/bin/claude" : "/usr/local/bin/worker-\(index)",
                cpu: Double(index % 200),
                memory: UInt64(index)
            )
        }
        let attention = ProcessesPresentation.AttentionContext(
            hot: Set(processes.prefix(40).map(\.identity)),
            highMemory: [],
            watchdogStopped: [],
            ignored: []
        )

        let started = ContinuousClock.now
        let visible = ProcessesPresentation.displayed(
            processes: processes,
            search: "",
            filter: .all,
            sort: .cpu,
            attention: attention
        )
        let elapsed = started.duration(to: .now)
        XCTAssertEqual(visible.count, 1_200)
        XCTAssertLessThan(
            elapsed,
            Duration.milliseconds(50),
            "filter/sort of 1,200 snapshots took \(elapsed)"
        )
    }

    private var emptyAttention: ProcessesPresentation.AttentionContext {
        ProcessesPresentation.AttentionContext(hot: [], highMemory: [], watchdogStopped: [], ignored: [])
    }

    private func ids(_ filter: ProcessListFilter, _ processes: [ProcessSnapshot]) -> [Int32] {
        ProcessesPresentation.displayed(
            processes: processes,
            search: "",
            filter: filter,
            sort: .pid,
            attention: emptyAttention
        ).map(\.id)
    }

    private func snapshot(
        pid: Int32,
        path: String,
        cpu: Double = 0,
        memory: UInt64 = 0,
        parent: Int32 = 2,
        tty: String = "ttys001",
        state: String = "R",
        workingDirectory: String? = nil
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            id: pid,
            parentPID: parent,
            processGroupID: pid,
            userID: getuid(),
            tty: tty,
            cpuPercent: cpu,
            residentBytes: memory,
            state: state,
            elapsed: "00:10",
            executablePath: path,
            startTimeMicroseconds: UInt64(pid) * 1_000,
            workingDirectory: workingDirectory
        )
    }
}
