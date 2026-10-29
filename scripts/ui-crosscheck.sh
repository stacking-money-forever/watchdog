#!/usr/bin/env bash
# Cross-check what a running Watchdog shows in its window against the JSON the
# watchdog-cli from the same bundle reports. Reads the UI through the
# accessibility tree (scripts/ax-walk.swift bound to the pid) so the values the
# user hears/sees are the ones compared.
#
# Usage: scripts/ui-crosscheck.sh <pid> <path/to/Watchdog.app>
#   WATCHDOG_CROSSCHECK_CPU_TOLERANCE  max |UI − CLI| CPU points per session (default 40)
#
# Exit codes: 0 all hard checks agree, 1 mismatch, 64 usage, 65 window/AX failure.
set -euo pipefail

pid="${1:?usage: ui-crosscheck.sh <pid> <Watchdog.app>}"
app="${2:?usage: ui-crosscheck.sh <pid> <Watchdog.app>}"
cli="$app/Contents/MacOS/watchdog-cli"
[[ -x "$cli" ]] || { echo "no watchdog-cli in $app" >&2; exit 64; }
kill -0 "$pid" 2>/dev/null || { echo "pid $pid is not running" >&2; exit 64; }
cpu_tolerance="${WATCHDOG_CROSSCHECK_CPU_TOLERANCE:-40}"

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/watchdog-crosscheck.XXXXXX")"
trap 'rm -rf "$work"' EXIT
swiftc -O -framework ApplicationServices -framework CoreGraphics -o "$work/ax-walk" "$here/ax-walk.swift"
walker="$work/ax-walk"

labels() { "$walker" "$pid" labels "$1"; }

has_window() { labels "watchdog.window" >/dev/null 2>&1; }

ensure_window() {
  if has_window; then return 0; fi
  echo "main window not open; opening it through the menu bar popover"
  "$walker" "$pid" extras >/dev/null

  for _ in $(seq 1 30); do
    if "$walker" "$pid" press "watchdog.open-window" 2>/dev/null; then break; fi
    sleep 0.2
  done
  for _ in $(seq 1 50); do
    has_window && return 0
    sleep 0.2
  done
  echo "could not open the Watchdog window for pid $pid" >&2
  exit 65
}

select_section() {
  local section="$1"
  if ! "$walker" "$pid" press "watchdog.sidebar.$section" 2>/dev/null; then
    "$walker" "$pid" click "watchdog.sidebar.$section"
  fi

  for _ in $(seq 1 50); do
    labels "watchdog.window.detail.$section" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "section $section did not appear" >&2
  exit 65
}

ensure_window

# --- Overview counters -------------------------------------------------------
select_section overview
sleep 0.5
labels "watchdog.overview." >"$work/overview.tsv"
"$cli" stopped --json >"$work/stopped.json"
"$cli" list --json >"$work/list.json"
"$cli" sessions --json >"$work/sessions.json"

ui_stopped="$(awk -F'\t' '$1=="watchdog.overview.stopped-button"{print $3}' "$work/overview.tsv" | grep -o '[0-9]\+' | head -1 || true)"
ui_orphans="$(awk -F'\t' '$1=="watchdog.overview.orphans-button"{print $3}' "$work/overview.tsv" | grep -o '[0-9]\+' | head -1 || true)"
ui_attention="$(awk -F'\t' '$1=="watchdog.overview.sessions-button"{print $3}' "$work/overview.tsv" | grep -o '[0-9]\+' | head -1 || true)"
cli_stopped="$(jq 'length' "$work/stopped.json")"
cli_orphans="$(jq '[.[] | select(.orphanReason != null)] | length' "$work/list.json")"

# --- Session rows --------------------------------------------------------------
select_section sessions
sleep 0.5
labels "session." >"$work/sessions.tsv" || true

status=0
printf '%-28s %10s %10s %s\n' "check" "ui" "cli" "result"
printf '%-28s %10s %10s %s\n' "---------------------------" "----------" "----------" "------"

compare() {
  local name="$1" ui="$2" cli="$3" hard="$4"
  local result="ok"
  if [[ "$ui" != "$cli" ]]; then
    if [[ "$hard" == "hard" ]]; then result="MISMATCH"; status=1; else result="differs (soft)"; fi
  fi
  printf '%-28s %10s %10s %s\n' "$name" "${ui:-?}" "${cli:-?}" "$result"
}

compare "stopped by Watchdog" "$ui_stopped" "$cli_stopped" hard
compare "orphans" "$ui_orphans" "$cli_orphans" soft
printf '%-28s %10s %10s %s\n' "attention sessions" "${ui_attention:-?}" "-" "(UI only; CLI has no hot flag)"

python3 - "$work/sessions.tsv" "$work/sessions.json" "$cpu_tolerance" <<'PY' || status=1
import json, re, sys
rows = {}
for line in open(sys.argv[1], encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 3 or not parts[0].endswith(".row"):
        continue
    ident, label = parts[0], parts[2]
    m = re.match(r"session\.(\d+)\.(\d+)\.row", ident)
    if not m:
        continue
    root = int(m.group(1))
    cpu = re.search(r"CPU (\d+)퍼센트", label)
    members = re.search(r"자식 (\d+)개", label)
    name = label.split(",", 1)[0].strip()
    rows[root] = {
        "name": name,
        "cpu": int(cpu.group(1)) if cpu else None,
        "members": int(members.group(1)) if members else None,
    }
cli = {s["rootPID"]: s for s in json.load(open(sys.argv[2], encoding="utf-8"))}
tol = float(sys.argv[3])
bad = 0

def report(name, ui, cl, ok):
    global bad
    print(f"{name:<28} {str(ui):>10} {str(cl):>10} {'ok' if ok else 'MISMATCH'}")
    if not ok:
        bad += 1

ui_set, cli_set = set(rows), set(cli)
report("session roots (count)", len(ui_set), len(cli_set), ui_set == cli_set)
for root in sorted(ui_set - cli_set):
    print(f"  UI only: {root} {rows[root]['name']}")
for root in sorted(cli_set - ui_set):
    print(f"  CLI only: {root} {cli[root]['name']}")
for root in sorted(ui_set & cli_set):
    u, c = rows[root], cli[root]
    report(f"  {root} {u['name']} members", u["members"], c["memberCount"], u["members"] == c["memberCount"])
    if u["cpu"] is not None:
        delta = abs(u["cpu"] - round(c["cpuPercent"]))
        print(f"  {root} {u['name']} cpu          {u['cpu']:>10} {round(c['cpuPercent']):>10} {'ok' if delta <= tol else 'differs (soft, Δ%d)' % delta}")
sys.exit(1 if bad else 0)
PY

if [[ "$status" -eq 0 ]]; then
  echo "crosscheck: UI and CLI agree"
else
  echo "crosscheck: MISMATCH" >&2
fi
exit "$status"
