#!/bin/bash
set -euo pipefail

usage() {
  echo "Usage: scripts/build-candidate.sh --output-dir PATH" >&2
}

[[ $# -eq 2 && "$1" == "--output-dir" ]] || { usage; exit 2; }
output_dir="$2"
[[ -n "$output_dir" && "$output_dir" != "/" ]] || { usage; exit 2; }

if [[ -e "$output_dir" ]]; then
  [[ -d "$output_dir" ]] || { echo "Output path is not a directory." >&2; exit 2; }
  [[ -z "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
    echo "Output directory must be empty." >&2
    exit 2
  }
else
  mkdir -p "$output_dir"
fi

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/watchdog-candidate.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

# Record the exact source state before project generation mutates the worktree.
# HEAD alone cannot identify a candidate built from a dirty worktree, so the
# manifest also carries a tree hash of the working state.
source_sha="$(git rev-parse HEAD)"
worktree_index="$build_dir/candidate-index"
GIT_INDEX_FILE="$worktree_index" git read-tree HEAD
GIT_INDEX_FILE="$worktree_index" git add -A
source_tree="$(GIT_INDEX_FILE="$worktree_index" git write-tree)"
if [[ -z "$(git status --porcelain)" ]]; then
  source_dirty=false
else
  source_dirty=true
fi

xcodegen generate
/usr/bin/xcodebuild \
  -project Watchdog.xcodeproj \
  -scheme Watchdog \
  -configuration Release \
  -derivedDataPath "$build_dir" \
  build

app="$build_dir/Build/Products/Release/Watchdog.app"
[[ -d "$app" ]] || { echo "Release app was not produced." >&2; exit 1; }

version="$(defaults read "$app/Contents/Info" CFBundleShortVersionString)"
build="$(defaults read "$app/Contents/Info" CFBundleVersion)"
app_output="$output_dir/Watchdog.app"
zip_output="$output_dir/Watchdog-${version}-macos.zip"
dmg_output="$output_dir/Watchdog-${version}-macos.dmg"

ditto "$app" "$app_output"
ditto -c -k --keepParent "$app_output" "$zip_output"
hdiutil create -volname Watchdog -srcfolder "$app_output" -ov -format UDZO "$dmg_output"

zip_sha="$(shasum -a 256 "$zip_output" | awk '{print $1}')"
dmg_sha="$(shasum -a 256 "$dmg_output" | awk '{print $1}')"
architectures="$(lipo -archs "$app_output/Contents/MacOS/Watchdog")"
codesign_info="$(codesign -dv --verbose=4 "$app_output" 2>&1)"
signature="$(awk -F= '/^Signature=/{print $2}' <<<"$codesign_info")"
team_id="$(awk -F= '/^TeamIdentifier=/{print $2}' <<<"$codesign_info")"
entitlements="$(codesign -d --entitlements :- "$app_output" 2>&1 || true)"
if grep -q 'get-task-allow' <<<"$entitlements"; then
  get_task_allow=true
else
  get_task_allow=false
fi

cat > "$output_dir/SHA256SUMS.txt" <<EOF
$zip_sha  $(basename "$zip_output")
$dmg_sha  $(basename "$dmg_output")
EOF

cat > "$output_dir/manifest.json" <<EOF
{
  "source_sha": "$source_sha",
  "source_tree": "$source_tree",
  "source_dirty": $source_dirty,
  "version": "$version",
  "build": "$build",
  "architectures": "$architectures",
  "artifacts": {
    "zip": {"name": "$(basename "$zip_output")", "sha256": "$zip_sha"},
    "dmg": {"name": "$(basename "$dmg_output")", "sha256": "$dmg_sha"}
  },
  "codesign": {
    "signature": "$signature",
    "team_identifier": "$team_id",
    "get_task_allow": $get_task_allow
  }
}
EOF

codesign --verify --deep --strict --verbose=2 "$app_output"
echo "Candidate artifacts: $output_dir"
