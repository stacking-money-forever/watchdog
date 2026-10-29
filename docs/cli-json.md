# watchdog-cli JSON 계약

기계가 읽는 `--json` 출력의 필드·타입·enum 문자열을 고정한다. 스키마 파일은 [`cli-json.schema.json`](cli-json.schema.json)이다.

## 안정성 약속

- **값은 바뀌지 않고 추가만 된다.** 이미 문서화된 enum 문자열·필드 이름을 다른 뜻으로 바꾸지 않는다.
- **제거는 메이저** 버전에서만 한다.
- `watch` 이벤트 이름은 `cleared.cpu`처럼 점과 `session-hot`처럼 하이픈이 섞여 있다. 이 철자를 그대로 유지한다.
- 저널의 `action`은 `forceQuit`(카멜)이고, `suspend`/`resume`/`terminate`/`force-quit` JSON의 `action`은 하이픈 `force-quit`이다. 둘 다 계약이다.

날짜는 ISO 8601(`JSONEncoder.dateEncodingStrategy = .iso8601`)이다. 객체 키는 정렬되어 나올 수 있으나, 소비자는 순서에 의존하지 않는다. 값이 없는 선택 필드는 키 자체가 생략된다.

## 종료 코드

| 코드 | 이름 | 의미 |
|---:|---|---|
| 0 | `success` | 성공 |
| 1 | `failure` | 실패(검증 불일치, 손상된 규칙, 샘플 실패 등) |
| 2 | `usage` | 사용법 오류 |
| 3 | `blocked` | 되돌릴 수 없는 동작에 `--force` 필요 |
| 4 | `refused` | 안전 계약상 거부(`--force`로도 불가) |

## 공통 enum

### `processKind`

`agent` · `service` · `browserRenderer` · `application` · `system` · `other`

### `orphanReason`

`reparentedToLaunchd` · `missingParent` · `cyclicLineage` · `detachedSession` · `temporaryLaunchPath`

### `alertReasonKind`

`sustainedCPU` · `sustainedMemory` · `orphan` (엔진 경고 종류. CLI JSON에는 직접 나가지 않고 `watch`의 `alert.cpu` / `alert.memory`로 대응)

### `processActionOutcome`

저널 `outcome` 고정값: `signalDelivered` · `suspended` · `resumed` · `awaitingExit` · `exited` · `stillRunning` · `identityChanged` · `verificationFailed`

실패는 접두사 `failed:` 뒤에 메시지: `failed:ledger unavailable`

### `journalSource` / `journalAction`

source: `app` · `auto` · `cli`

action: `suspend` · `resume` · `terminate` · `forceQuit`

### `autoSuspendScope`

`agent` · `session` (`watch --scope`)

### `agentConfidence`

`known` · `suspected`

### `stoppedSource`

`auto` · `manual` · `cli` (`stopped --json`의 `source`. 앱 수동 정지는 `manual`)

### `listFlags` (`list --json`의 `flags`)

고정값: `cpu` · `memory` · `orphan` · `suspected` · `stopped-by-watchdog` · `protected`

패턴: `via:<name>#<pid>` (예: `via:claude#4123`)

`inspect --json`의 `flags`는 거부 사유 문장 배열이라 이 집합이 아니다.

세션 표(텍스트) 플래그: `suspended` · `orphan` · `suspected` · `service`. 세션 JSON에는 `flags` 배열이 없다.

### `watchEventType`

`watch.start` · `auto-suspend.restrict` · `resumed.by-user` · `alert.cpu` · `alert.memory` · `cleared.cpu` · `cleared.memory` · `session-hot` · `session-high-memory` · `auto-suspend` · `auto-suspend.failed` · `auto-suspend.skipped` · `sample` · `sample.failed` · `watch.end`

`sample`은 JSON 모드가 아닐 때만 나온다. `session-hot` / `session-high-memory`는 아래 `SessionAlertEvent` 스키마다. 나머지는 `WatchEvent`.

### 제어 JSON

`result`: `ok` · `unverified` · `blocked` · `refused` · `usage` · `failed`

`action`: `suspend` · `resume` · `terminate` · `force-quit`

`stopped --resume-all --json`의 `result`: `resumed` · `failed` · `skipped`

---

## `list --json`

배열. 원소는 `ProcessRecord`. `--scope`는 `attention` · `agents` · `all`.

| 필드 | 타입 |
|---|---|
| `token` | string (`pid:startMicroseconds:uid`) |
| `pid` | number (int32) |
| `parentPID` | number |
| `userID` | number |
| `name` | string |
| `path` | string |
| `kind` | `processKind` |
| `state` | string (`ps` 상태) |
| `suspended` | bool |
| `cpuPercent` | number (소수 첫째 자리) |
| `residentBytes` | number |
| `tty` | string |
| `elapsed` | string |
| `orphanReason` | `orphanReason` 또는 null |
| `launchScript` | string 또는 null |
| `agentAncestorPID` | number 또는 null |
| `agentAncestorName` | string 또는 null |
| `workingDirectory` | string 또는 null |
| `worktree` | string 또는 null |
| `controllable` | bool |
| `watchdogSuspended` | bool |
| `flags` | string 배열 (`listFlags` + `via:` 패턴) |

