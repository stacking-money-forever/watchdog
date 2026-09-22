# A19 — 실제 MenuBarExtra popover 관찰 (2026-09-21)

대상: 설치된 후보 `/Users/justn/Applications/Watchdog.app` (0.2.0 build 5, executable sha256 `6674f98d…`)
수단: `cua-driver` (Accessibility + Screen Recording), 자체 AX 프로브(`/private/tmp/axprobe`, `/private/tmp/winlist`)
조건: soak 진행 중(pid 52429). popover는 `scope=전체`, 검색어 없음.

## 판정

**FAIL — popover의 프로세스 목록이 사용 불가.** 아래 두 사실이 서로 독립적으로 같은 결론을 가리킨다.

1. 목록 영역이 렌더되지 않는다(픽셀).
2. 행이 창 밖으로 배치된다(AX 레이아웃).

## 통과한 부분 (R 등급)

| 항목 | 관측 |
|---|---|
| status item 존재 | `AXMenuBarItem` subrole `AXMenuExtra`, title `Watchdog`, frame x=1099 y=4.5 w=34 h=24 |
| 클릭으로 열림 | 창 `layer=101` `onscreen false→true` |
| 창 크기 | 298×212 (points), 위치 (1100, 35) |
| 크롬 렌더 | 제목 `Watchdog`, `CPU 18% 44.43GB/48GB`, 범위 세그먼트(`주의 필요` 기본 선택), 검색 필드, `감지 규칙`, 푸터 `방금 관찰 · HH:MM:SS` + ↻ ⓘ 종료 |
| 포커스 비탈취 | popover를 열고 내부를 클릭해도 frontmost는 계속 `Music` |
| 닫기/재열기 | 토글 동작, 수회 반복 성공 |
| 상태 보존 | 범위와 검색어가 close/reopen을 견딤 |

## 실패 근거

### 1. 픽셀 — 목록 영역이 비어 있다

`first-open-desktop.png`(데스크톱 합성, popover 열린 상태)와 `first-open-window.png`(윈도우 스코프) 모두,
`감지 규칙`과 푸터 사이의 목록 카드가 **높이 몇 pt의 슬리버**로만 그려지고 행 텍스트가 없다.

- `scope=주의 필요`(행 없음, `ContentUnavailableView` 표시되어야 함)일 때도 같은 슬리버 → 빈 상태 문구조차 렌더되지 않음.
- `scope=전체` + 검색어 없음(다수 행이 기대되는 상태)에서도 동일.

### 2. AX 레이아웃 — 행이 창 밖으로 나간다

`first-open-ax-frames.txt` (스크린 좌표):

```
0   AXWindow               x=1100.0 y=35.0  w=298.0 h=212.0   ← 창 하단은 y=247
1-4 범위/검색              y=101 .. y=143
5   AXDisclosureTriangle   y=181 h=13                          ← 하단 194
6   AXOpaqueProviderGroup  x=1112 y=210 w=274 h=48             ← 행 그룹 210..258
7   AXStaticText 'sleep'                 y=218 h=16
8   AXStaticText 'PID 23930 · 06:48'     y=237 h=13
17  AXButton '지금 새로고침'              y=225.5
18  AXButton 'Watchdog 정보'             y=225.5
19  AXButton '종료'                      y=224 h=13              ← 푸터 224..237
```

행 그룹(210..258)이 창 하단(247)을 11pt 넘고, 푸터(224..237)와 27pt 겹친다.
행 이름 텍스트(y=218)는 푸터 위 6pt 구간에만 걸린다 — 실제 캡처에서 그 위치에 아무것도 그려지지 않았다.

### 3. 창 높이가 내용을 따르지 않는다

행이 있든 없든 창은 **항상 298×212**다. 212pt는 크롬(헤더+범위+검색+감지 규칙+푸터 ≈204pt)에 목록 약 8pt를 더한 값과 일치한다.
즉 `ScrollView`가 이상적 높이에 기여하지 못해 목록이 항상 잔여 8pt로 압축된다.

### 4. 이 결함이 테스트에 걸리지 않는 이유

DEBUG UI 테스트는 `MenuBarExtra` popover가 아니라 `WatchdogUITestFixtureHost`가 만든
**별도 `NSWindow(contentRect: 480×590)`** 를 대상으로 한다(`WatchdogApp.swift`).
크기가 강제되므로 popover의 높이 결정 문제가 드러나지 않는다.
체크리스트가 A19 실패 조건으로 명시한 "fixed-window fixture used as popover proof" 그대로다.

## 파괴적 확인창 항목 — 미도달

행의 `프로세스 작업` 메뉴가 필요하지만:
- AX `AXPress`/`show_menu` → `element_outside_target_window` (거부)
- 윈도우 로컬 픽셀 클릭 → `off_space_or_ax_unresolved` (거부)
- 키 입력(`cmd+a`, `delete`) → 거부

