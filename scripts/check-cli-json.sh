#!/usr/bin/env bash
# Compare live watchdog-cli --json enum strings against docs/cli-json.schema.json.
# Usage: scripts/check-cli-json.sh /path/to/watchdog-cli
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /path/to/watchdog-cli" >&2
  exit 64
fi

cli=$1
if [[ ! -x "$cli" ]]; then
  echo "not executable: $cli" >&2
  exit 64
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
schema="$repo_root/docs/cli-json.schema.json"
fixture="$repo_root/WatchdogTests/Fixtures/mac-20261030.json"
labels="$repo_root/WatchdogTests/Fixtures/mac-20261030.labels.json"

if [[ ! -f "$schema" ]]; then
  echo "missing schema: $schema" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/watchdog-cli-json.XXXXXX")"
trap 'rm -rf "$work"' EXIT
export WATCHDOG_LEDGER_PATH="$work/ledger/suspensions.json"
export WATCHDOG_JOURNAL_PATH="$work/journal.jsonl"
export WATCHDOG_RULES_PATH="$work/absent-rules.json"
mkdir -p "$work/ledger"

run_json() {
  local name=$1
  shift
  local out="$work/$name.json"
  if ! "$@" >"$out" 2>"$work/$name.err"; then
    echo "command failed: $*" >&2
    sed 's/^/  | /' "$work/$name.err" >&2
    exit 1
  fi
  echo "$out"
}

list_out=$(run_json list "$cli" list --scope all --json --interval 0.2)
sessions_out=$(run_json sessions "$cli" sessions --json --interval 0.2)
doctor_out=$(run_json doctor "$cli" doctor --json)
rules_out=$(run_json rules "$cli" rules show --json)
audit_out=$(run_json audit "$cli" audit "$fixture" --json)
audit_labels_out=$(run_json audit-labels "$cli" audit "$fixture" --labels "$labels" --json)

/usr/bin/python3 - "$schema" "$list_out" "$sessions_out" "$doctor_out" "$rules_out" "$audit_out" "$audit_labels_out" <<'PY'
import json, re, sys

schema_path, list_path, sessions_path, doctor_path, rules_path, audit_path, audit_labels_path = sys.argv[1:]
schema = json.load(open(schema_path))
mismatches = []

def add(where, message):
    mismatches.append(f"{where}: {message}")

process_kind = set(schema["processKind"])
orphan_reason = set(schema["orphanReason"])
list_flags = set(schema["listFlags"])
via_re = re.compile(schema["listFlagViaPattern"])
watch_types = set(schema["watchEventType"])
stopped_source = set(schema["stoppedSource"])
journal_source = set(schema["journalSource"])
journal_action = set(schema["journalAction"])
control_result = set(schema["controlResult"])
session_flags = set(schema["sessionFlags"])
missing_kind = schema["auditMissingKind"]
allowed_kind_keys = process_kind | {missing_kind}

def load(path):
    with open(path) as fh:
        return json.load(fh)

def check_flag(where, flag):
    if flag in list_flags:
        return
    if via_re.match(flag):
        return
    add(where, f"unknown list flag {flag!r}")

list_rows = load(list_path)
if not isinstance(list_rows, list):
    add("list", "expected a JSON array")
else:
    print(f"list --json: {len(list_rows)} rows")
    for index, row in enumerate(list_rows):
        if not isinstance(row, dict):
            add(f"list[{index}]", "expected object")
            continue
        kind = row.get("kind")
        if kind not in process_kind:
            add(f"list[{index}].kind", repr(kind))
        reason = row.get("orphanReason")
        if reason is not None and reason not in orphan_reason:
            add(f"list[{index}].orphanReason", repr(reason))
        flags = row.get("flags", [])
        if not isinstance(flags, list):
            add(f"list[{index}].flags", "expected array")
            continue
        for flag in flags:
            check_flag(f"list[{index}].flags", flag)

sessions = load(sessions_path)
if not isinstance(sessions, list):
    add("sessions", "expected a JSON array")
else:
    print(f"sessions --json: {len(sessions)} rows")
    for index, row in enumerate(sessions):
        kind = row.get("kind") if isinstance(row, dict) else None
        if kind not in process_kind:
            add(f"sessions[{index}].kind", repr(kind))

doctor = load(doctor_path)
if not isinstance(doctor, dict):
    add("doctor", "expected an object")
else:
    print("doctor --json: object")
    settings = doctor.get("settings")
    if not isinstance(settings, dict):
        add("doctor.settings", "expected object")

rules = load(rules_path)
if not isinstance(rules, dict):
    add("rules show", "expected an object")
else:
    print("rules show --json: object")
    nested = rules.get("rules")
    if nested is not None:
        if not isinstance(nested, dict):
            add("rules show.rules", "expected object or null")
        else:
            markers = nested.get("packageMarkers", [])
            if not isinstance(markers, list):
                add("rules show.rules.packageMarkers", "expected array")

summary = load(audit_path)
if not isinstance(summary, dict):
    add("audit", "expected an object")
else:
    print("audit --json: ClassificationSummary")
    kinds = summary.get("kinds", {})
    if not isinstance(kinds, dict):
        add("audit.kinds", "expected object")
    else:
        for key in kinds:
            if key not in process_kind:
                add("audit.kinds", repr(key))
    for index, row in enumerate(summary.get("orphans") or []):
        reason = row.get("orphanReason") if isinstance(row, dict) else None
        if reason is not None and reason not in orphan_reason:
            add(f"audit.orphans[{index}].orphanReason", repr(reason))

report = load(audit_labels_path)
if not isinstance(report, dict):
    add("audit --labels", "expected an object")
else:
    print("audit --labels --json: AuditReport")
    confusion = report.get("kindConfusion") or {}
    if isinstance(confusion, dict):
        for row_key, cols in confusion.items():
            if row_key not in allowed_kind_keys:
                add("audit.kindConfusion row", repr(row_key))
            if isinstance(cols, dict):
                for col_key in cols:
                    if col_key not in allowed_kind_keys:
                        add("audit.kindConfusion col", repr(col_key))

# Silence unused contract sets so the schema is the single checklist.
_ = (watch_types, stopped_source, journal_source, journal_action, control_result, session_flags)

print()
if mismatches:
    print(f"mismatches: {len(mismatches)}")
    for item in mismatches:
        print(f"  {item}")
    sys.exit(1)

print("mismatches: 0")
PY
