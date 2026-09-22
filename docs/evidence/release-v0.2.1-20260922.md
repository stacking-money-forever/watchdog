# Watchdog v0.2.1 릴리스 기록 (2026-09-22)

## 릴리스

| 항목 | 값 |
|---|---|
| 태그 | `v0.2.1` |
| 태그 대상 | `100354e` (main, PR #18 병합 커밋) |
| 제목 | `Watchdog 0.2.1 (unnotarized beta)` |
| 게시 | 2026-09-22T00:25:28Z, draft=false, prerelease=false |
| URL | <https://github.com/stacking-money-forever/watchdog/releases/tag/v0.2.1> |

정식 릴리스(prerelease 아님)로 게시한 이유: 노트 제목과 "Known limitations" 절에 unnotarized beta임을 명시했고,
prerelease로 표시하면 Releases의 Latest가 구버전 `v0.2.0`으로 남아 설치 문서(`v0.2.1`)와 어긋나기 때문이다.

## 자산과 해시 (3자 일치)

| 파일 | 빌드 산출물 | manifest | GitHub 자산 digest | 직접 다운로드 |
|---|---|---|---|---|
| `Watchdog-0.2.1-macos.zip` | `9153bef5…` | `9153bef5…` | `sha256:9153bef5…` | `9153bef5…` |
| `Watchdog-0.2.1-macos.dmg` | `0b489544…` | `0b489544…` | `sha256:0b489544…` | `0b489544…` |

전체 값:
- zip `9153bef56fb0871cc10718d21b6351c47e64e9dea19d2374d51135d66d1bebd7`
- dmg `0b489544c217d5f27820ccc23025872f247450a4860aada9b1d5ecca04d1822b`

## 소스 바인딩 (검증됨)

아티팩트는 커밋 `f0172fd`에서 `source_dirty=false`로 빌드됐고, `manifest.json`의
`source_tree`는 `a3d80607fb26adb640dec6328162de1868d73e11` — **`f0172fd`의 트리와 정확히 일치**한다.

태그가 가리키는 `100354e`의 트리는 `fcd727a6…`로 다르지만, 차이는 문서 3개 파일뿐임을 확인했다:

```
git diff --stat f0172fd 100354e
  INSTALL.md          | 16 ++++----
  README.md           |  8 +++---
  scripts/install.sh  |  6 +++---
```

소스 서브트리는 전부 동일하다(`Watchdog`, `WatchdogPreview`, `WatchdogSnapshot`, `WatchdogTests`,
`WatchdogUITests`, `WatchdogE2EHelper`, `WatchdogLiveQA`, `project.yml` — 각각 `git rev-parse`로 확인).
즉 태그의 문서는 이 릴리스 자산의 해시를 정확히 기록하고, 코드는 아티팩트와 바이트 단위로 같다.

## End-to-end 설치 검증

게시된 릴리스에 대해 저장소의 문서화된 installer를 그대로 실행했다:

```
$ ./scripts/install.sh --install-dir /tmp/wd-install-verify --no-launch
Downloading v0.2.1…
Checksum verified: 9153bef56fb0871cc10718d21b6351c47e64e9dea19d2374d51135d66d1bebd7
Watchdog.app: valid on disk / satisfies its Designated Requirement
Installed Watchdog 0.2.1 (6) at /private/tmp/wd-install-verify/Watchdog.app
```

설치본 확인: `CFBundleShortVersionString 0.2.1`, `CFBundleVersion 6`, `codesign --verify --deep --strict` 통과,
실행 파일 sha256 `d75457b30ac50494474fec46752fe2dcce6a6c284094404032154757fdebbabe`.
검증 후 임시 설치본과 LaunchServices 등록은 제거했다.

## 릴리스 노트에 명시한 한계

- ad-hoc 서명 + 미공증 → Gatekeeper 거부. Finder 우클릭 → 열기, 또는 시스템 설정 → 그래도 열기. 전역 비활성화·`xattr` 제거 금지.
- 게시 시점에 8시간 안정성 soak이 아직 진행 중이었다.
- clean account에서의 앱별 Gatekeeper 승인 미관찰.
- 실제 알림 배너, 로그아웃 후 로그인 자동 실행, 키보드·VoiceOver 미검증.

## 릴리스 바이너리로 A28 재시작

릴리스와 동일한 실행 파일을 측정하도록 soak을 다시 걸었다:

- candidate pid `72785`, version `0.2.1` build `6`, executable sha256 `d75457b3…`
  (게시 ZIP에서 설치한 앱의 실행 파일과 동일 해시)
- `started_at` `2026-09-22T00:26:45Z`, `duration_seconds` 28800, `interval_seconds` 60
- 출력 `/tmp/wd-soak-rel`, 종료 예정 `2026-09-22T08:26:45Z`(KST 17:26:45)
- 첫 sample fd 38
