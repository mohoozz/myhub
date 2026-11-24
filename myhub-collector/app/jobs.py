"""后台任务：把登录 / 采集这类长任务丢进线程，Web 端靠轮询拿进度。

设计取舍：
- **同一时间只跑一个任务**。Playwright 抢 profile、B 站风控、SQLite 写入都不适合并发，
  串行反而更稳；后来者直接收到「已有任务在跑」。
- **日志全收**：项目里的进度既走 ``logging``（pipeline）也走 ``print``（login），
  任务线程内两种都转进环形缓冲区，前端按游标增量拉取。
"""
from __future__ import annotations

import contextlib
import io
import logging
import threading
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from typing import Callable

MAX_LINES = 600


class JobBusy(RuntimeError):
    """已有任务在跑。"""


def _now() -> str:
    return datetime.now().strftime("%H:%M:%S")


@dataclass
class Job:
    """一次后台任务的完整状态（前端只读快照）。"""

    id: str
    kind: str                      # login / collect / sync / init
    title: str
    status: str = "queued"         # queued / running / done / failed
    created_at: str = field(default_factory=lambda: datetime.now().isoformat(timespec="seconds"))
    started_at: str = ""
    finished_at: str = ""
    lines: list[str] = field(default_factory=list)
    result: dict = field(default_factory=dict)
    error: str = ""
    dropped: int = 0               # 超出 MAX_LINES 被丢掉的早期日志行数

    def log(self, text: str) -> None:
        line = (text or "").rstrip()
        if not line:
            return
        self.lines.append(line)
        if len(self.lines) > MAX_LINES:
            overflow = len(self.lines) - MAX_LINES
            del self.lines[:overflow]
            self.dropped += overflow

    def snapshot(self, since: int = 0) -> dict:
        """``since`` 是客户端已收到的绝对行号（含被丢弃的部分）。"""
        if since < 0:
            since = 0
        start = max(since - self.dropped, 0)
        return {
            "id": self.id,
            "kind": self.kind,
            "title": self.title,
            "status": self.status,
            "created_at": self.created_at,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "lines": self.lines[start:],
            "cursor": self.dropped + len(self.lines),
            "result": self.result,
            "error": self.error,
        }

    def brief(self) -> dict:
        return {
            "id": self.id,
            "kind": self.kind,
            "title": self.title,
            "status": self.status,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "error": self.error,
            "summary": _summary_of(self),
        }


def _summary_of(job: Job) -> str:
    """给任务列表用的一句话结论。"""
    if job.status == "failed":
        return job.error[:160]
    if job.status in ("queued", "running"):
        return ""
    parts: list[str] = []
    for platform, data in (job.result or {}).items():
        if not isinstance(data, dict):
            continue
        if "downloaded" in data:
            parts.append(
                f"{platform} 新增 {data.get('new_items', 0)} / 下载 {data.get('downloaded', 0)}"
                f" / 失败 {data.get('failed', 0)}"
            )
    return "；".join(parts)


class _ThreadFilter(logging.Filter):
    """只收任务线程自己打的日志（服务线程的访问日志不要混进来）。"""

    def __init__(self, ident: int) -> None:
        super().__init__()
        self.ident = ident

    def filter(self, record: logging.LogRecord) -> bool:
        return record.thread == self.ident


class _JobHandler(logging.Handler):
    def __init__(self, job: Job) -> None:
        super().__init__(level=logging.INFO)
        self.job = job
        self.setFormatter(logging.Formatter("%(asctime)s %(message)s", "%H:%M:%S"))

    def emit(self, record: logging.LogRecord) -> None:
        try:
            self.job.log(self.format(record))
        except Exception:  # noqa: BLE001 日志失败不能影响业务
            pass


class _JobStream(io.TextIOBase):
    """把 ``print()`` 的输出按行塞进任务日志。"""

    def __init__(self, job: Job) -> None:
        self._job = job
        self._buf = ""

    def write(self, text: str) -> int:  # type: ignore[override]
        self._buf += text
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            self._job.log(line)
        return len(text)

    def flush(self) -> None:
        if self._buf.strip():
            self._job.log(self._buf)
            self._buf = ""

    def isatty(self) -> bool:
        return False


class JobManager:
    """进程内的任务表：提交、查询、互斥。"""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._jobs: dict[str, Job] = {}
        self._order: list[str] = []
        self._current: str | None = None

    # ---------- 查询 ----------

    def busy(self) -> Job | None:
        with self._lock:
            job = self._jobs.get(self._current or "")
            if job and job.status in ("queued", "running"):
                return job
            return None

    def get(self, job_id: str) -> Job | None:
        with self._lock:
            return self._jobs.get(job_id)

    def recent(self, limit: int = 12) -> list[Job]:
        with self._lock:
            ids = list(reversed(self._order[-limit:]))
            return [self._jobs[i] for i in ids if i in self._jobs]

    # ---------- 提交 ----------

    def submit(self, kind: str, title: str, func: Callable[[Job], dict | None]) -> Job:
        running = self.busy()
        if running:
            raise JobBusy(f"已有任务在跑：{running.title}（{running.status}），等它结束再试")

        job = Job(id=f"{datetime.now():%H%M%S}-{uuid.uuid4().hex[:6]}", kind=kind, title=title)
        thread = threading.Thread(target=self._run, args=(job, func), name=f"job-{job.id}", daemon=True)
        with self._lock:
            self._jobs[job.id] = job
            self._order.append(job.id)
            self._current = job.id
            # 只留最近 40 条，避免常驻内存一直涨
            while len(self._order) > 40:
                self._jobs.pop(self._order.pop(0), None)
        thread.start()
        return job

    # ---------- 执行 ----------

    def _run(self, job: Job, func: Callable[[Job], dict | None]) -> None:
        job.status = "running"
        job.started_at = _now()

        handler = _JobHandler(job)
        handler.addFilter(_ThreadFilter(threading.get_ident()))
        root = logging.getLogger()
        previous_level = root.level
        root.addHandler(handler)
        if previous_level > logging.INFO:
            root.setLevel(logging.INFO)

        stream = _JobStream(job)
        try:
            with contextlib.redirect_stdout(stream):
                result = func(job) or {}
            job.result = result if isinstance(result, dict) else {"result": result}
            job.status = "done"
        except Exception as e:  # noqa: BLE001 任何异常都要落到任务状态里给前端看
            job.error = f"{type(e).__name__}: {e}"
            job.log(job.error)
            job.status = "failed"
        finally:
            stream.flush()
            root.removeHandler(handler)
            root.setLevel(previous_level)
            job.finished_at = _now()
            with self._lock:
                if self._current == job.id:
                    self._current = None


JOBS = JobManager()
