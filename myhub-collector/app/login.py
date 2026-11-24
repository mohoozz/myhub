"""统一的登录入口：``python -m app login <platform>``。

三个平台同一套流程：弹出独立浏览器窗口（不影响你日常用的浏览器）→
你在窗口里手动登录 → 检测到登录态后自动导出 ``data/credentials/<platform>.txt``
→ 关窗口。中途关窗口随时可退出。
"""
from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from pathlib import Path

from app import browser, credentials
from app.config import get_settings

logger = logging.getLogger(__name__)

POLL_SECONDS = 1.5
"""轮询登录态的间隔。"""


@dataclass(frozen=True)
class Target:
    url: str
    settle_ms: int
    hint: str


TARGETS: dict[str, Target] = {
    "bilibili": Target(
        "https://www.bilibili.com/", 3000, "点页面右上角「登录」，扫码或账号密码都可以"
    ),
    "youtube": Target(
        "https://www.youtube.com/", 4000, "点页面右上角「登录」（打不开就先在 .env 配 PROXY）"
    ),
    "douyin": Target(
        "https://www.douyin.com/", 3000, "扫码登录抖音"
    ),
}


def _profile(platform: str, override: str) -> Path:
    if override.strip():
        return Path(override).expanduser().resolve()
    settings = get_settings()
    if platform == "douyin":
        return settings.douyin_profile
    return settings.browser_profile(platform)


def _channel() -> str:
    """三个平台统一用 BROWSER_CHANNEL（profile 路径能认出 Edge/Chrome 时会再覆盖一次）。"""
    return get_settings().browser_channel


def _proxy(platform: str) -> str:
    settings = get_settings()
    if platform == "douyin":
        return settings.douyin_proxy or settings.proxy
    if platform == "youtube":
        return settings.youtube_proxy or settings.proxy
    return settings.proxy


def _profile_name(platform: str) -> str:
    return get_settings().douyin_profile_name if platform == "douyin" else ""


def _still_open(ctx) -> bool:
    try:
        return bool(ctx.pages)
    except Exception:  # noqa: BLE001 上下文已销毁
        return False


def _logged_in(ctx, keys: tuple[str, ...]) -> bool:
    try:
        return browser.logged_in(ctx, keys)
    except Exception:  # noqa: BLE001 窗口被关掉时会抛
        return False


def _open(pw, platform: str, profile: Path, headless: bool):
    channel = browser.guess_channel(profile, _channel())
    try:
        return browser.launch_context(
            pw, profile, headless, channel, _proxy(platform), _profile_name(platform)
        )
    except Exception as e:  # noqa: BLE001 本机没装 Chrome 时退回自带 Chromium
        logger.warning("用 %s 启动失败（%s），改用 Playwright 自带 Chromium", channel or "chromium", e)
        return browser.launch_context(
            pw, profile, headless, "", _proxy(platform), _profile_name(platform)
        )


def login(
    platform: str,
    wait_seconds: int = 300,
    profile: str = "",
    headless: bool = False,
) -> tuple[bool, Path | None]:
    """弹窗等待手动登录，成功后导出统一格式的 cookies.txt。

    返回 ``(是否已登录, 导出文件路径)``；用户中途关窗口会立刻返回，不空等。
    """
    site = credentials.SITES.get(platform)
    target = TARGETS.get(platform)
    if site is None or target is None:
        raise credentials.CredentialError(
            f"不支持的平台：{platform}（支持：{', '.join(TARGETS)}）"
        )

    current = credentials.status(platform)
    if current.ok:
        print(
            f"当前已有 {site.title} 登录态（{current.source}，过期时间 {current.expires}）；"
            "重新登录成功会覆盖它。"
        )

    from playwright.sync_api import sync_playwright

    profile_dir = _profile(platform, profile)
    if browser.profile_locked(profile_dir):
        raise credentials.CredentialError(
            f"浏览器正在占用 profile：{profile_dir}\n先完全退出该浏览器（含托盘/后台进程）再跑"
        )
    profile_dir.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as pw:
        ctx = _open(pw, platform, profile_dir, headless)
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        try:
            page.goto(target.url, wait_until="domcontentloaded", timeout=90000)
        except Exception as e:  # noqa: BLE001 代理未开时 YouTube 会走到这里
            ctx.close()
            raise credentials.CredentialError(
                f"打开 {target.url} 失败：{type(e).__name__}: {e}\n"
                + ("需要代理就先在 .env 里配 PROXY / YOUTUBE_PROXY 再跑" if platform == "youtube" else "检查网络后重试")
            ) from e

        page.wait_for_timeout(target.settle_ms)

        ok = _logged_in(ctx, site.login_keys)
        if ok:
            print("这个浏览器里已经有登录态，直接重新导出。")
        elif wait_seconds > 0:
            print(f"浏览器已打开：{target.hint}")
            print(f"登录成功会自动继续（最多等 {wait_seconds} 秒，直接关窗口也能取消）。")
            deadline = time.monotonic() + wait_seconds
            while time.monotonic() < deadline:
                if not _still_open(ctx):
                    print("窗口已关闭，取消登录。")
                    break
                time.sleep(POLL_SECONDS)
                if _logged_in(ctx, site.login_keys):
                    ok = True
                    print("已检测到登录态，正在导出 Cookie…")
                    break
            if not ok:
                print("等待结束，仍未检测到登录态。")
        else:
            print(f"浏览器已打开：{target.hint}")
            print("完成后回到终端按回车继续…")
            try:
                input()
            except EOFError:
                time.sleep(3)
            ok = _logged_in(ctx, site.login_keys)

        saved: Path | None = None
        if ok:
            time.sleep(1)  # 等最后一次 Set-Cookie 落定
            try:
                saved = credentials.save_cookies(ctx.cookies(), platform)
            except Exception as e:  # noqa: BLE001 窗口已关就导不出
                logger.warning("导出 Cookie 失败：%s", e)
                ok = False

        try:
            ctx.close()
        except Exception:  # noqa: BLE001 用户可能已经手动关掉
            pass

    return ok, saved


def login_all(
    platforms: list[str] | None = None,
    wait_seconds: int = 300,
) -> dict[str, tuple[bool, Path | None]]:
    """逐个弹出浏览器登录（默认三个平台全跑），单个失败不影响后面。"""
    order = platforms or list(TARGETS)
    results: dict[str, tuple[bool, Path | None]] = {}
    for index, platform in enumerate(order, 1):
        title = credentials.SITES[platform].title
        print(f"\n=== [{index}/{len(order)}] {title} ===")
        try:
            results[platform] = login(platform, wait_seconds=wait_seconds)
        except credentials.CredentialError as e:
            print(f"{title} 跳过：{e}")
            results[platform] = (False, None)
        if not results[platform][0]:
            print(f"{title} 未完成，之后可单独补：python -m app login {platform}")
    return results
