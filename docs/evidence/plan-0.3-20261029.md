# Watchdog 0.3 실행 계획 — 정확도 + UI/UX 전면 개편

작성: 2026-10-29 · 기준 커밋: `a480e80` (main, v0.2.6 설치됨)
오케스트레이터: Claude(Fable 5.1, 이 세션). 워커: brgr `local.omp`.

## 0. 결정 사항과 전제

| 항목 | 결정 |
|---|---|
| 자동화 범위 | Claude가 설치된 실제 앱을 직접 조종해 테스트한다(사용자 허가 2026-10-29). 실제 시그널은 Claude가 띄운 일회용 프로세스에만 보낸다. |
| UI 범위 | 메뉴바(요약·빠른 조치) + 별도 창(상세). |
| 버전 | 정확도 개선은 0.2.7 패치로 먼저 배포. UI 개편은 화면 구조가 통째로 바뀌므로 0.3.0(마이너) 제안. 사용자 확인 전까지는 0.3.0으로 가정. |
| 자손 자동 일시 정지 | 세션 단위 옵션으로 추가, 기본값 꺼짐. 자손만 멈추는 모드는 만들지 않는다(에이전트가 응답 대기로 멈춤). |
| 불변 안전 계약 | sudo·자동 SIGKILL·Gatekeeper 해제·xattr 제거 금지. 시그널마다 새 일회용 승인. 샘플링이 오래되면 제어 비활성화. 시스템·다른 사용자 프로세스 제어 금지. UI 테스트는 실제 시그널 금지. |
| 문서 동기화 | INSTALL.md, README.md, scripts/install.sh, AGENTS.md, 릴리스 자산을 함께 갱신. |

## 1. 현재 상태에서 확인한 결함 (2026-10-29 실기)

- `opencode serve --service`(52820), `codex app-server daemon`(66092)가 **고아**로 표시된다. 둘 다 launchd 아래 상주하도록 설계된 서비스라 오탐.
- 임시 scratchpad 경로에서 시작돼 남은 `codex app-server daemon`(60210)은 실제 정리 대상인데, 위 둘과 같은 `reparentedToLaunchd` 사유로만 표시되어 구분이 안 된다.
- 에이전트와 그 자손의 부하를 묶어 보여 주지 않는다. "어느 세션이 무겁나"에 답하지 못한다.
- 목록(`AgentCatalog`)에 없는 에이전트는 인식하지 못한다. 사용자가 추가할 방법이 없다.
- 조치 기록이 메모리에만 있고 몇 초 뒤 사라진다(`actionOutcomes`). 자동 조치가 늘어나면 "왜 멈췄는지"를 나중에 볼 수 없다.
- 정확도를 재는 기준이 없다. 매번 `ps`·`lsof`와 손으로 대조했다.

## 2. 목표 아키텍처 (0.3)

```
┌──────────────────────── Watchdog.app ────────────────────────┐
│ MenuBarExtra (요약)            Window "Watchdog" (상세)        │
│  - 상태 아이콘 3단계            NavigationSplitView            │
│  - 주의 항목 ≤5                 ├ 개요                          │
│  - 최근 조치 + 되돌리기          ├ 에이전트 세션 (트리)          │
│  - "창 열기"                     ├ 전체 프로세스                 │
│                                  ├ 조치 기록 (영구)              │
│                                  ├ 감지 규칙                    │
│                                  └ 설정                         │
│            ProcessMonitor (@MainActor 어댑터, 기존)            │
├──────────────────────── WatchdogCore ────────────────────────┤
│ MonitorEngine ─ ingest ─▶ MonitorUpdate{processes, sessions}  │
│   ├ ProcessClassifier  (kind: agent|service|renderer|app|…)   │
│   │   ├ AgentCatalog + AgentRules(사용자 규칙 파일)            │
│   │   └ OrphanClassifier (service 제외, 임시 경로 사유 추가)   │
│   ├ SessionAggregator  (에이전트 루트 + 자손 합산)             │
│   ├ Hot/Memory/SessionTracker (지속 판정, 히스테리시스)        │
│   └ AutoSuspendPolicy  (agent | session, 기본 agent)           │
│ SuspensionLedger (기존) ◀─▶ ActionJournal (신규, JSONL 영구)   │
│ Audit: SnapshotDump / LabeledFixture / ClassifierAudit        │
├──────────────────────── watchdog-cli ────────────────────────┤
│ list · inspect · watch · stopped · doctor (기존)              │
│ sessions · journal · snapshot · audit · rules (신규)          │
│ JSON enum 안정화 (kind/state/reason/outcome 문자열 고정)       │
└───────────────────────────────────────────────────────────────┘
```

