#!/usr/bin/env python3
"""由满铺原图生成带底色 / 内缩 / 圆角的 AppIcon.png。

用法示例（方案 F：浅蓝底 + 正圆插图，9% 留白）：
    python Tools/make_app_icon.py --bg "#EEF4FB" --pad 0.09 --radius 0.5

参数说明：
    --source  原图（默认 AppIcon-source.png，缺失时回退 AppIcon.png）
    --out     输出文件（默认 AppIcon.appiconset/AppIcon.png）
    --bg      底色，纯色不透明（App Store 不接受 alpha，脚本最后强制 RGB）
    --pad     插图四周留白，占图标边长的比例（0.13 = 每边留 13%）
    --radius  插图自身圆角，占插图边长的比例（0.5 = 正圆，0 = 直角）
    --size    输出边长，默认 1024
"""

import argparse
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SET = ROOT / "MyHub/Resources/Assets.xcassets/AppIcon.appiconset"
# 原图备份放在 Tools/（不进 app target，避免资源目录出现未引用的 PNG 警告）
BACKUP = ROOT / "Tools/AppIcon-source.png"


def build(source: Path, out: Path, bg: str, pad: float, radius: float, size: int) -> None:
    art = Image.open(source).convert("RGB")
    inner = max(1, round(size * (1 - pad * 2)))
    art = art.resize((inner, inner), Image.LANCZOS)

    if radius > 0:
        mask = Image.new("L", (inner, inner), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            (0, 0, inner - 1, inner - 1), radius=round(inner * radius), fill=255
        )
        art.putalpha(mask)

    canvas = Image.new("RGB", (size, size), bg)
    if radius > 0:
        canvas.paste(art, (round(size * pad), round(size * pad)), art)
    else:
        canvas.paste(art, (round(size * pad), round(size * pad)))

    out.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(out, "PNG", optimize=True)
    print(f"{out}  bg={bg} pad={pad:.0%} radius={radius:.0%} size={size}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--source", type=Path)
    p.add_argument("--out", type=Path)
    p.add_argument("--bg", default="#FFFFFF")
    p.add_argument("--pad", type=float, default=0.13)
    p.add_argument("--radius", type=float, default=0.18)
    p.add_argument("--size", type=int, default=1024)
    a = p.parse_args()

    source = a.source or (BACKUP if BACKUP.exists() else DEFAULT_SET / "AppIcon.png")
    out = a.out or (DEFAULT_SET / "AppIcon.png")

    build(source, out, a.bg, a.pad, a.radius, a.size)


if __name__ == "__main__":
    main()
