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
            WindowSectionPlaceholder(section: selectedSection)
        }
        .frame(minWidth: 680, minHeight: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchdog.window")
        .onAppear {
            WatchdogWindowOpener.bringMainWindowForward()
        }
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
