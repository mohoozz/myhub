"""采集编排：同步关注 → 抓取当日内容 → 下载 → 生成总结。"""
from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path

from sqlmodel import Session, select

from app.config import get_settings
from app.cookies import CookieError, bili_cookiefile
from app.downloader import download, download_images
from app.models import Content, Download, RunLog, Subscription
from app.sources import build_source
from app.sources.base import RawItem
from app.summarize import day_range, write_reports
from app.utils import safe_name

logger = logging.getLogger(__name__)


@dataclass
class RunResult:
    day: str
    platform: str
    authors: int = 0
    new_items: int = 0
    downloaded: int = 0
    failed: int = 0
    skipped: int = 0
    report: str = ""
    message: str = ""

    def as_dict(self) -> dict:
        return {
            "day": self.day, "platform": self.platform, "authors": self.authors,
            "new_items": self.new_items, "downloaded": self.downloaded,
            "failed": self.failed, "skipped": self.skipped,
            "report": self.report, "message": self.message,
        }


# ---------------- 入库 ----------------

def sync_subscriptions(session: Session, platform: str) -> dict:
    """把账号关注列表同步为订阅源（新增/改名）。"""
    source = build_source(platform)
    try:
        discovered = source.discover_sources()
    finally:
        source.close()

    existing = {
        s.target: s
        for s in session.exec(select(Subscription).where(Subscription.platform == platform)).all()
    }
    created = 0
    now = datetime.now()
    for item in discovered:
        sub = existing.get(item.target)
        if sub is None:
            session.add(Subscription(
                platform=platform, target=item.target, name=item.name, last_synced_at=now
            ))
            created += 1
        elif sub.name != item.name:
            sub.name = item.name
            sub.last_synced_at = now
            session.add(sub)
    session.commit()
    return {"platform": platform, "discovered": len(discovered), "created": created}


def _save_item(session: Session, platform: str, sub_name: str, item: RawItem) -> bool:
    """入库一条内容；已存在返回 False。"""
    exists = session.exec(
        select(Content.id).where(
            Content.platform == platform, Content.content_id == item.content_id
        )
    ).first()
    if exists is not None:
        return False

    session.add(Content(
        platform=platform,
        content_id=item.content_id,
        dynamic_id=item.content_id if item.media_type != "video" else "",
        author=item.author or sub_name,
        author_id=item.author_id,
        title=item.title,
        media_type=item.media_type,
        url=item.url,
        cover=item.cover,
        description=item.description[:2000],
        duration=item.duration,
        images_json=json.dumps(item.images, ensure_ascii=False) if item.images else "",
        published_at=item.published_at,
        like_count=item.like_count,
        comment_count=item.comment_count,
    ))
    session.add(Download(platform=platform, content_id=item.content_id, status="pending"))
    session.commit()
    return True


# ---------------- 抓取 ----------------

def collect_contents(
    session: Session,
    day: date,
    platform: str,
    only_mid: str | None = None,
) -> int:
    """抓取指定日期内所有关注作者的内容，返回新增条数。"""
    settings = get_settings()
    since, until = day_range(day)
    source = build_source(platform)
    new_items = 0

    try:
        subs = session.exec(
            select(Subscription).where(
                Subscription.platform == platform, Subscription.enabled == True  # noqa: E712
            )
        ).all()
        if only_mid:
            subs = [s for s in subs if s.target == only_mid]
        if not subs:
            logger.warning("没有可抓取的订阅源，请先执行：python -m app sync")
            return 0

        for index, sub in enumerate(subs, start=1):
            try:
                items = source.fetch_range(sub.target, since, until)
            except Exception as e:  # noqa: BLE001 单个作者失败不影响整体
                logger.warning("[%d/%d] %s 抓取失败：%s", index, len(subs), sub.name, e)
                time.sleep(settings.request_interval)
                continue

            added = sum(1 for item in items if _save_item(session, platform, sub.name, item))
            new_items += added
            if added:
                logger.info("[%d/%d] %s：新增 %d 条", index, len(subs), sub.name, added)
            time.sleep(settings.request_interval)
    finally:
        source.close()

    return new_items


# ---------------- 下载 ----------------

def _pick_targets(session: Session, day: date, platform: str, limit: int, per_author: int):
    since, until = day_range(day)
    contents = session.exec(
        select(Content)
        .where(
            Content.platform == platform,
            Content.published_at >= since,
            Content.published_at < until,
        )
        .order_by(Content.published_at.desc())
    ).all()
    downloads = {
        (d.platform, d.content_id): d
        for d in session.exec(select(Download).where(Download.platform == platform)).all()
    }
    picked: list[tuple[Content, Download]] = []
    per_author_count: dict[str, int] = {}
    for content in contents:
        dl = downloads.get((content.platform, content.content_id))
        if dl is None or dl.status not in ("pending", "failed"):
            continue
        if per_author_count.get(content.author, 0) >= per_author:
            continue
        if len(picked) >= limit:
            logger.info("达到单次下载上限 %d，剩余内容留到下次", limit)
            break
        per_author_count[content.author] = per_author_count.get(content.author, 0) + 1
        picked.append((content, dl))
    return picked


