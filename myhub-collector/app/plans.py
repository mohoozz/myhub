"""定时计划：任务类型注册表 + 计划存储（``plans`` 表）。

和旧的「一个 .env 配一个 cron」相比，这里把「到点做什么」拆成可增删的计划：

- 一条计划 = **类型（kind）** + cron + 自己的参数（平台 / 日期偏移…）；
- 同一类型可以有多条计划，例如「每天 3 点全平台采集」和「每小时只抓抖音」；
- 以后要加「自动下载稍后观看」「自动下载收藏」，只需用 :func:`register_kind`
  注册一个新的 :class:`Kind`（含表单字段声明和 runner），门户的下拉框、
  表单、列表、手动触发、调度全部自动支持，不用改调度器和前端。
- 计划存在数据库里，门户增删改后调度器下一轮（20 秒内）就按新配置跑，不用重启。
"""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from typing import Any, Callable

from app import jobs
from app.models import Plan

logger = logging.getLogger(__name__)


# ---------------- 任务类型 ----------------

Runner = Callable[[jobs.Job], dict | None]


@dataclass(frozen=True)
class Field:
    """计划参数的表单声明：前端按 type 渲染控件，后端按 type 归一化取值。

    ``override=True`` 表示这是「配置覆盖」项：值与环境变量同名字段（``key``），
    留空就沿用环境配置；只在该计划执行期间生效，不影响其他计划和手动操作。
    """

    key: str
    label: str
    type: str = "bool"          # bool / int / text / select / platforms / inherit_*
    default: Any = False
    help: str = ""
    options: tuple[str, ...] = ()
    override: bool = False
    # 前端占位提示要展示的当前值取自哪个 Settings 属性（默认与 key 同名，
    # 下载目录用 download_path 才能显示计算后的真实绝对路径）
    env_attr: str = ""


@dataclass(frozen=True)
class Kind:
    """一种定时任务：「采集下载」「稍后观看」「收藏」……

    ``runner`` 入参是归一化后的参数和 Job（写日志用），返回结果字典。
    """

    key: str
    title: str
    desc: str
    default_cron: str
    fields: tuple[Field, ...]
    runner: Callable[[dict, jobs.Job], dict]


KINDS: dict[str, Kind] = {}


def register_kind(kind: Kind) -> Kind:
    KINDS[kind.key] = kind
    return kind


def get_kind(key: str) -> Kind | None:
    return KINDS.get((key or "").strip())


def _env_value_text(f: Field) -> str:
    """当前环境配置里这一项的生效值，用于表单占位提示（留空时用它）。"""
    from app.config import get_settings

    settings = get_settings()
    value = getattr(settings, f.env_attr or f.key, "")
    if isinstance(value, bool):
        return "是" if value else "否"
    if value is None:
        return ""
    return str(value)


def _field_meta(f: Field) -> dict:
    return {
        "key": f.key,
        "label": f.label,
        "type": f.type,
        "default": f.default,
        "help": f.help,
        "options": list(f.options),
        "override": bool(f.override),
        "env_value": _env_value_text(f) if f.override else "",
    }


def kinds_meta() -> list[dict]:
    """给前端渲染表单用的类型清单。"""
    return [
        {
            "key": kind.key,
            "title": kind.title,
            "desc": kind.desc,
            "default_cron": kind.default_cron,
            "fields": [_field_meta(f) for f in kind.fields],
        }
        for kind in KINDS.values()
    ]


# ---------------- 参数归一化 ----------------

def _truthy(value: Any) -> bool:
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "on")
    return bool(value)


def normalize_platforms(value: Any) -> str:
    """统一成 ``all`` 或 ``bilibili,youtube`` 这种逗号串。"""
    from app.sources import SUPPORTED

    if isinstance(value, (list, tuple, set)):
        items = [str(x).strip() for x in value]
    else:
        items = [p.strip() for p in str(value or "").replace("，", ",").split(",")]
    items = [p for p in items if p]
    if not items or "all" in items:
        return "all"
    picked = [p for p in items if p in SUPPORTED]
    return ",".join(dict.fromkeys(picked)) or "all"


def platforms_of(value: Any) -> list[str]:
    from app.sources import SUPPORTED

    text = normalize_platforms(value)
    return list(SUPPORTED) if text == "all" else [p for p in text.split(",") if p in SUPPORTED]


def _opt_text(value: Any) -> str | None:
    """空值表示「不覆盖」，归一化成 None。"""
    text = str(value if value is not None else "").strip()
    return text or None


def _opt_int(value: Any) -> int | None:
    text = _opt_text(value)
    if text is None:
        return None
    try:
        return max(int(float(text)), 0)
    except (TypeError, ValueError):
        return None


def _opt_bool(value: Any) -> bool | None:
    if isinstance(value, bool):
        return value
    text = _opt_text(value)
    if text is None:
        return None
    return _truthy(text)


