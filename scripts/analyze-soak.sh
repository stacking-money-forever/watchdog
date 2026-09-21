#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Analyze one soak-candidate sample set without changing the candidate.

Usage: scripts/analyze-soak.sh --input-dir PATH --output-dir PATH

The input directory must contain metadata.json and samples.csv created by
soak-candidate.sh. The output directory must be new or empty. The result
reports candidate identity, expected versus observed sample count, heartbeat
continuity, the largest gap between consecutive sample timestamps, and
first/last/max RSS and FD values. It fails if the sample set is incomplete or
malformed, or if a timestamp gap exceeds two sampling intervals.
EOF
}

input_dir=""
output_dir=""

while (($#)); do
  case "$1" in
    --input-dir) input_dir="${2:-}"; shift 2 ;;
    --output-dir) output_dir="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$input_dir" && -n "$output_dir" ]] || { usage >&2; exit 2; }
[[ -f "$input_dir/metadata.json" && -f "$input_dir/samples.csv" ]] || {
  echo "Input directory must contain metadata.json and samples.csv." >&2
  exit 2
}
[[ ! -e "$output_dir" || -d "$output_dir" ]] || { echo "Output path is not a directory." >&2; exit 2; }
mkdir -p "$output_dir"
[[ -z "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
  echo "Output directory must be empty." >&2
  exit 2
}

for command in awk jq; do
  command -v "$command" >/dev/null || { echo "Required command not found: $command" >&2; exit 1; }
done

duration="$(jq -er '.duration_seconds | numbers' "$input_dir/metadata.json")"
interval="$(jq -er '.interval_seconds | numbers' "$input_dir/metadata.json")"
expected=$((duration / interval + 1))

awk -F, -v expected="$expected" -v interval="$interval" '
  function days_from_civil(y, m, d,   era, yoe, doy, doe) {
    y -= (m <= 2)
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
  }
  function parse_timestamp(ts,   parts, sec) {
    if (ts ~ /^[0-9]+$/) return ts + 0
    if (ts !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z?$/) return -1
    split(ts, parts, /[-T:]/)
    sec = parts[6]
    sub(/Z$/, "", sec)
    return days_from_civil(parts[1], parts[2], parts[3]) * 86400 + parts[4] * 3600 + parts[5] * 60 + sec
  }
  NR == 1 {
    if ($0 != "timestamp_utc,rss_kb,cpu_percent,fd_count,heartbeat") {
      print "invalid sample header" > "/dev/stderr"; exit 2
    }
    next
  }
  {
    if (NF != 5 || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+(\.[0-9]+)?$/ || $4 !~ /^[0-9]+$/ || $5 !~ /^[0-9]+$/) {
      print "malformed sample at line " NR > "/dev/stderr"; exit 2
    }
    ts = parse_timestamp($1)
    if (ts < 0) {
      print "malformed timestamp at line " NR > "/dev/stderr"; exit 2
    }
    if (count > 0) {
      gap = ts - previous_ts
      if (gap <= 0) {
        print "non-increasing timestamp at line " NR > "/dev/stderr"; exit 2
      }
      if (gap > max_gap) max_gap = gap
    }
    previous_ts = ts
    count++
    rss = $2 + 0
    fd = $4 + 0
    heartbeat = $5 + 0
    if (count == 1) {
      first_rss = rss; first_fd = fd; first_heartbeat = heartbeat
      max_rss = rss; max_fd = fd
    }
    if (rss > max_rss) max_rss = rss
    if (fd > max_fd) max_fd = fd
    if (count > 1 && heartbeat <= previous_heartbeat) {
      print "non-increasing heartbeat at line " NR > "/dev/stderr"; exit 2
    }
    previous_heartbeat = heartbeat
    last_rss = rss; last_fd = fd; last_heartbeat = heartbeat
  }
  END {
    if (count == 0) { print "no samples" > "/dev/stderr"; exit 2 }
    printf "expected_samples=%d\nobserved_samples=%d\n", expected, count
    printf "rss_kb_first=%d\nrss_kb_last=%d\nrss_kb_max=%d\n", first_rss, last_rss, max_rss
    printf "fd_first=%d\nfd_last=%d\nfd_max=%d\n", first_fd, last_fd, max_fd
    printf "heartbeat_first=%d\nheartbeat_last=%d\n", first_heartbeat, last_heartbeat
    printf "interval_seconds=%d\nmax_timestamp_gap_seconds=%d\n", interval, max_gap
    if (max_gap > 2 * interval) {
      print "timestamp gap " max_gap "s exceeds two sampling intervals (" 2 * interval "s)" > "/dev/stderr"
      exit 4
    }
    if (count != expected) exit 3
  }
' "$input_dir/samples.csv" > "$output_dir/summary.txt"

jq -e '{app, pid, version, build, executable_sha256, started_at, duration_seconds, interval_seconds}' \
  "$input_dir/metadata.json" > "$output_dir/identity.json"

echo "Soak analysis written to $output_dir"
