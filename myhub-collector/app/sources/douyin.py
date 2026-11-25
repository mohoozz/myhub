"""抖音抓取源：Playwright 驱动已登录的浏览器，读关注列表和作者作品。

为什么不用纯 HTTP：
- 抖音 web 接口要 a_bogus / X-Bogus 签名，算法随前端发版变化，纯 Python 复刻很快就失效；
- 浏览器里页面自己会算签名，我们只拦截响应拿原始 JSON，结构稳定、改动少。

登录态：
- 首次执行 `python -m app login douyin`，在弹出的窗口里扫码；
- Cookie 落在 <DATA_DIR>/browser/douyin 这个独立 profile（不动系统 Chrome 配置），
  之后 sync / collect 复用，不用重复扫码；
- 同时导出 <DATA_DIR>/credentials/douyin.txt（统一目录，给 yt-dlp 兜底下载用）。

抓取：
- 关注列表：打开 https://www.douyin.com/user/self，点页头「关注 N」弹层，
  收 `/user/following/list/` 的响应；
- 作者作品：打开 https://www.douyin.com/user/<sec_uid>，收 `/aweme/v1/web/aweme/post/`
  的响应，按 create_time 判停（置顶作品时间很旧，不参与判停）。

下载：作品 JSON 里 `video.play_addr` 就是现成 mp4，交给 app.downloader.direct
（带 Referer 直下）；图文作品按 image 类型走自包含 HTML。
"""
from __future__ import annotations

import logging
import re
from datetime import datetime
from pathlib import Path

from app import browser, credentials
from app.sources.base import DiscoveredSource, RawItem, Source, SourceError

logger = logging.getLogger(__name__)

_HOME = "https://www.douyin.com/"
_SELF = "https://www.douyin.com/user/self"
_USER_URL = "https://www.douyin.com/user/{sec}"
_VIDEO_URL = "https://www.douyin.com/video/{aid}"

_FOLLOWING_API = "/following/list"
_POST_API = "/aweme/v1/web/aweme/post/"
_DETAIL_API = "/aweme/v1/web/aweme/detail/"
_SEC_UID = re.compile(r"MS4wLjABAAAA[\w-]{5,}")
# 只认真正的登录票据：passport_csrf_token 之类匿名访问也有，拿它判断会误判成已登录
_LOGIN_COOKIES = ("sessionid", "sessionid_ss")

_UA_HINT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"


def _first_url(values) -> str:
    if isinstance(values, list):
        for value in values:
            if isinstance(value, str) and value:
                return value
    elif isinstance(values, str):
        return values
    return ""


def _fmt_duration(ms) -> str:
    try:
        total = int(ms) // 1000
    except (TypeError, ValueError):
        return ""
    if total <= 0:
        return ""
    return f"{total // 60}:{total % 60:02d}"


def parse_following(data: dict) -> list[tuple[str, str]]:
    """解析关注列表接口，返回 [(sec_uid, 昵称)]。"""
    users = data.get("user_list") or data.get("followings") or data.get("data") or []
    if isinstance(users, dict):
        users = users.get("user_list") or users.get("followings") or []
    result: list[tuple[str, str]] = []
    for user in users if isinstance(users, list) else []:
        if not isinstance(user, dict):
            continue
        sec = str(user.get("sec_uid") or user.get("secUid") or "").strip()
        if not _SEC_UID.fullmatch(sec):
            continue
        name = str(user.get("nickname") or user.get("remark_name") or "").strip() or sec
        result.append((sec, name))
    return result


