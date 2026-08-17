#!/usr/bin/env python3
"""生成 Jive 应用图标（夜幕影院主题：深底 + 琥珀播放三角）。

用法：python3 tool/generate_app_icon.py
输出：
  - ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png（按 Contents.json 尺寸）
  - android/app/src/main/res/mipmap-*/ic_launcher.png
  - tool/app_icon_master.png（1024 母图，供预览/再加工）
"""

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent

# 主题色（与 lib/app/theme.dart AppColors 对齐）
BACKGROUND = (11, 13, 16)  # #0B0D10
ACCENT = (242, 184, 75)  # #F2B84B

MASTER = 1024
SS = 4  # 超采样抗锯齿

IOS_ICONS = [
    ("Icon-App-20x20@2x.png", 40),
    ("Icon-App-20x20@3x.png", 60),
    ("Icon-App-29x29@1x.png", 29),
    ("Icon-App-29x29@2x.png", 58),
    ("Icon-App-29x29@3x.png", 87),
    ("Icon-App-40x40@2x.png", 80),
    ("Icon-App-40x40@3x.png", 120),
    ("Icon-App-60x60@2x.png", 120),
    ("Icon-App-60x60@3x.png", 180),
    ("Icon-App-20x20@1x.png", 20),
    ("Icon-App-20x20@2x.png", 40),
    ("Icon-App-29x29@1x.png", 29),
    ("Icon-App-29x29@2x.png", 58),
    ("Icon-App-40x40@1x.png", 40),
    ("Icon-App-40x40@2x.png", 80),
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


def _rounded_triangle(draw: ImageDraw.ImageDraw, vertices, radius, color):
    """画圆角实心三角形：内切六边形 + 各角圆弧圆盘。"""
    pts = []
    n = len(vertices)
    for i in range(n):
        vx, vy = vertices[i]
        px, py = vertices[(i - 1) % n]
        nx, ny = vertices[(i + 1) % n]
        # 两条邻边的单位向量
        u1 = (px - vx, py - vy)
        u2 = (nx - vx, ny - vy)
        l1 = math.hypot(*u1)
        l2 = math.hypot(*u2)
        u1 = (u1[0] / l1, u1[1] / l1)
        u2 = (u2[0] / l2, u2[1] / l2)
        # 夹角
        cos_a = max(-1.0, min(1.0, u1[0] * u2[0] + u1[1] * u2[1]))
        angle = math.acos(cos_a)
        d = radius / math.tan(angle / 2)
        cx = vx + (u1[0] + u2[0])
        cy = vy + (u1[1] + u2[1])
        cl = math.hypot(cx - vx, cy - vy)
        center = (
            vx + (cx - vx) / cl * (radius / math.sin(angle / 2)),
            vy + (cy - vy) / cl * (radius / math.sin(angle / 2)),
        )
        t1 = (vx + u1[0] * d, vy + u1[1] * d)
        t2 = (vx + u2[0] * d, vy + u2[1] * d)
        pts.append((t1, t2, center))
    # 中心六边形（每个角的两个切点）
    hexagon = []
    for t1, t2, _ in pts:
        hexagon.extend([t1, t2])
    # 重排：按顶点顺序 t2(Prev) -> t1(Next) 即环绕顺序，上面 extend 的顺序已环绕
    draw.polygon(hexagon, fill=color)
    for _, _, (cx, cy) in pts:
        draw.ellipse(
            [cx - radius, cy - radius, cx + radius, cy + radius], fill=color
        )


def render_master(size: int = MASTER) -> Image.Image:
    s = size * SS
    img = Image.new("RGB", (s, s), BACKGROUND)

    # 琥珀色柔光晕（极低透明度，只做氛围）
    glow = Image.new("L", (s, s), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([s * 0.18, s * 0.14, s * 0.82, s * 0.78], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(s * 0.12))
    amber_layer = Image.new("RGB", (s, s), ACCENT)
    img = Image.composite(
        amber_layer, img, glow.point(lambda v: int(v * 0.28))
    )

    draw = ImageDraw.Draw(img)
    # 播放三角：视觉重心略偏右上，指向右
    cx, cy = s * 0.54, s * 0.5
    w, h = s * 0.40, s * 0.46
    vertices = [
        (cx - w / 2, cy - h / 2),  # 左上
        (cx - w / 2, cy + h / 2),  # 左下
        (cx + w / 2, cy),  # 右尖
    ]
    _rounded_triangle(draw, vertices, radius=s * 0.075, color=ACCENT)

    return img.resize((size, size), Image.LANCZOS)


def main() -> None:
    master = render_master()
    master_path = ROOT / "tool" / "app_icon_master.png"
    master.save(master_path)
    print(f"master -> {master_path}")

    ios_dir = ROOT / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    for name, px in IOS_ICONS:
        icon = master.resize((px, px), Image.LANCZOS)
        icon.save(ios_dir / name)
    print(f"ios -> {ios_dir} ({len(IOS_ICONS)} files)")

    res_dir = ROOT / "android/app/src/main/res"
    for folder, px in ANDROID_ICONS.items():
        icon = master.resize((px, px), Image.LANCZOS)
        icon.save(res_dir / folder / "ic_launcher.png")
    print(f"android -> {res_dir}/mipmap-* ({len(ANDROID_ICONS)} files)")


if __name__ == "__main__":
    main()