def _media_dir(day: date, platform: str, author: str, extra: str = "") -> Path:
    settings = get_settings()
    base = settings.media_path / day.isoformat() / platform / safe_name(author, 40)
    return base / safe_name(extra, 50) if extra else base


def _images_of(content: Content) -> list[str]:
    if not content.images_json:
        return [content.cover] if content.cover else []
    try:
        urls = json.loads(content.images_json)
    except (ValueError, TypeError):
        return [content.cover] if content.cover else []
    return [u for u in urls if isinstance(u, str) and u]


def download_contents(session: Session, day: date, platform: str, limit: int, per_author: int) -> dict:
    """下载当日待下载内容，返回统计。"""
    settings = get_settings()
    stats = {"downloaded": 0, "failed": 0, "skipped": 0}

    # 上次异常退出留下的 running 任务重置为 pending
    for stale in session.exec(
        select(Download).where(Download.platform == platform, Download.status == "running")
    ).all():
        stale.status = "pending"
        session.add(stale)
    session.commit()

    cookiefile = None
    if platform == "bilibili":
        try:
            cookiefile = bili_cookiefile()
        except CookieError as e:
            logger.warning("未取到 Cookie，将以匿名身份下载（画质受限）：%s", e)

    targets = _pick_targets(session, day, platform, limit, per_author)
    for content, dl in targets:
        dl.started_at = datetime.now()
        dl.attempts += 1
        dl.status = "running"
        session.add(dl)
        session.commit()

        if content.media_type == "text":
            dl.status, dl.error = "skipped", "纯文本动态，无需下载"
            stats["skipped"] += 1
        elif content.media_type == "image":
            if not settings.download_images:
                dl.status, dl.error = "skipped", "已关闭图片下载"
                stats["skipped"] += 1
            else:
                out_dir = _media_dir(
                    day, platform, content.author, f"{content.dynamic_id} {content.title}"
                )
                saved, errors = download_images(_images_of(content), out_dir)
                if saved:
                    dl.status = "done"
                    dl.path = str(out_dir)
                    dl.size = sum(p.stat().st_size for p in saved)
                    stats["downloaded"] += 1
                    if errors:
                        dl.error = ("部分图片失败：" + "; ".join(errors))[:300]
                else:
                    dl.status = "failed"
                    dl.error = ("; ".join(errors) or "没有可下载的图片")[:300]
                    stats["failed"] += 1
        else:
            out_dir = _media_dir(day, platform, content.author)
            stem = f"{safe_name(content.title, 70)} [{content.content_id}]"
            ok, path, err = download(
                content.url, out_dir, stem,
                quality=settings.quality, cookiefile=cookiefile, proxy=settings.proxy,
            )
            if ok:
                dl.status, dl.path = "done", path
                dl.size = _file_size(path)
                stats["downloaded"] += 1
            else:
                dl.status, dl.error = "failed", err
                stats["failed"] += 1

        dl.finished_at = datetime.now()
        session.add(dl)
        session.commit()

    return stats


def _file_size(path: str) -> int:
    try:
        return Path(path).stat().st_size
    except OSError:
        return 0


# ---------------- 主流程 ----------------

def run_once(
    day: date | None = None,
    platform: str = "bilibili",
    limit: int | None = None,
    do_download: bool = True,
    refresh_sources: bool = True,
    only_mid: str | None = None,
) -> dict:
    """完整跑一次：同步关注 → 抓取 → 下载 → 生成报告。"""
    settings = get_settings()
    settings.ensure_dirs()
    target_day = day or (date.today() - timedelta(days=1))
    started = datetime.now()
    result = RunResult(day=target_day.isoformat(), platform=platform)
    message = ""

    from app.database import session_scope

    with session_scope() as session:
        try:
            if refresh_sources:
                info = sync_subscriptions(session, platform)
                logger.info("关注列表同步：%s", info)
            subs = session.exec(
                select(Subscription).where(
                    Subscription.platform == platform, Subscription.enabled == True  # noqa: E712
                )
            ).all()
            result.authors = len(subs)

            result.new_items = collect_contents(session, target_day, platform, only_mid)
            logger.info("%s 新增内容 %d 条", target_day, result.new_items)

            if do_download:
                stats = download_contents(
                    session, target_day, platform,
                    limit=limit or settings.max_downloads_per_run,
                    per_author=settings.max_downloads_per_author,
                )
                result.downloaded = stats["downloaded"]
                result.failed = stats["failed"]
                result.skipped = stats["skipped"]

            if paths := write_reports(session, target_day):
                result.report = str(paths[1])
        except CookieError as e:
            message = f"登录态问题：{e}"
            logger.error("登录态问题：%s", str(e).splitlines()[0])
        except Exception as e:  # noqa: BLE001
            message = str(e)
            logger.exception("采集失败")

        result.message = message

        session.add(RunLog(
            run_date=target_day.isoformat(),
            platform=platform,
            status="failed" if message else "success",
            authors=result.authors,
            new_items=result.new_items,
            downloaded=result.downloaded,
            failed=result.failed,
            skipped=result.skipped,
            message=message[:1000],
            started_at=started,
            finished_at=datetime.now(),
        ))
        session.commit()

    return result.as_dict()
