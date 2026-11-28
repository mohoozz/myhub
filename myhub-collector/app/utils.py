"""通用小工具：文件名清理、统一命名、大小/时长格式化。"""
from __future__ import annotations

import re

_ILLEGAL = re.compile(r'[\\/:*?"<>|%\x00-\x1f]')

# 超时长跳过的统一前缀：pipeline 写进 downloads.error、下载器返回错误、
# 门户的「重试超时长」按它筛选，避免和「已关闭图片下载」的 skipped 混在一起。
DURATION_SKIP_PREFIX = "超时长"

# 平台标识 → 文件名里的平台前缀
PLATFORM_LABELS = {
    "bilibili": "Bili",
    "bili_watchlater": "BiliWL",
    "bili_favorite": "BiliFav",
    "douyin": "DouYin",
    "youtube": "Youtube",
}


def platform_label(platform: str) -> str:
    return PLATFORM_LABELS.get(platform, platform)


def safe_name(text: str, limit: int = 60) -> str:
    """把任意标题清成安全的目录/文件名（Windows 非法字符 + 结尾点号）。"""
    cleaned = _ILLEGAL.sub("_", str(text or "")).strip().rstrip(" .")
    return (cleaned[:limit].rstrip(" .")) or "_"


def build_stem(
    platform: str,
    author: str,
    title: str,
    ident: str,
    part: str | int | None = None,
) -> str:
    """统一文件名：平台-作者-文件名称-发布号-[Pn]（单 P 时省略末段 [Pn]）。"""
    pieces = [
        platform_label(platform),
        safe_name(author, 40),
        safe_name(title, 60),
        safe_name(str(ident), 60),
    ]
    if part:
        pieces.append(f"[P{part}]")
    return "-".join(pieces)


def fmt_duration(sec: float | int | None) -> str:
    total = int(sec or 0)
    h, m, s = total // 3600, total % 3600 // 60, total % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def parse_duration(text: str | int | float | None) -> int | None:
    """把 "m:ss" / "h:mm:ss" / 超一小时的 "90:00" / 纯秒数解析成秒。

    平台给的时长格式并不统一：B 站动态是 "23:39"（多 P 为总时长），抖音是
    "m:ss"（超过一小时会变成 "90:00"），解析失败或为 0 时返回 None 表示「时长未知」。
    """
    if isinstance(text, (int, float)):
        return int(text) if text > 0 else None
    raw = str(text or "").strip()
    if not raw:
        return None
    parts = raw.split(":")
    if not 1 <= len(parts) <= 3:
        return None
    try:
        nums = [int(p) for p in parts]
    except ValueError:
        return None
    if any(n < 0 for n in nums):
        return None
    total = 0
    for n in nums:
        total = total * 60 + n
    return total or None


def human_size(num: int | float | None) -> str:
    size = float(num or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.0f}{unit}" if unit == "B" else f"{size:.1f}{unit}"
        size /= 1024
    return f"{size:.1f}TB"


def human_count(num: int | None) -> str:
    n = int(num or 0)
    if n >= 100_000_000:
        return f"{n / 100_000_000:.1f}亿"
    if n >= 10_000:
        return f"{n / 10_000:.1f}万"
    return str(n)
