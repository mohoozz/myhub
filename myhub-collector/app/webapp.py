"""本地门户服务：浏览器里完成登录、看下载进度、改配置。

只用标准库（``http.server``），不引入 Flask / FastAPI——多一个依赖就多一个
``pip install`` 失败的可能，而这个服务只服务本机一个人。

安全边界：
- 只绑 ``127.0.0.1``，不监听外网；
- 所有 ``/api/*`` 要求页面内注入的随机 token（请求头 ``X-MyHub-Token``），
  外部站点即使向 localhost 发 POST 也拿不到这个 token。
"""
from __future__ import annotations

import argparse
import json
import logging
import re
import secrets
import threading
import webbrowser
from datetime import date, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import unquote, urlsplit

from app import credentials, envfile, jobs, webui
from app.config import get_settings
from app.database import get_engine, init_db
from app.utils import DURATION_SKIP_PREFIX

logger = logging.getLogger(__name__)

DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TOKEN = secrets.token_urlsafe(18)
MAX_BODY = 1 << 20  # 1 MB，配置表单够用了

BRAND = {"bilibili": "B", "youtube": "Y", "douyin": "D"}


# ---------------- 查询 ----------------

def _platform_status() -> list[dict]:
    out: list[dict] = []
    for platform in credentials.SITES:
        st = credentials.status(platform)
        out.append({
            "platform": st.platform,
            "title": st.title,
            "brand": BRAND.get(st.platform, st.platform[:1].upper()),
            "ok": st.ok,
            "expires": st.expires,
            "source": st.source,
            "hint": st.hint,
            "path": str(st.path),
        })
    return out


def api_overview() -> dict:
    settings = get_settings()
    busy = jobs.JOBS.busy()
    return {
        "platforms": _platform_status(),
        "busy": busy.brief() if busy else None,
        "jobs": [job.brief() for job in jobs.JOBS.recent(8)],
        "runs": _recent_runs(8),
        "env": envfile.env_status(),
        "last_day": (date.today() - timedelta(days=1)).isoformat(),
        "today": date.today().isoformat(),
        "report_dir": str(settings.report_path),
    }


_SQL_DAY_GROUPS = """
SELECT substr(c.published_at, 1, 10) AS day,
       c.platform AS platform,
       COALESCE(dl.status, 'pending') AS status,
       COUNT(*) AS n,
       COALESCE(SUM(dl.size), 0) AS size
FROM contents c
LEFT JOIN downloads dl
       ON dl.platform = c.platform AND dl.content_id = c.content_id
GROUP BY 1, 2, 3
ORDER BY day DESC
"""

_SQL_DAY_DETAIL = """
SELECT c.platform, c.author, c.title, c.media_type, c.published_at, c.url,
       COALESCE(dl.status, 'pending') AS status,
       COALESCE(dl.path, '') AS path,
       COALESCE(dl.size, 0) AS size,
       COALESCE(dl.error, '') AS error
FROM contents c
LEFT JOIN downloads dl
       ON dl.platform = c.platform AND dl.content_id = c.content_id
WHERE substr(c.published_at, 1, 10) = ?
ORDER BY c.published_at DESC
LIMIT 400
"""


def _blank_day(day: str) -> dict:
    return {
        "day": day, "total": 0, "done": 0, "failed": 0,
        "running": 0, "pending": 0, "skipped": 0, "size": 0, "platforms": {},
    }


def _add_count(bucket: dict, status: str, count: int, size: int) -> None:
    bucket["total"] += count
    bucket["size"] += size
    bucket[status] = bucket.get(status, 0) + count


def api_days(limit: int = 14) -> dict:
    init_db()
    with get_engine().connect() as conn:
        rows = conn.exec_driver_sql(_SQL_DAY_GROUPS).fetchall()
    days: dict[str, dict] = {}
    for day, platform, status, count, size in rows:
        node = days.setdefault(day, _blank_day(day))
        sub = node["platforms"].setdefault(platform, _blank_day(day))
        _add_count(node, status, count, size or 0)
        _add_count(sub, status, count, size or 0)

    ordered = sorted(days.values(), key=lambda item: item["day"], reverse=True)[:limit]
    return {"days": ordered, "runs": _recent_runs(12)}


