import SwiftUI

@MainActor
private struct LiveQALaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}

@main
struct WatchdogLiveQAApp: App {
    @StateObject private var monitor: ProcessMonitor
    @StateObject private var launchAtLogin: LaunchAtLoginController

    @MainActor
    init() {
        let defaults = UserDefaults(suiteName: "dev.justn.watchdog.liveqa") ?? .standard
        defaults.set(false, forKey: "notificationsEnabled")
        let monitor = ProcessMonitor(defaults: defaults)
        let launchAtLogin = LaunchAtLoginController(
            service: LiveQALaunchAtLoginService(),
            automaticallyRegister: false
        )
        monitor.start()
        _monitor = StateObject(wrappedValue: monitor)
        _launchAtLogin = StateObject(wrappedValue: launchAtLogin)
    }

    var body: some Scene {
        WindowGroup("Watchdog Live QA") {
            WatchdogMenuView(monitor: monitor, launchAtLogin: launchAtLogin)
                .frame(minWidth: 480, minHeight: 590)
        }
        .defaultSize(width: 480, height: 590)
    }
}
