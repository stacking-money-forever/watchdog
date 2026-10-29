import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var launchAtLogin: LaunchAtLoginController

    private var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/watchdog-cli").path
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "버전 \(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("설정")
                    .font(.title2)

                GroupBox("알림과 로그인") {
                    NotificationAndLoginControls(monitor: monitor, launchAtLogin: launchAtLogin)
                        .font(.body)
                }

                GroupBox("CLI") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(cliPath)
                            .font(.body)
                            .textSelection(.enabled)
                        Button("경로 복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cliPath, forType: .string)
                        }
                        Text("터미널에서 쓰려면 ./scripts/install.sh --link-cli 또는 이 경로를 PATH에 추가")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("정보") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(versionText)
                            .font(.body)
                        HStack {
                            Button("Watchdog 정보") {
                                NSApplication.shared.orderFrontStandardAboutPanel(nil)
                                NSApplication.shared.activate(ignoringOtherApps: true)
                            }
                            Button("Watchdog 종료") {
                                NSApplication.shared.terminate(nil)
                            }
                            .accessibilityIdentifier("watchdog.settings.quit")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchdog.window.detail.settings")
        .onAppear {
            monitor.refreshNotificationAuthorization()
            launchAtLogin.refresh()
        }
    }
}
