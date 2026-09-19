#!/bin/sh

# Restores the official FVM SDK's generated configs after any CPF OpenHarmony
# flutter command ran in this checkout. The ohos toolchain rewrites
# .dart_tool/package_config.json and the ephemeral Xcode configs with its own
# FLUTTER_ROOT, which makes tool/check_flutter_sdk.sh (and therefore iOS/macOS
# builds) fail. ./tool/build_ohos.sh runs this automatically; run it manually
# after any other ohos flutter command (JIVE_SKIP_FVM_RESTORE=1 skips the
# automatic call).

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_root"

echo "==> fvm flutter pub get"
fvm flutter pub get

# pub get does NOT regenerate macos/Flutter/ephemeral, so this step is required
# even right after a pub get.
echo "==> fvm flutter build macos --config-only"
if ! fvm flutter build macos --config-only; then
  echo "ERROR: macOS config generation failed. If macOS desktop is disabled, run: fvm flutter config --enable-macos-desktop" >&2
  exit 1
fi

# Belt and braces: flutter run/build ios regenerates these on its own, but
# doing it here keeps tool/check_flutter_sdk.sh green immediately.
echo "==> fvm flutter build ios --config-only --no-codesign"
fvm flutter build ios --config-only --no-codesign

./tool/check_flutter_sdk.sh
