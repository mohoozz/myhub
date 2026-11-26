"""yt-dlp 封装：B 站 / YouTube 通用（视频 + 音频）。"""
from __future__ import annotations

import logging
import os
import re
import shutil
import subprocess
import time
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import httpx
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
# 纯音频容器：视频内容下只剩这些文件，说明音视频没合并成功或视频流没下完。
# yt-dlp 开了 ignoreerrors，这种「半成品」不会抛异常，只能靠自己认出来。
# 注意不要放 .webm：YouTube 的纯音频流也是 webm，放进去会把正常结果判成失败。
_AUDIO_SUFFIXES = frozenset(
    {".m4a", ".mp3", ".aac", ".flac", ".opus", ".ogg", ".oga", ".wav", ".wma"}
)


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


# 这些错误重试同一个 URL 没用（B 站分片锁死在一个连不通的 CDN 节点上），
# 必须重新解析拿一份新的播放地址，才会换到能连的镜像。
_TRANSIENT_HINTS = (
    "10060",  # WinError 连接超时
    "10054",  # WinError 连接被重置
    "timed out",
    "Timeout",
    "TransportError",
    "Connection reset",
    "Remote end closed",
    "EOF occurred",
    "Unable to connect",
    "Temporary failure",
)


def _transient(reason: str) -> bool:
    text = reason or ""
    return any(hint in text for hint in _TRANSIENT_HINTS)


# ===== B 站 PCDN 换源兜底 =====
# 部分视频的 DASH 播放地址只给 PCDN 边缘节点（*.edge.mountaintoys.cn:4483）。
# 实测 B 站签名不绑定 host：把 host 换成常规 CDN（upos-*），path/query/签名
# 保持不变仍然返回 206。因此保留 1080P DASH，只换一个可达 CDN。
# 主机列表优先从 playurl 响应的 backupUrl 自动学习（见 _host_pool），
# 下面的常量只是响应里全是 PCDN 时的兜底种子，不需要人工跟着 B 站改。
_BV_RE = re.compile(r"(BV[0-9A-Za-z]{10})")
_BILI_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)
_BILI_CDN_MIRRORS = (
    "upos-sz-mirrorcos.bilivideo.com",
    "upos-sz-mirrorali.bilivideo.com",
    "upos-sz-mirrorhw.bilivideo.com",
)
_BILI_QN = {"best": 120, "1080": 80, "720": 64, "480": 32}
_BILI_QN_LABEL = {120: "4K", 112: "1080P+", 80: "1080P", 74: "720P60", 64: "720P", 32: "480P", 16: "360P"}


def _cookie_header(cookiefile: Path | None) -> str:
    """Netscape cookies.txt → Cookie 请求头（SESSDATA 常是 HttpOnly 行）。"""
    if not cookiefile:
        return ""
    pairs: list[str] = []
    try:
        for line in Path(cookiefile).read_text(encoding="utf-8", errors="ignore").splitlines():
            line = line.strip()
            if line.startswith("#HttpOnly_"):
                line = line[len("#HttpOnly_"):]
            elif not line or line.startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) >= 7 and cols[5]:
                pairs.append(f"{cols[5]}={cols[6]}")
    except OSError:
        return ""
    return "; ".join(pairs)


def _bili_client(proxy: str, timeout: float = 20.0) -> httpx.Client:
    kwargs: dict = {
        "timeout": httpx.Timeout(timeout, connect=min(8.0, timeout)),
        "follow_redirects": True,
    }
    if proxy in ("", "direct"):
        kwargs["trust_env"] = False
    elif proxy != "system":
        kwargs["proxy"] = proxy
    return httpx.Client(**kwargs)


# yt-dlp 音视频分离下载的中间产物：stem.f100026.mp4 / stem-[P1].f140.m4a
_INTERMEDIATE_RE = re.compile(
    r"\.[0-9A-Za-z_-]+\.(mp4|m4a|webm|mkv|flv|ts|part|ytdl)$", re.IGNORECASE
)


