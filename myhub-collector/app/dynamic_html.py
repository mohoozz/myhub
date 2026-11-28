"""把纯文本 / 图文动态渲染成本地 HTML 页面（离线可读，图片以 base64 内嵌）。"""
from __future__ import annotations

import base64
import html
import mimetypes
import re
from datetime import datetime
from pathlib import Path
from typing import Mapping, Sequence

from app.models import Content
from app.utils import human_count

_TYPE_LABEL = {"video": "视频", "image": "图文动态", "text": "动态"}
_PLATFORM_LABEL = {
    "bilibili": "B站",
    "bili_watchlater": "B站稍后观看",
    "bili_favorite": "B站收藏夹",
    "youtube": "YouTube",
    "douyin": "抖音",
}


def _esc(text: object) -> str:
    return html.escape(str(text or ""))


def image_data_uri(path: Path) -> str:
    """把本地图片转成 data URI，让整条图文动态只有一个 HTML 文件。"""
    mime = mimetypes.guess_type(path.name)[0] or "image/jpeg"
    return f"data:{mime};base64,{base64.b64encode(path.read_bytes()).decode()}"


def _render_text(description: str, emotes: Mapping[str, str] | None = None) -> str:
    """正文转 HTML：换行转 <br>，[表情名] 换成内嵌图标（没有图标 URL 时原样保留文字）。"""
    text = _esc(description).replace("\n", "<br>")
    pairs = {_esc(name): url for name, url in (emotes or {}).items() if name and url}
    if not pairs:
        return text
    keys = sorted(pairs, key=len, reverse=True)
    pattern = re.compile("|".join(re.escape(k) for k in keys))
    return pattern.sub(
        lambda m: (
            f'<img class="emote" src="{_esc(pairs[m.group(0)])}" '
            f'alt="{m.group(0)}" loading="lazy">'
        ),
        text,
    )


