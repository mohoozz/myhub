"""抓取源注册表（B 站 / YouTube / 抖音，新平台按同样接口扩展）。"""
from __future__ import annotations

from app import credentials
from app.config import get_settings
from app.sources.base import DiscoveredSource, RawItem, Source, SourceError
from app.sources.bilibili import BilibiliSource
from app.sources.douyin import DouyinSource
from app.sources.youtube import YoutubeSource

SUPPORTED = ("bilibili", "youtube", "douyin")


def build_source(platform: str) -> Source:
    settings = get_settings()
    if platform == "bilibili":
        return BilibiliSource(
            cookie=credentials.cookie_header("bilibili"),
            interval=settings.request_interval,
            max_pages=settings.max_pages,
        )
    if platform == "youtube":
        return YoutubeSource(
            channels=settings.youtube_channels,
            interval=settings.request_interval,
            proxy=settings.youtube_proxy or settings.proxy,
            cookiefile=credentials.cookiefile("youtube"),
            use_subscriptions=settings.youtube_subscriptions,
        )
    if platform == "douyin":
        return DouyinSource(
            headless=settings.douyin_headless,
            interval=settings.request_interval,
            proxy=settings.douyin_proxy or settings.proxy,
            profile_dir=settings.douyin_profile,
            max_scrolls=settings.douyin_max_scrolls,
            channel=settings.browser_channel,
            profile_name=settings.douyin_profile_name,
            reuse_existing=settings.douyin_reuse_browser,
        )
    raise SourceError(f"暂不支持的平台：{platform}（已支持：{', '.join(SUPPORTED)}）")


__all__ = ["Source", "RawItem", "DiscoveredSource", "SourceError", "build_source", "SUPPORTED"]
