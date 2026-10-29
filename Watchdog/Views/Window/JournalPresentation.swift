import Foundation

enum JournalPresentation {
    static func sourceLabel(_ source: ActionJournalEntry.Source) -> String {
        switch source {
        case .app: "앱"
        case .auto: "자동"
        case .cli: "CLI"
        }
    }

    static func actionLabel(_ action: ActionJournalEntry.ActionKind) -> String {
        switch action {
        case .suspend: "일시 정지"
        case .resume: "재개"
        case .terminate: "종료"
        case .forceQuit: "강제 종료"
        }
    }

    static func outcomeLabel(_ outcome: String) -> String {
        if outcome.hasPrefix("failed:") {
            let message = String(outcome.dropFirst("failed:".count))
            return "실패: \(message)"
        }
        switch outcome {
        case "suspended": return "멈춤"
        case "resumed": return "재개됨"
        case "awaitingExit": return "종료 대기"
        case "exited": return "종료됨"
        case "stillRunning": return "아직 실행 중"
        case "identityChanged": return "다른 프로세스로 바뀜"
        case "verificationFailed": return "확인 실패"
        case "signalDelivered": return "신호 전달됨"
        default: return outcome
        }
    }

    static func targetLabel(_ entry: ActionJournalEntry) -> String {
        "\(entry.displayName) · PID \(entry.pid)"
    }
}
