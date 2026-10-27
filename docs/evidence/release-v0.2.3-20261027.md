# Watchdog v0.2.3 릴리스 기록 (2026-10-27)

## 릴리스

| 항목 | 값 |
|---|---|
| 태그 | `v0.2.3` |
| 태그 대상 | `a498005` (main, PR #24 병합 커밋, 빌드 소스와 동일) |
| 제목 | `Watchdog 0.2.3 (unnotarized beta)` |
| 게시 | 2026-10-27T00:24:35Z, draft=false, prerelease=false |
| URL | <https://github.com/stacking-money-forever/watchdog/releases/tag/v0.2.3> |
| 버전 | 0.2.3 (build 8), 패치 릴리스 |

## 포함 변경 (PR #24)

- `watchdog-cli`를 `Watchdog.app/Contents/MacOS/watchdog-cli`에 포함하고 함께 서명합니다. `install.sh --link-cli` 또는 `--cli-dir PATH`는 설치된 앱을 가리키는 심볼릭 링크를 만들며, 일반 파일은 덮어쓰지 않습니다.
- **닫힌 패널의 메모리 증가를 수정했습니다.** MenuBarExtra 창은 닫혀도 SwiftUI 그래프를 유지하고, 매 샘플마다 보이지 않는 행을 다시 만들었습니다. 이제 `onDisappear`부터 `onAppear` 사이에는 `Color.clear`만 그립니다. 대기 중인 확인을 포함한 `@State`는 보존됩니다.
- 패널이 열려 있는 동안 행 위치를 고정하고, 닫으면 다시 정렬합니다. UI 테스트 `testRowsHoldPositionWhileRankingChanges`를 추가했고, 고정을 끄면 이 테스트가 실패하는 것을 확인했습니다.
- 정지·재개 직후 실제 상태를 다시 조회해 행 상태를 즉시 반영합니다.
- 앱 밖에서 재개한 프로세스는 자동 정지 대상에서 제외됩니다.
- 슬라이더와 스테퍼 범위가 저장된 값을 항상 포함합니다. 오류 배너는 하나로 묶고 "외 N건"으로 표시하며, Watchdog이 정지한 행에는 배지를 붙입니다.
- `analyze-soak.sh`가 CPU 평균과 최댓값, 워밍업 이후 RSS 증가량을 출력합니다.

## 자산과 해시 (3자 일치)

| 파일 | 빌드 산출물·manifest | GitHub 자산 digest | 직접 다운로드 |
|---|---|---|---|
| `Watchdog-0.2.3-macos.zip` | `39e03934…` | `sha256:39e03934…` | `39e03934…` |
| `Watchdog-0.2.3-macos.dmg` | `b4911ee3…` | `sha256:b4911ee3…` | `b4911ee3…` |

전체 값:
- zip `39e03934ee327e92a3bcbea39b7d11b067330e890621584105c06990655c02f3`
- dmg `b4911ee3b7b37e11ab94d6cbf7bed29da2fa1e281803077ad4f4ec897da1d199`

## 소스 바인딩

새로 clone한 main `a498005`에서 `scripts/build-candidate.sh`로 빌드했습니다. manifest 값은 `source_sha=a498005…`, `source_tree=5a458c246db39c40250a7ab64e53aa5f0e33baa9`, `source_dirty=false`입니다. 태그 대상과 빌드 소스가 같은 커밋입니다.

## 후보 검증

- `codesign --verify --deep --strict` 통과. `Signature=adhoc`, `TeamIdentifier=not set`, `get_task_allow=false`입니다. 공증하지 않았으므로 `spctl`은 거부하며, 이는 예상된 상태입니다.
- 앱 실행 파일 sha256: `c9b9a43ba5da289d3bebc859f2356cce7c40bd3ef0569ef7c1b896f28b01135c`
- 포함된 CLI sha256: `d71704ea9eb3f04776e6c65542de807afaed16c2ead589b56259039922fa7597`. `watchdog-cli --version`의 출력은 `watchdog-cli 0.2.3`입니다.
- `scripts/launch-smoke.sh` 4/4 통과.
- 설치 e2e: `install.sh --install-dir <tmp> --no-launch --cli-dir <tmp>`를 실행했습니다.
  - 체크섬과 codesign을 검증했습니다.
  - `0.2.3 (8)` 설치를 확인했습니다.
  - 링크를 생성했고, 링크를 통해 `--version`과 `doctor`(결과: "문제 없음")를 실행했습니다.
  - 설치된 실행 파일의 해시는 후보와 같습니다.

## 테스트

| 위치 | 단위 | 출시 대상 UI | CLI e2e | 실행 스모크 | 빌드 |
|---|---|---|---|---|---|
| 로컬 (macOS 26, arm64) | 128/128 | 10/10 | 40/40 | 4/4 | Debug, Release 전 스킴 (Snapshot은 DEBUG 전용이라 Debug) |
| CI PR #24 `9cf1478`, `f7251d8` | 통과 | 통과 | 통과 | 통과 | 통과 |

로컬 UI 테스트는 macOS 자동화 모드를 인증 없이 쓸 수 있게 설정한 뒤 실행했습니다. 한 번은 herdr 권한 대화상자가 클릭을 가로채 2건이 실패했지만, 대화상자를 처리한 뒤 10/10 통과했습니다.

## Soak

### 8시간 (0.2.2 빌드, 2026-10-26T15:10Z–23:18Z, 60초 간격)

`analyze-soak.sh`는 2163초 공백 때문에 입력을 거부합니다. 맥이 잠자기 상태였던 구간입니다. 그래서 구간을 나눠 직접 계산했습니다.

| 구간 | 샘플 | RSS | FD | CPU 평균, 최대 |
|---|---|---|---|---|
| 15:10–22:24, 패널을 열지 않음 | 419 | 82.9 → 86.1 MB. 30분 워밍업 이후 증가량은 **160 KB** | 38 (일부 39–42) | 2.16%, 17.1% |
| 23:00–23:18, 깨어난 뒤 패널을 엶 | 19 | 86 → 148 MB | 49–50 | 4.36%, 30.2% |

두 번째 구간에서 footprint는 43 MB에서 66 MB로 늘었습니다. 같은 엔진을 쓰는 `watchdog-cli watch`는 같은 조건에서 4.2 MB로 평탄했습니다. 그래서 원인을 UI 계층으로 좁혔고, 위 수정으로 이어졌습니다.

### 수정 확인 (Release 빌드, `proc_pid_rusage` footprint, 초당 약 30개의 짧은 프로세스가 생성되는 조건)

| 상태 | 수정 전 | 수정 후 |
|---|---|---|
| 패널을 열지 않음 (10분) | 16.2 MB 평탄 | — |
| 열림, 주의 범위 (5분) | 26.2 → 27.3 MB | 30.6 → 26.8 MB에서 안정 |
| 열림, 전체 범위 60행 (5분) | — | 38.1 → 34.0 MB에서 안정 |
| 닫은 뒤 (4–5분) | 28.8 → 29.8 MB, 계속 증가 | 27.0 → 27.1 MB / 34.0 → 34.4 MB, 평탄 |

다시 열었을 때 AX 트리에 헤더, 범위 선택, 목록 영역, 새 관찰 시각이 보이는 것을 두 번 확인했습니다.

## 남은 한계

- 공증받지 않은 ad-hoc 베타입니다. 처음 실행할 때 macOS 승인이 필요하며, 이는 정책상 의도한 상태입니다.
- 수정 후 빌드로는 장시간 soak를 다시 돌리지 않았습니다. 근거는 위의 10–15분 단위 측정뿐입니다.
- `analyze-soak.sh`는 잠자기로 생긴 공백이 있으면 입력을 거부합니다.
