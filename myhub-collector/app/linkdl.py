"""按链接下载：抖音单视频 / B站单视频（含分P）/ B站稍后再看 / YouTube 单视频、播放列表、稍后观看。

和「采集」的区别是不依赖关注列表和日期，给什么链接下什么；入库、命名、下载器
全部复用采集那套（contents / downloads + 「平台-作者-标题-内容号」），
所以下载进度页、日报、失败重试看到的都是同一批文件。
"""
from __future__ import annotations

import json
import logging
import re
from collections import defaultdict
from datetime import date, datetime
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import httpx
from sqlmodel import select

from app import credentials, jobs
from app.config import get_settings
from app.database import session_scope
from app.models import Content, Download
from app.sources.base import RawItem
from app.utils import fmt_duration

logger = logging.getLogger(__name__)

MAX_ITEMS = 100          # 播放列表 / 稍后再看一次最多下这么多条，防止手滑
_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
# 只吃 URL 合法字符：抖音分享文案里链接后面常紧跟中文，按空白切会把汉字带进来
_URL_RE = re.compile(r"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+", re.I)
_BV_RE = re.compile(r"(BV[0-9A-Za-z]{10})")
_AV_RE = re.compile(r"\bav(\d+)\b", re.I)
_DY_ID_RE = re.compile(r"/(?:video|note|share/video|share/note)/(\d{10,})")

_HOSTS = (
    ("douyin", ("douyin.com", "iesdouyin.com")),
    ("bilibili", ("bilibili.com", "b23.tv")),
    ("youtube", ("youtube.com", "youtu.be")),
)
_NAME = {"douyin": "抖音", "bilibili": "B站", "youtube": "YouTube"}
_BILI_VIEW = "https://api.bilibili.com/x/web-interface/view"
_BILI_TOVIEW = "https://api.bilibili.com/x/v2/history/toview/web"


# ---------------- 链接识别 ----------------
def extract_urls(text: str) -> list[str]:
    """从任意文本里抠链接：抖音分享文案、多行粘贴、混着中文标点都能处理。"""
    out, seen = [], set()
    for raw in _URL_RE.findall(text or ""):
        url = raw.rstrip("，。、；：！？）】」》…,.;:!?)'\"")
        if url and url not in seen:
            seen.add(url)
            out.append(url)
    return out


def sniff(url: str) -> str:
    host = (urlsplit(url).netloc or "").lower()
    for platform, hosts in _HOSTS:
        if any(host == h or host.endswith("." + h) for h in hosts):
            return platform
    return ""


def _is_watchlater(url: str) -> bool:
    return "watchlater" in urlsplit(url).path.lower()


# ---------------- B站 ----------------
def _bili_client() -> httpx.Client:
    headers = {"User-Agent": _UA, "Referer": "https://www.bilibili.com/",
               "Accept": "application/json, text/plain, */*"}
    try:
        cookie = credentials.cookie_header("bilibili")
    except Exception:  # noqa: BLE001 没登录也能看公开视频的基础信息
        cookie = ""
    if cookie:
        headers["Cookie"] = cookie
    return httpx.Client(headers=headers, timeout=20, follow_redirects=True, trust_env=False)


def _bili_data(client: httpx.Client, url: str, params: dict) -> dict:
    resp = client.get(url, params=params)
    resp.raise_for_status()
    data = resp.json()
    if data.get("code") not in (0, None):
        raise ValueError(f"B站接口返回 {data.get('code')}：{data.get('message') or '未知错误'}")
    return data.get("data") or {}