def _cleanup_intermediates(out_dir: Path, stem: str) -> None:
    """删掉 DASH 半途失败留下的中间文件，避免兜底成功后还占着几十 MB 残渣。"""
    if not out_dir.exists():
        return
    for path in out_dir.iterdir():
        if not path.is_file() or not path.name.startswith(stem):
            continue
        if path.name.endswith(_PART_SUFFIXES) or _INTERMEDIATE_RE.search(path.name):
            try:
                path.unlink()
            except OSError:
                pass


def _is_pcdn(url: str) -> bool:
    return "edge.mountaintoys.cn" in url or ":4483" in url


def _replace_url_host(url: str, host: str) -> str:
    parts = urlsplit(url)
    return urlunsplit((parts.scheme or "https", host, parts.path, parts.query, parts.fragment))


def _fmt_urls(fmt: dict) -> list[str]:
    urls = [fmt.get("baseUrl") or fmt.get("base_url")]
    urls += list(fmt.get("backupUrl") or fmt.get("backup_url") or [])
    return [u for u in urls if u]


def _host_pool(dash: dict) -> list[str]:
    """从 playurl 响应里学可达的常规 CDN 主机（backupUrl 常带），静态列表只兜底。

    B 站的备用地址本身就指向常规 CDN，换成这些 host 等于用官方给的节点；
    静态列表仅在响应全是 PCDN 主机时兜底，避免以后换域名就完全失效。
    """
    learned: list[str] = []
    for key in ("video", "audio"):
        for fmt in dash.get(key) or []:
            for url in _fmt_urls(fmt):
                if _is_pcdn(url):
                    continue
                host = urlsplit(url).netloc
                if host:
                    learned.append(host)
    hosts: list[str] = []
    for host in learned + list(_BILI_CDN_MIRRORS):
        if host not in hosts:
            hosts.append(host)
    return hosts[:6]


def _candidate_urls(fmt: dict, hosts: list[str] | None = None) -> list[str]:
    """常规 CDN 地址优先，PCDN 地址放最后，只作为理论上的兜底。"""
    urls = _fmt_urls(fmt)
    if not urls:
        return []
    candidates: list[str] = [u for u in urls if not _is_pcdn(u)]
    for host in (hosts if hosts is not None else _BILI_CDN_MIRRORS):
        candidates.append(_replace_url_host(urls[0], host))
    candidates.extend(urls)
    seen: set[str] = set()
    result: list[str] = []
    for url in candidates:
        if url not in seen:
            seen.add(url)
            result.append(url)
    return result


def _pick_video_format(dash: dict, target_qn: int) -> dict | None:
    videos = [f for f in dash.get("video") or [] if f.get("baseUrl") and f.get("id")]
    if not videos:
        return None
    eligible = [f for f in videos if int(f["id"]) <= target_qn] or videos
    best_qn = max(int(f["id"]) for f in eligible)
    same = [f for f in eligible if int(f["id"]) == best_qn]
    # 优先 AVC（兼容性最好），其次 HEVC，最后 AV1
    for prefix in ("avc1", "hvc1", "hev1", "av01"):
        matched = [f for f in same if str(f.get("codecs") or "").startswith(prefix)]
        if matched:
            return max(matched, key=lambda f: int(f.get("bandwidth") or 0))
    return max(same, key=lambda f: int(f.get("bandwidth") or 0))


def _pick_audio_format(dash: dict) -> dict | None:
    audios = [f for f in dash.get("audio") or [] if f.get("baseUrl")]
    if not audios:
        return None
    aac = [f for f in audios if "mp4a" in str(f.get("codecs") or "")]
    pool = aac or audios
    return max(pool, key=lambda f: (int(f.get("id") or 0), int(f.get("bandwidth") or 0)))


