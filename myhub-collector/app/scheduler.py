"""定时调度：按 cron 表达式把「计划」提交成后台任务。

设计取舍：
- **不引入 APScheduler / croniter**。项目刻意只用标准库 + 现有依赖，这里自己实现
  5 段 cron（分 时 日 月 周），够用且零安装成本。
- **计划来自数据库**（``plans`` 表，见 :mod:`app.plans`），不是 .env：同一类型可以
  建多条计划，门户里增删改后下一轮 tick 就生效，不用重启服务。
- **复用 ``jobs.JOBS``**：到点后提交成普通后台任务，自动继承「同一时间只跑一个
  任务」的约束，手动点按钮和定时任务不会同时抢 Playwright profile。
- **任务类型用注册表**：调度器只认 ``TaskSpec``，新的任务类型（稍后观看 / 收藏
  自动下载）在 :mod:`app.plans` 里注册即可，这里不用改。
"""
from __future__ import annotations

import json
import logging
import threading
from dataclasses import dataclass
from datetime import date, datetime, timedelta

from app import jobs
from app import plans as plans_store

logger = logging.getLogger(__name__)

TICK_SECONDS = 20.0          # 轮询粒度：cron 最小精度是分钟，20 秒足够准
BUSY_RETRY_MINUTES = 5.0     # 到点时有任务在跑：过几分钟再试，不直接丢掉这次触发


# ---------------- cron 解析 ----------------

_FIELD_RANGES = ((0, 59), (0, 23), (1, 31), (1, 12), (0, 7))


def _parse_field(text: str, low: int, high: int, label: str) -> tuple[frozenset[int], bool]:
    """解析单个 cron 字段，返回（取值集合, 是否被限制）。

    ``*`` / ``?`` 算未限制；``*/5``、``1-10/2``、``1,5,9`` 都支持。
    """
    text = (text or "").strip()
    if not text:
        raise ValueError(f"{label}不能为空")
    values: set[int] = set()
    restricted = True
    if text in ("*", "?"):
        return frozenset(range(low, high + 1)), False
    for part in text.split(","):
        part = part.strip()
        if not part:
            raise ValueError(f"{label}格式错误：{text}")
        step = 1
        step_text = ""
        if "/" in part:
            part, _, step_text = part.partition("/")
            part = part.strip()
            try:
                step = int(step_text)
            except ValueError as e:
                raise ValueError(f"{label}的步长不是整数：{step_text}") from e
            if step <= 0:
                raise ValueError(f"{label}的步长必须大于 0")
        if part in ("*", "?"):
            start, end = low, high
        elif "-" in part:
            a, _, b = part.partition("-")
            try:
                start, end = int(a), int(b)
            except ValueError as e:
                raise ValueError(f"{label}的区间格式错误：{part}") from e
        else:
            try:
                start = int(part)
            except ValueError as e:
                raise ValueError(f"{label}只能是数字：{part}") from e
            end = high if step_text else start
        if not (low <= start <= high and low <= end <= high) or start > end:
            raise ValueError(f"{label}超出范围 {low}-{high}：{text}")
        values.update(range(start, end + 1, step))
    if not values:
        raise ValueError(f"{label}没有可用取值：{text}")
    # weekday 的 7 与 0 都表示周日
    if high == 7 and 7 in values:
        values.discard(7)
        values.add(0)
    return frozenset(values), restricted


