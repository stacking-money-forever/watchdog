import AppKit
import SwiftUI

private struct MenuActionFeedback: Identifiable {
    let id = UUID()
    let isError: Bool
    let message: String
}

private struct LocalActionFailure {
    let id = UUID()
    let message: String
}

private struct ProcessOutcomeSummary: Identifiable {
    let identity: ProcessIdentity
    let text: String
    let isError: Bool

    var id: ProcessIdentity { identity }
}

struct WatchdogMenuView: View {
    @ObservedObject var monitor: ProcessMonitor
    @ObservedObject private var launchAtLogin: LaunchAtLoginController
    @Environment(\.dismiss) private var dismiss
    @State private var pendingAction: PendingProcessAction?
    @State private var menuActionFeedback: MenuActionFeedback?
    @State private var localActionFailures: [ProcessIdentity: LocalActionFailure] = [:]
    /// A closed MenuBarExtra window keeps its view graph, and SwiftUI kept
    /// rebuilding every row on each sample while nobody could see it; the
    /// footprint grew without bound after the panel had been opened once.
    /// Rendering nothing while closed lets the graph go idle; @State above
    /// (a pending confirmation included) is kept.
    @State private var isShown = false
    @FocusState private var focusedRow: WatchdogFocusTarget?
    @State private var focusAfterConfirmation: WatchdogFocusTarget?

    private let sessionLimit = 8
    private let orphanLimit = 3
    private let recentLimit = 3

    init(monitor: ProcessMonitor, launchAtLogin: LaunchAtLoginController) {
        self.monitor = monitor
        self._launchAtLogin = ObservedObject(wrappedValue: launchAtLogin)
    }

