"""Playwright 的公共封装：持久化上下文、登录判定、profile 占用检测。

抖音抓取与三个平台的登录命令共用这一层，避免各写一份。
"""
from __future__ import annotations

import logging
from pathlib import Path

logger = logging.getLogger(__name__)


def launch_context(
    pw,
    profile: Path,
    headless: bool = False,
    channel: str = "",
    proxy: str = "",
    profile_name: str = "",
):
    """启动持久化上下文（复用 profile 里的登录态）。"""
    args = ["--disable-blink-features=AutomationControlled"]
    if profile_name:
        args.append(f"--profile-directory={profile_name}")
    kwargs: dict = {
        "user_data_dir": str(profile),
        "headless": headless,
        "locale": "zh-CN",
        "viewport": {"width": 1440, "height": 900},
        "accept_downloads": True,
        "args": args,
    }
    if channel:
        kwargs["channel"] = channel
    if proxy and proxy not in ("", "direct", "system"):
        kwargs["proxy"] = {"server": proxy}
    return pw.chromium.launch_persistent_context(**kwargs)


def guess_channel(profile: Path, channel: str) -> str:
    """Cookie 是 app-bound 加密的，必须用当初写入它的那个浏览器打开，否则解不开。"""
    text = str(profile).lower()
    if "microsoft" in text and "edge" in text:
        return "msedge"
    if "google" in text and "chrome" in text:
        return "chrome"
    return channel


def profile_locked(profile: Path) -> bool:
    """判断 profile 是否正被浏览器占用（Cookies 库被独占打开就说明在跑）。"""
    cookie_dbs = list(profile.glob("*/Network/Cookies")) + list(profile.glob("Network/Cookies"))
    if not cookie_dbs:
        return False
    for db in cookie_dbs:
        try:
            with db.open("rb"):
                pass
        except OSError:
            return True
    return False


def logged_in(ctx, keys: tuple[str, ...]) -> bool:
    """浏览器上下文里是否存在该平台的登录票据。"""
    names = {c.get("name") for c in ctx.cookies()}
    return any(key in names for key in keys)
