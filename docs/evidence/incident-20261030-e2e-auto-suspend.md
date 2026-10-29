# 사고 기록 — 2026-10-30 e2e `watch --auto-suspend`가 실제 세션을 멈춤

## 무슨 일이 있었나
- brgr 워커 A6(세션 단위 자동 정지, task `f3b92ab7`)가 자기 워크트리에서 `scripts/cli-e2e.sh`를 돌렸다. 새로 추가한 "Session auto-suspend" 섹션은 `watch --auto-suspend --scope session --cpu 50 --sustain 2 --interval 0.5 --count 12`를 실행한다.
- `watch`는 **머신 전체**를 샘플링한다. 세션 합계가 50%를 2초 넘긴 세션을 전부 멈췄다: 사용자의 `claude`(justn-bench, 멤버 15: bench.py·cargo test·brgr wait…), 또 다른 `claude` 세션(33957, 멤버 6), 워커 자신의 `cursor-agent`(85793, 멤버 5 — e2e 셸 포함), 그리고 의도한 가짜 에이전트(60204). 총 35개 프로세스, 02:19부터 약 70분.
- 워커는 자기 셸이 멈춰 보고를 못 했고, brgr는 `running`으로 남았다. 사용자의 실제 ledger(`~/Library/Application Support/Watchdog/suspensions.json`)에는 기록이 없다(e2e는 `WATCHDOG_LEDGER_PATH`로 격리).

## 복구
1. 워커의 e2e ledger(`…/watchdog-cli-e2e.1Xlgkk/ledger/suspensions.json`, 35건; 사본 scratchpad `incident-ledger-20261030.json`)로 설치된 0.2.6 CLI `stopped --resume-all` 실행 → 34개 재개.
2. 사용자의 `claude` 63828은 SIGCONT 뒤에도 `T`로 남았다: 부모 zsh가 TTY 전경 그룹을 가져가 SIGTTIN으로 다시 멈춤. 해당 Herdr 페인(`wEE:p1`)의 zsh에 `fg`를 보내 전경으로 복귀 → `R+`. (첫 시도는 정지 중 쌓인 터미널 응답 문자열이 명령 앞에 붙어 실패.)
3. 남은 CPU 버너 `yes` 2개(e2e 찌꺼기, ppid 1) 종료. 전체 `ps`에서 `T` 상태 프로세스 0개 확인.
4. brgr 작업 취소·lost 결과 ack. 부분 패치(671줄)는 scratchpad `a6-partial.patch`로 보존.

## 원인
- e2e가 자동 정지 대상을 **자기가 띄운 프로세스로 제한할 수단이 없었다.** 기존 agent 범위 섹션(`--cpu 50 --sustain 2`)도 같은 잠재 위험이 있었고, 세션 합계로 바뀌면서 실제로 터졌다.
- 세션 그룹 자체는 계보(agentAncestor) 기준으로 맞게 묶였다(멈춘 목록은 각 루트의 자손뿐). 문제는 "누구를 대상으로 하느냐"였다.

## 조치
- `watch --auto-suspend`에 `--only TOKEN|PID …`(대상 제한) 추가. 제한이 있으면 그 밖의 어떤 프로세스에도 SIGSTOP을 보내지 않는다. `cli-e2e.sh`의 자동 정지 섹션 둘 다 반드시 `--only`를 쓴다.
- 워커 지시문에 "자동 정지 e2e는 `--only` 없이 실행 금지"를 명시. 메모리 `e2e-auto-suspend-incident` 기록.
- 세션 그룹 안전 테스트: 그룹 멤버는 전부 루트의 자손이어야 한다(조상·형제 금지)를 단위 테스트로 고정.
