#!/usr/bin/env bash
# Repeat WatchdogUITests N times (default 10) and print a per-test pass/skip/fail
# table. Leftover DEBUG fixture Watchdog processes are stopped with SIGTERM
# before each run. The installed app at ~/Applications/Watchdog.app is never
# targeted.
#
# Usage: scripts/ui-test-loop.sh [N]
#   WATCHDOG_UI_TEST_EXPECTED=19  fail unless exactly N distinct tests were parsed
#   WATCHDOG_UI_TEST_WAIT_SECONDS  how long to wait for a foreign UI test run (default 1800)
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
runs="${1:-10}"
if ! [[ "$runs" =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $0 [positive integer]" >&2
  exit 64
fi

stamp="$(date +%Y%m%d-%H%M%S)"
work="${WATCHDOG_UI_TEST_LOOP_DIR:-$repo_root/DerivedData/ui-test-loop}"
mkdir -p "$work"
log_dir="$work/logs-$stamp"
mkdir -p "$log_dir"
# Stable product path so the UI-test runner keeps the same TCC/Accessibility
# identity across loop iterations (a unique DerivedData folder each run
# produces a new WatchdogUITests-Runner that macOS will not automate).
derived_data="${WATCHDOG_UI_TEST_DERIVED_DATA:-$repo_root/DerivedData/ui}"
install_app="$HOME/Applications/Watchdog.app"

stop_pid() {
  local pid="$1"
  local reason="$2"
  [[ -n "$pid" ]] || return 0
  if ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  echo "stop leftover fixture pid $pid ($reason)"
  kill -TERM "$pid" 2>/dev/null || true
  local i
  for i in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  echo "fixture pid $pid still running after SIGTERM" >&2
}

stop_fixture_watchdogs() {
  # Only fixtures launched from this checkout's build products are ours to stop.
  # Fixtures or runners from other checkouts/sessions are left alone (see
  # wait_for_foreign_ui_tests, which waits for them to finish instead).
  local pid args
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    [[ "$args" == *"--ui-test-"* ]] || continue
    [[ "$args" == *"$install_app"* ]] && continue
    [[ "$args" == "$repo_root/"* ]] || continue
    stop_pid "$pid" "--ui-test leftover from this checkout"
  done < <(ps -ax -o pid= -o args= | awk '/\/Watchdog\.app\/Contents\/MacOS\/Watchdog/ && /--ui-test-/ {print $1}')
}

# XCUITest binds the target by bundle id (dev.justn.watchdog). Two UI test
# sessions on one machine race for the same target and both fail with
# "Application 'dev.justn.watchdog' does not have a process ID". Wait for any
# other WatchdogUITests run (another checkout, another agent) to finish.
wait_for_foreign_ui_tests() {
  local waited=0 limit="${WATCHDOG_UI_TEST_WAIT_SECONDS:-1800}" others
  while :; do
    others="$(ps -ax -o pid= -o args= \
      | grep -E 'xcodebuild[^|]*WatchdogUITests|WatchdogUITests-Runner\.app/Contents/MacOS/|MacOS/Watchdog .*--ui-test-' \
      | grep -v -F -- "$repo_root/" \
      | grep -v -F -- "$install_app" \
      | grep -v grep || true)"
    [[ -z "$others" ]] && return 0
    if (( waited == 0 )); then
      echo "another WatchdogUITests run is active; waiting for it to finish:"
      echo "$others" | cut -c1-160
    fi
    if (( waited >= limit )); then
      echo "gave up after ${limit}s; a foreign UI test run is still active" >&2
      return 1
    fi
    sleep 10
    waited=$((waited + 10))
  done
}

echo "Generating Xcode project"
(cd "$repo_root" && USER="$(id -un)" xcodegen generate)

echo "Looping WatchdogUITests $runs time(s); logs: $log_dir"
run_status=0

for i in $(seq 1 "$runs"); do
  echo
  echo "======== run $i / $runs ========"
  stop_fixture_watchdogs
  wait_for_foreign_ui_tests
  run_log="$log_dir/run-$i.log"
  bundle="$log_dir/run-$i.xcresult"
  rm -rf "$bundle"
  set +e
  set -o pipefail
  xcodebuild \
    -project "$repo_root/Watchdog.xcodeproj" \
    -scheme Watchdog \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$bundle" \
    test \
    -only-testing:WatchdogUITests \
    2>&1 | tee "$run_log"
  status=${PIPESTATUS[0]}
  set +o pipefail
  set -e
  echo "run $i xcodebuild exit $status"
  echo "$status" >"$log_dir/run-$i.exit"
  if [[ "$status" -ne 0 ]]; then
    run_status=1
  fi
done

stop_fixture_watchdogs

python3 - "$log_dir" "$runs" "${WATCHDOG_UI_TEST_EXPECTED:-}" <<'PY'
import pathlib, re, sys
from collections import defaultdict

log_dir = pathlib.Path(sys.argv[1])
runs = int(sys.argv[2])
case_re = re.compile(
    r"Test Case '-\[WatchdogUITests\.(\w+) (\w+)\]' (passed|failed|skipped)"
)
skip_reason_re = re.compile(r"skipped(?:ed)?: (.+)$")
tests = defaultdict(lambda: {"passed": 0, "skipped": 0, "failed": 0})
skip_reasons = defaultdict(list)
failed_logs = []
order = []

for i in range(1, runs + 1):
    text = (log_dir / f"run-{i}.log").read_text(errors="replace")
    seen = set()
    for match in case_re.finditer(text):
        name, result = f"{match.group(1)}.{match.group(2)}", match.group(3)
        if name not in tests and name not in seen:
            order.append(name)
        seen.add(name)
        tests[name][result] += 1
    if "keyboard focus unavailable" in text:
        skip_reasons["keyboard focus unavailable: another app is frontmost"].append(i)
    if "** TEST FAILED **" in text or (log_dir / f"run-{i}.exit").read_text().strip() != "0":
        failed_logs.append(str(log_dir / f"run-{i}.log"))

print()
print("Per-test totals")
print(f"{'test':<64} {'pass':>4} {'skip':>4} {'fail':>4}")
print("-" * 80)
total_pass = total_skip = total_fail = 0
for name in order:
    row = tests[name]
    print(f"{name:<64} {row['passed']:>4} {row['skipped']:>4} {row['failed']:>4}")
    total_pass += row["passed"]
    total_skip += row["skipped"]
    total_fail += row["failed"]
print("-" * 80)
print(f"{'TOTAL':<64} {total_pass:>4} {total_skip:>4} {total_fail:>4}")
print(f"distinct tests: {len(order)}")
print(f"log directory: {log_dir}")
if skip_reasons:
    print("skip reasons:")
    for reason, run_ids in skip_reasons.items():
        print(f"  {reason} (runs: {', '.join(map(str, run_ids))})")
if failed_logs:
    print("failure logs:")
    for path in failed_logs:
        print(f"  {path}")
else:
    print("failure logs: none")

summary = log_dir / "summary.txt"
lines = [
    f"runs={runs}",
    f"distinct={len(order)}",
    f"pass={total_pass}",
    f"skip={total_skip}",
    f"fail={total_fail}",
]
summary.write_text("\n".join(lines) + "\n")
if total_fail:
    sys.exit(1)
expected = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else 0
if expected and len(order) != expected:
    print(f"expected {expected} distinct UI tests, parsed {len(order)}", file=sys.stderr)
    sys.exit(1)
PY

exit "$run_status"
