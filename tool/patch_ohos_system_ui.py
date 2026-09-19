#!/usr/bin/env python3
"""Patch the Flutter-OH system UI mode reply in source and cached HARs.

Exit codes: 0 = everything already patched (no-op), 2 = patched something this
run, 1 = error. tool/build_ohos.sh uses exit code 2 to decide whether a cold
cache needs a second build with the now-patched embedding.
"""

from io import BytesIO
from pathlib import Path
import os
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parent.parent
CHANNEL = Path("src/main/ets/embedding/engine/systemchannels/PlatformChannel.ets")
HAR_CHANNEL = f"package/{CHANNEL}"
BEFORE = b"this.platform.platformMessageHandler.showSystemUiMode(mode);\n          } catch (err) {"
AFTER = b"this.platform.platformMessageHandler.showSystemUiMode(mode);\n            result.success(null);\n          } catch (err) {"


def resolve_sdk() -> Path:
    """Locate the shared CPF Flutter checkout.

    Resolution order: $OHOS_FLUTTER_ROOT, ~/.ohos-flutter/flutter_flutter,
    then the legacy in-repo .ohos-sdk checkout. Must match build_ohos.sh.
    """
    candidates = []
    env_root = os.environ.get("OHOS_FLUTTER_ROOT")
    if env_root:
        candidates.append(Path(env_root).expanduser())
    candidates.append(Path.home() / ".ohos-flutter" / "flutter_flutter")
    candidates.append(ROOT / ".ohos-sdk")
    for candidate in candidates:
        if (candidate / "bin" / "flutter").exists():
            return candidate.resolve()
    looked = ", ".join(str(c) for c in candidates)
    raise SystemExit(
        "OpenHarmony Flutter SDK not found. Run tool/setup_ohos_sdk.sh first "
        f"(looked at: {looked})"
    )


def display(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def patched(data: bytes, label: Path) -> tuple[bytes, bool]:
    if AFTER in data:
        return data, False
    if data.count(BEFORE) != 1:
        raise RuntimeError(f"Expected system UI mode handler was not found in {label}")
    return data.replace(BEFORE, AFTER, 1), True


def patch_file(path: Path) -> bool:
    data, changed = patched(path.read_bytes(), path)
    if changed:
        path.write_bytes(data)
        print(f"Patched {display(path)}")
    return changed


def patch_har(path: Path) -> bool:
    with tarfile.open(path, "r:gz") as source:
        member = source.getmember(HAR_CHANNEL)
        content = source.extractfile(member)
        if content is None:
            raise RuntimeError(f"Cannot read {HAR_CHANNEL} in {path}")
        _, changed = patched(content.read(), path)
        if not changed:
            return False

        with tempfile.NamedTemporaryFile(dir=path.parent, suffix=".har", delete=False) as temp:
            temp_path = Path(temp.name)
        try:
            with tarfile.open(temp_path, "w:gz") as target:
                for item in source:
                    item_content = source.extractfile(item) if item.isfile() else None
                    if item_content is None:
                        target.addfile(item)
                        continue
                    data = item_content.read()
                    if item.name == HAR_CHANNEL:
                        data, _ = patched(data, path)
                        item.size = len(data)
                    target.addfile(item, BytesIO(data))
            os.chmod(temp_path, path.stat().st_mode)
            os.replace(temp_path, path)
        finally:
            temp_path.unlink(missing_ok=True)
    print(f"Patched {display(path)}")
    return True


def main() -> int:
    sdk = resolve_sdk()
    patched_any = False

    source = sdk / "engine/src/flutter/shell/platform/ohos/flutter_embedding/flutter" / CHANNEL
    if not source.is_file():
        raise SystemExit(f"Flutter-OH engine source is missing: {source}")
    patched_any |= patch_file(source)

    for har in sorted((sdk / "bin/cache/artifacts/engine").glob("ohos-*/flutter.har")):
        patched_any |= patch_har(har)

    for installed in sorted(
        (ROOT / "ohos/oh_modules").glob(
            f".ohpm/@ohos+flutter_ohos@*/oh_modules/@ohos/flutter_ohos/{CHANNEL}"
        )
    ):
        patched_any |= patch_file(installed)

    return 2 if patched_any else 0


if __name__ == "__main__":
    sys.exit(main())
