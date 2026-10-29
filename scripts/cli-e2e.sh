#!/usr/bin/env bash
# End-to-end verification of watchdog-cli against disposable processes this
# script starts itself. It never signals any process it did not create, and it
# uses an isolated suspension ledger (WATCHDOG_LEDGER_PATH), so the user's real
# ledger and processes are untouched.
#
# Usage: scripts/cli-e2e.sh [--derived-data DIR]
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --derived-data) derived_data="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

work="$(mktemp -d "${TMPDIR:-/tmp}/watchdog-cli-e2e.XXXXXX")"
derived_data="${derived_data:-$work/DerivedData}"
export WATCHDOG_LEDGER_PATH="$work/ledger/suspensions.json"

spawned=()
cleanup() {
  for pid in "${spawned[@]:-}"; do
    [[ -n "$pid" ]] || continue
    if kill -0 "$pid" 2>/dev/null; then
      kill -CONT "$pid" 2>/dev/null || true
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT

pass=0
fail=0
check() {
  local name="$1"; shift
  if "$@"; then
    pass=$((pass + 1)); echo "  ok   $name"
  else
    fail=$((fail + 1)); echo "  FAIL $name"
  fi
}
expect_exit() {
  local expected="$1"; shift
  local status=0
  "$@" >"$work/last.out" 2>"$work/last.err" || status=$?
  if [[ "$status" -ne "$expected" ]]; then
    echo "    expected exit $expected, got $status: $*" >&2
    sed 's/^/    | /' "$work/last.err" >&2
    return 1
  fi
}
state_of() { ps -o state= -p "$1" 2>/dev/null | tr -d ' ' || true; }
alive() { kill -0 "$1" 2>/dev/null; }
gone() { ! kill -0 "$1" 2>/dev/null; }
stopped() { [[ "$(state_of "$1" | cut -c1)" == T ]]; }
running() { alive "$1" && [[ "$(state_of "$1" | cut -c1)" != T ]]; }
token_of() {
  "$cli" list --scope all --search "$1" --json --interval 0.2 \
    | /usr/bin/python3 -c 'import json,sys; pid=int(sys.argv[1]); print(next(r["token"] for r in json.load(sys.stdin) if r["pid"]==pid))' "$1"
}
ledger_count() {
  "$cli" stopped --json | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'
}
wait_until() {
  local tries=50
  while (( tries-- > 0 )); do
    if "$@"; then return 0; fi
    sleep 0.1
  done
  return 1
}

echo "Building watchdog-cli and WatchdogE2EHelper into $derived_data"
(cd "$repo_root" && xcodegen generate >/dev/null)
for scheme in WatchdogCLI WatchdogE2EHelper; do
  xcodebuild -quiet -project "$repo_root/Watchdog.xcodeproj" -scheme "$scheme" \
    -configuration Debug -derivedDataPath "$derived_data" build
done
cli="$derived_data/Build/Products/Debug/watchdog-cli"
helper="$derived_data/Build/Products/Debug/WatchdogE2EHelper"

start_helper() {
  local name="$1"
  "$helper" "$work/$name.heartbeat" "$work/$name.term" >/dev/null 2>&1 &
  local pid=$!
  spawned+=("$pid")
  wait_until test -s "$work/$name.heartbeat"
  echo "$pid"
}
heartbeat() { cat "$work/$1.heartbeat" 2>/dev/null | tr -d '\n'; }

echo "Read-only commands"
check "help exits 0" expect_exit 0 "$cli" help
check "unknown command is a usage error" expect_exit 2 "$cli" frobnicate
check "doctor" expect_exit 0 "$cli" doctor
check "list --json" expect_exit 0 "$cli" list --scope all --json --interval 0.2
check "watch runs a bounded session" expect_exit 0 "$cli" watch --count 3 --interval 0.5 --json
check "watch emitted start and end events" grep -q '"watch.end"' "$work/last.out"
check "watch --count 0 is a usage error" expect_exit 2 "$cli" watch --count 0
check "watch --count abc is a usage error" expect_exit 2 "$cli" watch --count abc

echo "Suspend / resume (reversible)"
a=$(start_helper a); spawned+=("$a")
token_a=$(token_of "$a")
check "inspect by token" expect_exit 0 "$cli" inspect "$token_a"
check "suspend runs with a non-agent warning" expect_exit 0 "$cli" suspend "$token_a"
check "warning names the non-agent target" grep -q '경고' "$work/last.err"
check "process is stopped" wait_until stopped "$a"
beat=$(heartbeat a); sleep 1.5
check "heartbeat stalls while stopped" test "$(heartbeat a)" = "$beat"
check "ledger records the stop" test "$(ledger_count)" = 1
check "terminate without --force is blocked" expect_exit 3 "$cli" terminate "$token_a"
check "blocked terminate leaves it alive" alive "$a"
check "terminate by bare PID is a usage error" expect_exit 2 "$cli" terminate "$a" --force
check "resume by PID" expect_exit 0 "$cli" resume "$a"
check "process runs again" wait_until running "$a"
check "ledger cleared on resume" test "$(ledger_count)" = 0

echo "Terminate a stopped process (SIGCONT then SIGTERM)"
check "suspend again" expect_exit 0 "$cli" suspend "$token_a" --force
check "terminate --force exits 0" expect_exit 0 "$cli" terminate "$token_a" --force
check "outcome reports verified exit" grep -q '종료 확인됨' "$work/last.out"
check "helper handled SIGTERM" grep -q term "$work/a.term"
check "process is gone" wait_until gone "$a"
check "ledger stays empty" test "$(ledger_count)" = 0

echo "Force quit and identity safety"
b=$(start_helper b); spawned+=("$b")
token_b=$(token_of "$b")
stale_b="${b}:1:$(id -u)"
check "force-quit without --force is blocked" expect_exit 3 "$cli" force-quit "$token_b"
check "stale token is refused even with --force" expect_exit 4 "$cli" force-quit "$stale_b" --force
check "refusal explains the identity change" grep -q '다른 프로세스' "$work/last.err"
check "still alive after refusals" alive "$b"
check "force-quit --force exits 0" expect_exit 0 "$cli" force-quit "$token_b" --force
check "SIGKILL bypassed the TERM handler" test ! -e "$work/b.term"
check "process is gone" wait_until gone "$b"

echo "Always-refused targets"
launchd_token=$("$cli" inspect 1 --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
check "launchd refused with --force" expect_exit 4 "$cli" force-quit "$launchd_token" --force
root_pid=$(ps -axo pid=,uid=,comm= | awk '$2==0 && $3 ~ /syslogd$/ {print $1}' | head -1 || true)
if [[ -n "$root_pid" ]]; then
  check "root-owned process refused with --force" expect_exit 4 "$cli" suspend "$root_pid" --force
fi

echo "Auto-suspend through watch (agent-named CPU burner)"
mkdir -p "$work/bin"
ln -s /usr/bin/yes "$work/bin/claude"
"$work/bin/claude" >/dev/null &
burner=$!
spawned+=("$burner")
check "watch auto-suspends the runaway agent" expect_exit 0 \
  "$cli" watch --auto-suspend --cpu 50 --sustain 2 --interval 0.5 --count 12 --json
check "auto-suspend event emitted" grep -q '"auto-suspend"' "$work/last.out"
check "burner is stopped" wait_until stopped "$burner"
check "ledger lists it" test "$(ledger_count)" = 1
check "stopped --resume-all" expect_exit 0 "$cli" stopped --resume-all
check "burner runs again" wait_until running "$burner"
check "ledger empty after resume-all" test "$(ledger_count)" = 0

echo "Agent recognition through an interpreter"
# npm/pip agents run as `node …/gemini.js` or `python3 …/aider`; the agent is
# only visible in the script argument. The fake agent also starts a child,
# which must be attributed to it.
printf 'import subprocess\nsubprocess.run(["sleep", "30"])\n' >"$work/bin/gemini.py"
/usr/bin/python3 "$work/bin/gemini.py" &
interpreted=$!
spawned+=("$interpreted")
wait_until pgrep -P "$interpreted" sleep >/dev/null
child=$(pgrep -P "$interpreted" sleep | head -1)
spawned+=("$child")
agent_json=$("$cli" list --scope agents --search gemini.py --json --interval 0.2)
check "python-launched agent is an agent named gemini" /usr/bin/python3 -c \
  'import json,sys; r=[p for p in json.loads(sys.argv[1]) if p["pid"]==int(sys.argv[2])]; sys.exit(not (r and r[0]["name"]=="gemini" and r[0]["kind"]=="agent"))' \
  "$agent_json" "$interpreted"
child_json=$("$cli" inspect "$child" --json)
check "its child is attributed to it" /usr/bin/python3 -c \
  'import json,sys; sys.exit(json.loads(sys.argv[1]).get("agentAncestorPID")!=int(sys.argv[2]))' \
  "$child_json" "$interpreted"
kill -TERM "$child" "$interpreted" 2>/dev/null || true

echo "Audit"
check "snapshot --out writes a file" expect_exit 0 "$cli" snapshot --out "$work/snap.json"
check "snapshot JSON is valid" /usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "rows" in d and isinstance(d["rows"], list)' "$work/snap.json"
check "audit reads snapshot and prints a summary" expect_exit 0 "$cli" audit "$work/snap.json"
check "audit summary names kinds" grep -q '종류:' "$work/last.out"
check "audit fixture+labels --json reports mismatches" expect_exit 1 \
  "$cli" audit "$repo_root/WatchdogTests/Fixtures/mac-20261030.json" \
  --labels "$repo_root/WatchdogTests/Fixtures/mac-20261030.labels.json" --json
check "audit JSON has mismatches" /usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit("mismatches" not in d)' "$work/last.out"

echo
echo "cli-e2e: $pass passed, $fail failed (work dir $work)"
[[ "$fail" -eq 0 ]]
