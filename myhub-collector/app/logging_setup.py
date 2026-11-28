"""统一日志：所有输出（logging 记录 + print）都写进 ``data/logs/myhub-collector.log``。

三处入口共用这一份配置：

- CLI（``python -m app ...``）启动时调用 :func:`setup_logging`，``serve`` 走同一个入口；
- ``print()`` 走的 ``sys.stdout`` / ``sys.stderr`` 被换成双写对象，控制台照常显示、文件照常留档；
- 门户后台任务线程用 ``contextlib.redirect_stdout`` 接走 print，``app.jobs._JobStream``
  会把每一行回填 :func:`write_line`，所以任务日志同样不丢。

轮转只在进程启动时检查：运行中可能有多个进程（门户 + 计划任务）同时持有同一个文件句柄，
边写边改名会互相踩。
"""
from __future__ import annotations

import io
import logging
import sys
import threading
from datetime import datetime
from pathlib import Path

LOG_NAME = "myhub-collector.log"
MAX_BYTES = 10 * 1024 * 1024   # 单个文件上限，超过就轮转
BACKUP_COUNT = 3               # 保留 .1 / .2 / .3
_NO_NEWLINE_LIMIT = 4096       # 进度条这类只有 \r 没有换行的输出，攒够就先落盘

_LOCK = threading.RLock()
_PATH: Path | None = None
_STREAM = None                 # type: ignore[var-annotated]
_INSTALLED = False


def log_path() -> Path:
    """日志文件位置：``<DATA_DIR>/logs/myhub-collector.log``（DATA_DIR 改了日志跟着走）。"""
    from app.config import get_settings

    return get_settings().data_path / "logs" / LOG_NAME


def _rotate(path: Path) -> None:
    """启动时按大小轮转一次：myhub-collector.log → .1 → .2 → .3。"""
    try:
        if not path.exists() or path.stat().st_size < MAX_BYTES:
            return
        for index in range(BACKUP_COUNT - 1, 0, -1):
            src = path.with_name(f"{path.name}.{index}")
            if src.exists():
                src.replace(path.with_name(f"{path.name}.{index + 1}"))
        path.replace(path.with_name(f"{path.name}.1"))
    except OSError:
        pass  # 被别的进程占着就继续追加，不能因为轮转失败挡启动


def _open_raw():
    """惰性打开追加写入的文件句柄（print 的原始输出走这里）。"""
    global _STREAM

    with _LOCK:
        if _STREAM is None and _PATH is not None:
            _STREAM = _PATH.open("a", encoding="utf-8", errors="replace", newline="")
        return _STREAM


def write_line(text: str) -> None:
    """把一行原始输出（print / 任务线程 stdout）加时间戳写进日志；未初始化时静默忽略。"""
    line = (text or "").rstrip("\r\n")
    if not line:
        return
    stream = _open_raw()
    if stream is None:
        return
    with _LOCK:
        try:
            stream.write(f"{datetime.now():%Y-%m-%d %H:%M:%S} {line}\n")
            stream.flush()
        except (OSError, ValueError):
            pass


class _Tee(io.TextIOBase):
    """控制台 + 日志文件双写；控制台写失败（没有控制台、管道已关）不影响文件留档。"""

    def __init__(self, console) -> None:
        self._console = console
        self._buf = ""

    # ---------- 写 ----------
    def write(self, text: str) -> int:  # type: ignore[override]
        if self._console is not None:
            try:
                self._console.write(text)
                self._console.flush()
            except (OSError, ValueError, AttributeError):
                pass
        if not text:
            return 0
        with _LOCK:
            self._buf += text
            while "\n" in self._buf:
                line, self._buf = self._buf.split("\n", 1)
                write_line(line)
            if len(self._buf) > _NO_NEWLINE_LIMIT:   # 进度条只回 \r，别攒着
                write_line(self._buf)
                self._buf = ""
        return len(text)

    def flush(self) -> None:
        if self._console is not None:
            try:
                self._console.flush()
            except (OSError, ValueError, AttributeError):
                pass

    # ---------- 内省 ----------
    def writable(self) -> bool:
        return True

    def isatty(self) -> bool:
        try:
            return bool(self._console.isatty()) if self._console is not None else False
        except (AttributeError, ValueError):
            return False

    def fileno(self) -> int:
        return self._console.fileno()

    @property
    def encoding(self):  # type: ignore[override]
        return getattr(self._console, "encoding", "utf-8")

    @property
    def errors(self):  # type: ignore[override]
        return getattr(self._console, "errors", "replace")

    def reconfigure(self, **kwargs) -> None:
        fn = getattr(self._console, "reconfigure", None)
        if callable(fn):
            fn(**kwargs)

    def __getattr__(self, item):  # 其余属性（name / buffer / ...）继续用控制台的实现
        console = self.__dict__.get("_console")
        if console is None:
            raise AttributeError(item)
        return getattr(console, item)


def setup_logging(level: int = logging.INFO, console: bool = True) -> Path:
    """装上文件日志 + print 镜像；重复调用只生效一次，返回日志文件路径。

    ``console`` 只控制 logging 记录是否同时打到控制台；print 的文件镜像始终开启。
    """
    global _INSTALLED, _PATH

    if _INSTALLED and _PATH is not None:
        return _PATH

    stdout, stderr = sys.stdout, sys.stderr
    path = log_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    _rotate(path)
    _PATH = path
    _open_raw()

    fmt = logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s", "%Y-%m-%d %H:%M:%S")
    root = logging.getLogger()
    root.setLevel(level)

    file_handler = logging.FileHandler(path, encoding="utf-8")
    file_handler.setLevel(level)
    file_handler.setFormatter(fmt)
    root.addHandler(file_handler)

    console_stream = stdout if stdout is not None else sys.__stdout__
    if console and console_stream is not None:
        # 必须绑定原始 stdout：用 _Tee 的话记录会默认日志文件之外再镜像一次，日志翻倍
        # （pythonw 启动时没有控制台，这里整块跳过，只留文件日志）
        stream_handler = logging.StreamHandler(console_stream)
        stream_handler.setLevel(level)
        stream_handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%H:%M:%S"))
        root.addHandler(stream_handler)

    if stdout is not None:
        sys.stdout = _Tee(stdout)
    if stderr is not None:
        sys.stderr = _Tee(stderr)

    _INSTALLED = True
    logging.getLogger("myhub-collector").info("日志文件：%s", path)
    return path
