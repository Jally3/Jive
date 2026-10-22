#!/usr/bin/env bash

set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
trace_dir="$repo_root/logs"
trace_file="$trace_dir/playback_trace.log"

mkdir -p "$trace_dir"
: > "$trace_file"

echo "Playback trace output: $trace_file"
echo "Only JIVE_PLAYBACK_TRACE lines are written to that file."

cd "$repo_root" || exit 1
fvm flutter run --dart-define=JIVE_PLAYBACK_TRACE=true "$@" 2>&1 | awk -v trace_file="$trace_file" '
  /JIVE_PLAYBACK_TRACE/ {
    trace_line = $0
    sub(/^flutter:[[:space:]]*/, "", trace_line)
    print trace_line >> trace_file
    close(trace_file)
  }
  { print }
'

flutter_status=${PIPESTATUS[0]}
echo "Playback trace saved to: $trace_file"
exit "$flutter_status"
