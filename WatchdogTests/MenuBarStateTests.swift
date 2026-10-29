import XCTest
@testable import Watchdog

final class MenuBarStateTests: XCTestCase {
    func testResolvePrefersStaleOverActedAndAttention() {
        XCTAssertEqual(
            MenuBarIconState.resolve(attentionCount: 2, suspendedCount: 1, isStale: true),
            .stale
        )
    }

    func testResolvePrefersActedOverAttention() {
        XCTAssertEqual(
            MenuBarIconState.resolve(attentionCount: 3, suspendedCount: 1, isStale: false),
            .acted(1)
        )
    }

    func testResolveAttentionWhenNothingIsStopped() {
        XCTAssertEqual(
            MenuBarIconState.resolve(attentionCount: 2, suspendedCount: 0, isStale: false),
            .attention(2)
        )
    }

    func testResolveNormalWhenQuiet() {
        XCTAssertEqual(
            MenuBarIconState.resolve(attentionCount: 0, suspendedCount: 0, isStale: false),
            .normal
        )
    }

    func testAccessibilitySentences() {
        XCTAssertEqual(MenuBarIconState.normal.accessibilityLabel, "Watchdog, 문제 없음")
        XCTAssertEqual(MenuBarIconState.attention(2).accessibilityLabel, "Watchdog, 주의 2건")
        XCTAssertEqual(MenuBarIconState.acted(1).accessibilityLabel, "Watchdog, 멈춤 1건")
        XCTAssertEqual(MenuBarIconState.stale.accessibilityLabel, "Watchdog, 관찰 정보 오래됨")
    }
}
