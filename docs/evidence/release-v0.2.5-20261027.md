# Watchdog v0.2.5 릴리스 기록 (2026-10-27)

## 릴리스

| 항목 | 값 |
|---|---|
| 태그 | `v0.2.5` |
| 태그 대상 | `112dac7` (main, PR #28 병합 커밋, 빌드 소스와 동일) |
| 제목 | `Watchdog 0.2.5 (unnotarized beta)` |
| 게시 | 2026-10-27T09:15:38Z |
| URL | <https://github.com/stacking-money-forever/watchdog/releases/tag/v0.2.5> |
| 버전 | 0.2.5 (build 10), 패치 릴리스 |

## 계기

0.2.4를 설치한 뒤 "정확도가 낮다"는 피드백이 있었습니다. `watchdog-cli list`를 실제 `ps`·`lsof`·`top` 출력과 대조해 다음 오차를 확인했습니다.

- npm·pip로 설치한 에이전트(gemini, pi, npm판 codex, aider)는 argv[0]이 `node`나 `python`이라 에이전트로 인식되지 않았습니다.
  - macOS의 Python은 `…/Python.app/Contents/MacOS/Python`으로 실행되어 일반 앱으로 분류됐습니다.
- 이 Mac에 설치된 omp, amp, copilot이 에이전트 이름 목록에 없었습니다.
- 에이전트가 띄운 빌드·테스트·MCP 서버는 어느 에이전트 것인지, 어느 프로젝트인지 표시되지 않았습니다.
- 다른 에이전트, brgr, 데스크톱 호스트가 띄운 에이전트가 고아로 오탐됐습니다.
- Chrome 외의 Electron 렌더러(예: Aside)가 일반 앱으로 분류됐습니다.
- 커널이 잠자는 프로세스도 `SRUN`으로 보고해, 모든 프로세스가 `R`로 표시됐습니다(`ps`는 `S`).
- 단위 테스트 호스트와 launch-smoke가 실제 defaults의 `launchAtLogin.lastStatus`를 `notFound`로 덮어써, `doctor`가 "등록 안 됨"으로 잘못 보고했습니다.

## 포함 변경 (PR #28)

- `AgentCatalog`가 argv[0]과, 인터프리터라면 스크립트 인자(패키지 경로 또는 파일 이름)로 에이전트를 판별합니다.
  - 앱 번들 안의 바이너리(예: ChatGPT.app의 codex)는 기존 규칙대로 그 앱의 일부로 봅니다.
  - 번들 안의 인터프리터(Python.app)는 예외로, 스크립트로 판별합니다.
- `KERN_PROCARGS2`에서 스크립트 인자를 함께 읽고, 기존 argv[0] 캐시에 함께 저장합니다.
- `OrphanClassifier`
  - 비에이전트 프로세스에 가장 가까운 상위 에이전트(`agentAncestor`)를 붙입니다. 결과는 메모이즈합니다.
  - 살아 있는 에이전트 아래의 하위 에이전트는 고아가 아닙니다.
  - 세션 호스트에 cmux, Superset, Zed, Cursor, Codex, Claude, Conductor, JetBrains 계열, screen, brgr를 추가했습니다.
- 하위 프로세스의 프로젝트는 그 에이전트의 작업 디렉터리로 표시합니다.
- 실행 중인 스레드가 없으면 `S`로 표시합니다(`pti_numrunning`).
- 표시
  - CLI에 `via:<agent>#PID` 플래그를 추가했습니다.
  - JSON에 `launchScript`, `agentAncestorPID`, `agentAncestorName` 필드를 추가했습니다.
  - `inspect`에 "실행 스크립트"와 "시작한 에이전트" 항목을 추가했습니다.
  - 패널 행에 "<agent>에서 실행"을 붙입니다.
  - 검색이 스크립트 경로도 봅니다.
- 로그인 항목 진단값은 실제 앱(일반 모드, launch-smoke 제외)만 실제 defaults에 기록합니다.

## 자산과 해시 (3자 일치: manifest, GitHub digest, 직접 다운로드)

- zip `9f3ac15895ddc20b34954c2640c768ced99a53c227ed28402267ff87fc9f9874`
- dmg `09915fe74223ee07bb61de18d29b1dbf6fe109ccf9e7e0ff5e63ab9d0bc55005`

## 소스 바인딩

- 새로 clone한 main `112dac7`에서 빌드했습니다.
- manifest 값은 `source_tree=910d8afe1cbbffda321b36a44fbe99cc37e630c1`, `source_dirty=false`입니다.
- 앱 실행 파일 sha256: `0f3700411e6c0396ed1881fe352139e0b36fb83122770c2434645688accfd6fb`
- CLI sha256: `fa32e7aab5e7ca097f56e3fb263c91dbea92ff76105dee70c8d553a8ca5db710`
- codesign은 ad-hoc 서명이며 `TeamIdentifier=not set`입니다. `spctl`은 거부하며, 이는 예상된 결과입니다.

## 테스트

| 위치 | 단위 | UI | CLI e2e | 실행 스모크 |
|---|---|---|---|---|
| 로컬 | 155/155 | 10/10 | 44/44 | 4/4 (후보 앱) |
| CI PR #28 | 통과 | 통과 | 통과 | 통과 |

UI 테스트 `testAboutPanelShowsVersionAndCopyright`가 전체 실행 중 한 번 실패했습니다. 단독 재실행과 그다음 전체 재실행에서는 통과했습니다.

## 실측 대조 (이 Mac)

- 에이전트 10개가 `ps`와 일치합니다. 작업 디렉터리 기반 프로젝트명은 `lsof` cwd와 일치합니다.
- 상태 열이 `ps`와 같은 `S`를 보입니다.
- 각 claude 아래의 MCP 서버, bun, zsh, rg가 해당 claude PID로 귀속됩니다.
- 실제 프로세스로 확인했습니다.
  - `node …/@google/gemini-cli/bundle/gemini.js` → agent `gemini`
  - `python3 …/gemini.py` → agent `gemini`, 그 자식 `sleep`은 이 에이전트에 귀속됩니다.
- 샘플링 비용(Release `doctor`, 캐시 후)은 0.2.4와 0.2.5 모두 약 5ms입니다.

## 남은 한계

- 공증받지 않은 ad-hoc 베타입니다.
- 자동 일시 정지는 여전히 에이전트 자신에게만 적용됩니다. 에이전트가 띄운 하위 프로세스는 표시와 귀속만 합니다.
- 알려진 이름이나 패키지 목록에 없는 에이전트는 여전히 인식하지 못합니다.
