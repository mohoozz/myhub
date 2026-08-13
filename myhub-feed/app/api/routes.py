"""HTTP API：供 myhub-server 及后续前端调用。

接口一览：
  GET  /health                                  健康检查
  GET  /api/items?platform=&since_id=&limit=    动态条目增量同步（server 侧主接口）
  GET  /api/subscriptions                       订阅源列表
  POST /api/subscriptions                       手动添加订阅源
  POST /api/subscriptions/sync?platform=        同步账号关注/订阅列表为订阅源
  POST /api/fetch?platform=&subscription_id=    触发抓取（全部 / 单平台 / 单个）
  GET  /api/logs?limit=                         抓取日志
"""
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlmodel import Session, select

from app.database import get_session
from app.models import FeedFetchLog, FeedItem, FeedSubscription
from app.services import feed_service

router = APIRouter()


@router.get("/health")
def health():
    return {"status": "ok", "time": datetime.now().isoformat()}


# ---------- 动态条目 ----------

@router.get("/api/items")
def list_items(
    platform: str | None = None,
    since_id: int = 0,
    limit: int = 100,
    session: Session = Depends(get_session),
):
    """增量同步接口：返回 id > since_id 的条目（id 升序），server 记录最大 id 作为游标。"""
    limit = min(max(limit, 1), 500)
    stmt = select(FeedItem).where(FeedItem.id > since_id).order_by(FeedItem.id).limit(limit)
    if platform:
        stmt = stmt.where(FeedItem.platform == platform)
    items = session.exec(stmt).all()
    return {"items": items, "count": len(items)}


# ---------- 订阅源 ----------

class SubscriptionCreate(BaseModel):
    platform: str = Field(pattern="^(bilibili|youtube|douyin)$")
    target: str
    name: str = ""


@router.get("/api/subscriptions")
def list_subscriptions(session: Session = Depends(get_session)):
    subs = session.exec(select(FeedSubscription).order_by(FeedSubscription.id)).all()
    return {"items": subs, "count": len(subs)}


@router.post("/api/subscriptions", status_code=201)
def create_subscription(body: SubscriptionCreate, session: Session = Depends(get_session)):
    sub = feed_service.upsert_subscription(
        session, body.platform, body.target, body.name or body.target
    )
    return sub


@router.post("/api/subscriptions/sync")
def sync_subscriptions(platform: str = "bilibili", session: Session = Depends(get_session)):
    """同步账号关注/订阅列表为订阅源（platform=bilibili|youtube）。"""
    try:
        return feed_service.sync_sources(session, platform)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=str(e)) from e


@router.delete("/api/subscriptions/{sub_id}")
def delete_subscription(
    sub_id: int,
    purge: bool = False,
    session: Session = Depends(get_session),
):
    """删除订阅源；purge=true 时连带删除其已抓取的内容和日志。"""
    from sqlmodel import delete as sa_delete

    sub = session.get(FeedSubscription, sub_id)
    if sub is None:
        raise HTTPException(status_code=404, detail="订阅源不存在")

    purged = 0
    if purge:
        # FeedItem 无订阅源外键，按 platform+author 匹配清理
        purged = session.exec(sa_delete(FeedItem).where(
            FeedItem.platform == sub.platform, FeedItem.author == sub.name
        )).rowcount
        session.exec(sa_delete(FeedFetchLog).where(FeedFetchLog.subscription_id == sub_id))
    session.delete(sub)
    session.commit()
    return {"deleted": sub_id, "purged_items": purged}


# ---------- 抓取 ----------

@router.post("/api/fetch")
def trigger_fetch(
    platform: str | None = None,
    subscription_id: int | None = None,
    session: Session = Depends(get_session),
):
    if subscription_id is not None:
        sub = session.get(FeedSubscription, subscription_id)
        if sub is None:
            raise HTTPException(status_code=404, detail="订阅源不存在")
        added = feed_service.fetch_subscription(session, sub)
        return {"processed": 1, "added": added, "failed": 0}
    try:
        return feed_service.fetch_all(session, platform)
    except Exception as e:  # noqa: BLE001
        raise HTTPException(status_code=502, detail=str(e)) from e


# ---------- 日志 ----------

@router.get("/api/logs")
def list_logs(limit: int = 50, session: Session = Depends(get_session)):
    limit = min(max(limit, 1), 200)
    logs = session.exec(
        select(FeedFetchLog).order_by(FeedFetchLog.id.desc()).limit(limit)
    ).all()
    return {"items": logs, "count": len(logs)}
