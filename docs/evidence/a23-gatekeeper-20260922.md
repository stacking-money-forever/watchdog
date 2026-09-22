# A23 — 다운로드된 quarantined 후보 준비 (2026-09-22)

## 방법

후보를 실제로 "다운로드"해서 quarantine을 붙이되, 사용자 화면·프로필·포커스를 건드리지 않았다.

1. `03eb3be` 클린 빌드 산출물(`/tmp/wd-cand-clean`)을 `127.0.0.1:8799`에서 제공.
2. 별도 `--user-data-dir=/tmp/wd-chrome-profile`로 **headless Chrome 153.0.8010.47** 기동(사용자 프로필 미사용, 포커스 비탈취).
3. CDP로 다운로드 실행: `Browser.setDownloadBehavior{behavior:"allowAndName", downloadPath:/tmp/wd-qa-download}` 후
   `Target.createTarget{url:"http://127.0.0.1:8799/Watchdog-0.2.0-macos.dmg"}`.
   `Browser.downloadProgress`가 `state:"completed"`로 종료.

## 결과

| 확인 | 값 |
|---|---|
| 다운로드 크기 | 2,497,127 bytes |
| quarantine | `0081;6ab1c494;Chrome;` ← 실제로 붙음 |
| 다운로드 sha256 | `03383d71daf5051c3e376c62860e6629717030c3d5cfcbff60ed5034afcf97aa` |
| manifest dmg sha256 | `03383d71daf5051c3e376c62860e6629717030c3d5cfcbff60ed5034afcf97aa` (일치) |
| 보관 위치 | `~/Downloads/Watchdog-0.2.0-macos.dmg` (quarantine 유지) |

즉 ledger가 요구한 **"다운로드된 quarantined 후보"가 실제로 존재**하며, 그 바이트가 빌드 산출물과 동일하다.

## Gatekeeper 판정 (기계적)

| 대상 | quarantine | codesign | `spctl -a -vvv` |
|---|---|---|---|
| quarantined DMG 자체 | `0081;6ab1c494;Chrome;` | (DMG 미서명) | **rejected** — `source=no usable signature` |
| 마운트된 DMG 안의 `Watchdog.app` | 없음(마운트는 전파하지 않음) | valid on disk / satisfies DR | **rejected** |
| `ditto`로 밖으로 복사한 앱 | `0281;00000000;;` | valid | **rejected** |

## A23을 닫으려면 남은 것 (사람)

기계적으로는 **승인 UI 통과 관찰**만 남았다. 그리고 ledger의 수락 조건은
"clean-account Gatekeeper approval receipt"이므로 **앱이 한 번도 승인된 적 없는 계정/호스트**여야 한다.
현재 호스트는 이미 `~/Applications/Watchdog.app`이 설치돼 있어 clean account가 아니다.

절차:

1. `~/Downloads/Watchdog-0.2.0-macos.dmg`를 Finder에서 열기(더블클릭).
2. 안의 `Watchdog.app`을 실행 → macOS가 차단 UI를 띄우는지 확인.
3. 문서화된 경로로만 승인: Finder에서 우클릭 → **Open**, 또는 시스템 설정 → 개인정보 보호 및 보안 → **Open Anyway**.
4. 앱이 실제로 실행되고 상태 아이콘이 나타나는지 확인.

**금지**: `xattr`로 quarantine 제거, Gatekeeper 전역 비활성화, `spctl --add`. 이 경우 receipt는 무효다.
