import AppKit
import SwiftUI

enum SessionsPresentation {
    static func summary(sessionCount: Int, warningCount: Int) -> String {
        "세션 \(sessionCount)개 · 주의 \(warningCount)개"
    }

    static func identityToken(_ identity: ProcessIdentity) -> String {
        "\(identity.pid):\(identity.startTimeMicroseconds):\(identity.userID)"
    }

    static func kindLabel(_ kind: ProcessKind) -> String {
        switch kind {
        case .agent: "에이전트"
        case .service: "서비스"
        default: "추정"
        }
    }

    static func reasonBadgeText(_ reason: AlertReason) -> String {
        switch reason {
        case .sustainedCPU: "CPU 높음"
        case .sustainedMemory: "메모리 높음"
        case .orphan: "고아"
        }
    }

    static func statusParts(
        reasons: [AlertReason],
        isSuspended: Bool,
        isSuspendedByWatchdog: Bool,
        outcome: ProcessActionOutcome?
    ) -> [String] {
        var parts = reasons.map(reasonBadgeText)
        if isSuspended {
            parts.append(isSuspendedByWatchdog ? "Watchdog이 정지함" : "멈춤")
        }
        if let outcome {
            parts.append(outcome.localizedDescription)
        }
        return parts
    }

    static func sessionAccessibilityLabel(
        name: String,
        projectName: String?,
        cpuPercent: Double,
        residentBytes: UInt64,
        reasons: [AlertReason],
        memberCount: Int
    ) -> String {
        let project = projectName.map { "\($0) 프로젝트" } ?? "프로젝트 없음"
        let memory = ByteCountFormatter.string(fromByteCount: Int64(clamping: residentBytes), countStyle: .memory)
        var sentence = "\(name), \(project), CPU \(Int(cpuPercent.rounded()))퍼센트, 메모리 \(memory)"
        if let first = reasons.first {
            sentence += ", 주의: \(first.text)"
        }
        sentence += ", 자식 \(memberCount)개"
        return sentence
    }
}

private struct SessionTableNode: Identifiable, Hashable {
    enum Kind: Hashable {
        case session(ProcessIdentity)
        case member(ProcessIdentity)
    }

    let kind: Kind
    var children: [SessionTableNode]?

    var id: String {
        switch kind {
        case let .session(identity):
            "session.\(identity.pid).\(identity.startTimeMicroseconds).row"
        case let .member(identity):
            "process.\(identity.pid).\(identity.startTimeMicroseconds).row"
        }
    }

    var identity: ProcessIdentity {
        switch kind {
        case let .session(identity), let .member(identity):
            identity
        }
    }
}

private struct LocalActionFailure {
    let id = UUID()
    let message: String
}

