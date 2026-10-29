import XCTest
@testable import Watchdog

final class SessionsPresentationTests: XCTestCase {
    func testSummaryCombinesSessionAndWarningCounts() {
        XCTAssertEqual(
            SessionsPresentation.summary(sessionCount: 12, warningCount: 2),
            "세션 12개 · 주의 2개"
        )
        XCTAssertEqual(
            SessionsPresentation.summary(sessionCount: 0, warningCount: 0),
            "세션 0개 · 주의 0개"
        )
    }

    func testIdentityTokenJoinsPidStartAndUser() {
        let identity = ProcessIdentity(pid: 71_001, startTimeMicroseconds: 9_071_001, userID: 501)
        XCTAssertEqual(SessionsPresentation.identityToken(identity), "71001:9071001:501")
    }

    func testKindLabels() {
        XCTAssertEqual(SessionsPresentation.kindLabel(.agent), "에이전트")
        XCTAssertEqual(SessionsPresentation.kindLabel(.service), "서비스")
        XCTAssertEqual(SessionsPresentation.kindLabel(.other), "추정")
        XCTAssertEqual(SessionsPresentation.kindLabel(.application), "추정")
    }

    func testReasonBadgeTexts() {
        XCTAssertEqual(SessionsPresentation.reasonBadgeText(.sustainedCPU(percent: 184)), "CPU 높음")
        XCTAssertEqual(SessionsPresentation.reasonBadgeText(.sustainedMemory(bytes: 1_024)), "메모리 높음")
        XCTAssertEqual(SessionsPresentation.reasonBadgeText(.orphan(.detachedSession)), "고아")
    }

    func testStatusPartsIncludeReasonsSuspensionAndOutcome() {
        let parts = SessionsPresentation.statusParts(
            reasons: [
                .sustainedCPU(percent: 184),
                .orphan(.detachedSession),
            ],
            isSuspended: true,
            isSuspendedByWatchdog: true,
            outcome: .suspended
        )
        XCTAssertEqual(
            parts,
            ["CPU 높음", "고아", "Watchdog이 정지함", "일시 정지됨 · 재개할 때까지 멈춰 있음"]
        )
    }

    func testSessionAccessibilityLabelMatchesHandoffExampleShape() {
        let label = SessionsPresentation.sessionAccessibilityLabel(
            name: "claude",
            projectName: "watchdog",
            cpuPercent: 184,
            residentBytes: 1_900_000_000,
            reasons: [.sustainedCPU(percent: 184)],
            memberCount: 4
        )
        XCTAssertTrue(label.contains("claude"))
        XCTAssertTrue(label.contains("watchdog 프로젝트"))
        XCTAssertTrue(label.contains("CPU 184퍼센트"))
        XCTAssertTrue(label.contains("메모리"))
        XCTAssertTrue(label.contains("주의:"))
        XCTAssertTrue(label.contains("자식 4개"))
    }
}
