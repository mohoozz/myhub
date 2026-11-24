"""服务配置：环境变量或 .env。登录态不放这里，统一由 `python -m app login` 管理。"""
from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

BASE_DIR = Path(__file__).resolve().parent.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=str(BASE_DIR / ".env"), extra="ignore")

    # ---------- 浏览器 ----------
    # 三平台登录 + 抖音抓取共用的通道：chrome / msedge / chromium
    # 留空 = 用 Playwright 自带 Chromium（本机没装 Chrome/Edge 时）
    browser_channel: str = "chrome"

    # ---------- 目录 ----------
    data_dir: str = "data"          # 数据库、Cookie 缓存放这里
    download_dir: str = ""          # 下载根目录（平铺存放），空 = <data>/downloads
    report_dir: str = ""            # 报告输出目录，空 = <data>/reports
    out_dir: str = ""               # 兼容旧配置：DOWNLOAD_DIR 未设置时生效

    # ---------- 抓取 ----------
    request_interval: float = 1.2   # 相邻请求/相邻作者的间隔（秒），防风控
    max_pages: int = 5              # 单个作者最多翻几页动态

    # ---------- YouTube ----------
    # 频道清单：频道 ID（UCxxx）/ @handle / 频道主页链接，逗号、空格或换行分隔
    youtube_channels: str = ""
    # 自动并入登录账号的订阅列表（需要 YOUTUBE_COOKIEFILE），默认开；只想要手填清单就设 false
    youtube_subscriptions: bool = True
    # 兼容项：指向已有的 cookies.txt 时会自动收编到 data/credentials/youtube.txt
    youtube_cookiefile: str = ""
    # 可选：YouTube 单独走代理（RSS / 视频 CDN），留空跟随 PROXY
    youtube_proxy: str = ""

    # ---------- 抖音 ----------
    # 登录态在 data/credentials/douyin.txt（先跑 python -m app login douyin 扫码一次）
    # 无头模式容易被验证码拦，默认开窗口
    douyin_headless: bool = False
    # 关注列表 / 作者主页最多滚动几次（每次约 20 条）
    douyin_max_scrolls: int = 30
    # 想直接复用本机已登录的浏览器：填它的 User Data 目录
    #   Edge  : %LOCALAPPDATA%\Microsoft\Edge\User Data
    #   Chrome: %LOCALAPPDATA%\Google\Chrome\User Data
    # 留空 = 用独立的 data/browser/douyin（扫码一次，长期有效，不打扰日常浏览器）
    douyin_user_data_dir: str = ""
    # 真实 profile 里用哪个子目录（Default / Profile 1），留空跟随浏览器上次使用
    douyin_profile_name: str = ""
    # 可选：抖音单独走代理（网页 + 视频 CDN），留空跟随 PROXY
    douyin_proxy: str = ""

    # ---------- 下载 ----------
    # direct=直连（国内站推荐） / system=跟随系统代理 / http://127.0.0.1:7890=指定代理
    proxy: str = "direct"
    quality: str = "1080"           # best / 1080 / 720 / audio
    download_images: bool = True    # 是否下载图文动态的图片
    keep_days: int = 30             # 媒体保留天数（python -m app clean 使用）
    # 下载完成后把文件修改时间改成内容发布时间（资源管理器按「修改日期」即发布顺序）
    file_mtime_from_publish: bool = True
    # ffmpeg / ffprobe 所在目录；留空表示只从 PATH 找。没有 ffmpeg 就无法合并音视频
    ffmpeg_location: str = ""

    # ---------- 路径属性 ----------
    def _abs(self, value: str) -> Path:
        p = Path(value)
        return p if p.is_absolute() else (BASE_DIR / p)

    @property
    def data_path(self) -> Path:
        return self._abs(self.data_dir)

    @property
    def download_path(self) -> Path:
        """下载根目录：DOWNLOAD_DIR → OUT_DIR（旧） → <data>/downloads。"""
        for value in (self.download_dir, self.out_dir):
            if value:
                return self._abs(value)
        return self.data_path / "downloads"

    # 旧名字，保持向后兼容
    @property
    def media_path(self) -> Path:
        return self.download_path

    @property
    def report_path(self) -> Path:
        """报告输出目录：REPORT_DIR → <data>/reports。"""
        if self.report_dir:
            return self._abs(self.report_dir)
        return self.data_path / "reports"

    @property
    def db_file(self) -> Path:
        return self.data_path / "collector.db"

    @property
    def credentials_dir(self) -> Path:
        """三个平台登录态的统一存放目录（Netscape cookies.txt）。"""
        return self.data_path / "credentials"

    def credential_file(self, platform: str) -> Path:
        return self.credentials_dir / f"{platform}.txt"

    def browser_profile(self, platform: str) -> Path:
        """登录/抓取用的浏览器 profile：抖音可能指向真实浏览器，其余用独立目录。"""
        if platform == "douyin":
            return self.douyin_profile
        return self.data_path / "browser" / platform

    @property
    def cookie_cache(self) -> Path:
        """兼容旧接口：B 站 Cookie 现在统一放在 credentials 目录。"""
        return self.credential_file("bilibili")

    @property
    def youtube_cookie_file(self) -> Path | None:
        """兼容旧接口：存在才返回，配置为空或文件缺失都算没有。"""
        path = self.credential_file("youtube")
        return path if path.exists() else None

    @property
    def douyin_profile(self) -> Path:
        """抖音用的浏览器 profile：默认独立目录；配了 DOUYIN_USER_DATA_DIR 就用本机真实 profile。

        真实 profile 的好处是直接带上现成登录态（不用扫码），代价是同一时间只能被一个
        浏览器进程占用，跑采集前必须完全退出 Edge / Chrome。
        """
        custom = (self.douyin_user_data_dir or "").strip()
        if custom:
            return Path(os.path.expandvars(custom)).expanduser()
        return self.data_path / "browser" / "douyin"

    @property
    def douyin_reuse_browser(self) -> bool:
        """是否在用本机真实浏览器 profile（决定提示语和启动参数）。"""
        return bool((self.douyin_user_data_dir or "").strip())

    @property
    def douyin_cookie_file(self) -> Path | None:
        """兼容旧接口：抖音导出给 yt-dlp 的 Cookie 也在 credentials 目录。"""
        path = self.credential_file("douyin")
        return path if path.exists() else None

    @property
    def db_url(self) -> str:
        return f"sqlite:///{self.db_file.as_posix()}"

    def ensure_dirs(self) -> None:
        for p in (self.data_path, self.download_path, self.report_path, self.credentials_dir):
            p.mkdir(parents=True, exist_ok=True)


@lru_cache
def get_settings() -> Settings:
    return Settings()
