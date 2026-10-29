import AppKit
import SwiftUI

struct RulesView: View {
    @ObservedObject var monitor: ProcessMonitor
    @State private var fileActionMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("감지 규칙")
                        .font(.title2)
                    Text("지속 시간 동안 임계값을 넘긴 프로세스만 경고합니다")
                        .foregroundStyle(.secondary)
                }

                GroupBox {
                    DetectionRulesControls(monitor: monitor, showsItemDescriptions: true)
                        .font(.body)
                }

                GroupBox("사용자 규칙 파일") {
                    rulesFileContent
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchdog.window.detail.rules")
    }

    private var rulesFileContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(rulesURL.path)
                .font(.caption)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)

            Text(statusLine)
                .accessibilityIdentifier("watchdog.rules.file.status")

            if case let .loaded(rules, _) = monitor.rulesStatus {
                Text(appliedSummary(rules))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let issues = rules.validationIssues()
                if !issues.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(issues, id: \.self) { issue in
                            Text(issue)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            if let fileActionMessage {
                Text(fileActionMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                if case .absent = monitor.rulesStatus {
                    Button("파일 만들기") {
                        createTemplate()
                    }
                    .accessibilityLabel("파일 만들기")
                    .accessibilityIdentifier("watchdog.rules.file.create")
                }
                Button("편집기에서 열기") {
                    NSWorkspace.shared.open(rulesURL)
                }
                .accessibilityLabel("편집기에서 열기")
                .accessibilityIdentifier("watchdog.rules.file.open")
                Button("Finder에서 보기") {
                    revealInFinder()
                }
                .accessibilityLabel("Finder에서 보기")
                Button("다시 읽기") {
                    monitor.reloadRules()
                    fileActionMessage = nil
                }
                .accessibilityLabel("다시 읽기")
                .accessibilityIdentifier("watchdog.rules.file.reload")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rulesURL: URL {
        switch monitor.rulesStatus {
        case let .loaded(_, url), let .absent(url), let .invalid(url, _):
            url
        }
    }

    private var statusLine: String {
        switch monitor.rulesStatus {
        case let .loaded(rules, _):
            "\(rules.appliedCount)개 규칙 적용"
        case .absent:
            "없음"
        case let .invalid(_, reason):
            "손상: \(reason)"
        }
    }

    private func appliedSummary(_ rules: AgentRules) -> String {
        "이름 \(rules.agentNames.count) · 마커 \(rules.packageMarkers.count) · 서브커맨드 \(rules.serviceSubcommands.count) · 호스트 \(rules.sessionHosts.count) · 제외 \(rules.ignoreNames.count)"
    }

    private func createTemplate() {
        do {
            try AgentRules.writeTemplate(to: rulesURL)
            monitor.reloadRules()
            fileActionMessage = nil
        } catch {
            fileActionMessage = error.localizedDescription
        }
    }

    private func revealInFinder() {
        if FileManager.default.fileExists(atPath: rulesURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([rulesURL])
        } else {
            NSWorkspace.shared.open(rulesURL.deletingLastPathComponent())
        }
    }
}