def _recent_runs(limit: int) -> list[dict]:
    from sqlmodel import select

    from app.database import session_scope
    from app.models import RunLog

    with session_scope() as session:
        runs = session.exec(
            select(RunLog).order_by(RunLog.started_at.desc()).limit(limit)
        ).all()
        return [
            {
                "day": r.run_date,
                "platform": r.platform,
                "status": r.status,
                "authors": r.authors,
                "new_items": r.new_items,
                "downloaded": r.downloaded,
                "failed": r.failed,
                "skipped": r.skipped,
                "message": r.message,
                "started_at": r.started_at.strftime("%Y-%m-%d %H:%M") if r.started_at else "",
                "finished_at": r.finished_at.strftime("%H:%M:%S") if r.finished_at else "",
            }
            for r in runs
        ]


def _hhmm(value: Any) -> str:
    """原生 SQL 取回的 published_at 是字符串；ORM 查询则是 datetime，两种都兼容。"""
    if not value:
        return ""
    if isinstance(value, datetime):
        return value.strftime("%H:%M")
    text = str(value)
    return text[11:16] if len(text) >= 16 else text


def api_day(day: str) -> dict:
    if not DAY_RE.match(day or ""):
        raise ValueError("日期格式应为 YYYY-MM-DD")
    init_db()
    with get_engine().connect() as conn:
        rows = conn.exec_driver_sql(_SQL_DAY_DETAIL, (day,)).fetchall()
    node = _blank_day(day)
    items: list[dict] = []
    failures: list[dict] = []
    skipped_duration = 0
    for platform, author, title, media_type, published_at, url, status, path, size, error in rows:
        sub = node["platforms"].setdefault(platform, _blank_day(day))
        _add_count(node, status, 1, size or 0)
        _add_count(sub, status, 1, size or 0)
        entry = {
            "platform": platform,
            "author": author or "",
            "title": title or "",
            "media_type": media_type or "",
            "published_at": _hhmm(published_at),
            "url": url or "",
            "status": status,
            "size": size or 0,
            "error": error or "",
        }
        items.append(entry)
        if status == "failed":
            failures.append(entry)
        if status == "skipped" and (error or "").startswith(DURATION_SKIP_PREFIX):
            skipped_duration += 1

    report = get_settings().report_path / f"{day}.html"
    return {
        "day": day,
        "summary": node,
        "items": items,
        "failures": failures,
        "skipped_duration": skipped_duration,
        "report": f"/report/{day}" if report.exists() else "",
    }


# ---------------- 任务 ----------------

def _login_job(platform: str, wait: int) -> str:
    from app.login import login, login_all

    def run(job: jobs.Job) -> dict:
        if platform == "all":
            results = login_all(list(credentials.SITES), wait_seconds=wait)
            out = {
                p: {"ok": ok, "saved": str(saved or "")} for p, (ok, saved) in results.items()
            }
            if not all(item["ok"] for item in out.values()):
                job.log("部分平台未完成，可以稍后单独登录")
        else:
            ok, saved = login(platform, wait_seconds=wait)
            out = {platform: {"ok": ok, "saved": str(saved or "")}}
            if not ok:
                job.log("没检测到登录态：可能没登完或中途关了窗口")
        return out

    title = "登录全部平台" if platform == "all" else f"登录 {credentials.SITES[platform].title}"
    return jobs.JOBS.submit("login", title, run).id


def _reset_duration_skips(day: str, platforms: list[str]) -> int:
    """把当天「超时长跳过」的记录改回待下载：调大上限后可一键补下。"""
    init_db()
    marks = ", ".join("?" for _ in platforms)
    sql = (
        "UPDATE downloads SET status = 'pending', error = '', attempts = 0, finished_at = NULL, "
        "path = '', size = 0 "
        "WHERE status = 'skipped' AND error LIKE ? "
        f"AND platform IN ({marks}) "
        "AND EXISTS (SELECT 1 FROM contents c WHERE c.platform = downloads.platform "
        "AND c.content_id = downloads.content_id AND substr(c.published_at, 1, 10) = ?)"
    )
    params: tuple = (f"{DURATION_SKIP_PREFIX}%", *platforms, day)
    with get_engine().begin() as conn:
        result = conn.exec_driver_sql(sql, params)
    return int(result.rowcount or 0)


