#!/usr/bin/env python3
"""Patch the Flutter-OH system UI mode reply in source and cached HARs."""

from io import BytesIO
from pathlib import Path
import os
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SDK = ROOT / ".ohos-sdk"
CHANNEL = Path("src/main/ets/embedding/engine/systemchannels/PlatformChannel.ets")
HAR_CHANNEL = f"package/{CHANNEL}"
BEFORE = b"this.platform.platformMessageHandler.showSystemUiMode(mode);\n          } catch (err) {"
AFTER = b"this.platform.platformMessageHandler.showSystemUiMode(mode);\n            result.success(null);\n          } catch (err) {"


def patched(data: bytes, label: Path) -> tuple[bytes, bool]:
    if AFTER in data:
        return data, False
    if data.count(BEFORE) != 1:
        raise RuntimeError(f"Expected system UI mode handler was not found in {label}")
    return data.replace(BEFORE, AFTER, 1), True


def patch_file(path: Path) -> None:
    data, changed = patched(path.read_bytes(), path)
    if changed:
        path.write_bytes(data)
        print(f"Patched {path.relative_to(ROOT)}")


def patch_har(path: Path) -> None:
    with tarfile.open(path, "r:gz") as source:
        member = source.getmember(HAR_CHANNEL)
        content = source.extractfile(member)
        if content is None:
            raise RuntimeError(f"Cannot read {HAR_CHANNEL} in {path}")
        _, changed = patched(content.read(), path)
        if not changed:
            return

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
    print(f"Patched {path.relative_to(ROOT)}")


source = SDK / "engine/src/flutter/shell/platform/ohos/flutter_embedding/flutter" / CHANNEL
if not source.is_file():
    raise SystemExit(f"Flutter-OH engine source is missing: {source}")
patch_file(source)

for har in sorted((SDK / "bin/cache/artifacts/engine").glob("ohos-*/flutter.har")):
    patch_har(har)

for installed in sorted((ROOT / "ohos/oh_modules").glob(f".ohpm/@ohos+flutter_ohos@*/oh_modules/@ohos/flutter_ohos/{CHANNEL}")):
    patch_file(installed)
