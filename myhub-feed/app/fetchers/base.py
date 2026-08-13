"""抓取器抽象：每个平台实现一个 Fetcher，输出统一的 RawItem。"""
from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime
from typing import Callable


@dataclass
class RawItem:
    """平台原始条目，与 FeedItem 的映射由 service 层完成。"""

    content_id: str
    title: str
    author: str
    url: str
    published_at: datetime
    cover: str = ""
    description: str = ""
    media_type: str = "video"


@dataclass
class DiscoveredSource:
    """账号关联发现的订阅源（如 B站关注列表）。"""

    name: str
    target: str


class Fetcher(ABC):
    """平台抓取器接口。"""

    platform: str = ""

    @abstractmethod
    def fetch_first(self, target: str, limit: int) -> list[RawItem]:
        """首次抓取：拉取该订阅源最近的 limit 条。"""

    @abstractmethod
    def fetch_incremental(self, target: str, exists: Callable[[str], bool]) -> list[RawItem]:
        """增量抓取：按时间倒序翻页，遇到 exists() 为真的条目即停止。"""

    def discover_sources(self) -> list[DiscoveredSource]:
        """可选：自动发现订阅源（如 B站关注列表）。默认不支持。"""
        return []
