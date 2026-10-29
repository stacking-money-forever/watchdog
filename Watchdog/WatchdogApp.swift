import AppKit
import Darwin
import SwiftUI

#if DEBUG
/// Synthetic launch arguments for shipping-target UI tests. Fixture instances
/// bypass the single-instance lock so tests can run next to the installed
/// Watchdog.
enum WatchdogUITestFixture {
    static let actionable = "--ui-test-fixture"
    static let live = "--ui-test-live"
    static let stale = "--ui-test-stale-fixture"
    static let outcome = "--ui-test-outcome-fixture"
    static let exited = "--ui-test-exited-fixture"
    static let stillRunning = "--ui-test-still-running-fixture"
    /// Live refresh loop over a scripted sampler that swaps the CPU ranking of
    /// two rows every sample, for verifying that rows hold still while shown.
    static let reorder = "--ui-test-reorder-fixture"
    /// Same fixture data as `actionable`, but opens the main window instead of
    /// the popover hosting window (status-item clicks are unstable in XCUITest).
    static let window = "--ui-test-window-fixture"

    static func isActive(in arguments: [String]) -> Bool {
        [actionable, live, stale, outcome, exited, stillRunning, reorder, window]
            .contains { arguments.contains($0) }
    }
}
#endif

#if DEBUG
@MainActor
private enum WatchdogUITestFixtureHost {
    static var monitor: ProcessMonitor?
    static var launchAtLogin: LaunchAtLoginController?
    static var window: NSWindow?

    static func showWindowIfNeeded() {
        guard window == nil, let monitor, let launchAtLogin else { return }
        let hosting = NSHostingView(
            rootView: WatchdogMenuView(monitor: monitor, launchAtLogin: launchAtLogin)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 590),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Watchdog UI 테스트"
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        Self.window = window
    }
}
#endif

#if DEBUG
/// Alternates which of two fixture agents is busier on every sample.
actor WatchdogReorderFixtureSampler: ProcessSampling {
    private var flipped = false
    private let processes: [ProcessSnapshot]

    init(processes: [ProcessSnapshot]) {
        self.processes = processes
    }

    func sample() async throws -> ProcessSample {
        flipped.toggle()
        let ranked = processes.enumerated().map { index, process -> ProcessSnapshot in
            var process = process
            let busy = (index == 0) == flipped
            process.cpuPercent = busy ? 90 : 10
            return process
        }
        return ProcessSample(processes: ranked, systemCPUPercent: 20, systemMemory: nil)
    }
}
#endif

/// Single-instance lock. Acquired in `WatchdogApp.init` before monitoring
/// starts, so a second launch never samples, notifies, or auto-suspends before
/// it exits.
@MainActor
enum WatchdogInstanceLock {
    enum Result {
        case acquired
        case heldByAnotherInstance
        case unavailable
        case notRequired
    }

    private(set) static var result: Result?
    private static var fileDescriptor: Int32 = -1

    static func acquireIfNeeded(required: Bool) -> Result {
        if let result { return result }
        let acquired = required ? acquire() : .notRequired
        result = acquired
        return acquired
    }

    private static func acquire() -> Result {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return .unavailable
        }
        let directory = applicationSupport.appendingPathComponent("Watchdog", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return .unavailable
        }

        let descriptor = Darwin.open(
            directory.appendingPathComponent("instance.lock").path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return .unavailable }
        var fileLock = Darwin.flock()
        fileLock.l_start = 0
        fileLock.l_len = 0
        fileLock.l_pid = 0
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        guard fcntl(descriptor, F_SETLK, &fileLock) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            return lockError == EACCES || lockError == EAGAIN
                ? .heldByAnotherInstance
                : .unavailable
        }
        fileDescriptor = descriptor
        return .acquired
    }
}

/// How this process was launched. Computed once so the lock, login item,
/// ledger, and sampling decisions can never disagree.
enum WatchdogLaunchMode {
    case normal
    case unitTestHost
    #if DEBUG
    case uiTestFixture
    #endif

    static var current: WatchdogLaunchMode {
        #if DEBUG
        if WatchdogUITestFixture.isActive(in: ProcessInfo.processInfo.arguments) {
            return .uiTestFixture
        }
        #endif
        return isRunningUnitTests ? .unitTestHost : .normal
    }
}

