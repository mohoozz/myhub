"""抖音抓取器：Playwright + 系统 Edge 渲染用户主页，拦截 aweme/post API 响应取数据。

为什么不是 yt-dlp：2026 版 yt-dlp 已移除抖音用户主页支持（仅剩单视频），
且抖音网页接口带 a_bogus 签名，自实现成本高。浏览器内页面自己发出带签名的
API 请求，这里只监听响应，零签名实现。

Cookie：可选。不登录即可抓公开主页；若遇验证码/风控，配置 DOUYIN_COOKIE，
或先用浏览器 profile 人工登录一次（profile 持久化在 data/browser_profile/douyin）。
"""
import json
from datetime import datetime
from typing import Callable

from playwright.sync_api import sync_playwright

from app.fetchers.base import Fetcher, RawItem

_API_MARK = "/aweme/v1/web/aweme/post/"  # 用户主页视频列表 API
_MAX_SCROLLS = 30                        # 滚动兜底上限（每屏约 18 条）


class DouyinApiError(Exception):
    pass


class DouyinFetcher(Fetcher):
    platform = "douyin"

    def __init__(self, cookie: str = "", profile_dir: str = "data/browser_profile/douyin"):
        self._cookie = cookie
        self._profile_dir = profile_dir

    # ---------- 抓取 ----------

    def fetch_first(self, target: str, limit: int) -> list[RawItem]:
        return self._fetch(target, max_items=limit, exists=None)

    def fetch_incremental(self, target: str, exists: Callable[[str], bool]) -> list[RawItem]:
        return self._fetch(target, max_items=200, exists=exists)

    def _fetch(self, target: str, max_items: int, exists: Callable[[str], bool] | None) -> list[RawItem]:
        items: dict[str, RawItem] = {}  # aweme_id -> item，dict 保持插入序（API 按时间倒序返回）

        def on_response(resp) -> None:
            if _API_MARK not in resp.url:
                return
            try:
                data = resp.json()
            except Exception:  # noqa: BLE001 非 JSON 响应直接忽略
                return
            for aweme in data.get("aweme_list") or []:
                if item := _parse_aweme(aweme):
                    items[item.content_id] = item

        with sync_playwright() as p:
            ctx = _launch(p, self._profile_dir)
            try:
                if self._cookie:
                    ctx.add_cookies(_to_playwright_cookies(self._cookie))
                page = ctx.new_page()
                page.on("response", on_response)
                page.goto(target, wait_until="domcontentloaded", timeout=30000)
                page.wait_for_timeout(3000)

                if not items:
                    raise DouyinApiError(
                        f"首屏未获取到视频列表（可能被风控或需要登录），页面标题: {page.title()!r}"
                    )

                last_height = 0
                for _ in range(_MAX_SCROLLS):
                    if len(items) >= max_items:
                        break
                    # 增量模式：最近几条里出现已入库条目 → 更早的都是旧数据，停止滚动
                    if exists and any(exists(cid) for cid in list(items)[-5:]):
                        break
                    page.mouse.wheel(0, 3000)
                    page.wait_for_timeout(1500)
                    height = page.evaluate("document.body.scrollHeight")
                    if height == last_height:
                        break
                    last_height = height
            finally:
                ctx.close()

        out = sorted(items.values(), key=lambda x: x.published_at, reverse=True)
        return out[:max_items]


# ---------- 解析 ----------

def _parse_aweme(aweme: dict) -> RawItem | None:
    aid = aweme.get("aweme_id")
    if not aid:
        return None
    cover = ""
    if urls := (aweme.get("video") or {}).get("cover", {}).get("url_list"):
        cover = urls[0]
    ts = int(aweme.get("create_time") or 0)
    return RawItem(
        content_id=str(aid),
        title=aweme.get("desc") or "(无标题)",
        author=(aweme.get("author") or {}).get("nickname", ""),
        cover=cover,
        description=aweme.get("desc") or "",
        url=f"https://www.douyin.com/video/{aid}",
        published_at=datetime.fromtimestamp(ts) if ts else datetime.now(),
    )


def _launch(p, profile_dir: str):
    """优先复用系统 Edge（更真实的指纹），无 Edge 则回退内置 Chromium。"""
    for kwargs in ({"channel": "msedge"}, {}):
        try:
            return p.chromium.launch_persistent_context(
                profile_dir, headless=True,
                viewport={"width": 1280, "height": 900}, **kwargs,
            )
        except Exception:  # noqa: BLE001
            continue
    raise DouyinApiError("无法启动浏览器（Edge / Chromium 均不可用）")


def _to_playwright_cookies(cookie: str) -> list[dict]:
    out = []
    for part in cookie.split(";"):
        if "=" in part:
            k, v = part.split("=", 1)
            out.append({
                "name": k.strip(), "value": v.strip(),
                "domain": ".douyin.com", "path": "/",
            })
    return out


__all__ = ["DouyinFetcher", "DouyinApiError", "json"]  # json 供未来扩展解析用
