import SwiftUI

enum ProcessListFilter: String, CaseIterable, Identifiable {
    case all = "전체"
    case agents = "에이전트"
    case service = "서비스"
    case application = "앱"
    case system = "시스템"
    case orphan = "고아"
    case attention = "주의"

    var id: String { rawValue }

    var accessibilityIdentifier: String {
        switch self {
        case .all: "watchdog.processes.filter.all"
        case .agents: "watchdog.processes.filter.agents"
        case .service: "watchdog.processes.filter.service"
        case .application: "watchdog.processes.filter.application"
        case .system: "watchdog.processes.filter.system"
        case .orphan: "watchdog.processes.filter.orphan"
        case .attention: "watchdog.processes.filter.attention"
        }
    }
}

enum ProcessListSort: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "메모리"
    case name = "이름"
    case pid = "PID"

    var id: String { rawValue }
}

enum ProcessesPresentation {
    struct AttentionContext {
        var hot: Set<ProcessIdentity>
        var highMemory: Set<ProcessIdentity>
        var watchdogStopped: Set<ProcessIdentity>
        var ignored: Set<ProcessIdentity>
    }

    static func rowIdentifier(_ process: ProcessSnapshot) -> String {
        "process.\(process.id).\(process.startTimeMicroseconds).row"
    }

