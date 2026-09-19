#!/usr/bin/env python3
"""Inject/restore local HarmonyOS signing configs for Jive's OHOS build.

The committed ohos/build-profile.json5 must stay free of machine-specific
signing material. To produce a signed HAP from the CLI, this script splices a
`signingConfigs` array read from a gitignored JSON file into the build profile
before the build and restores the original file afterwards.

Usage:
  ohos_signing.py inject    # copy build profile to backup, splice signing in
  ohos_signing.py restore   # restore the original build profile

The signing config file defaults to tool/ohos_signing.local.json and is a JSON
document with a single "signingConfigs" array, exactly as DevEco Studio
generates it (File > Project Structure > Signing Configs). Copy that block
into the local file; never commit it.
"""

import json
import re
import shutil
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
BUILD_PROFILE = PROJECT_ROOT / "ohos" / "build-profile.json5"
BACKUP = PROJECT_ROOT / "ohos" / "build-profile.json5.pre-signing"
DEFAULT_CONFIG = PROJECT_ROOT / "tool" / "ohos_signing.local.json"

SIGNING_RE = re.compile(r'("signingConfigs"\s*:\s*)\[')


def fail(message: str) -> "None":
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_signing_configs() -> str:
    path = Path(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_CONFIG
    if not path.is_file():
        fail(
            f"signing config file is missing: {path}\n"
            "Create it from DevEco Studio's generated signing block "
            "(File > Project Structure > Signing Configs > signingConfigs), e.g.\n"
            '{"signingConfigs": [{"name": "default", "type": "HarmonyOS", '
            '"material": {"certpath": "...", "keyAlias": "debug", '
            '"keyPassword": "...", "profile": "...", "signAlg": "SHA256withECDSA", '
            '"storeFile": "...", "storePassword": "..."}}]}\n'
            "The file is gitignored; keep it that way."
        )
    try:
        data = json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        fail(f"{path} is not valid JSON: {exc}")
    configs = data.get("signingConfigs") if isinstance(data, dict) else data
    if not isinstance(configs, list) or not configs:
        fail(f"{path} must contain a non-empty \"signingConfigs\" array")
    # json5 tolerates plain JSON, so dumping the array back is safe.
    return json.dumps(configs, indent=2, ensure_ascii=False)


def inject() -> None:
    if BACKUP.exists():
        # A previous run died before restoring; start from the clean copy.
        shutil.copyfile(BACKUP, BUILD_PROFILE)
    original = BUILD_PROFILE.read_text()
    new_text, count = SIGNING_RE.subn(
        lambda m: m.group(1) + load_signing_configs(), original, count=1
    )
    if count != 1:
        fail("could not find a \"signingConfigs\" array in ohos/build-profile.json5")
    BACKUP.write_text(original)
    BUILD_PROFILE.write_text(new_text)
    print(f"Injected signing configs into {BUILD_PROFILE} (backup: {BACKUP})")


def restore() -> None:
    if not BACKUP.exists():
        print("No signing backup to restore; build profile left untouched.")
        return
    shutil.copyfile(BACKUP, BUILD_PROFILE)
    BACKUP.unlink()
    print(f"Restored {BUILD_PROFILE}")


def main() -> None:
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    if action == "inject":
        inject()
    elif action == "restore":
        restore()
    else:
        fail(f"unknown action {action!r}; use inject or restore")


if __name__ == "__main__":
    main()