def _collect_job(
    day: str,
    platforms: list[str],
    download: bool,
    refresh: bool,
    retry_skipped: bool = False,
) -> str:
    from app.pipeline import run_once

    if retry_skipped:
        # 只补下载：不重新抓取、不重复同步关注
        download, refresh = True, False

    def run(job: jobs.Job) -> dict:
        out: dict = {}
        if retry_skipped:
            reset = _reset_duration_skips(day, platforms)
            job.log(f"已重置 {reset} 条「超时长跳过」记录，只补下载不重新抓取")
        for platform in platforms:
            job.log(f"=== {platform} · {day} ===")
            out[platform] = run_once(
                day=date.fromisoformat(day),
                platform=platform,
                do_download=download,
                refresh_sources=refresh,
                do_collect=not retry_skipped,
            )
        return out

    if retry_skipped:
        title = f"重试超时长 {day}"
    else:
        title = f"采集 {day}（{'、'.join(platforms)}）"
    return jobs.JOBS.submit("collect", title, run).id


def _sync_job(platforms: list[str]) -> str:
    from app.database import session_scope
    from app.pipeline import sync_subscriptions

    def run(job: jobs.Job) -> dict:
        out: dict = {}
        for platform in platforms:
            job.log(f"同步 {platform} 的关注 / 频道…")
            with session_scope() as session:
                out[platform] = sync_subscriptions(session, platform)
            job.log(f"{platform}：{out[platform]}")
        return out

    return jobs.JOBS.submit("sync", f"同步订阅源（{'、'.join(platforms)}）", run).id


def _init_job() -> str:
    def run(job: jobs.Job) -> dict:
        from app.__main__ import cmd_init

        code = cmd_init(argparse.Namespace())
        return {"exit": code}

    return jobs.JOBS.submit("init", "环境自检", run).id


# ---------------- HTTP ----------------

