# Watchdog v0.2.6 릴리스 기록 (2026-10-27)

## 릴리스

| 항목 | 값 |
|---|---|
| 태그 | `v0.2.6` |
| 태그 대상 | `8946f13` (main, PR #30 병합 커밋, 빌드 소스와 동일) |
| 제목 | `Watchdog 0.2.6 (unnotarized beta)` |
| 게시 | 2026-10-27T10:28:01Z |
| URL | <https://github.com/stacking-money-forever/watchdog/releases/tag/v0.2.6> |
| 버전 | 0.2.6 (build 11), 패치 릴리스 |

## 계기

0.2.5를 `install.sh --link-cli`로 설치한 직후, 실제 앱이 `launchAtLogin.lastStatus=notFound`를 기록했고 `doctor`도 "등록 안 됨 (notFound)"을 보고했습니다. 0.2.4에서는 같은 Mac에서 `enabled`였습니다.

- 이 베타는 ad-hoc 서명이라 업데이트할 때마다 코드 신원이 바뀝니다. 그래서 Background Task Management가 새 빌드를 `.notFound`로 보고합니다.
- 0.2.4의 일회성 `didAutoRegister` 플래그는 이 상태를 사용자가 로그인 항목을 지운 것으로 취급해, 다시 등록하지 않았습니다.

## 포함 변경 (PR #30)

- `launchAtLogin.registeredBuild`에 등록한 빌드("버전 (빌드)")를 기록합니다.
- `.notFound`가 빌드가 바뀐 뒤에 나타나면 다시 등록합니다. 기록이 없는 0.2.4·0.2.5에서 업데이트한 경우도 포함합니다.
- 다음 경우에는 다시 등록하지 않습니다.
  - 같은 빌드에서 나타난 `.notFound`
  - `.notRegistered`
  - 사용자가 명시적으로 끈 경우(`userOptedOut`)

## 자산과 해시 (3자 일치: manifest, GitHub digest, 직접 다운로드)

- zip `0332b90641336edcef36b5e21ee2068c8b009c2d91576fe58e0a06837277251c`
- dmg `fd07e1fe5645a13c93e452a9344ab52299a5a142d58194f1d419c52f7497c92f`

## 소스 바인딩

- 새로 clone한 main `8946f13`에서 빌드했습니다.
- manifest 값은 `source_tree=7f20a0b4b4dfc899d9c9f3489585c0b09873d277`, `source_dirty=false`입니다.
- 앱 실행 파일 sha256: `1f663b29f673c99b9a4bbddc6258c39d6fc2831fa93c0cd9aa9fa73c75126c12`
- CLI sha256: `4819a92bc4e4e35fb3f8e1f7231170e8bc3cd9b1ad5c3372c65625c5dd77f3f9`
- codesign은 ad-hoc 서명이며 `TeamIdentifier=not set`입니다. `spctl`은 거부하며, 이는 예상된 결과입니다.

## 테스트

| 위치 | 단위 | UI | CLI e2e | 실행 스모크 |
|---|---|---|---|---|
| 로컬 | 158/158 | 10/10 | 44/44 | 4/4 (후보 앱) |
| CI PR #30 | 통과 | 통과 | 통과 | 통과 |
