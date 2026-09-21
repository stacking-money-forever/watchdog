# Release evidence manifest — 후보 수락 기록 (B12)

이 문서는 릴리스 후보 하나에 모든 receipt를 바인딩하는 유일한 수락 기록이다.
작업 항목별 상태·판정 기준은 `COMPLETION_CHECKLIST.md`가 유일한 출처이며, 여기서는 중복하지 않는다.

## 후보 신원 (이 블록의 값이 receipt 바인딩 키다)

| 항목 | 값 | 출처 |
|---|---|---|
| `source_sha` | `07d35f5f8510cbbb6953097fb379b647f1e69bb6` | `manifest.json` |
| `source_tree` | (재빌드 시 `manifest.json`에서 확정) | `manifest.json` |
| `source_dirty` | `true` | `manifest.json` |
| version / build | `0.2.0` / `5` | `manifest.json` |
| architectures | `x86_64 arm64` | `manifest.json` |
| signature | `adhoc`, `team_identifier` 없음, `get_task_allow` false | `manifest.json` |
| zip sha256 | `manifest.json` | |
| dmg sha256 | `manifest.json` | |
| executable sha256 | `6674f98db564e07820223bff0745f2d7a825bdec41d6606dfe55dc773e4f9b59` | soak `metadata.json` |

**주의.** 후보 바이너리는 재현 가능하지 않다(같은 소스·같은 설정의 두 빌드가 서로 다른 해시를 냈다:
`6674f98d…` / `f92ec75b…`). ZIP·DMG 해시도 회차마다 달라진다. 따라서 receipt는 version/build가 아니라
**정확한 아티팩트 해시 또는 `source_tree`**에 바인딩해야 하며, version만 같은 두 후보를 같은 것으로 취급하면 안 된다.

## 수락 조건

1. `docs/evidence/session-20260921-candidate-and-launchservices.md`를 포함한 모든 runtime/distribution receipt가
   위 블록의 동일한 `source_tree` / 아티팩트 해시를 인용한다.
2. `COMPLETION_CHECKLIST.md`에 unresolved P0가 없다.
3. 아래 중 하나라도 해당하면 수락하지 않는다: 해시 불일치, receipt 누락, `A19`/`A23`/`A28`/`A29` 미완, `B10`/`B11`/`B13` 같은 권한 경계를 완료로 보고.

## 현재 판정

**미수락.** 남은 P0: `A19`, `A23`, `A28`, `A29` (진행 중), `B07`, `B08`, `B09`.
`B08`은 실제 로그아웃이 필요해 에이전트가 닫을 수 없다.

## 릴리스 절차상 선행 조건

- `source_dirty: true`인 후보는 릴리스 대상으로 확정할 수 없다. 수락할 후보는 커밋된 소스에서 재빌드해야 하며,
  그때 `source_tree`가 해당 커밋 트리와 일치해야 한다(PUBLISH 게이트).
- `scripts/install.sh`의 고정 SHA(`a5492e56…`)는 **현재 공개된 v0.2.0 릴리스 자산**을 가리킨다. 이는 지금 정합적이며,
  로컬 후보와 다른 것은 새 릴리스를 자르지 않았기 때문이다. 릴리스 시 `INSTALL.md`/`README.md`/`install.sh`/릴리스 자산을
  함께 갱신한다.
