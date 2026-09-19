#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage: ./tool/build_ohos.sh [--debug|--profile|--release] [--signed] [--target FILE]

Build Jive's HarmonyOS HAP. Defaults to a debug, unsigned build of lib/main.dart.
Set DEVECO_ROOT if DevEco Studio is outside /Applications/DevEco-Studio.app/Contents.
The OpenHarmony Flutter SDK must be installed at .ohos-sdk/.
EOF
}

mode=debug
signed=0
target=lib/main.dart

while [ "$#" -gt 0 ]; do
  case "$1" in
    --debug) mode=debug ;;
    --profile) mode=profile ;;
    --release) mode=release ;;
    --signed) signed=1 ;;
    --target)
      if [ "$#" -lt 2 ]; then
        echo "ERROR: --target requires a file path" >&2
        exit 2
      fi
      target=$2
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"

flutter_bin="$project_root/.ohos-sdk/bin/flutter"
if [ ! -x "$flutter_bin" ]; then
  echo "ERROR: OpenHarmony Flutter SDK is missing: $flutter_bin" >&2
  exit 1
fi
if [ ! -d ohos ]; then
  echo "ERROR: HarmonyOS runner is missing: $project_root/ohos" >&2
  exit 1
fi
if [ ! -f pubspec_overrides.yaml ]; then
  echo "ERROR: pubspec_overrides.yaml is missing; HarmonyOS plugins are not configured" >&2
  exit 1
fi
if [ ! -f "$target" ]; then
  echo "ERROR: Flutter entry point is missing: $target" >&2
  exit 1
fi

deveco_root=${DEVECO_ROOT:-/Applications/DevEco-Studio.app/Contents}
if [ -d "$deveco_root" ]; then
  PATH="$deveco_root/tools/ohpm/bin:$deveco_root/tools/hvigor/bin:$deveco_root/tools/node/bin:$PATH"
  DEVECO_SDK_HOME=${DEVECO_SDK_HOME:-$deveco_root/sdk}
  HOS_SDK_HOME=${HOS_SDK_HOME:-$DEVECO_SDK_HOME}
  export PATH DEVECO_SDK_HOME HOS_SDK_HOME
fi

if ! command -v hvigorw >/dev/null 2>&1; then
  echo "ERROR: hvigorw was not found; set DEVECO_ROOT to your DevEco Studio Contents directory" >&2
  exit 1
fi
if [ -z "${DEVECO_SDK_HOME:-}" ] || [ ! -d "$DEVECO_SDK_HOME" ]; then
  echo "ERROR: DEVECO_SDK_HOME must point to the installed HarmonyOS SDK" >&2
  exit 1
fi

python3 "$project_root/tool/patch_ohos_system_ui.py"

echo "Building HarmonyOS HAP: mode=$mode target=$target signed=$signed"
if [ "$signed" -eq 1 ]; then
  "$flutter_bin" build hap "--$mode" --codesign -t "$target"
else
  "$flutter_bin" build hap "--$mode" --no-codesign -t "$target"
fi
