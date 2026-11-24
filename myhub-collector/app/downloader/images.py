"""图片下载：图文动态 / 专栏封面（B 站图床需要带 Referer）。"""
from __future__ import annotations

import logging
from pathlib import Path
from urllib.parse import urlsplit

import httpx

logger = logging.getLogger(__name__)

_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
)
_ALLOWED_EXT = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif"}


def _ext_of(url: str) -> str:
    suffix = Path(urlsplit(url).path).suffix.lower()
    return suffix if suffix in _ALLOWED_EXT else ".jpg"


def download_images(
    urls: list[str],
    out_dir: Path,
    referer: str = "https://www.bilibili.com/",
) -> tuple[list[Path], list[str]]:
    """下载一组图片到 out_dir，返回 (成功路径列表, 错误列表)。序号命名，幂等跳过。"""
    if not urls:
        return [], []
    out_dir.mkdir(parents=True, exist_ok=True)
    saved: list[Path] = []
    errors: list[str] = []

    with httpx.Client(
        headers={"User-Agent": _UA, "Referer": referer},
        timeout=30,
        follow_redirects=True,
        trust_env=False,
    ) as client:
        for index, url in enumerate(urls, start=1):
            target = out_dir / f"{index:02d}{_ext_of(url)}"
            if target.exists() and target.stat().st_size > 0:
                saved.append(target)
                continue
            try:
                resp = client.get(url)
                resp.raise_for_status()
                target.write_bytes(resp.content)
                saved.append(target)
            except Exception as e:  # noqa: BLE001
                logger.warning("图片下载失败 %s: %s", url, e)
                errors.append(f"{url} -> {e}")

    return saved, errors


def download_images_by_url(
    urls: list[str],
    out_dir: Path,
    referer: str = "https://www.bilibili.com/",
) -> tuple[dict[str, Path], list[str]]:
    """按 URL 下载一组小图（表情图标等），返回 ({url: 本地路径}, 错误列表)。"""
    if not urls:
        return {}, []
    out_dir.mkdir(parents=True, exist_ok=True)
    saved: dict[str, Path] = {}
    errors: list[str] = []
    with httpx.Client(
        headers={"User-Agent": _UA, "Referer": referer},
        timeout=30,
        follow_redirects=True,
        trust_env=False,
    ) as client:
        for index, url in enumerate(urls, start=1):
            target = out_dir / f"{index:03d}{_ext_of(url)}"
            if target.exists() and target.stat().st_size > 0:
                saved[url] = target
                continue
            try:
                resp = client.get(url)
                resp.raise_for_status()
                target.write_bytes(resp.content)
                saved[url] = target
            except Exception as e:  # noqa: BLE001
                logger.warning("图片下载失败 %s: %s", url, e)
                errors.append(f"{url} -> {e}")
    return saved, errors
