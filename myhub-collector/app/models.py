"""表结构：关注快照 / 内容 / 下载任务 / 运行日志。"""
from __future__ import annotations

from datetime import datetime

from pydantic import NaiveDatetime
from sqlalchemy import UniqueConstraint
from sqlmodel import Field, SQLModel

# 说明：sqlmodel 新版会把裸 datetime 映射成“必须带时区”的列，而本项目统一用本地
# 朴素时间（与日报的按天过滤一致），因此显式标注 NaiveDatetime。
# 注意：NaiveDatetime 的映射支持从 sqlmodel 0.0.49 才开始有，旧版会直接抛
# ValueError: NaiveDatetime has no matching SQLAlchemy type。


class Subscription(SQLModel, table=True):
    """关注列表快照：platform + target 唯一（B站为 mid）。"""

    __tablename__ = "subscriptions"
    __table_args__ = (UniqueConstraint("platform", "target", name="uk_sub_platform_target"),)

    id: int | None = Field(default=None, primary_key=True)
    platform: str = Field(index=True, max_length=32)
    target: str = Field(max_length=128)
    name: str = Field(max_length=128)
    enabled: bool = Field(default=True)
    last_synced_at: NaiveDatetime | None = None
    created_at: NaiveDatetime = Field(default_factory=datetime.now)


class Content(SQLModel, table=True):
    """抓到的单条内容：platform + content_id 唯一（去重键）。"""

    __tablename__ = "contents"
    __table_args__ = (UniqueConstraint("platform", "content_id", name="uk_content_platform_cid"),)

    id: int | None = Field(default=None, primary_key=True)
    platform: str = Field(index=True, max_length=32)
    content_id: str = Field(max_length=128)
    dynamic_id: str = Field(default="", max_length=128)
    author: str = Field(default="", max_length=128)
    author_id: str = Field(default="", max_length=128)
    title: str = Field(default="", max_length=512)
    media_type: str = Field(default="video", index=True, max_length=16)  # video/image/text
    url: str = Field(default="", max_length=1024)
    cover: str = Field(default="", max_length=1024)
    media_url: str = Field(default="", max_length=1024)  # 可直接下载的媒体直链（抖音 mp4）
    description: str = Field(default="")
    duration: str = Field(default="", max_length=32)
    images_json: str = Field(default="")  # 图文动态的图片 URL 列表（JSON 字符串）
    emotes_json: str = Field(default="")  # 正文表情：[名称] -> 图标 URL（JSON 字符串）
    published_at: NaiveDatetime = Field(index=True)
    like_count: int = Field(default=0)
    comment_count: int = Field(default=0)
    created_at: NaiveDatetime = Field(default_factory=datetime.now)


class Download(SQLModel, table=True):
    """下载任务：一条内容一行，记录本地路径与状态。"""

    __tablename__ = "downloads"
    __table_args__ = (UniqueConstraint("platform", "content_id", name="uk_dl_platform_cid"),)

    id: int | None = Field(default=None, primary_key=True)
    platform: str = Field(index=True, max_length=32)
    content_id: str = Field(max_length=128)
    status: str = Field(default="pending", index=True, max_length=16)  # pending/done/failed/skipped
    path: str = Field(default="", max_length=1024)
    size: int = Field(default=0)
    error: str = Field(default="")
    attempts: int = Field(default=0)
    started_at: NaiveDatetime | None = None
    finished_at: NaiveDatetime | None = None


class RunLog(SQLModel, table=True):
    """一次采集运行的汇总日志。"""

    __tablename__ = "run_logs"

    id: int | None = Field(default=None, primary_key=True)
    run_date: str = Field(index=True, max_length=16)  # 采集的目标日期 YYYY-MM-DD
    platform: str = Field(max_length=32)
    status: str = Field(default="success", max_length=16)
    authors: int = Field(default=0)
    new_items: int = Field(default=0)
    downloaded: int = Field(default=0)
    failed: int = Field(default=0)
    skipped: int = Field(default=0)
    message: str = Field(default="")
    started_at: NaiveDatetime
    finished_at: NaiveDatetime | None = None
