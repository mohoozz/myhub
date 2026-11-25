"""yt-dlp 封装：B 站 / YouTube 通用（视频 + 音频）。"""
from __future__ import annotations

import logging
import os
import shutil
from pathlib import Path

import yt_dlp

from app.utils import DURATION_SKIP_PREFIX, fmt_duration

logger = logging.getLogger(__name__)

QUALITY_FORMATS = {
    "best": "bv*+ba/b",
    "1080": "bv*[height<=1080]+ba/b[height<=1080]/b",
    "720": "bv*[height<=720]+ba/b[height<=720]/b",
    "audio": "ba/b",
}

# YouTube 用 res（短边）而不是 height：竖屏 Shorts 的 height 是 1920，
# 按 height 限 1080 会退化到 608x1080。B 站 extractor 没有 res 字段，只能用上面那份。
YOUTUBE_QUALITY_FORMATS = {
    "best": "bv*+ba/b",
    "1080": "bv*[res<=1080]+ba/b[res<=1080]/b",
    "720": "bv*[res<=720]+ba/b[res<=720]/b",
    "audio": "ba/b",
}

_SINGLE_STREAM = "best[acodec!=none][vcodec!=none]/best"
_PART_SUFFIXES = (".part", ".ytdl", ".temp")
# 超时长视频只落一张预览卡片（stem.html），它不是视频成品；调大时长上限后
# 重新下载时不能被它挡住「已存在」的判断。
_CARD_SUFFIXES = (".html", ".htm")


def _ffmpeg_dir(location: str = "") -> str:
    """返回可用的 ffmpeg 目录（配置优先），没有则返回空串。"""
    if location:
        p = Path(location)
        exe = p / ("ffmpeg.exe" if os.name == "nt" else "ffmpeg")
        if exe.exists():
            return str(p)
    return ""


def ffmpeg_available(location: str = "") -> bool:
    return bool(_ffmpeg_dir(location)) or shutil.which("ffmpeg") is not None


def find_deno() -> str:
    """定位 YouTube 解 JS 挑战用的 Deno：项目内置优先，其次 PATH。

    YouTube 的 nsig / n 挑战必须有 JS 运行时，否则只能拿到 storyboard 预览图。
    内置位置：<DATA_DIR>/tools/deno/deno.exe（deno 单文件，约 40MB，不进 git）。
    """
    from app.config import get_settings

    exe = "deno.exe" if os.name == "nt" else "deno"
    bundled = get_settings().data_path / "tools" / "deno" / exe
    if bundled.exists():
        return str(bundled)
    return shutil.which("deno") or ""


class _ErrorCollector:
    """收集 yt-dlp 的错误日志：ignoreerrors 会把异常吞掉，至少要把原因留下来。"""

    def __init__(self) -> None:
        self.errors: list[str] = []

    def debug(self, msg: str) -> None:
        pass

    def info(self, msg: str) -> None:
        pass

    def warning(self, msg: str) -> None:
        text = str(msg).strip()
        if text.startswith("ERROR"):
            self.errors.append(text)

    def error(self, msg: str) -> None:
        text = str(msg).strip()
        if text:
            self.errors.append(text)

    def last_error(self) -> str:
        for msg in reversed(self.errors):
            if msg:
                return msg
        return ""


def _on_progress(d: dict) -> None:
    """yt-dlp 进度钩子 → 当前任务的结构化进度（没有任务在跑时自动忽略）。"""
    from app import jobs

    info = d.get("info_dict") or {}
    status = str(d.get("status") or "")
    title = str(info.get("title") or "").strip()
    if not title:
        name = str(d.get("filename") or "")
        title = Path(name).name if name else ""
    title = title[:60]

    if status == "downloading":
        total = int(d.get("total_bytes") or d.get("total_bytes_estimate") or 0)
        done = int(d.get("downloaded_bytes") or 0)
        jobs.report_progress(
            stage="下载",
            title=title,
            percent=round(done * 100 / total, 1) if total else 0.0,
            downloaded=done,
            size=total,
            speed=float(d.get("speed") or 0.0),
            eta=int(d.get("eta") or 0),
        )
    elif status == "finished":
        size = int(
            d.get("total_bytes") or d.get("total_bytes_estimate")
            or d.get("downloaded_bytes") or 0
        )
        jobs.report_progress(
            stage="下载", title=title, percent=100.0,
            downloaded=size, size=size, speed=0.0, eta=0,
        )


