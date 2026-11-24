"""yt-dlp 封装：B 站 / YouTube 通用（视频 + 音频）。"""
from __future__ import annotations

import logging
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

_SINGLE_STREAM = "best[acodec!=none][vcodec!=none]/best"
_PART_SUFFIXES = (".part", ".ytdl", ".temp")


def ffmpeg_available() -> bool:
    return shutil.which("ffmpeg") is not None


def build_opts(
    out_dir: Path,
    stem: str,
    quality: str = "1080",
    cookiefile: Path | None = None,
    proxy: str = "direct",
) -> dict:
    """构造 yt-dlp 选项；stem 为不含扩展名的固定文件名（便于幂等判断）。"""
    has_ffmpeg = ffmpeg_available()
    fmt = QUALITY_FORMATS.get(quality, QUALITY_FORMATS["1080"])
    if not has_ffmpeg:
        # 没有 ffmpeg 不能合并音视频，退化成单文件流
        fmt = _SINGLE_STREAM

    opts: dict = {
        "noplaylist": True,
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
        "outtmpl": str(out_dir / f"{stem}.%(ext)s"),
    }
    if has_ffmpeg:
        # B 站无损音轨是 FLAC，固定 mp4 会导致合并失败，故允许 mp4/mkv
        opts["merge_output_format"] = "mp4/mkv"
    if quality == "audio" and has_ffmpeg:
        opts["postprocessors"] = [{"key": "FFmpegExtractAudio", "preferredcodec": "m4a"}]
    if cookiefile:
        opts["cookiefile"] = str(cookiefile)
    # "direct"/空 强制直连（B 站等国内站点）；"system" 交给 yt-dlp 默认（读环境变量代理）
    if proxy != "system":
        opts["proxy"] = "" if proxy in ("", "direct") else proxy
    return opts


def find_file(out_dir: Path, stem: str) -> Path | None:
    """按固定 stem 找已下载好的文件（跳过 .part 等中间文件）。"""
    if not out_dir.exists():
        return None
    for path in out_dir.glob(f"{stem}.*"):
        if path.is_file() and not path.name.endswith(_PART_SUFFIXES):
            return path
    return None


def download(
    url: str,
    out_dir: Path,
    stem: str,
    quality: str = "1080",
    cookiefile: Path | None = None,
    proxy: str = "direct",
) -> tuple[bool, str, str]:
    """下载单个视频/音频，返回 (是否成功, 本地路径, 错误信息)。已存在则直接跳过。"""
    out_dir.mkdir(parents=True, exist_ok=True)
    if (existing := find_file(out_dir, stem)) is not None:
        return True, str(existing), "已存在"

    try:
        with yt_dlp.YoutubeDL(build_opts(out_dir, stem, quality, cookiefile, proxy)) as ydl:
            ydl.download([url])
    except Exception as e:  # noqa: BLE001
        logger.warning("yt-dlp 异常 %s: %s", url, e)
        return False, "", str(e)[:300]

    if (found := find_file(out_dir, stem)) is not None:
        return True, str(found), ""
    return False, "", "下载结束但未找到输出文件（可能被 ignoreerrors 吞掉，详见 yt-dlp 日志）"
