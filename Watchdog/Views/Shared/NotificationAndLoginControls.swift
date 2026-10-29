import AppKit
import SwiftUI

struct NotificationAndLoginControls: View {
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject var launchAtLogin: LaunchAtLoginController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("시스템 알림", isOn: $monitor.notificationsEnabled)
                .accessibilityIdentifier("watchdog.settings.notifications")
            if monitor.notificationAuthorization == .denied {
                HStack {
                    Label("macOS 알림 권한이 꺼져 있습니다", systemImage: "bell.slash")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("알림 설정 열기") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }
            }

            Toggle(
                "로그인 시 자동 실행",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )
            .accessibilityIdentifier("watchdog.settings.login")
            if launchAtLogin.requiresApproval {
                Text("시스템 설정의 로그인 항목에서 승인이 필요합니다")
                    .foregroundStyle(.orange)
            } else if let errorMessage = launchAtLogin.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
    }
}
