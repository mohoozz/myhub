"""YouTube 抓取源：频道 RSS（免登录）+ 复用 yt-dlp 下载。

- 订阅来源有两个，合并去重：
  1. .env 里的 YOUTUBE_CHANNELS，支持三种写法
     频道 ID（UCxxxxxxxxxxxxxxxxxxxxxx）、@handle、频道主页链接
     用逗号 / 空格 / 换行分隔，例如：
       YOUTUBE_CHANNELS=UCBR8-60-B28hp2BmDPdntcQ, @MrBeast
  2. 登录账号自己的订阅列表：有 data/credentials/youtube.txt（login 命令写入）时，
     用 yt-dlp 打开 https://www.youtube.com/feed/channels 读取（自动翻页，取 channel_id + 频道名）
- 内容来源：https://www.youtube.com/feeds/videos.xml?channel_id=UC...
  RSS 是公开接口，一次给最近 15 条视频，含标题 / 发布时间 / 封面 / 简介 / 播放量。
- 时间是 UTC（2026-11-23T10:00:00+00:00），入库前统一转成本地朴素时间，
  与 B 站、日报的「按天过滤」口径一致。
"""
from __future__ import annotations

import logging
import re
import time
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

import httpx

from app.sources.base import DiscoveredSource, RawItem, Source, SourceError

logger = logging.getLogger(__name__)

_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
)
_FEED = "https://www.youtube.com/feeds/videos.xml?channel_id={cid}"
_HOME = "https://www.youtube.com/"
_WATCH = "https://www.youtube.com/watch?v={vid}"
_SUBSCRIPTIONS = "https://www.youtube.com/feed/channels"

_NS = {
    "atom": "http://www.w3.org/2005/Atom",
    "yt": "http://www.youtube.com/xml/schemas/2015",
    "media": "http://search.yahoo.com/mrss/",
}
_CHANNEL_ID = re.compile(r"UC[\w-]{22}")
_CHANNEL_ID_IN_HTML = re.compile(r'"(?:channelId|externalId)":"(UC[\w-]{22})"')
_CHANNEL_URL_IN_HTML = re.compile(r"youtube\.com/channel/(UC[\w-]{22})")


def _local(dt: datetime) -> datetime:
    """UTC → 本地朴素时间（项目里所有时间列都不带时区）。"""
    if dt.tzinfo is None:
        return dt
    return dt.astimezone().replace(tzinfo=None)


