"""B 站「列表型」抓取源：稍后观看 / 默认收藏夹。

和「关注 UP 主动态」不同，这两个是**待清空的队列**：

- 抓取不看日期区间，列表里有什么就抓什么（首次运行会把存量全部入库）；
- 下载成功后从列表里取消掉，下次不会重复下载；
- 平台标识 ``bili_watchlater`` / ``bili_favorite``，落盘前缀 BiliWL / BiliFav。

接口（按 bilibili-API-collect 的文档实现，写操作都要 csrf=bili_jct）：

- 稍后观看列表: GET  x/v2/history/toview
- 移出稍后观看: POST x/v2/history/toview/del          (aid, csrf)
- 收藏夹清单:   GET  x/v3/fav/folder/created/list-all  (up_mid，取默认收藏夹)
- 收藏夹内容:   GET  x/v3/fav/resource/list            (media_id, pn, ps<=20)
- 收藏内容 id:  GET  x/v3/fav/resource/ids             (取消前拿 aid 用，一次拿全)
- 取消收藏:     POST x/v3/fav/resource/batch-del       (resources=aid:2,..., media_id, csrf)
"""
from __future__ import annotations

import logging
import time
from datetime import datetime

from app.sources.base import DiscoveredSource, RawItem, SourceError
from app.sources.bilibili import BilibiliSource
from app.utils import fmt_duration

logger = logging.getLogger(__name__)

_TOVIEW = "https://api.bilibili.com/x/v2/history/toview"
_TOVIEW_DEL = "https://api.bilibili.com/x/v2/history/toview/del"
_FAV_FOLDERS = "https://api.bilibili.com/x/v3/fav/folder/created/list-all"
_FAV_LIST = "https://api.bilibili.com/x/v3/fav/resource/list"
_FAV_IDS = "https://api.bilibili.com/x/v3/fav/resource/ids"
_FAV_DEL = "https://api.bilibili.com/x/v3/fav/resource/batch-del"

_WATCHLATER_REFERER = "https://www.bilibili.com/watchlater/"


class _BilibiliListSource(BilibiliSource):
    """列表型平台公共部分：一个固定「订阅源」+ 全量抓取 + 下载后清理。"""

    platform = ""
    target = ""      # 订阅表里的 target（固定值，账号只有一个列表）
    list_title = ""

    def discover_sources(self) -> list[DiscoveredSource]:
        self.my_mid()  # 顺带校验登录态，Cookie 失效时直接报错
        return [DiscoveredSource(name=self.list_title, target=self.target)]

    def fetch_range(self, target: str, since: datetime, until: datetime) -> list[RawItem]:
        """列表型平台忽略日期区间：把当前列表里的内容全部返回，交给入库去重。"""
        return self.list_items()

    def list_items(self) -> list[RawItem]:
        raise NotImplementedError

    def prune(self, content_ids: list[str]) -> int:
        """把已下载的内容从列表里取消，返回实际移除条数。"""
        raise NotImplementedError

    # ---------- 内部 ----------

    def _csrf(self) -> str:
        token = self.cookie_value("bili_jct")
        if not token:
            raise SourceError(
                "登录态里没有 bili_jct（CSRF Token），无法取消收藏；"
                "先跑 python -m app login bilibili 重新登录"
            )
        return token


def _video_item(
    *,
    bvid: str,
    title: str,
    cover: str,
    description: str,
    duration: int,
    published_at: int | None,
    author: str,
    author_id: str,
) -> RawItem:
    """列表里的视频行 → RawItem（媒体类型统一是视频，下载走 yt-dlp）。"""
    return RawItem(
        content_id=str(bvid),
        title=str(title or bvid)[:200],
        author=str(author or ""),
        author_id=str(author_id or ""),
        url=f"https://www.bilibili.com/video/{bvid}",
        published_at=(
            datetime.fromtimestamp(int(published_at)) if published_at else datetime.now()
        ),
        media_type="video",
        cover=str(cover or ""),
        description=str(description or "")[:500],
        duration=fmt_duration(int(duration or 0)),
    )


class BilibiliWatchLaterSource(_BilibiliListSource):
    """稍后观看（watchlater）作为独立采集平台。"""

    platform = "bili_watchlater"
    target = "watchlater"
    list_title = "B站稍后观看"

    def list_items(self) -> list[RawItem]:
        data = self._get(_TOVIEW, referer=_WATCHLATER_REFERER)
        code = data.get("code")
        if code == -101:
            raise SourceError("B 站未登录：先跑 python -m app login bilibili")
        if code != 0:
            raise SourceError(f"稍后观看接口错误：code={code} {data.get('message')}")
        items: list[RawItem] = []
        for row in (data.get("data") or {}).get("list") or []:
            bvid = str(row.get("bvid") or "")
            if not bvid:
                continue
            owner = row.get("owner") or {}
            items.append(_video_item(
                bvid=bvid,
                title=str(row.get("title") or ""),
                cover=str(row.get("pic") or ""),
                description=str(row.get("desc") or ""),
                duration=int(row.get("duration") or 0),
                published_at=int(row.get("pubdate") or row.get("add_at") or 0),
                author=str(owner.get("name") or ""),
                author_id=str(owner.get("mid") or ""),
            ))
        return items

    def prune(self, content_ids: list[str]) -> int:
        wanted = {str(c) for c in content_ids if c}
        if not wanted:
            return 0
        # 重新拉一次列表，拿到 bvid → aid 的映射；期间用户手动移除的条目自动跳过
        data = self._get(_TOVIEW, referer=_WATCHLATER_REFERER)
        if data.get("code") != 0:
            raise SourceError(
                f"稍后观看接口错误：code={data.get('code')} {data.get('message')}"
            )
        aids = {
            str(row.get("bvid")): int(row.get("aid"))
            for row in (data.get("data") or {}).get("list") or []
            if row.get("bvid") and row.get("aid")
        }
        csrf = self._csrf()
        removed = 0
        for bvid in wanted:
            aid = aids.get(bvid)
            if aid is None:
                continue
            data = self._post(
                _TOVIEW_DEL, {"aid": aid, "csrf": csrf}, referer=_WATCHLATER_REFERER
            )
            if data.get("code") == 0:
                removed += 1
            else:
                logger.warning(
                    "移出稍后观看失败 %s（aid=%s）：code=%s %s",
                    bvid, aid, data.get("code"), data.get("message"),
                )
            time.sleep(self._interval)
        return removed


