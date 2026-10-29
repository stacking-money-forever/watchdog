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
                        .accessibilityIdentifier(section.accessibilityIdentifier)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            switch selectedSection {
            case .sessions:
                SessionsView(monitor: monitor)
            case .journal:
                JournalView(monitor: monitor)
            case .rules:
                RulesView(monitor: monitor)
            case .settings:
                SettingsView(monitor: monitor, launchAtLogin: launchAtLogin)
            default:
                WindowSectionPlaceholder(section: selectedSection)
            }
        }
        .frame(minWidth: 680, minHeight: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchdog.window")
        .onAppear {
            applyPendingSection()
            WatchdogWindowOpener.bringMainWindowForward()
        }
        .onReceive(NotificationCenter.default.publisher(for: WatchdogWindowOpener.sectionDidChange)) { notification in
            if let raw = notification.userInfo?["section"] as? String,
               let section = WindowSection(rawValue: raw) {
                selectedSection = section
                WatchdogWindowOpener.pendingSection = nil
            }
        }
    }

    private func applyPendingSection() {
        guard let section = WatchdogWindowOpener.pendingSection else { return }
        selectedSection = section
        WatchdogWindowOpener.pendingSection = nil
    }
}

struct WindowSectionPlaceholder: View {
    let section: WindowSection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.title2)
            Text(section.summary)
                .foregroundStyle(.secondary)
            Text("이 화면은 0.3에서 채워집니다")
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchdog.window.detail.\(section.rawValue)")
    }
}