class YoutubeSource(Source):
    platform = "youtube"

    def __init__(
        self,
        channels: str = "",
        interval: float = 1.2,
        proxy: str = "direct",
        cookiefile: Path | None = None,
        use_subscriptions: bool = True,
    ):
        self._channels = [c for c in re.split(r"[,\s]+", channels or "") if c]
        self._interval = max(interval, 0.5)
        self._proxy = proxy
        self._cookiefile = cookiefile
        self._use_subscriptions = use_subscriptions
        self._feeds: dict[str, ET.Element] = {}
        self._client = httpx.Client(**_client_opts(proxy))

    # ---------- 订阅 ----------

    def discover_sources(self) -> list[DiscoveredSource]:
        """订阅源 = YOUTUBE_CHANNELS 手填清单 + 登录账号自己的订阅列表（频道 ID 做 target）。"""
        found: list[DiscoveredSource] = []
        seen: set[str] = set()

        def add(cid: str, name: str) -> None:
            if cid and cid not in seen:
                seen.add(cid)
                found.append(DiscoveredSource(name=name or cid, target=cid))

        for index, raw in enumerate(self._channels):
            try:
                cid = self._resolve_channel_id(raw)
            except Exception as e:  # noqa: BLE001 单个频道失败不影响其它
                logger.warning("YouTube 频道解析失败 %s：%s", raw, e)
                continue
            add(cid, self._channel_name(cid) or raw)
            if index + 1 < len(self._channels):
                time.sleep(self._interval)

        if self._use_subscriptions:
            try:
                for cid, name in self._account_subscriptions():
                    add(cid, name)
            except Exception as e:  # noqa: BLE001 读不到订阅不影响手填清单
                logger.warning("读取 YouTube 账号订阅列表失败：%s", e)

        if not found:
            logger.warning(
                "YouTube 没有可采集的频道：填 YOUTUBE_CHANNELS，"
                "或先跑 python -m app login youtube 再同步账号订阅"
            )
        return found

    def _account_subscriptions(self) -> list[tuple[str, str]]:
        """用登录态 cookie 读账号的全部订阅。

        yt-dlp 的 youtube:tab 提取器支持 feed/channels，会自动翻页；
        返回条目里 channel_id 是 UCxxx，channel 是频道名。
        """
        if not self._cookiefile:
            logger.info("未登录 YouTube（python -m app login youtube），跳过账号订阅列表")
            return []

        import yt_dlp  # 延迟导入：yt-dlp 体积大，只在需要时加载

        opts: dict = {
            "quiet": True,
            "no_warnings": True,
            "skip_download": True,
            "extract_flat": True,
            "cookiefile": str(self._cookiefile),
        }
        if self._proxy != "system":
            opts["proxy"] = "" if self._proxy in ("", "direct") else self._proxy

        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(_SUBSCRIPTIONS, download=False)

        result: list[tuple[str, str]] = []
        for entry in (info or {}).get("entries") or []:
            cid = str(entry.get("channel_id") or "").strip()
            if not _CHANNEL_ID.fullmatch(cid):
                continue
            name = str(entry.get("channel") or entry.get("title") or "").strip()
            result.append((cid, name))
        logger.info("YouTube 账号订阅：%d 个频道", len(result))
        return result

    def _resolve_channel_id(self, raw: str) -> str:
        """频道 ID 直接用；@handle / 链接则抓主页解析 channelId。"""
        value = raw.strip()
        if _CHANNEL_ID.fullmatch(value):
            return value
        if "youtube.com" in value and "/channel/" in value:
            if match := _CHANNEL_URL_IN_HTML.search(value):
                return match.group(1)

        url = value if value.startswith(("http://", "https://")) else _HOME + (
            value if value.startswith(("@", "c/", "user/")) else f"@{value}"
        )
        resp = self._client.get(url)
        resp.raise_for_status()
        if match := _CHANNEL_ID_IN_HTML.search(resp.text):
            return match.group(1)
        if match := _CHANNEL_URL_IN_HTML.search(resp.text):
            return match.group(1)
        raise SourceError(f"页面里没找到频道 ID：{url}")

    def _channel_name(self, cid: str) -> str:
        try:
            feed = self._feed(cid)
        except Exception as e:  # noqa: BLE001 拿不到名字就用标识占位
            logger.debug("取 YouTube 频道名失败 %s：%s", cid, e)
            return ""
        return (feed.findtext("atom:title", default="", namespaces=_NS) or "").strip()

    # ---------- 抓取 ----------

    def fetch_range(self, target: str, since: datetime, until: datetime) -> list[RawItem]:
        feed = self._feed(target)
        default_author = (feed.findtext("atom:title", default="", namespaces=_NS) or "").strip()
        items: list[RawItem] = []
        for entry in feed.findall("atom:entry", _NS):
            vid = (entry.findtext("yt:videoId", default="", namespaces=_NS) or "").strip()
            published = (entry.findtext("atom:published", default="", namespaces=_NS) or "").strip()
            if not vid or not published:
                continue
            try:
                when = _local(datetime.fromisoformat(published))
            except ValueError:
                logger.debug("跳过发布时间异常的条目 %s：%s", vid, published)
                continue
            if when < since or when >= until:
                continue

            group = entry.find("media:group", _NS)
            thumbnail = ""
            description = ""
            if group is not None:
                thumb = group.find("media:thumbnail", _NS)
                if thumb is not None:
                    thumbnail = (thumb.get("url") or "").strip()
                description = (
                    group.findtext("media:description", default="", namespaces=_NS) or ""
                ).strip()
            title = (
                entry.findtext("atom:title", default="", namespaces=_NS)
                or (group.findtext("media:title", default="", namespaces=_NS) if group is not None else "")
                or ""
            ).strip()
            author = (
                entry.findtext("atom:author/atom:name", default="", namespaces=_NS) or default_author
            ).strip()

            items.append(RawItem(
                content_id=vid,
                title=title or vid,
                author=author,
                author_id=target,
                url=_WATCH.format(vid=vid),
                published_at=when,
                media_type="video",
                cover=thumbnail,
                description=description,
            ))
        items.sort(key=lambda i: i.published_at)
        return items

    # ---------- 内部 ----------

    def _feed(self, cid: str) -> ET.Element:
        """拉频道 RSS（进程内缓存，discover 与 fetch 共用一次请求）。"""
        if cid in self._feeds:
            return self._feeds[cid]
        resp = self._client.get(_FEED.format(cid=cid))
        if resp.status_code != 200:
            raise SourceError(f"频道 RSS 返回 {resp.status_code}：{cid}")
        try:
            root = ET.fromstring(resp.text)
        except ET.ParseError as e:
            raise SourceError(f"频道 RSS 解析失败：{cid}（{e}）") from e
        self._feeds[cid] = root
        return root

    def close(self) -> None:
        self._client.close()


def _client_opts(proxy: str) -> dict:
    """与 yt-dlp 的代理口径保持一致：direct/空=直连，system=跟随系统，其余=指定代理。"""
    opts: dict = {
        "headers": {"User-Agent": _UA},
        "timeout": 20,
        "follow_redirects": True,
    }
    if proxy in ("", "direct"):
        opts["trust_env"] = False
    elif proxy == "system":
        opts["trust_env"] = True
    else:
        opts["proxy"] = proxy
        opts["trust_env"] = False
    return opts