def _bili_selected_is_pcdn(
    url: str, quality: str, cookiefile: Path | None, proxy: str
) -> bool:
    """开下前探测选中的 DASH 地址是否落在 PCDN；失败按“未知”处理，继续 yt-dlp。"""
    match = _BV_RE.search(url or "")
    if not match:
        return False
    bvid = match.group(1)
    target_qn = _BILI_QN.get(quality, 80)
    headers = {
        "User-Agent": _BILI_UA,
        "Referer": f"https://www.bilibili.com/video/{bvid}/",
        "Origin": "https://www.bilibili.com",
    }
    if cookie := _cookie_header(cookiefile):
        headers["Cookie"] = cookie
    try:
        with _bili_client(proxy, timeout=6.0) as client:
            view = client.get(
                "https://api.bilibili.com/x/web-interface/view",
                params={"bvid": bvid}, headers=headers,
            ).json()
            data = view.get("data") or {}
            pages = data.get("pages") or [{"cid": data.get("cid")}]
            cid = pages[0].get("cid") if pages else None
            if not cid:
                return False
            play_params = {
                "bvid": bvid, "cid": cid, "qn": target_qn,
                "fnval": 4048, "fnver": 0, "fourk": 1, "platform": "pc",
            }
            if "Cookie" not in headers:
                # 未登录时 B 站默认只给 480P，带上 try_look 才会返回全清晰度
                play_params["try_look"] = 1
            play = client.get(
                "https://api.bilibili.com/x/player/playurl",
                params=play_params,
                headers=headers,
            ).json()
            dash = (play.get("data") or {}).get("dash") or {}
            video = _pick_video_format(dash, target_qn)
            audio = _pick_audio_format(dash)
            if not video or not audio:
                return False
            urls = _fmt_urls(video) + _fmt_urls(audio)
            return any(_is_pcdn(u) for u in urls)
    except Exception:  # noqa: BLE001
        return False


def _download_stream(
    client: httpx.Client, urls: list[str], dest: Path, headers: dict, stage: str
) -> tuple[bool, str]:
    """依次尝试候选 URL，把响应流写入 dest；全部失败才返回错误。"""
    from app import jobs

    last = ""
    for url in urls:
        tmp = dest.with_name(dest.name + ".part")
        try:
            with client.stream("GET", url, headers=headers) as resp:
                resp.raise_for_status()
                total = int(resp.headers.get("content-length") or 0)
                done = 0
                with tmp.open("wb") as fh:
                    for chunk in resp.iter_bytes(1 << 20):
                        fh.write(chunk)
                        done += len(chunk)
                        if total:
                            jobs.report_progress(
                                stage=stage,
                                percent=round(done * 100 / total, 1),
                                downloaded=done, size=total,
                            )
            if tmp.stat().st_size <= 0:
                raise OSError("下载文件为空")
            tmp.replace(dest)
            return True, ""
        except Exception as e:  # noqa: BLE001
            tmp.unlink(missing_ok=True)
            last = f"{type(e).__name__}: {e}"
    return False, last[:200] or "没有可用的下载地址"


def _ffmpeg_exe(location: str = "") -> str:
    ffmpeg_dir = _ffmpeg_dir(location)
    if ffmpeg_dir:
        return str(Path(ffmpeg_dir) / ("ffmpeg.exe" if os.name == "nt" else "ffmpeg"))
    return shutil.which("ffmpeg") or ""


def _merge_av(video: Path, audio: Path, final: Path, ffmpeg_location: str) -> tuple[bool, str]:
    ffmpeg = _ffmpeg_exe(ffmpeg_location)
    if not ffmpeg:
        return False, "没有找到 ffmpeg，无法合并 1080P 音视频"
    final.unlink(missing_ok=True)
    cmd = [ffmpeg, "-y", "-loglevel", "error", "-i", str(video), "-i", str(audio), "-c", "copy"]
    if final.suffix.lower() == ".mp4":
        cmd += ["-movflags", "+faststart"]
    cmd.append(str(final))
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
    except Exception as e:  # noqa: BLE001
        final.unlink(missing_ok=True)
        return False, f"合并异常：{type(e).__name__}: {e}"
    if r.returncode != 0:
        final.unlink(missing_ok=True)
        return False, f"合并失败：{(r.stderr or '')[-200:]}"
    if not final.exists() or final.stat().st_size <= 0:
        final.unlink(missing_ok=True)
        return False, "合并后没有输出文件"
    return True, ""


