"""数据库引擎与会话。"""
from __future__ import annotations

from contextlib import contextmanager
from typing import Iterator

from sqlmodel import Session, SQLModel, create_engine

from app.config import get_settings

_engine = None


def get_engine():
    global _engine
    if _engine is None:
        settings = get_settings()
        settings.ensure_dirs()
        _engine = create_engine(
            settings.db_url, connect_args={"check_same_thread": False}
        )
    return _engine


def init_db() -> None:
    from app import models  # noqa: F401  确保表结构已注册
    get_settings().ensure_dirs()
    SQLModel.metadata.create_all(get_engine())


@contextmanager
def session_scope() -> Iterator[Session]:
    init_db()
    with Session(get_engine()) as session:
        yield session
        session.commit()