### 2.1 Core 모델 변경

- `ProcessKind`에 `service` 추가. 판정: argv에 `serve`/`daemon`/`app-server`/`--service`/`mcp`/`lsp` 패턴 **또는** 사용자 규칙의 `services` 항목. 에이전트 바이너리라도 service 모드면 `service`(예: `codex app-server`, `opencode serve`). 단, `agentName`은 유지해 "codex 서비스"로 표시.
- `OrphanReason`에 `temporaryLaunchPath` 추가(`/tmp`, `/private/tmp`, `*/scratchpad/*`, `$TMPDIR`). 고아 규칙: `kind == .agent`이고 세션 호스트·에이전트 조상이 없을 때만. `service`는 임시 경로일 때만 고아.
- `AgentConfidence { known, suspected }`. `suspected`: 인터프리터(node/bun/python)가 TTY에 붙어 있고, 부모가 세션 호스트이며, 실행 스크립트가 홈 디렉터리 아래 패키지 경로일 때. `suspected`는 표시만 하고 자동 일시 정지·세션 집계 루트가 되지 않는다.
- `AgentSession { root: ProcessIdentity, name, workingDirectory, members: [ProcessIdentity], cpuPercent(합), residentBytes(합), memberCount }`. `OrphanClassifier`의 `AgentLineage` 결과를 재사용해 O(n)으로 집계.
- `SessionTracker`: 세션 합계에 대한 지속 판정(기존 `SustainedProcessTracker` 재사용, 키만 루트 identity).
- `MonitorSettings`에 `autoSuspendScope: agent | session` 추가(정규화 포함). `session`일 때 후보는 루트 + 멤버 전체, ledger에 `groupID`(루트 identity)로 기록해 재개 시 묶음 재개.
- `AgentRules`(Codable): `~/Library/Application Support/Watchdog/agent-rules.json`. 필드: `agentNames`, `packageMarkers`, `sessionHosts`, `services`, `ignorePaths`. `AgentCatalog`를 정적 enum에서 값 타입으로 바꾸고 기본 규칙 + 사용자 규칙 병합. 파일 없음·손상 시 기본값, 오류는 `doctor`에 표시.
- `ActionJournal`: `~/Library/Application Support/Watchdog/journal.jsonl`, append-only, `flock`, 최대 2,000건 롤링. 항목: `at, source(app|auto|cli), action, identity, displayName, sessionRoot?, reason(AlertReason 증거: CPU%·지속 초), outcome, undoOf?`. 앱과 CLI가 공유. ledger는 그대로 "지금 멈춰 있는 것"의 진실 원천.

### 2.2 정확도 측정 장치

- `watchdog-cli snapshot --out FILE`: 리스터 원시 행(pid, ppid, pgid, uid, tty, argv[0..9], 실행 경로, cwd, 상태)을 JSON으로 저장. 개인 정보를 줄이려고 홈 경로는 `~`로 치환.
- 라벨 파일 `FILE.labels.json`: `{pid: {kind, agentName?, sessionRoot?, orphan: bool, project?}}`. 라벨은 Claude가 `ps`/`lsof`/`launchctl`로 확인해 붙이고, 근거를 주석 필드에 남긴다.
- `watchdog-cli audit SNAPSHOT [--labels]`: 분류기 실행 → 항목별 일치/불일치, 혼동 행렬, 불일치 목록 출력. 라벨 없으면 분류 결과만.
- `WatchdogTests/Fixtures/mac-20261029.json` + 라벨 → `ClassifierAccuracyTests`가 불일치 0건을 단언. 이후 모든 정확도 작업은 이 테스트를 먼저 깨뜨리고 고친다.

### 2.3 앱 구조

- `WatchdogApp`: `MenuBarExtra` 유지 + `Window("Watchdog", id: "main")` 추가. 창은 `openWindow`로 열고, 닫아도 앱은 종료되지 않는다(메뉴바 앱).
- `Watchdog/Views/` 재편: `MenuBar/`(Label, Popover), `Window/`(Sidebar, Overview, Sessions, Processes, Journal, Rules, Settings), `Shared/`(ProcessRow, Badges, ConfirmationCard).
- `ProcessMonitor`에 `@Published sessions`, `journalEntries`(최근 N건, 파일 감시) 추가. 분류·집계는 전부 Core.
- 상태 아이콘: 정상(단색) / 주의(주황 점) / 조치함(Watchdog이 멈춘 프로세스가 있음, 파랑 점). 색만 쓰지 않고 모양도 다르게.
- 모든 조작 요소에 `accessibilityIdentifier`와 접근성 레이블. 키보드: 목록 ↑↓, Return 상세, ⌘F 검색, ⌘Z 되돌리기(마지막 조치). VoiceOver 안내문은 조치 결과가 나올 때 `AccessibilityNotification.Announcement`.
- 기존 안전 UI 유지: 종료·강제 종료는 별도 확인 카드, 샘플링 오래됨 배너 + 제어 비활성화.

