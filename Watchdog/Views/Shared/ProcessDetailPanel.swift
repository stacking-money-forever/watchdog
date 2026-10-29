import SwiftUI

struct ProcessDetailPanel: View {
    let process: ProcessSnapshot?
    let reasons: [AlertReason]
    let identifier: String

    var body: some View {
        Group {
            if let process {
                VStack(alignment: .leading, spacing: 6) {
                    Text("선택 상세")
                        .font(.headline)
                    detailLine("토큰", SessionsPresentation.identityToken(process.identity))
                    detailLine("실행 경로", process.executablePath)
                    detailLine("실행 스크립트", process.launchScript ?? "—")
                    detailLine("작업 디렉터리", process.workingDirectory ?? "—")
                    detailLine("워크트리 상태", worktreeText(process.worktreeState))
                    detailLine("시작한 에이전트", ancestorText(process.agentAncestor))
                    detailLine("종류", SessionsPresentation.kindLabel(process.kind))
                    detailLine("사유", reasons.isEmpty ? "—" : reasons.map(\.text).joined(separator: " · "))
                }
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("행을 선택하면 상세가 보입니다")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(minHeight: 132)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func detailLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
        }
    }

    private func worktreeText(_ state: WorktreeState?) -> String {
        guard let state else { return "—" }
        if let detail = state.detail, !detail.isEmpty {
            return "\(state.verdict.localizedDescription) · \(detail)"
        }
        return state.verdict.localizedDescription
    }

    private func ancestorText(_ ancestor: AgentAncestor?) -> String {
        guard let ancestor else { return "—" }
        return "\(ancestor.name) (PID \(ancestor.pid))"
    }
}
