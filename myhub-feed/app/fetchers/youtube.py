"""YouTube 抓取器：

- 视频抓取：频道公开 RSS（无需 Key，已实测）——注意只含最近 ~15 条，日常增量足够。
- 订阅列表：InnerTube 内部接口（youtubei/v1/browse, browseId=FEchannels）+ SAPISIDHASH 鉴权，
  与 B 站一样贴 Cookie 即可使用。InnerTube 属非公开接口，返回结构可能随版本变化，
  解析处做了防御性处理，失败时会抛出包含结构线索的错误便于修复。

Cookie 获取：浏览器登录 youtube.com，F12 复制请求头 Cookie（需要 SAPISID 和 __Secure-3PAPISID）。
"""
import hashlib
import time
import xml.etree.ElementTree as ET
from datetime import datetime
from typing import Callable

import httpx

from app.fetchers.base import DiscoveredSource, Fetcher, RawItem

_RSS = "https://www.youtube.com/feeds/videos.xml"
_BROWSE = "https://www.youtube.com/youtubei/v1/browse"
_ORIGIN = "https://www.youtube.com"
_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
# InnerTube WEB 客户端版本，YouTube 对旧版本有一定容忍；若接口异常需更新此值
_CLIENT_VERSION = "2.20260812.01.00"
_NS = {"atom": "http://www.w3.org/2005/Atom", "yt": "http://www.youtube.com/xml/schemas/2015"}
_MRSS = "{http://search.yahoo.com/mrss/}"


class YouTubeApiError(Exception):
    pass


class YouTubeFetcher(Fetcher):
    platform = "youtube"

    def __init__(self, cookie: str = ""):
        self._cookie = cookie
        self._cookies = _parse_cookie(cookie)
        self._client = httpx.Client(
            headers={"User-Agent": _UA, "Cookie": cookie}, timeout=15, follow_redirects=True
        )

    # ---------- 订阅列表（InnerTube） ----------

    def discover_sources(self) -> list[DiscoveredSource]:
        """拉取本账号订阅的频道列表。"""
        if not self._cookies.get("SAPISID") and not self._cookies.get("__Secure-3PAPISID"):
            raise YouTubeApiError(
                "拉取 YouTube 订阅列表需要登录 Cookie（含 SAPISID / __Secure-3PAPISID），"
                "请配置 YOUTUBE_COOKIE"
            )
        sources: list[DiscoveredSource] = []
        continuation: str | None = None
        for _ in range(20):  # 分页兜底
            page, continuation = self._channels_page(continuation)
            sources.extend(page)
            if not continuation:
                break
            time.sleep(1)
        return sources

    def _channels_page(self, continuation: str | None) -> tuple[list[DiscoveredSource], str | None]:
        body: dict = {"context": _innertube_context()}
        if continuation:
            body["continuation"] = continuation
        else:
            body["browseId"] = "FEchannels"
        resp = self._client.post(_BROWSE, json=body, headers=self._auth_headers())
        if resp.status_code != 200:
            raise YouTubeApiError(f"InnerTube HTTP {resp.status_code}: {resp.text[:200]}")
        payload = resp.json()
        if "contents" not in payload and "onResponseReceivedActions" not in payload:
            # 鉴权失败/被拦截时 YouTube 常返回 200 但空响应，打印上下文便于定位
            import json as _json
            raise YouTubeApiError(
                f"InnerTube 响应无内容（鉴权失败或请求被拒）。"
                f"responseContext: {_json.dumps(payload.get('responseContext', {}), ensure_ascii=False)[:400]}"
            )
        return _parse_channels(payload)

    def _auth_headers(self) -> dict:
        # SAPISIDHASH：优先 SAPISID，否则用 __Secure-3PAPISID（两者算法相同，前缀名不变）
        sid = self._cookies.get("SAPISID") or self._cookies.get("__Secure-3PAPISID", "")
        return {
            "Authorization": f"SAPISIDHASH {_sapisid_hash(sid)}",
            "X-Origin": _ORIGIN,
            "X-Youtube-Client-Name": "1",
            "X-Youtube-Client-Version": _CLIENT_VERSION,
        }

    # ---------- 视频抓取（RSS） ----------

    def fetch_first(self, target: str, limit: int) -> list[RawItem]:
        return self._fetch(target)[:limit]

    def fetch_incremental(self, target: str, exists: Callable[[str], bool]) -> list[RawItem]:
        return [it for it in self._fetch(target) if not exists(it.content_id)]

    def _fetch(self, channel_id: str) -> list[RawItem]:
        resp = self._client.get(_RSS, params={"channel_id": channel_id})
        resp.raise_for_status()
        root = ET.fromstring(resp.text)

        author = ""
        items: list[RawItem] = []
        for entry in root.findall("atom:entry", _NS):
            vid = entry.findtext("yt:videoId", "", _NS)
            title = entry.findtext("atom:title", "", _NS)
            if not author:
                name_el = entry.find("atom:author/atom:name", _NS)
                author = name_el.text if name_el is not None and name_el.text else ""
            published = entry.findtext("atom:published", "", _NS)
            thumb, desc = "", ""
            if (media := entry.find(f"{_MRSS}group")) is not None:
                if (t := media.find(f"{_MRSS}thumbnail")) is not None:
                    thumb = t.get("url", "")
                desc = media.findtext(f"{_MRSS}description") or ""
            items.append(RawItem(
                content_id=vid,
                title=title,
                author=author,
                cover=thumb,
                description=desc,
                url=f"https://www.youtube.com/watch?v={vid}",
                published_at=datetime.fromisoformat(published.replace("Z", "+00:00")).replace(tzinfo=None),
            ))
        items.sort(key=lambda x: x.published_at, reverse=True)
        return items


