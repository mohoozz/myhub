"""服务配置：环境变量或 .env 文件（BILI_COOKIE=xxx）。"""
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    # B 站登录 Cookie（至少包含 SESSDATA）
    bili_cookie: str = ""
    # YouTube 登录 Cookie（拉订阅列表用，至少包含 SAPISID / __Secure-3PAPISID；仅 RSS 抓视频不需要）
    youtube_cookie: str = ""
    # 抖音 Cookie（可选；不登录可抓公开主页，遇风控时再配置）
    douyin_cookie: str = ""
    # SQLite 数据库路径
    db_path: str = "data/feed.db"
    # HTTP 服务监听
    host: str = "127.0.0.1"
    port: int = 8100
    # 抓取行为
    first_fetch_limit: int = 10   # 新订阅源首次拉取条数
    fetch_interval: float = 2.0   # 订阅源之间的限速（秒），防风控

    @property
    def db_url(self) -> str:
        return f"sqlite:///{self.db_path}"


@lru_cache
def get_settings() -> Settings:
    return Settings()