### 2.4 검증 구조

- 단위: Core 전부. 새 테스트 — `ClassifierAccuracyTests`, `SessionAggregatorTests`, `AgentRulesTests`, `ActionJournalTests`(동시 쓰기·롤링·손상 복구), `AutoSuspendScopeTests`.
- CLI e2e: `scripts/cli-e2e.sh`에 service 오탐 없음, 임시 경로 고아, `sessions` 합산, 세션 일시 정지→`stopped --resume-all`로 묶음 재개, `journal` 기록 검증 추가.
- XCUITest: 창 열기, 사이드바 이동, 세션 트리 펼침, 기록에서 되돌리기(픽스처), 규칙 편집 반영. 실제 시그널 없음.
- 실제 앱 조종(Claude 직접): `cua-driver`로 접근성 트리 스냅샷 → 조작 → 스크린샷. `scripts/ui-crosscheck.sh`가 창에 보이는 세션·프로세스 값과 `watchdog-cli sessions --json`을 같은 시점에 대조. 일회용 CPU 폭주 프로세스(`yes > /dev/null`를 가짜 에이전트 이름으로)로 자동 조치→기록→되돌리기 전 과정 확인.
- 릴리스 전: 기존 파이프라인(build-candidate → launch-smoke → release → 3중 해시 → pin PR → install) 그대로.

## 3. 워커 운용 방식 (brgr)

- 사전 확인(2026-10-29 14:56Z): `brgr doctor` — `local.omp` 등 주요 하네스 healthy, `local.cline`만 unspawnable(사용 안 함). Meter — cursor live(Cursor Models 68% 남음, **Other Models 0%**), codex live(5h 80%, 주간 90%), command-code **stale**(실행 전 `--refresh` 필요).
  - Other Models 0%는 경고이지 차단이 아니지만, 디자인 역할(`designer`=cursor/gemini, `senior_designer`=cursor/kimi)이 그 버킷을 쓸 가능성이 있다. 디자인 레인 첫 실행에서 실패 영수증이 나오면 사용자에게 보고하고 대안을 묻는다. 임의로 다른 모델로 바꾸지 않는다.
- 역할: 구현·검토 단위는 `default`(cursor/cursor-grok-4.6, medium). 기계적 반복(enum 문자열 고정, 접근성 ID 일괄)은 `bulk`. 테스트 루프는 `tester`. 디자인 방향은 사용자가 명시적으로 개편을 요청했으므로 `designer`→`senior_designer` 레인을 쓰되, 최종 IA 승인은 사용자.
- 호출 틀(각 단위마다 하나):
  ```
  brgr run "FROM CODEX
  <한 가지 목표, 수정 범위, 금지 사항, 산출물 경로>" \
    --harness local.omp --model cursor/cursor-grok-4.6 --effort medium \
    --workspace /Users/justn/dev/watchdog \
    --criterion "<관찰 가능한 검사 1개>" \
    --scope "<허용 경로>" --capture-diff --capture-logs \
    --deadline-seconds 5400 --json
  ```
- 동시 워커 최대 2개. 각 단위는 산출물 1개 + 검사 1개. 워커 Todo 3개 이하, 하위 에이전트 금지.
- 통합: `brgr diff --stat` → 패치 정독 → 워커 워크트리에서 `xcodebuild test` + `cli-e2e.sh` 직접 실행 → `brgr accept|reject` → `brgr apply --execute` → 기능 브랜치 커밋 → PR → CI → `gh api PUT merge`. 워커 보고서는 신뢰하지 않고 패치와 테스트 결과만 본다.
- 워커 금지 사항(모든 objective에 명시): 실제 프로세스에 시그널 금지, `~/Library/Application Support/Watchdog` 접근 금지(테스트는 `WATCHDOG_LEDGER_PATH`·임시 suite), `project.yml` 외 Xcode 프로젝트 직접 수정 금지, 릴리스·설치 스크립트 수정 금지(Fable 전담), 커밋 금지(패치로 전달).
- 질문이 오면(`brgr_question`) 즉시 답하고 `ack`. 중단·실패는 `brgr errors`로 기록 확인 후 `revise`.

