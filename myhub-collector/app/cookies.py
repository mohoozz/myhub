"""B 站登录态：配置值 → 本地缓存 → 读浏览器，三级回落。

Chrome 127+ 启用了 app-bound encryption，第三方读 Cookie 数据库基本会失败
（这是 Google 的安全设计），所以最稳的是把 SESSDATA 写进 .env，或粘贴整段 Cookie。
"""
from __future__ import annotations

import http.cookiejar
import logging
from pathlib import Path

import httpx
from yt_dlp.cookies import YoutubeDLCookieJar, extract_cookies_from_browser

from app.config import get_settings

logger = logging.getLogger(__name__)

HOME = "https://www.bilibili.com/"
_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
)

_jar_cache: YoutubeDLCookieJar | None = None


class CookieError(RuntimeError):
    """登录态缺失或无效。"""


# ---------------- 基础 ----------------

def _mk_cookie(name: str, value: str) -> http.cookiejar.Cookie:
    return http.cookiejar.Cookie(
        version=0, name=name, value=value, port=None, port_specified=False,
        domain=".bilibili.com", domain_specified=True, domain_initial_dot=True,
        path="/", path_specified=True, secure=False, expires=None, discard=False,
        comment=None, comment_url=None, rest={}, rfc2109=False,
    )


def find_cookie(jar, name: str) -> str | None:
    for c in jar:
        if c.name == name and "bilibili.com" in (c.domain or ""):
            return c.value
    return None


def cookie_header(jar) -> str:
    """把 bilibili.com 域的 Cookie 拼成请求头字符串。"""
    pairs: list[str] = []
    seen: set[str] = set()
    for c in jar:
        if "bilibili.com" not in (c.domain or "") or c.name in seen:
            continue
        seen.add(c.name)
        pairs.append(f"{c.name}={c.value}")
    return "; ".join(pairs)


def _from_header(header: str) -> YoutubeDLCookieJar:
    """把 "a=1; b=2" 形式的 Cookie 头解析成 jar。"""
    jar = YoutubeDLCookieJar()
    for part in (header or "").split(";"):
        name, sep, value = part.partition("=")
        name = name.strip()
        if sep and name:
            jar.set_cookie(_mk_cookie(name, value.strip()))
    return jar


def _add_buvid(jar) -> None:
    """补 buvid3 / b_nut / buvid4，降低接口风控概率（失败不影响主流程）。

    注意：旧的 x/frontend/finger/spider 接口已下线（404），现在由首页下发 buvid3。
    只填了 SESSDATA 的 Cookie 通常仍会被 -352 拦截，建议直接粘贴浏览器里整段 Cookie。
    """
    try:
        with httpx.Client(
            headers={"User-Agent": _UA}, timeout=10, trust_env=False, follow_redirects=True
        ) as client:
            resp = client.get(HOME)
        for raw in resp.headers.get_list("set-cookie"):
            name, _, rest = raw.partition("=")
            name = name.strip()
            value = rest.split(";", 1)[0].strip()
            if name in ("buvid3", "buvid4", "b_nut") and value and not find_cookie(jar, name):
                jar.set_cookie(_mk_cookie(name, value))
    except Exception:  # noqa: BLE001
        logger.debug("获取 buvid 失败，忽略")


# ---------------- 三级来源 ----------------

def _load_cached(path: Path) -> YoutubeDLCookieJar | None:
    if not path.exists():
        return None
    try:
        jar = YoutubeDLCookieJar(str(path))
        jar.load(ignore_discard=True, ignore_expires=True)
        return jar
    except Exception:  # noqa: BLE001
        return None


def _from_browser() -> YoutubeDLCookieJar:
    settings = get_settings()
    try:
        return extract_cookies_from_browser(settings.bili_browser, settings.bili_profile or None)
    except Exception as e:  # noqa: BLE001
        raise CookieError(
            f"读取 {settings.bili_browser} Cookie 失败：{e}\n"
            "  · Chrome 127+ 有 app-bound 加密，第三方通常读不出来（属正常现象）\n"
            "  · 请在 .env 里配置 BILI_COOKIE=<整段 Cookie>（至少含 SESSDATA）\n"
            "  · 或改 BILI_BROWSER=firefox 后重试"
        ) from e


def get_bili_jar() -> YoutubeDLCookieJar:
    """拿到带登录态的 Cookie jar（进程内缓存）。"""
    global _jar_cache
    if _jar_cache is not None:
        return _jar_cache

    settings = get_settings()
    jar: YoutubeDLCookieJar | None = None

    if settings.bili_cookie.strip():
        jar = _from_header(settings.bili_cookie)
        source = ".env 中的 BILI_COOKIE"
    if jar is None:
        jar = _load_cached(settings.cookie_cache)
        source = f"本地缓存 {settings.cookie_cache}"
    if jar is None:
        jar = _from_browser()
        source = f"浏览器 {settings.bili_browser}"

    if not find_cookie(jar, "SESSDATA"):
        raise CookieError(
            f"{source} 中没有 SESSDATA（未登录或 Cookie 已失效）。\n"
            "在浏览器登录 bilibili.com → F12 → 应用 → Cookie，把整段复制到 .env：\n"
            "  BILI_COOKIE=SESSDATA=xxx; bili_jct=xxx; DedeUserID=xxx"
        )

    _add_buvid(jar)
    try:
        settings.ensure_dirs()
        jar.save(str(settings.cookie_cache))
    except Exception:  # noqa: BLE001
        logger.debug("Cookie 缓存写入失败，忽略")

    logger.info("B 站登录态来源：%s", source)
    _jar_cache = jar
    return jar


def bili_cookie_header() -> str:
    return cookie_header(get_bili_jar())


def bili_cookiefile() -> Path:
    """给 yt-dlp 用的 Cookie 文件（与 API 共用同一份登录态）。"""
    get_bili_jar()
    path = get_settings().cookie_cache
    if not path.exists():
        raise CookieError(f"Cookie 缓存文件不存在：{path}")
    return path


def reset_cache() -> None:
    """Cookie 更新后清掉进程内缓存。"""
    global _jar_cache
    _jar_cache = None
