# Watchdog v0.2.4 릴리스 기록 (2026-10-27)

## 릴리스

| 항목 | 값 |
|---|---|
| 태그 | `v0.2.4` |
| 태그 대상 | `126767e` (main, PR #26 병합 커밋, 빌드 소스와 동일) |
| 제목 | `Watchdog 0.2.4 (unnotarized beta)` |
| 게시 | 2026-10-27T01:16:45Z |
| URL | <https://github.com/stacking-money-forever/watchdog/releases/tag/v0.2.4> |
| 버전 | 0.2.4 (build 9), 패치 릴리스 |

## 계기

v0.2.3을 설치한 뒤 코드 리뷰를 세 갈래(Core, SwiftUI 앱, 생명주기·CLI·설치)로 나눠 진행했습니다. 그중 상시 실행에 직결되는 항목을 고쳤습니다.

가장 큰 문제는 로그인 자동 등록이 실제로 한 번도 동작하지 않았다는 점입니다. 실행 중인 0.2.3의 시스템 로그에서 `[SMAppService] Service status: 3`(`.notFound`)을 확인했습니다. 등록 가드는 `.notRegistered`만 받았기 때문에 첫 설치 상태인 `.notFound`에서는 `register()`가 호출되지 않았습니다.

## 포함 변경 (PR #26)

- **로그인 자동 등록**
  - `.notFound`도 등록 대상으로 받습니다.
  - 등록 판단 과정을 `os.Logger`(category `login-item`)로 남깁니다.
  - 마지막 상태와 오류를 defaults에 저장합니다.
  - `doctor` 출력에 "로그인 시 실행" 줄을 추가했습니다.
- **중복 실행:** 두 번째 인스턴스는 종료 프롬프트를 띄우지 않고 바로 종료합니다.
- **정지 기록**
  - 샘플을 근거로 기록을 지우기 전에 실제 상태를 다시 조회합니다.
  - SIGSTOP을 보내기 전에 기록을 먼저 씁니다. 기록하지 못하면 정지하지 않습니다(`ledgerUnavailable`).
  - CLI가 쓴 기록은 5초 동안 보존합니다.
  - 파일을 레코드 단위로 디코드하고, 손상된 원본은 한 번만 따로 보존합니다.
- **재개 후 종료**
  - 무시 중인 프로세스도 재개할 수 있습니다.
  - 재개에 실패한 프로세스가 있으면 앱을 종료하지 않고 알립니다.
- **install.sh**
  - 기존 앱을 종료하기 전에 쓰기 권한부터 확인합니다.
  - Watchdog이 정지한 프로세스가 있는데 `--no-launch`로 실행하면 설치를 중단합니다.
  - 교체에 실패하면 이전 앱을 복원하고 다시 실행합니다.
- **CLI**
  - `watch`의 연속성 공백 기준을 `max(5s, 2.5 × interval)`로 바꿨습니다.
  - `--count` 값을 검증합니다.
  - 사용자가 직접 재개한 프로세스는 다시 정지하지 않습니다.
  - 이미 정지돼 있던 프로세스는 기록하지 않습니다.
  - `stopped --resume-all --json`이 JSON을 출력합니다.
- **워크트리:** upstream이 없으면 `rev-list --count HEAD --not --remotes`로 원격 어디에도 없는 커밋 수를 셉니다.
- **성능**
  - 값이 바뀌었을 때만 publish합니다.
  - scene이 monitor를 관찰하지 않습니다. 메뉴바 라벨은 `alertCount`만 구독합니다.
  - 스피너는 사용자가 직접 새로고침했을 때만 표시합니다.
  - 작업 디렉터리가 그대로면 다시 반영하지 않습니다.
  - worktree git 조회는 패널이 열려 있을 때만 합니다.
  - 확인 창은 샘플링 실패 시나 30초가 지나면 닫습니다.

## 자산과 해시 (3자 일치: manifest, GitHub digest, 직접 다운로드)

- zip `2c32e59568fea25ebd601d407be9b6b6f3828d3722c01073b8f223ac5a8c6877`
- dmg `ae4ae10b24d8a5d736be481618824faa68fff3a8a67de7b88f7ce1c05b27ae23`

## 소스 바인딩

- 새로 clone한 main `126767e`에서 빌드했습니다.
- manifest 값은 `source_tree=0a01fbc8b7b08744f127de65c3e56942742c5ac8`, `source_dirty=false`입니다.
- 앱 실행 파일 sha256: `a15bbbdb9fc44f2463f11c3734b809f845d5fec2b5cffdc047ec8750a3e8c2a4`
- CLI sha256: `4c88fce67c4249bba431c49e91f9014742bdcfca22281d61f28b32cded3234ef`
- codesign은 ad-hoc 서명이며 `TeamIdentifier=not set`입니다. `spctl`은 거부하며, 이는 예상된 결과입니다.

## 테스트

| 위치 | 단위 | UI | CLI e2e | 실행 스모크 | 빌드 |
|---|---|---|---|---|---|
| 로컬 | 141/141 | 10/10 | 42/42 | 4/4 (후보 앱) | Release 5개 스킴, Debug Watchdog·Snapshot |
| CI PR #26 | 통과 | 통과 | 통과 | 통과 | 통과 |

`install.sh`가 쓰기 불가 디렉터리를 만나면 다음과 같이 멈추는 것을 확인했습니다.
- 출력: "Cannot write to … nothing was changed"
- 실행 중이던 Watchdog은 그대로 유지됐습니다.

## 실사용 설치 확인

이 브랜치의 `install.sh --link-cli`로 `~/Applications`에 0.2.3을 0.2.4로 교체 설치했습니다.

- `watchdog-cli doctor` 결과
  - "앱 실행 중: 예"
  - **"로그인 시 실행: 켜짐"**
  - "문제 없음"
- defaults 값: `launchAtLogin.didAutoRegister=1`, `launchAtLogin.lastStatus=enabled`

0.2.3 때 우회책으로 넣었던 레거시 로그인 항목(System Events)은 제거된 상태입니다.

## CPU A/B (패널 닫힘, 빌드 없는 상태, 각 180초)

| | 누적 CPU | 평균 |
|---|---|---|
| 0.2.3 (설치본) | 4.56초 | 2.53% |
| 0.2.4 (Release) | 2.11초 | 1.17% |

## 남은 한계

- 공증받지 않은 ad-hoc 베타입니다.
- 0.2.4를 장시간 soak하지 않았습니다. 근거는 3분 A/B 측정과, 앞서 패널을 열고 닫으며 진행한 메모리 측정입니다.
- 미뤄 둔 작업
  - CLI JSON 필드의 기계 안정성(한국어 메시지와 enum 분리)
  - VoiceOver 안내, 확인 창 포커스
  - 행 `Equatable` 최적화
  - 패널이 닫혀 있을 때 `processes` publish를 생략하는 것