def parse_aweme(aweme: dict) -> RawItem | None:
    """把 aweme/post 里的单条作品转成 RawItem。"""
    if not isinstance(aweme, dict):
        return None
    aid = str(aweme.get("aweme_id") or "").strip()
    if not aid:
        return None

    try:
        published = datetime.fromtimestamp(int(aweme.get("create_time") or 0))
    except (TypeError, ValueError, OSError):
        return None
    if published.year < 2009:
        return None

    author = aweme.get("author") or {}
    video = aweme.get("video") or {}
    images = [
        url
        for url in (_first_url(img.get("url_list")) for img in (aweme.get("images") or []) if isinstance(img, dict))
        if url
    ]
    cover = _first_url((video.get("cover") or {}).get("url_list")) or (images[0] if images else "")

    play = ""
    for key in ("play_addr_h264", "play_addr"):
        play = _first_url((video.get(key) or {}).get("url_list"))
        if play:
            break

    desc = str(aweme.get("desc") or "").strip()
    title = (desc.splitlines()[0].strip() if desc else "") or f"抖音作品 {aid}"
    stats = aweme.get("statistics") or {}

    return RawItem(
        content_id=aid,
        title=title[:200],
        author=str(author.get("nickname") or "").strip() or "抖音作者",
        author_id=str(author.get("sec_uid") or "").strip(),
        url=_VIDEO_URL.format(aid=aid),
        published_at=published,
        media_type="image" if images else "video",
        cover=cover,
        description=desc,
        duration=_fmt_duration(video.get("duration")),
        images=images,
        media_url="" if images else play,
        like_count=int(stats.get("digg_count") or 0),
        comment_count=int(stats.get("comment_count") or 0),
        pinned=bool(aweme.get("is_top")),
    )


def parse_posts(data: dict) -> tuple[list[RawItem], bool]:
    """解析作品列表接口，返回 (条目, 是否还有下一页)。"""
    if not isinstance(data, dict):
        return [], False
    awemes = data.get("aweme_list") or []
    items = [item for item in (parse_aweme(a) for a in awemes if isinstance(a, dict)) if item]
    return items, bool(data.get("has_more"))


