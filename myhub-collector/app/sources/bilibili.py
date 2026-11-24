"""B 站抓取源（接口已实测验证）：

- 登录校验/取自身 mid:  GET x/web-interface/nav
- 关注列表（自己全部）:   GET x/relation/followings      （仅登录账号可拉全量）
- UP 主动态流:            GET x/polymer/web-dynamic/v1/feed/space （免 wbi 签名）

注意：
- x/space/wbi/arc/search 风控严格（-403），不要使用；动态流已能覆盖视频投稿。
- 动态流一次请求即含视频/图文/纯文本，按 pub_ts 过滤前一天成本最低。
"""
from __future__ import annotations

import logging
import time
from datetime import datetime

import httpx

from app.sources.base import DiscoveredSource, RawItem, Source, SourceError

logger = logging.getLogger(__name__)

_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
)

_NAV = "https://api.bilibili.com/x/web-interface/nav"
_FOLLOWINGS = "https://api.bilibili.com/x/relation/followings"
_FEED_SPACE = "https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/space"
_DETAIL = "https://api.bilibili.com/x/polymer/web-dynamic/v1/detail"


class BilibiliSource(Source):
    platform = "bilibili"

    def __init__(self, cookie: str, interval: float = 1.2, max_pages: int = 5):
        if not cookie:
            raise SourceError("缺少 B 站 Cookie")
        self._interval = max(interval, 0.5)
        self._max_pages = max(max_pages, 1)
        self._client = httpx.Client(
            headers={
                "User-Agent": _UA,
                "Referer": "https://www.bilibili.com",
                "Cookie": cookie,
            },
            timeout=20,
            follow_redirects=True,
            trust_env=False,  # B 站国内直连，避开系统代理拖慢
        )
        self._mid: int | None = None

    # ---------- 账号 ----------

    def my_mid(self) -> int:
        if self._mid is None:
            data = self._get(_NAV)
            if data.get("code") != 0 or not (data.get("data") or {}).get("mid"):
                raise SourceError(
                    f"Cookie 无效或未登录：code={data.get('code')} {data.get('message')}"
                )
            self._mid = int(data["data"]["mid"])
        return self._mid

    def discover_sources(self) -> list[DiscoveredSource]:
        """拉取本账号全部关注的 UP 主。"""
        vmid = self.my_mid()
        sources: list[DiscoveredSource] = []
        page = 1
        while True:
            data = self._get(_FOLLOWINGS, {
                "vmid": vmid, "pn": page, "ps": 50, "order": "desc", "order_type": "attention",
            })
            if data.get("code") != 0:
                raise SourceError(
                    f"关注列表接口错误：code={data.get('code')} {data.get('message')}"
                )
            payload = data.get("data") or {}
            batch = payload.get("list") or []
            sources += [
                DiscoveredSource(name=u.get("uname") or str(u.get("mid")), target=str(u["mid"]))
                for u in batch
                if u.get("mid")
            ]
            total = int(payload.get("total") or 0)
            if not batch or len(sources) >= total:
                break
            page += 1
            time.sleep(self._interval)
        return sources

    # ---------- 抓取 ----------

    def fetch_range(self, target: str, since: datetime, until: datetime) -> list[RawItem]:
        items: list[RawItem] = []
        seen: set[str] = set()
        offset = ""
        for _ in range(self._max_pages):
            page, offset, has_more = self._feed_page(target, offset)
            reached_old = False
            for item in page:
                if item.published_at < since:
                    # 置顶动态的 pub_ts 往往是很久以前，不能用它判断「已翻到底」
                    if not item.pinned:
                        reached_old = True
                    continue
                if item.published_at >= until:
                    continue
                if item.content_id in seen:
                    continue
                seen.add(item.content_id)
                items.append(item)
            if reached_old or not has_more or not offset:
                break
            time.sleep(self._interval)
        return items

    # ---------- 内部 ----------

    def _feed_page(self, mid: str, offset: str) -> tuple[list[RawItem], str, bool]:
        params: dict = {"host_mid": mid, "timezone_offset": -480}
        if offset:
            params["offset"] = offset
        referer = f"https://space.bilibili.com/{mid}/dynamic"
        data = self._get(_FEED_SPACE, params, referer=referer)
        code = data.get("code")
        if code == -352:
            raise SourceError(
                "动态流被风控（-352）：Cookie 需要浏览器整段值（buvid3 / _uuid / b_nut 等），"
                "只填 SESSDATA 通常不够；可稍后重试或降低抓取频率"
            )
        if code != 0:
            raise SourceError(f"动态流接口错误：code={code} {data.get('message')}")
        payload = data.get("data") or {}
        items: list[RawItem] = []
        for entry in payload.get("items") or []:
            if (item := parse_entry(entry)) is not None:
                items.append(item)
        return items, str(payload.get("offset") or ""), bool(payload.get("has_more"))

    def fetch_detail(self, dyn_id: str) -> RawItem | None:
        """按动态号取单条详情，用于补齐动态流里缺失的正文 / 图片。"""
        try:
            data = self._get(
                _DETAIL,
                {"id": dyn_id, "features": "itemOpusStyle"},
                referer=f"https://t.bilibili.com/{dyn_id}",
            )
        except SourceError as e:
            logger.debug("详情接口失败 %s: %s", dyn_id, e)
            return None
        if data.get("code") != 0:
            return None
        entry = (data.get("data") or {}).get("item") or {}
        return parse_entry(entry)

    def _get(self, url: str, params: dict | None = None, referer: str | None = None) -> dict:
        last_error: Exception | None = None
        headers = {"Referer": referer} if referer else None
        for attempt in range(3):
            try:
                resp = self._client.get(url, params=params, headers=headers)
                resp.raise_for_status()
                return resp.json()
            except Exception as e:  # noqa: BLE001
                last_error = e
                logger.debug("请求失败（第 %d 次）%s: %s", attempt + 1, url, e)
                time.sleep(1.5 * (attempt + 1))
        raise SourceError(f"请求 {url} 失败：{last_error}")

    def close(self) -> None:
        self._client.close()