class BilibiliFavoriteSource(_BilibiliListSource):
    """默认收藏夹作为独立采集平台。"""

    platform = "bili_favorite"
    target = "favorite"
    list_title = "B站默认收藏夹"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._fav_id: str | None = None

    def default_media_id(self) -> str:
        """默认收藏夹的 media_id：优先按标题「默认收藏夹」认，兜底取第一个。"""
        if self._fav_id:
            return self._fav_id
        vmid = self.my_mid()
        referer = f"https://space.bilibili.com/{vmid}/favlist"
        data = self._get(_FAV_FOLDERS, {"up_mid": vmid}, referer=referer)
        if data.get("code") != 0:
            raise SourceError(
                f"收藏夹列表接口错误：code={data.get('code')} {data.get('message')}"
            )
        folders = [
            f for f in ((data.get("data") or {}).get("list") or [])
            if isinstance(f, dict) and f.get("id")
        ]
        if not folders:
            raise SourceError("当前账号没有收藏夹（或登录态不可见）")
        default = next(
            (f for f in folders if "默认收藏夹" in str(f.get("title") or "")), folders[0]
        )
        self._fav_id = str(default["id"])
        logger.info("默认收藏夹：%s（media_id=%s）", default.get("title"), self._fav_id)
        return self._fav_id

    def list_items(self) -> list[RawItem]:
        media_id = self.default_media_id()
        referer = f"https://www.bilibili.com/medialist/detail/ml{media_id}"
        items: list[RawItem] = []
        page = 1
        while True:
            data = self._get(
                _FAV_LIST,
                {"media_id": media_id, "pn": page, "ps": 20, "platform": "web"},
                referer=referer,
            )
            if data.get("code") != 0:
                raise SourceError(
                    f"收藏夹内容接口错误：code={data.get('code')} {data.get('message')}"
                )
            payload = data.get("data") or {}
            medias = [m for m in payload.get("medias") or [] if isinstance(m, dict)]
            for media in medias:
                # 只收视频稿件：12=音频、21=视频合集都没有 bvid，下载器也处理不了
                if int(media.get("type") or 2) != 2:
                    continue
                if int(media.get("attr") or 0) != 0:  # 已失效（被删 / 仅 UP 可见）
                    continue
                bvid = str(media.get("bvid") or "")
                if not bvid:
                    continue
                upper = media.get("upper") or {}
                items.append(_video_item(
                    bvid=bvid,
                    title=str(media.get("title") or ""),
                    cover=str(media.get("cover") or ""),
                    description=str(media.get("intro") or ""),
                    duration=int(media.get("duration") or 0),
                    published_at=int(media.get("pubtime") or media.get("fav_time") or 0),
                    author=str(upper.get("name") or ""),
                    author_id=str(upper.get("mid") or ""),
                ))
            if not payload.get("has_more") or not medias:
                break
            page += 1
            time.sleep(self._interval)
        return items

    def prune(self, content_ids: list[str]) -> int:
        wanted = {str(c) for c in content_ids if c}
        if not wanted:
            return 0
        media_id = self.default_media_id()
        referer = f"https://www.bilibili.com/medialist/detail/ml{media_id}"
        data = self._get(_FAV_IDS, {"media_id": media_id, "platform": "web"}, referer=referer)
        if data.get("code") != 0:
            raise SourceError(
                f"收藏夹 id 接口错误：code={data.get('code')} {data.get('message')}"
            )
        aids = {
            str(row.get("bvid") or row.get("bv_id") or ""): int(row.get("id") or 0)
            for row in (data.get("data") or [])
            if isinstance(row, dict) and row.get("id")
        }
        pending = [aids[bvid] for bvid in wanted if bvid in aids]
        if not pending:
            return 0
        csrf = self._csrf()
        removed = 0
        for start in range(0, len(pending), 50):  # 分批，避免表单过长
            chunk = pending[start:start + 50]
            resp = self._post(
                _FAV_DEL,
                {
                    "resources": ",".join(f"{aid}:2" for aid in chunk),
                    "media_id": media_id,
                    "platform": "web",
                    "csrf": csrf,
                },
                referer=referer,
            )
            if resp.get("code") == 0:
                removed += len(chunk)
            else:
                logger.warning(
                    "取消收藏失败（%d 条）：code=%s %s",
                    len(chunk), resp.get("code"), resp.get("message"),
                )
            time.sleep(self._interval)
        return removed
