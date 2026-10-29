# Watchdog v0.2.7 릴리스 기록 (2026-10-30)

## 릴리스

| 항목 | 값 |
|---|---|
| 태그 | `v0.2.7` |
| 태그 대상 | `8a8cd44` (main, PR #32 병합 커밋, 빌드 소스와 동일) |
| 제목 | `Watchdog 0.2.7 (unnotarized beta)` |
| URL | <https://github.com/stacking-money-forever/watchdog/releases/tag/v0.2.7> |
| 버전 | 0.2.7 (build 12), 패치 릴리스 |

## 포함 변경 (PR #32, 브랜치 `claude/0.3-accuracy`)

brgr 워커(Cursor CLI, `cursor-grok-4.6-medium`)가 단위별로 구현하고, 오케스트레이터가 패치를 읽고 워크트리에서 직접 검증한 뒤 적용했다.

| 단위 | 내용 | 워커 task |
|---|---|---|
| A1 | 라벨 픽스처(1,151행·166 라벨), `snapshot`/`audit` CLI, `ClassifierAccuracyTests` | 288f437d |
| A5 | `ActionJournal`(JSONL, flock, 2,000건 롤링) + 모든 시그널 경로 배선 | d3e90e46 |
| A2 | `service` kind, `temporaryLaunchPath` 고아 사유, 서비스 루트 계보; 불일치 38→0 | 86a8530d (+ 시스템 데몬 제외·앱 cwd 조회 확장) |
| A3 | `AgentSession` 집계, 세션 합계 지속 판정, `sessions` CLI | c57da81b (+ 세션 호스트 제외·CLI 필터) |
| A4 | `agent-rules.json`, 값 타입 `AgentCatalog`, suspected 신뢰도, `rules` CLI | c068e793 |
| A6 | 세션 범위 자동 정지(기본 꺼짐), ledger `groupID`, `watch --only` | 7a8ced45 (첫 시도 f3b92ab7는 사고로 취소) |
| A7 | CLI JSON 계약(`docs/cli-json.md`, 스키마, 검사 스크립트), `journal` CLI | aab729cf |

## 사고

A6 첫 시도의 e2e가 `--only` 없이 `watch --auto-suspend --scope session`을 실행해 이 Mac의 실제 세션 3개(35개 프로세스)를 약 70분 멈췄다. 복구와 재발 방지는 `incident-20261030-e2e-auto-suspend.md`.

## 자산과 해시 (3자 일치: manifest, GitHub digest, 직접 다운로드)

- zip `b9207305d1f612da6ea3d4fc5a05af43f1bcd1a0b0f834aff214a16aab381cd3`
- dmg `36d1c7a0dcefb0fbba503eb8352d81d45061db570b249c11b7cb4effbccb0f0e`

## 소스 바인딩

- 새로 clone한 main `8a8cd44`에서 `scripts/build-candidate.sh`로 빌드했다.
- manifest: `source_tree=a74dfeca25bd154f9201253cadac670d971253d7`, `source_dirty=false`, 아키텍처 `x86_64 arm64`.
- codesign은 ad-hoc 서명이며 `TeamIdentifier=not set`. `spctl`은 거부하며, 이는 예상된 결과다.

## 테스트

| 위치 | 단위 | UI | CLI e2e | JSON 계약 | 실행 스모크 |
|---|---|---|---|---|---|
| 워커 워크트리(A7 기준) | 220/220 | — | 80/80 (전후 `T` 상태 0) | 불일치 0 | — |
| 로컬 accuracy HEAD | 통과 | 9/10 (`testSearchShowsNoMatchState`는 다른 앱이 전면일 때 키보드 포커스 실패) | — | — | 4/4 (후보 앱) |
| CI PR #32 | 통과 | 통과 | 통과 | 통과 | 통과 |

## 실기 확인 (2026-10-30, 이 Mac)

- `audit` 라벨 대비 불일치 0건(허용 10건은 인자에만 증거가 있는 brgr 테스트 찌꺼기).
- 고아 목록 = 임시 wait-gate 셸 15, brgr notify 워커 3, scratchpad에서 뜬 codex 데몬 1. 실행 중인 서비스는 하나도 안 잡힘.
- `sessions`: 사용자 세션만, 세션 호스트(herdr·brgr) 제외.
- 샘플링 비용 약 6–8ms(0.2.6 대비 +1–2ms, 카탈로그 잠금).
