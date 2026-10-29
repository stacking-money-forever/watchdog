#!/usr/bin/env bash
# Walk the shipping Watchdog UI (popover fixture + six window sections).
# System Events identifies processes by name, so a second Watchdog (the
# installed menu bar app) makes window specifiers ambiguous. Waiting uses
# osascript/System Events with unix id; tree walk and sidebar clicks use
# AXUIElement bound to the launched pid (scripts/ax-walk.swift).
# Usage: scripts/ax-audit.sh <path/to/Watchdog.app>
set -euo pipefail

app="${1:?usage: ax-audit.sh <Watchdog.app>}"
executable="$app/Contents/MacOS/Watchdog"
[[ -x "$executable" ]] || { echo "not an app bundle: $app" >&2; exit 64; }

if [[ "$app" == "$HOME/Applications/Watchdog.app" ]] || [[ "$app" == "/Applications/Watchdog.app" ]]; then
  echo "refusing to launch or quit the installed Watchdog; pass a build product" >&2
  exit 64
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/watchdog-ax-audit.XXXXXX")"
here="$(cd "$(dirname "$0")" && pwd)"
swiftc -O -framework ApplicationServices -framework CoreGraphics -o "$work/ax-walk" "$here/ax-walk.swift"
walker="$work/ax-walk"
pids=()
cleanup() {
  local pid
  for pid in "${pids[@]:-}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
      fi
    fi
  done
}
trap cleanup EXIT

launch_fixture() {
  local flag="$1"
  local log="$2"
  WATCHDOG_DISABLE_LOGIN_ITEM=1 "$executable" "$flag" >"$log" 2>&1 &
  local pid=$!
  pids+=("$pid")
  echo "$pid"
}

wait_for_window() {
  local pid="$1"
  local attempts="${2:-50}"
  local i
  for i in $(seq 1 "$attempts"); do
    if osascript - "$pid" <<'APPLESCRIPT' >/dev/null 2>"$work/wait.err"
on run argv
  set thePid to (item 1 of argv) as integer
  tell application "System Events"
    if not (exists (first process whose unix id is thePid)) then error "process not listed"
    set winCount to count of windows of (first process whose unix id is thePid)
    if winCount is 0 then error "no windows"
  end tell
end run
APPLESCRIPT
    then
      return 0
    fi
    sleep 0.2
  done
  echo "timed out waiting for Watchdog window (pid $pid)" >&2
  cat "$work/wait.err" >&2 || true
  return 1
}

dump_unnamed() {
  local pid="$1"
  local surface="$2"
  "$walker" "$pid" dump "$surface"
}

click_sidebar() {
  local pid="$1"
  local title="$2"
  "$walker" "$pid" click "$title"
}

unnamed_lines=()
record_dump() {
  local dump="$1"
  if [[ -z "${dump}" ]]; then
    unnamed_lines+=("empty audit output")
    return
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" == SCANNED* ]] && continue
    unnamed_lines+=("$line")
  done <<<"$dump"
}

echo "== popover fixture (--ui-test-fixture) =="
popover_pid="$(launch_fixture --ui-test-fixture "$work/popover.log")"
# launch_fixture runs in a command substitution, so register the PID here.
pids+=("$popover_pid")
wait_for_window "$popover_pid"
sleep 0.8
popover_dump="$(dump_unnamed "$popover_pid" "popover")"
if [[ -n "$popover_dump" ]]; then
  echo "$popover_dump"
else
  echo "(no unnamed controls)"
fi
record_dump "$popover_dump"
kill -TERM "$popover_pid" 2>/dev/null || true
for _ in $(seq 1 30); do
  kill -0 "$popover_pid" 2>/dev/null || break
  sleep 0.1
done
pids=()

echo
echo "== window fixture (--ui-test-window-fixture) =="
window_pid="$(launch_fixture --ui-test-window-fixture "$work/window.log")"
# launch_fixture runs in a command substitution, so register the PID here.
pids+=("$window_pid")
wait_for_window "$window_pid" 80
sleep 0.8

sections=("개요" "에이전트 세션" "전체 프로세스" "조치 기록" "감지 규칙" "설정")
section_keys=(overview sessions processes journal rules settings)
for i in "${!sections[@]}"; do
  title="${sections[$i]}"
  key="${section_keys[$i]}"
  echo "-- section: $title --"
  click_sidebar "$window_pid" "$title"
  sleep 0.35
  section_dump="$(dump_unnamed "$window_pid" "window.$key")"
  if [[ -n "$section_dump" ]]; then
    echo "$section_dump"
  else
    echo "(no unnamed controls)"
  fi
  record_dump "$section_dump"
done

echo
count="${#unnamed_lines[@]}"
echo "unnamed_controls=$count"
if (( count > 0 )); then
  printf '%s\n' "${unnamed_lines[@]}"
  exit "$count"
fi
exit 0
