"""每日总结：Markdown + 静态 HTML（按作者分组，附下载状态与热门 Top）。"""
from __future__ import annotations

import html
import logging
import os
from collections import defaultdict
from datetime import date, datetime, timedelta, time
from pathlib import Path

from sqlmodel import Session, select

from app.config import get_settings
from app.models import Content, Download
from app.utils import human_count

logger = logging.getLogger(__name__)

_PLATFORM_LABEL = {
    "bilibili": ("B站", "#00a1d6"),
    "youtube": ("YouTube", "#ff0033"),
    "douyin": ("抖音", "#fe2c55"),
}
_TYPE_LABEL = {"video": "视频", "image": "图文", "text": "动态"}


def day_range(day: date) -> tuple[datetime, datetime]:
    start = datetime.combine(day, time.min)
    return start, start + timedelta(days=1)


def _esc(text: str) -> str:
    return html.escape(str(text or ""))


def _status_text(dl: Download | None) -> str:
    if dl is None:
        return "未下载"
    return {
        "done": "已下载",
        "failed": "下载失败",
        "skipped": "已跳过",
        "pending": "待下载",
    }.get(dl.status, dl.status)


def _rel_link(local_path: str, report_dir: Path) -> str:
    """把本地文件路径转成相对报告目录的链接（报告直接在浏览器打开即可点）。"""
    if not local_path:
        return ""
    try:
        return Path(os.path.relpath(local_path, report_dir)).as_posix()
    except ValueError:  # 跨盘符
        return ""


def render_markdown(
    day: date,
    contents: list[Content],
    downloads: dict[tuple[str, str], Download],
) -> str:
    settings = get_settings()
    report_dir = settings.report_path

    total = len(contents)
    by_type: dict[str, int] = defaultdict(int)
    by_platform: dict[str, int] = defaultdict(int)
    by_author: dict[tuple[str, str], list[Content]] = defaultdict(list)
    for item in contents:
        by_type[item.media_type] += 1
        by_platform[item.platform] += 1
        by_author[(item.platform, item.author or "未知作者")].append(item)

    done = sum(1 for c in contents
               if (dl := downloads.get((c.platform, c.content_id))) and dl.status == "done")
    failed = sum(1 for c in contents
                 if (dl := downloads.get((c.platform, c.content_id))) and dl.status == "failed")
    skipped = sum(1 for c in contents
                  if (dl := downloads.get((c.platform, c.content_id))) and dl.status == "skipped")

    type_text = " / ".join(f"{_TYPE_LABEL.get(k, k)} {v}" for k, v in sorted(by_type.items()))
    lines = [
        f"# MyHub 每日汇总 · {day.isoformat()}",
        "",
        f"- 新增内容 **{total}** 条" + (f"（{type_text}）" if type_text else ""),
        f"- 覆盖作者 **{len(by_author)}** 位",
        f"- 本地下载：成功 {done} · 失败 {failed} · 跳过 {skipped}",
        f"- 生成时间：{datetime.now().strftime('%Y-%m-%d %H:%M')}",
        "",
    ]

    hottest = sorted(
        [c for c in contents if c.like_count > 0], key=lambda c: c.like_count, reverse=True
    )[:5]
    if hottest:
        lines += ["## 热门 Top 5", "", "| 平台 | 作者 | 标题 | 点赞 |", "| --- | --- | --- | --- |"]
        for c in hottest:
            label = _PLATFORM_LABEL.get(c.platform, (c.platform, ""))[0]
            title = (c.title or "").replace("|", "｜")[:50]
            lines.append(f"| {label} | {c.author or '-'} | [{title}]({c.url}) | {human_count(c.like_count)} |")
        lines.append("")

    lines += ["## 按作者", ""]
    for (platform, author), items in sorted(
        by_author.items(), key=lambda kv: (-len(kv[1]), kv[0][1])
    ):
        label = _PLATFORM_LABEL.get(platform, (platform, ""))[0]
        items.sort(key=lambda c: c.published_at, reverse=True)
        lines += [f"### {author} · {label} · {len(items)} 条", ""]
        for c in items:
            dl = downloads.get((c.platform, c.content_id))
            mark = {"done": "✅", "failed": "❌", "skipped": "➖"}.get(
                dl.status if dl else "", "⏳"
            )
            bits = [f"**{c.title or '(无标题)'}**"]
            if c.duration:
                bits.append(f"`{c.duration}`")
            if c.like_count:
                bits.append(f"赞 {human_count(c.like_count)}")
            bits.append(c.published_at.strftime("%m-%d %H:%M"))
            local = ""
            if dl and dl.status == "done" and dl.path:
                href = _rel_link(dl.path, report_dir)
                local = f" · [本地]({href})" if href else ""
            lines.append(f"- {mark} " + " · ".join(bits) + f" · [链接]({c.url}){local}")
        lines.append("")

    return "\n".join(lines).rstrip() + "\n"


