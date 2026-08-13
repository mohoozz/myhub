"""静态 HTML 报告导出：查看已抓取的数据（无 server 依赖，浏览器直接打开）。

用法：python -m app export [输出路径]  （默认 data/feed_report.html）
"""
from datetime import datetime
from pathlib import Path

from sqlmodel import Session, func, select

from app.database import engine
from app.models import FeedItem, FeedSubscription

_PLATFORM_BADGE = {
    "bilibili": ("B站", "#00a1d6"),
    "youtube": ("YouTube", "#ff0033"),
    "douyin": ("抖音", "#fe2c55"),
}


def export_html(out_path: str = "data/feed_report.html", limit: int = 500) -> str:
    with Session(engine) as session:
        sub_count = session.exec(select(func.count(FeedSubscription.id))).one()
        item_count = session.exec(select(func.count(FeedItem.id))).one()
        platform_counts = dict(session.exec(
            select(FeedItem.platform, func.count(FeedItem.id)).group_by(FeedItem.platform)
        ).all())
        items = session.exec(
            select(FeedItem).order_by(FeedItem.published_at.desc()).limit(limit)
        ).all()

    cards = "\n".join(_card(it) for it in items)
    badges = " ".join(
        f'<span class="chip" style="border-color:{_PLATFORM_BADGE.get(p, (p, "#888"))[1]}">'
        f'{_PLATFORM_BADGE.get(p, (p, "#888"))[0]} {c}</span>'
        for p, c in sorted(platform_counts.items())
    )
    html = _TEMPLATE.replace("__SUB_COUNT__", str(sub_count)) \
        .replace("__ITEM_COUNT__", str(item_count)) \
        .replace("__BADGES__", badges) \
        .replace("__CARDS__", cards) \
        .replace("__GENERATED__", datetime.now().strftime("%Y-%m-%d %H:%M:%S"))

    path = Path(out_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(html, encoding="utf-8")
    return str(path)


def _card(it: FeedItem) -> str:
    name, color = _PLATFORM_BADGE.get(it.platform, (it.platform, "#888"))
    rel = _rel(it.published_at)
    exact = it.published_at.strftime("%Y-%m-%d %H:%M")
    cover = (f'<img class="cover" loading="lazy" src="{_esc(it.cover)}" alt="">'
             if it.cover else '<div class="cover"></div>')
    return f'''<a class="card" href="{_esc(it.url)}" target="_blank" rel="noopener">
  {cover}
  <div class="body">
    <div class="title">{_esc(it.title)}</div>
    <div class="meta">
      <span class="badge" style="background:{color}">{name}</span>
      <span class="author">{_esc(it.author)}</span>
      <span title="{exact}">{rel}</span>
    </div>
  </div>
</a>'''


def _esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def _rel(t: datetime) -> str:
    d = datetime.now() - t
    if d.total_seconds() < 3600:
        return f"{int(d.total_seconds() // 60)} 分钟前"
    if d.days < 1:
        return f"{int(d.total_seconds() // 3600)} 小时前"
    if d.days < 30:
        return f"{d.days} 天前"
    return t.strftime("%Y-%m-%d")


_TEMPLATE = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MyHub 动态</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{background:#0f1115;color:#e6e6e6;font-family:"Segoe UI",system-ui,sans-serif;max-width:1280px;margin:0 auto;padding:24px}
h1{font-size:20px}
.stats{display:flex;gap:16px;margin:16px 0 8px;flex-wrap:wrap;align-items:center}
.stat{background:#1a1d24;border-radius:10px;padding:14px 22px;min-width:150px}
.stat b{display:block;font-size:24px;color:#7cc7ff;margin-bottom:4px}
.stat span{color:#8a8f98;font-size:12px}
.chips{margin-bottom:20px}
.chip{border:1px solid;border-radius:20px;padding:3px 12px;font-size:12px;color:#c9ced6;margin-right:8px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:16px}
.card{background:#1a1d24;border-radius:10px;overflow:hidden;transition:transform .15s,box-shadow .15s;display:block;color:inherit;text-decoration:none}
.card:hover{transform:translateY(-3px);box-shadow:0 6px 20px rgba(0,0,0,.4)}
.cover{width:100%;aspect-ratio:16/9;object-fit:cover;display:block;background:#2a2e38}
.body{padding:12px}
.title{font-size:14px;line-height:1.4;height:2.8em;overflow:hidden;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
.meta{display:flex;align-items:center;gap:8px;margin-top:10px;font-size:12px;color:#8a8f98}
.badge{color:#fff;border-radius:4px;padding:1px 6px;font-size:11px;flex-shrink:0}
.author{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1}
.footer{margin-top:28px;color:#565b64;font-size:12px;text-align:center}
</style>
</head>
<body>
<h1>MyHub 动态</h1>
<div class="stats">
  <div class="stat"><b>__SUB_COUNT__</b><span>订阅源</span></div>
  <div class="stat"><b>__ITEM_COUNT__</b><span>已收录内容</span></div>
</div>
<div class="chips">__BADGES__</div>
<div class="grid">
__CARDS__
</div>
<p class="footer">生成于 __GENERATED__</p>
</body>
</html>"""
