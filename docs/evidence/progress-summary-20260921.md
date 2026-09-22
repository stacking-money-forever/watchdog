# Watchdog 진행 요약 — 2026-09-21

한 줄 상태: 핵심 안전성·QA 보강은 integration owner에 모였고 로컬 검증은 상당수 통과했지만, 실제 사람 QA·Gatekeeper·호스트 XCUITest 환경·gap-free 장기 run이 남아 공개 출시 증거는 아직 불충분하다.

## 이번에 구현·수정한 핵심 작업

- orphan 프로세스가 CPU/메모리 경고 수에 잘못 포함되지 않도록 badge/문구를 정리했다.
- working-directory enrichment와 worktree 상태 해석을 연결하고, missing·unavailable·clean 상태를 구분해 표시하도록 보강했다.
- Preview/Snapshot을 실제 login-item 등록 없이 실행할 수 있는 no-op 의존성으로 분리했다.
- DEBUG 전용 LiveQA/E2E helper를 추가해 실제 helper 프로세스의 suspend, resume, terminate, force-quit confirmation을 앱 제어로 검증할 수 있게 했다.
- Release의 `get-task-allow` 제거, installer의 graceful update·복구 경로, 후보 ZIP/DMG/SHA manifest 생성, CI/candidate workflow 초안을 추가했다.
- soak 분석기에 timestamp 간격 검사를 추가했다. 두 interval을 넘는 간격은 exit 4로 실패하며, 실제 run에서 703초 gap을 검출했다.

## 직접 실행해 통과한 검증

- 통합 owner의 default signed Release build 성공, `codesign --verify --deep --strict` 통과, Release entitlement에 `get-task-allow` 없음.
- unit test bundle 직접 실행 84/84 통과 및 `git diff --check` 통과.
- installer의 fresh `--no-launch`, graceful update, TERM-resistant refusal, staged replacement 실패 복구를 disposable 대상에서 확인했다.
- soak 분석기: 210초 synthetic gap은 exit 4, 60초 간격 synthetic fixture는 exit 0, `shellcheck scripts/analyze-soak.sh` 통과.
- 실제 candidate soak은 2시간 30분 36초 동안 candidate/helper 생존과 FD 38–40 범위를 관찰했다. Thermal Emergency Sleep 뒤 helper heartbeat와 candidate가 재개됐지만, 703초 표본 공백 때문에 gap-free 안정성 통과로 처리하지 않았다.

## 남은 미검증·외부 경계

- XCUITest: Xcode 27.0의 CoreDevice/CoreSimulator framework 불일치로 자동화 증거를 만들 수 없다. 런타임 설치는 인증을 요구한다.
- Gatekeeper: 로컬 설치 후보는 signature-valid이지만 `spctl --assess`가 거절하고 quarantine xattr가 없다. 다운로드된 quarantined 후보를 Finder Open 또는 System Settings Open Anyway로 승인하는 사람 증거가 필요하다.
- 실제 MenuBarExtra popover, 키보드/VoiceOver, login-item/notification 흐름은 사람 QA가 남아 있다.
- 새 gap-free 8시간 run은 thermal sleep 없이 안정적인 실제 호스트 조건에서 다시 수행해야 한다.
- GitHub protected branch·secret scanning과 remote workflow execution은 repository-admin/push 권한 경계다.

## Worktree 정리

- 보존: main `/Users/justn/dev/watchdog`(사용자 untracked 파일 및 active pane), integration owner `/Users/justn/dev/.worktrees/watchdog-completion-owner`, detached evidence `/Users/justn/dev/.worktrees/watchdog-fp-evidence-20260913`.
- 정리: clean·base SHA 동일·idle shell만 있던 `watchdog-a09`, `a10`, `a14`, `a15mode`, `a22`, `a24`, `watchdog-liveqa`를 Herdr worktree remove로 제거했다.
- 남은 task 변경은 현재 owner에 반영돼 있으나, 삭제 전 task별 recoverable patch manifest artifact는 현재 owner에서 확인되지 않는다.

## 재개 시 첫 작업

1. Xcode/CoreDevice runtime을 인증된 방식으로 복구한 뒤 shipping Watchdog UI test를 실행하고, 별도 안정 호스트에서 새 8시간 gap-free candidate soak을 시작한다.

## 증거 구분

- 로컬: source diff, signed Release build, codesign, shellcheck, installer/package scripts.
- 합성: unit tests, DEBUG fixtures, E2E helper signal scenarios, timestamp-gap fixtures.
- 실제 런타임/배포 후보: installed candidate installer QA, actual process control, 2.5시간 soak 및 실제 sleep/wake 생존. 이는 공개 운영 배포 증거는 아니다.
- 사람 QA: Gatekeeper 승인, MenuBarExtra/접근성, notification/login-item 검증은 아직 미수행이다.