# ---------- 辅助 ----------

def _parse_cookie(cookie: str) -> dict[str, str]:
    out = {}
    for part in cookie.split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def _sapisid_hash(sapisid: str) -> str:
    ts = int(time.time())
    digest = hashlib.sha1(f"{ts} {sapisid} {_ORIGIN}".encode()).hexdigest()
    return f"{ts}_{digest}"


def _innertube_context() -> dict:
    return {"client": {
        "clientName": "WEB", "clientVersion": _CLIENT_VERSION, "hl": "zh-CN",
        "utcOffsetMinutes": -480,
    }}


def _parse_channels(payload: dict) -> tuple[list[DiscoveredSource], str | None]:
    """从 FEchannels 响应中递归扫描 channelRenderer 与翻页 token。

    InnerTube 页面结构经常改版，固定路径解析容易失效，改为全树扫描更稳。
    """
    sources: list[DiscoveredSource] = []
    seen: set[str] = set()
    continuations: list[str] = []

    def walk(node):
        if isinstance(node, dict):
            if (ch := node.get("channelRenderer")) and isinstance(ch, dict):
                cid = ch.get("channelId", "")
                if cid and cid not in seen:
                    seen.add(cid)
                    sources.append(DiscoveredSource(name=_text(ch.get("title")), target=cid))
            if (cont := node.get("continuationItemRenderer")) and isinstance(cont, dict):
                token = (cont.get("continuationEndpoint", {})
                         .get("continuationCommand", {}).get("token"))
                if token:
                    continuations.append(token)
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(payload.get("contents", payload))
    if not sources:
        raise YouTubeApiError(
            f"未解析到任何频道（可能 Cookie 已失效）；顶层 keys: {list(payload.keys())}"
        )
    return sources, (continuations[-1] if continuations else None)


def _text(field) -> str:
    """InnerTube 文本字段兼容 simpleText / runs 两种形态。"""
    if isinstance(field, dict):
        if "simpleText" in field:
            return field["simpleText"]
        if isinstance(field.get("runs"), list):
            return "".join(r.get("text", "") for r in field["runs"])
    return ""
