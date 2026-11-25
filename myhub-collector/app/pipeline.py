"""采集编排：同步关注 → 抓取当日内容 → 下载 → 生成总结。"""
from __future__ import annotations

import json
import logging
import tempfile
import time
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path

from sqlmodel import Session, select

from app import credentials, jobs
from app.config import get_settings
from app.cookies import CookieError
from app.downloader import download, download_direct, download_images, download_images_by_url, find_files
from app.downloader.ytdlp import ffmpeg_available, find_deno
from app.dynamic_html import image_data_uri, write_dynamic_html, write_video_card
from app.filetime import touch_published
from app.models import Content, Download, RunLog, Subscription
from app.sources import SourceError, build_source
from app.sources.base import RawItem
from app.summarize import day_range, write_reports
from app.utils import DURATION_SKIP_PREFIX, build_stem, fmt_duration, parse_duration

logger = logging.getLogger(__name__)


def _report_stage(name: str, percent: float = 0.0) -> None:
    """把「同步 / 抓取 / 生成报告」这类没有字节进度的阶段告诉门户。

    命令行直接跑采集时没有任务在跑，report_progress 会自动忽略。
    """
    jobs.report_progress(
        stage=name, current=0, total=0, percent=percent,
        downloaded=0, size=0, speed=0.0, eta=0, title="",
    )


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
    """把账号关注列表同步为订阅源（新增 / 改名 / 重新关注恢复 / 取关停用）。"""
    source = build_source(platform)
    try:
        discovered = source.discover_sources()
    finally:
        source.close()

    existing = {
        s.target: s
        for s in session.exec(select(Subscription).where(Subscription.platform == platform)).all()
    }
    created = disabled = 0
    now = datetime.now()
    seen: set[str] = set()
    for item in discovered:
        seen.add(item.target)
        sub = existing.get(item.target)
        if sub is None:
            session.add(Subscription(
                platform=platform, target=item.target, name=item.name, last_synced_at=now
            ))
            created += 1
        elif sub.name != item.name or not sub.enabled:
            sub.name = item.name
            sub.enabled = True  # 重新关注后恢复采集
            sub.last_synced_at = now
            session.add(sub)

    # 已取关的源停用；发现结果为空时不动，避免接口异常把全部订阅停掉
    if seen:
        for target, sub in existing.items():
            if target not in seen and sub.enabled:
                sub.enabled = False
                sub.last_synced_at = now
                session.add(sub)
                disabled += 1
    session.commit()
    return {
        "platform": platform,
        "discovered": len(discovered),
        "created": created,
        "disabled": disabled,
    }


def _save_item(session: Session, platform: str, sub_name: str, item: RawItem) -> bool:
    """入库一条内容；已存在则刷新标题/正文等元数据并返回 False。"""
    existing = session.exec(
        select(Content).where(
            Content.platform == platform, Content.content_id == item.content_id
        )
    ).first()
    if existing is not None:
        touched = False
        for field, value in (
            ("title", item.title),
            ("description", item.description[:2000]),
            ("cover", item.cover),
            ("url", item.url),
            ("media_url", item.media_url),
        ):
            if value and getattr(existing, field) != value:
                setattr(existing, field, value)
                touched = True
        if item.images:
            payload = json.dumps(item.images, ensure_ascii=False)
            if existing.images_json != payload:
                existing.images_json = payload
                touched = True
        if item.emotes:
            payload = json.dumps(item.emotes, ensure_ascii=False)
            if existing.emotes_json != payload:
                existing.emotes_json = payload
                touched = True
        if touched:
            session.add(existing)
            session.commit()
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
        media_url=item.media_url,
        description=item.description[:2000],
        duration=item.duration,
        images_json=json.dumps(item.images, ensure_ascii=False) if item.images else "",
        emotes_json=json.dumps(item.emotes, ensure_ascii=False) if item.emotes else "",
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

