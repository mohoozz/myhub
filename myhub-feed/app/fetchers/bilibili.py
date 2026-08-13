"""B 站抓取器（接口已实测验证 2026-08）：

- 登录校验/取自身 mid:  GET x/web-interface/nav
- 关注列表:            GET x/relation/followings（仅自己的关注可拉全量）
- UP 主投稿:           GET x/polymer/web-dynamic/v1/feed/space（动态流，免 wbi 签名）

注意：x/space/wbi/arc/search 风控严格（-403），不要使用。
"""
import time
from datetime import datetime
from typing import Callable

import httpx

from app.fetchers.base import DiscoveredSource, Fetcher, RawItem

_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
       "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")

_NAV = "https://api.bilibili.com/x/web-interface/nav"
_FOLLOWINGS = "https://api.bilibili.com/x/relation/followings"
_FEED_SPACE = "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/space"

_MAX_PAGES = 5  # 翻页兜底上限，防异常无限翻页


class BiliApiError(Exception):
    pass


class BilibiliFetcher(Fetcher):
    platform = "bilibili"

    def __init__(self, cookie: str):
        if not cookie:
            raise ValueError("缺少 B 站 Cookie（配置 BILI_COOKIE 或 .env）")
        self._client = httpx.Client(
            headers={"User-Agent": _UA, "Referer": "https://www.bilibili.com", "Cookie": cookie},
            timeout=15,
        )
        self._mid: int | None = None

    # ---------- 账号 ----------

    def _my_mid(self) -> int:
        if self._mid is None:
            data = self._get(_NAV)
            if data.get("code") != 0 or not data["data"].get("mid"):
                raise BiliApiError(f"Cookie 无效或未登录: code={data.get('code')} {data.get('message')}")
            self._mid = int(data["data"]["mid"])
        return self._mid

    def discover_sources(self) -> list[DiscoveredSource]:
        """拉取本账号全部关注 UP 主作为订阅源。"""
        vmid = self._my_mid()
        sources: list[DiscoveredSource] = []
        pn = 1
        while True:
            data = self._get(_FOLLOWINGS, {
                "vmid": vmid, "pn": pn, "ps": 50, "order": "desc", "order_type": "attention",
            })
            if data.get("code") != 0:
                raise BiliApiError(f"关注列表接口错误: code={data.get('code')} {data.get('message')}")
            lst = data["data"].get("list") or []
            sources += [DiscoveredSource(name=u["uname"], target=str(u["mid"])) for u in lst]
            if not lst or len(sources) >= data["data"].get("total", 0):
                return sources
            pn += 1
            time.sleep(1)

    # ---------- 抓取 ----------

    def fetch_first(self, target: str, limit: int) -> list[RawItem]:
        items: list[RawItem] = []
        offset = ""
        for _ in range(_MAX_PAGES):
            if len(items) >= limit:
                break
            page, offset, has_more = self._feed_page(target, offset)
            items.extend(page)
            if not has_more or not offset:
                break
            time.sleep(1)
        return items[:limit]

    def fetch_incremental(self, target: str, exists: Callable[[str], bool]) -> list[RawItem]:
        items: list[RawItem] = []
        offset = ""
        for _ in range(_MAX_PAGES):
            page, offset, has_more = self._feed_page(target, offset)
            stop = False
            for it in page:
                if exists(it.content_id):
                    stop = True
                    break
                items.append(it)
            if stop or not has_more or not offset:
                break
            time.sleep(1)
        return items

    # ---------- 内部 ----------

    def _feed_page(self, mid: str, offset: str) -> tuple[list[RawItem], str, bool]:
        params: dict = {"host_mid": mid, "timezone_offset": -480}
        if offset:
            params["offset"] = offset
        data = self._get(_FEED_SPACE, params)
        if data.get("code") != 0:
            raise BiliApiError(f"动态流接口错误: code={data.get('code')} {data.get('message')}")

        items = []
        for entry in data["data"].get("items") or []:
            if entry.get("type") != "DYNAMIC_TYPE_AV":  # 仅视频投稿，图文动态后续再收
                continue
            archive = entry["modules"]["module_dynamic"]["major"]["archive"]
            pub_ts = entry["modules"]["module_author"].get("pub_ts") or "0"
            items.append(RawItem(
                content_id=archive["bvid"],
                title=archive["title"],
                author="",  # 由 service 层填订阅源名
                cover=archive.get("cover", ""),
                description=archive.get("desc", ""),
                url=f"https://www.bilibili.com/video/{archive['bvid']}",
                published_at=datetime.fromtimestamp(int(pub_ts)),
            ))
        d = data["data"]
        return items, d.get("offset") or "", bool(d.get("has_more"))

    def _get(self, url: str, params: dict | None = None) -> dict:
        resp = self._client.get(url, params=params)
        resp.raise_for_status()
        return resp.json()
