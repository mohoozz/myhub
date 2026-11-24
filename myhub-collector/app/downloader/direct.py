"""直链下载：抖音的作品 JSON 里直接给了 mp4 地址，用 httpx 流式落盘。

为什么不走 yt-dlp：
- yt-dlp 的抖音提取器要「新鲜 cookie」，一命中验证页就报错；
- 直链只认 UA + Referer，单文件、无音视频合并，失败点少、日志清楚。
"""
from __future__ import annotations

import logging
import time
from pathlib import Path

import httpx

logger = logging.getLogger(__name__)

_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)
_CHUNK = 1 << 20


def _client(proxy: str, timeout: float) -> httpx.Client:
    opts: dict = {"timeout": timeout, "follow_redirects": True}
    if proxy in ("", "direct"):
        opts["trust_env"] = False
    elif proxy == "system":
        opts["trust_env"] = True
    else:
        opts["proxy"] = proxy
    return httpx.Client(**opts)


def download_direct(
    url: str,
    out_dir: Path,
    stem: str,
    referer: str = "https://www.douyin.com/",
    proxy: str = "direct",
    retries: int = 3,
    suffix: str = ".mp4",
) -> tuple[bool, str, str]:
    """把直链存成 <stem><suffix>，返回 (是否成功, 路径, 错误信息)。"""
    if not url:
        return False, "", "直链为空"

    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / f"{stem}{suffix}"
    if target.exists() and target.stat().st_size > 0:
        return True, str(target), "已存在"

    headers = {"User-Agent": _UA, "Referer": referer or "https://www.douyin.com/"}
    part = target.with_suffix(target.suffix + ".part")
    last_error = ""

    for attempt in range(1, max(retries, 1) + 1):
        try:
            with _client(proxy, timeout=60) as client:
                with client.stream("GET", url, headers=headers) as resp:
                    resp.raise_for_status()
                    with part.open("wb") as fh:
                        for chunk in resp.iter_bytes(_CHUNK):
                            if chunk:
                                fh.write(chunk)
            if part.stat().st_size <= 0:
                raise OSError("下载到的文件为空")
            part.replace(target)
            return True, str(target), ""
        except Exception as e:  # noqa: BLE001 重试后仍失败才放弃
            last_error = f"{type(e).__name__}: {e}"[:300]
            logger.debug("直链下载失败（第 %d 次）：%s", attempt, last_error)
            part.unlink(missing_ok=True)
            if attempt < retries:
                time.sleep(min(2 * attempt, 5))

    return False, "", last_error or "下载失败"
