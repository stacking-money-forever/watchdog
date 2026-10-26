import AppKit
import SwiftUI

private struct PendingProcessAction: Identifiable {
    enum Kind {
        case terminate
        case forceQuit
    }

    let id = UUID()
    let process: ProcessSnapshot
    let kind: Kind
    let confirmationRequest: DestructiveActionConfirmationRequest

    var title: String {
        switch kind {
        case .terminate: return "프로세스를 종료할까요?"
        case .forceQuit: return "프로세스를 강제 종료할까요?"
        }
    }

    var message: String {
        switch kind {
        case .terminate:
            return "\(process.displayName) · PID \(process.id)\nSIGTERM을 보내 정리 후 종료할 기회를 줍니다."
        case .forceQuit:
            return "\(process.displayName) · PID \(process.id)\nSIGKILL을 보내 즉시 종료합니다. 저장하지 않은 작업은 사라집니다."
        }
    }
}

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
    @State private var scope: ProcessScope = .attention
    @State private var search = ""
    @State private var showsRules = false
    @State private var pendingAction: PendingProcessAction?
    @State private var menuActionFeedback: MenuActionFeedback?
    @State private var localActionFailures: [ProcessIdentity: LocalActionFailure] = [:]

    init(monitor: ProcessMonitor, launchAtLogin: LaunchAtLoginController) {
        self.monitor = monitor
        self._launchAtLogin = ObservedObject(wrappedValue: launchAtLogin)
    }

    private var visibleProcesses: [ProcessSnapshot] {
        monitor.visibleProcesses(scope: scope, search: search)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                controls
                processList
                Divider()
                footer
            }
            .disabled(pendingAction != nil)
            .accessibilityHidden(pendingAction != nil)

            if let pendingAction {
                destructiveConfirmation(for: pendingAction)
            }
        }
        // A pending confirmation must survive the popup closing (focus loss);
        // it is only cancelled explicitly or when its 30 s validity expires.
        .onReceive(monitor.$processes) { _ in
            dismissConfirmationIfInvalid()
        }
        .onAppear {
            monitor.isPresented = true
            monitor.refreshNotificationAuthorization()
            launchAtLogin.refresh()
        }
        .onDisappear {
            monitor.isPresented = false
        }
    }

    /// A confirmation whose window expired or whose process is gone can only
    /// fail; close it and say why instead of leaving the list disabled.
    private func dismissConfirmationIfInvalid() {
        guard let pending = pendingAction,
              !monitor.isConfirmationValid(pending.confirmationRequest)
        else { return }
        pendingAction = nil
        monitor.cancelDestructiveConfirmation(pending.confirmationRequest)
        let stillListed = monitor.processes.contains { $0.identity == pending.process.identity }
        let message = stillListed
            ? ProcessControlError.confirmationExpired.localizedDescription
            : ProcessControlError.processChanged.localizedDescription
        showMenuFeedback(.init(isError: true, message: message))
    }


    private func destructiveConfirmation(for action: PendingProcessAction) -> some View {
        ZStack {
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 16) {
                Text(action.title)
                    .font(.headline)

                Text(action.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()

                    Button("취소") {
                        cancelDestructiveAction(action)
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(action.kind == .terminate ? "종료" : "강제 종료", role: .destructive) {
                        pendingAction = nil
                        completeDestructiveAction(action)
                    }
                    .accessibilityIdentifier("watchdog.destructive-confirmation.confirm")
                }
            }
            .padding(20)
            .frame(width: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.separator.opacity(0.7))
            }
            .shadow(radius: 18, y: 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchdog.destructive-confirmation")
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Watchdog")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .accessibilityIdentifier("watchdog.header")
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }

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
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Picker("범위", selection: $scope) {
                ForEach(ProcessScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("프로세스, PID 또는 프로젝트 검색", text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("watchdog.search")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))

            DisclosureGroup("감지 규칙", isExpanded: $showsRules) {
                VStack(spacing: 10) {
                    HStack {
                        Text("CPU 임계값")
                        Spacer()
                        Text("\(Int(monitor.threshold))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $monitor.threshold, in: min(25, monitor.threshold)...max(300, monitor.threshold), step: 5)

                    HStack {
                        Text("프로세스 메모리 임계값")
                        Spacer()
                        Text("\(monitor.memoryThresholdGB, specifier: "%.1f")GB")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $monitor.memoryThresholdGB, in: min(0.5, monitor.memoryThresholdGB)...max(16, monitor.memoryThresholdGB), step: 0.5)

                    Stepper(
                        "임계값 유지 시간: \(Int(monitor.sustainedDuration))초",
                        value: $monitor.sustainedDuration,
                        // A value set from the CLI or defaults may sit outside
                        // the usual range; keep it reachable and visible.
                        in: min(5, monitor.sustainedDuration)...max(120, monitor.sustainedDuration),
                        step: 5
                    )
                    Toggle("CPU 폭주 에이전트 자동 일시 정지", isOn: $monitor.autoSuspendEnabled)
                        .help("CPU 임계값을 지속해서 넘긴 코딩 에이전트에만 SIGSTOP을 보냅니다. 메모리만 넘긴 프로세스와 일반 앱은 멈추지 않으며, 직접 재개한 프로세스는 다시 멈추지 않습니다.")
                    Toggle("시스템 알림", isOn: $monitor.notificationsEnabled)
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
                    if launchAtLogin.requiresApproval {
                        Text("시스템 설정의 로그인 항목에서 승인이 필요합니다")
                            .foregroundStyle(.orange)
                    } else if let errorMessage = launchAtLogin.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .padding(.top, 8)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// At most one transient message: an explicit menu action wins over a
    /// background one.
    private var currentFeedback: (message: String, isError: Bool)? {
        if let feedback = menuActionFeedback { return (feedback.message, feedback.isError) }
        if let feedback = monitor.actionFeedback { return (feedback.message, feedback.kind == .error) }
        return nil
    }

    /// Rows show their own outcome, so the banner only summarizes failures,
    /// one line at most, so stacked banners can never squeeze the list away.
    private var outcomeBanner: (text: String, isError: Bool)? {
        let failures = outcomeSummaries.filter(\.isError)
        guard let first = failures.first else { return nil }
        let extra = failures.count > 1 ? " 외 \(failures.count - 1)건" : ""
        return (first.text + extra, true)
    }

    private var processList: some View {
        let visible = visibleProcesses
        return VStack(spacing: 8) {
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
            } else if visible.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: scope == .attention ? "checkmark.shield" : "magnifyingglass",
                    description: Text(emptyDescription)
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        // Keyed by full identity, not PID: a reused PID is a
                        // different row and never inherits another's controls.
                        ForEach(visible, id: \.identity) { process in
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
                                onUndoIgnore: { monitor.undoIgnore(process) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
                .accessibilityIdentifier("watchdog.process-list")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            if let lastUpdated = monitor.lastUpdated {
                Text(observationText(lastUpdated))
            } else {
                Text("프로세스 확인 중…")
            }

            Spacer()

            Button {
                Task { await monitor.refresh() }
            } label: {
                if monitor.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .disabled(monitor.isRefreshing)
            .help("지금 새로고침")
            .accessibilityLabel("지금 새로고침")

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
            .accessibilityIdentifier("watchdog.quit")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        if monitor.alertCount == 0 { return "감시 중인 프로세스가 안정적입니다" }
        return "\(monitor.alertCount)개 프로세스를 확인해야 합니다"
    }

    private var statusColor: Color {
        monitor.alertCount == 0 ? .secondary : .orange
    }

    private var gaugeColor: Color {
        if monitor.systemCPUPercent >= 80 { return .red }
        if monitor.systemCPUPercent >= 55 { return .orange }
        return .mint
    }

    private var emptyTitle: String {
        if !search.isEmpty { return "검색 결과가 없습니다" }
        return switch scope {
        case .attention: "확인할 프로세스가 없습니다"
        case .agents: "에이전트 프로세스가 없습니다"
        case .all: "일치하는 프로세스가 없습니다"
        }
    }

    private var emptyDescription: String {
        if !search.isEmpty { return "다른 프로세스 이름, PID 또는 프로젝트를 검색해보세요." }
        return switch scope {
        case .attention: "CPU 또는 메모리 사용량이 오래 높은 프로세스를 표시합니다."
        case .agents: "지원하는 코딩 에이전트를 실행하거나 검색어를 바꿔보세요."
        case .all: "다른 프로세스 이름, PID 또는 프로젝트를 검색해보세요."
        }
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
                    text: "PID \(entry.key.pid) · \(outcomeText(entry.value))",
                    isError: outcomeIsError(entry.value)
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

    private func outcomeText(_ outcome: ProcessActionOutcome) -> String {
        outcome.localizedDescription
    }

    private func outcomeIsError(_ outcome: ProcessActionOutcome) -> Bool {
        outcome.isError
    }

    private func observationText(_ lastUpdated: Date) -> String {
        let age = max(0, Int(Date().timeIntervalSince(lastUpdated)))
        let freshness = age < 1 ? "방금 관찰" : "\(age)초 전 관찰"
        return "\(freshness) · \(WatchdogFormatters.updatedTime.string(from: lastUpdated))"
    }

    private func prepareDestructiveAction(
        _ action: ProcessControlAction,
        process: ProcessSnapshot,
        kind: PendingProcessAction.Kind
    ) {
        do {
            let request = try monitor.destructiveActionRequest(action, for: process)
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