class DouyinSource(Source):
    """抖音：浏览器抓列表 + 直链下载。"""

    platform = "douyin"

    def __init__(
        self,
        headless: bool = False,
        interval: float = 1.2,
        proxy: str = "direct",
        profile_dir: Path | None = None,
        max_scrolls: int = 30,
        channel: str = "chrome",
        profile_name: str = "",
        reuse_existing: bool = False,
    ):
        self._headless = headless
        self._interval = max(interval, 0.5)
        self._proxy = proxy
        self._profile = Path(profile_dir) if profile_dir else Path("data/browser/douyin")
        self._max_scrolls = max(int(max_scrolls), 5)
        self._channel = channel
        self._profile_name = profile_name
        self._reuse = reuse_existing

        self._pw = None
        self._ctx = None

    # ---------------- 浏览器生命周期 ----------------
    def _context(self):
        if self._ctx is not None:
            return self._ctx

        try:
            from playwright.sync_api import sync_playwright
        except ImportError as e:  # pragma: no cover - 依赖缺失时给明确提示
            raise SourceError(
                "抖音源需要 Playwright：pip install playwright && python -m playwright install chromium"
            ) from e

        if browser.profile_locked(self._profile):
            raise SourceError(
                f"浏览器正在占用 profile：{self._profile}\n"
                "先完全退出该浏览器（含托盘 / 后台进程）再跑；"
                "或把 DOUYIN_USER_DATA_DIR 留空，改用独立 profile（扫码一次，不打扰日常浏览器）"
            )

        self._profile.mkdir(parents=True, exist_ok=True)
        channel = browser.guess_channel(self._profile, self._channel)
        self._pw = sync_playwright().start()
        try:
            self._ctx = browser.launch_context(
                self._pw, self._profile, self._headless, channel, self._proxy, self._profile_name
            )
        except Exception as e:  # noqa: BLE001 指定通道不可用时退回自带 Chromium
            if self._reuse:
                self._pw.stop()
                self._pw = None
                raise SourceError(
                    f"无法用真实浏览器 profile 启动：{self._profile}（{type(e).__name__}: {e}）\n"
                    "确认浏览器已完全退出；仍然失败就把 DOUYIN_USER_DATA_DIR 留空改用独立 profile"
                ) from e
            logger.warning("用 %s 启动浏览器失败（%s），改用 Playwright 自带 Chromium", channel or "chromium", e)
            self._ctx = browser.launch_context(
                self._pw, self._profile, self._headless, "", self._proxy, self._profile_name
            )

        self._ctx.set_default_timeout(60000)
        return self._ctx

    def _page(self):
        ctx = self._context()
        for page in ctx.pages:
            if not page.is_closed():
                return page
        return ctx.new_page()

    def _check_login(self, page) -> None:
        ctx = self._context()
        if browser.logged_in(ctx, _LOGIN_COOKIES):
            return
        page.goto(_SELF, wait_until="domcontentloaded")
        page.wait_for_timeout(3500)
        if browser.logged_in(ctx, _LOGIN_COOKIES):
            return
        if self._reuse:
            raise SourceError(
                f"这个浏览器 profile 里没有抖音登录态：{self._profile}\n"
                "用它打开 https://www.douyin.com 登录一次，完全关闭浏览器后再重跑"
            )
        raise SourceError(
            "抖音未登录或登录已过期：先执行 `python -m app login douyin` 扫码，"
            f"登录态保存在 {self._profile}"
        )

    def _scroll(self, page) -> None:
        try:
            page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        except Exception:  # noqa: BLE001 页面切换中偶发，忽略
            pass
        try:
            page.mouse.move(720, 520)
            page.mouse.wheel(0, 2800)
            page.keyboard.press("End")
        except Exception:  # noqa: BLE001
            pass

    def close(self) -> None:
        if self._ctx is not None:
            try:
                credentials.save_cookies(self._ctx.cookies(), "douyin")
            except Exception as e:  # noqa: BLE001 导出失败不影响主流程
                logger.debug("导出抖音 Cookie 失败：%s", e)
        if self._ctx is not None:
            try:
                self._ctx.close()
            finally:
                self._ctx = None
        if self._pw is not None:
            try:
                self._pw.stop()
            finally:
                self._pw = None

    # ---------------- 抓取 ----------------
    def discover_sources(self) -> list[DiscoveredSource]:
        page = self._page()
        self._check_login(page)

        responses: list = []
        page.on("response", lambda r: responses.append(r) if _FOLLOWING_API in r.url else None)

        # PC 端关注列表没有独立的 tab，点个人中心页头的「关注 N」才会请求 following/list
        page.goto(_SELF, wait_until="domcontentloaded")
        page.wait_for_timeout(3000)
        self._open_following(page)

        for _ in range(12):  # 等首个响应到
            if responses:
                break
            page.wait_for_timeout(500)

        found: dict[str, str] = {}
        for _ in range(self._max_scrolls):
            pairs, has_more = self._drain_following(responses)
            for sec, name in pairs:
                found.setdefault(sec, name)
            if not has_more:
                break
            self._scroll_modal(page)
            page.wait_for_timeout(1200)

        if not found:
            raise SourceError(
                "抖音关注列表为空：确认账号确实关注了人，或页面被验证码拦住"
                "（可重跑 python -m app douyin-login 刷新登录态）"
            )

        logger.info("抖音关注列表：%d 个作者", len(found))
        return [DiscoveredSource(name=name, target=sec) for sec, name in found.items()]

    def fetch_range(self, target: str, since: datetime, until: datetime) -> list[RawItem]:
        page = self._page()
        self._check_login(page)

        responses: list = []
        handler = lambda r: responses.append(r) if _POST_API in r.url else None  # noqa: E731
        page.on("response", handler)

        url = _USER_URL.format(sec=target)
        page.goto(url, wait_until="domcontentloaded")
        page.wait_for_timeout(2500)

        items: dict[str, RawItem] = {}
        stagnant = 0
        try:
            for _ in range(self._max_scrolls):
                before = len(items)
                has_more = True
                for batch, more in self._drain_posts(responses):
                    for item in batch:
                        items.setdefault(item.content_id, item)
                    has_more = has_more and more

                oldest = min(
                    (i.published_at for i in items.values() if not i.pinned),
                    default=None,
                )
                if oldest is not None and oldest < since:
                    break
                if not has_more and items:
                    break

                if len(items) == before:
                    stagnant += 1
                    if stagnant >= 3:
                        break
                else:
                    stagnant = 0

                self._scroll(page)
                page.wait_for_timeout(1200)
        finally:
            try:
                page.remove_listener("response", handler)
            except Exception:  # noqa: BLE001
                pass

        picked = [
            item for item in items.values() if since <= item.published_at < until
        ]
        picked.sort(key=lambda i: i.published_at)
        return picked

    def fetch_detail(self, content_id: str) -> RawItem | None:
        """列表接口已经给了正文/图片，下载阶段不需要再开浏览器补详情。"""
        return None

    def fetch_one(self, aweme_id: str) -> RawItem | None:
        """按作品号打开视频页，截获详情接口返回单条 RawItem（链接下载用）。

        抖音 web 接口要 a_bogus 签名，纯 HTTP 拿不到；这里让页面自己算，
        我们只读它发出的响应，和抓作者作品是同一套思路。
        """
        page = self._page()
        self._check_login(page)
        hits: list = []
        handler = lambda r: hits.append(r) if _DETAIL_API in (r.url or "") else None  # noqa: E731
        page.on("response", handler)
        try:
            page.goto(_VIDEO_URL.format(aid=aweme_id), wait_until="domcontentloaded")
            page.wait_for_timeout(3500)
        finally:
            try:
                page.remove_listener("response", handler)
            except Exception:  # noqa: BLE001
                pass

        for resp in hits:
            try:
                data = resp.json()
            except Exception:  # noqa: BLE001 非 JSON 响应直接跳过
                continue
            aweme = data.get("aweme_detail")
            if not isinstance(aweme, dict):
                details = data.get("aweme_details") or []
                aweme = details[0] if details and isinstance(details[0], dict) else None
            if aweme:
                item = parse_aweme(aweme)
                if item is not None:
                    return item
        return None

    # ---------------- 响应解析 ----------------
    def _drain_following(self, responses: list) -> tuple[list[tuple[str, str]], bool]:
        """抽干关注列表响应，返回 ([(sec_uid, 昵称)], 是否还有下一页)。"""
        result: list[tuple[str, str]] = []
        has_more = False
        while responses:
            resp = responses.pop(0)
            try:
                data = resp.json()
            except Exception:  # noqa: BLE001 非 JSON / 已失效的响应直接跳过
                continue
            result.extend(parse_following(data))
            if data.get("has_more"):
                has_more = True
        return result, has_more

    def _drain_posts(self, responses: list) -> list[tuple[list[RawItem], bool]]:
        result: list[tuple[list[RawItem], bool]] = []
        while responses:
            resp = responses.pop(0)
            try:
                result.append(parse_posts(resp.json()))
            except Exception:  # noqa: BLE001
                continue
        return result

    @staticmethod
    def _open_following(page) -> bool:
        """打开页头的「关注 N」弹层（douyin 用 data-e2e 标记这个入口）。"""
        try:
            entry = page.query_selector('[data-e2e="user-info-follow"]')
            if entry:
                entry.evaluate("e => e.click()")
                return True
        except Exception:  # noqa: BLE001
            pass
        try:
            page.get_by_text(re.compile(r"^\s*关注\s*[\d.万亿]+\s*$")).first.click(timeout=8000)
            return True
        except Exception:  # noqa: BLE001
            return False

    @staticmethod
    def _scroll_modal(page) -> None:
        """关注列表在弹层里滚动，滚动窗口没用，得滚最外层可滚容器。"""
        try:
            page.evaluate(
                """() => {
                    const cands = [...document.querySelectorAll('div')]
                        .filter(d => d.scrollHeight > d.clientHeight + 50 && d.clientHeight > 200);
                    const target = cands.sort((a, b) => b.scrollHeight - a.scrollHeight)[0];
                    if (target) target.scrollTop = target.scrollHeight;
                }"""
            )
        except Exception:  # noqa: BLE001 弹层关闭/切换中偶发
            pass



