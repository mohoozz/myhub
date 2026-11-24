"""媒体清理：按 KEEP_DAYS 删除过期的下载文件，并同步清理对应下载记录。

下载目录是平铺的（`<DOWNLOAD_DIR>/平台-作者-标题-发布号.ext`），没有日期子目录，
所以按 downloads 表的完成时间（finished_at）判断过期，逐条删文件或目录。
"""
from __future__ import annotations

import logging
import shutil
from datetime import date, datetime, time, timedelta
from pathlib import Path

from sqlmodel import Session, select

from app.config import get_settings
from app.models import Download

logger = logging.getLogger(__name__)


def _path_size(path: Path) -> int:
    total = 0
    if path.is_file():
        try:
            return path.stat().st_size
        except OSError:
            return 0
    try:
        for item in path.rglob("*"):
            if item.is_file():
                try:
                    total += item.stat().st_size
                except OSError:  # 文件被占用 / 权限不足
                    continue
    except OSError:
        return total
    return total


def clean_media(
    session: Session,
    keep_days: int | None = None,
    dry_run: bool = False,
) -> dict:
    """删除完成时间早于保留天数的下载文件，并清理对应下载记录。"""
    settings = get_settings()
    keep = settings.keep_days if keep_days is None else max(int(keep_days), 0)
    cutoff = date.today() - timedelta(days=keep)
    cutoff_dt = datetime.combine(cutoff, time.min)

    removed_items: list[str] = []
    removed_downloads = 0
    freed = 0

    for dl in session.exec(select(Download).where(Download.status == "done")).all():
        finished = dl.finished_at or dl.started_at
        if finished is None or finished >= cutoff_dt:
            continue
        removed_downloads += 1
        path = Path(dl.path) if dl.path else None
        if path is None or not path.exists():
            if not dry_run:
                session.delete(dl)
            continue

        freed += _path_size(path)
        removed_items.append(path.name)
        if not dry_run:
            try:
                if path.is_dir():
                    shutil.rmtree(path, ignore_errors=True)
                else:
                    path.unlink(missing_ok=True)
            except OSError as e:  # 占用中的文件，下轮再删
                logger.warning("删除失败 %s: %s", path, e)
                continue
            session.delete(dl)

    if not dry_run:
        session.commit()

    logger.info(
        "%s清理：截止 %s，文件/目录 %d 个，释放 %d 字节，下载记录 %d 条",
        "试运行" if dry_run else "", cutoff, len(removed_items), freed, removed_downloads,
    )
    return {
        "cutoff": cutoff.isoformat(),
        "keep_days": keep,
        "root": str(settings.download_path),
        "removed_items": removed_items,
        "removed_size": freed,
        "removed_downloads": removed_downloads,
        "dry_run": dry_run,
    }
