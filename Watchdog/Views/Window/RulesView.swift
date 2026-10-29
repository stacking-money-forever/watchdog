import SwiftUI

struct RulesView: View {
    @ObservedObject var monitor: ProcessMonitor

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
                    // A6: 자동 일시 정지 아래에 범위 선택(끔 / 에이전트만 / 세션 전체)을 추가한다.
                }

                GroupBox("사용자 규칙 파일") {
                    Text("준비 중 — 에이전트 이름·패키지·서비스·호스트 규칙을 파일로 추가할 수 있게 됩니다")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watchdog.window.detail.rules")
    }
}
