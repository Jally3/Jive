#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"

expected_version=$(sed -n 's/.*"flutter"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' .fvmrc)
if [ -z "$expected_version" ]; then
  echo "ERROR: cannot read Flutter version from .fvmrc" >&2
  exit 1
fi

failed=0

check_contains() {
  label=$1
  file=$2
  pattern=$3
  if [ ! -f "$file" ]; then
    echo "ERROR: $label is missing: $file" >&2
    failed=1
  elif ! grep -Fq "$pattern" "$file"; then
    echo "ERROR: $label does not use Flutter $expected_version: $file" >&2
    failed=1
  else
    echo "OK: $label"
  fi
}

if [ ! -L .fvm/flutter_sdk ]; then
  echo "ERROR: .fvm/flutter_sdk is missing; run 'fvm use'" >&2
  exit 1
else
  linked_sdk=$(readlink .fvm/flutter_sdk)
  case "$linked_sdk" in
    *"/$expected_version") echo "OK: FVM SDK link" ;;
    *)
      echo "ERROR: FVM SDK link points to $linked_sdk, expected Flutter $expected_version" >&2
      failed=1
      ;;
  esac
fi

expected_sdk=$(CDPATH= cd -- .fvm/flutter_sdk && pwd -P)
check_contains "Dart package config" .dart_tool/package_config.json "$expected_sdk"
check_contains "iOS generated config" ios/Flutter/Generated.xcconfig "$expected_sdk"
check_contains "iOS export environment" ios/Flutter/flutter_export_environment.sh "$expected_sdk"
check_contains "Android local properties" android/local.properties "$expected_sdk"

if [ -f macos/Flutter/ephemeral/Flutter-Generated.xcconfig ]; then
  check_contains \
    "macOS generated config" \
    macos/Flutter/ephemeral/Flutter-Generated.xcconfig \
    "$expected_sdk"
fi

if [ "$failed" -ne 0 ]; then
  echo "SDK configuration is inconsistent. Run 'fvm use' and 'fvm flutter pub get', then retry." >&2
  exit 1
fi

echo "Flutter SDK configuration is consistent: $expected_version"
