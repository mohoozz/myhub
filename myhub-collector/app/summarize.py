"""每日总结：只产出一个 HTML 报告（总览 + 失败优先的明细清单）。"""
from __future__ import annotations

import html
import logging
import os
from collections import Counter, defaultdict
from datetime import date, datetime, time, timedelta
from pathlib import Path

from sqlmodel import Session, select

from app.config import get_settings
from app.models import Content, Download
from app.utils import DURATION_SKIP_PREFIX, build_stem

logger = logging.getLogger(__name__)

# 总览里固定列出的平台（没有数据也显示 0）
_PLATFORMS = ("bilibili", "bili_watchlater", "bili_favorite", "douyin", "youtube")
_PLATFORM_LABEL = {
    "bilibili": "B站",
    "bili_watchlater": "B站稍后观看",
    "bili_favorite": "B站收藏夹",
    "youtube": "YouTube",
    "douyin": "抖音",
}
_PLATFORM_COLOR = {
    "bilibili": "#00a1d6",
    "bili_watchlater": "#fb7299",
    "bili_favorite": "#f472b6",
    "youtube": "#ff0033",
    "douyin": "#fe2c55",
}
_TYPE_LABEL = {"video": "视频", "image": "图文", "text": "动态"}
_STATUS_TEXT = {
    "done": "成功",
    "failed": "失败",
    "skipped": "已跳过",
    "pending": "待下载",
}
_STATUS_CLASS = {
    "done": "ok",
    "failed": "fail",
    "skipped": "idle",
    "pending": "idle",
}


def day_range(day: date) -> tuple[datetime, datetime]:
    start = datetime.combine(day, time.min)
    return start, start + timedelta(days=1)


def _esc(text: object) -> str:
    return html.escape(str(text or ""))


def _rel_link(local_path: str, report_dir: Path) -> str:
    """把本地文件路径转成相对报告目录的链接（报告直接在浏览器打开即可点）。"""
    if not local_path:
        return ""
    try:
        return Path(os.path.relpath(local_path, report_dir)).as_posix()
    except ValueError:  # 跨盘符
        return ""


def _file_name(item: Content, dl: Download | None) -> str:
    """已下载用真实文件名，未下载/失败用预期的 平台-作者-标题-发布号[-Pn].ext。"""
    if dl is not None and dl.path:
        return Path(dl.path).name
    ext = "html" if item.media_type in ("text", "image") else "mp4"
    return f"{build_stem(item.platform, item.author, item.title, item.content_id)}.{ext}"


def _overview(contents: list[Content]) -> str:
    authors: dict[str, set[str]] = defaultdict(set)
    counts: Counter[str] = Counter()
    types: dict[str, Counter[str]] = defaultdict(Counter)
    for item in contents:
        authors[item.platform].add(item.author or "未知作者")
        counts[item.platform] += 1
        types[item.platform][item.media_type] += 1

    rows = []
    for platform in _PLATFORMS:
        label = _PLATFORM_LABEL[platform]
        color = _PLATFORM_COLOR[platform]
        detail = " / ".join(
            f"{_TYPE_LABEL.get(k, k)} {v}" for k, v in sorted(types[platform].items())
        ) or "-"
        rows.append(
            f'<tr><td><span class="dot" style="background:{color}"></span>{label}</td>'
            f'<td>{len(authors[platform])} 位</td>'
            f'<td>{counts[platform]} 条</td>'
            f'<td class="muted">{_esc(detail)}</td></tr>'
        )
    return (
        '<table class="overview">'
        '<tr><th>平台</th><th>UP 主</th><th>内容</th><th>构成</th></tr>'
        + "".join(rows)
        + "</table>"
    )


def _rows(
    items: list[tuple[Content, Download | None]],
    report_dir: Path,
) -> str:
    out: list[str] = []
    for item, dl in items:
        name = _file_name(item, dl)
        status = dl.status if dl else ""
        cls = _STATUS_CLASS.get(status, "idle")
        # 超时长视频没下载本体，但 path 指向 HTML 预览卡片，也该能点开
        rel = _rel_link(dl.path, report_dir) if dl and dl.path and status in ("done", "skipped") else ""
        title = _esc(item.author) + " · " + _esc(_TYPE_LABEL.get(item.media_type, item.media_type))
        if rel:
            label = f'<a href="{_esc(rel)}"><code>{_esc(name)}</code></a>'
        elif item.url:
            label = f'<a href="{_esc(item.url)}" target="_blank" rel="noopener"><code>{_esc(name)}</code></a>'
        else:
            label = f"<code>{_esc(name)}</code>"
        note = _STATUS_TEXT.get(status, "未下载")
        if status == "skipped" and dl and (dl.error or "").startswith(DURATION_SKIP_PREFIX):
            note = "已跳过视频（有 HTML 预览）" if dl.path else "已跳过视频（超时长）"
        elif status == "failed" and dl and dl.error:
            note = f"失败（{dl.error}）"
        out.append(
            f'<li class="{cls}">{label}'
            f'<span class="note">{_esc(note)}</span>'
            f'<span class="src">{title}</span></li>'
        )
    return '<ol class="list">' + "".join(out) + "</ol>"


