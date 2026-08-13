"""数据库连接与初始化。"""
from pathlib import Path

from sqlmodel import Session, SQLModel, create_engine

from app.config import get_settings

settings = get_settings()

if settings.db_path != ":memory:":
    Path(settings.db_path).parent.mkdir(parents=True, exist_ok=True)

engine = create_engine(settings.db_url, connect_args={"check_same_thread": False})


def init_db() -> None:
    from app import models  # noqa: F401  确保模型已注册

    SQLModel.metadata.create_all(engine)


def get_session():
    with Session(engine) as session:
        yield session
