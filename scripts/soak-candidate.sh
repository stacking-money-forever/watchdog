#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Record bounded local stability measurements for one running Watchdog candidate.

Usage: scripts/soak-candidate.sh --app PATH --pid PID --output-dir PATH [options]

Required:
  --app PATH                 Exact Watchdog.app bundle being observed
  --pid PID                  Running Watchdog PID whose text executable must match --app
  --output-dir PATH          New or empty directory for metadata.json and samples.csv

Optional:
  --duration-seconds N       Total duration (default: 28800; maximum: 28800)
  --interval-seconds N       Sample interval (default: 60; minimum: 1)
  --heartbeat PATH           Optional disposable-helper heartbeat file to sample
  -h, --help                 Show this help

The sampler never signals, launches, or modifies the candidate. It records no
command lines. A vanished candidate or changed text executable fails the run.
EOF
}

app_path=""
pid=""
output_dir=""
duration_seconds=28800
interval_seconds=60
heartbeat_path=""

while (($#)); do
  case "$1" in
    --app) app_path="${2:-}"; shift 2 ;;
    --pid) pid="${2:-}"; shift 2 ;;
    --output-dir) output_dir="${2:-}"; shift 2 ;;
    --duration-seconds) duration_seconds="${2:-}"; shift 2 ;;
    --interval-seconds) interval_seconds="${2:-}"; shift 2 ;;
    --heartbeat) heartbeat_path="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -d "$app_path" && -n "$pid" && -n "$output_dir" ]] || {
  usage >&2
  exit 2
}
[[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo "PID must be a positive integer." >&2; exit 2; }
[[ "$duration_seconds" =~ ^[1-9][0-9]*$ && "$duration_seconds" -le 28800 ]] || {
  echo "Duration must be 1–28800 seconds." >&2
  exit 2
}
[[ "$interval_seconds" =~ ^[1-9][0-9]*$ ]] || { echo "Interval must be at least one second." >&2; exit 2; }
(( duration_seconds / interval_seconds + 1 <= 500 )) || {
  echo "Requested sample count exceeds the 500-sample bound." >&2
  exit 2
}
[[ ! -e "$output_dir" || -d "$output_dir" ]] || { echo "Output path is not a directory." >&2; exit 2; }
mkdir -p "$output_dir"
[[ -z "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
  echo "Output directory must be empty." >&2
  exit 2
}

for command in codesign defaults find lsof ps shasum; do
  command -v "$command" >/dev/null || { echo "Required command not found: $command" >&2; exit 1; }
done

executable="$app_path/Contents/MacOS/Watchdog"
[[ -x "$executable" ]] || { echo "Watchdog executable is missing." >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$app_path"

is_exact_candidate_process() {
  /bin/kill -0 "$pid" 2>/dev/null || return 1
  lsof -a -p "$pid" -d txt -Fn 2>/dev/null | grep -Fx "n$executable" >/dev/null
}

is_exact_candidate_process || {
  echo "PID is not the exact requested Watchdog bundle." >&2
  exit 1
}

version="$(defaults read "$app_path/Contents/Info" CFBundleShortVersionString)"
build="$(defaults read "$app_path/Contents/Info" CFBundleVersion)"
bundle_hash="$(shasum -a 256 "$executable" | awk '{print $1}')"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

printf '{\n  "app": "%s",\n  "pid": %s,\n  "version": "%s",\n  "build": "%s",\n  "executable_sha256": "%s",\n  "started_at": "%s",\n  "duration_seconds": %s,\n  "interval_seconds": %s\n}\n' \
  "$app_path" "$pid" "$version" "$build" "$bundle_hash" "$started_at" "$duration_seconds" "$interval_seconds" \
  > "$output_dir/metadata.json"
printf 'timestamp_utc,rss_kb,cpu_percent,fd_count,heartbeat\n' > "$output_dir/samples.csv"

elapsed=0
while (( elapsed <= duration_seconds )); do
  is_exact_candidate_process || {
    echo "Candidate process disappeared or changed identity." >&2
    exit 1
  }
  process_stats="$(ps -p "$pid" -o rss= -o %cpu=)"
  rss_kb="$(awk 'NR == 1 { print $1 }' <<<"$process_stats")"
  cpu_percent="$(awk 'NR == 1 { print $2 }' <<<"$process_stats")"
  fd_count="$(lsof -p "$pid" 2>/dev/null | wc -l | tr -d ' ')"
  heartbeat="-"
  if [[ -n "$heartbeat_path" && -f "$heartbeat_path" ]]; then
    heartbeat="$(LC_ALL=C tr -cd '0-9\n' < "$heartbeat_path" | head -n 1 || true)"
    [[ -n "$heartbeat" ]] || heartbeat="invalid"
  fi
  printf '%s,%s,%s,%s,%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rss_kb" "$cpu_percent" "$fd_count" "$heartbeat" \
    >> "$output_dir/samples.csv"
  (( elapsed == duration_seconds )) && break
  sleep "$interval_seconds"
  elapsed=$((elapsed + interval_seconds))
done

printf 'Completed %s samples in %s.\n' "$(($(wc -l < "$output_dir/samples.csv") - 1))" "$output_dir"