@MainActor
final class WatchdogAppDelegate: NSObject, NSApplicationDelegate {
    var launchAtLoginController: LaunchAtLoginController?
    var monitor: ProcessMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mode = WatchdogLaunchMode.current
        if case .heldByAnotherInstance = WatchdogInstanceLock.result {
            activateExistingInstanceIfPresent()
            NSApplication.shared.terminate(nil)
            return
        }
        switch mode {
        case .normal:
            NSApplication.shared.setActivationPolicy(.accessory)
            // Launch smoke tests run the real launch path from a build
            // directory; they must not register that build as a login item.
            if ProcessInfo.processInfo.environment["WATCHDOG_DISABLE_LOGIN_ITEM"] != "1" {
                launchAtLoginController?.registerByDefaultIfNeeded()
            }
        case .unitTestHost:
            // The hosted test bundle must not register a DerivedData build as
            // a login item or touch the user's real state.
            NSApplication.shared.setActivationPolicy(.accessory)
        #if DEBUG
        case .uiTestFixture:
            NSApplication.shared.setActivationPolicy(.regular)
            Task { @MainActor in
                let wantsMainWindow = ProcessInfo.processInfo.arguments
                    .contains(WatchdogUITestFixture.window)
                if wantsMainWindow {
                    WatchdogWindowOpener.pendingOpen = true
                    for _ in 0..<80 {
                        if WatchdogWindowOpener.openWindowAction != nil { break }
                        await Task.yield()
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    WatchdogWindowOpener.openMainWindow()
                } else {
                    await Task.yield()
                    WatchdogUITestFixtureHost.showWindowIfNeeded()
                }
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        #endif
        }
    }

    /// Never leave a process frozen behind Watchdog: if it stopped anything
    /// that is still stopped, ask before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let monitor, case .normal = WatchdogLaunchMode.current else { return .terminateNow }
        // A duplicate launch quits right away. It never monitored anything,
        // so it must not prompt about (or resume) the primary's suspensions.
        guard case .acquired = WatchdogInstanceLock.result else { return .terminateNow }
        // Logout, restart, and shutdown end every user process anyway; a
        // modal prompt there would only stall or cancel the logout.
        if NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil {
            return .terminateNow
        }
        monitor.reconcileLedger()
        let stopped = monitor.watchdogSuspended
        guard !stopped.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Watchdog이 일시 정지한 프로세스 \(stopped.count)개가 멈춰 있습니다"
        alert.informativeText = stopped.prefix(5)
            .map { "• \($0.displayName) (PID \($0.pid))" }
            .joined(separator: "\n")
            + (stopped.count > 5 ? "\n…" : "")
            + "\n\n그대로 종료하면 직접 재개하기 전까지 멈춘 상태로 남습니다. 다음 실행 때 다시 알려 드립니다."
        alert.addButton(withTitle: "재개 후 종료")
        alert.addButton(withTitle: "그대로 종료")
        alert.addButton(withTitle: "취소")
        NSApplication.shared.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                let result = await monitor.resumeAllWatchdogSuspended()
                sender.reply(toApplicationShouldTerminate: Self.confirmQuitAfterResume(failed: result.failed, monitor: monitor))
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// "재개 후 종료" must not quietly leave processes frozen: when some
    /// could not be resumed (for example the pre-quit sample failed), say so
    /// and let the user stay.
    private static func confirmQuitAfterResume(failed: Int, monitor: ProcessMonitor) -> Bool {
        guard failed > 0, !monitor.watchdogSuspended.isEmpty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "프로세스 \(monitor.watchdogSuspended.count)개를 재개하지 못했습니다"
        alert.informativeText = monitor.watchdogSuspended.prefix(5)
            .map { "• \($0.displayName) (PID \($0.pid))" }
            .joined(separator: "\n")
            + "\n\n종료하면 멈춘 상태로 남습니다. 남아서 직접 재개하거나 watchdog-cli stopped --resume-all을 쓸 수 있습니다."
        alert.addButton(withTitle: "남아 있기")
        alert.addButton(withTitle: "그대로 종료")
        NSApplication.shared.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func activateExistingInstanceIfPresent() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        guard let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter({ $0.processIdentifier != getpid() })
            .min(by: {
                ($0.launchDate ?? .distantFuture) < ($1.launchDate ?? .distantFuture)
            })
        else {
            return
        }
        existing.activate(options: [.activateAllWindows])
    }
}

/// Hosted unit tests launch a second Watchdog app next to the installed
/// instance; they must neither contend for the single-instance lock nor run
/// the live sampling loop during tests.
private var isRunningUnitTests: Bool {
    ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
}

@main
struct WatchdogApp: App {
    @NSApplicationDelegateAdaptor(WatchdogAppDelegate.self) private var appDelegate
    // Owned but deliberately not observed: observing it re-evaluated the whole
    // scene on every published change. The panel observes it itself and the
    // label listens to menuBarIconState alone.
    @State private var monitor: ProcessMonitor
    @StateObject private var launchAtLogin: LaunchAtLoginController
    private let showsFixtureWindow: Bool