def _on_postprocess(d: dict) -> None:
    """合并音视频 / 转码没有字节进度，只把当前阶段写清楚。"""
    from app import jobs

    if str(d.get("status") or "") in ("started", "processing"):
        jobs.report_progress(stage="合并 / 转码", percent=100.0, speed=0.0, eta=0)


def quality_format(quality: str, platform: str = "bilibili") -> str:
    table = YOUTUBE_QUALITY_FORMATS if platform == "youtube" else QUALITY_FORMATS
    return table.get(quality, table["1080"])


def build_opts(
    out_dir: Path,
    stem: str,
    quality: str = "1080",
    platform: str = "bilibili",
    cookiefile: Path | None = None,
    proxy: str = "direct",
    ffmpeg_location: str = "",
    cookies_from_browser: tuple | None = None,
    js_runtimes: dict | None = None,
) -> dict:
    """构造 yt-dlp 选项；stem 为不含扩展名的固定文件名（便于幂等判断）。"""
    has_ffmpeg = ffmpeg_available(ffmpeg_location)
    fmt = quality_format(quality, platform)
    if not has_ffmpeg:
        # 没有 ffmpeg 不能合并音视频，退化成单文件流
        fmt = _SINGLE_STREAM

    opts: dict = {
        # 多 P 视频要展开成 playlist，文件名按 P 号追加 -[Pn]（单视频这段为空）
        "noplaylist": False,
        "ignoreerrors": True,
        "no_warnings": True,
        "quiet": True,
        "noprogress": True,
        "retries": 10,
        "fragment_retries": 10,
        "socket_timeout": 30,
        "windowsfilenames": True,
        "continuedl": True,
        "overwrites": False,
        "format": fmt,
        "outtmpl": str(out_dir / f"{stem}%(playlist_index&-[P{{}}]|)s.%(ext)s"),
        # 门户的实时进度：只写内存里的任务字段，命令行跑采集时是空操作
        "progress_hooks": [_on_progress],
        "postprocessor_hooks": [_on_postprocess],
    }
    if has_ffmpeg:
        # B 站无损音轨是 FLAC，固定 mp4 会导致合并失败，故允许 mp4/mkv
        opts["merge_output_format"] = "mp4/mkv"
        if (dir_ := _ffmpeg_dir(ffmpeg_location)):
            opts["ffmpeg_location"] = dir_
    if quality == "audio" and has_ffmpeg:
        opts["postprocessors"] = [{"key": "FFmpegExtractAudio", "preferredcodec": "m4a"}]
    if cookiefile:
        opts["cookiefile"] = str(cookiefile)
    if cookies_from_browser:
        opts["cookiesfrombrowser"] = cookies_from_browser
    if js_runtimes:
        opts["js_runtimes"] = js_runtimes
    # "direct"/空 强制直连（B 站等国内站点）；"system" 交给 yt-dlp 默认（读环境变量代理）
    if proxy != "system":
        opts["proxy"] = "" if proxy in ("", "direct") else proxy
    return opts


def find_files(out_dir: Path, stem: str) -> list[Path]:
    """找出与 stem 匹配的成品文件（含多 P 的 stem-[Pn].ext），排除 .part 等中间文件。

    注意：stem 里带 "[BV号]" 这样的方括号，glob 会把 [] 当成字符集，
    匹配不到真实文件，所以这里改用前缀遍历，不能用 out_dir.glob()。
    """
    if not out_dir.exists():
        return []
    found: list[Path] = []
    for path in out_dir.iterdir():
        if not path.is_file() or path.name.endswith(_PART_SUFFIXES):
            continue
        if path.suffix.lower() in _CARD_SUFFIXES:
            continue
        if not path.name.startswith(stem):
            continue
        rest = path.name[len(stem):]
        if rest.startswith(".") or rest.startswith("-[P"):
            found.append(path)
    return sorted(found)


