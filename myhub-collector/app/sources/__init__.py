"""抓取源注册表（当前仅 B 站，YouTube / 抖音按同样接口扩展）。"""
from __future__ import annotations

from app.config import get_settings
from app.cookies import bili_cookie_header
from app.sources.base import DiscoveredSource, RawItem, Source, SourceError
from app.sources.bilibili import BilibiliSource

SUPPORTED = ("bilibili",)


def build_source(platform: str) -> Source:
    settings = get_settings()
    if platform == "bilibili":
        return BilibiliSource(
            cookie=bili_cookie_header(),
            interval=settings.request_interval,
            max_pages=settings.max_pages,
        )
    raise SourceError(f"暂不支持的平台：{platform}（已支持：{', '.join(SUPPORTED)}）")


__all__ = ["Source", "RawItem", "DiscoveredSource", "SourceError", "build_source", "SUPPORTED"]
