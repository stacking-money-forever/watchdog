import Foundation
import XCTest
@testable import Watchdog

final class WorktreeStateResolverTests: XCTestCase {
    func testParseStatusCleanWorktree() {
        let output = """
        # branch.oid 1234abcd
        # branch.head feature/alert-policy
        # branch.upstream origin/feature/alert-policy
        # branch.ab +0 -0
        """

        let state = WorktreeStateResolver.parseStatus(output: output, path: "/tmp/wt")

        XCTAssertEqual(state.verdict, .clean)
        XCTAssertEqual(state.detail, "feature/alert-policy")
    }

    func testParseStatusDirtyWorktreeCountsEntries() {
        let output = """
        # branch.head main
        1 .M N... 100644 100644 100644 abc def Watchdog/App.swift
        ? untracked-file.txt
        """

        let state = WorktreeStateResolver.parseStatus(output: output, path: "/tmp/wt")

        XCTAssertEqual(state.verdict, .dirty)
        XCTAssertEqual(state.detail, "main · 변경 2개")
    }

    func testParseStatusUnpushedCommitsMarkDirty() {
        let output = """
        # branch.head main
        # branch.ab +3 -0
        """

        let state = WorktreeStateResolver.parseStatus(output: output, path: "/tmp/wt")

        XCTAssertEqual(state.verdict, .dirty)
        XCTAssertEqual(state.detail, "main · 미푸시 3커밋")
    }

    func testParseStatusDetachedHeadOmitsBranchFromDetail() {
        let output = """
        # branch.head (detached)
        """

        let state = WorktreeStateResolver.parseStatus(output: output, path: "/tmp/wt")

        XCTAssertEqual(state.verdict, .clean)
        XCTAssertNil(state.detail)
    }

    func testLookupFailingCommandReportsUnavailable() async {
        let resolver = WorktreeStateResolver(
            runner: { _, _, _ in
                throw CommandRunnerError.failed(
                    executable: "/usr/bin/git",
                    status: 128,
                    message: "not a git repository"
                )
            }
        )
        let collector = StateCollector()

        await resolver.resolve(["/tmp"]) { path, state in
            collector.record(path: path, state: state)
        }
        await resolver.drainForTesting()

        let states = collector.states
        XCTAssertEqual(states.first?.value.verdict, .unavailable)
    }

    func testLookupNonexistentPathReportsMissing() async {
        let resolver = WorktreeStateResolver(
            runner: { _, _, _ in "# branch.head main\n" }
        )
        let collector = StateCollector()
        let path = "/tmp/watchdog-a08-nonexistent-\(UUID().uuidString)"

        await resolver.resolve([path]) { path, state in
            collector.record(path: path, state: state)
        }
        await resolver.drainForTesting()

        XCTAssertEqual(collector.states[path]?.verdict, .missing)
    }

    func testResolveDeduplicatesPathsAndCachesWithinTTL() async {
        let counter = InvocationCounter()
        let resolver = WorktreeStateResolver(
            runner: { _, _, _ in
                await counter.increment()
                return "# branch.head main\n"
            }
        )
        let collector = StateCollector()

        await resolver.resolve(["/tmp", "/tmp", "/var"]) { path, state in
            collector.record(path: path, state: state)
        }
        await resolver.drainForTesting()

        let firstRound = counter.count
        XCTAssertEqual(firstRound, 2, "duplicate path must collapse to one lookup")

        // Cached result: no new git invocation.
        await resolver.resolve(["/tmp"]) { _, _ in }
        await resolver.drainForTesting()

        let cachedRound = counter.count
        XCTAssertEqual(cachedRound, 2, "cached path must not re-invoke git")

        let states = collector.states
        XCTAssertEqual(states["/tmp"]?.verdict, .clean)
    }

    func testResolveDeliversParsedStatusFromRunner() async {
        let resolver = WorktreeStateResolver(
            runner: { _, _, _ in
                "# branch.head feature/alert-policy\n# branch.ab +0 -0\n"
            }
        )
        let collector = StateCollector()

        await resolver.resolve(["/tmp"]) { path, state in
            collector.record(path: path, state: state)
        }
        await resolver.drainForTesting()

        let states = collector.states
        XCTAssertEqual(states["/tmp"]?.verdict, .clean)
        XCTAssertEqual(states["/tmp"]?.detail, "feature/alert-policy")
    }

    func testResolveQueuesPathsBeyondConcurrencyLimit() async {
        let counter = InvocationCounter()
        let resolver = WorktreeStateResolver(
            policy: .init(
                maximumConcurrentLookups: 2,
                lookupDeadline: .seconds(1),
                cacheCapacity: 8,
                positiveTTL: .seconds(1),
                negativeTTL: .seconds(1)
            ),
            runner: { _, _, _ in
                await counter.increment()
                try? await Task.sleep(for: .milliseconds(10))
                return "# branch.head main\n"
            }
        )
        let collector = StateCollector()

        await resolver.resolve(["/tmp", "/var", "/usr"]) { path, state in
            collector.record(path: path, state: state)
        }
        await resolver.drainForTesting()

        XCTAssertEqual(counter.count, 3)
        XCTAssertEqual(Set(collector.states.keys), Set(["/tmp", "/var", "/usr"]))
    }
}


private final class StateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: WorktreeState] = [:]

    var states: [String: WorktreeState] {
        lock.withLock { storage }
    }

    func record(path: String, state: WorktreeState?) {
        lock.withLock {
            if let state {
                storage[path] = state
            }
        }
    }
}

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func increment() {
        lock.withLock { value += 1 }
    }
}
