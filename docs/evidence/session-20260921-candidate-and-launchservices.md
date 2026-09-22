# 세션 증거 — 후보 재빌드, LaunchServices 근본 원인, soak 기동 (2026-09-21)

대상 worktree: `/Users/justn/dev/.worktrees/watchdog-completion-owner` (branch `codex/watchdog-completion-owner`, HEAD `07d35f5`, dirty)

## 1. 후보 재빌드 (A21/A22 재확인)

`scripts/build-candidate.sh --output-dir /tmp/wd-candidate-20260921`

- version `0.2.0`, build `5`, architectures `x86_64 arm64`
- `codesign --verify --deep --strict` → `valid on disk` / `satisfies its Designated Requirement`
- signature `adhoc`, `get_task_allow: false`

## 2. LaunchServices 근본 원인 규명 (A15의 "ambiguity" 해소)

`dev.justn.watchdog` 등록이 **95개**였다. 그중 실제 존재하는 후보 외 경로:

- `~/Applications/.Watchdog.app.backup-20260901-144351|1455|1517` (옛 네이밍, 현재 스크립트는 `.Watchdog.app.backup.$$` 형식)
- `/private/tmp/watchdog-*`, `~/dev/watchdog/DerivedData/*` 등 다수 (대부분 이미 삭제된 경로)

**직접 영향 확인:** 정리 전 `cua-driver launch_app {bundle_id: dev.justn.watchdog}`가 가장 최근에 설치한 `~/Applications/Watchdog.app`이 아니라
`.Watchdog.app.backup-20260901-144351/Contents/MacOS/Watchdog`(pid 40517)을 실행했다.

`lsregister -u`로 stale 등록 100개를 제거한 뒤 같은 호출이 `~/Applications/Watchdog.app`(pid 52429)을 실행했다.

### 반증된 가설 (기록용)

"installer가 `~/Applications`에 남기는 백업이 등록된 채 남아 실행을 가로챈다"는 가설은 **재현되지 않았다**:

- pre-fix 스크립트(`git show HEAD:scripts/install.sh`)로 disposable 디렉터리에 2회 설치 → 등록은 target 경로 1개, 백업 잔존 없음
- 등록된 번들을 `mv`로 백업 이름으로 옮겨도 LaunchServices 레코드는 **원래 경로에 그대로 남고** 백업 경로를 새로 등록하지 않음
- 성공 경로에서 `rm -rf "$backup_app"`가 백업을 제거하므로 정상 설치 후 잔존물이 없음

추가로 **위치 이전도 해결책이 아님을 확인**했다: `~/Library/Application Support/Watchdog/InstallerBackups/Stray.app`에 둔 동일 번들도 등록됐다.
LaunchServices는 볼륨 어디든 앱 번들을 인덱싱하므로, **같은 CFBundleIdentifier 복사본이 디스크에 존재하는 한 모호성은 남는다.**
따라서 `scripts/install.sh`는 수정하지 않고 원상 복구했다(남은 diff는 세션 이전부터 있던 owner 변경뿐).

실질적 완화책은 운영 조치다: 잔존 동일-ID 복사본을 제거하고 `lsregister -u`로 등록을 해제한다.

## 3. 후보 아티팩트가 소스를 식별하지 못하던 문제 수정

`manifest.json`은 `source_sha = git rev-parse HEAD`만 기록했는데, 후보는 **dirty worktree**에서 빌드됐다.
HEAD만으로는 서로 다른 두 후보를 구분할 수 없어 B12의 "모든 receipt가 같은 SHA/hash" 바인딩이 성립하지 않는다.

`scripts/build-candidate.sh`에 빌드 **이전** 소스 상태 기록을 추가했다:

- `source_tree`: 임시 인덱스(`GIT_INDEX_FILE`)로 `read-tree HEAD` → `add -A` → `write-tree`한 트리 해시
- `source_dirty`: `git status --porcelain` 비어있지 않으면 true

검증: `source_tree = 8049f91fbdcf0ec4d741d8e258e7aba12ab80dee`, `source_dirty = true`,
같은 시점의 `git rev-parse HEAD^{tree} = 27224a92283932e44beab3037333804555009d11` → dirty 델타가 실제로 반영됨.
`bash -n`, `shellcheck` 통과.

### 후보 바이너리 비재현성 (기록)

동일 소스·동일 설정으로 두 번 빌드했는데 실행 파일 해시가 다르다:

| 빌드 | `Contents/MacOS/Watchdog` sha256 |
|---|---|
| 1회차 (설치본) | `6674f98db564e07820223bff0745f2d7a825bdec41d6606dfe55dc773e4f9b59` |
| 2회차 | `f92ec75bec4683e769699f3da8e7206434f999e306e196c3be1b391e0231e8b9` |

ZIP/DMG 해시도 회차마다 달라진다(`7947616524…` → `3f14f7d1…`). 따라서 후보 동일성은 **정확한 바이너리/아티팩트 해시**에만 바인딩해야 하며,
`source_tree`가 그 위에 소스 수준 식별자를 제공한다.

## 4. 8시간 soak 기동

- candidate: `~/Applications/Watchdog.app`, pid `52429`, executable sha256 `6674f98d…`
- helper: `WatchdogE2EHelper` pid `55385` (1초 heartbeat, `~/.../wd-soak-state-20260921/heartbeat.txt`)
- sampler: `scripts/soak-candidate.sh --app ~/Applications/Watchdog.app --pid 52429 --output-dir /tmp/wd-soak-20260921 --heartbeat …`
- `started_at` `2026-09-21T08:42:07Z`, `duration_seconds` 28800, `interval_seconds` 60
- 첫 sample: `08:42:08Z, 78480 KB, 0.1%, fd 38, heartbeat 8`

candidate는 이 세션에서 `ditto`로 설치했고 기존 `~/Applications/Watchdog.app`은
`.Watchdog.app.backup-precandidate-20260921-173953`으로 백업했다(UserDefaults는 bundle id 기준이라 보존).

## 5. 미해결

- `~/Applications/.Watchdog.app.backup-20260901-144351`이 아직 존재하고 재등록된다. 제거에는 사용자 확인이 필요하다.
- A19/A23/B07/B08/B09는 GUI 조작 또는 재로그인이 필요하다. B08(로그인 시 자동 실행)은 실제 로그아웃이 필요해 에이전트가 수행할 수 없다.