## 4. 작업 분해와 순서

### P0 — 기준선 (Fable 직접, 워커 없음)
| ID | 작업 | 산출물 | 검사 |
|---|---|---|---|
| P0-1 | 이 Mac 스냅샷 + 라벨링(임시 `ps`/`lsof` 기반 스크립트, CLI 구현 전) | `WatchdogTests/Fixtures/mac-20261029.json`, `.labels.json` | 라벨 ≥ 60건, 에이전트 전수 + 고아 후보 3건 포함 |
| P0-2 | 기능 브랜치 `claude/0.3-accuracy`, `claude/0.3-ui` 생성 | 브랜치 | — |
| P0-3 | `ap` 계획을 아래 단위로 갱신 | ap | — |

### P1 — 정확도 (브랜치 `claude/0.3-accuracy`, 배포 0.2.7)
| ID | 역할 | 목표 | 의존 | 검사 기준 |
|---|---|---|---|---|
| A1 | default | `snapshot`/`audit` CLI + 픽스처 로더 + `ClassifierAccuracyTests` 골격(현재 불일치는 `XCTExpectFailure`로 표시) | P0-1 | `watchdog-cli audit Fixtures/mac-20261029.json --labels` 가 혼동 행렬을 출력하고 테스트가 불일치 건수를 그대로 보고 |
| A2 | default | `service` kind, `temporaryLaunchPath` 사유, 고아 규칙 수정 | A1 | 픽스처에서 52820·66092 비고아, 60210 고아(temporaryLaunchPath); 기존 158 단위 테스트 통과 |
| A3 | default | `AgentSession` 집계 + `SessionTracker` + CLI `sessions` | A2 | `sessions --json` 합계가 `list --json` 멤버 합과 ±1% 이내; e2e에 가짜 에이전트+자식 2개 합산 검사 |
| A4 | default (A3와 병렬) | `AgentRules` 파일 + `suspected` 신뢰도 + CLI `rules show/validate` | A1 | 규칙 파일로 추가한 이름이 e2e에서 agent로 인식, 손상 파일은 기본값 + `doctor` 경고 |
| A5 | default (A3·A4 뒤) | `ActionJournal` + CLI `journal` + 앱·CLI 모든 시그널 경로 기록 | A2 | e2e: suspend→resume→terminate 3건이 journal에 순서대로, 동시 2프로세스 쓰기 후 파일 유효 |
| A6 | default | `autoSuspendScope: session` + ledger `groupID` + 묶음 재개 + **`watch --auto-suspend --only` 대상 제한** | A3, A5 | e2e: `watch --auto-suspend --scope session --only <root>`로 가짜 세션 3 프로세스만 T, `stopped --resume-all`로 모두 복귀. 첫 시도는 `--only` 없이 실행돼 실제 세션을 멈춤 → `incident-20261030-e2e-auto-suspend.md` |
| A7 | bulk | CLI JSON enum 문자열 고정 + `docs/cli-json.md` | A5 | 스키마 문서의 모든 enum 값이 코드 `rawValue`와 일치(스크립트 검사) |
| R1 | Fable | 실기 재검증(audit 불일치 0, 에이전트·세션·고아 `ps` 대조), 0.2.7 릴리스·pin·설치 | A1–A7 | 기존 릴리스 게이트 전부 |

### P2 — 디자인 게이트 (코드 전에 승인)
| ID | 역할 | 목표 | 검사 |
|---|---|---|---|
| D1 | Fable | 디자인 핸드오프 문서: 독자·주 과업·정보 계층·상태표(기본/로딩/빈/오류/비활성/포커스/오래됨)·접근성 시퀀스 | `docs/evidence/design-0.3-handoff.md` |
| D2 | designer → senior_designer | 메뉴바 팝오버·개요·세션 화면 와이어프레임(마크다운+ASCII, 필요 시 SwiftUI 프리뷰 스크린샷) 2안 | senior_designer 판정 포함 핸드오프 |
| D3 | Fable | IA·와이어프레임 결정 (사용자 지시 2026-10-30: 승인 게이트 생략) | 결정 근거 기록 |
| D4 | default | 본보기: 팝오버 1개 구현 + 스크린샷 | Fable 검토 후 롤아웃(사용자 확인 생략) |