class Handler(BaseHTTPRequestHandler):
    server_version = "myhub-collector"
    protocol_version = "HTTP/1.1"

    # 访问日志对本地门户没意义，还会刷满控制台
    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
        logger.debug("web %s", fmt % args)

    # ---------- 输出 ----------

    def _send(self, status: int, body: bytes = b"", ctype: str = "application/json; charset=utf-8") -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _json(self, data: Any, status: int = 200) -> None:
        body = json.dumps(data, ensure_ascii=False, default=str).encode("utf-8")
        self._send(status, body)

    def _error(self, status: int, message: str) -> None:
        self._json({"ok": False, "error": message}, status)

    # ---------- 输入 ----------

    def _body(self) -> dict:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length <= 0:
            return {}
        if length > MAX_BODY:
            raise ValueError("请求体过大")
        raw = self.rfile.read(length)
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as e:
            raise ValueError(f"请求体不是合法 JSON：{e}") from e
        return data if isinstance(data, dict) else {}

    # ---------- 路由 ----------

    def do_GET(self) -> None:  # noqa: N802
        self._dispatch("GET")

    def do_POST(self) -> None:  # noqa: N802
        self._dispatch("POST")

    def _dispatch(self, method: str) -> None:
        path = urlsplit(self.path).path
        try:
            if path in ("/", "/index.html"):
                html = webui.HTML.replace("__TOKEN__", TOKEN)
                return self._send(200, html.encode("utf-8"), "text/html; charset=utf-8")
            if path == "/favicon.ico":
                return self._send(204)
            if path.startswith("/report/"):
                return self._report(unquote(path.split("/", 2)[2]))

            if not path.startswith("/api/"):
                return self._error(404, "没有这个页面")
            if self.headers.get("X-MyHub-Token") != TOKEN:
                return self._error(403, "令牌无效，请刷新页面")

            return self._api(method, path)
        except jobs.JobBusy as e:
            self._error(409, str(e))
        except ValueError as e:
            self._error(400, str(e))
        except Exception as e:  # noqa: BLE001 服务不能因为单个请求挂掉
            logger.exception("处理请求失败：%s", path)
            self._error(500, f"{type(e).__name__}: {e}")

    def _report(self, name: str) -> None:
        day = name[:-5] if name.endswith(".html") else name
        if not DAY_RE.match(day):
            return self._error(400, "日期格式应为 YYYY-MM-DD")
        path = get_settings().report_path / f"{day}.html"
        if not path.exists():
            return self._error(404, f"{day} 还没有生成报告")
        return self._send(200, path.read_bytes(), "text/html; charset=utf-8")

    def _api(self, method: str, path: str) -> None:
        if method == "GET":
            if path == "/api/overview":
                return self._json(api_overview())
            if path == "/api/days":
                return self._json(api_days())
            if path.startswith("/api/day/"):
                return self._json(api_day(unquote(path.rsplit("/", 1)[-1])))
            if path == "/api/env":
                return self._json({"groups": envfile.schema(), "status": envfile.env_status()})
            if path.startswith("/api/jobs/"):
                job = jobs.JOBS.get(unquote(path.rsplit("/", 1)[-1]))
                return self._json(job.snapshot(0) if job else {})
            return self._error(404, "没有这个接口")

        if method == "POST":
            payload = self._body()
            if path == "/api/login":
                platform = str(payload.get("platform") or "")
                if platform != "all" and platform not in credentials.SITES:
                    raise ValueError(f"未知平台：{platform}")
                wait = max(int(payload.get("wait") or 300), 30)
                return self._json({"ok": True, "job_id": _login_job(platform, wait)}, 202)
            if path == "/api/collect":
                day = str(payload.get("day") or "").strip() or (
                    date.today() - timedelta(days=1)
                ).isoformat()
                if not DAY_RE.match(day):
                    raise ValueError("日期格式应为 YYYY-MM-DD")
                platform = str(payload.get("platform") or "all")
                from app.sources import SUPPORTED

                targets = list(SUPPORTED) if platform == "all" else [platform]
                if any(p not in SUPPORTED for p in targets):
                    raise ValueError(f"未知平台：{platform}")
                job_id = _collect_job(
                    day, targets,
                    bool(payload.get("download", True)),
                    bool(payload.get("sync", True)),
                    bool(payload.get("retry_skipped")),
                )
                return self._json({"ok": True, "job_id": job_id}, 202)
            if path == "/api/sync":
                platform = str(payload.get("platform") or "all")
                from app.sources import SUPPORTED

                targets = list(SUPPORTED) if platform == "all" else [platform]
                if any(p not in SUPPORTED for p in targets):
                    raise ValueError(f"未知平台：{platform}")
                return self._json({"ok": True, "job_id": _sync_job(targets)}, 202)
            if path == "/api/init":
                return self._json({"ok": True, "job_id": _init_job()}, 202)
            if path == "/api/env":
                values = payload.get("values") or {}
                if not isinstance(values, dict):
                    raise ValueError("values 必须是对象")
                return self._json({"ok": True, **envfile.save(values)})
            return self._error(404, "没有这个接口")

        return self._error(405, "方法不支持")


# ---------------- 启动 ----------------

def _bind(server_cls, host: str, port: int, attempts: int = 10):
    last: OSError | None = None
    for offset in range(attempts):
        try:
            return server_cls((host, port + offset), Handler), port + offset
        except OSError as e:
            last = e
    raise SystemExit(f"端口 {port}-{port + attempts - 1} 都被占用：{last}")


def serve(host: str = "127.0.0.1", port: int = 8765, open_browser: bool = True) -> None:
    settings = get_settings()
    settings.ensure_dirs()
    init_db()

    httpd, real_port = _bind(ThreadingHTTPServer, host, port)
    httpd.daemon_threads = True
    url = f"http://{host}:{real_port}/"
    print(f"myhub-collector 门户已启动：{url}")
    print("按 Ctrl+C 停止；登录会弹出浏览器窗口，完成后回到页面看状态。")
    if open_browser:
        threading.Timer(0.8, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")
    finally:
        httpd.server_close()