struct SessionsView: View {
    @ObservedObject var monitor: ProcessMonitor
    @State private var selection: SessionTableNode.ID?
    @State private var pendingAction: PendingProcessAction?
    @State private var localActionFailures: [ProcessIdentity: LocalActionFailure] = [:]
    @FocusState private var tableFocused: Bool
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
                if monitor.sessions.isEmpty {
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
                        tableFocused = true
                    }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchdog.window.detail.sessions")
        .dismissInvalidDestructiveConfirmation(pendingAction: $pendingAction, monitor: monitor)
        .onKeyPress(.space) {
            performPrimaryAction()
            return .handled
        }
        .onKeyPress(.return) {
            toggleSelectedOutlineExpansion()
            return .handled
        }
        .focusable()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("에이전트 세션")
                    .font(.title2)
                Text(SessionsPresentation.summary(sessionCount: monitor.sessions.count, warningCount: warningCount))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            refreshButton
        }
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

    private var emptyState: some View {
        Text("실행 중인 코딩 에이전트가 없습니다")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 24)
            .accessibilityIdentifier("watchdog.sessions.empty")
    }

    private var table: some View {
        Table(tableNodes, children: \.children, selection: $selection) {
            TableColumn("이름") { node in
                nameCell(node)
            }
            .width(min: 120, ideal: 160)
            TableColumn("프로젝트") { node in
                Text(projectName(for: node) ?? "—")
                    .lineLimit(1)
            }
            .width(min: 72, ideal: 96)
            TableColumn("CPU") { node in
                Text(cpuText(for: node))
                    .monospacedDigit()
            }
            .width(min: 52, ideal: 64)
            TableColumn("메모리") { node in
                Text(memoryText(for: node))
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 80)
            TableColumn("자식") { node in
                Text(childCountText(for: node))
                    .monospacedDigit()
            }
            .width(min: 44, ideal: 52)
            TableColumn("상태") { node in
                statusCell(node)
            }
            .width(min: 120, ideal: 180)
            TableColumn("시작 후") { node in
                Text(elapsedText(for: node))
                    .foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 80)
            TableColumn("조치") { node in
                primaryActionCell(node)
            }
            .width(min: 108, ideal: 120)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .focused($tableFocused)
        .animation(reduceMotion ? nil : .default, value: monitor.sessions.map(\.id))
        .contextMenu(forSelectionType: SessionTableNode.ID.self) { ids in
            if let id = ids.first, let node = node(for: id), let process = process(for: node) {
                contextMenu(for: process, node: node)
            }
        }
    }

    private var detailPanel: some View {
        let selected: (ProcessSnapshot, [AlertReason])? = {
            guard let selection, let node = node(for: selection), let process = process(for: node) else {
                return nil
            }
            let reasons: [AlertReason]
            if case .session = node.kind, let session = session(for: node) {
                reasons = monitor.sessionAlertReasons(session)
            } else {
                reasons = monitor.alertReasons(for: process)
            }
            return (process, reasons)
        }()
        return ProcessDetailPanel(
            process: selected?.0,
            reasons: selected?.1 ?? [],
            identifier: "watchdog.sessions.detail"
        )
    }

    @ViewBuilder
    private func nameCell(_ node: SessionTableNode) -> some View {
        let title: String = {
            switch node.kind {
            case .session:
                session(for: node)?.name ?? "—"
            case .member:
                process(for: node)?.displayName ?? "—"
            }
        }()
        Text(title)
            .lineLimit(1)
            .accessibilityLabel(accessibilityLabel(for: node))
            .accessibilityIdentifier(node.id)
    }

    @ViewBuilder
    private func statusCell(_ node: SessionTableNode) -> some View {
        let parts = statusParts(for: node)
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
    private func primaryActionCell(_ node: SessionTableNode) -> some View {
        if case .session = node.kind, let session = session(for: node), let root = monitor.rootProcess(of: session) {
            let canAct = monitor.actionability(of: root).canAct
            Button(root.isSuspended ? "세션 재개" : "세션 일시 정지") {
                selection = node.id
                if root.isSuspended {
                    monitor.resume(root)
                } else {
                    monitor.suspend(root)
                }
            }
            .controlSize(.small)
            .disabled(!canAct)
            .accessibilityLabel(root.isSuspended ? "세션 재개" : "세션 일시 정지")
            .accessibilityIdentifier(sessionControlIdentifier(session, root.isSuspended ? "resume" : "suspend"))
        } else {
            Text("")
        }
    }

    @ViewBuilder
    private func contextMenu(for process: ProcessSnapshot, node: SessionTableNode) -> some View {
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
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "arrow.clockwise")
                    .accessibilityHidden(true)
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

    private var tableNodes: [SessionTableNode] {
        monitor.sessions.map { session in
            let members = monitor.members(of: session).map { member in
                SessionTableNode(kind: .member(member.identity), children: nil)
            }
            return SessionTableNode(
                kind: .session(session.id),
                children: members.isEmpty ? nil : members
            )
        }
    }

    private var warningCount: Int {
        monitor.sessions.filter { monitor.sessionHasWarning($0) }.count
    }

    private var isObservationStale: Bool {
        if monitor.samplingError != nil { return true }
        if let first = monitor.processes.first {
            return monitor.actionability(of: first).freshness != .current
        }
        return false
    }

    private func node(for id: SessionTableNode.ID) -> SessionTableNode? {
        func search(_ nodes: [SessionTableNode]) -> SessionTableNode? {
            for node in nodes {
                if node.id == id { return node }
                if let children = node.children, let found = search(children) {
                    return found
                }
            }
            return nil
        }
        return search(tableNodes)
    }

    private func session(for node: SessionTableNode) -> AgentSession? {
        guard case let .session(identity) = node.kind else { return nil }
        return monitor.sessions.first { $0.id == identity }
    }

    private func process(for node: SessionTableNode) -> ProcessSnapshot? {
        monitor.processes.first { $0.identity == node.identity }
    }

    private func projectName(for node: SessionTableNode) -> String? {
        switch node.kind {
        case .session:
            session(for: node)?.projectName
        case .member:
            process(for: node)?.projectName
        }
    }

    private func cpuText(for node: SessionTableNode) -> String {
        let value: Double
        switch node.kind {
        case .session:
            value = session(for: node)?.cpuPercent ?? 0
        case .member:
            value = process(for: node)?.cpuPercent ?? 0
        }
        return "\(Int(value.rounded()))%"
    }

    private func memoryText(for node: SessionTableNode) -> String {
        let bytes: UInt64
        switch node.kind {
        case .session:
            bytes = session(for: node)?.residentBytes ?? 0
        case .member:
            bytes = process(for: node)?.residentBytes ?? 0
        }
        return WatchdogFormatters.memory.string(fromByteCount: Int64(bytes))
    }

    private func childCountText(for node: SessionTableNode) -> String {
        switch node.kind {
        case .session:
            if let session = session(for: node) { return "\(session.memberCount)" }
            return "—"
        case .member:
            return "—"
        }
    }

    private func elapsedText(for node: SessionTableNode) -> String {
        switch node.kind {
        case .session:
            session(for: node)?.elapsed ?? "—"
        case .member:
            process(for: node)?.elapsed ?? "—"
        }
    }

    private func statusParts(for node: SessionTableNode) -> [String] {
        guard let process = process(for: node) else { return [] }
        let reasons: [AlertReason]
        let isSuspended: Bool
        switch node.kind {
        case .session:
            if let session = session(for: node) {
                reasons = monitor.sessionAlertReasons(session)
                isSuspended = session.isSuspended
            } else {
                reasons = monitor.alertReasons(for: process)
                isSuspended = process.isSuspended
            }
        case .member:
            reasons = monitor.alertReasons(for: process)
            isSuspended = process.isSuspended
        }
        var parts = SessionsPresentation.statusParts(
            reasons: reasons,
            isSuspended: isSuspended,
            isSuspendedByWatchdog: monitor.isSuspendedByWatchdog(process),
            outcome: actionOutcome(for: process)
        )
        if let feedback = monitor.actionFeedback, selection == node.id {
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

    private func accessibilityLabel(for node: SessionTableNode) -> String {
        switch node.kind {
        case .session:
            guard let session = session(for: node) else { return node.id }
            return SessionsPresentation.sessionAccessibilityLabel(
                name: session.name,
                projectName: session.projectName,
                cpuPercent: session.cpuPercent,
                residentBytes: session.residentBytes,
                reasons: monitor.sessionAlertReasons(session),
                memberCount: session.memberCount
            )
        case .member:
            guard let process = process(for: node) else { return node.id }
            return "\(process.displayName), PID \(process.id)"
        }
    }

    private func sessionControlIdentifier(_ session: AgentSession, _ control: String) -> String {
        "session.\(session.rootPID).\(session.id.startTimeMicroseconds).\(control)"
    }

    private func performPrimaryAction() {
        guard let selection, let node = node(for: selection) else { return }
        switch node.kind {
        case .session:
            guard let session = session(for: node), let root = monitor.rootProcess(of: session) else { return }
            guard monitor.actionability(of: root).canAct else { return }
            if root.isSuspended {
                monitor.resume(root)
            } else {
                monitor.suspend(root)
            }
        case .member:
            guard let process = process(for: node), monitor.actionability(of: process).canAct else { return }
            if process.isSuspended {
                monitor.resume(process)
            } else {
                monitor.suspend(process)
            }
        }
    }

    private func toggleSelectedOutlineExpansion() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        guard let outline = firstOutline(in: window.contentView) else { return }
        let row = outline.selectedRow
        guard row >= 0 else { return }
        let item = outline.item(atRow: row)
        if reduceMotion {
            if outline.isItemExpanded(item) {
                outline.collapseItem(item)
            } else {
                outline.expandItem(item)
            }
        } else if outline.isItemExpanded(item) {
            outline.animator().collapseItem(item)
        } else {
            outline.animator().expandItem(item)
        }
    }

    private func firstOutline(in view: NSView?) -> NSOutlineView? {
        guard let view else { return nil }
        if let outline = view as? NSOutlineView { return outline }
        for child in view.subviews {
            if let found = firstOutline(in: child) { return found }
        }
        return nil
    }

    private func prepareDestructiveAction(
        _ action: ProcessControlAction,
        process: ProcessSnapshot,
        kind: PendingProcessAction.Kind
    ) {
        do {
            let request = try monitor.destructiveActionRequest(action, for: process)
            tableFocused = false
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
        tableFocused = true
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
