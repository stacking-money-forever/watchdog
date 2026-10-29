import SwiftUI

enum MenuBarIconState: Equatable, Sendable {
    case normal
    case attention(Int)
    case acted(Int)
    case stale

    static func resolve(attentionCount: Int, suspendedCount: Int, isStale: Bool) -> MenuBarIconState {
        if isStale { return .stale }
        if suspendedCount > 0 { return .acted(suspendedCount) }
        if attentionCount > 0 { return .attention(attentionCount) }
        return .normal
    }

    var accessibilityLabel: String {
        switch self {
        case .normal:
            "Watchdog, 문제 없음"
        case let .attention(count):
            "Watchdog, 주의 \(count)건"
        case let .acted(count):
            "Watchdog, 멈춤 \(count)건"
        case .stale:
            "Watchdog, 관찰 정보 오래됨"
        }
    }
}

struct WatchdogMenuBarLabel: View {
    let monitor: ProcessMonitor
    @State private var iconState: MenuBarIconState = .normal

    var body: some View {
        WatchdogMenuBarIcon(state: iconState)
            .onReceive(monitor.$menuBarIconState.removeDuplicates()) { iconState = $0 }
    }
}

struct WatchdogMenuBarIcon: View {
    let state: MenuBarIconState

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "dog.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(silhouetteStyle)
                .frame(width: 18, height: 16)

            overlayMark
        }
        .frame(width: 18, height: 16)
        .symbolRenderingMode(.monochrome)
        .accessibilityLabel(state.accessibilityLabel)
    }

    @ViewBuilder
    private var overlayMark: some View {
        switch state {
        case .normal:
            EmptyView()
        case .attention:
            Circle()
                .fill(Color.orange)
                .frame(width: 6, height: 6)
                .overlay {
                    Circle()
                        .strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 1)
                }
                .offset(x: 3, y: -3)
                .accessibilityHidden(true)
        case .acted:
            Image(systemName: "pause.fill")
                .font(.system(size: 6, weight: .bold))
                .foregroundStyle(Color.blue)
                .offset(x: 3, y: -3)
                .accessibilityHidden(true)
        case .stale:
            Image(systemName: "exclamationmark")
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(Color.primary)
                .offset(x: 3, y: -3)
                .accessibilityHidden(true)
        }
    }

    private var silhouetteStyle: some ShapeStyle {
        switch state {
        case .stale: Color.secondary.opacity(0.45)
        default: Color.primary
        }
    }
}