def _bili_video(client: httpx.Client, url: str) -> RawItem:
    bvid = _BV_RE.search(url)
    aid = _AV_RE.search(url)
    if not bvid and not aid:                       # b23.tv 短链先展开
        final = str(client.get(url).url)
        bvid, aid = _BV_RE.search(final), _AV_RE.search(final)
    if bvid:
        params = {"bvid": bvid.group(1)}
    elif aid:
        params = {"aid": aid.group(1)}
    else:
        raise ValueError("链接里没有识别到 BV 号")

    v = _bili_data(client, _BILI_VIEW, params)
    if not v.get("bvid"):
        raise ValueError("B站没有返回视频信息（可能已删除或仅限登录）")
    pages = [p for p in (v.get("pages") or []) if isinstance(p, dict)]
    owner = v.get("owner") or {}
    pno = int((parse_qs(urlsplit(url).query).get("p") or ["0"])[0] or 0)

    if 0 < pno <= len(pages):                      # 带 ?p=N 只下这一 P
        page = pages[pno - 1]
        title = page.get("part") or v.get("title") or ""
        duration = int(page.get("duration") or 0)
        cid = f"{v['bvid']}-p{pno}"
        page_url = f"https://www.bilibili.com/video/{v['bvid']}?p={pno}"
    else:
        title = v.get("title") or ""
        duration = sum(int(p.get("duration") or 0) for p in pages) or int(v.get("duration") or 0)
        cid = str(v["bvid"])
        page_url = f"https://www.bilibili.com/video/{v['bvid']}"

    return RawItem(
        content_id=cid, title=str(title)[:200], author=str(owner.get("name") or ""),
        author_id=str(owner.get("mid") or ""), url=page_url,
        published_at=datetime.fromtimestamp(int(v.get("pubdate") or 0) or 0),
        media_type="video", cover=v.get("pic") or "",
        description=str(v.get("desc") or "")[:500], duration=fmt_duration(duration),
    )


def _bili_watchlater(client: httpx.Client) -> list[RawItem]:
    data = _bili_data(client, _BILI_TOVIEW, {"jsonp": "jsonp"})
    rows = [it for it in (data.get("list") or []) if isinstance(it, dict)]
    if not rows:
        raise ValueError("稍后再看是空的，或者当前 B站没登录")
    out: list[RawItem] = []
    for it in rows:
        bvid = it.get("bvid")
        if not bvid:
            continue
        pages = [p for p in (it.get("pages") or []) if isinstance(p, dict)]
        duration = int(it.get("duration") or 0) or sum(int(p.get("duration") or 0) for p in pages)
        ts = int(it.get("pubdate") or it.get("add_at") or 0)
        owner = it.get("owner") or {}
        out.append(RawItem(
            content_id=str(bvid), title=str(it.get("title") or bvid)[:200],
            author=str(owner.get("name") or ""), author_id=str(owner.get("mid") or ""),
            url=f"https://www.bilibili.com/video/{bvid}",
            published_at=datetime.fromtimestamp(ts) if ts else datetime.now(),
            media_type="video", cover=it.get("pic") or "",
            description=str(it.get("desc") or "")[:500], duration=fmt_duration(duration),
        ))
    return out


# ---------------- YouTube ----------------
def _ytdlp_opts() -> dict:
    from app.downloader.ytdlp import find_deno   # 复用采集下载器里的运行时探测

    settings = get_settings()
    opts: dict = {"quiet": True, "no_warnings": True, "skip_download": True,
                  "ignoreerrors": True, "extract_flat": "in_playlist",
                  # 只取元数据，别按下载的参数重试十几次，直连被墙时要在几十秒内失败
                  "socket_timeout": 15, "retries": 1, "fragment_retries": 1,
                  "extractor_retries": 1}
    proxy = settings.youtube_proxy or settings.proxy
    if proxy not in ("", "system", "direct"):
        opts["proxy"] = proxy
    cookie = credentials.cookiefile("youtube")
    if cookie:
        opts["cookiefile"] = str(cookie)
    deno = find_deno()
    if deno:
        opts["js_runtimes"] = {"deno": {"path": deno}}
    return opts


def _yt_item(entry: dict, info: dict) -> RawItem | None:
    vid = str(entry.get("id") or "").strip()
    if not vid:
        return None
    ts = entry.get("timestamp")
    published = datetime.fromtimestamp(int(ts)) if ts else datetime.now()
    stamp = str(entry.get("upload_date") or "")
    if not ts and re.fullmatch(r"\d{8}", stamp):
        published = datetime.strptime(stamp, "%Y%m%d")
    thumbs = entry.get("thumbnails") or []
    return RawItem(
        content_id=vid, title=str(entry.get("title") or vid)[:200],
        author=str(entry.get("uploader") or entry.get("channel")
                   or info.get("uploader") or info.get("channel") or ""),
        author_id=str(entry.get("channel_id") or ""),
        url=f"https://www.youtube.com/watch?v={vid}", published_at=published,
        media_type="video", cover=(thumbs[-1].get("url") if thumbs else "") or "",
        description=str(entry.get("description") or "")[:500],
        duration=fmt_duration(entry.get("duration")),
    )


