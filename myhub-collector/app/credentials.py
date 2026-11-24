"""三个平台统一的登录态层：一个目录、一种格式、一套流程。

目录约定（Netscape cookies.txt）::

    data/credentials/bilibili.txt
    data/credentials/youtube.txt
    data/credentials/douyin.txt

唯一来源：``python -m app login <platform>`` 弹窗登录后自动写入上述文件，
过期重跑即可。旧的 ``data/cookies_*.txt`` / ``YOUTUBE_COOKIEFILE`` 首次访问时
自动迁移过来，之后固定读 credentials 目录。
"""
from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import httpx

from app.config import get_settings

logger = logging.getLogger(__name__)

_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
)

_LEGACY_NAMES = {
    "bilibili": "cookies_bili.txt",
    "youtube": "cookies_youtube.txt",
    "douyin": "cookies_douyin.txt",
}


class CredentialError(RuntimeError):
    """登录态缺失或失效。"""


@dataclass(frozen=True)
class Site:
    platform: str
    title: str
    home: str
    domain: str
    login_keys: tuple[str, ...]
    add_buvid: bool = False


SITES: dict[str, Site] = {
    "bilibili": Site(
        "bilibili", "B站", "https://www.bilibili.com/", "bilibili.com",
        ("SESSDATA",), True,
    ),
    "youtube": Site(
        "youtube", "YouTube", "https://www.youtube.com/", "youtube.com",
        ("SAPISID", "__Secure-1PSID", "__Secure-3PSID", "SID"),
    ),
    "douyin": Site(
        "douyin", "抖音", "https://www.douyin.com/", "douyin.com",
        ("sessionid", "sessionid_ss"),
    ),
}


def _site(platform: str) -> Site:
    site = SITES.get(platform)
    if site is None:
        raise CredentialError(f"未收录的平台：{platform}（支持：{', '.join(SITES)}）")
    return site


# ---------------- 路径与迁移 ----------------

def credential_path(platform: str) -> Path:
    """统一的 Cookie 文件路径；旧文件存在时先迁移过来。"""
    site = _site(platform)
    settings = get_settings()
    path = settings.data_path / "credentials" / f"{site.platform}.txt"
    if path.exists():
        return path

    legacy = settings.data_path / _LEGACY_NAMES[site.platform]
    if legacy.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        legacy.replace(path)
        logger.info("已把 %s 迁移到 %s", legacy.name, path)
        return path

    if site.platform == "youtube":
        configured = settings.youtube_cookiefile.strip()
        if configured:
            source = settings._abs(configured)
            if source.exists() and source != path:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(source.read_text(encoding="utf-8", errors="replace"), encoding="utf-8")
                logger.info("已把 YOUTUBE_COOKIEFILE=%s 收编到 %s", source, path)
    return path


# ---------------- Netscape 读写 ----------------

def _read_rows(path: Path) -> list[list[str]]:
    """读 Netscape 文件；顺手修正 includeSubdomains（扩展常写错导致整份被拒）。"""
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    rows: list[list[str]] = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 7:
            continue
        if len(parts) > 7:  # value 里带 tab 时并回去
            parts = parts[:6] + ["\t".join(parts[6:])]
        parts[1] = "TRUE" if parts[0].startswith(".") else "FALSE"
        rows.append(parts)
    return rows