### P3 — UI 구현 (브랜치 `claude/0.3-ui`, A-시리즈 머지 후 rebase)
| ID | 역할 | 목표 | 의존 | 검사 |
|---|---|---|---|---|
| U1 | default | `Window` 씬 + `NavigationSplitView` 골격 + 라우팅 + 빈 화면들 + 접근성 ID | D4 | XCUITest: 메뉴에서 창 열기, 6개 사이드바 항목 이동 |
| U2 | default | 팝오버 재설계(상태 아이콘 3단계, 주의 ≤5, 최근 조치+되돌리기) | U1 | 픽스처 XCUITest + 실기 스크린샷 |
| U3 | default | 세션 화면(트리, 합계, 세션 단위 일시 정지/재개) | U1, A3 | 실기 cross-check: 창 값 = `sessions --json` |
| U4 | default (U3와 병렬) | 조치 기록 화면 + 되돌리기(⌘Z) | U1, A5 | 픽스처 XCUITest + 실기: 일회용 프로세스 자동 정지→기록→되돌리기 |
| U5 | default | 전체 프로세스 화면(검색·필터·키보드) + 감지 규칙·설정 화면(규칙 파일 편집 UI 포함) | U1, A4 | XCUITest 검색/규칙 반영 |
| U6 | bulk | VoiceOver 레이블·안내문·포커스 복귀 일괄 | U2–U5 | 접근성 트리 덤프에 이름 없는 컨트롤 0개 |
| U7 | tester | XCUITest 10회 반복 안정성(About 플레이크 포함) | U6 | 10/10 통과 또는 플레이크 원인 보고 |

### P4 — 실제 앱 QA (Fable 직접, cua-driver)
| ID | 작업 | 검사 |
|---|---|---|
| Q1 | Release 빌드를 `~/Applications`에 후보 설치(사용자 앱 SIGTERM 전 `stopped --json == []` 확인) | 실행·메뉴바 아이콘 노출(Hidden Bar 주의) |
| Q2 | `scripts/ui-crosscheck.sh`: 접근성 트리에서 세션·프로세스 값 추출 ↔ CLI JSON 대조 | 불일치 0 |
| Q3 | 시나리오: 가짜 에이전트 세션 폭주 → 주의 표시 → 세션 일시 정지(옵션 켬) → 기록 → 되돌리기 → 종료 확인 카드 취소 | 스크린샷 + journal 증거 |
| Q4 | 오래된 샘플링(샘플러 멈춤 픽스처) → 제어 비활성화 확인 | 스크린샷 |
| Q5 | 1시간 soak(`scripts/soak-candidate.sh`) — 메모리·CPU 추이 | analyze-soak 결과 |

### P5 — 릴리스 0.3.0
- 기존 파이프라인. 문서 4종 + 릴리스 노트("화면 구조 변경", "정확도", "조치 기록") + evidence `release-v0.3.0-*.md`.
- 설치 후 `doctor`, 로그인 항목 재등록 확인(0.2.6 메커니즘).

## 5. 일정 감각과 정지 지점

- P0 → P1(A1~A7) → R1(0.2.7) → P2(D1~D3 승인 대기) → D4 본보기 확인 → P3 → P4 → P5.
- 2026-10-30 사용자 지시로 D3·D4의 사용자 승인을 생략한다. 전 구간을 기존 자율 권한으로 진행한다(커밋·푸시·릴리스·워크트리 정리, 메이저 금지). 사용자에게 돌아가는 경우는 안전 계약 경계와 모델 실패 영수증뿐.
- 열린 질문(답 없으면 괄호 안으로 진행): 0.3.0 마이너 가능 여부(가능으로), 세션 자동 정지 옵션 추가(기본 꺼짐으로 추가).

## 6. 위험

- Cursor "Other Models" 버킷 0%: 디자인 레인 모델이 실패할 수 있음 → 실패 영수증 보고 후 사용자 선택.
- `MenuBarExtra` + `Window` 동시 사용 시 창 닫힘·활성화 정책(`NSApp.setActivationPolicy`) 이슈 → U1에서 먼저 검증.
- 세션 집계는 트리 깊이에 비례; 1,100개 프로세스에서 샘플링 5ms 유지 목표, 넘으면 memo 재사용 강제.
- `suspected` 휴리스틱 오탐 → 표시 전용이며 사용자 규칙으로 끌 수 있게 한다.
- 워커가 Xcode 프로젝트를 깨뜨릴 수 있음 → 모든 패치 적용 후 `xcodegen generate` + 전체 테스트를 Fable이 재실행.