```json
[
  {
    "agentAncestorName": null,
    "agentAncestorPID": null,
    "controllable": true,
    "cpuPercent": 12.3,
    "elapsed": "01:02",
    "flags": ["cpu"],
    "kind": "agent",
    "launchScript": null,
    "name": "claude",
    "orphanReason": null,
    "parentPID": 1,
    "path": "/usr/local/bin/claude",
    "pid": 4123,
    "residentBytes": 104857600,
    "state": "S",
    "suspended": false,
    "token": "4123:1761483670123456:501",
    "tty": "ttys001",
    "userID": 501,
    "watchdogSuspended": false,
    "workingDirectory": "~/src/watchdog",
    "worktree": null
  }
]
```

## `inspect --json`

객체 하나. 필드는 `list`의 `ProcessRecord`와 같다. `flags`에는 제어 거부 문장이 들어갈 수 있다.

```json
{
  "agentAncestorName": null,
  "agentAncestorPID": null,
  "controllable": false,
  "cpuPercent": 0.0,
  "elapsed": "12:00:00",
  "flags": ["PID 1(launchd)은 제어할 수 없습니다."],
  "kind": "system",
  "launchScript": null,
  "name": "launchd",
  "orphanReason": null,
  "parentPID": 0,
  "path": "/sbin/launchd",
  "pid": 1,
  "residentBytes": 0,
  "state": "S",
  "suspended": false,
  "token": "1:0:0",
  "tty": "??",
  "userID": 0,
  "watchdogSuspended": false,
  "workingDirectory": null,
  "worktree": null
}
```

## `sessions --json`

배열. 원소는 `SessionRecord`.

| 필드 | 타입 |
|---|---|
| `id` | string (루트 TOKEN) |
| `rootPID` | number |
| `name` | string |
| `kind` | `processKind` (`agent` 또는 `service`) |
| `workingDirectory` | string 또는 null |
| `projectName` | string 또는 null |
| `members` | number 배열 (자손 PID) |
| `memberCount` | number |
| `cpuPercent` | number |
| `residentBytes` | number |
| `isSuspended` | bool |
| `elapsed` | string |

```json
[
  {
    "cpuPercent": 34.5,
    "elapsed": "00:10",
    "id": "8801:1761483670000000:501",
    "isSuspended": false,
    "kind": "agent",
    "memberCount": 2,
    "members": [8802, 8803],
    "name": "claude",
    "projectName": "watchdog",
    "residentBytes": 209715200,
    "rootPID": 8801,
    "workingDirectory": "~/src/watchdog"
  }
]
```

## `watch --json`

한 줄에 이벤트 하나(NDJSON). 일반 이벤트:

| 필드 | 타입 |
|---|---|
| `time` | string (ISO 8601) |
| `type` | `watchEventType` |
| `token` | string 또는 null |
| `name` | string 또는 null |
| `detail` | string 또는 null |

```json
{"detail":"CPU 100% · 메모리 2 GB · 지속 20초 · 자동 정지 끔","name":null,"time":"2026-10-30T03:50:00Z","token":null,"type":"watch.start"}
```

세션 경고(`session-hot`, `session-high-memory`):

| 필드 | 타입 |
|---|---|
| `event` | `session-hot` 또는 `session-high-memory` |
| `token` | string |
| `name` | string |
| `cpuPercent` | number |
| `memberCount` | number |

```json
{"cpuPercent":180.0,"event":"session-hot","memberCount":3,"name":"claude","token":"8801:1761483670000000:501"}
```

## `stopped --json`

배열. 원소는 `CLIStoppedRecord`.

| 필드 | 타입 |
|---|---|
| `token` | string |
| `name` | string |
| `path` | string |
| `suspendedAt` | string (ISO 8601) |
| `source` | `stoppedSource` |
| `groupID` | string 또는 null |

```json
[
  {
    "groupID": null,
    "name": "WatchdogE2EHelper",
    "path": "~/Library/Developer/Xcode/DerivedData/WatchdogE2EHelper",
    "source": "cli",
    "suspendedAt": "2026-10-30T03:50:00Z",
    "token": "9100:1761483670000000:501"
  }
]
```

`--resume-all --json`은 `{token,name,result,message}` 배열이다. `result`는 `resumed` · `failed` · `skipped`.

## `doctor --json`

객체 `CLIDoctorReport`.

| 필드 | 타입 |
|---|---|
| `libprocMilliseconds` | number 배열 |
| `psMilliseconds` | number 또는 null |
| `processCount` | number |
| `ownProcessCount` | number |
| `agentCount` | number |
| `agentsWithWorkingDirectory` | number |
| `ledgerPath` | string |
| `ledgerEntries` | number |
| `settings` | object (`cpuThreshold`, `sustainedDuration`, `memoryThresholdGB`) |
| `autoSuspendEnabled` | bool |
| `appRunning` | bool |
| `loginItemStatus` | string 또는 null |
| `loginItemOptedOut` | bool |
| `loginItemLastError` | string 또는 null |
| `rulesPath` | string |
| `rulesStatus` | string |
| `problems` | string 배열 |

