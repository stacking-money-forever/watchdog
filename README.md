# Watchdog

Watchdog는 폭주하거나 고아가 된 프로세스를 터미널 명령 없이 찾아 정리할 수 있는 네이티브 macOS 메뉴바 유틸리티입니다.

## 설치

요구 사항: macOS 14 이상. 사람·에이전트 공통 상세 절차는 **[INSTALL.md](INSTALL.md)**가 기준입니다.

### 사람이 설치

1. [GitHub Releases](https://github.com/stacking-money-forever/watchdog/releases)에서 최신 DMG를 내려받습니다.
2. DMG를 열고 Watchdog을 Applications 폴더로 드래그합니다.
3. 현재 공개 배포본은 ad-hoc 서명(Team ID 없음)이며 Apple 공증·스테이플링이 없어 Gatekeeper 평가(`spctl`)를 통과하지 못합니다. 최초 실행 시 Finder에서 Watchdog을 우클릭하고 **열기 → 열기**를 선택합니다.

우클릭으로 열리지 않으면 한 번 실행을 시도한 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기**를 선택합니다. 이는 Apple이 제공하는 앱별 승인 절차입니다. 전역 Gatekeeper 비활성화나 격리 속성 제거는 필요하지 않습니다.

공식 배포 파일은 이 저장소의 Releases에서만 제공합니다. `v0.2.7` 파일 무결성:

```text
Watchdog-0.2.7-macos.zip  b9207305d1f612da6ea3d4fc5a05af43f1bcd1a0b0f834aff214a16aab381cd3
Watchdog-0.2.7-macos.dmg  36d1c7a0dcefb0fbba503eb8352d81d45061db570b249c11b7cb4effbccb0f0e
```

검증 명령:

```bash
shasum -a 256 Watchdog-0.2.7-macos.dmg
```

### 에이전트·터미널에서 설치

```bash
git clone https://github.com/stacking-money-forever/watchdog.git
cd watchdog
./scripts/install.sh
```

스크립트는 공식 릴리스 다운로드, SHA-256 확인, 코드 서명 구조 검증과 `~/Applications` 설치만 수행합니다. `sudo`, `SIGKILL`, Gatekeeper 비활성화 또는 quarantine 제거는 사용하지 않습니다.

## 주요 기능

- 앱 실행 직후 메뉴를 열지 않아도 2초 주기로 감시를 시작합니다.
- 프로세스 목록과 작업 디렉터리를 `ps`·`lsof` 같은 하위 프로세스 없이 커널에서 직접 읽어, 시스템이 무거울 때도 샘플링이 실패하지 않습니다.
- 프로세스 CPU 누적 시간의 구간별 차이와 실제 메모리 사용량을 확인합니다.
- CPU·메모리 임계값을 지속해서 넘긴 프로세스를 이유와 함께 표시합니다. 임계값 근처에서 오르내리는 프로세스가 깜빡이지 않도록 해제 구간(CPU 80%, 메모리 90%)을 둡니다. 고아 의심 에이전트는 경고가 아닌 정보로 표시합니다.
- 코딩 에이전트는 실행 파일 이름(claude, codex, opencode, omp, amp, copilot, cursor-agent 등)으로, npm·pip로 설치되어 `node`·`python`으로 실행되는 에이전트(gemini, pi, aider 등)는 스크립트 경로로 알아봅니다. 앱 번들 안의 바이너리(예: ChatGPT.app의 codex)는 그 앱의 일부로 봅니다. 에이전트가 띄운 빌드·테스트·MCP 서버는 어느 에이전트가 시작했는지와 그 프로젝트를 함께 표시합니다.
- 지원하는 코딩 에이전트의 작업 디렉터리와 프로젝트명을 조회하고, 해당 경로가 정리 가능한 워크트리인지 알려줍니다. Git 조회는 `--no-optional-locks`로 실행해 에이전트의 커밋을 방해하지 않습니다.
- 에이전트 하나와 그 자손(빌드·테스트·MCP 서버)을 **세션**으로 묶어 CPU·메모리 합계로 보여 주고, 합계가 임계값을 지속해서 넘기면 세션 단위로 경고합니다(`watchdog-cli sessions`).
- launchd 아래 상주하도록 만든 서비스(`opencode serve`, `codex app-server`, 사용자 데몬)는 고아로 보지 않습니다. 반대로 임시 폴더(`$TMPDIR`, scratchpad)에서 시작돼 부모 없이 남은 프로세스는 종류와 상관없이 "임시 폴더에서 시작된 채 남아 있습니다"로 표시합니다. 분류 정확도는 이 Mac의 실제 프로세스 트리 1,151개를 라벨링한 픽스처로 재며, 테스트가 불일치 0건을 지킵니다(`watchdog-cli audit`).
- 목록에 없는 에이전트는 `~/Library/Application Support/Watchdog/agent-rules.json`으로 추가할 수 있습니다(이름·패키지 경로·서비스 서브커맨드·세션 호스트, 제외 이름). 세션 호스트 아래에서 TTY를 갖고 패키지 경로의 스크립트를 실행하는 `node`·`python` 프로세스는 "에이전트일 수 있음"으로 표시만 하고 자동으로 멈추지 않습니다(`watchdog-cli rules`).
- Watchdog이 보낸 모든 시그널은 `~/Library/Application Support/Watchdog/journal.jsonl`에 출처(앱·자동·CLI)·사유·결과와 함께 남습니다(`watchdog-cli journal`).
- 감지 규칙에서 자동 일시 정지를 켜면 CPU 임계값을 지속해서 넘긴 코딩 에이전트에만 되돌릴 수 있는 SIGSTOP을 보냅니다. 메모리만 넘긴 프로세스나 일반 앱, 서비스는 멈추지 않고, 직접 재개한 프로세스는 다시 멈추지 않습니다. 재개는 항상 수동입니다. 범위를 세션으로 바꾸면(기본값은 에이전트만) 세션 합계가 지속 초과할 때 루트와 자손을 함께 멈추고 함께 재개합니다. 자손만 멈추는 동작은 없습니다.
- Watchdog이 멈춘 프로세스는 기록으로 남아 "주의 필요"에 계속 보이고, Watchdog을 종료할 때 멈춘 프로세스가 있으면 재개 후 종료할지 묻습니다.
- 경고를 해당 프로세스가 종료될 때까지 무시하고 즉시 되돌릴 수 있습니다.
- 현재 사용자 소유 프로세스를 일시 정지, 재개, 종료 또는 강제 종료합니다.
- 첫 실행 시 로그인 항목에 자동 등록되며, 감지 규칙에서 끌 수 있습니다.

## 터미널 명령 (`watchdog-cli`)

앱 번들에 함께 들어 있는 CLI로, 메뉴바 앱과 같은 감지·제어 코드를 터미널에서 실행합니다. 경로는 `Watchdog.app/Contents/MacOS/watchdog-cli`이며, `./scripts/install.sh --link-cli`로 `~/.local/bin/watchdog-cli`에 연결할 수 있습니다.

```bash
watchdog-cli list --scope agents          # TOKEN(pid:시작시각:uid)과 함께 목록
watchdog-cli inspect <TOKEN|PID>          # 작업 디렉터리·워크트리 상태까지 상세 정보
watchdog-cli sessions                     # 에이전트 세션별 CPU·메모리 합계와 멤버 수
watchdog-cli watch --auto-suspend --only <TOKEN> --json  # 지속 감시; --only로 자동 정지 대상을 제한
watchdog-cli suspend <TOKEN|PID>          # SIGSTOP (되돌릴 수 있음)
watchdog-cli terminate <TOKEN>            # 차단되고 무엇을 할지만 출력 (exit 3)
watchdog-cli terminate <TOKEN> --force    # 실제 SIGTERM 후 종료 확인
watchdog-cli stopped --resume-all         # Watchdog이 멈춘 프로세스 재개
watchdog-cli doctor                       # 샘플링 비용과 환경 진단
watchdog-cli journal                      # Watchdog이 보낸 시그널 기록
watchdog-cli rules show                   # 사용자 규칙 파일 상태 (init·validate)
watchdog-cli audit <스냅샷> --labels <라벨>  # 분류 정확도 측정 (snapshot으로 저장)
```

- `terminate`·`force-quit`은 PID만으로 실행할 수 없고 TOKEN과 `--force`가 모두 필요합니다.
- `--force`로도 PID 1, Watchdog 자신, 다른 사용자, 시스템 경로, 신원 불일치·확인 불가 대상은 거부됩니다(exit 4).
- `watch --auto-suspend`는 머신 전체를 감시합니다. 스크립트나 테스트에서 쓸 때는 반드시 `--only`로 대상을 제한하세요. 그러지 않으면 조건을 넘긴 다른 세션도 멈춥니다.
- 종료 코드: 0 성공 · 1 실패 · 2 사용법 오류 · 3 `--force` 필요 · 4 안전 계약상 거부.
- JSON 필드와 enum 문자열은 [`docs/cli-json.md`](docs/cli-json.md)에 고정되어 있습니다.
- 앱과 CLI는 같은 정지 기록을 공유하므로, CLI로 멈춘 프로세스도 메뉴의 "주의 필요"에 보입니다.

## 안전 계약

- 시스템·다른 사용자·PID 1·Watchdog 자체와 신원을 확인할 수 없는 프로세스는 제어하지 않습니다.
- 모든 동작은 PID, 사용자 ID, 시작 시각, 최신 관측 세대를 결합한 단일 사용 권한을 거칩니다.
- 표본이 5초 이상 오래됐거나 수집에 실패하면 기존 정보는 참고용으로 남지만 모든 제어가 차단됩니다.
- 일반 종료는 `SIGTERM`만 사용하며 종료 여부를 별도로 확인합니다.
- `SIGKILL`은 별도의 강제 종료 확인을 완료한 경우에만 한 번 전송합니다. 시간 초과나 경고가 자동 강제 종료로 이어지지 않습니다.
- 자동 일시 정지는 되돌릴 수 있는 `SIGSTOP`만 사용하며, 강제 종료로 이어지지 않습니다.
- PID 확인과 `kill(2)` 사이의 운영체제 수준 경쟁 조건을 완전히 제거할 수는 없으므로, 전송 직전 신원을 다시 검사하고 전송 후 결과를 재확인합니다.

## 감지 설정

| 설정 | 기본값 | 지원 범위 |
|---|---:|---:|
| CPU 임계값 | 100% | 1–1000% |
| 지속 시간 | 20초 | 2–300초 |
| 프로세스 메모리 | 2 GiB | 0.1–1024 GiB |

저장된 값이 숫자가 아니거나 무한대·범위 밖 값이면 시작 시 안전한 범위로 정규화됩니다. CPU와 메모리의 지속 시간은 벽시계가 아닌 단조 시계로 계산하며, 수집 실패나 5초를 넘는 관측 공백은 누적을 초기화합니다.

## 소스에서 빌드

요구 사항: Xcode 16 이상, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
git clone https://github.com/stacking-money-forever/watchdog.git
cd watchdog
xcodegen generate
xcodebuild -project Watchdog.xcodeproj -scheme Watchdog -configuration Debug build
```

전체 검증:

```bash
xcodebuild -project Watchdog.xcodeproj -scheme Watchdog -configuration Debug test
xcodebuild -project Watchdog.xcodeproj -scheme Watchdog -configuration Release build
```

### 검증 스크립트

- `scripts/cli-e2e.sh`는 직접 띄운 일회용 프로세스만 대상으로 CLI 전체 경로를 검증하고, 별도 정지 기록 파일(`WATCHDOG_LEDGER_PATH`)을 씁니다.
- `scripts/launch-smoke.sh <Watchdog.app>`은 출시 실행 경로의 단일 인스턴스 동작을 로그인 항목 등록 없이 확인합니다.
- `scripts/soak-candidate.sh`와 `scripts/analyze-soak.sh`는 장시간 실행 시 메모리·CPU·FD 추세를 기록하고 요약합니다.

`WatchdogPreview`는 합성 프로세스 상태로 메뉴 화면과 접근성을 검증하는 개발 전용 창입니다. `WatchdogUITests`는 실제 프로세스에 시그널을 보내지 않습니다.

`project.yml`이 Xcode 프로젝트 구성의 유일한 기준입니다. 대상이나 파일 배치를 변경한 뒤에는 XcodeGen으로 프로젝트를 재생성합니다.

## 배포 정책

Watchdog는 유료 Apple Developer Program에 의존하지 않는 공개판으로 배포합니다. Developer ID 공증은 현재 릴리스 조건이 아니며, 사용자는 최초 실행 시 macOS의 앱별 승인 절차를 거쳐야 합니다. 공식 GitHub Releases, 고정 SHA-256, 코드 서명 구조 검증, 재현 가능한 소스 빌드 절차로 배포 무결성을 보완합니다.

단위·통합·UI 테스트, Debug/Release 빌드, 앱 실행 스모크와 장기 실행 리소스 검증은 공증 여부와 관계없이 릴리스 품질 게이트로 유지합니다. 향후 공증 배포를 선택할 경우에만 Developer ID 서명, 올바른 Team ID, Apple 공증 `Accepted`, stapling과 Gatekeeper 검증을 추가로 요구합니다.

## 라이선스

[MIT License](LICENSE)
