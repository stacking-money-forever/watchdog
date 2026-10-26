#!/usr/bin/env bash
# Launch smoke for the shipping launch path (Release by default): the first
# instance starts and stays up, a second launch exits on its own without
# disturbing the first, and the first quits on SIGTERM.
#
# It runs the real (non-fixture) launch mode, so it is isolated explicitly:
# no login-item registration (WATCHDOG_DISABLE_LOGIN_ITEM=1) and a throwaway
# suspension ledger. It refuses to run while another Watchdog is running,
# because the single-instance lock is per user.
#
# Usage: scripts/launch-smoke.sh <path/to/Watchdog.app>
set -euo pipefail

app="${1:?usage: launch-smoke.sh <Watchdog.app>}"
executable="$app/Contents/MacOS/Watchdog"
[[ -x "$executable" ]] || { echo "not an app bundle: $app" >&2; exit 64; }

if pgrep -f '/Watchdog.app/Contents/MacOS/Watchdog$' >/dev/null; then
  echo "Another Watchdog is running; the instance lock is per user. Quit it first." >&2
  exit 65
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/watchdog-launch-smoke.XXXXXX")"
export WATCHDOG_DISABLE_LOGIN_ITEM=1
export WATCHDOG_LEDGER_PATH="$work/suspensions.json"

first=""
cleanup() {
  if [[ -n "$first" ]] && kill -0 "$first" 2>/dev/null; then
    kill -TERM "$first" 2>/dev/null || true
  fi
}
trap cleanup EXIT

"$executable" >"$work/first.log" 2>&1 &
first=$!
sleep 4
kill -0 "$first" || { echo "FAIL first instance exited early" >&2; cat "$work/first.log" >&2; exit 1; }
echo "ok   first instance running (pid $first)"

second_status=0
"$executable" >"$work/second.log" 2>&1 &
second=$!
for _ in $(seq 1 100); do
  kill -0 "$second" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$second" 2>/dev/null; then
  kill -TERM "$second" 2>/dev/null || true
  echo "FAIL second instance did not exit on its own" >&2
  exit 1
fi
wait "$second" || second_status=$?
echo "ok   second instance exited by itself (status $second_status)"

kill -0 "$first" || { echo "FAIL first instance died when the second launched" >&2; exit 1; }
echo "ok   first instance unaffected"

kill -TERM "$first"
for _ in $(seq 1 50); do
  kill -0 "$first" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$first" 2>/dev/null; then
  echo "FAIL first instance ignored SIGTERM" >&2
  exit 1
fi
first=""
echo "ok   first instance quit on SIGTERM"
