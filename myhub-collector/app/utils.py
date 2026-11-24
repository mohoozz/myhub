"""通用小工具：文件名清理、大小/时长格式化。"""
from __future__ import annotations

import re

_ILLEGAL = re.compile(r'[\\/:*?"<>|%\x00-\x1f]')


def safe_name(text: str, limit: int = 60) -> str:
    """把任意标题清成安全的目录/文件名（Windows 非法字符 + 结尾点号）。"""
    cleaned = _ILLEGAL.sub("_", str(text or "")).strip().rstrip(" .")
    return (cleaned[:limit].rstrip(" .")) or "_"


def fmt_duration(sec: float | int | None) -> str:
    total = int(sec or 0)
    h, m, s = total // 3600, total % 3600 // 60, total % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


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