def render_dynamic_html(
    content: Content,
    images: Sequence[str] | None = None,
    emotes: Mapping[str, str] | None = None,
) -> str:
    """images 为图片地址（data URI 或远程 URL）；为空时回落到远程 cover。

    emotes 是正文表情的「[名称] -> 图标地址」映射，图标一并内嵌，保证离线可读。
    """
    pics = [src for src in (images or []) if src]
    if pics:
        figures = "\n".join(
            f'<figure><img src="{_esc(src)}" alt="" loading="lazy"></figure>' for src in pics
        )
    elif content.cover:
        figures = f'<figure><img src="{_esc(content.cover)}" alt="" loading="lazy"></figure>'
    else:
        figures = ""

    meta = [
        f'<span class="chip">{_esc(_PLATFORM_LABEL.get(content.platform, content.platform))}</span>',
        f'<span class="chip">{_esc(_TYPE_LABEL.get(content.media_type, content.media_type))}</span>',
        f'<span class="chip">{content.published_at.strftime("%Y-%m-%d %H:%M")}</span>',
    ]
    if content.like_count:
        meta.append(f'<span class="chip">赞 {_esc(human_count(content.like_count))}</span>')
    if content.comment_count:
        meta.append(f'<span class="chip">评 {_esc(human_count(content.comment_count))}</span>')

    body = _render_text(content.description, emotes)

    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{_esc(content.title or "动态")} · {_esc(content.author)}</title>
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
body{{background:#0f1115;color:#e6e6e6;font-family:"Segoe UI",system-ui,sans-serif;max-width:760px;margin:0 auto;padding:32px 20px 60px}}
h1{{font-size:20px;line-height:1.5;margin-bottom:14px}}
.meta{{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:18px}}
.chip{{background:#242833;color:#c9ced6;border-radius:20px;padding:3px 12px;font-size:12px}}
.author{{color:#7cc7ff;font-size:13px;margin-bottom:10px}}
.text{{font-size:15px;line-height:1.85;color:#dfe3e8;white-space:normal;margin-bottom:20px;word-break:break-word}}
figure{{margin:0 0 14px}}
img{{width:100%;border-radius:10px;display:block;background:#2a2e38}}
img.emote{{display:inline-block;width:24px;height:24px;border-radius:0;background:none;vertical-align:-7px;margin:0 2px}}
.source{{margin-top:32px;font-size:12px;color:#8a8f98;text-align:center}}
.source a{{color:#7cc7ff;text-decoration:none}}
</style>
</head>
<body>
<div class="author">{_esc(content.author)}</div>
<h1>{_esc(content.title or "(无标题)")}</h1>
<div class="meta">{''.join(meta)}</div>
{('<div class="text">' + body + '</div>') if body else ''}
{figures}
<p class="source">抓取于 {datetime.now():%Y-%m-%d %H:%M} · <a href="{_esc(content.url)}" target="_blank" rel="noopener">查看原动态</a></p>
</body>
</html>
"""


def write_dynamic_html(
    content: Content,
    path: Path,
    images: Sequence[str] | None = None,
    emotes: Mapping[str, str] | None = None,
) -> Path:
    """把动态写成 HTML 文件，返回该文件路径。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(render_dynamic_html(content, images, emotes), encoding="utf-8")
    return path


def render_video_card_html(
    content: Content,
    cover: str = "",
    limit_minutes: int = 0,
) -> str:
    """超时长视频的本地预览页：只要标题和封面，不下载视频本体。

    cover 可以是 data URI（封面下载成功时离线可看），也可以是远程 URL；
    远程封面靠 ``no-referrer`` 绕过 B 站图床的防盗链。
    """
    figures = (
        f'<figure><img src="{_esc(cover)}" alt="" loading="lazy"></figure>'
        if cover
        else ""
    )
    meta = [
        f'<span class="chip">{_esc(_PLATFORM_LABEL.get(content.platform, content.platform))}</span>',
        f'<span class="chip">视频</span>',
        f'<span class="chip">{content.published_at.strftime("%Y-%m-%d %H:%M")}</span>',
    ]
    if content.like_count:
        meta.append(f'<span class="chip">赞 {_esc(human_count(content.like_count))}</span>')
    if content.comment_count:
        meta.append(f'<span class="chip">评 {_esc(human_count(content.comment_count))}</span>')

    reason = "；".join(
        piece
        for piece in (
            f"时长 {_esc(content.duration)}" if content.duration else "",
            f"超过上限 {limit_minutes} 分钟" if limit_minutes else "超过时长上限",
        )
        if piece
    )

    return f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>{_esc(content.title or "视频")} · {_esc(content.author)}</title>
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
body{{background:#0f1115;color:#e6e6e6;font-family:"Segoe UI",system-ui,sans-serif;max-width:760px;margin:0 auto;padding:32px 20px 60px}}
h1{{font-size:20px;line-height:1.5;margin-bottom:14px}}
.meta{{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:18px}}
.chip{{background:#242833;color:#c9ced6;border-radius:20px;padding:3px 12px;font-size:12px}}
.author{{color:#7cc7ff;font-size:13px;margin-bottom:10px}}
figure{{margin:0 0 16px}}
img{{width:100%;border-radius:10px;display:block;background:#2a2e38}}
.note{{border-left:3px solid #f0b95b;background:#1c1a14;color:#d8c9a4;font-size:13px;line-height:1.7;padding:10px 12px;border-radius:6px;margin-bottom:16px}}
.source{{margin-top:28px;font-size:12px;color:#8a8f98;text-align:center}}
.source a{{color:#7cc7ff;text-decoration:none}}
</style>
</head>
<body>
<div class="author">{_esc(content.author)}</div>
<h1>{_esc(content.title or "(无标题)")}</h1>
<div class="meta">{''.join(meta)}</div>
{figures}
<p class="note">{reason}，未下载视频本体，这里只保留标题和封面。</p>
<p class="source">抓取于 {datetime.now():%Y-%m-%d %H:%M} · <a href="{_esc(content.url)}" target="_blank" rel="noopener">查看原视频</a></p>
</body>
</html>
"""


def write_video_card(
    content: Content,
    path: Path,
    cover: str = "",
    limit_minutes: int = 0,
) -> Path:
    """把超时长视频写成 HTML 预览卡片，返回该文件路径。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(render_video_card_html(content, cover, limit_minutes), encoding="utf-8")
    return path