    @MainActor
    init() {
        let mode = WatchdogLaunchMode.current
        let lock: WatchdogInstanceLock.Result
        switch mode {
        case .normal: lock = WatchdogInstanceLock.acquireIfNeeded(required: true)
        default: lock = WatchdogInstanceLock.acquireIfNeeded(required: false)
        }
        let isPrimaryInstance: Bool
        if case .heldByAnotherInstance = lock { isPrimaryInstance = false } else { isPrimaryInstance = true }
        let monitor: ProcessMonitor
        // Login-item diagnostics go to the user's real defaults only from the
        // shipping instance; a test host or fixture lives at another path and
        // would overwrite them with its own (unregistered) status.
        let loginDefaults: UserDefaults
        switch mode {
        case .normal:
            monitor = ProcessMonitor(ledger: .standard(), journal: .standard())
            // Launch smoke runs this path from a build directory.
            loginDefaults = ProcessInfo.processInfo.environment["WATCHDOG_DISABLE_LOGIN_ITEM"] == "1"
                ? UserDefaults(suiteName: "dev.justn.watchdog.isolated") ?? .standard
                : .standard
        default:
            // Tests and fixtures never read or write the user's real defaults
            // or suspension ledger, and never prompt for notification access.
            let suite = "dev.justn.watchdog.isolated"
            let defaults = UserDefaults(suiteName: suite) ?? .standard
            defaults.removePersistentDomain(forName: suite)
            defaults.set(false, forKey: MonitorSettings.Keys.notificationsEnabled)
            loginDefaults = defaults
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(WatchdogUITestFixture.reorder) {
                monitor = ProcessMonitor(
                    defaults: defaults,
                    sampler: WatchdogReorderFixtureSampler(processes: Self.fixtureProcesses),
                    ledger: .inMemory(),
                    journal: .inMemory()
                )
                break
            }
            #endif
            monitor = ProcessMonitor(defaults: defaults, ledger: .inMemory(), journal: .inMemory())
        }
        let launchAtLogin = LaunchAtLoginController(defaults: loginDefaults, automaticallyRegister: false)
        var shouldShowFixtureWindow = false
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let usesActionableFixture = arguments.contains(WatchdogUITestFixture.actionable)
        let usesLiveFixture = arguments.contains(WatchdogUITestFixture.live)
        let usesStaleFixture = arguments.contains(WatchdogUITestFixture.stale)
        let usesOutcomeFixture = arguments.contains(WatchdogUITestFixture.outcome)
        let usesExitedFixture = arguments.contains(WatchdogUITestFixture.exited)
        let usesStillRunningFixture = arguments.contains(WatchdogUITestFixture.stillRunning)
        let usesReorderFixture = arguments.contains(WatchdogUITestFixture.reorder)
        let usesWindowFixture = arguments.contains(WatchdogUITestFixture.window)
        shouldShowFixtureWindow = usesActionableFixture || usesLiveFixture || usesStaleFixture
            || usesOutcomeFixture || usesExitedFixture || usesStillRunningFixture || usesReorderFixture
        if usesActionableFixture || usesOutcomeFixture || usesExitedFixture
            || usesStillRunningFixture || usesWindowFixture {
            monitor.loadActionablePreview(
                processes: Self.fixtureProcesses,
                hotProcesses: [Self.fixtureProcesses[0].identity],
                highMemoryProcesses: [Self.fixtureProcesses[0].identity],
                updatedAt: Date()
            )
            if usesWindowFixture {
                Self.preloadWindowJournalFixture(into: monitor)
            }
            if usesOutcomeFixture {
                monitor.setActionOutcomePreview(.verificationFailed, for: Self.fixtureProcesses[0])
            } else if usesExitedFixture {
                monitor.setActionOutcomePreview(.exited, for: Self.fixtureProcesses[0])
            } else if usesStillRunningFixture {
                monitor.setActionOutcomePreview(.stillRunning, for: Self.fixtureProcesses[0])
            }
            Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    monitor.refreshActionablePreviewObservation()
                }
            }
        } else if usesStaleFixture {
            monitor.loadStalePreview(
                processes: Self.fixtureProcesses,
                hotProcesses: [Self.fixtureProcesses[0].identity],
                highMemoryProcesses: [Self.fixtureProcesses[0].identity],
                updatedAt: Date(timeIntervalSinceNow: -6)
            )
        } else if usesLiveFixture || usesReorderFixture || (mode == .normal && isPrimaryInstance) {
            monitor.start()
        }
        if shouldShowFixtureWindow {
            WatchdogUITestFixtureHost.monitor = monitor
            WatchdogUITestFixtureHost.launchAtLogin = launchAtLogin
        }
        #else
        if isPrimaryInstance {
            monitor.start()
        }
        #endif
        _monitor = State(initialValue: monitor)
        _launchAtLogin = StateObject(wrappedValue: launchAtLogin)
        showsFixtureWindow = shouldShowFixtureWindow
        appDelegate.launchAtLoginController = launchAtLogin
        appDelegate.monitor = monitor
    }

    var body: some Scene {
        MenuBarExtra {
            // A MenuBarExtra window sizes to its content's ideal height, and the
            // process list is a ScrollView whose ideal height is effectively zero.
            // Without an explicit size the popover collapsed to the chrome plus a
            // few points and the list was unusable. Pin the popover so the list
            // always gets real height, and keep it wider than the 360 pt
            // confirmation card. The UI-test fixture window sizes WatchdogMenuView
            // itself and must keep its own geometry.
            WatchdogMenuView(monitor: monitor, launchAtLogin: launchAtLogin)
                .frame(width: 380, height: 520)
        } label: {
            WatchdogMenuBarLabel(monitor: monitor)
                .modifier(WatchdogWindowOpenInstaller())
        }
        .menuBarExtraStyle(.window)

        Window("Watchdog", id: "main") {
            WatchdogWindowView(monitor: monitor, launchAtLogin: launchAtLogin)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 560)
    }

    #if DEBUG
    private static let fixtureProcesses: [ProcessSnapshot] = [
        ProcessSnapshot(
            id: 71_001,
            parentPID: 600,
            processGroupID: 71_001,
            userID: getuid(),
            tty: "ttys001",
            cpuPercent: 184,
            residentBytes: 5 * 1_024 * 1_024 * 1_024,
            state: "R",
            elapsed: "00:12:34",
            executablePath: "/usr/local/bin/claude",
            startTimeMicroseconds: 9_071_001,
            workingDirectory: "/tmp/watchdog-fixture",
            orphanReason: .detachedSession
        ),
        ProcessSnapshot(
            id: 71_002,
            parentPID: 600,
            processGroupID: 71_002,
            userID: getuid(),
            tty: "ttys002",
            cpuPercent: 12,
            residentBytes: 256 * 1_024 * 1_024,
            state: "R",
            elapsed: "00:02:10",
            executablePath: "/usr/local/bin/codex",
            startTimeMicroseconds: 9_071_002,
            workingDirectory: "/tmp/watchdog-second"
        ),
        ProcessSnapshot(
            id: 71_003,
            parentPID: 71_001,
            processGroupID: 71_001,
            userID: getuid(),
            tty: "ttys001",
            cpuPercent: 8,
            residentBytes: 32 * 1_024 * 1_024,
            state: "R",
            elapsed: "00:01:04",
            executablePath: "/usr/bin/make",
            startTimeMicroseconds: 9_071_003,
            workingDirectory: "/tmp/watchdog-fixture",
            agentAncestor: AgentAncestor(
                pid: 71_001,
                name: "claude",
                workingDirectory: "/tmp/watchdog-fixture"
            )
        ),
    ]

    private static func preloadWindowJournalFixture(into monitor: ProcessMonitor) {
        let claude = fixtureProcesses[0]
        let codex = fixtureProcesses[1]
        let autoSuspend = ActionJournalEntry(
            id: windowJournalAutoSuspendID,
            at: Date(timeIntervalSinceNow: -180),
            source: .auto,
            action: .suspend,
            pid: claude.id,
            startTimeMicroseconds: claude.startTimeMicroseconds,
            userID: claude.userID,
            executablePath: claude.executablePath,
            displayName: claude.displayName,
            workingDirectory: claude.workingDirectory,
            reason: "CPU 184% 지속 25초",
            outcome: "suspended"
        )
        let cliSuspend = ActionJournalEntry(
            id: windowJournalCLISuspendID,
            at: Date(timeIntervalSinceNow: -90),
            source: .cli,
            action: .suspend,
            pid: codex.id,
            startTimeMicroseconds: codex.startTimeMicroseconds,
            userID: codex.userID,
            executablePath: codex.executablePath,
            displayName: codex.displayName,
            workingDirectory: codex.workingDirectory,
            outcome: "suspended"
        )
        let appResume = ActionJournalEntry(
            id: windowJournalAppResumeID,
            at: Date(timeIntervalSinceNow: -30),
            source: .app,
            action: .resume,
            pid: codex.id,
            startTimeMicroseconds: codex.startTimeMicroseconds,
            userID: codex.userID,
            executablePath: codex.executablePath,
            displayName: codex.displayName,
            workingDirectory: codex.workingDirectory,
            outcome: "resumed",
            undoOf: cliSuspend.id
        )
        monitor.loadJournalDisplayPreview(
            entries: [autoSuspend, cliSuspend, appResume],
            suspended: [
                SuspensionRecord(
                    identity: claude.identity,
                    executablePath: claude.executablePath,
                    suspendedAt: Date(timeIntervalSinceNow: -180),
                    source: .auto
                ),
            ]
        )
    }

    static let windowJournalAutoSuspendID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1")!
    static let windowJournalCLISuspendID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2")!
    static let windowJournalAppResumeID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3")!
    #endif
}
