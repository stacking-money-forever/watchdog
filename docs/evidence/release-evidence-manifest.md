# Release evidence manifest — 후보 수락 기록 (B12)

이 문서는 릴리스 후보 하나에 모든 receipt를 바인딩하는 유일한 수락 기록이다.
작업 항목별 상태·판정 기준은 `COMPLETION_CHECKLIST.md`가 유일한 출처이며, 여기서는 중복하지 않는다.

## 후보 신원 (이 블록의 값이 receipt 바인딩 키다)

| 항목 | 값 |
|---|---|
| `source_sha` | `03eb3befee6c2c410a609869dc5e571d99b6f59f` |
| `source_tree` | `c472bb01c8c2b6b16ed39d780254663e3073abec` |
| `source_dirty` | `false` |
| version / build | `0.2.0` / `5` |
| architectures | `x86_64 arm64` |
| signature | `adhoc`, `team_identifier` 없음, `get_task_allow` false |
| zip sha256 | `268a1d2fb181aba5af06916ed40c501c6f34c3e95ee1b6e2a626215355cd94a0` |
| dmg sha256 | `03383d71daf5051c3e376c62860e6629717030c3d5cfcbff60ed5034afcf97aa` |
| executable sha256 (설치본, soak 대상) | `1a273e23d07846a3df378490ddaedaf8ce9ffdee693a32414981a7782d54b2b8` |

`source_tree`는 `git rev-parse 03eb3be^{tree}`와 **일치함을 확인**했다(`c472bb01…`). 즉 이 후보는 커밋된 소스에서
빌드됐고 dirty 상태가 아니다.

## 후보 바이너리는 재현 가능하지 않다 (중요)

같은 소스·같은 설정으로 다시 빌드하면 실행 파일과 ZIP/DMG 해시가 달라진다(관측: `6674f98d…`, `9ca3770e…`,
`1a273e23…`). 따라서 receipt는 version/build가 아니라 **`source_tree` 또는 정확한 아티팩트 해시**에 바인딩해야 하며,
"0.2.0 build 5"인 두 후보를 같은 것으로 취급하면 안 된다.

## 수락 조건

1. 모든 runtime/distribution receipt가 위 블록의 동일한 `source_tree`와 아티팩트 해시를 인용한다.
2. `COMPLETION_CHECKLIST.md`에 unresolved P0가 없다.
3. 다음 중 하나라도 해당하면 수락하지 않는다: 해시 불일치, receipt 누락, `A23`/`A28`/`A29` 미완,
   `B08`/`B09` 같은 사람 경계를 완료로 보고.

## 현재 판정

**v0.2.1 게시됨(2026-09-22T00:25:28Z).** 릴리스 기록과 검증 전문은
`docs/evidence/release-v0.2.1-20260922.md`.

게시된 자산은 빌드 산출물·manifest·GitHub digest·직접 다운로드의 해시가 모두 일치했고,
문서화된 `scripts/install.sh`가 게시 릴리스에서 체크섬 검증 후 **Watchdog 0.2.1 (6)** 을 설치함을 확인했다.
아티팩트는 커밋 `f0172fd`(`source_tree` `a3d80607…`, `source_dirty=false`)에서 빌드됐고,
태그 대상 `100354e`와의 차이는 문서 3개 파일뿐임을 서브트리 비교로 확인했다.

게시 시점에 남아 있던 미완 항목(릴리스 노트에도 명시):
- `A28` 8시간 안정성 soak — 게시 후 **릴리스 바이너리**(`d75457b3…`)로 다시 시작해 진행 중.
- `A23` clean account에서의 앱별 Gatekeeper 승인 미관찰.
- `B07` 실제 알림 배너, `B08` 로그아웃 후 로그인 자동 실행, `B09` 키보드·VoiceOver 미검증.
- `B06` `candidate.yml`은 기본 브랜치 병합 후에만 dispatch 가능(현재 병합됨).

`A28` soak: candidate pid `72785`(exe `d75457b3…`, version `0.2.1` build `6`), `started_at` `2026-09-22T00:26:45Z`,
`duration_seconds` 28800, `interval_seconds` 60, 출력 `/tmp/wd-soak-rel`.
종료 `2026-09-22T08:26:45Z`(KST 17:26:45). 판정은 `scripts/analyze-soak.sh`로 하며 `max_timestamp_gap_seconds ≤ 120`이어야 한다.

## 릴리스 절차상 선행 조건

- `scripts/install.sh`의 고정 SHA(`a5492e56…`)는 **현재 공개된 v0.2.0 릴리스 자산**을 가리킨다. 이는 정합적이며,
  위 후보와 다른 것은 새 릴리스를 자르지 않았기 때문이다. 릴리스 시 `INSTALL.md`/`README.md`/`install.sh`/
  릴리스 자산을 함께 갱신해야 한다.
- 이 후보를 공개하려면 커밋 `03eb3be`가 기본 브랜치에 병합돼야 한다(현재는 브랜치
  `codex/watchdog-completion-owner`에만 있음).
