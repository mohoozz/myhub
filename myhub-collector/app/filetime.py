"""文件时间对齐：把下载产物的修改时间改成内容发布时间。

为什么这么做：下载目录是平铺的，文件名以「平台-作者-标题-发布号」开头，按名称排序
得到的是作者聚合顺序。把 mtime 设成 published_at 之后，资源管理器按「修改日期」
排序就是发布顺序；B 站和 YouTube 走同一套逻辑，跨平台也能对齐。

注意：`python -m app clean` 按 downloads.finished_at 判断过期，不看 mtime，
所以改时间不影响清理策略。
"""
from __future__ import annotations

import logging
import os
from datetime import date, datetime
from pathlib import Path

from sqlmodel import Session, select

from app.downloader import find_files
from app.models import Content, Download
from app.utils import build_stem

logger = logging.getLogger(__name__)


def touch_published(paths, when: datetime) -> int:
    """把一批文件的 atime/mtime 设成发布时间，返回成功的文件数。"""
    if not when:
        return 0
    ts = when.timestamp()
    touched = 0
    for path in paths:
        try:
            target = Path(path)
            if target.exists():
                os.utime(target, (ts, ts))
                touched += 1
        except OSError as e:  # 文件被占用 / 权限不足：不影响下载结果
            logger.debug("设置文件时间失败 %s：%s", path, e)
    return touched


def _files_of(content: Content, download: Download) -> list[Path]:
    """一条内容对应的全部文件：单文件直接用，多 P 用 stem 前缀找齐。"""
    if not download.path:
        return []
    path = Path(download.path)
    if not path.exists():
        return []
    if path.is_dir():
        return [p for p in path.rglob("*") if p.is_file()]
    stem = build_stem(content.platform, content.author, content.title, content.content_id)
    siblings = find_files(path.parent, stem)
    return siblings or [path]


def restamp_downloads(
    session: Session,
    day: date | None = None,
    dry_run: bool = False,
) -> dict:
    """按 downloads 表回填修改时间；day 为空表示处理全部已下载内容。"""
    stmt = select(Download).where(Download.status == "done")
    downloads = session.exec(stmt).all()

    updated = missing = 0
    files = 0
    for download in downloads:
        content = session.exec(
            select(Content).where(
                Content.platform == download.platform,
                Content.content_id == download.content_id,
            )
        ).first()
        if content is None:
            missing += 1
            continue
        if day is not None and content.published_at.date() != day:
            continue
        targets = _files_of(content, download)
        if not targets:
            missing += 1
            continue
        updated += 1
        if dry_run:
            files += len(targets)
            continue
        files += touch_published(targets, content.published_at)

    return {
        "day": day.isoformat() if day else "全部",
        "matched": updated,
        "files": files,
        "missing": missing,
        "dry_run": dry_run,
    }