def normalize_params(kind: Kind, raw: Any) -> dict:
    raw = raw if isinstance(raw, dict) else {}
    out: dict = {}
    for f in kind.fields:
        value = raw.get(f.key, f.default)
        if f.type == "bool":
            out[f.key] = _truthy(value)
        elif f.type == "int":
            try:
                out[f.key] = max(int(float(value or 0)), 0)
            except (TypeError, ValueError):
                out[f.key] = int(f.default or 0)
        elif f.type == "platforms":
            out[f.key] = normalize_platforms(value)
        elif f.type == "select":
            text = str(value or "").strip()
            out[f.key] = text if text in f.options else str(f.default or "")
        elif f.type == "inherit_int":
            out[f.key] = _opt_int(value)
        elif f.type == "inherit_bool":
            out[f.key] = _opt_bool(value)
        elif f.type in ("inherit_text", "inherit_select"):
            text = _opt_text(value)
            if f.type == "inherit_select" and text and f.options and text not in f.options:
                text = None
            out[f.key] = text
        else:
            out[f.key] = str(value or "").strip()
    return out


def overrides_of(kind: Kind, params: dict) -> dict:
    """把计划里填了的「配置覆盖」项挑出来，交给 settings_overrides 临时生效。"""
    out: dict = {}
    for f in kind.fields:
        if not f.override:
            continue
        value = params.get(f.key)
        if value is None or value == "":
            continue
        out[f.key] = value
    return out


# ---------------- 内置类型：采集下载 ----------------

def _collect_run(params: dict, job: jobs.Job) -> dict:
    """同步关注 → 抓取 → 下载 → 日报，按参数决定平台 / 日期 / 是否下载。"""
    from app.pipeline import run_once

    targets = platforms_of(params.get("platforms"))
    day_offset = max(int(params.get("day_offset") or 0), 0)
    do_download = bool(params.get("download", True))
    do_sync = bool(params.get("sync", True))
    day = date.today() - timedelta(days=day_offset)

    job.log(f"采集 {day.isoformat()} · {'、'.join(targets)}")
    out: dict = {}
    for platform in targets:
        job.log(f"=== {platform} · {day.isoformat()} ===")
        out[platform] = run_once(
            day=day,
            platform=platform,
            do_download=do_download,
            refresh_sources=do_sync,
            do_collect=True,
        )
    return out


# 计划级配置覆盖：留空 = 用环境配置（.env），只在本计划执行期间生效，
# 不影响其他计划、也不影响手动采集。key 与 Settings 的字段同名。
CONFIG_FIELDS: tuple[Field, ...] = (
    Field("download_dir", "下载目录", "inherit_text", "",
          "留空 = 环境配置的下载目录；可填绝对路径，或相对项目根目录的路径",
          override=True, env_attr="download_path"),
    Field("report_dir", "报告目录", "inherit_text", "",
          "留空 = 环境配置的报告目录", override=True, env_attr="report_path"),
    Field("quality", "画质", "inherit_select", "",
          "留空 = 环境配置的画质", options=("best", "1080", "720", "audio"),
          override=True),
    Field("max_duration_minutes", "单条时长上限（分钟）", "inherit_int", "",
          "留空 = 环境配置；0 = 不限制", override=True),
    Field("download_images", "下载图片动态", "inherit_bool", "",
          "留空 = 环境配置", override=True),
    Field("proxy", "代理", "inherit_text", "",
          "留空 = 环境配置；direct / system / http://127.0.0.1:7890",
          override=True),
)


register_kind(Kind(
    key="collect",
    title="采集并下载",
    desc="同步关注 → 抓取内容 → 下载媒体 → 生成日报",
    default_cron="0 3 * * *",
    fields=(
        Field("platforms", "平台", "platforms", "all", "全部平台，或只选其中几个"),
        Field("day_offset", "采集日期偏移（天）", "int", 1, "1 = 昨天（默认）；0 = 今天"),
        Field("download", "同时下载", "bool", True, "关掉只抓取入库，不下载媒体"),
        Field("sync", "先同步关注列表", "bool", True, "关掉只抓已入库的订阅源"),
        *CONFIG_FIELDS,
    ),
    runner=_collect_run,
))


# ---------------- 计划存储 ----------------

@dataclass
class TaskSpec:
    """调度器眼里的一个任务：只关心 key / cron / runner。"""

    key: str                 # 稳定标识，用 plan-<id>
    plan_id: int
    title: str
    cron: str
    runner: Runner
    params: dict = field(default_factory=dict)


def plan_name(row: Plan, kind: Kind | None = None) -> str:
    name = (row.name or "").strip()
    if name:
        return name
    kind = kind or get_kind(row.kind)
    return kind.title if kind else (row.kind or "计划")