# ---------------- 解析 ----------------

def emotes_of(*containers: dict | None) -> dict[str, str]:
    """从 rich_text_nodes 抽出表情映射：[名称] -> 图标 URL（正文里只留了文字，图标要另取）。"""
    found: dict[str, str] = {}
    for container in containers:
        nodes = (container or {}).get("rich_text_nodes") or []
        for node in nodes:
            if (node.get("type") or "") != "RICH_TEXT_NODE_TYPE_EMOJI":
                continue
            emoji = node.get("emoji") or {}
            text = str(node.get("text") or emoji.get("text") or "").strip()
            icon = str(emoji.get("icon_url") or node.get("icon_url") or "")
            if text and icon:
                found[text] = icon
    return found


def parse_entry(entry: dict) -> RawItem | None:
    """把动态流的一条 entry 解析成 RawItem；转发/无法识别的类型返回 None。"""
    dyn_type = entry.get("type") or ""
    if dyn_type == "DYNAMIC_TYPE_FORWARD":
        return None  # 转发内容归属原作者，容易被判重复，一期不收

    modules = entry.get("modules") or {}
    author_mod = modules.get("module_author") or {}
    dynamic_mod = modules.get("module_dynamic") or {}
    major = dynamic_mod.get("major") or {}
    stat = modules.get("module_stat") or {}

    pub_ts = int(author_mod.get("pub_ts") or entry.get("pub_ts") or 0)
    if not pub_ts:
        return None

    dyn_id = str(entry.get("id_str") or entry.get("id") or "")
    if not dyn_id:
        return None

    author = str(author_mod.get("name") or "")
    author_id = str(author_mod.get("mid") or "")
    desc = str((dynamic_mod.get("desc") or {}).get("text") or "").strip()
    # 新版 opus 动态正文放在 major.opus.summary.text（此时 desc 为空），图文动态取这里
    if not desc:
        desc = str(
            (((major.get("opus") or {}).get("summary") or {}).get("text")) or ""
        ).strip()
    like = int(((stat.get("like") or {}).get("count") or 0))
    comment = int(((stat.get("comment") or {}).get("count") or 0))
    tag_text = str((modules.get("module_tag") or {}).get("text") or "")
    emotes = emotes_of(dynamic_mod.get("desc"), (major.get("opus") or {}).get("summary"))
    common = {
        "author": author,
        "author_id": author_id,
        "like_count": like,
        "comment_count": comment,
        "published_at": datetime.fromtimestamp(pub_ts),
        "pinned": "置顶" in tag_text,
    }

    # 1) 视频投稿
    if (archive := major.get("archive")) and archive.get("bvid"):
        return RawItem(
            content_id=str(archive["bvid"]),
            title=str(archive.get("title") or ""),
            url=f"https://www.bilibili.com/video/{archive['bvid']}",
            cover=str(archive.get("cover") or ""),
            description=str(archive.get("desc") or desc),
            duration=str(archive.get("duration_text") or ""),
            media_type="video",
            **common,
        )

    # 2) 图文（draw 为旧结构，opus 为新结构）
    images: list[str] = []
    title = ""
    if draw := major.get("draw"):
        images = [str(i.get("src")) for i in draw.get("items") or [] if i.get("src")]
    if opus := major.get("opus"):
        images = images or [str(p.get("url")) for p in opus.get("pics") or [] if p.get("url")]
        title = str(opus.get("title") or "")
    if images:
        return RawItem(
            content_id=dyn_id,
            title=title or (desc[:60] or "图文动态"),
            url=f"https://t.bilibili.com/{dyn_id}",
            cover=images[0],
            images=images,
            emotes=emotes,
            media_type="image",
            description=desc,
            **common,
        )

    # 3) 专栏
    if article := major.get("article"):
        covers = article.get("covers") or []
        return RawItem(
            content_id=str(article.get("id") or dyn_id),
            title=str(article.get("title") or "专栏"),
            url=str(article.get("jump_url") or f"https://t.bilibili.com/{dyn_id}"),
            cover=str(covers[0]) if covers else "",
            emotes=emotes,
            media_type="text",
            description=desc,
            **common,
        )

    # 4) 纯文本动态
    if desc or dyn_type == "DYNAMIC_TYPE_WORD":
        return RawItem(
            content_id=dyn_id,
            title=desc[:60] or "文字动态",
            url=f"https://t.bilibili.com/{dyn_id}",
            emotes=emotes,
            media_type="text",
            description=desc,
            **common,
        )

    return None
