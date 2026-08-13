"""myhub-feed 动态抓取服务。

用法：
    python -m app serve                  # 启动 HTTP 服务（默认 127.0.0.1:8100，供 myhub-server 调用）
    python -m app fetch [platform]       # 手动执行一次抓取（可指定平台，供计划任务调用）
    python -m app sync [platform]        # 同步账号关注/订阅列表为订阅源（默认 bilibili）
    python -m app export [输出路径]       # 导出静态 HTML 报告（默认 data/feed_report.html）
"""
import logging
import sys

import uvicorn
from fastapi import FastAPI
from sqlmodel import Session

from app.api.routes import router
from app.config import get_settings
from app.database import engine, init_db
from app.services import feed_service

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("myhub-feed")

app = FastAPI(title="myhub-feed", version="0.1.0")
app.include_router(router)


@app.on_event("startup")
def _startup() -> None:
    init_db()


def main() -> None:
    init_db()
    settings = get_settings()
    cmd = sys.argv[1] if len(sys.argv) > 1 else "serve"
    arg = sys.argv[2] if len(sys.argv) > 2 else None

    match cmd:
        case "serve":
            uvicorn.run(app, host=settings.host, port=settings.port)
        case "fetch":
            with Session(engine) as session:
                result = feed_service.fetch_all(session, arg)
            logger.info("抓取完成: %s", result)
        case "sync":
            with Session(engine) as session:
                result = feed_service.sync_sources(session, arg or "bilibili")
            logger.info("同步完成: %s", result)
        case "export":
            from app.report import export_html
            path = export_html(arg or "data/feed_report.html")
            logger.info("报告已导出: %s", path)
        case _:
            print(__doc__)
            sys.exit(1)


if __name__ == "__main__":
    main()