def find_file(out_dir: Path, stem: str) -> Path | None:
    """兼容旧用法：命中即返回第一个文件。"""
    files = find_files(out_dir, stem)
    return files[0] if files else None


def _total_duration(info: dict | None) -> int:
    """单视频取 duration；playlist（B 站多 P / YouTube 播放列表）把各条累加。"""
    if not isinstance(info, dict):
        return 0
    entries = info.get("entries")
    if isinstance(entries, list) and entries:
        return sum(
            int((entry or {}).get("duration") or 0)
            for entry in entries
            if isinstance(entry, dict)
        )
    try:
        return int(info.get("duration") or 0)
    except (TypeError, ValueError):
        return 0


def duration_skip_error(total: int, limit_sec: int) -> str:
    """超时长跳过的统一文案；pipeline 按 DURATION_SKIP_PREFIX 识别后记为 skipped。"""
    return f"{DURATION_SKIP_PREFIX}：{fmt_duration(total)} 超过上限 {limit_sec // 60} 分钟"


def _probe_total_duration(url: str, opts: dict) -> int:
    """只解析不下载，尽量拿到真实总时长；失败返回 0（按不限制处理，绝不误杀）。

    用一份去掉 format 的独立配置来探测：用户选的清晰度对某些视频并不存在，
    带 format 会在拿到 duration 之前就报 "Requested format is not available"。
    同时去掉 logger，避免探测的报错污染真正的下载错误信息。
    """
    probe_opts = dict(opts)
    probe_opts.pop("format", None)
    probe_opts.pop("logger", None)
    probe_opts.update({"quiet": True, "no_warnings": True, "skip_download": True})
    try:
        with yt_dlp.YoutubeDL(probe_opts) as probe:
            info = probe.extract_info(url, download=False)
    except Exception as e:  # noqa: BLE001
        logger.info("时长探测失败（按不限制处理）%s: %s", url, e)
        return 0
    return _total_duration(info)


def download(
    url: str,
    out_dir: Path,
    stem: str,
    quality: str = "1080",
    platform: str = "bilibili",
    cookiefile: Path | None = None,
    proxy: str = "direct",
    ffmpeg_location: str = "",
    cookies_from_browser: tuple | None = None,
    js_runtimes: dict | None = None,
    max_duration_sec: int = 0,
) -> tuple[bool, str, str]:
    """下载单个视频/音频，返回 (是否成功, 本地路径, 错误信息)。

    单 P 已存在则直接跳过；多 P 会交给 yt-dlp 逐个跳过已下好的分 P。
    max_duration_sec > 0 时先只解析拿总时长（多 P 求和），超限直接返回不下载；
    没超限再按用户原配置正常下载（多一次元数据解析，换取清晰度不被探测污染）。
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    if (existing := find_files(out_dir, stem)) and not any("-[P" in p.name for p in existing):
        return True, str(existing[0]), "已存在"

    collector = _ErrorCollector()
    try:
        opts = build_opts(
            out_dir, stem, quality, platform, cookiefile, proxy, ffmpeg_location,
            cookies_from_browser, js_runtimes,
        )
        if max_duration_sec > 0:
            total = _probe_total_duration(url, opts)
            if total > max_duration_sec:
                return False, "", duration_skip_error(total, max_duration_sec)
        opts["logger"] = collector
        with yt_dlp.YoutubeDL(opts) as ydl:
            ydl.download([url])
    except Exception as e:  # noqa: BLE001
        logger.warning("yt-dlp 异常 %s: %s", url, e)
        return False, "", str(e)[:300]

    if (found := find_files(out_dir, stem)):
        return True, str(found[0]), ""
    reason = collector.last_error() or "下载结束但没有输出文件（详见 yt-dlp 日志）"
    logger.warning("yt-dlp 未产出文件 %s：%s", url, reason)
    return False, "", reason[:300]
