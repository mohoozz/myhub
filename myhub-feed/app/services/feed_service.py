"""抓取编排：首次/增量、去重入库、日志记录。"""
import logging
import time
from datetime import datetime

from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlmodel import Session, select

from app.config import get_settings
from app.fetchers import get_fetcher
from app.fetchers.base import Fetcher, RawItem
from app.models import FeedFetchLog, FeedItem, FeedSubscription

logger = logging.getLogger(__name__)


def _exists(session: Session, platform: str, content_id: str) -> bool:
    stmt = select(FeedItem.id).where(
        FeedItem.platform == platform, FeedItem.content_id == content_id
    )
    return session.exec(stmt).first() is not None


def _save_items(session: Session, platform: str, author: str, items: list[RawItem]) -> int:
    """批量入库，(platform, content_id) 冲突跳过，返回实际新增数。"""
    added = 0
    for it in items:
        stmt = sqlite_insert(FeedItem).values(
            platform=platform, content_id=it.content_id, media_type=it.media_type,
            author=author or it.author, title=it.title, cover=it.cover, url=it.url,
            description=it.description, published_at=it.published_at,
        ).on_conflict_do_nothing(index_elements=["platform", "content_id"])
        added += session.exec(stmt).rowcount
    return added


def fetch_subscription(session: Session, sub: FeedSubscription) -> int:
    """抓取单个订阅源：LastFetchedAt 为空=首次拉最近 N 条，否则增量到上次位置。"""
    settings = get_settings()
    started = datetime.now()
    fetcher: Fetcher = get_fetcher(sub.platform)
    status, msg, added = "success", "", 0

    try:
        if sub.last_fetched_at is None:
            items = fetcher.fetch_first(sub.target, settings.first_fetch_limit)
        else:
            items = fetcher.fetch_incremental(
                sub.target, lambda cid: _exists(session, sub.platform, cid)
            )
        added = _save_items(session, sub.platform, sub.name, items)
        if items:
            sub.last_fetched_at = max(it.published_at for it in items)
            session.add(sub)
    except Exception as e:  # noqa: BLE001 单个订阅源失败不影响其他
        status, msg = "failed", str(e)
        logger.warning("抓取失败 [%s] %s: %s", sub.platform, sub.name, e)

    session.add(FeedFetchLog(
        subscription_id=sub.id, status=status, new_items=added,
        message=msg, started_at=started, finished_at=datetime.now(),
    ))
    session.commit()
    return added


def fetch_all(session: Session, platform: str | None = None) -> dict:
    """抓取所有启用的订阅源，返回 {processed, added, failed}。"""
    settings = get_settings()
    stmt = select(FeedSubscription).where(FeedSubscription.enabled == True)  # noqa: E712
    if platform:
        stmt = stmt.where(FeedSubscription.platform == platform)
    subs = session.exec(stmt).all()

    added, failed = 0, 0
    for i, sub in enumerate(subs):
        try:
            n = fetch_subscription(session, sub)
            added += n
            logger.info("[%d/%d] %s: 新增 %d 条", i + 1, len(subs), sub.name, n)
        except Exception as e:  # noqa: BLE001
            failed += 1
            logger.warning("[%d/%d] %s: 失败 %s", i + 1, len(subs), sub.name, e)
        time.sleep(settings.fetch_interval)
    return {"processed": len(subs), "added": added, "failed": failed}


def upsert_subscription(session: Session, platform: str, target: str, name: str) -> FeedSubscription:
    """按 (platform, target) 查找，不存在则创建；改名时同步名称。"""
    stmt = select(FeedSubscription).where(
        FeedSubscription.platform == platform, FeedSubscription.target == target
    )
    sub = session.exec(stmt).first()
    if sub is None:
        sub = FeedSubscription(platform=platform, target=target, name=name)
        session.add(sub)
        session.commit()
        session.refresh(sub)
    elif sub.name != name:
        sub.name = name
        session.add(sub)
        session.commit()
    return sub


def sync_sources(session: Session, platform: str) -> dict:
    """把账号的关注/订阅列表同步为订阅源（B站关注、YouTube 订阅频道）。"""
    fetcher = get_fetcher(platform)
    sources = fetcher.discover_sources()
    if not sources:
        return {"discovered": 0, "message": "未获取到数据（该平台可能不支持自动发现）"}
    for s in sources:
        upsert_subscription(session, platform, s.target, s.name)
    return {"discovered": len(sources)}