def _loads(text: str) -> dict:
    try:
        data = json.loads(text or "{}")
    except (TypeError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def load_plans(enabled_only: bool = False) -> list[Plan]:
    from sqlmodel import select

    from app.database import session_scope

    with session_scope() as session:
        rows = list(session.exec(select(Plan).order_by(Plan.id)).all())
    return [row for row in rows if row.enabled] if enabled_only else rows


def get_plan(plan_id: int) -> Plan | None:
    from app.database import session_scope

    try:
        key = int(plan_id)
    except (TypeError, ValueError):
        return None
    with session_scope() as session:
        return session.get(Plan, key)


def save_plan(payload: dict) -> int:
    """新建或更新计划（payload 带 id 即更新），返回计划 id。"""
    from app.database import session_scope
    from app.scheduler import CronExpr  # 延迟导入：scheduler 依赖本模块

    kind_key = str(payload.get("kind") or "").strip()
    kind = get_kind(kind_key)
    if kind is None:
        raise ValueError(f"未知的任务类型：{kind_key or '（空）'}")
    cron = str(payload.get("cron") or "").strip() or kind.default_cron
    CronExpr.parse(cron)  # 提前校验，错误直接回给前端
    params = normalize_params(kind, payload.get("params") or {})
    name = str(payload.get("name") or "").strip()[:64]
    enabled = bool(payload.get("enabled", True))
    raw_id = payload.get("id")

    with session_scope() as session:
        if raw_id in (None, "", 0, "0"):
            row = Plan(
                name=name,
                kind=kind.key,
                cron=cron,
                enabled=enabled,
                params_json=json.dumps(params, ensure_ascii=False),
            )
            session.add(row)
        else:
            row = session.get(Plan, int(raw_id))
            if row is None:
                raise ValueError(f"计划不存在：{raw_id}")
            row.name = name
            row.kind = kind.key
            row.cron = cron
            row.enabled = enabled
            row.params_json = json.dumps(params, ensure_ascii=False)
            row.updated_at = datetime.now()
            session.add(row)
        session.flush()
        return int(row.id)


def delete_plan(plan_id: int) -> bool:
    from app.database import session_scope

    with session_scope() as session:
        row = session.get(Plan, int(plan_id))
        if row is None:
            return False
        session.delete(row)
        return True


def set_enabled(plan_id: int, enabled: bool) -> None:
    from app.database import session_scope

    with session_scope() as session:
        row = session.get(Plan, int(plan_id))
        if row is None:
            raise ValueError(f"计划不存在：{plan_id}")
        row.enabled = bool(enabled)
        row.updated_at = datetime.now()
        session.add(row)


def stamp(plan_id: int, *, runs_delta: int = 0, **fields: Any) -> None:
    """把运行状态写回计划行；失败只记日志，不影响调度本身。"""
    from app.database import session_scope

    if not plan_id:
        return
    try:
        with session_scope() as session:
            row = session.get(Plan, int(plan_id))
            if row is None:
                return
            for key, value in fields.items():
                if key == "last_error":
                    value = str(value or "")[:500]
                setattr(row, key, value)
            if runs_delta:
                row.runs = int(row.runs or 0) + runs_delta
            row.updated_at = datetime.now()
            session.add(row)
    except Exception:  # noqa: BLE001 状态更新失败不能让调度线程死掉
        logger.exception("更新定时计划状态失败：%s", plan_id)


# ---------------- 计划 → 调度任务 ----------------

def build_spec(row: Plan) -> TaskSpec | None:
    kind = get_kind(row.kind)
    if kind is None:
        logger.error("定时计划 %s 的类型 %r 未注册，已跳过", row.id, row.kind)
        return None
    params = normalize_params(kind, _loads(row.params_json))
    title = plan_name(row, kind)
    overrides = overrides_of(kind, params)

    def run(job: jobs.Job) -> dict:
        from app.config import settings_overrides

        job.log(f"计划「{title}」触发（{datetime.now():%Y-%m-%d %H:%M:%S}）")
        if overrides:
            job.log("本计划覆盖配置：" + "、".join(f"{k}={v}" for k, v in overrides.items()))
        try:
            # 覆盖只在本线程、本次执行内生效，其他计划与手动操作仍用环境配置
            with settings_overrides(**overrides):
                result = kind.runner(params, job)
        except Exception as e:  # noqa: BLE001 失败要落到计划状态里
            stamp(row.id, last_status="failed",
                  last_error=f"{type(e).__name__}: {e}", last_job_id=job.id)
            raise
        stamp(row.id, last_status="done", last_error="", last_job_id=job.id)
        return result

    return TaskSpec(
        key=f"plan-{row.id}",
        plan_id=int(row.id),
        title=title,
        cron=(row.cron or "").strip(),
        runner=run,
        params=params,
    )


def build_specs() -> list[TaskSpec]:
    """调度器每轮调用：只返回启用中的计划。"""
    specs: list[TaskSpec] = []
    for row in load_plans():
        if not row.enabled:
            continue
        spec = build_spec(row)
        if spec is not None:
            specs.append(spec)
    return specs