def _pick_targets(
    session: Session,
    day: date,
    platform: str,
    only_ids: set[str] | None = None,
):
    since, until = day_range(day)
    contents = session.exec(
        select(Content)
        .where(
            Content.platform == platform,
            Content.published_at >= since,
            Content.published_at < until,
        )
        # 按发布顺序正序：老内容先下，最新发布的排在最后；同一秒的用 id 兜底保证顺序稳定
        .order_by(Content.published_at.asc(), Content.id.asc())
    ).all()
    downloads = {
        (d.platform, d.content_id): d
        for d in session.exec(select(Download).where(Download.platform == platform)).all()
    }
    picked: list[tuple[Content, Download]] = []
    for content in contents:
        if only_ids and content.content_id not in only_ids:
            continue
        dl = downloads.get((content.platform, content.content_id))
        if dl is None or dl.status not in ("pending", "failed"):
            continue
        picked.append((content, dl))
    return picked


def _stem(content: Content) -> str:
    """平台-作者-标题-发布号（多 P 时由 yt-dlp 补 -[Pn]）。"""
    return build_stem(
        content.platform, content.author, content.title, content.content_id
    )


def _images_of(content: Content) -> list[str]:
    if not content.images_json:
        return [content.cover] if content.cover else []
    try:
        urls = json.loads(content.images_json)
    except (ValueError, TypeError):
        return [content.cover] if content.cover else []
    return [u for u in urls if isinstance(u, str) and u]


def _emotes_of(content: Content) -> dict[str, str]:
    """正文表情映射：[名称] -> 图标 URL。"""
    if not content.emotes_json:
        return {}
    try:
        data = json.loads(content.emotes_json)
    except (ValueError, TypeError):
        return {}
    if not isinstance(data, dict):
        return {}
    return {str(k): str(v) for k, v in data.items() if k and v}


def _emote_uris(content: Content) -> dict[str, str]:
    """把正文表情图标下载后转成 data URI，随 HTML 一起离线可用。"""
    emotes = _emotes_of(content)
    if not emotes:
        return {}
    with tempfile.TemporaryDirectory(prefix="myhub_emote_") as tmp:
        saved, errors = download_images_by_url(list(emotes.values()), Path(tmp))
        if errors:
            logger.debug("%s 部分表情下载失败：%s", content.content_id, "; ".join(errors))
        return {
            name: image_data_uri(path)
            for name, url in emotes.items()
            if (path := saved.get(url)) is not None and path.stat().st_size > 0
        }


def _card_cover(content: Content) -> str:
    """封面转 data URI；下载失败时回落远程 URL，保证卡片至少有图可看。"""
    url = (content.cover or "").strip()
    if not url:
        return ""
    if url.startswith("//"):
        url = "https:" + url
    referer = (
        "https://www.bilibili.com/"
        if content.platform == "bilibili"
        else (content.url or "")
    )
    with tempfile.TemporaryDirectory(prefix="myhub_cover_") as tmp:
        saved, errors = download_images([url], Path(tmp), referer=referer)
        if errors:
            logger.debug("%s 封面下载失败：%s", content.content_id, "; ".join(errors))
        if saved and saved[0].stat().st_size > 0:
            return image_data_uri(saved[0])
    return url


