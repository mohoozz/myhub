"""服务配置：环境变量或 .env（BILI_COOKIE=xxx）。"""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

BASE_DIR = Path(__file__).resolve().parent.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=str(BASE_DIR / ".env"), extra="ignore")

    # ---------- 账号 ----------
    # B 站登录 Cookie（手工粘贴整段 Cookie，至少含 SESSDATA；优先级最高）
    bili_cookie: str = ""
    # 读浏览器 Cookie 的兜底来源：chrome / edge / firefox ...（Chrome 127+ 常读不出来）
    bili_browser: str = "chrome"
    bili_profile: str = ""

    # ---------- 目录 ----------
    data_dir: str = "data"          # 数据库、Cookie 缓存、媒体、报告都放这里
    out_dir: str = ""               # 媒体输出目录，空 = <data>/media

    # ---------- 抓取 ----------
    request_interval: float = 1.2   # 相邻请求/相邻作者的间隔（秒），防风控
    max_pages: int = 5              # 单个作者最多翻几页动态

    # ---------- 下载 ----------
    # direct=直连（国内站推荐） / system=跟随系统代理 / http://127.0.0.1:7890=指定代理
    proxy: str = "direct"
    quality: str = "1080"           # best / 1080 / 720 / audio
    max_downloads_per_run: int = 40  # 单次运行下载条数上限（磁盘保护）
    max_downloads_per_author: int = 8
    download_images: bool = True    # 是否下载图文动态的图片
    keep_days: int = 30             # 媒体保留天数（清理功能见 README 待办）

    # ---------- 路径属性 ----------
    def _abs(self, value: str) -> Path:
        p = Path(value)
        return p if p.is_absolute() else (BASE_DIR / p)

    @property
    def data_path(self) -> Path:
        return self._abs(self.data_dir)

    @property
    def media_path(self) -> Path:
        return self._abs(self.out_dir) if self.out_dir else self.data_path / "media"

    @property
    def report_path(self) -> Path:
        return self.data_path / "reports"

    @property
    def db_file(self) -> Path:
        return self.data_path / "collector.db"

    @property
    def cookie_cache(self) -> Path:
        return self.data_path / "cookies_bili.txt"

    @property
    def db_url(self) -> str:
        return f"sqlite:///{self.db_file.as_posix()}"

    def ensure_dirs(self) -> None:
        for p in (self.data_path, self.media_path, self.report_path):
            p.mkdir(parents=True, exist_ok=True)


@lru_cache
def get_settings() -> Settings:
    return Settings()