def _youtube_guard() -> None:
    """直连模式下先探一下：被墙就立刻报错，别让 yt-dlp 卡着重试好几分钟。"""
    proxy = get_settings().youtube_proxy or get_settings().proxy
    if proxy not in ("", "system", "direct"):
        return
    try:
        with httpx.Client(timeout=8, follow_redirects=True, trust_env=(proxy == "system")) as c:
            c.get("https://www.youtube.com/")
    except Exception as exc:  # noqa: BLE001
        raise ValueError(
            "连不上 YouTube（直连超时）：先在 .env 配 PROXY 或 YOUTUBE_PROXY 再重试"
        ) from exc


def _youtube(url: str) -> list[RawItem]:
    import yt_dlp

    _youtube_guard()
    try:
        with yt_dlp.YoutubeDL(_ytdlp_opts()) as ydl:
            info = ydl.extract_info(url, download=False)
    except Exception as exc:  # noqa: BLE001 统一转成人话
        msg = str(exc)[:200]
        hint = ""
        if any(k in msg for k in ("timed out", "Timeout", "10060", "resolve", "Connection")):
            hint = "；YouTube 需要代理，先在 .env 配 PROXY 或 YOUTUBE_PROXY 再重试"
        raise ValueError(f"YouTube 解析失败：{msg}{hint}") from exc
    if not info:
        raise ValueError("YouTube 没有解析到内容，检查链接或登录状态")
    entries = [e for e in (info.get("entries") or []) if isinstance(e, dict)]
    if entries:
        items = [it for it in (_yt_item(e, info) for e in entries) if it is not None]
        if not items:
            raise ValueError("列表是空的：稍后观看 / 私人播放列表需要先在设置里登录 YouTube")
        return items
    single = _yt_item(info, info)
    if single is None:
        raise ValueError("YouTube 没有返回视频信息")
    return [single]


# ---------------- 抖音 ----------------
def _douyin_aweme_id(url: str) -> str:
    found = _DY_ID_RE.search(url)
    if found:
        return found.group(1)
    with httpx.Client(headers={"User-Agent": _UA}, timeout=15,
                      follow_redirects=True, trust_env=False) as client:
        final = str(client.get(url).url)
    found = _DY_ID_RE.search(final)
    if not found:
        raise ValueError("抖音链接里没有识别到作品号")
    return found.group(1)


def _douyin(url: str) -> list[RawItem]:
    from app.sources import build_source

    aweme_id = _douyin_aweme_id(url)
    source = build_source("douyin")
    try:
        item = source.fetch_one(aweme_id)
    finally:
        source.close()
    if item is None:
        raise ValueError("抖音详情没有拿到（可能未登录、作品被删或链接失效）")
    return [item]


def resolve(url: str) -> list[RawItem]:
    """一个链接 → 若干待下载条目。"""
    platform = sniff(url)
    if platform == "bilibili":
        with _bili_client() as client:
            if _is_watchlater(url) and not (_BV_RE.search(url) or _AV_RE.search(url)):
                return _bili_watchlater(client)
            return [_bili_video(client, url)]
    if platform == "youtube":
        return _youtube(url)
    if platform == "douyin":
        return _douyin(url)
    raise ValueError(f"不支持的链接：{url[:80]}")


