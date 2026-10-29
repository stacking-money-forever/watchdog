import SwiftUI

struct DetectionRulesControls: View {
    @ObservedObject var monitor: ProcessMonitor
    var showsItemDescriptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            item {
                HStack {
                    Text("CPU 임계값")
                    Spacer()
                    Text("\(Int(monitor.threshold))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $monitor.threshold,
                    in: min(25, monitor.threshold)...max(300, monitor.threshold),
                    step: 5
                )
                .accessibilityLabel("CPU 임계값")
                .accessibilityValue("\(Int(monitor.threshold))퍼센트")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("watchdog.rules.cpu")
            } description: {
                "이 비율 이상으로 CPU를 쓰는 프로세스를 주의 대상으로 봅니다."
            }

            item {
                HStack {
                    Text("프로세스 메모리 임계값")
                    Spacer()
                    Text("\(monitor.memoryThresholdGB, specifier: "%.1f")GB")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $monitor.memoryThresholdGB,
                    in: min(0.5, monitor.memoryThresholdGB)...max(16, monitor.memoryThresholdGB),
                    step: 0.5
                )
                .accessibilityLabel("프로세스 메모리 임계값")
                .accessibilityValue(String(format: "%.1f기가바이트", monitor.memoryThresholdGB))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("watchdog.rules.memory")
            } description: {
                "이 크기 이상으로 메모리를 쓰는 프로세스를 주의 대상으로 봅니다."
            }

            item {
                Stepper(
                    "임계값 유지 시간: \(Int(monitor.sustainedDuration))초",
                    value: $monitor.sustainedDuration,
                    // A value set from the CLI or defaults may sit outside
                    // the usual range; keep it reachable and visible.
                    in: min(5, monitor.sustainedDuration)...max(120, monitor.sustainedDuration),
                    step: 5
                )
                .accessibilityLabel("임계값 유지 시간")
                .accessibilityValue("\(Int(monitor.sustainedDuration))초")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("watchdog.rules.sustain")
            } description: {
                "임계값을 이 시간 동안 넘긴 프로세스만 경고합니다."
            }

            item {
                Toggle("CPU 폭주 에이전트 자동 일시 정지", isOn: $monitor.autoSuspendEnabled)
                    .help("CPU 임계값을 지속해서 넘긴 코딩 에이전트에만 SIGSTOP을 보냅니다. 메모리만 넘긴 프로세스와 일반 앱은 멈추지 않으며, 직접 재개한 프로세스는 다시 멈추지 않습니다.")
                    .accessibilityLabel("CPU 폭주 에이전트 자동 일시 정지")
                    .accessibilityValue(monitor.autoSuspendEnabled ? "켬" : "끔")
                    .accessibilityIdentifier("watchdog.rules.auto-suspend")
            } description: {
                "CPU 임계값을 지속해서 넘긴 코딩 에이전트에만 SIGSTOP을 보냅니다."
            }
        }
    }

    @ViewBuilder
    private func item<Content: View>(
        @ViewBuilder content: () -> Content,
        description: () -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
            if showsItemDescriptions {
                Text(description())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
