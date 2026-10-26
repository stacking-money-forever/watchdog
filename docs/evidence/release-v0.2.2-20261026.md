# Watchdog v0.2.2 릴리스 기록 (2026-10-26)

## 릴리스

| 항목 | 값 |
|---|---|
| 태그 | `v0.2.2` |
| 태그 대상 | `c670640` (main, PR #22 병합 커밋) |
| 제목 | `Watchdog 0.2.2 (unnotarized beta)` |
| 게시 | 2026-10-26T15:01:04Z, draft=false, prerelease=false, Latest |
| URL | <https://github.com/stacking-money-forever/watchdog/releases/tag/v0.2.2> |
| 버전 | 0.2.2 (build 7), 패치 릴리스 |

## 포함 변경

- PR #20: `WatchdogCore` 분리, 검증용 `watchdog-cli`, 신뢰성 수정 전반. 가장 중요한 수정은 **Apple Silicon에서 CPU 사용률이 약 41.7배 낮게 측정되던 문제**입니다. `pti_total_*`가 Mach tick 단위라서 생긴 문제로, 이 때문에 CPU 경고와 자동 정지가 사실상 동작하지 않았습니다.
- PR #21: tty 이름(`devname(3)`)과 argv[0]을 캐시해 샘플링 비용을 약 8배 줄였습니다.
- PR #22: 설치 문서와 installer의 고정값을 갱신했습니다.

## 자산과 해시 (3자 일치)

| 파일 | 빌드 산출물·manifest | GitHub 자산 digest | 직접 다운로드 |
|---|---|---|---|
| `Watchdog-0.2.2-macos.zip` | `ed87c89f…` | `sha256:ed87c89f…` | `ed87c89f…` |
| `Watchdog-0.2.2-macos.dmg` | `e1a3e62a…` | `sha256:e1a3e62a…` | `e1a3e62a…` |

전체 값:
- zip `ed87c89f65511aa1027c1d6b7270ec29fd0ad84d5034616569989c8089addd42`
- dmg `e1a3e62a060701f9d8055952cd2d8c8b61ca5038f5b5d4ed47aba613c08d301a`

## 소스 바인딩 (검증됨)

아티팩트는 커밋 `2824ca2`(PR #21 병합)에서 `source_dirty=false`로 빌드했습니다. manifest의 `source_tree`인 `298d37354371f977de2e6a5c6fda9c0d6f075923`는 `2824ca2`의 트리와 정확히 일치합니다.

태그 대상 `c670640`과 비교하면 `AGENTS.md`, `INSTALL.md`, `README.md`, `scripts/install.sh` 4개 파일만 다릅니다. 소스 서브트리(`Watchdog`, `WatchdogCore`, `WatchdogCLI`, `WatchdogPreview`, `WatchdogSnapshot`, `WatchdogTests`, `WatchdogUITests`, `WatchdogE2EHelper`, `WatchdogLiveQA`, `project.yml`)는 `git rev-parse`로 비교한 결과 모두 같습니다.

## 후보 검증

- `codesign --verify --deep --strict` 통과. `Signature=adhoc`, `TeamIdentifier=not set`이고 `get-task-allow`는 없습니다.
- `spctl --assess` 거부. 미공증 정책에 따라 예상된 상태입니다.
- `scripts/launch-smoke.sh`를 후보 앱에 실행해 4/4 통과했습니다.
  - 첫 인스턴스가 계속 실행됩니다.
  - 두 번째 실행은 스스로 종료합니다.
  - 첫 인스턴스는 영향을 받지 않습니다.
  - SIGTERM을 받으면 종료합니다.
- 후보 앱의 실행 파일 sha256은 `6341a991593a7b0487aee05e923bc39cc016878a9806c7c7113b41bd6fcc779b`입니다.

## CI (병합 전 PR 기준, macos-15)

| PR | 단위 테스트 | 출시 대상 UI 테스트 | 실행 스모크 | CLI e2e | 빌드 |
|---|---|---|---|---|---|
| #20 | 123/123 | 9/9 | 4/4 | 40/40 | Debug·Release·Preview·Snapshot |
| #21 | 124/124 | 통과 | 통과 | 통과 | 통과 |
| #22 | 통과 | 통과 | 통과 | 통과 | 통과 |

로컬 호스트에서는 UI 테스트 러너가 macOS 자동화 권한 인증 단계에서 시작되지 못했습니다("인증이 취소되었습니다"). 그래서 UI 테스트 통과의 근거는 CI뿐입니다.

## Soak (짧은 리소스 확인)

Release 경로 앱을 `WATCHDOG_DISABLE_LOGIN_ITEM=1`과 임시 정지 기록으로 실행했습니다. `scripts/soak-candidate.sh`로 300초 동안 10초 간격, 31샘플을 수집했습니다.

| 빌드 | CPU 평균 / 최대 | RSS 처음 → 마지막 | FD |
|---|---|---|---|
| PR #20 후보(`f7c6420`) | 3.64% / 21.8% | 82.5 → 86.5 MB | 39 (1회 40) |
| PR #21 적용 Release | 2.25% / 13.4% | 82.4 → 85.5 MB | 38 (1회 39) |

`scripts/analyze-soak.sh`는 heartbeat 열이 없는 샘플(`-`)을 malformed로 판정해서 수치를 직접 집계했습니다. 8시간 soak은 이번 릴리스에서 실행하지 않았습니다.

## End-to-end 설치 검증

게시된 릴리스를 대상으로 태그 `v0.2.2` 체크아웃의 installer를 실행했습니다.

```
$ ./scripts/install.sh --install-dir <임시 디렉터리> --no-launch
Downloading v0.2.2…
Checksum verified: ed87c89f65511aa1027c1d6b7270ec29fd0ad84d5034616569989c8089addd42
Watchdog.app: valid on disk / satisfies its Designated Requirement
Installed Watchdog 0.2.2 (7)
```

설치본은 `dev.justn.watchdog` 0.2.2 (7)이고 `codesign --verify --deep --strict`를 통과했습니다. 실행 파일 sha256은 후보와 같은 `6341a991…`입니다. 검증 후 임시 설치본과 LaunchServices 등록은 제거했습니다.

## 릴리스 노트에 명시한 한계

- ad-hoc 서명과 미공증 때문에 Gatekeeper가 거부합니다. Finder 우클릭 → 열기, 또는 시스템 설정 → 그래도 열기를 사용합니다. 전역 비활성화나 `xattr` 제거는 금지입니다.
- 8시간 soak은 실행하지 않았고 5분 soak만 했습니다.
- 메뉴바 UI 자체는 개편하지 않았습니다.
- 다음은 검증하지 않았습니다: 실제 알림 배너, 로그아웃 후 로그인 자동 실행, 키보드·VoiceOver, clean account에서의 앱별 Gatekeeper 승인.