def _write_rows(path: Path, rows: list[list[str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["# Netscape HTTP Cookie File", "# 由 python -m app login 生成", ""]
    lines += ["\t".join(row) for row in rows]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def save_cookies(cookies: list[dict], platform: str) -> Path | None:
    """把 Playwright 的 ``context.cookies()`` 写成该平台的统一 cookies.txt。"""
    site = _site(platform)
    rows: list[list[str]] = []
    for c in cookies:
        domain = str(c.get("domain") or "")
        if site.domain not in domain:
            continue
        rows.append(
            [
                domain,
                "TRUE" if domain.startswith(".") else "FALSE",
                str(c.get("path") or "/"),
                "TRUE" if c.get("secure") else "FALSE",
                str(int(c.get("expires") or 0)),
                str(c.get("name") or ""),
                str(c.get("value") or ""),
            ]
        )
    if not rows:
        return None
    path = credential_path(platform)
    _write_rows(path, rows)
    return path


def _key_map(rows: list[list[str]]) -> dict[str, str]:
    return {row[5]: row[6] for row in rows}


def _login_keys_in(rows: list[list[str]], site: Site) -> tuple[str, ...]:
    found = tuple(k for k in site.login_keys if k in _key_map(rows))
    return found


def _logindata_expiry(rows: list[list[str]]) -> str:
    stamps = [int(row[4]) for row in rows if row[4].isdigit() and int(row[4]) > 0]
    if not stamps:
        return "会话级"
    ts = min(stamps)
    when = datetime.fromtimestamp(ts)
    mark = "已过期" if ts < time.time() else ""
    return f"{when:%Y-%m-%d %H:%M}{mark}"


# ---------------- B 站的 Cookie 补全 ----------------

def _add_buvid(path: Path, rows: list[list[str]], site: Site) -> list[list[str]]:
    """补 buvid3 / b_nut：只填 SESSDATA 的 Cookie 很容易被 -352 拦。"""
    names = set(_key_map(rows))
    if "buvid3" in names:
        return rows
    try:
        with httpx.Client(
            headers={"User-Agent": _UA}, timeout=10, trust_env=False, follow_redirects=True
        ) as client:
            resp = client.get(site.home)
        for raw in resp.headers.get_list("set-cookie"):
            name, _, rest = raw.partition("=")
            value = rest.split(";", 1)[0].strip()
            if name in ("buvid3", "buvid4", "b_nut") and value and name not in names:
                rows.append([".bilibili.com", "TRUE", "/", "FALSE", "0", name, value])
                names.add(name)
        if len(names) > 1:
            _write_rows(path, rows)
    except Exception:  # noqa: BLE001
        logger.debug("补 buvid 失败，忽略")
    return rows


def _ensure_rows(platform: str) -> list[list[str]]:
    """唯一来源：data/credentials/<platform>.txt（由 login 命令写入）。"""
    site = _site(platform)
    path = credential_path(platform)
    rows = _read_rows(path)
    if site.add_buvid and _login_keys_in(rows, site):
        rows = _add_buvid(path, rows, site)
    return rows


# ---------------- 对外接口 ----------------

def cookiefile(platform: str) -> Path | None:
    """给 yt-dlp / httpx 用的统一 cookies.txt；没有有效登录态返回 None。"""
    site = _site(platform)
    rows = _ensure_rows(platform)
    if not _login_keys_in(rows, site):
        return None
    return credential_path(platform)


def cookie_header(platform: str) -> str:
    """把统一 cookies.txt 拼成请求头；缺登录票据直接报错。"""
    site = _site(platform)
    rows = _ensure_rows(platform)
    found = _login_keys_in(rows, site)
    if not found:
        raise CredentialError(
            f"{site.title} 没有可用登录态。先跑：python -m app login {platform}"
        )
    pairs: list[str] = []
    seen: set[str] = set()
    for row in rows:
        if site.domain not in row[0] or row[5] in seen:
            continue
        seen.add(row[5])
        pairs.append(f"{row[5]}={row[6]}")
    return "; ".join(pairs)


def status(platform: str) -> "CredentialStatus":
    """离线自检：是否登录、来源、关键 Cookie、过期时间。"""
    site = _site(platform)
    path = credential_path(platform)
    rows = _read_rows(path)
    source = f"credentials/{path.name}" if rows else ""
    found = _login_keys_in(rows, site)
    return CredentialStatus(
        platform=site.platform,
        title=site.title,
        path=path,
        exists=path.exists(),
        ok=bool(found),
        keys=found,
        missing=tuple(k for k in site.login_keys if k not in found),
        expires=_logindata_expiry(rows) if rows else "-",
        source=source or "（无）",
        hint="" if found else f"python -m app login {platform}",
    )


@dataclass
class CredentialStatus:
    platform: str
    title: str
    path: Path
    exists: bool
    ok: bool
    keys: tuple[str, ...]
    missing: tuple[str, ...]
    expires: str
    source: str
    hint: str


def reset_cache() -> None:
    """保留旧接口：统一层不再做进程内缓存。"""
    return None