def download_bilibili_dash(
    url: str,
    out_dir: Path,
    stem: str,
    quality: str = "1080",
    cookiefile: Path | None = None,
    proxy: str = "direct",
    ffmpeg_location: str = "",
) -> tuple[bool, str, str]:
    """B 站 PCDN 兜底：保留 DASH 画质，把不可达的 host 换成常规 CDN 后合并。"""
    match = _BV_RE.search(url or "")
    if not match:
        return False, "", "无法从链接解析 BV 号"
    bvid = match.group(1)
    target_qn = _BILI_QN.get(quality, 80)
    headers = {
        "User-Agent": _BILI_UA,
        "Referer": f"https://www.bilibili.com/video/{bvid}/",
        "Origin": "https://www.bilibili.com",
    }
    if cookie := _cookie_header(cookiefile):
        headers["Cookie"] = cookie

    out_dir.mkdir(parents=True, exist_ok=True)
    try:
        with _bili_client(proxy) as client:
            view = client.get(
                "https://api.bilibili.com/x/web-interface/view",
                params={"bvid": bvid}, headers=headers,
            ).json()
            if view.get("code") != 0:
                return False, "", f"取视频信息失败：{view.get('message')}"
            data = view.get("data") or {}
            pages = data.get("pages") or [{"cid": data.get("cid"), "page": 1}]
            multi = len(pages) > 1
            for page in pages:
                cid = page.get("cid")
                if not cid:
                    continue
                play_params = {
                    "bvid": bvid, "cid": cid, "qn": target_qn,
                    "fnval": 4048, "fnver": 0, "fourk": 1, "platform": "pc",
                }
                if "Cookie" not in headers:
                    play_params["try_look"] = 1
                play = client.get(
                    "https://api.bilibili.com/x/player/playurl",
                    params=play_params,
                    headers=headers,
                ).json()
                if play.get("code") != 0:
                    return False, "", f"取 DASH 地址失败：{play.get('message')}"
                dash = (play.get("data") or {}).get("dash") or {}
                video = _pick_video_format(dash, target_qn)
                audio = _pick_audio_format(dash)
                if not video or not audio:
                    return False, "", "DASH 没有可用的视频/音频流"

                qn = int(video.get("id") or target_qn)
                label = _BILI_QN_LABEL.get(qn, f"{qn}")
                if qn < target_qn:
                    logger.info(
                        "B 站只返回了 %s 流（目标 %s）%s",
                        label, _BILI_QN_LABEL.get(target_qn, target_qn), bvid,
                    )
                ext = ".mkv" if "flac" in str(audio.get("codecs") or "").lower() else ".mp4"
                index = page.get("page") or 1
                name = f"{stem}-[P{index}]{ext}" if multi else f"{stem}{ext}"
                target = out_dir / name
                if target.exists() and target.stat().st_size > 0:
                    continue

                video_path = out_dir / f"{target.stem}.video.mp4"
                audio_path = out_dir / f"{target.stem}.audio.m4a"
                hosts = _host_pool(dash)
                ok, err = _download_stream(
                    client, _candidate_urls(video, hosts), video_path,
                    headers, f"下载视频（{label} 换源）",
                )
                if not ok:
                    return False, "", f"视频流下载失败：{err}"
                ok, err = _download_stream(
                    client, _candidate_urls(audio, hosts), audio_path,
                    headers, f"下载音频（{label} 换源）",
                )
                if not ok:
                    video_path.unlink(missing_ok=True)
                    return False, "", f"音频流下载失败：{err}"

                from app import jobs

                jobs.report_progress(stage=f"合并（{label} 换源）", percent=100.0)
                ok, err = _merge_av(video_path, audio_path, target, ffmpeg_location)
                video_path.unlink(missing_ok=True)
                audio_path.unlink(missing_ok=True)
                if not ok:
                    return False, "", err
    except Exception as e:  # noqa: BLE001
        return False, "", f"1080P 换源异常：{type(e).__name__}: {e}"[:300]

    if found := find_files(out_dir, stem):
        if has_video(found, stem):
            videos = [p for p in found if p.suffix.lower() not in _AUDIO_SUFFIXES]
            # 首轮 yt-dlp 失败可能留下 stem.m4a，别让它排在 stem.mp4 前面被当成成品
            for path in found:
                if path.suffix.lower() in _AUDIO_SUFFIXES:
                    path.unlink(missing_ok=True)
            _cleanup_intermediates(out_dir, stem)
            if videos:
                return True, str(videos[0]), ""
    return False, "", "1080P 换源没有产出可用文件"


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
        # 卡死防护：单个请求 15s 没动静就算失败。B 站的 PCDN 节点（4483 端口）
        # 根本连不上，重试只是白等，快速放弃交给 CDN 换源兜底；其他平台留 4 次容错。
        "retries": 2 if platform == "bilibili" else 4,
        "fragment_retries": 2 if platform == "bilibili" else 4,
        "socket_timeout": 15,
        "extractor_retries": 1,
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

    stem 之后带两段扩展名的（stem.f137.mp4 / stem-[P1].f140.m4a）是 yt-dlp
    合并音视频时用的中间文件：合并成功后会被删掉，留下的就是合并失败的残留，
    不能算成品，否则「只有音频 / 只有视频」的半成品会被当成下载完成。
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
        if not (rest.startswith(".") or rest.startswith("-[P")):
            continue
        _, _, ext = rest.partition(".")
        if "." in ext:
            continue  # 带格式号的合并中间文件（stem.f137.mp4）
        found.append(path)
    return sorted(found)


