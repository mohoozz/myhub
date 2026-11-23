"""myhub-collector 命令行入口。

用法：
    python -m app collect [--day 2026-11-22] [--limit 40] [--no-download] [--no-sync] [--mid MID]
    python -m app sync [--platform bilibili]     # 只同步关注列表
    python -m app list [--day 2026-11-22]        # 查看某天已采集内容
    python -m app report [--day 2026-11-22]      # 重新生成某天报告
"""
from __future__ import annotations

import argparse
import logging
import sys
from datetime import date, datetime, timedelta

from sqlmodel import select

logger = logging.getLogger("myhub-collector")

SUPPORTED = ("bilibili",)


def _setup_logging() -> None:
    for stream in (sys.stdout, sys.stderr):
        if stream and hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except Exception:  # noqa: BLE001
                pass
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )


def _parse_day(value: str | None) -> date:
    if not value:
        return date.today() - timedelta(days=1)
    return datetime.strptime(value, "%Y-%m-%d").date()


def cmd_collect(args: argparse.Namespace) -> int:
    from app.pipeline import run_once

    day = _parse_day(args.day)
    print(f"开始采集 {day.isoformat()} · 平台 {args.platform}（{datetime.now():%H:%M:%S}）")
    result = run_once(
        day=day,
        platform=args.platform,
        limit=args.limit,
        do_download=not args.no_download,
        refresh_sources=not args.no_sync,
        only_mid=args.mid,
    )
    message = result.pop("message", "")
    if message:
        print(f"\n采集未成功：\n{message}", file=sys.stderr)
    print("结果：")
    for key, value in result.items():
        if value or key in ("new_items", "downloaded", "failed", "skipped"):
            print(f"  {key:<12}{value}")
    return 0 if not message else 1


def cmd_sync(args: argparse.Namespace) -> int:
    from app.database import session_scope
    from app.pipeline import sync_subscriptions

    try:
        with session_scope() as session:
            info = sync_subscriptions(session, args.platform)
    except Exception as e:  # noqa: BLE001
        print(f"同步失败：\n{e}", file=sys.stderr)
        return 1
    print(f"同步完成：发现 {info['discovered']} 个关注，新增 {info['created']} 个订阅源")
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    from app.database import session_scope
    from app.models import Content
    from app.summarize import day_range
    from app.utils import human_count

    day = _parse_day(args.day)
    since, until = day_range(day)
    with session_scope() as session:
        items = session.exec(
            select(Content)
            .where(Content.published_at >= since, Content.published_at < until)
            .order_by(Content.published_at.desc())
            .limit(args.limit)
        ).all()

    print(f"{day.isoformat()} 共 {len(items)} 条（最多显示 {args.limit} 条）")
    for item in items:
        like = f" 赞{human_count(item.like_count)}" if item.like_count else ""
        print(f"  [{item.media_type}] {item.author} · {item.title[:40]} · "
              f"{item.published_at:%H:%M}{like}")
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    from app.database import session_scope
    from app.summarize import write_reports

    day = _parse_day(args.day)
    with session_scope() as session:
        paths = write_reports(session, day)
    if not paths:
        print(f"{day.isoformat()} 没有内容，未生成报告")
        return 0
    print(f"报告：{paths[0]}\n      {paths[1]}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="myhub-collector", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command")

    p = sub.add_parser("collect", help="采集指定日期的内容并下载、生成总结")
    p.add_argument("--day", help="目标日期 YYYY-MM-DD（默认昨天）")
    p.add_argument("--platform", default="bilibili", choices=SUPPORTED)
    p.add_argument("--limit", type=int, default=None, help="本次最多下载条数")
    p.add_argument("--no-download", action="store_true", help="只抓取不下载")
    p.add_argument("--no-sync", action="store_true", help="跳过关注列表同步")
    p.add_argument("--mid", default=None, help="只采集指定 UP 主（调试用）")
    p.set_defaults(func=cmd_collect)

    p = sub.add_parser("sync", help="同步关注列表为订阅源")
    p.add_argument("--platform", default="bilibili", choices=SUPPORTED)
    p.set_defaults(func=cmd_sync)

    p = sub.add_parser("list", help="查看某天已采集内容")
    p.add_argument("--day", help="目标日期 YYYY-MM-DD（默认昨天）")
    p.add_argument("--limit", type=int, default=50)
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("report", help="重新生成某天报告")
    p.add_argument("--day", help="目标日期 YYYY-MM-DD（默认昨天）")
    p.set_defaults(func=cmd_report)

    return parser


def main(argv: list[str] | None = None) -> int:
    _setup_logging()
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return 1
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