따라서 "confirmation survives close/reopen"은 검증 불가. 소스 계약은 문서화되어 있다:
`// A pending confirmation must survive the popup closing (focus loss); it is only cancelled explicitly or when its 30 s validity expires.`
별도로 확인된 관련 사실: 범위·검색어 같은 popover 상태는 close/reopen 후에도 보존된다.

## 잔여 불확실성

에이전트가 연 popover가 앱을 활성화하지 못한 상태(포커스를 뺏지 않았다는 관측이 그 증거)라,
비활성 윈도우에서 `ScrollView` 내용이 그려지지 않는 아티팩트일 가능성을 완전히 배제하지 못한다.
다만 **AX 레이아웃상 행이 창 밖으로 배치된다는 사실(근거 2)은 렌더링과 무관**하므로 그 자체로 결함이다.
최종 확정은 사람이 popover를 직접 열어 목록을 보는 1회 관찰로 끝난다(A19의 H 게이트).

## 수정 (2026-09-21, 같은 세션)

**원인**: `MenuBarExtra`는 창을 콘텐츠의 ideal height로 맞추는데, 목록이 `ScrollView`라 ideal height가 사실상 0이었다.
그래서 창이 크롬(헤더+범위+검색+감지 규칙+푸터 ≈204pt) + 잔여 몇 pt로 결정됐고, 행이 창 밖에 배치됐다.

**변경**: `WatchdogApp.swift`의 `MenuBarExtra` 콘텐츠에만 크기를 고정했다.

```swift
MenuBarExtra {
    WatchdogMenuView(monitor: monitor, launchAtLogin: launchAtLogin)
        .frame(width: 380, height: 520)
} label: { ... }
```

`WatchdogMenuView` 본문이 아니라 scene 콘텐츠에 적용한 이유: 같은 뷰가 UI 테스트 fixture
(`NSWindow(contentRect: 480×590)`)에도 호스팅되므로, 뷰에 고정 프레임을 넣으면 fixture 기하 가정이 깨진다.
폭 380은 파괴적 확인 카드의 360pt를 수용하기 위한 값이다.

**수정 전 → 후 (설치된 빌드에서 AX로 측정)**

| 항목 | 수정 전 | 수정 후 |
|---|---|---|
| popover 창 | 298 × 212 | **380 × 520** |
| 감지 규칙 하단 | y=194 | y=195 |
| 푸터 상단 | y=224 (창 하단 247, 행과 27pt 겹침) | y=532 (창 하단 555) |
| 목록 영역 높이 | 약 30pt, 행 그룹이 210..258로 창 밖 초과 | **337pt** |
| 검색 필드 폭 | 226.5 | 308.5 |
| 모든 요소가 창 안에 있는가 | 아니오 | 예 |

빌드/설치: exe sha256 `9ca3770ebad4a657ee9ca01fa41a198d66c700413d635c6e861ef1c50eb43cca`,
`codesign --verify --deep --strict` 통과, DMG/ZIP/manifest는 `scripts/build-candidate.sh`로 생성.

**잔여**: 목록에 실제 행이 그려지는지는 여전히 확정하지 못했다. 에이전트가 연 popover는 앱이 활성화되지 않아
1초 내로 닫히고, 그 짧은 구간에는 목록 콘텐츠(행 또는 빈 상태 뷰)가 AX 트리에 나타나지 않는다.
구조적 결함(목록에 높이가 없음)은 위 표대로 제거됐고, 남은 확인은 실제 사용자 클릭 1회다.

## 수정 검증 — 사람 관찰 (2026-09-22, H 등급)

사용자가 두 번의 실제 클릭으로 캡처를 제공했다.

| | 수정 전 (2026-09-22 08:18) | 수정 후 (2026-09-22 08:22) |
|---|---|---|
| 실행 중이던 앱 | `DerivedData/Watchdog-cmdmntevkpkjrpaimxkbuxsdbast/Build/Products/Debug/Watchdog.app` (빌드 2026-09-02 23:41, pid 14058) | `/Users/justn/Applications/Watchdog.app` (exe `9ca3770e…`, pid 34773) |
| popover 크기 | 약 294 × 207 | **380 × 520** |
| 헤더 설명 | `감시 중인 프로세스가 안…` (잘림) | `감시 중인 프로세스가 안정적입니다` (온전) |
| 목록 영역 | 완전히 빈 공간 | **빈 상태 정상 렌더**: shield 아이콘 + `확인할 프로세스가 없습니다` + `CPU 또는 메모리 사용량이 오래 높은 프로세스를 표시합니다` |
| 푸터 | `방금 관찰 · 08:18:03` | `방금 관찰 · 08:22:34` |

