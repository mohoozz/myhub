"""抓取源注册表（B 站 / B 站稍后观看 / B 站收藏夹 / YouTube / 抖音，新平台按同样接口扩展）。"""
from __future__ import annotations

from app import credentials
from app.config import get_settings
from app.sources.base import DiscoveredSource, RawItem, Source, SourceError
from app.sources.bilibili import BilibiliSource
from app.sources.bilibili_lists import BilibiliFavoriteSource, BilibiliWatchLaterSource
from app.sources.douyin import DouyinSource
from app.sources.youtube import YoutubeSource

SUPPORTED = ("bilibili", "bili_watchlater", "bili_favorite", "youtube", "douyin")

# 列表型平台：不按日期抓，列表里有什么抓什么，下载成功后从列表里取消
LIST_PLATFORMS = ("bili_watchlater", "bili_favorite")

# 这些平台共用 B 站登录态 / 下载器参数（Cookie、yt-dlp 行为都按 bilibili 处理）
_PLATFORM_ALIAS = {"bili_watchlater": "bilibili", "bili_favorite": "bilibili"}


def is_list_platform(platform: str) -> bool:
    return platform in LIST_PLATFORMS


def download_platform(platform: str) -> str:
    """下载器 / 登录态层面实际要用的平台标识（列表型归到 bilibili）。"""
    return _PLATFORM_ALIAS.get(platform, platform)


def build_source(platform: str) -> Source:
    settings = get_settings()
    if platform in ("bilibili", *_PLATFORM_ALIAS):
        cookie = credentials.cookie_header("bilibili")
        if platform == "bili_watchlater":
            return BilibiliWatchLaterSource(
                cookie=cookie,
                interval=settings.request_interval,
                max_pages=settings.max_pages,
            )
        if platform == "bili_favorite":
            return BilibiliFavoriteSource(
                cookie=cookie,
                interval=settings.request_interval,
                max_pages=settings.max_pages,
            )
        return BilibiliSource(
            cookie=cookie,
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


__all__ = [
    "Source", "RawItem", "DiscoveredSource", "SourceError", "build_source",
    "SUPPORTED", "LIST_PLATFORMS", "is_list_platform", "download_platform",
]