def render_html(
    day: date,
    contents: list[Content],
    downloads: dict[tuple[str, str], Download],
) -> str:
    report_dir = get_settings().report_path

    pairs = [(c, downloads.get((c.platform, c.content_id))) for c in contents]
    failed = [(c, d) for c, d in pairs if d and d.status == "failed"]
    done = [(c, d) for c, d in pairs if d and d.status == "done"]
    others = [(c, d) for c, d in pairs if not d or d.status not in ("failed", "done")]

    def sort_key(pair: tuple[Content, Download | None]):
        item = pair[0]
        return (item.platform, item.author, -item.published_at.timestamp())

    sections: list[str] = []
    if failed:
        sections.append(
            f'<h2>失败 <small>{len(failed)} 条</small></h2>{_rows(sorted(failed, key=sort_key), report_dir)}'
        )
    sections.append(
        f'<h2>成功 <small>{len(done)} 条</small></h2>'
        + (_rows(sorted(done, key=sort_key), report_dir) if done else '<p class="muted">无</p>')
    )
    if others:
        sections.append(
            f'<h2>其他 <small>{len(others)} 条</small></h2>{_rows(sorted(others, key=sort_key), report_dir)}'
        )

    return _TEMPLATE.format(
        day=day.isoformat(),
        overview=_overview(contents),
        summary=(
            f"共 {len(contents)} 条内容 · 成功 {len(done)} · 失败 {len(failed)}"
            f" · 其他 {len(others)}"
        ),
        sections="\n".join(sections),
        generated=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    )


def write_reports(session: Session, day: date) -> Path | None:
    """生成并落盘当天的 HTML 报告；无内容时返回 None。"""
    start, end = day_range(day)
    contents = session.exec(
        select(Content)
        .where(Content.published_at >= start, Content.published_at < end)
        .order_by(Content.published_at.desc())
    ).all()
    if not contents:
        logger.info("%s 无内容，跳过总结", day)
        return None

    keys = {(c.platform, c.content_id) for c in contents}
    downloads: dict[tuple[str, str], Download] = {}
    for dl in session.exec(select(Download)):
        key = (dl.platform, dl.content_id)
        if key in keys:
            downloads[key] = dl

    settings = get_settings()
    settings.report_path.mkdir(parents=True, exist_ok=True)
    html_path = settings.report_path / f"{day.isoformat()}.html"
    html_path.write_text(render_html(day, contents, downloads), encoding="utf-8")
    # 报告的修改时间统一设成当天零点：文件管理器里按日期排序更整齐，
    # 也方便按「报告属于哪一天」而不是「哪天生成」来归档。
    ts = datetime.combine(day, time.min).timestamp()
    try:
        os.utime(html_path, (ts, ts))
    except OSError as e:  # 文件被占用 / 权限不足：不影响报告生成
        logger.debug("设置报告文件时间失败 %s：%s", html_path, e)
    logger.info("报告已生成：%s", html_path)
    return html_path


_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MyHub 每日汇总 · {day}</title>
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
body{{background:#0f1115;color:#e6e6e6;font-family:"Segoe UI",system-ui,sans-serif;max-width:980px;margin:0 auto;padding:28px 20px 60px;line-height:1.6}}
h1{{font-size:22px;margin-bottom:6px}}
.sub{{color:#8a8f98;font-size:13px;margin-bottom:24px}}
h2{{font-size:16px;margin:26px 0 10px;display:flex;align-items:center;gap:8px}}
h2 small{{color:#8a8f98;font-weight:400;font-size:12px}}
.dot{{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:6px}}
.overview{{width:100%;border-collapse:collapse;background:#161920;border-radius:10px;overflow:hidden}}
.overview th,.overview td{{text-align:left;padding:9px 14px;font-size:13px;border-bottom:1px solid #22262f}}
.overview th{{color:#8a8f98;font-weight:400;background:#1a1d24}}
.overview tr:last-child td{{border-bottom:none}}
.muted{{color:#8a8f98}}
.list{{list-style:none}}
.list li{{display:flex;gap:12px;align-items:baseline;padding:5px 0;border-bottom:1px solid #191c23;font-size:13px;flex-wrap:wrap}}
.list li:last-child{{border-bottom:none}}
code{{font-family:"Cascadia Mono",Consolas,monospace;font-size:12.5px;color:#dfe3e8;word-break:break-all}}
a code{{color:#7cc7ff}}
a{{text-decoration:none}}
.note{{color:#8a8f98;flex-shrink:0}}
.ok .note{{color:#4ade80}}
.fail .note{{color:#f87171}}
.src{{color:#565b64;font-size:12px;margin-left:auto}}
.footer{{margin-top:32px;color:#565b64;font-size:12px;text-align:center}}
</style>
</head>
<body>
<h1>MyHub 每日汇总 · {day}</h1>
<div class="sub">{summary}</div>

<h2>总览</h2>
{overview}

{sections}
<p class="footer">生成于 {generated}</p>
</body>
</html>
"""