@dataclass(frozen=True)
class CronExpr:
    """5 段 cron 表达式：分 时 日 月 周（周日 = 0 或 7）。"""

    text: str
    minutes: frozenset[int]
    hours: frozenset[int]
    days: frozenset[int]
    months: frozenset[int]
    weekdays: frozenset[int]
    day_restricted: bool = True
    weekday_restricted: bool = True

    @classmethod
    def parse(cls, text: str) -> "CronExpr":
        parts = (text or "").replace("T", " ").split()
        if len(parts) != 5:
            raise ValueError(
                f"cron 需要 5 段（分 时 日 月 周），收到 {len(parts)} 段：{text!r}。"
                "例：0 3 * * *"
            )
        minutes, _ = _parse_field(parts[0], 0, 59, "分钟")
        hours, _ = _parse_field(parts[1], 0, 23, "小时")
        days, day_restricted = _parse_field(parts[2], 1, 31, "日")
        months, _ = _parse_field(parts[3], 1, 12, "月")
        weekdays, weekday_restricted = _parse_field(parts[4], 0, 7, "星期")
        return cls(
            text=" ".join(parts),
            minutes=minutes,
            hours=hours,
            days=days,
            months=months,
            weekdays=weekdays,
            day_restricted=day_restricted,
            weekday_restricted=weekday_restricted,
        )

    @staticmethod
    def _cron_weekday(moment: date) -> int:
        """Python 周一=0 → cron 周日=0。"""
        return (moment.weekday() + 1) % 7

    def _day_ok(self, moment: date) -> bool:
        if moment.month not in self.months:
            return False
        day_ok = moment.day in self.days
        weekday_ok = self._cron_weekday(moment) in self.weekdays
        # 标准 cron：日和周都被限制时取「或」，否则取「与」
        if self.day_restricted and self.weekday_restricted:
            return day_ok or weekday_ok
        return day_ok and weekday_ok

    def matches(self, moment: datetime) -> bool:
        return (
            moment.minute in self.minutes
            and moment.hour in self.hours
            and self._day_ok(moment.date())
        )

    def next_after(self, moment: datetime) -> datetime | None:
        """严格晚于 ``moment`` 的下一个触发时间（按分钟对齐）。"""
        cursor = (moment + timedelta(minutes=1)).replace(second=0, microsecond=0)
        limit = cursor + timedelta(days=366 * 5)
        while cursor < limit:
            if not self._day_ok(cursor.date()):
                cursor = (cursor + timedelta(days=1)).replace(hour=0, minute=0)
                continue
            if cursor.hour not in self.hours:
                cursor = (cursor + timedelta(hours=1)).replace(minute=0)
                continue
            if cursor.minute not in self.minutes:
                cursor += timedelta(minutes=1)
                continue
            return cursor
        return None


# ---------------- 调度器 ----------------

@dataclass
class _TaskState:
    cron: str
    expr: CronExpr | None
    next_run_at: datetime | None = None


def _fmt(moment: datetime | None) -> str:
    return moment.strftime("%Y-%m-%d %H:%M") if moment else ""


