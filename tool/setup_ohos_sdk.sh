#!/bin/sh
# Install (or verify) the machine-level shared OpenHarmony (CPF) Flutter SDK.
#
# Usage: ./tool/setup_ohos_sdk.sh [tag]
#   tag defaults to the version pinned in tool/ohos_sdk_version.
#
# Resolution: installs into $OHOS_FLUTTER_ROOT or ~/.ohos-flutter/flutter_flutter.
# Every repo resolves that same checkout, so the 1.1 GB toolchain and its
# download cache exist once per machine. Official (fvm) Flutter is untouched;
# never run `fvm use` against this SDK.

set -eu

usage() {
  cat <<'EOF'
Usage: ./tool/setup_ohos_sdk.sh [tag]

Install the CPF OpenHarmony Flutter fork into $OHOS_FLUTTER_ROOT
(default ~/.ohos-flutter/flutter_flutter) and bootstrap its toolchain.
The tag defaults to the version pinned in tool/ohos_sdk_version.
EOF
}

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_url=https://gitcode.com/CPF-Flutter/flutter_flutter.git
version=${1:-}
if [ -z "$version" ]; then
  version=$(tr -d ' \n' < "$project_root/tool/ohos_sdk_version")
fi

target=${OHOS_FLUTTER_ROOT:-$HOME/.ohos-flutter/flutter_flutter}

if [ -x "$target/bin/flutter" ]; then
  current=$(git -C "$target" describe --tags --always 2>/dev/null || echo unknown)
  if [ "$current" = "$version" ]; then
    echo "CPF Flutter $version already installed at $target"
  else
    echo "ERROR: $target has CPF Flutter $current but $version was requested." >&2
    echo "Upgrade manually:" >&2
    echo "  git -C $target fetch --tags --depth 1 origin refs/tags/$version:refs/tags/$version" >&2
    echo "  git -C $target checkout $version" >&2
    exit 1
  fi
else
  if [ -e "$target" ]; then
    echo "ERROR: $target exists but has no bin/flutter; remove it and retry." >&2
    exit 1
  fi
  mkdir -p "$(dirname -- "$target")"
  echo "Cloning CPF Flutter $version into $target ..."
  git clone --depth 1 --filter=blob:none --branch "$version" "$repo_url" "$target"
fi

echo "Bootstrapping the CPF Flutter toolchain (first run downloads Dart SDK) ..."
"$target/bin/flutter" --version

actual=$(python3 -c "import json; print(json.load(open('$target/bin/cache/flutter.version.json'))['frameworkVersion'])")
if [ "$actual" != "$version" ]; then
  echo "ERROR: bootstrapped CPF Flutter reports $actual, expected $version" >&2
  exit 1
fi
echo "CPF Flutter $version ready at $target"