    var body: some View {
        ZStack {
            if isShown {
                VStack(spacing: 0) {
                    header
                    Divider()
                    statusLine
                    Divider()
                    content
                    Divider()
                    footer
                }
                .disabled(pendingAction != nil)
                .accessibilityHidden(pendingAction != nil)

                if let pendingAction {
                    DestructiveConfirmationCard(
                        action: pendingAction,
                        onCancel: { cancelDestructiveAction(pendingAction) },
                        onConfirm: {
                            self.pendingAction = nil
                            completeDestructiveAction(pendingAction)
                            restoreFocusAfterConfirmation()
                        }
                    )
                }
            } else {
                Color.clear
            }
        }
        .background {
            Button("감지 규칙") {
                openWindow(section: .rules)
            }
            .keyboardShortcut(",", modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
        .dismissInvalidDestructiveConfirmation(pendingAction: $pendingAction, monitor: monitor) { pending, stillListed in
            let message = stillListed
                ? ProcessControlError.confirmationExpired.localizedDescription
                : ProcessControlError.processChanged.localizedDescription
            showMenuFeedback(.init(isError: true, message: message))
        }
        .onAppear {
            isShown = true
            monitor.isPresented = true
            monitor.refreshNotificationAuthorization()
            launchAtLogin.refresh()
            if focusedRow == nil, pendingAction == nil {
                focusedRow = firstFocusTarget()
            }
        }
        .onKeyPress(.upArrow) {
            moveFocus(.up)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveFocus(.down)
            return .handled
        }
        .onDisappear {
            isShown = false
            monitor.isPresented = false
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Watchdog")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .accessibilityIdentifier("watchdog.header")

            Spacer()

            Text("CPU \(Int(monitor.systemCPUPercent.rounded()))%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(gaugeColor)
                .accessibilityLabel("시스템 CPU 사용률")
                .accessibilityValue("\(Int(monitor.systemCPUPercent.rounded()))%")

            Text(memorySummary)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(memoryPressureColor)
                .accessibilityLabel("시스템 메모리 사용률")
                .accessibilityValue(memorySummary)

            Button {
                openWindow()
            } label: {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.plain)
            .help("창 열기")
            .accessibilityLabel("창 열기")
            .accessibilityIdentifier("watchdog.open-window")
            .keyboardShortcut("o", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var isObservationStale: Bool {
        if monitor.samplingError != nil { return true }
        if let first = monitor.processes.first {
            let freshness = monitor.actionability(of: first).freshness
            return freshness != .current
        }
        return false
    }

    private var statusLine: some View {
        HStack(alignment: .center, spacing: 8) {
            if isObservationStale {
                Text("관찰 정보가 오래되어 새로고침 후 제어할 수 있습니다")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                Spacer(minLength: 8)
                refreshButton
            } else {
                Text(statusLineText)
                    .font(.caption)
                    .foregroundStyle(statusLineColor)
                Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("watchdog.status-line")
    }

    private var statusLineText: String {
        let warningCount = monitor.sessions.filter { monitor.sessionHasWarning($0) }.count
        let stoppedCount = monitor.watchdogSuspended.count
        if warningCount == 0 && stoppedCount == 0 {
            if monitor.sessions.isEmpty {
                return "실행 중인 코딩 에이전트가 없습니다"
            }
            return "문제 없음 · 세션 \(monitor.sessions.count)개 감시 중"
        }
        return "⚠ 주의 \(warningCount) · ⏸ 멈춤 \(stoppedCount)"
    }

    private var statusLineColor: Color {
        let warningCount = monitor.sessions.filter { monitor.sessionHasWarning($0) }.count
        if warningCount > 0 || !monitor.watchdogSuspended.isEmpty { return .orange }
        return .secondary
    }

    private var content: some View {
        VStack(spacing: 8) {
            if let feedback = currentFeedback {
                feedbackBanner(feedback.message, isError: feedback.isError)
                    .padding(.horizontal, 12)
            }

            if let banner = outcomeBanner {
                feedbackBanner(banner.text, isError: banner.isError)
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("watchdog.outcome-banner")
            }

            if let samplingError = monitor.samplingError, !monitor.processes.isEmpty {
                Label("새 정보를 가져오지 못했습니다: \(samplingError)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
            }

            if let samplingError = monitor.samplingError, monitor.processes.isEmpty {
                ContentUnavailableView(
                    "프로세스 정보를 가져오지 못했습니다",
                    systemImage: "exclamationmark.triangle",
                    description: Text(samplingError)
                )
            } else if monitor.lastUpdated == nil && monitor.processes.isEmpty {
                Text("샘플링 중…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        sessionSection
                        orphanSection
                        recentActionsSection
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
                .accessibilityIdentifier("watchdog.process-list")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionSection: some View {
        let visible = monitor.visibleSessions(limit: sessionLimit)
        let remaining = max(0, monitor.sessions.count - visible.count)
        return VStack(alignment: .leading, spacing: 7) {
            Text("세션")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if monitor.sessions.isEmpty {
                Text("실행 중인 코딩 에이전트가 없습니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                Button("창 열기") { openWindow() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
            } else {
                ForEach(visible, id: \.id) { session in
                    sessionRow(for: session)
                }
                if remaining > 0 {
                    Button("창에서 \(remaining)개 더 보기") {
                        openWindow(section: .sessions)
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("watchdog.sessions.more")
                }
            }
        }
    }

    private var orphanSection: some View {
        let orphans = monitor.orphans(limit: orphanLimit)
        return Group {
            if !orphans.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("고아 \(orphans.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(orphans, id: \.identity) { process in
                        processRow(for: process, compact: false)
                    }
                    Button("창에서 보기") {
                        openWindow(section: .processes)
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("watchdog.orphans.show-in-window")
                }
            }
        }
    }

    private var recentActionsSection: some View {
        let entries = Array(monitor.journalEntries.prefix(recentLimit))
        return VStack(alignment: .leading, spacing: 7) {
            Text("최근 조치")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if entries.isEmpty {
                Text("아직 조치가 없습니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("watchdog.recent.empty")
            } else {
                ForEach(entries) { entry in
                    recentActionRow(entry)
                }
            }
        }
    }

    private func recentActionRow(_ entry: ActionJournalEntry) -> some View {
        let undoTarget = monitor.undoTarget(for: entry)
        return HStack(spacing: 8) {
            Image(systemName: recentActionSymbol(entry.action))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(recentActionTitle(entry))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(JournalPresentation.sourceLabel(entry.source)) · \(relativeTime(entry.at))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("되돌리기") {
                monitor.undo(entry)
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .disabled(undoTarget == nil || isObservationStale)
            .help(undoTarget == nil ? "이미 종료됨" : "되돌리기")
            .accessibilityLabel("되돌리기")
            .accessibilityIdentifier("watchdog.recent.\(entry.id.uuidString).undo")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchdog.recent.\(entry.id.uuidString).row")
        .focused($focusedRow, equals: .journal(entry.id))
        .focusable()
    }

    private func sessionRow(for session: AgentSession) -> some View {
        let root = monitor.rootProcess(of: session)
        return Group {
            if let root {
                SessionRow(
                    session: session,
                    root: root,
                    members: monitor.members(of: session),
                    actionability: monitor.actionability(of: root),
                    alertReasons: monitor.sessionAlertReasons(session),
                    isIgnored: monitor.isIgnored(root),
                    isSuspendedByWatchdog: monitor.isSuspendedByWatchdog(root),
                    actionOutcome: actionOutcome(for: root),
                    onSuspend: { monitor.suspend(root) },
                    onResume: { monitor.resume(root) },
                    onTerminate: {
                        prepareDestructiveAction(.terminate, process: root, kind: .terminate)
                    },
                    onForceQuit: {
                        prepareDestructiveAction(.forceQuit, process: root, kind: .forceQuit)
                    },
                    onIgnore: { monitor.ignoreUntilExit(root) },
                    onUndoIgnore: { monitor.undoIgnore(root) },
                    memberRow: { member in
                        processRow(for: member, compact: true)
                    },
                    onShowInWindow: { openWindow(section: .sessions) },
                    focusedRow: $focusedRow,
                    focusTarget: .session(session.id)
                )
            }
        }
    }

    private func processRow(for process: ProcessSnapshot, compact: Bool) -> ProcessRow {
        ProcessRow(
            process: process,
            actionability: monitor.actionability(of: process),
            alertReasons: monitor.alertReasons(for: process),
            isIgnored: monitor.isIgnored(process),
            isSuspendedByWatchdog: monitor.isSuspendedByWatchdog(process),
            actionOutcome: actionOutcome(for: process),
            onSuspend: { monitor.suspend(process) },
            onResume: { monitor.resume(process) },
            onTerminate: {
                prepareDestructiveAction(.terminate, process: process, kind: .terminate)
            },
            onForceQuit: {
                prepareDestructiveAction(.forceQuit, process: process, kind: .forceQuit)
            },
            onIgnore: { monitor.ignoreUntilExit(process) },
            onUndoIgnore: { monitor.undoIgnore(process) },
            compact: compact,
            focusedRow: $focusedRow,
            focusTarget: .process(process.identity)
        )
    }

    private var footer: some View {
        HStack {
            Button("창 열기") {
                openWindow()
            }
            .buttonStyle(.plain)
            .help("창 열기")
            .accessibilityLabel("창 열기")

            Button("설정") {
                openWindow(section: .settings)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("설정")
            .accessibilityIdentifier("watchdog.open-settings")

            Spacer()

            refreshButton

            Button {
                NSApplication.shared.orderFrontStandardAboutPanel(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .help("Watchdog 정보")
            .accessibilityLabel("Watchdog 정보")
            .accessibilityIdentifier("watchdog.about")

            Button("Watchdog 종료") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Watchdog 종료")
            .accessibilityIdentifier("watchdog.quit")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var refreshButton: some View {
        Button {
            Task { await monitor.refreshNow() }
        } label: {
            if monitor.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "arrow.clockwise")
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .disabled(monitor.isRefreshing)
        .help("지금 새로고침")
        .accessibilityLabel("지금 새로고침")
        .keyboardShortcut("r", modifiers: .command)
    }

    private var currentFeedback: (message: String, isError: Bool)? {
        if let feedback = menuActionFeedback { return (feedback.message, feedback.isError) }
        if let feedback = monitor.actionFeedback { return (feedback.message, feedback.kind == .error) }
        return nil
    }

    private var outcomeBanner: (text: String, isError: Bool)? {
        let failures = outcomeSummaries.filter(\.isError)
        guard let first = failures.first else { return nil }
        let extra = failures.count > 1 ? " 외 \(failures.count - 1)건" : ""
        return (first.text + extra, true)
    }

    private var gaugeColor: Color {
        if monitor.systemCPUPercent >= 80 { return .red }
        if monitor.systemCPUPercent >= 55 { return .orange }
        return .mint
    }

    private var memorySummary: String {
        guard let memory = monitor.systemMemory else { return "--" }
        let used = WatchdogFormatters.memory.string(fromByteCount: Int64(memory.usedBytes))
        let total = WatchdogFormatters.memory.string(fromByteCount: Int64(memory.totalBytes))
        return "\(used)/\(total)"
    }

    private var memoryPressureColor: Color {
        switch monitor.systemMemory?.pressureLevel {
        case .normal: return .mint
        case .warning: return .orange
        case .critical: return .red
        case .unknown, nil: return .secondary
        }
    }

    @ViewBuilder
    private func feedbackBanner(_ message: String, isError: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .accessibilityHidden(true)
            Text(message)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(isError ? Color.red : Color.green)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            (isError ? Color.red : Color.green).opacity(0.09),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var outcomeSummaries: [ProcessOutcomeSummary] {
        let monitored = monitor.actionOutcomes
            .map { entry in
                ProcessOutcomeSummary(
                    identity: entry.key,
                    text: "PID \(entry.key.pid) · \(entry.value.localizedDescription)",
                    isError: entry.value.isError
                )
            }
        let failures: [ProcessOutcomeSummary] = localActionFailures.compactMap { entry in
            guard monitor.actionOutcomes[entry.key] == nil else { return nil }
            return ProcessOutcomeSummary(
                identity: entry.key,
                text: "PID \(entry.key.pid) · 작업 실패: \(entry.value.message)",
                isError: true
            )
        }
        return (monitored + failures).sorted { $0.identity.pid < $1.identity.pid }
    }

    private func recentActionSymbol(_ action: ActionJournalEntry.ActionKind) -> String {
        switch action {
        case .suspend: "pause.fill"
        case .resume: "play.fill"
        case .terminate: "xmark.circle"
        case .forceQuit: "bolt.trianglebadge.exclamationmark"
        }
    }

    private func recentActionTitle(_ entry: ActionJournalEntry) -> String {
        let action = JournalPresentation.actionLabel(entry.action)
        if let reason = entry.reason, !reason.isEmpty {
            return "\(entry.displayName) \(action) · \(reason)"
        }
        return "\(entry.displayName) \(action)"
    }

    private func relativeTime(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .short
        return formatter
    }()

    private func openWindow(section: WindowSection? = nil) {
        dismiss()
        if let section {
            WatchdogWindowOpener.openMainWindow(section: section)
        } else {
            WatchdogWindowOpener.openMainWindow()
        }
    }

    private func prepareDestructiveAction(
        _ action: ProcessControlAction,
        process: ProcessSnapshot,
        kind: PendingProcessAction.Kind
    ) {
        do {
            let request = try monitor.destructiveActionRequest(action, for: process)
            focusAfterConfirmation = focusedRow ?? .process(process.identity)
            focusedRow = nil
            pendingAction = PendingProcessAction(
                process: process,
                kind: kind,
                confirmationRequest: request
            )
        } catch {
            recordLocalActionFailure(error.localizedDescription, for: process.identity)
            showMenuFeedback(.init(isError: true, message: error.localizedDescription))
        }
    }

    private func completeDestructiveAction(_ pending: PendingProcessAction) {
        Task {
            do {
                try await monitor.completeDestructiveConfirmation(pending.confirmationRequest)
                localActionFailures.removeValue(forKey: pending.process.identity)
                let message: String
                switch pending.kind {
                case .terminate:
                    message = "종료 신호를 전달했습니다 · 종료 여부를 확인 중입니다"
                case .forceQuit:
                    message = "강제 종료 신호를 전달했습니다 · 종료 여부를 확인 중입니다"
                }
                showMenuFeedback(.init(isError: false, message: message))
            } catch {
                recordLocalActionFailure(
                    error.localizedDescription,
                    for: pending.process.identity
                )
                showMenuFeedback(.init(isError: true, message: error.localizedDescription))
            }
        }
    }

    private func cancelDestructiveAction(_ pending: PendingProcessAction) {
        pendingAction = nil
        monitor.cancelDestructiveConfirmation(pending.confirmationRequest)
        restoreFocusAfterConfirmation()
    }

    private func restoreFocusAfterConfirmation() {
        focusedRow = focusAfterConfirmation
        focusAfterConfirmation = nil
    }

    private func focusOrder() -> [WatchdogFocusTarget] {
        var order: [WatchdogFocusTarget] = monitor.visibleSessions(limit: sessionLimit).map { .session($0.id) }
        order.append(contentsOf: monitor.orphans(limit: orphanLimit).map { .process($0.identity) })
        order.append(contentsOf: Array(monitor.journalEntries.prefix(recentLimit)).map { .journal($0.id) })
        return order
    }

    private func firstFocusTarget() -> WatchdogFocusTarget? {
        focusOrder().first
    }

    private func moveFocus(_ direction: MoveCommandDirection) {
        let order = focusOrder()
        guard !order.isEmpty else { return }
        guard let current = focusedRow, let index = order.firstIndex(of: current) else {
            focusedRow = order.first
            return
        }
        switch direction {
        case .up:
            if index > 0 { focusedRow = order[index - 1] }
        case .down:
            if index + 1 < order.count { focusedRow = order[index + 1] }
        default:
            break
        }
    }

    private func actionOutcome(for process: ProcessSnapshot) -> ProcessActionOutcome? {
        if let outcome = monitor.actionOutcomes[process.identity] {
            return outcome
        }
        return localActionFailures[process.identity].map { .failed($0.message) }
    }

    private func showMenuFeedback(_ feedback: MenuActionFeedback) {
        menuActionFeedback = feedback
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard menuActionFeedback?.id == feedback.id else { return }
            menuActionFeedback = nil
        }
    }

    private func recordLocalActionFailure(
        _ message: String,
        for identity: ProcessIdentity
    ) {
        let failure = LocalActionFailure(message: message)
        localActionFailures[identity] = failure
        Task {
            try? await Task.sleep(for: .seconds(30))
            guard localActionFailures[identity]?.id == failure.id else { return }
            localActionFailures[identity] = nil
        }
    }
}