def render_html(
    day: date,
    contents: list[Content],
    downloads: dict[tuple[str, str], Download],
) -> str:
    settings = get_settings()
    report_dir = settings.report_path

    by_author: dict[tuple[str, str], list[Content]] = defaultdict(list)
    platform_counts: dict[str, int] = defaultdict(int)
    for item in contents:
        by_author[(item.platform, item.author or "未知作者")].append(item)
        platform_counts[item.platform] += 1

    done = sum(1 for c in contents
               if (dl := downloads.get((c.platform, c.content_id))) and dl.status == "done")

    chips = " ".join(
        f'<span class="chip" style="border-color:{_PLATFORM_LABEL.get(p, (p, "#888"))[1]}">'
        f'{_PLATFORM_LABEL.get(p, (p, "#888"))[0]} {n}</span>'
        for p, n in sorted(platform_counts.items())
    )

    sections: list[str] = []
    for (platform, author), items in sorted(by_author.items(), key=lambda kv: (-len(kv[1]), kv[0][1])):
        items.sort(key=lambda c: c.published_at, reverse=True)
        label, color = _PLATFORM_LABEL.get(platform, (platform, "#888"))
        cards = "\n".join(
            _card(c, downloads.get((c.platform, c.content_id)), report_dir, label, color)
            for c in items
        )
        sections.append(
            f'<h2><span class="dot" style="background:{color}"></span>{_esc(author)}'
            f'<small>{label} · {len(items)} 条</small></h2>\n<div class="grid">\n{cards}\n</div>'
        )

    return _TEMPLATE.format(
        day=day.isoformat(),
        total=len(contents),
        authors=len(by_author),
        downloaded=done,
        chips=chips,
        sections="\n".join(sections),
        generated=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    )


def _card(
    item: Content,
    dl: Download | None,
    report_dir: Path,
    label: str,
    color: str,
) -> str:
    cover = (f'<img class="cover" loading="lazy" src="{_esc(item.cover)}" alt="">'
             if item.cover else '<div class="cover"></div>')
    status = _status_text(dl)
    cls = "status-ok" if dl and dl.status == "done" else (
        "status-fail" if dl and dl.status == "failed" else "status-idle"
    )
    href = _esc(item.url)
    if dl and dl.status == "done" and dl.path:
        rel = _rel_link(dl.path, report_dir)
        if rel:
            href = _esc(rel)
    meta = [f'<span class="badge" style="background:{color}">{_esc(label)}</span>']
    if item.duration:
        meta.append(f'<span class="chip-mini">{_esc(item.duration)}</span>')
    if item.like_count:
        meta.append(f'<span class="chip-mini">赞 {human_count(item.like_count)}</span>')
    meta.append(f'<span class="chip-mini">{item.published_at.strftime("%m-%d %H:%M")}</span>')
    return f'''<a class="card" href="{href}" target="_blank" rel="noopener">
  {cover}
  <div class="body">
    <div class="title">{_esc(item.title or "(无标题)")}</div>
    <div class="meta">{''.join(meta)}</div>
    <div class="foot"><span class="{cls}">{_esc(status)}</span>
      <span class="type">{_TYPE_LABEL.get(item.media_type, item.media_type)}</span></div>
  </div>
</a>'''


def write_reports(session: Session, day: date) -> tuple[Path, Path] | None:
    """生成并落盘当天的 Markdown / HTML 报告；无内容时返回 None。"""
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
    md_path = settings.report_path / f"{day.isoformat()}.md"
    html_path = settings.report_path / f"{day.isoformat()}.html"
    md_path.write_text(render_markdown(day, contents, downloads), encoding="utf-8")
    html_path.write_text(render_html(day, contents, downloads), encoding="utf-8")
    logger.info("报告已生成：%s / %s", md_path, html_path)
    return md_path, html_path


_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MyHub 每日汇总 · {day}</title>
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
body{{background:#0f1115;color:#e6e6e6;font-family:"Segoe UI",system-ui,sans-serif;max-width:1280px;margin:0 auto;padding:24px}}
h1{{font-size:22px}}
h2{{font-size:16px;margin:28px 0 12px;display:flex;align-items:center;gap:8px}}
h2 small{{color:#8a8f98;font-weight:400;font-size:12px}}
.dot{{width:8px;height:8px;border-radius:50%;display:inline-block}}
.stats{{display:flex;gap:16px;margin:16px 0 8px;flex-wrap:wrap}}
.stat{{background:#1a1d24;border-radius:10px;padding:14px 22px;min-width:150px}}
.stat b{{display:block;font-size:24px;color:#7cc7ff;margin-bottom:4px}}
.stat span{{color:#8a8f98;font-size:12px}}
.chips{{margin:12px 0 4px}}
.chip{{border:1px solid;border-radius:20px;padding:3px 12px;font-size:12px;color:#c9ced6;margin-right:8px}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:16px}}
.card{{background:#1a1d24;border-radius:10px;overflow:hidden;transition:transform .15s,box-shadow .15s;display:block;color:inherit;text-decoration:none}}
.card:hover{{transform:translateY(-3px);box-shadow:0 6px 20px rgba(0,0,0,.4)}}
.cover{{width:100%;aspect-ratio:16/9;object-fit:cover;display:block;background:#2a2e38}}
.body{{padding:12px}}
.title{{font-size:14px;line-height:1.4;height:2.8em;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}}
.meta{{display:flex;align-items:center;gap:6px;margin-top:10px;font-size:12px;color:#8a8f98;flex-wrap:wrap}}
.badge{{color:#fff;border-radius:4px;padding:1px 6px;font-size:11px}}
.chip-mini{{background:#242833;border-radius:4px;padding:1px 6px;font-size:11px}}
.foot{{display:flex;justify-content:space-between;margin-top:10px;font-size:11px;color:#8a8f98}}
.status-ok{{color:#4ade80}} .status-fail{{color:#f87171}} .status-idle{{color:#8a8f98}}
.footer{{margin-top:32px;color:#565b64;font-size:12px;text-align:center}}
</style>
</head>
<body>
<h1>MyHub 每日汇总 · {day}</h1>
<div class="stats">
  <div class="stat"><b>{total}</b><span>当日内容</span></div>
  <div class="stat"><b>{authors}</b><span>覆盖作者</span></div>
  <div class="stat"><b>{downloaded}</b><span>已下载到本地</span></div>
</div>
<div class="chips">{chips}</div>
{sections}
<p class="footer">生成于 {generated}</p>
</body>
</html>
"""
