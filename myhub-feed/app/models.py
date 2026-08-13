"""数据模型：与 myhub-server internal/model/feed.go 的表结构保持一致。"""
from datetime import datetime

from sqlalchemy import UniqueConstraint
from sqlmodel import Field, SQLModel


class FeedSubscription(SQLModel, table=True):
    """订阅源：platform + target 唯一。"""

    __tablename__ = "feed_subscriptions"
    __table_args__ = (UniqueConstraint("platform", "target", name="uk_sub_platform_target"),)

    id: int | None = Field(default=None, primary_key=True)
    platform: str = Field(index=True, max_length=32)          # bilibili / youtube / douyin
    name: str = Field(max_length=128)                          # 订阅源显示名（如 UP 主名）
    target: str = Field(max_length=512)                        # 抓取目标（UID / Channel ID / 主页 URL）
    cron_expr: str = Field(default="0 */6 * * *", max_length=64)
    enabled: bool = Field(default=True)
    last_fetched_at: datetime | None = None                    # 上次抓取到的最新发布时间，空 = 未抓过
    created_at: datetime = Field(default_factory=datetime.now)


class FeedItem(SQLModel, table=True):
    """动态条目：platform + content_id 唯一（去重键）。"""

    __tablename__ = "feed_items"
    __table_args__ = (UniqueConstraint("platform", "content_id", name="uk_feed_platform_content"),)

    id: int | None = Field(default=None, primary_key=True)
    platform: str = Field(index=True, max_length=32)
    content_id: str = Field(max_length=128)                    # 平台内唯一 ID（BV号 / 视频ID）
    media_type: str = Field(default="video", index=True, max_length=32)  # video / audio / article
    author: str = Field(default="", max_length=128)
    title: str = Field(max_length=512)
    cover: str = Field(default="", max_length=1024)
    url: str = Field(default="", max_length=1024)              # 原站链接
    description: str = Field(default="")
    published_at: datetime = Field(index=True)                 # 平台发布时间
    created_at: datetime = Field(default_factory=datetime.now)


class FeedFetchLog(SQLModel, table=True):
    """抓取任务日志。"""

    __tablename__ = "feed_fetch_logs"

    id: int | None = Field(default=None, primary_key=True)
    subscription_id: int = Field(index=True)
    status: str = Field(max_length=16)                         # success / failed
    new_items: int = Field(default=0)
    message: str = Field(default="")
    started_at: datetime
    finished_at: datetime | None = None
