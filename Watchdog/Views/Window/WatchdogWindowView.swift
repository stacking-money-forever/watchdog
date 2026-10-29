import SwiftUI

struct WatchdogWindowView: View {
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @SceneStorage("window.section") private var selectedSection: WindowSection = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                ForEach(WindowSection.allCases) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                        .accessibilityLabel(section.title)
                        .accessibilityIdentifier(section.accessibilityIdentifier)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selectedSection {
            case .overview:
                OverviewView(monitor: monitor)
            case .sessions:
                SessionsView(monitor: monitor)
            case .processes:
                ProcessesView(monitor: monitor)
            case .journal:
                JournalView(monitor: monitor)
            case .rules:
                RulesView(monitor: monitor)
            case .settings:
                SettingsView(monitor: monitor, launchAtLogin: launchAtLogin)
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchdog.window")
        .background(windowKeyboardCommands)
        .onAppear {
            applyPendingSection()
            WatchdogWindowOpener.bringMainWindowForward()
            #if DEBUG
            ProcessesUITestObserver.shared.install()
            ProcessesUITestObserver.shared.onShowProcesses = { selectedSection = .processes }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchdogWindowOpener.sectionDidChange)) { notification in
            if let raw = notification.userInfo?["section"] as? String,
               let section = WindowSection(rawValue: raw) {
                selectedSection = section
                WatchdogWindowOpener.pendingSection = nil
            }
        }
    }

    private var windowKeyboardCommands: some View {
        VStack {
            Button("검색") {
                selectedSection = .processes
                NotificationCenter.default.post(name: WatchdogWindowOpener.focusProcessSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
            Button("지금 새로고침") {
                Task { await monitor.refreshNow() }
            }
            .keyboardShortcut("r", modifiers: .command)
            Button("감지 규칙") {
                selectedSection = .rules
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func applyPendingSection() {
        guard let section = WatchdogWindowOpener.pendingSection else { return }
        selectedSection = section
        WatchdogWindowOpener.pendingSection = nil
    }
}
