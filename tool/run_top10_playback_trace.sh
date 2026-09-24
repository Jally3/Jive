#!/usr/bin/env bash

set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
trace_dir="$repo_root/logs"
trace_file="$trace_dir/playback_trace_top10.log"
device="${PLAYBACK_TRACE_DEVICE:-iPhone 17 Pro}"

if [[ $# -gt 0 ]]; then
  device="$1"
  shift
fi

mkdir -p "$trace_dir"
: > "$trace_file"

echo "Device: $device"
echo "Playback trace output: $trace_file"
echo "The test will open and start the first 10 distinct videos on Home."

cd "$repo_root" || exit 1
fvm flutter test \
  --dart-define=JIVE_PLAYBACK_TRACE=true \
  integration_test/playback_trace_top10_test.dart \
  -d "$device" \
  "$@" 2>&1 | awk -v trace_file="$trace_file" '
  /JIVE_PLAYBACK_TRACE/ {
    trace_line = $0
    sub(/^[[:space:]]*flutter:[[:space:]]*/, "", trace_line)
    print trace_line >> trace_file
    close(trace_file)
  }
  { print }
'

flutter_status=${PIPESTATUS[0]}
echo "Top-10 playback traces saved to: $trace_file"
exit "$flutter_status"
