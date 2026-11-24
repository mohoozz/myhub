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


# 轻量迁移：create_all 只建新表，不会给老表加列，这里补齐后加的字段
_ADDED_COLUMNS: dict[str, dict[str, str]] = {
    "contents": {
        "emotes_json": "VARCHAR DEFAULT ''",
        "media_url": "VARCHAR DEFAULT ''",
    },
}


def _ensure_columns() -> None:
    engine = get_engine()
    with engine.begin() as conn:
        for table, columns in _ADDED_COLUMNS.items():
            rows = conn.exec_driver_sql(f"PRAGMA table_info({table})").fetchall()
            if not rows:
                continue
            existing = {row[1] for row in rows}
            for column, ddl in columns.items():
                if column not in existing:
                    conn.exec_driver_sql(f"ALTER TABLE {table} ADD COLUMN {column} {ddl}")


def init_db() -> None:
    from app import models  # noqa: F401  确保表结构已注册
    get_settings().ensure_dirs()
    SQLModel.metadata.create_all(get_engine())
    _ensure_columns()


@contextmanager
def session_scope() -> Iterator[Session]:
    init_db()
    # expire_on_commit=False：commit 后仍能读已加载对象的字段（CLI 里常在退出 with 后打印）
    with Session(get_engine(), expire_on_commit=False) as session:
        yield session
        session.commit()
