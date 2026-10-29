import SwiftUI

struct SessionRow: View {
    let session: AgentSession
    let root: ProcessSnapshot
    let members: [ProcessSnapshot]
    let actionability: ProcessActionability
    let alertReasons: [AlertReason]
    let isIgnored: Bool
    var isSuspendedByWatchdog = false
    let actionOutcome: ProcessActionOutcome?
    let onSuspend: () -> Void
    let onResume: () -> Void
    let onTerminate: () -> Void
    let onForceQuit: () -> Void
    let onIgnore: () -> Void
    let onUndoIgnore: () -> Void
    let memberRow: (ProcessSnapshot) -> ProcessRow
    let onShowInWindow: () -> Void
    var focusedRow: FocusState<WatchdogFocusTarget?>.Binding
    var focusTarget: WatchdogFocusTarget

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let visibleMemberLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    toggleExpanded()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isExpanded)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "세션 접기" : "세션 펼치기")
                .accessibilityIdentifier(controlIdentifier("expand"))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(titleText)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)

                        ForEach(Array(alertReasons.enumerated()), id: \.offset) { _, reason in
                            reasonBadge(reason)
                        }

                        if isIgnored {
                            statusBadge("무시 중", color: .secondary)
                        }

                        if root.isSuspended {
                            statusBadge(isSuspendedByWatchdog ? "Watchdog이 정지함" : "정지됨", color: .blue)
                        }
                    }

                    Text(subtitleText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let statusDetail {
                        Text(statusDetail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(actionability.canAct ? Color.secondary : Color.orange)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(session.cpuPercent, format: .number.precision(.fractionLength(0)))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(cpuColor)
                        + Text("%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(cpuColor)

                    Text(WatchdogFormatters.memory.string(fromByteCount: Int64(session.residentBytes)))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(hasHighMemoryAlert ? Color.purple : Color.secondary)
                }
                .frame(width: 66, alignment: .trailing)

                Button(action: root.isSuspended ? onResume : onSuspend) {
                    Image(systemName: root.isSuspended ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .disabled(!actionability.canAct)
                .help(actionability.canAct ? (root.isSuspended ? "세션 재개" : "세션 일시 정지") : nonActionableReason)
                .accessibilityLabel(root.isSuspended ? "세션 재개" : "세션 일시 정지")
                .accessibilityHint(actionability.canAct ? "" : nonActionableReason)
                .accessibilityIdentifier(controlIdentifier(root.isSuspended ? "resume" : "suspend"))

                overflowMenu
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(members.prefix(visibleMemberLimit), id: \.identity) { member in
                        memberRow(member)
                    }
                    Button("창에서 보기", action: onShowInWindow)
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .padding(.leading, 8)
                        .accessibilityLabel("창에서 보기")
                        .accessibilityIdentifier(controlIdentifier("show-in-window"))
                }
                .padding(.leading, 12)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(actionability.canAct ? "세션 제어를 사용할 수 있습니다" : nonActionableReason)
        .accessibilityIdentifier(controlIdentifier("row"))
        .focused(focusedRow, equals: focusTarget)
        .focusable()
        .onKeyPress(.return) {
            toggleExpanded()
            return .handled
        }
        .onKeyPress(.space) {
            guard actionability.canAct else { return .ignored }
            if root.isSuspended {
                onResume()
            } else {
                onSuspend()
            }
            return .handled
        }
        .accessibilityAction(.default) {
            toggleExpanded()
        }
    }

    private func toggleExpanded() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        }
    }

    @ViewBuilder
    private var overflowMenu: some View {
        if isIgnored {
            Button(action: onUndoIgnore) {
                Label("다시 감시", systemImage: "bell")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("다시 감시")
            .accessibilityLabel("다시 감시")
            .accessibilityIdentifier(controlIdentifier("undo-ignore"))
        } else {
            Menu {
                if actionability.canAct {
                    if root.isSuspended {
                        Button("재개", systemImage: "play.fill", action: onResume)
                    } else {
                        Button("일시 정지", systemImage: "pause.fill", action: onSuspend)
                    }

                    Button("종료할 때까지 무시", systemImage: "bell.slash", action: onIgnore)
                        .accessibilityIdentifier(controlIdentifier("ignore"))
                    Divider()
                    Button("종료…", systemImage: "xmark.circle", action: onTerminate)
                        .accessibilityIdentifier(controlIdentifier("terminate"))
                    Button("강제 종료…", systemImage: "bolt.trianglebadge.exclamationmark", role: .destructive, action: onForceQuit)
                        .accessibilityIdentifier(controlIdentifier("force-quit"))
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(actionability.canAct ? .primary : .tertiary)
                    .frame(width: 22, height: 22)
                    .background(
                        Color.secondary.opacity(actionability.canAct ? 0.12 : 0.06),
                        in: Circle()
                    )
                    .accessibilityHidden(true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(!actionability.canAct)
            .help(actionability.canAct ? "프로세스 작업" : nonActionableReason)
            .accessibilityLabel("프로세스 작업")
            .accessibilityHint(actionability.canAct ? "" : nonActionableReason)
            .accessibilityIdentifier(controlIdentifier("actions"))
        }
    }

    @ViewBuilder
    private func reasonBadge(_ reason: AlertReason) -> some View {
        switch reason {
        case .sustainedCPU:
            statusBadge("CPU 높음", color: .red)
        case .sustainedMemory:
            statusBadge("메모리 높음", color: .purple)
        case .orphan:
            statusBadge("고아 의심", color: .orange)
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel(text)
    }

    private var titleText: String {
        if let project = session.projectName, !project.isEmpty {
            return "\(session.name) · \(project)"
        }
        return session.name
    }

    private var subtitleText: String {
        var parts: [String] = []
        if let first = alertReasons.first {
            parts.append(first.text)
        }
        parts.append("자식 \(session.memberCount)")
        if session.kind == .service {
            parts.append("서비스")
        }
        return parts.joined(separator: " · ")
    }

    private var cpuColor: Color {
        if session.cpuPercent >= 150 { return .red }
        if session.cpuPercent >= 80 { return .orange }
        return .primary
    }

    private var rowBackground: Color {
        if hasHotAlert { return .red.opacity(0.06) }
        if hasHighMemoryAlert { return .purple.opacity(0.07) }
        return Color(nsColor: .controlBackgroundColor).opacity(0.55)
    }

    private var hasHotAlert: Bool {
        alertReasons.contains {
            if case .sustainedCPU = $0 { return true }
            return false
        }
    }

    private var hasHighMemoryAlert: Bool {
        alertReasons.contains {
            if case .sustainedMemory = $0 { return true }
            return false
        }
    }

    private var nonActionableReason: String {
        if isIgnored { return "무시를 취소해야 제어할 수 있습니다" }
        if actionability.isProtected { return "보호된 프로세스라 제어할 수 없습니다" }
        switch actionability.freshness {
        case .current: return "현재 제어할 수 없습니다"
        case .stale: return "관찰 정보가 오래되어 새로고침 후 제어할 수 있습니다"
        case .unavailable: return "관찰 정보가 없어 제어할 수 없습니다"
        }
    }

    private var statusDetail: String? {
        if let actionOutcome {
            return actionOutcome.localizedDescription
        }
        if !actionability.canAct {
            return nonActionableReason
        }
        return alertReasons.compactMap {
            if case let .orphan(reason) = $0 { return reason.localizedDescription }
            return nil
        }.first
    }

    private var accessibilityLabel: String {
        let project = session.projectName.map { "\($0) 프로젝트" } ?? "프로젝트 없음"
        let memory = WatchdogFormatters.memory.string(fromByteCount: Int64(session.residentBytes))
        var sentence = "\(session.name), \(project), CPU \(Int(session.cpuPercent.rounded()))퍼센트, 메모리 \(memory)"
        if let first = alertReasons.first {
            sentence += ", 주의: \(first.text)"
        }
        sentence += ", 자식 \(session.memberCount)개"
        return sentence
    }

    private func controlIdentifier(_ control: String) -> String {
        "process.\(root.id).\(root.startTimeMicroseconds).\(control)"
    }
}
