"""yt-dlp 封装：B 站 / YouTube 通用（视频 + 音频）。"""
from __future__ import annotations

import logging
import os
import shutil
from pathlib import Path

import yt_dlp

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
) -> tuple[bool, str, str]:
    """下载单个视频/音频，返回 (是否成功, 本地路径, 错误信息)。

    单 P 已存在则直接跳过；多 P 会交给 yt-dlp 逐个跳过已下好的分 P。
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
