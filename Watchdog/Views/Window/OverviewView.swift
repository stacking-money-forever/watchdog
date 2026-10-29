import SwiftUI

struct OverviewView: View {
    @ObservedObject var monitor: ProcessMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("개요")
                    .font(.title2)

                statusBox
                nowBox
                recentBox
                rulesSummaryBox
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchdog.window.detail.overview")
    }

    private var statusBox: some View {
        GroupBox("상태") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    WatchdogMenuBarIcon(state: monitor.menuBarIconState)
                        .scaleEffect(1.35)
                        .frame(width: 24, height: 22)
                    Text(statusSentence)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 16) {
                    Text("CPU \(Int(monitor.systemCPUPercent.rounded()))%")
                        .monospacedDigit()
                        .accessibilityLabel("시스템 CPU 사용률")
                        .accessibilityValue("\(Int(monitor.systemCPUPercent.rounded()))%")
                    Text(memorySummary)
                        .monospacedDigit()
                        .accessibilityLabel("시스템 메모리 사용률")
                        .accessibilityValue(memorySummary)
                }

                HStack(alignment: .center, spacing: 8) {
                    if let lastUpdated = monitor.lastUpdated {
                        Text("마지막 샘플 \(WatchdogFormatters.updatedTime.string(from: lastUpdated))")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("샘플링 중…")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if isObservationStale {
                        Button("지금 새로고침") {
                            Task { await monitor.refreshNow() }
                        }
                        .disabled(monitor.isRefreshing)
                        .accessibilityLabel("지금 새로고침")
                        .accessibilityIdentifier("watchdog.overview.refresh")
                    }
                }

                if isObservationStale {
                    Text("관찰 정보가 오래되어 새로고침 후 제어할 수 있습니다")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("watchdog.overview.status")
        }
    }

    private var nowBox: some View {
        GroupBox("지금") {
            VStack(alignment: .leading, spacing: 8) {
                Button("주의 세션 \(attentionSessionCount)개") {
                    WatchdogWindowOpener.openMainWindow(section: .sessions)
                }
                .accessibilityLabel("주의 세션 \(attentionSessionCount)개")
                .accessibilityIdentifier("watchdog.overview.sessions-button")

                Button("Watchdog이 멈춘 프로세스 \(monitor.watchdogSuspended.count)개") {
                    WatchdogWindowOpener.openMainWindow(section: .journal)
                }
                .accessibilityLabel("Watchdog이 멈춘 프로세스 \(monitor.watchdogSuspended.count)개")
                .accessibilityIdentifier("watchdog.overview.stopped-button")

                Button("고아 \(orphanCount)개") {
                    WatchdogWindowOpener.openMainWindow(section: .processes)
                }
                .accessibilityLabel("고아 \(orphanCount)개")
                .accessibilityIdentifier("watchdog.overview.orphans-button")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recentBox: some View {
        GroupBox("최근 조치") {
            let entries = Array(monitor.journalEntries.prefix(5))
            VStack(alignment: .leading, spacing: 8) {
                if entries.isEmpty {
                    Text("아직 조치가 없습니다")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("watchdog.overview.recent.empty")
                } else {
                    ForEach(entries) { entry in
                        recentRow(entry)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("watchdog.overview.recent")
        }
    }

    private var rulesSummaryBox: some View {
        GroupBox("감지 규칙 요약") {
            VStack(alignment: .leading, spacing: 10) {
                Text(rulesSummaryLine)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("watchdog.overview.rules-summary")
                Button("감지 규칙 열기") {
                    WatchdogWindowOpener.openMainWindow(section: .rules)
                }
                .accessibilityLabel("감지 규칙 열기")
                .accessibilityIdentifier("watchdog.overview.open-rules")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func recentRow(_ entry: ActionJournalEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(JournalPresentation.actionLabel(entry.action)) · \(JournalPresentation.targetLabel(entry))")
                    .lineLimit(1)
                Text("\(JournalPresentation.sourceLabel(entry.source)) · \(relativeTime(entry.at)) · \(JournalPresentation.outcomeLabel(entry.outcome))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if monitor.undoTarget(for: entry) != nil {
                Button("되돌리기") {
                    monitor.undo(entry)
                }
                .controlSize(.small)
                .accessibilityLabel("되돌리기")
                .accessibilityIdentifier("overview.journal.\(entry.id.uuidString).undo")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.journal.\(entry.id.uuidString).row")
    }

    private var statusSentence: String {
        let attention = attentionItemCount
        switch monitor.menuBarIconState {
        case .normal:
            return "정상입니다. 주의 항목이 없습니다."
        case let .attention(count):
            return "주의 \(count)건입니다."
        case let .acted(count):
            if attention > 0 {
                return "멈춤 \(count)건 · 주의 \(attention)건입니다."
            }
            return "멈춤 \(count)건입니다."
        case .stale:
            return "오래됨 — 관찰 정보가 오래되어 제어할 수 없습니다."
        }
    }

    private var attentionSessionCount: Int {
        monitor.sessions.filter { monitor.sessionHasWarning($0) }.count
    }

    private var orphanCount: Int {
        monitor.orphans(limit: 1_000).count
    }

    private var attentionItemCount: Int {
        attentionSessionCount + orphanCount
    }

    private var isObservationStale: Bool {
        if monitor.samplingError != nil { return true }
        if case .stale = monitor.menuBarIconState { return true }
        if let first = monitor.processes.first {
            return monitor.actionability(of: first).freshness != .current
        }
        return false
    }

    private var memorySummary: String {
        guard let memory = monitor.systemMemory else { return "--" }
        let used = WatchdogFormatters.memory.string(fromByteCount: Int64(memory.usedBytes))
        let total = WatchdogFormatters.memory.string(fromByteCount: Int64(memory.totalBytes))
        return "\(used)/\(total)"
    }

    private var rulesSummaryLine: String {
        let auto: String
        if !monitor.autoSuspendEnabled {
            auto = "꺼짐"
        } else {
            switch monitor.autoSuspendScope {
            case .agent: auto = "에이전트만"
            case .session: auto = "세션 전체"
            }
        }
        return "CPU \(Int(monitor.threshold))% · 메모리 \(String(format: "%.1f", monitor.memoryThresholdGB))GB · \(Int(monitor.sustainedDuration))초 유지 · 자동 정지 \(auto)"
    }

    private func relativeTime(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()
}