class Scheduler:
    """单例调度线程：每 ``TICK_SECONDS`` 检查一次是否有计划到点。"""

    def __init__(self, tick_seconds: float = TICK_SECONDS) -> None:
        self._tick = max(float(tick_seconds), 1.0)
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self._states: dict[str, _TaskState] = {}
        self._signature: tuple = ()

    # ---------- 生命周期 ----------

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name="scheduler", daemon=True)
        self._thread.start()
        logger.info("定时调度器已启动（每 %.0f 秒检查一次）", self._tick)

    def stop(self) -> None:
        self._stop.set()
        thread = self._thread
        if thread and thread.is_alive():
            thread.join(timeout=2.0)
        self._thread = None

    @property
    def running(self) -> bool:
        return bool(self._thread and self._thread.is_alive())

    def _loop(self) -> None:
        while not self._stop.wait(self._tick):
            try:
                self.tick()
            except Exception:  # noqa: BLE001 调度线程不能死
                logger.exception("定时计划检查失败")

    # ---------- 单轮检查 ----------

    def tick(self, now: datetime | None = None) -> None:
        now = now or datetime.now().replace(second=0, microsecond=0)
        try:
            specs = plans_store.build_specs()
        except Exception:  # noqa: BLE001 读库失败（表还没建好等）下轮再试
            logger.exception("读取定时计划失败")
            return

        signature = tuple(
            (s.key, s.cron, _params_key(s.params)) for s in specs
        )
        if signature != self._signature:
            self._signature = signature
            logger.info("定时计划：%s", self._describe(specs))

        live = {spec.key for spec in specs}
        with self._lock:
            for key in list(self._states):
                if key not in live:
                    self._states.pop(key, None)

        for spec in specs:
            state = self._states.get(spec.key)
            if state is None or state.cron != spec.cron:
                state = self._make_state(spec.cron, now)
                with self._lock:
                    self._states[spec.key] = state
            if state.expr is None or state.next_run_at is None:
                continue
            if now >= state.next_run_at:
                self._fire(spec, state, now)

    @staticmethod
    def _describe(specs: list[plans_store.TaskSpec]) -> str:
        if not specs:
            return "没有启用中的计划"
        return "；".join(f"{s.title} @ {s.cron}" for s in specs)

    @staticmethod
    def _make_state(cron: str, now: datetime) -> _TaskState:
        try:
            expr = CronExpr.parse(cron)
        except ValueError as e:
            logger.error("cron 表达式无效：%s", e)
            return _TaskState(cron=cron, expr=None)
        # 当前这一分钟就匹配时立刻执行；否则算下一个触发点
        next_run = now if expr.matches(now) else expr.next_after(now)
        return _TaskState(cron=cron, expr=expr, next_run_at=next_run)

    def _fire(self, spec: plans_store.TaskSpec, state: _TaskState, now: datetime) -> None:
        # 先落「排队中」再提交：任务线程可能比提交调用还快，晚写状态会把 done/failed 覆盖掉
        plans_store.stamp(
            spec.plan_id,
            last_run_at=now,
            last_status="queued",
            last_job_id="",
            last_error="",
            runs_delta=1,
        )
        try:
            job = jobs.JOBS.submit("schedule", spec.title, spec.runner)
        except jobs.JobBusy as e:
            with self._lock:
                state.next_run_at = now + timedelta(minutes=BUSY_RETRY_MINUTES)
            plans_store.stamp(spec.plan_id, last_status="busy",
                              last_error=str(e), runs_delta=-1)
            logger.warning("计划「%s」到点时已有任务在跑，%.0f 分钟后再试：%s",
                           spec.title, BUSY_RETRY_MINUTES, e)
            return

        next_run = state.expr.next_after(now) if state.expr else None
        with self._lock:
            state.next_run_at = next_run
        plans_store.stamp(spec.plan_id, last_job_id=job.id)
        logger.info("计划「%s」已提交：%s（下次 %s）", spec.title, job.id, _fmt(next_run))

    # ---------- 手动触发 ----------

    def run_now(self, plan_id: int) -> jobs.Job:
        """立即执行一次（不看 cron、不看启用状态），仍受「同时只跑一个任务」约束。"""
        row = plans_store.get_plan(plan_id)
        if row is None:
            raise ValueError(f"计划不存在：{plan_id}")
        spec = plans_store.build_spec(row)
        if spec is None:
            raise ValueError("这个计划的类型未注册，无法执行")

        plans_store.stamp(
            int(plan_id),
            last_run_at=datetime.now(),
            last_status="queued",
            last_job_id="",
            last_error="",
            runs_delta=1,
        )
        try:
            job = jobs.JOBS.submit("schedule", f"{spec.title}（手动触发）", spec.runner)
        except jobs.JobBusy as e:
            plans_store.stamp(int(plan_id), last_status="busy",
                              last_error=str(e), runs_delta=-1)
            raise
        plans_store.stamp(int(plan_id), last_job_id=job.id)
        with self._lock:
            state = self._states.get(spec.key)
            if state is not None:
                state.next_run_at = (
                    state.expr.next_after(datetime.now()) if state.expr else None
                )
        return job

    # ---------- 状态 ----------

    def status(self) -> dict:
        """给门户用：类型清单 + 每条计划的 cron、下次执行、上次结果。"""
        try:
            rows = plans_store.load_plans()
            load_error = ""
        except Exception as e:  # noqa: BLE001 表还没建好时也要能打开页面
            logger.exception("读取定时计划失败")
            rows, load_error = [], f"{type(e).__name__}: {e}"

        now = datetime.now().replace(second=0, microsecond=0)
        with self._lock:
            states = dict(self._states)

        tasks = []
        for row in rows:
            kind = plans_store.get_kind(row.kind)
            state = states.get(f"plan-{row.id}")
            next_run = state.next_run_at if state else None
            valid: bool | None = state.expr is not None if state else None
            error = (row.last_error or "").strip()
            if state is None and row.cron:
                # 调度器还没跑过第一轮：直接按 cron 算给界面看
                try:
                    expr = CronExpr.parse(row.cron)
                    next_run = now if expr.matches(now) else expr.next_after(now)
                    valid = True
                except ValueError as e:
                    valid, error = False, str(e)
            tasks.append({
                "id": int(row.id),
                "name": plans_store.plan_name(row, kind),
                "kind": row.kind,
                "kind_title": kind.title if kind else row.kind,
                "cron": row.cron,
                "enabled": bool(row.enabled),
                "params": plans_store.normalize_params(kind, _loads(row.params_json)) if kind else {},
                "next_run_at": _fmt(next_run),
                "last_run_at": _fmt(row.last_run_at),
                "last_status": row.last_status or "idle",
                "last_error": error,
                "last_job_id": row.last_job_id or "",
                "runs": int(row.runs or 0),
                "valid": valid,
            })

        return {
            "running": self.running,
            "kinds": plans_store.kinds_meta(),
            "plans": tasks,
            "error": load_error,
        }


def _loads(text: str) -> dict:
    try:
        data = json.loads(text or "{}")
    except (TypeError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _params_key(params: dict) -> str:
    return json.dumps(params, ensure_ascii=False, sort_keys=True, default=str)


SCHEDULER = Scheduler()


def start() -> Scheduler:
    SCHEDULER.start()
    return SCHEDULER


def status() -> dict:
    return SCHEDULER.status()