def _write_duration_card(content: Content, limit_seconds: int) -> str:
    """超时长视频不下载本体，只落一张含标题和封面的 HTML 预览，返回路径。"""
    settings = get_settings()
    settings.download_path.mkdir(parents=True, exist_ok=True)
    path = settings.download_path / f"{_stem(content)}.html"
    return str(write_video_card(content, path, _card_cover(content), limit_seconds // 60))


def _duration_from_error(err: str) -> str:
    """从「超时长：23:38 超过上限 10 分钟」里取回真实时长文本（取不到返回空串）。"""
    prefix = f"{DURATION_SKIP_PREFIX}："
    if prefix not in err:
        return ""
    text, sep, _ = err.split(prefix, 1)[1].partition(" 超过上限")
    return text.strip() if sep else ""


def _platform_cookiefile(platform: str) -> Path | None:
    """各平台给 yt-dlp 用的 Cookie 文件；统一走 app.credentials，拿不到就匿名下载。"""
    path = credentials.cookiefile(platform)
    if path is None:
        logger.info("%s 没有可用登录态，按匿名下载（画质可能受限）", platform)
    return path


def download_contents(
    session: Session,
    day: date,
    platform: str,
    only_ids: set[str] | None = None,
) -> dict:
    """下载当日待下载内容，返回统计。only_ids 可只处理指定内容（重下/修复用）。

    不限条数、不限单作者条数：当天所有待下载内容都会处理。
    """
    settings = get_settings()
    stats = {"downloaded": 0, "failed": 0, "skipped": 0}
    # 0 = 不限制；时长未知的内容（YouTube RSS 没有时长）交给下载器解析后再判断
    duration_limit = max(int(settings.max_duration_minutes or 0), 0) * 60

    # 上次异常退出留下的 running 任务重置为 pending
    for stale in session.exec(
        select(Download).where(Download.platform == platform, Download.status == "running")
    ).all():
        stale.status = "pending"
        session.add(stale)
    session.commit()

    if not ffmpeg_available(settings.ffmpeg_location):
        logger.warning(
            "未检测到 ffmpeg（PATH 与 FFMPEG_LOCATION 都没有），视频将退化为单文件流，画质可能只有 480p/720p"
        )

    cookiefile = _platform_cookiefile(platform)
    if platform == "youtube":
        proxy = settings.youtube_proxy or settings.proxy
    elif platform == "douyin":
        proxy = settings.douyin_proxy or settings.proxy
    else:
        proxy = settings.proxy
    # YouTube 的 nsig / n 挑战必须靠 Deno 解，否则只剩 storyboard 预览图
    js_runtimes = None
    if platform == "youtube":
        if deno := find_deno():
            js_runtimes = {"deno": {"path": deno}}
        else:
            logger.warning(
                "没找到 Deno：YouTube 只能拿到预览图格式。"
                "执行 python -m app deps 可自动下载到 data/tools/deno/"
            )

    targets = _pick_targets(session, day, platform, only_ids)

    # 旧数据可能缺正文（早期只读 desc），落盘前用详情接口补一次
    detail_source = None
    try:
        detail_source = build_source(platform)
    except SourceError as e:
        logger.debug("详情补齐不可用：%s", e)

    total = len(targets)
    for index, (content, dl) in enumerate(targets, 1):
        # 门户实时进度：先报「第几条 / 共几条」，字节级进度由下载器继续覆盖
        jobs.report_progress(
            stage="下载",
            current=index,
            total=total,
            title=(content.title or content.content_id)[:60],
            percent=0.0,
            downloaded=0,
            size=0,
            speed=0.0,
            eta=0,
        )
        # 已知时长的超长视频直接跳过：不占带宽，也不算「失败」
        known_seconds = parse_duration(content.duration)
        if (
            duration_limit
            and content.media_type == "video"
            and known_seconds
            and known_seconds > duration_limit
        ):
            # 不下载视频本体，只落一张「标题 + 封面」的 HTML 预览
            card_path = ""
            try:
                card_path = _write_duration_card(content, duration_limit)
            except OSError as e:
                logger.warning("超时长预览生成失败 %s：%s", content.content_id, e)
            dl.status = "skipped"
            dl.error = (
                f"{DURATION_SKIP_PREFIX}：{fmt_duration(known_seconds)}"
                f" 超过上限 {settings.max_duration_minutes} 分钟"
                + ("，已生成 HTML 预览" if card_path else "")
            )
            dl.path, dl.size = card_path, _file_size(card_path)
            dl.finished_at = datetime.now()
            stats["skipped"] += 1
            session.add(dl)
            session.commit()
            if card_path:
                _stamp(content, [Path(card_path)])
            logger.info(
                "跳过超长视频：%s %s（%s）", content.platform, content.content_id, dl.error
            )
            continue

        dl.started_at = datetime.now()
        dl.attempts += 1
        dl.status = "running"
        session.add(dl)
        session.commit()

        if (
            detail_source is not None
            and content.media_type in ("text", "image")
            and (not content.description or not content.emotes_json)
        ):
            detail = detail_source.fetch_detail(content.content_id)
            if detail is not None:
                touched = False
                if detail.description and not content.description:
                    content.description = detail.description[:2000]
                    touched = True
                if detail.title and not content.title:
                    content.title = detail.title
                    touched = True
                if detail.images and not content.images_json:
                    content.images_json = json.dumps(detail.images, ensure_ascii=False)
                    touched = True
                if detail.emotes:
                    payload = json.dumps(detail.emotes, ensure_ascii=False)
                    if content.emotes_json != payload:
                        content.emotes_json = payload
                        touched = True
                if touched:
                    session.add(content)
                    session.commit()
                    logger.info("补齐动态元数据：%s（正文 %d 字）", content.content_id, len(content.description))

        if content.media_type == "text":
            # 纯文本 / 专栏动态：不下载媒体，落一份本地 HTML 页面
            settings.download_path.mkdir(parents=True, exist_ok=True)
            out_path = settings.download_path / f"{_stem(content)}.html"
            try:
                write_dynamic_html(content, out_path, None, _emote_uris(content))
                dl.status, dl.path = "done", str(out_path)
                dl.size = _file_size(dl.path)
                stats["downloaded"] += 1
                _stamp(content, [out_path])
            except OSError as e:
                dl.status, dl.error = "failed", f"HTML 生成失败：{e}"[:300]
                stats["failed"] += 1
        elif content.media_type == "image":
            if not settings.download_images:
                dl.status, dl.error = "skipped", "已关闭图片下载"
                stats["skipped"] += 1
            else:
                # 图文动态：单个自包含 HTML（图片转入临时目录后以 base64 内嵌）
                settings.download_path.mkdir(parents=True, exist_ok=True)
                page = settings.download_path / f"{_stem(content)}.html"
                images = _images_of(content)
                errors: list[str] = []
                uris: list[str] = []
                if images:
                    with tempfile.TemporaryDirectory(prefix="myhub_img_") as tmp:
                        saved, errors = download_images(images, Path(tmp))
                        uris = [image_data_uri(p) for p in saved if p.stat().st_size > 0]
                html_ok = False
                try:
                    write_dynamic_html(content, page, uris, _emote_uris(content))
                    html_ok = True
                except OSError as e:
                    errors.append(f"HTML 生成失败：{e}")
                # 纯文字动态被归到 image 时没有图片，只要有 HTML 就算成功
                if html_ok and (uris or not images):
                    dl.status = "done"
                    dl.path = str(page)
                    dl.size = _file_size(str(page))
                    stats["downloaded"] += 1
                    _stamp(content, [page])
                    if errors:
                        dl.error = ("部分图片失败：" + "; ".join(errors))[:300]
                else:
                    dl.status = "failed"
                    dl.error = ("; ".join(errors) or "没有可下载的图片")[:300]
                    stats["failed"] += 1
        else:
            # 视频：平铺在下载根目录，多 P 由 yt-dlp 追加 -[Pn]
            out_dir = settings.download_path
            stem = _stem(content)
            # 时长已知且没超限就不必再探测；未知时（YouTube）交给下载器解析后判断
            probe_limit = 0 if known_seconds else duration_limit
            if platform == "douyin" and content.media_url:
                # 抖音给的是现成 mp4 直链，直接拉更稳；失败再退回 yt-dlp
                ok, path, err = download_direct(
                    content.media_url, out_dir, stem,
                    referer=content.url, proxy=proxy,
                )
                if not ok and not _network_failure(err):
                    # 链接过期 / 403 这类还值得让 yt-dlp 重新解析一次
                    logger.info("抖音直链下载失败，改用 yt-dlp：%s", err)
                    ok, path, err = download(
                        content.url, out_dir, stem,
                        quality=settings.quality, platform=platform,
                        cookiefile=cookiefile, proxy=proxy,
                        ffmpeg_location=settings.ffmpeg_location,
                        js_runtimes=js_runtimes,
                        max_duration_sec=probe_limit,
                    )
                elif not ok:
                    logger.warning("抖音直链网络不通，跳过 yt-dlp 兜底：%s", err)
                if not ok:
                    err = _douyin_hint(err)
            else:
                ok, path, err = download(
                    content.url, out_dir, stem,
                    quality=settings.quality, platform=platform,
                    cookiefile=cookiefile, proxy=proxy,
                    ffmpeg_location=settings.ffmpeg_location,
                    js_runtimes=js_runtimes,
                    max_duration_sec=probe_limit,
                )
            if ok:
                dl.status, dl.path = "done", path
                files = find_files(out_dir, stem)
                dl.size = sum(f.stat().st_size for f in files) if files else _file_size(path)
                stats["downloaded"] += 1
                _stamp(content, files or [path])
            elif err.startswith(DURATION_SKIP_PREFIX):
                # 下载器解析出的真实总时长超限（B 站多 P / YouTube）
                if not content.duration and (real := _duration_from_error(err)):
                    # 回写探测到的时长，下次直接按已知时长跳过，不必再解析
                    content.duration = real
                    session.add(content)
                card_path = ""
                try:
                    card_path = _write_duration_card(content, duration_limit)
                    err = f"{err}，已生成 HTML 预览"
                except OSError as e:
                    logger.warning("超时长预览生成失败 %s：%s", content.content_id, e)
                dl.status, dl.error = "skipped", err
                dl.path, dl.size = card_path, _file_size(card_path)
                stats["skipped"] += 1
            else:
                if platform == "youtube":
                    err = _youtube_hint(err)
                dl.status, dl.error = "failed", err
                stats["failed"] += 1

        dl.finished_at = datetime.now()
        session.add(dl)
        session.commit()

    if detail_source is not None:
        detail_source.close()

    return stats


# 直链失败如果是网络层问题（连不上抖音 CDN），退 yt-dlp 只会用同一条网络再等一轮，
# 不如立刻记失败，等下一次「重新下载」换到别的节点。
_NETWORK_ERROR_HINTS = (
    "Timeout", "Timed out", "ConnectError", "ConnectTimeout",
    "ReadError", "ReadTimeout", "getaddrinfo", "SSL", "10060",
)


def _network_failure(err: str) -> bool:
    text = err or ""
    return any(hint in text for hint in _NETWORK_ERROR_HINTS)


def _douyin_hint(err: str) -> str:
    """抖音失败大多是登录态或直链过期，翻译成可执行的下一步。"""
    if "Fresh cookies" in err or "Verify" in err or "登录" in err:
        return f"{err.rstrip('。')}；先跑 python -m app login douyin 刷新登录态"[:300]
    for code in ("403", "404", "410", "expired", "过期"):
        if code in err:
            return f"{err.rstrip('。')}；直链可能已过期，重跑 collect 会重新抓链接"[:300]
    return err


def _youtube_hint(err: str) -> str:
    """把 YouTube 最常见的两种失败翻译成「该配什么」。"""
    if "Sign in to confirm" in err:
        return f"{err.rstrip('。')}；先跑 python -m app login youtube 刷新登录态"[:300]
    if "Only images are available" in err or "Signature solving failed" in err:
        return f"{err.rstrip('。')}；缺少 JS 运行时，执行 python -m app deps 自动安装"[:300]
    return err


def _stamp(content: Content, paths) -> None:
    """把下载产物的修改时间对齐到发布时间（FILE_MTIME_FROM_PUBLISH=false 可关）。"""
    if get_settings().file_mtime_from_publish:
        touch_published(paths, content.published_at)


def _file_size(path: str) -> int:
    try:
        return Path(path).stat().st_size
    except OSError:
        return 0


# ---------------- 主流程 ----------------

def run_once(
    day: date | None = None,
    platform: str = "bilibili",
    do_download: bool = True,
    refresh_sources: bool = True,
    only_mid: str | None = None,
    only_ids: set[str] | None = None,
    do_collect: bool = True,
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
                _report_stage("同步订阅")
                info = sync_subscriptions(session, platform)
                logger.info("关注列表同步：%s", info)
            subs = session.exec(
                select(Subscription).where(
                    Subscription.platform == platform, Subscription.enabled == True  # noqa: E712
                )
            ).all()
            result.authors = len(subs)

            if do_collect:
                _report_stage("抓取当日内容")
            result.new_items = (
                collect_contents(session, target_day, platform, only_mid) if do_collect else 0
            )
            logger.info("%s 新增内容 %d 条", target_day, result.new_items)

            if do_download:
                stats = download_contents(
                    session, target_day, platform,
                    only_ids=only_ids,
                )
                result.downloaded = stats["downloaded"]
                result.failed = stats["failed"]
                result.skipped = stats["skipped"]

            _report_stage("生成报告", percent=100.0)
            if report := write_reports(session, target_day):
                result.report = str(report)
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