def find_file(out_dir: Path, stem: str) -> Path | None:
    """兼容旧用法：命中即返回第一个文件。"""
    files = find_files(out_dir, stem)
    return files[0] if files else None


def _part_of(path: Path, stem: str) -> str:
    """stem-[P2].mp4 → "-[P2]"；单 P 的 stem.mp4 → ""（用于按分 P 分组）。"""
    rest = path.name[len(stem):]
    part, _, _ = rest.partition(".")
    return part if part.startswith("-[P") else ""


def _audio_only_files(files: list[Path], stem: str) -> list[Path]:
    """返回「整组只有音频」的那些分 P 的文件（单 P 就是 stem.m4a 这类）。"""
    groups: dict[str, list[Path]] = {}
    for path in files:
        groups.setdefault(_part_of(path, stem), []).append(path)
    return [
        path
        for group in groups.values()
        if all(p.suffix.lower() in _AUDIO_SUFFIXES for p in group)
        for path in group
    ]


def has_video(files: list[Path], stem: str) -> bool:
    """每个分 P 都至少有一个视频容器文件才算下全了。

    B 站音视频合并失败时会只留下 m4a，而 ignoreerrors 把错误吞掉，
    以前这里只看「有没有文件」，于是把半成品当成功写进 downloads.status=done。
    """
    if not files:
        return False
    return not _audio_only_files(files, stem)


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
    # quality=audio 时音频就是成品；其余情况必须真有视频文件，只在旧版留下的
    # 半成品（仅有 m4a）不算「已存在」，要重新下一次把视频补回来。
    want_video = quality != "audio"
    if (existing := find_files(out_dir, stem)) and not any("-[P" in p.name for p in existing):
        if not want_video or has_video(existing, stem):
            return True, str(existing[0]), "已存在"

    def _opts() -> dict:
        return build_opts(
            out_dir, stem, quality, platform, cookiefile, proxy, ffmpeg_location,
            cookies_from_browser, js_runtimes,
        )

    opts = _opts()
    if max_duration_sec > 0:
        total = _probe_total_duration(url, opts)
        if total > max_duration_sec:
            return False, "", duration_skip_error(total, max_duration_sec)

    # 开下前先探测：选中的地址全是 PCDN 时直接换源，避免先白等 yt-dlp 重试。
    if platform == "bilibili" and want_video and ffmpeg_available(ffmpeg_location):
        if _bili_selected_is_pcdn(url, quality, cookiefile, proxy):
            logger.info("检测到 B 站 PCDN 地址，直接换源下载 %s", url)
            ok_dash, path_dash, err_dash = download_bilibili_dash(
                url, out_dir, stem, quality=quality, cookiefile=cookiefile,
                proxy=proxy, ffmpeg_location=ffmpeg_location,
            )
            if ok_dash:
                logger.info("常规 CDN 换源成功 %s", url)
                return True, path_dash, ""
            logger.warning("常规 CDN 换源失败，继续走 yt-dlp %s：%s", url, err_dash[:120])

    # 最多两轮：第二轮是「重新解析」再下一次。B 站每次播放地址会分配到不同
    # 镜像节点，本轮连不上时，换一份地址往往就能下（等同于手动再点一次下载）。
    # B 站另有 PCDN 特例：某些视频的 DASH 只给 *.edge.mountaintoys.cn:4483
    # 这类被封禁的 PCDN 节点，重解析也换不掉，需要把 host 换成常规 CDN。
    reason = ""
    tried_rewrite = False
    for round_no in (1, 2):
        collector = _ErrorCollector()
        opts["logger"] = collector
        try:
            with yt_dlp.YoutubeDL(opts) as ydl:
                ydl.download([url])
        except Exception as e:  # noqa: BLE001
            logger.warning("yt-dlp 异常 %s: %s", url, e)
            reason = str(e)[:300]
        found = find_files(out_dir, stem)
        if found and (not want_video or has_video(found, stem)):
            first = next(
                (p for p in found if p.suffix.lower() not in _AUDIO_SUFFIXES),
                found[0],
            )
            return True, str(first), ""
        detail = collector.last_error() or reason
        if found and want_video:
            # 只剩音频：B 站音视频合并失败 / 视频流中断，半成品不能算成功
            names = "、".join(p.name for p in _audio_only_files(found, stem))[:120]
            reason = f"只下载到音频没有视频（{names}），多为音视频合并失败或视频流中断"
            if detail:
                reason = f"{reason}：{detail}"
        else:
            reason = detail or "下载结束但没有输出文件（详见 yt-dlp 日志）"
        if round_no == 2 or not _transient(reason):
            break
        if not tried_rewrite and platform == "bilibili" and want_video:
            tried_rewrite = True
            logger.info("DASH 不通（B 站 PCDN 节点不可达），改用常规 CDN 换源 %s", url)
            ok_dash, path_dash, err_dash = download_bilibili_dash(
                url, out_dir, stem, quality=quality, cookiefile=cookiefile,
                proxy=proxy, ffmpeg_location=ffmpeg_location,
            )
            if ok_dash:
                logger.info("常规 CDN 换源成功 %s", url)
                return True, path_dash, ""
            logger.warning("常规 CDN 换源失败 %s：%s", url, err_dash[:120])
            reason = err_dash or reason
        logger.info("网络不通，重新解析后再试一次 %s：%s", url, reason[:100])
        time.sleep(1.5)
        opts = _opts()

    logger.warning("yt-dlp 未产出可用的成品文件 %s：%s", url, reason)
    return False, "", reason[:300]