```json
{
  "agentCount": 1,
  "agentsWithWorkingDirectory": 1,
  "appRunning": false,
  "autoSuspendEnabled": false,
  "ledgerEntries": 0,
  "ledgerPath": "~/Library/Application Support/Watchdog/suspensions.json",
  "libprocMilliseconds": [4.2, 1.1, 1.0],
  "loginItemLastError": null,
  "loginItemOptedOut": false,
  "loginItemStatus": null,
  "ownProcessCount": 80,
  "problems": [],
  "processCount": 400,
  "psMilliseconds": 12.0,
  "rulesPath": "~/Library/Application Support/Watchdog/agent-rules.json",
  "rulesStatus": "없음",
  "settings": {
    "cpuThreshold": 100,
    "memoryThresholdGB": 2,
    "sustainedDuration": 20
  }
}
```

## `rules show --json`

객체 `CLIRulesShowReport`.

| 필드 | 타입 |
|---|---|
| `path` | string |
| `status` | string |
| `reason` | string 또는 null |
| `rules` | `AgentRules` 또는 null |
| `validationIssues` | string 배열 |
| `appliedCount` | number |

`AgentRules`: `agentNames` · `packageMarkers` · `serviceSubcommands` · `sessionHosts` · `ignoreNames`. `packageMarkers` 원소는 `{marker, agent}`.

```json
{
  "appliedCount": 0,
  "path": "~/Library/Application Support/Watchdog/agent-rules.json",
  "reason": null,
  "rules": null,
  "status": "없음",
  "validationIssues": []
}
```

## `audit FIXTURE --json`

라벨 없이: `ClassificationSummary`.

| 필드 | 타입 |
|---|---|
| `snapshotCount` | number |
| `kinds` | object (`processKind` → 개수) |
| `agents` | `{pid, agentName, workingDirectory}` 배열 |
| `orphans` | `{pid, path, orphanReason}` 배열 |

```json
{
  "agents": [{"agentName": "claude", "pid": 4123, "workingDirectory": "~/src/watchdog"}],
  "kinds": {"agent": 1, "other": 10, "system": 5},
  "orphans": [],
  "snapshotCount": 16
}
```

`--labels`와 함께: `AuditReport`. `kind` 등 필드 카운트는 `{compared, matches, mismatches, tolerated}`. 분류기가 행을 못 찾으면 종류 문자열 `missing`.

```json
{
  "agentName": {"compared": 3, "matches": 3, "mismatches": 0, "tolerated": 0},
  "kind": {"compared": 10, "matches": 10, "mismatches": 0, "tolerated": 0},
  "kindConfusion": {"agent": {"agent": 3}},
  "labeledCount": 10,
  "mismatches": [],
  "orphan": {"compared": 10, "matches": 10, "mismatches": 0, "tolerated": 0},
  "orphanReason": {"compared": 0, "matches": 0, "mismatches": 0, "tolerated": 0},
  "sessionRoot": {"compared": 3, "matches": 3, "mismatches": 0, "tolerated": 0},
  "snapshotCount": 16,
  "toleratedMismatchCount": 0,
  "untoleratedMismatchCount": 0
}
```

## `journal [--limit N] --json`

배열. 최신순. 원소는 `ActionJournalEntry` Codable 그대로.

| 필드 | 타입 |
|---|---|
| `id` | string (UUID) |
| `at` | string (ISO 8601) |
| `source` | `journalSource` |
| `action` | `journalAction` |
| `pid` | number |
| `startTimeMicroseconds` | number |
| `userID` | number |
| `executablePath` | string |
| `displayName` | string |
| `workingDirectory` | string 또는 null |
| `reason` | string 또는 null |
| `outcome` | `processActionOutcome` 또는 `failed:` 접두사 |
| `undoOf` | string (UUID) 또는 null |

```json
[
  {
    "action": "resume",
    "at": "2026-10-30T03:51:00Z",
    "displayName": "WatchdogE2EHelper",
    "executablePath": "~/DerivedData/WatchdogE2EHelper",
    "id": "11111111-1111-1111-1111-111111111111",
    "outcome": "resumed",
    "pid": 9100,
    "reason": null,
    "source": "cli",
    "startTimeMicroseconds": 1761483670000000,
    "undoOf": "00000000-0000-0000-0000-000000000000",
    "userID": 501,
    "workingDirectory": null
  }
]
```

## 제어 명령 `--json`

성공: `{result, action, token, name, outcome, groupResumed}`. `outcome`은 사람이 읽는 한국어 설명이다. 기계용 결과 코드는 저널 `outcome`을 쓴다.

```json
{"action":"suspend","groupResumed":"","name":"WatchdogE2EHelper","outcome":"일시 정지됨 · 재개할 때까지 멈춰 있음","result":"ok","token":"9100:1761483670000000:501"}
```