수정 전 캡처가 **9월 2일 빌드**에서 나온 것은 우연한 이득이다 — 제 진단(목록 영역 붕괴)이 제가 조작한 빌드가 아닌
독립적인 옛 빌드에서도 그대로 나타났다는 뜻이므로, 관측 아티팩트였다는 가능성이 배제된다.
수정 후 캡처는 같은 목록 영역이 정상 렌더됨을 보여준다.

**판정: A19의 "popover 사용 가능 + 첫 오픈 크기 정상" 항목은 통과(H).**
남은 하위 항목은 "confirmation survives close/reopen safely" 하나이며, 이는 행의 `프로세스 작업` 메뉴를 열어야 해서
아직 미검증이다(에이전트 경로는 아래 참조).

## 이 환경에서 에이전트가 GUI를 조작하지 못하는 이유 (기록)

- 디스플레이 2개: 메인(id 1, 1728×1117 @ 0,0)과 보조(id 4, 1920×1080 @ −84,−1080). status item은 양쪽 메뉴바에 존재하지만
  위치가 디스플레이별로 다르다(AX는 보조 기준 x=1243 y=−1077, 메인 캡처에서는 points ≈1152).
- `cua-driver`의 desktop 스코프는 `display_id: "primary"`(메인)만 지원하고, `get_desktop_state`도 메인만 캡처한다.
- 재부팅(2026-09-22 08:11)으로 전원 설정이 초기화돼 디스플레이가 잠들었고, 깨어난 뒤에도 상단 30pt가 캡처에서 완전 검정으로 나온다(메뉴바 숨김).
- `AXPress`로 status item을 누르면 popover가 열리지만 앱이 활성화되지 않아 1초 내 닫히고, 그 구간에는 콘텐츠가 실체화되지 않는다
  (`window_bounds`는 380×520으로 정상, `elements`는 0).
- `kAXFrontmostAttribute` 설정은 success를 반환하나 실제 frontmost는 false로 남는다(accessory 앱).
- 결과: **실제 사용자 클릭만이 popover를 안정적으로 열고 콘텐츠를 렌더한다.** 남은 GUI 항목은 사람 손이 필요하다.

## A19 확정 (2026-09-22) 및 근접 사고 기록

**확정**: 크기·사용가능성·포커스 항목은 통과(H). 목록이 실제로 렌더됨을 AX로도 확인했다 —
`AXScrollArea y=211 h=310`(창 520 안), 그 안에 `AXGroup "sleep, PID 99451"` 같은 행들이
이름/PID/CPU%/메모리/`일시 정지` 버튼/`프로세스 작업` 메뉴로 배치된다.
미확보 항목(confirmation survives close/reopen)은 사용자 결정으로 잔여 위험으로 기록하고 닫았다.

**근접 사고 — 재발 방지용 기록 (2026-09-22)**

에이전트가 popover의 확인창을 열려고 `AXMenuItem`을 **부분일치**로 찾았고, 탐색 범위에 앱 메뉴바가 포함돼 있어
Apple 메뉴의 **`시스템 종료…`** 에 매칭됐다. 결과적으로 macOS 시스템 종료 다이얼로그가 열렸다(사용자가 취소).

- 아무것도 확정되지 않았고 신호 전송도 없었다. `/sbin/shutdown` 예약 없음, 표적 프로세스 생존 확인.
- 원인: (1) 부분일치, (2) popover 밖(앱 메뉴바)까지 탐색, (3) 실행 직전 대상 라벨·좌표 미검증.
- **금지**: 표적 앱의 popover 창 하위 트리 밖에서 AX 요소를 찾거나 누르는 것. 특히 앱 메뉴바/Apple 메뉴.
- **필수**: popover 밖이면 실행하지 않고, 메뉴 항목은 정확 일치로만 누르며,
  `시스템 종료…`/`재시동…`/`로그아웃…`/`잠자기`/`강제 종료…`가 해석되면 즉시 중단한다.
- 이 사고 이후 A19의 남은 확인창 항목은 사용자 결정으로 미검증 잔여로 남겼다.

## 초기화한 것

- 전체 화면 캡처 `first-open-desktop.png`(3456×2234)는 사용자 데스크톱 내용을 포함하므로 **커밋 전에 삭제**했다.
  남은 이미지는 모두 popover 창 범위(380×520 또는 그 2x)만 담는다.
- 검색 필드: AX `set_value ""` 로 비움 (`effect: confirmed`)
- 일회용 표적 프로세스: `sleep 600` 종료
- 진단용 QA 앱/윈도우 프레임 변경: 시도했으나 거부됨(`set_window_frame` → no settable AXSize) — 변경 없음
