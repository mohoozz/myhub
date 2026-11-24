"""兼容层：保留旧的 B 站 / YouTube Cookie 接口，内部统一走 app.credentials。

新代码请直接用 ``app.credentials``（``cookiefile`` / ``cookie_header`` / ``status``）。
"""
from __future__ import annotations

from pathlib import Path

from app import credentials
from app.credentials import CredentialError as CookieError

__all__ = [
    "CookieError",
    "bili_cookie_header",
    "bili_cookiefile",
    "youtube_cookiefile",
    "reset_cache",
]


def bili_cookie_header() -> str:
    return credentials.cookie_header("bilibili")


def bili_cookiefile() -> Path:
    path = credentials.cookiefile("bilibili")
    if path is None:
        raise CookieError("B 站没有可用登录态，先跑：python -m app login bilibili")
    return path


def youtube_cookiefile() -> Path | None:
    return credentials.cookiefile("youtube")


def reset_cache() -> None:
    credentials.reset_cache()
