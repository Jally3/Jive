#!/usr/bin/env python3
"""从母图生成 Jive 应用图标。

用法：python3 tool/generate_app_icon.py
输入：tool/app_icon_source.png
输出：
  - ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png（按 Contents.json 尺寸）
  - android/app/src/main/res/mipmap-*/ic_launcher.png
  - tool/app_icon_master.png（1024 方图，供预览/再加工）
"""

from collections import deque
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "tool" / "app_icon_source.png"
MASTER = 1024
# 透明圆角铺底，取自 logo 夜幕底色
FALLBACK_BACKGROUND = (19, 25, 48)

IOS_ICONS = [
    ("Icon-App-20x20@1x.png", 20),
    ("Icon-App-20x20@2x.png", 40),
    ("Icon-App-20x20@3x.png", 60),
    ("Icon-App-29x29@1x.png", 29),
    ("Icon-App-29x29@2x.png", 58),
    ("Icon-App-29x29@3x.png", 87),
    ("Icon-App-40x40@1x.png", 40),
    ("Icon-App-40x40@2x.png", 80),
    ("Icon-App-40x40@3x.png", 120),
    ("Icon-App-60x60@2x.png", 120),
    ("Icon-App-60x60@3x.png", 180),
    ("Icon-App-76x76@1x.png", 76),
    ("Icon-App-76x76@2x.png", 152),
    ("Icon-App-83.5x83.5@2x.png", 167),
    ("Icon-App-1024x1024@1x.png", 1024),
]

ANDROID_ICONS = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}


def _sample_background(rgba: Image.Image) -> tuple[int, int, int]:
    """取画面内侧不透明暗色作为铺底，避免透明圆角在系统裁切后露白。"""
    px = rgba.load()
    w, h = rgba.size
    candidates = []
    for x, y in (
        (max(1, w // 12), max(1, h // 12)),
        (w - 1 - max(1, w // 12), max(1, h // 12)),
        (max(1, w // 12), h - 1 - max(1, h // 12)),
        (w - 1 - max(1, w // 12), h - 1 - max(1, h // 12)),
        (w // 2, max(1, h // 16)),
        (w // 2, h - 1 - max(1, h // 16)),
    ):
        r, g, b, a = px[x, y]
        if a >= 250 and 40 <= r + g + b < 140:
            candidates.append((r, g, b))
    return candidates[0] if candidates else FALLBACK_BACKGROUND


def _fill_outer_frame(rgba: Image.Image, background: tuple[int, int, int]) -> Image.Image:
    """把预烘焙圆角外的透明/纯黑像素铺成底色，让系统自己做圆角裁切。"""
    img = rgba.copy()
    px = img.load()
    w, h = img.size
    fill = (*background, 255)
    seen = [[False] * w for _ in range(h)]
    queue = deque()

    def is_outer(x: int, y: int) -> bool:
        r, g, b, a = px[x, y]
        return a < 250 or r + g + b < 24

    for x, y in (
        (0, 0),
        (w - 1, 0),
        (0, h - 1),
        (w - 1, h - 1),
        (w // 2, 0),
        (w // 2, h - 1),
        (0, h // 2),
        (w - 1, h // 2),
    ):
        if is_outer(x, y):
            queue.append((x, y))
            seen[y][x] = True

    while queue:
        x, y = queue.popleft()
        px[x, y] = fill
        for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
            if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and is_outer(nx, ny):
                seen[ny][nx] = True
                queue.append((nx, ny))
    return img


def render_master(size: int = MASTER) -> Image.Image:
    src = Image.open(SOURCE).convert("RGBA")
    background = _sample_background(src)
    filled = _fill_outer_frame(src, background)
    rgb = Image.alpha_composite(
        Image.new("RGBA", filled.size, (*background, 255)),
        filled,
    ).convert("RGB")
    w, h = rgb.size
    side = max(w, h)
    square = Image.new("RGB", (side, side), background)
    square.paste(rgb, ((side - w) // 2, (side - h) // 2))
    if side == size:
        return square
    return square.resize((size, size), Image.Resampling.LANCZOS)


def main() -> None:
    if not SOURCE.is_file():
        raise SystemExit(f"missing source icon: {SOURCE}")

    master = render_master()
    master_path = ROOT / "tool" / "app_icon_master.png"
    master.save(master_path)
    print(f"master -> {master_path}")

    ios_dir = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for name, px in IOS_ICONS:
        master.resize((px, px), Image.Resampling.LANCZOS).save(ios_dir / name)
    print(f"ios -> {ios_dir} ({len(IOS_ICONS)} files)")

    res_dir = ROOT / "android/app/src/main/res"
    for folder, px in ANDROID_ICONS.items():
        master.resize((px, px), Image.Resampling.LANCZOS).save(
            res_dir / folder / "ic_launcher.png"
        )
    print(f"android -> {res_dir}/mipmap-* ({len(ANDROID_ICONS)} files)")


if __name__ == "__main__":
    main()
