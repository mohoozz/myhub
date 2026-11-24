"""抓取源抽象：平台实现统一输出 RawItem。"""
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime


@dataclass
class RawItem:
    """平台原始条目，入库映射由 pipeline 完成。"""

    content_id: str
    title: str
    author: str
    author_id: str
    url: str
    published_at: datetime
    media_type: str = "video"          # video / image / text
    cover: str = ""
    description: str = ""
    duration: str = ""
    images: list[str] = field(default_factory=list)
    like_count: int = 0
    comment_count: int = 0


@dataclass
class DiscoveredSource:
    """账号关联发现的关注源。"""

    name: str
    target: str


class SourceError(RuntimeError):
    """抓取失败。"""


class Source(ABC):
    """平台抓取源接口。"""

    platform: str = ""

    @abstractmethod
    def discover_sources(self) -> list[DiscoveredSource]:
        """拉取当前账号的关注列表。"""

    @abstractmethod
    def fetch_range(self, target: str, since: datetime, until: datetime) -> list[RawItem]:
        """抓取 [since, until) 区间内该作者的内容（按时间倒序翻页，遇到更早的即停止）。"""

    def close(self) -> None:
        """释放网络资源。"""
