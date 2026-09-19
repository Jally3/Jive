#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage: ./tool/build_ohos.sh [--debug|--profile|--release] [--signed] [--target FILE]

Build Jive's HarmonyOS HAP. Defaults to a debug, unsigned build of lib/main.dart.
Set DEVECO_ROOT if DevEco Studio is outside /Applications/DevEco-Studio.app/Contents.

The CPF OpenHarmony Flutter SDK is resolved from $OHOS_FLUTTER_ROOT, then
~/.ohos-flutter/flutter_flutter, then the legacy .ohos-sdk/ checkout.
Run ./tool/setup_ohos_sdk.sh once to install it (see doc/ohos/SDK_SETUP.md).
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
ohos_sdk_version=$(tr -d ' \n' < "$project_root/tool/ohos_sdk_version")

# Resolve the shared CPF SDK: explicit env override, then the machine-level
# install, then the legacy in-repo checkout. Same order as patch_ohos_system_ui.py.
if [ -n "${OHOS_FLUTTER_ROOT:-}" ]; then
  ohos_sdk=$OHOS_FLUTTER_ROOT
  if [ ! -x "$ohos_sdk/bin/flutter" ]; then
    echo "ERROR: OHOS_FLUTTER_ROOT is set to $ohos_sdk but bin/flutter is missing" >&2
    exit 1
  fi
elif [ -x "$HOME/.ohos-flutter/flutter_flutter/bin/flutter" ]; then
  ohos_sdk=$HOME/.ohos-flutter/flutter_flutter
elif [ -x "$project_root/.ohos-sdk/bin/flutter" ]; then
  ohos_sdk=$project_root/.ohos-sdk
else
  echo "ERROR: OpenHarmony Flutter SDK not found. Run ./tool/setup_ohos_sdk.sh first." >&2
  exit 1
fi
flutter_bin="$ohos_sdk/bin/flutter"

# Bootstrap a fresh clone on demand, then pin the checkout to the exact CPF
# release this repository is validated against (tool/ohos_sdk_version).
if [ ! -f "$ohos_sdk/bin/cache/flutter.version.json" ]; then
  echo "Bootstrapping the CPF Flutter toolchain at $ohos_sdk ..."
  "$flutter_bin" --version
fi
ohos_sdk_actual=$(python3 -c "import json; print(json.load(open('$ohos_sdk/bin/cache/flutter.version.json'))['frameworkVersion'])")
if [ "$ohos_sdk_actual" != "$ohos_sdk_version" ]; then
  echo "ERROR: CPF Flutter at $ohos_sdk reports $ohos_sdk_actual, but this repository pins $ohos_sdk_version." >&2
  echo "Run ./tool/setup_ohos_sdk.sh <tag> for upgrade instructions." >&2
  exit 1
fi

# Keep the OHOS runner pointed at the resolved SDK (IDE / direct hvigorw runs
# read it too). The flutter tool regenerates the rest of the file.
props="$project_root/ohos/local.properties"
if [ -f "$props" ] && ! grep -qx "flutter.sdk=$ohos_sdk" "$props"; then
  if grep -q "^flutter.sdk=" "$props"; then
    sed -i.bak "s|^flutter.sdk=.*|flutter.sdk=$ohos_sdk|" "$props" && rm -f "$props.bak"
  else
    printf 'flutter.sdk=%s\n' "$ohos_sdk" >> "$props"
  fi
  echo "Updated ohos/local.properties flutter.sdk -> $ohos_sdk"
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

# Exit codes: 0 = already patched, 2 = patched something this run.
apply_patch() {
  python3 "$project_root/tool/patch_ohos_system_ui.py"
}

build_hap() {
  if [ "$signed" -eq 1 ]; then
    "$flutter_bin" build hap "--$mode" --codesign -t "$target"
  else
    "$flutter_bin" build hap "--$mode" --no-codesign -t "$target"
  fi
}

echo "Building HarmonyOS HAP: mode=$mode target=$target signed=$signed sdk=$ohos_sdk"
if [ "$signed" -eq 1 ]; then
  # Signing material stays out of the repository: splice it in from a
  # gitignored local file for the build, then always restore the clean profile.
  python3 "$project_root/tool/ohos_signing.py" inject
  restore_signing() {
    python3 "$project_root/tool/ohos_signing.py" restore
  }
  trap restore_signing EXIT INT TERM
fi

first_patch_rc=0
apply_patch || first_patch_rc=$?
if [ "$first_patch_rc" != 0 ] && [ "$first_patch_rc" != 2 ]; then
  exit "$first_patch_rc"
fi

build_hap

# Cold-cache convergence: engine artifacts (flutter.har) download during the
# first build, so a fresh clone can only be patched in full afterwards. If the
# second pass changed anything, rebuild once with the patched embedding.
second_patch_rc=0
apply_patch || second_patch_rc=$?
if [ "$second_patch_rc" -eq 2 ]; then
  echo "Cold cache detected: engine artifacts were patched after the first build; rebuilding with the patched embedding."
  build_hap
elif [ "$second_patch_rc" != 0 ]; then
  exit "$second_patch_rc"
fi