    static func matches(_ process: ProcessSnapshot, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return true }
        let needle = query.lowercased()
        if process.displayName.lowercased().contains(needle) { return true }
        if String(process.id).contains(needle) { return true }
        if process.projectName?.lowercased().contains(needle) == true { return true }
        if process.launchScript?.lowercased().contains(needle) == true { return true }
        if process.agentAncestor?.name.lowercased().contains(needle) == true { return true }
        if process.executablePath.lowercased().contains(needle) { return true }
        return false
    }

    static func includes(
        _ process: ProcessSnapshot,
        filter: ProcessListFilter,
        attention: AttentionContext
    ) -> Bool {
        switch filter {
        case .all:
            true
        case .agents:
            process.kind == .agent || (process.kind == .service && process.agentName != nil)
        case .service:
            process.kind == .service
        case .application:
            process.kind == .application || process.kind == .browserRenderer
        case .system:
            process.kind == .system
        case .orphan:
            process.suspectedOrphan
        case .attention:
            !attention.ignored.contains(process.identity)
                && (attention.hot.contains(process.identity)
                    || attention.highMemory.contains(process.identity)
                    || attention.watchdogStopped.contains(process.identity))
        }
    }

    static func displayed(
        processes: [ProcessSnapshot],
        search: String,
        filter: ProcessListFilter,
        sort: ProcessListSort,
        attention: AttentionContext
    ) -> [ProcessSnapshot] {
        let filtered = processes.filter {
            matches($0, search: search) && includes($0, filter: filter, attention: attention)
        }
        return sorted(filtered, by: sort)
    }

    static func sorted(_ processes: [ProcessSnapshot], by sort: ProcessListSort) -> [ProcessSnapshot] {
        processes.enumerated().sorted { lhs, rhs in
            let order = compare(lhs.element, rhs.element, by: sort)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    static func emptyTitle(search: String, filter: ProcessListFilter) -> String {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "검색 결과가 없습니다"
        }
        switch filter {
        case .attention: return "확인할 프로세스가 없습니다"
        case .agents: return "에이전트 프로세스가 없습니다"
        case .all: return "일치하는 프로세스가 없습니다"
        case .service: return "서비스 프로세스가 없습니다"
        case .application: return "앱 프로세스가 없습니다"
        case .system: return "시스템 프로세스가 없습니다"
        case .orphan: return "고아 프로세스가 없습니다"
        }
    }

    static func emptyMessage(search: String, filter: ProcessListFilter) -> String {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "다른 프로세스 이름, PID 또는 프로젝트를 검색해보세요."
        }
        switch filter {
        case .attention:
            return "CPU 또는 메모리 사용량이 오래 높거나 고아로 의심되는 에이전트를 표시합니다."
        case .agents:
            return "지원하는 코딩 에이전트를 실행하거나 검색어를 바꿔보세요."
        case .all:
            return "다른 프로세스 이름, PID 또는 프로젝트를 검색해보세요."
        case .service:
            return "실행 중인 서비스가 있으면 여기에 표시합니다."
        case .application:
            return "실행 중인 앱을 찾거나 필터를 바꿔보세요."
        case .system:
            return "시스템 프로세스가 있으면 여기에 표시합니다."
        case .orphan:
            return "고아로 의심되는 프로세스가 있으면 여기에 표시합니다."
        }
    }

    static func nameAnnotation(_ process: ProcessSnapshot) -> String? {
        if process.kind == .service { return "서비스" }
        if process.kind != .agent { return "추정" }
        return nil
    }

    static func iconName(_ process: ProcessSnapshot) -> String {
        switch process.kind {
        case .agent: "terminal"
        case .service: "server.rack"
        case .browserRenderer: "globe"
        case .application: "macwindow"
        case .system: "gearshape.2"
        case .other: "waveform.path.ecg"
        }
    }

    private static func compare(_ lhs: ProcessSnapshot, _ rhs: ProcessSnapshot, by sort: ProcessListSort) -> ComparisonResult {
        switch sort {
        case .cpu:
            if lhs.cpuPercent != rhs.cpuPercent {
                return lhs.cpuPercent > rhs.cpuPercent ? .orderedAscending : .orderedDescending
            }
        case .memory:
            if lhs.residentBytes != rhs.residentBytes {
                return lhs.residentBytes > rhs.residentBytes ? .orderedAscending : .orderedDescending
            }
        case .name:
            let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if order != .orderedSame { return order }
        case .pid:
            if lhs.id != rhs.id {
                return lhs.id < rhs.id ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }
}

private struct ProcessTableRow: Identifiable {
    let process: ProcessSnapshot
    var id: String { ProcessesPresentation.rowIdentifier(process) }
}

private struct LocalActionFailure {
    let id = UUID()
    let message: String
}

struct ProcessesView: View {
    @ObservedObject var monitor: ProcessMonitor
    @State private var searchText = ""
    @State private var filter: ProcessListFilter = .all
    @State private var sort: ProcessListSort = .cpu
    @State private var displayed: [ProcessSnapshot] = []
    @State private var isVisible = false
    @State private var selection: ProcessTableRow.ID?
    @State private var pendingAction: PendingProcessAction?
    @State private var localActionFailures: [ProcessIdentity: LocalActionFailure] = [:]
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 12) {
                header
                if isObservationStale {
                    staleBanner
                }
                if let feedback = monitor.actionFeedback {
                    feedbackBanner(feedback.message, isError: feedback.kind == .error)
                }
                if displayed.isEmpty {
                    emptyState
                } else {
                    table
                    detailPanel
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .disabled(pendingAction != nil)
            .accessibilityHidden(pendingAction != nil)

            if let pendingAction {
                DestructiveConfirmationCard(
                    action: pendingAction,
                    onCancel: { cancelDestructiveAction(pendingAction) },
                    onConfirm: {
                        self.pendingAction = nil
                        completeDestructiveAction(pendingAction)
                    }
                )
            }
        }
        .focusable()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchdog.window.detail.processes")
        .dismissInvalidDestructiveConfirmation(pendingAction: $pendingAction, monitor: monitor)
        .onAppear {
            isVisible = true
            recompute()
            #if DEBUG
            ProcessesUITestObserver.shared.install()
            ProcessesUITestObserver.shared.onClearSearch = { searchText = "" }
            ProcessesUITestObserver.shared.onSelectAgents = { filter = .agents }
            #endif
        }
        .onDisappear {
            isVisible = false
            #if DEBUG
            ProcessesUITestObserver.shared.onClearSearch = nil
            ProcessesUITestObserver.shared.onSelectAgents = nil
            #endif
        }
        .onChange(of: monitor.processes) { _, _ in recompute() }
        .onChange(of: monitor.hotProcesses) { _, _ in recompute() }
        .onChange(of: monitor.highMemoryProcesses) { _, _ in recompute() }
        .onChange(of: monitor.watchdogSuspended) { _, _ in recompute() }
        .onChange(of: searchText) { _, _ in recompute() }
        .onChange(of: filter) { _, _ in recompute() }
        .onChange(of: sort) { _, _ in recompute() }
        .onKeyPress(.escape) {
            guard pendingAction == nil, !searchText.isEmpty else { return .ignored }
            searchText = ""
            return .handled
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("전체 프로세스")
                    .font(.title2)
                Spacer()
                Text("\(displayed.count)개")
                    .foregroundStyle(.secondary)
                sortMenu
                refreshButton
                    .keyboardShortcut("r", modifiers: .command)
            }

            HStack(spacing: 8) {
                TextField("프로세스, PID 또는 프로젝트 검색", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .accessibilityIdentifier("watchdog.processes.search")
                    .background {
                        Button("검색") {
                            searchFocused = true
                        }
                        .keyboardShortcut("f", modifiers: .command)
                        .opacity(0)
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("검색 지우기")
                    .accessibilityLabel("검색 지우기")
                    .accessibilityIdentifier("watchdog.processes.search.clear")
                }
            }

            Picker("필터", selection: $filter) {
                ForEach(ProcessListFilter.allCases) { option in
                    Text(option.rawValue)
                        .tag(option)
                        .accessibilityIdentifier(option.accessibilityIdentifier)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("watchdog.processes.filter")
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("정렬", selection: $sort) {
                ForEach(ProcessListSort.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
        } label: {
            Label("정렬", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("목록 정렬")
        .accessibilityLabel("정렬")
        .accessibilityIdentifier("watchdog.processes.sort")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ProcessesPresentation.emptyTitle(search: searchText, filter: filter))
                .font(.headline)
            Text(ProcessesPresentation.emptyMessage(search: searchText, filter: filter))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 24)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchdog.processes.empty")
    }

    private var table: some View {
        Table(tableRows, selection: $selection) {
            TableColumn("이름") { row in
                nameCell(row.process)
            }
            .width(min: 140, ideal: 200)
            TableColumn("종류") { row in
                Text(SessionsPresentation.kindLabel(row.process.kind))
                    .lineLimit(1)
            }
            .width(min: 56, ideal: 72)
            TableColumn("PID") { row in
                Text("\(row.process.id)")
                    .monospacedDigit()
            }
            .width(min: 52, ideal: 64)
            TableColumn("프로젝트") { row in
                Text(row.process.projectName ?? "—")
                    .lineLimit(1)
            }
            .width(min: 72, ideal: 96)
            TableColumn("CPU") { row in
                Text("\(Int(row.process.cpuPercent.rounded()))%")
                    .monospacedDigit()
            }
            .width(min: 52, ideal: 64)
            TableColumn("메모리") { row in
                Text(WatchdogFormatters.memory.string(fromByteCount: Int64(row.process.residentBytes)))
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 80)
            TableColumn("상태") { row in
                statusCell(row.process)
            }
            .width(min: 120, ideal: 180)
            TableColumn("시작 후") { row in
                Text(row.process.elapsed)
                    .foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 80)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .animation(reduceMotion ? nil : .default, value: displayed.map(ProcessesPresentation.rowIdentifier))
        .contextMenu(forSelectionType: ProcessTableRow.ID.self) { ids in
            if let id = ids.first, let process = process(for: id) {
                contextMenu(for: process)
            }
        }
    }

    private var detailPanel: some View {
        let selected = selection.flatMap(process(for:))
        return ProcessDetailPanel(
            process: selected,
            reasons: selected.map { monitor.alertReasons(for: $0) } ?? [],
            identifier: "watchdog.processes.detail"
        )
    }

    private var tableRows: [ProcessTableRow] {
        displayed.map { ProcessTableRow(process: $0) }
    }

    @ViewBuilder
    private func nameCell(_ process: ProcessSnapshot) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ProcessesPresentation.iconName(process))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(process.displayName)
                .lineLimit(1)
            if let annotation = ProcessesPresentation.nameAnnotation(process) {
                Text(annotation)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityLabel(accessibilityLabel(for: process))
        .accessibilityIdentifier(ProcessesPresentation.rowIdentifier(process))
    }

    @ViewBuilder
    private func statusCell(_ process: ProcessSnapshot) -> some View {
        let parts = statusParts(for: process)
        if parts.isEmpty {
            Text("—")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Text(part)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor(part).opacity(0.12), in: Capsule())
                        .foregroundStyle(statusColor(part))
                }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for process: ProcessSnapshot) -> some View {
        let canAct = monitor.actionability(of: process).canAct
        let ignored = monitor.isIgnored(process)
        if ignored {
            Button("다시 감시") {
                monitor.undoIgnore(process)
            }
        } else {
            Button(process.isSuspended ? "재개" : "일시 정지") {
                if process.isSuspended {
                    monitor.resume(process)
                } else {
                    monitor.suspend(process)
                }
            }
            .disabled(!canAct)
            Button("종료할 때까지 무시") {
                monitor.ignoreUntilExit(process)
            }
            .disabled(!canAct)
            Divider()
            Button("종료…") {
                prepareDestructiveAction(.terminate, process: process, kind: .terminate)
            }
            .disabled(!canAct)
            Button("강제 종료…", role: .destructive) {
                prepareDestructiveAction(.forceQuit, process: process, kind: .forceQuit)
            }
            .disabled(!canAct)
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await monitor.refreshNow() }
        } label: {
            if monitor.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .disabled(monitor.isRefreshing)
        .help("지금 새로고침")
        .accessibilityLabel("지금 새로고침")
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

    private var staleBanner: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("관찰 정보가 오래되어 새로고침 후 제어할 수 있습니다")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(2)
            Spacer(minLength: 8)
            refreshButton
        }
        .accessibilityElement(children: .combine)
    }

    private var isObservationStale: Bool {
        if monitor.samplingError != nil { return true }
        if let first = monitor.processes.first {
            return monitor.actionability(of: first).freshness != .current
        }
        return false
    }

    private func recompute() {
        guard isVisible else { return }
        displayed = ProcessesPresentation.displayed(
            processes: monitor.processes,
            search: searchText,
            filter: filter,
            sort: sort,
            attention: attentionContext
        )
    }

    private var attentionContext: ProcessesPresentation.AttentionContext {
        ProcessesPresentation.AttentionContext(
            hot: monitor.hotProcesses,
            highMemory: monitor.highMemoryProcesses,
            watchdogStopped: Set(monitor.watchdogSuspended.map(\.identity)),
            ignored: Set(monitor.processes.filter { monitor.isIgnored($0) }.map(\.identity))
        )
    }

    private func process(for id: ProcessTableRow.ID) -> ProcessSnapshot? {
        displayed.first { ProcessesPresentation.rowIdentifier($0) == id }
    }

    private func statusParts(for process: ProcessSnapshot) -> [String] {
        var parts = SessionsPresentation.statusParts(
            reasons: monitor.alertReasons(for: process),
            isSuspended: process.isSuspended,
            isSuspendedByWatchdog: monitor.isSuspendedByWatchdog(process),
            outcome: actionOutcome(for: process)
        )
        if let feedback = monitor.actionFeedback,
           selection == ProcessesPresentation.rowIdentifier(process) {
            parts.append(feedback.message)
        }
        return parts
    }

    private func statusColor(_ part: String) -> Color {
        if part.contains("CPU") { return .red }
        if part.contains("메모리") { return .purple }
        if part.contains("고아") { return .orange }
        if part.contains("실패") || part.contains("실행 중") { return .red }
        if part.contains("멈춤") || part.contains("정지") { return .blue }
        return .secondary
    }

    private func accessibilityLabel(for process: ProcessSnapshot) -> String {
        if process.kind == .service {
            return "서비스, \(process.displayName), PID \(process.id)"
        }
        return "\(process.displayName), PID \(process.id)"
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
        }
    }

    private func completeDestructiveAction(_ pending: PendingProcessAction) {
        Task {
            do {
                try await monitor.completeDestructiveConfirmation(pending.confirmationRequest)
                localActionFailures.removeValue(forKey: pending.process.identity)
            } catch {
                recordLocalActionFailure(error.localizedDescription, for: pending.process.identity)
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

    private func recordLocalActionFailure(_ message: String, for identity: ProcessIdentity) {
        let failure = LocalActionFailure(message: message)
        localActionFailures[identity] = failure
        Task {
            try? await Task.sleep(for: .seconds(30))
            guard localActionFailures[identity]?.id == failure.id else { return }
            localActionFailures[identity] = nil
        }
    }
}

#if DEBUG
final class ProcessesUITestObserver: NSObject, @unchecked Sendable {
    static let shared = ProcessesUITestObserver()
    static let clearSearch = Notification.Name("dev.justn.watchdog.uitest.clear-search")
    static let selectAgents = Notification.Name("dev.justn.watchdog.uitest.select-agents-filter")
    static let showProcesses = Notification.Name("dev.justn.watchdog.uitest.show-processes")

    var onClearSearch: (@MainActor () -> Void)?
    var onSelectAgents: (@MainActor () -> Void)?
    var onShowProcesses: (@MainActor () -> Void)?
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        let center = DistributedNotificationCenter.default()
        center.addObserver(
            self,
            selector: #selector(handleClearSearch),
            name: Self.clearSearch,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        center.addObserver(
            self,
            selector: #selector(handleSelectAgents),
            name: Self.selectAgents,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        center.addObserver(
            self,
            selector: #selector(handleShowProcesses),
            name: Self.showProcesses,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func handleClearSearch(_ notification: Notification) {
        Task { @MainActor in ProcessesUITestObserver.shared.onClearSearch?() }
    }

    @objc private func handleSelectAgents(_ notification: Notification) {
        Task { @MainActor in ProcessesUITestObserver.shared.onSelectAgents?() }
    }

    @objc private func handleShowProcesses(_ notification: Notification) {
        Task { @MainActor in ProcessesUITestObserver.shared.onShowProcesses?() }
    }
}
#endif