# ---------------- 入库 / 下载 ----------------
def _upsert(session, platform: str, item: RawItem) -> bool:
    """确保 content + download 存在，返回是否还需要下载。"""
    content = session.exec(
        select(Content).where(Content.platform == platform, Content.content_id == item.content_id)
    ).first()
    if content is None:
        content = Content(
            platform=platform, content_id=item.content_id,
            dynamic_id=item.content_id if item.media_type != "video" else "",
            author=item.author or "", author_id=item.author_id or "",
            title=item.title or item.content_id, media_type=item.media_type or "video",
            url=item.url, cover=item.cover or "", media_url=item.media_url or "",
            description=(item.description or "")[:2000], duration=item.duration or "",
            images_json=json.dumps(item.images, ensure_ascii=False) if item.images else "",
            emotes_json="", published_at=item.published_at,
            like_count=item.like_count or 0, comment_count=item.comment_count or 0,
        )
        session.add(content)
        session.commit()
    else:
        content.title = content.title or item.title
        content.author = content.author or item.author
        content.url = content.url or item.url
        content.duration = content.duration or item.duration or ""
        session.add(content)
        session.commit()

    dl = session.exec(
        select(Download).where(Download.platform == platform, Download.content_id == item.content_id)
    ).first()
    if dl is None:
        dl = Download(platform=platform, content_id=item.content_id, status="pending")
        session.add(dl)
        session.commit()
    return not (dl.status == "done" and dl.path and Path(dl.path).exists())


def _collect(text: str) -> tuple[list[tuple[str, RawItem]], list[str]]:
    """解析全部链接，返回 (条目, 出错说明)。单条链接失败不影响其它链接。"""
    urls = extract_urls(text)
    if not urls:
        raise ValueError("没有识别到链接，粘贴 B站 / YouTube / 抖音 的视频地址即可")

    items: list[tuple[str, RawItem]] = []
    errors: list[str] = []
    for i, url in enumerate(urls, 1):
        platform = sniff(url)
        label = _NAME.get(platform, url)
        jobs.report_progress(stage="解析链接", current=i - 1, total=len(urls),
                             title=f"{label} {url[:60]}", percent=0.0,
                             downloaded=0, size=0, speed=0.0, eta=0)
        logger.info("解析 %s", url)
        try:
            batch = resolve(url)
        except Exception as exc:  # noqa: BLE001
            msg = f"{label} {url[:80]} 解析失败：{exc}"
            logger.warning("  %s", msg)
            errors.append(msg)
            continue
        logger.info("  → %d 条", len(batch))
        items.extend((platform, it) for it in batch[:MAX_ITEMS])
        if len(batch) > MAX_ITEMS:
            errors.append(f"{label} {url[:60]} 共 {len(batch)} 条，只取前 {MAX_ITEMS} 条")
    jobs.report_progress(stage="解析链接", current=len(urls), total=len(urls),
                         title="", percent=0.0, downloaded=0, size=0, speed=0.0, eta=0)
    return items, errors


def run(job, text: str) -> dict:
    items, errors = _collect(text)
    if not items:
        raise ValueError("；".join(errors) or "所有链接都没解析出内容")

    from app.pipeline import download_contents

    groups: dict[tuple[str, date], set[str]] = defaultdict(set)
    need = 0
    with session_scope() as session:
        for platform, item in items:
            if _upsert(session, platform, item):
                need += 1
                groups[(platform, item.published_at.date())].add(item.content_id)
    logger.info("解析完成：%d 条，待下载 %d 条", len(items), need)

    failed = 0
    with session_scope() as session:
        for (platform, day), ids in groups.items():
            stats = download_contents(session, day, platform, only_ids=set(ids))
            failed += int(stats.get("failed") or 0)

    result: dict = {"items": [], "errors": list(errors)}
    with session_scope() as session:
        for platform, item in items:
            dl = session.exec(
                select(Download).where(Download.platform == platform,
                                       Download.content_id == item.content_id)
            ).first()
            result["items"].append({
                "platform": platform, "name": _NAME.get(platform, platform),
                "title": item.title, "author": item.author, "url": item.url,
                "status": (dl.status if dl else "pending"), "path": (dl.path if dl else ""),
                "size": (dl.size if dl else 0), "error": (dl.error if dl else ""),
            })
        by_platform: dict[str, dict] = defaultdict(lambda: {"downloaded": 0, "failed": 0, "skipped": 0})
        for row in result["items"]:
            node = by_platform[row["name"]]
            if row["status"] == "done":
                node["downloaded"] += 1
            elif row["status"] == "failed":
                node["failed"] += 1
            elif row["status"] == "skipped":
                node["skipped"] += 1
    result.update({k: dict(v) for k, v in by_platform.items()})
    if not need:
        logger.info("全部已下载过，直接跳过")
    return result
