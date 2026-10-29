import Foundation

enum WindowSection: String, CaseIterable, Identifiable, Codable, Hashable {
    case overview
    case sessions
    case processes
    case journal
    case rules
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "개요"
        case .sessions: "에이전트 세션"
        case .processes: "전체 프로세스"
        case .journal: "조치 기록"
        case .rules: "감지 규칙"
        case .settings: "설정"
        }
    }

    var symbolName: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .sessions: "person.2.wave.2"
        case .processes: "list.bullet.rectangle"
        case .journal: "clock.arrow.circlepath"
        case .rules: "slider.horizontal.3"
        case .settings: "gearshape"
        }
    }

    var accessibilityIdentifier: String {
        "watchdog.sidebar.\(rawValue)"
    }

    /// 핸드오프 문서 §2 창 표의 "내용" 열을 한 문장으로 요약한 안내.
    var summary: String {
        switch self {
        case .overview:
            "아이콘 상태, 시스템 CPU·메모리, 주의·멈춤·고아 수, 최근 조치, 감지 규칙 요약을 보여 줍니다."
        case .sessions:
            "세션별 이름·프로젝트·CPU·메모리·자식 수·상태를 표로 보고, 행을 펼쳐 멤버를 확인합니다."
        case .processes:
            "전체 범위 프로세스 목록에서 검색·필터·정렬하고 기존과 같이 조치합니다."
        case .journal:
            "시각·출처·조치·대상·사유·결과가 남은 기록을 보고, 가능한 행은 되돌리거나 JSON으로 내보냅니다."
        case .rules:
            "CPU·메모리 임계값, 유지 시간, 자동 정지 범위, 사용자 규칙 파일을 편집하고 즉시 반영합니다."
        case .settings:
            "알림, 로그인 시 실행, CLI 링크, 진단, 앱 정보를 다룹니다."
        }
    }
}
