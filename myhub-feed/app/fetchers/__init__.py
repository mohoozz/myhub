"""平台抓取器注册表。"""
from app.config import get_settings
from app.fetchers.base import Fetcher
from app.fetchers.bilibili import BilibiliFetcher
from app.fetchers.douyin import DouyinFetcher
from app.fetchers.youtube import YouTubeFetcher


def get_fetcher(platform: str) -> Fetcher:
    """按平台构造抓取器（每次新建，避免 cookie 更新后残留旧状态）。"""
    match platform:
        case "bilibili":
            return BilibiliFetcher(get_settings().bili_cookie)
        case "youtube":
            return YouTubeFetcher(get_settings().youtube_cookie)
        case "douyin":
            return DouyinFetcher(get_settings().douyin_cookie)
        case _:
            raise ValueError(f"不支持的平台: {platform}")


__all__ = ["Fetcher", "get_fetcher"]
