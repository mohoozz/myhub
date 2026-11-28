"""myhub-collector 命令行入口。

用法：
    python -m app collect [--day 2026-11-22] [--platform all] [--no-download] [--no-sync]
                          [--no-collect] [--mid MID] [--id 内容号 ...]
    python -m app sync [--platform all]          # 只同步订阅源（B站关注 / YouTube 频道）
    python -m app list [--day 2026-11-22]        # 查看某天已采集内容
    python -m app report [--day 2026-11-22]      # 重新生成某天报告
    python -m app clean [--keep-days 30] [--dry-run]   # 清理过期媒体
    python -m app login all                            # 依次弹窗登录三个平台
    python -m app login bilibili                       # 只登录某个平台
    python -m app status                               # 查看三个平台的登录态
    python -m app init                                 # 首次自检：Python/依赖/浏览器/目录
    python -m app deps                                 # 检查并按需下载 Deno（YouTube 解 JS 挑战用）
    python -m app schedule [--status|--once|--run ID]  # 定时计划：看状态 / 立即执行 / 前台常驻
    python -m app serve [--port 8765]                  # 本地门户：浏览器里登录、看进度、改配置
"""
from __future__ import annotations

import argparse
import logging
import sys
from datetime import date, datetime, timedelta

from sqlmodel import select

logger = logging.getLogger("myhub-collector")


def _setup_logging() -> None:
    for stream in (sys.stdout, sys.stderr):
        if stream and hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except Exception:  # noqa: BLE001
                pass
    # 控制台 + data/logs/myhub-collector.log：print 和 logging 的所有输出都留档
    from app.logging_setup import setup_logging

    setup_logging(level=logging.INFO)


def _parse_day(value: str | None) -> date:
    if not value:
        return date.today() - timedelta(days=1)
    return datetime.strptime(value, "%Y-%m-%d").date()


def _targets(value: str) -> list[str]:
    """--platform all 展开成全部平台，否则只跑指定的那个。"""
    if value == "all":
        return list(_supported())
    return [value]


def cmd_collect(args: argparse.Namespace) -> int:
    from app.pipeline import run_once

    day = _parse_day(args.day)
    failed = False
    for platform in _targets(args.platform):
        print(f"开始采集 {day.isoformat()} · 平台 {platform}（{datetime.now():%H:%M:%S}）")
        result = run_once(
            day=day,
            platform=platform,
            do_download=not args.no_download,
            refresh_sources=not args.no_sync,
            only_mid=args.mid,
            only_ids=set(args.id) if args.id else None,
            do_collect=not args.no_collect,
        )
        message = result.pop("message", "")
        if message:
            print(f"\n[{platform}] 采集未成功：\n{message}", file=sys.stderr)
            failed = True
        print(f"[{platform}] 结果：")
        for key, value in result.items():
            if value or key in ("new_items", "downloaded", "failed", "skipped"):
                print(f"  {key:<12}{value}")
    return 1 if failed else 0


def cmd_sync(args: argparse.Namespace) -> int:
    from app.database import session_scope
    from app.pipeline import sync_subscriptions

    failed = False
    for platform in _targets(args.platform):
        try:
            with session_scope() as session:
                info = sync_subscriptions(session, platform)
        except Exception as e:  # noqa: BLE001
            print(f"[{platform}] 同步失败：\n{e}", file=sys.stderr)
            failed = True
            continue
        print(
            f"[{platform}] 同步完成：发现 {info['discovered']} 个关注，"
            f"新增 {info['created']} 个订阅源，停用 {info['disabled']} 个已取关"
        )
    return 1 if failed else 0


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
        report = write_reports(session, day)
    if not report:
        print(f"{day.isoformat()} 没有内容，未生成报告")
        return 0
    print(f"报告：{report}")
    return 0


def cmd_clean(args: argparse.Namespace) -> int:
    from app.cleanup import clean_media
    from app.database import session_scope
    from app.utils import human_size

    with session_scope() as session:
        info = clean_media(session, keep_days=args.keep_days, dry_run=args.dry_run)

    head = "试运行（未删除任何文件）" if info["dry_run"] else "清理完成"
    print(f"{head}：保留 {info['keep_days']} 天，截止 {info['cutoff']}（不含）")
    print(f"  下载目录：{info['root']}")
    print(f"  文件/目录：{len(info['removed_items'])} 个，{human_size(info['removed_size'])}")
    print(f"  下载记录：{info['removed_downloads']} 条")
    if info["removed_items"]:
        preview = "、".join(info["removed_items"][:10])
        more = f" 等 {len(info['removed_items'])} 个" if len(info["removed_items"]) > 10 else ""
        print(f"  明细：{preview}{more}")
    return 0


def cmd_fixtime(args: argparse.Namespace) -> int:
    from app.database import session_scope
    from app.filetime import restamp_downloads

    day = _parse_day(args.day) if args.day else None  # 不给 --day 就处理全部
    with session_scope() as session:
        info = restamp_downloads(session, day=day, dry_run=args.dry_run)

    head = "试运行（未修改文件）" if info["dry_run"] else "时间对齐完成"
    print(f"{head}：范围 {info['day']}")
    print(f"  匹配下载记录：{info['matched']} 条，文件：{info['files']} 个")
    if info["missing"]:
        print(f"  文件缺失或记录对不上：{info['missing']} 条")
    return 0


def cmd_login(args: argparse.Namespace) -> int:
    from app import credentials
    from app.login import TARGETS, login, login_all

    wait = getattr(args, "wait", 300)
    profile = getattr(args, "profile", "")

    if args.platform == "all":
        results = login_all(list(TARGETS), wait_seconds=wait)
        print("\n=== 登录结果 ===")
        for platform, (ok, saved) in results.items():
            title = credentials.SITES[platform].title
            print(f"{title:<8}{'成功' if ok else '未完成':<6}{saved or '-'}")
        done = sum(1 for ok, _ in results.values() if ok)
        print(f"\n{done}/{len(results)} 个平台就绪")
        return 0 if done == len(results) else 1

    try:
        ok, saved = login(args.platform, wait_seconds=wait, profile=profile)
    except credentials.CredentialError as e:
        print(f"登录未完成：\n{e}", file=sys.stderr)
        return 1

    if not ok:
        print("未检测到登录态：可能没登完或中途关了窗口", file=sys.stderr)
        return 1
    print(f"登录态确认成功：{credentials.SITES[args.platform].title}")
    if saved:
        print(f"Cookie 已写入：{saved}")
    print(f"下一步：python -m app sync --platform {args.platform}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    from app import credentials

    print(f"{'平台':<8}{'登录态':<8}{'过期':<18}来源")
    missing = 0
    for platform in credentials.SITES:
        s = credentials.status(platform)
        mark = "正常" if s.ok else "缺失"
        missing += 0 if s.ok else 1
        print(f"{s.title:<8}{mark:<8}{s.expires:<18}{s.source}")
        if not s.ok:
            print(f"  → {s.hint}")
    if missing:
        print(f"\n{missing} 个平台需要登录：python -m app login <平台>")
    return 0


_BROWSERS = (
    ("Chrome", r"%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"),
    ("Chrome", r"%ProgramFiles%\Google\Chrome\Application\chrome.exe"),
    ("Chrome", r"%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"),
    ("Edge", r"%LOCALAPPDATA%\Microsoft\Edge\Application\msedge.exe"),
    ("Edge", r"%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"),
    ("Edge", r"%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"),
)


def _find_browser() -> str:
    """找本机 Chrome / Edge（登录和抖音抓取优先用它们）。"""
    import os
    from pathlib import Path

    for name, raw in _BROWSERS:
        path = Path(os.path.expandvars(raw))
        if path.exists():
            return f"{name}（{path}）"
    return ""


def _playwright_chromium() -> str:
    from pathlib import Path

    try:
        from playwright.sync_api import sync_playwright

        with sync_playwright() as pw:
            exe = pw.chromium.executable_path
        return exe if Path(exe).exists() else ""
    except Exception:  # noqa: BLE001 没装或驱动异常都算没有
        return ""


def cmd_init(args: argparse.Namespace) -> int:
    """首次使用自检：环境、依赖、浏览器、配置、目录、登录态。不改任何数据。"""
    import importlib

    from app import credentials
    from app.config import BASE_DIR, get_settings

    print("== myhub-collector 初始化自检 ==\n")
    problems: list[str] = []
    warnings: list[str] = []

    def line(ok: bool, label: str, detail: str = "") -> None:
        print(f"[{'OK' if ok else '注意':<4}] {label}{'  —  ' + detail if detail else ''}")

    ver = sys.version_info
    py_ok = ver >= (3, 10)
    line(py_ok, f"Python {ver.major}.{ver.minor}.{ver.micro}", "" if py_ok else "需要 3.10 或更高")
    if not py_ok:
        problems.append("升级 Python 到 3.10+")

    missing = []
    for module, package in (
        ("httpx", "httpx"),
        ("sqlmodel", "sqlmodel"),
        ("pydantic_settings", "pydantic-settings"),
        ("yt_dlp", "yt-dlp"),
        ("playwright", "playwright"),
    ):
        try:
            importlib.import_module(module)
        except ImportError:
            missing.append(package)
    line(not missing, "Python 依赖", ", ".join(missing) if missing else "已安装")
    if missing:
        problems.append("安装依赖：pip install -e .")

    browser = _find_browser()
    chromium = _playwright_chromium()
    line(bool(browser or chromium), "浏览器",
         browser or (f"Playwright Chromium（{chromium}）" if chromium else "没找到 Chrome / Edge / Chromium"))
    if not browser and not chromium:
        problems.append("装一个 Chrome/Edge，或执行：python -m playwright install chromium")
    elif not browser:
        warnings.append("本机没有 Chrome/Edge，登录会退回 Playwright Chromium（抖音风控更严）")

    env_file = BASE_DIR / ".env"
    line(env_file.exists(), ".env 配置", str(env_file) if env_file.exists() else "没有，将全部使用默认值")
    if not env_file.exists() and (BASE_DIR / ".env.example").exists():
        warnings.append("复制 .env.example 为 .env，再按需填 PROXY / YOUTUBE_CHANNELS")

    settings = get_settings()
    settings.ensure_dirs()
    line(True, "数据目录", str(settings.data_path))

    from app.downloader import ffmpeg_available, find_deno

    if ffmpeg_available(settings.ffmpeg_location):
        line(True, "ffmpeg", "已找到")
    else:
        line(False, "ffmpeg", "未找到，视频会退化成单流（画质可能只有 480p/720p）")
        warnings.append("装 ffmpeg：winget install ffmpeg，或在 .env 设 FFMPEG_LOCATION")

    deno = find_deno()
    if not deno:
        from app.tools import ensure_deno

        print("未找到 Deno，正在自动下载（约 40 MB，仅首次）……")
        ok, info = ensure_deno(quiet=True)
        deno = info if ok else ""
        if not ok:
            line(False, "Deno", "自动安装失败，YouTube 只能拿到预览图")
            warnings.append(f"Deno 下载失败（{info}）；可设置 PROXY 后重试：python -m app deps")
    if deno:
        line(True, "Deno", deno)

    print()
    pending = 0
    for platform in credentials.SITES:
        st = credentials.status(platform)
        line(st.ok, f"{st.title} 登录态", st.source if st.ok else "未登录")
        if not st.ok:
            pending += 1

    if problems:
        print("\n需要先处理：")
        for item in problems:
            print(f"  · {item}")
    if warnings:
        print("\n可忽略的提醒：")
        for item in warnings:
            print(f"  · {item}")

    print("\n下一步：")
    if pending:
        print("  python -m app login all     # 依次弹窗登录三个平台")
    print("  python -m app sync          # 同步关注 / 频道")
    print("  python -m app collect       # 采集前一天")
    return 1 if problems else 0



def cmd_deps(args: argparse.Namespace) -> int:
    """检查并按需下载可选外部工具（Deno）。"""
    from app.tools import deno_status, ensure_deno

    if args.check:  # 只查本地，不联网：启动脚本用，40 MB 下载不能挡在启动路径上
        ok, message = deno_status()
    else:
        ok, message = ensure_deno(quiet=args.quiet)
    if ok:
        if not args.quiet:
            print(f"Deno 就绪：{message}")
        return 0
    if not args.quiet:
        print(f"Deno 不可用：{message}", file=sys.stderr)
    return 1


def cmd_schedule(args: argparse.Namespace) -> int:
    """定时计划：查看状态 / 立即执行某条计划 / 前台常驻（不用开门户也能定时）。"""
    import time

    from app import jobs, plans, scheduler

    if args.status:
        st = scheduler.status()
        print(f"调度器：{'运行中' if st['running'] else '未启动（python -m app serve 会自动启动）'}")
        if st.get("error"):
            print(f"读取计划失败：{st['error']}")
        if not st["plans"]:
            print("还没有定时计划：在门户「定时任务」页添加。")
        for plan in st["plans"]:
            mark = "启用" if plan["enabled"] else "停用"
            print(
                f"  [{plan['id']:>3}] {plan['name']}（{plan['kind_title']}）{mark} "
                f"{plan['cron']}  下次 {plan['next_run_at'] or '—'}  "
                f"上次 {plan['last_run_at'] or '—'}  状态 {plan['last_status']}"
            )
            if plan.get("last_error"):
                print(f"        → {plan['last_error']}")
        return 0

    if args.run or args.once:
        st = scheduler.status()
        if args.run:
            target = next((p for p in st["plans"] if p["id"] == args.run), None)
            if target is None:
                print(f"没有 id={args.run} 的计划", file=sys.stderr)
                return 1
        else:
            target = next((p for p in st["plans"] if p["enabled"]), None)
            if target is None:
                print("没有启用中的计划，先加一条：门户「定时任务」页", file=sys.stderr)
                return 1
        row = plans.get_plan(target["id"])
        spec = plans.build_spec(row) if row else None
        if spec is None:
            print("这个计划的类型未注册或计划已被删除", file=sys.stderr)
            return 1
        job = jobs.Job(id="cli", kind="schedule", title=spec.title)
        try:
            spec.runner(job)
        except Exception as e:  # noqa: BLE001
            print(f"计划执行失败：{type(e).__name__}: {e}", file=sys.stderr)
            return 1
        finally:
            for line in job.lines:
                print(line)
        return 0

    scheduler.start()
    st = scheduler.status()
    if not st["plans"]:
        print("还没有定时计划：在门户「定时任务」页添加后，这里会显示下次执行时间")
    for plan in st["plans"]:
        if plan["enabled"]:
            print(f"[{plan['id']}] {plan['name']}：{plan['cron']}  下次 {plan['next_run_at'] or '—'}")
    print("调度器前台运行中，按 Ctrl+C 退出（想常驻用 python -m app serve）")
    try:
        while True:
            time.sleep(5)
    except KeyboardInterrupt:
        print("\n已停止")
    finally:
        scheduler.SCHEDULER.stop()
    return 0


def cmd_serve(args: argparse.Namespace) -> int:
    """启动本地门户（阻塞，Ctrl+C 退出）。"""
    from app.webapp import serve

    serve(host=args.host, port=args.port, open_browser=not args.no_browser)
    return 0


def _supported() -> tuple[str, ...]:
    from app.sources import SUPPORTED

    return SUPPORTED


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="myhub-collector", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command")
    platforms = _supported()

    p = sub.add_parser("collect", help="采集指定日期的内容并下载、生成总结")
    p.add_argument("--day", help="目标日期 YYYY-MM-DD（默认昨天）")
    p.add_argument("--platform", default="bilibili", choices=(*platforms, "all"),
                   help="平台，默认 bilibili；all = 依次跑全部平台")
    p.add_argument("--no-download", action="store_true", help="只抓取不下载")
    p.add_argument("--no-sync", action="store_true", help="跳过关注列表同步")
    p.add_argument("--no-collect", action="store_true", help="跳过抓取，只按库里的待下载记录下载")
    p.add_argument("--mid", default=None, help="只采集指定 UP 主（调试用）")
    p.add_argument("--id", action="append", default=None, help="只处理指定内容号（可多次）")
    p.set_defaults(func=cmd_collect)

    p = sub.add_parser("sync", help="同步关注列表为订阅源")
    p.add_argument("--platform", default="bilibili", choices=(*platforms, "all"),
                   help="平台，默认 bilibili；all = 依次跑全部平台")
    p.set_defaults(func=cmd_sync)

    p = sub.add_parser("list", help="查看某天已采集内容")
    p.add_argument("--day", help="目标日期 YYYY-MM-DD（默认昨天）")
    p.add_argument("--limit", type=int, default=50)
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("report", help="重新生成某天报告")
    p.add_argument("--day", help="目标日期 YYYY-MM-DD（默认昨天）")
    p.set_defaults(func=cmd_report)

    p = sub.add_parser("clean", help="按 KEEP_DAYS 清理过期媒体与下载记录")
    p.add_argument("--keep-days", type=int, default=None, help="保留天数（默认取 KEEP_DAYS）")
    p.add_argument("--dry-run", action="store_true", help="只统计不删除")
    p.set_defaults(func=cmd_clean)

    p = sub.add_parser("fixtime", help="把已下载文件的修改时间对齐到发布时间")
    p.add_argument("--day", help="只处理某天（按内容发布时间），默认全部")
    p.add_argument("--dry-run", action="store_true", help="只统计不修改")
    p.set_defaults(func=cmd_fixtime)

    p = sub.add_parser("login", help="弹窗手动登录，Cookie 统一导出到 data/credentials/")
    # 登录只有三个真实平台；稍后观看 / 收藏夹用的是 B 站同一个登录态
    from app.credentials import SITES

    p.add_argument("platform", choices=(*SITES, "all"),
                   help="要登录的平台；all = 依次弹窗登录三个平台")
    p.add_argument(
        "--wait",
        type=int,
        default=300,
        metavar="秒",
        help="检测到登录态就自动继续，最多等多少秒；0 = 回终端按回车确认（默认 300）",
    )
    p.add_argument("--profile", default="", help="复用指定浏览器 profile 目录（默认 data/browser/<平台>）")
    p.set_defaults(func=cmd_login)

    p = sub.add_parser("status", help="查看三个平台的登录态（离线自检）")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("init", help="首次使用自检：Python / 依赖 / 浏览器 / 配置 / 登录态")
    p.set_defaults(func=cmd_init)

    p = sub.add_parser("deps", help="检查并按需下载可选工具（Deno，YouTube 解 JS 挑战用）")
    p.add_argument("--quiet", action="store_true", help="成功时不输出，失败仍报错（启动脚本用）")
    p.add_argument("--check", action="store_true",
                   help="只检查本地是否有 Deno，不联网下载（启动脚本用，秒回）")
    p.set_defaults(func=cmd_deps)

    p = sub.add_parser("schedule", help="定时计划：查看状态 / 立即执行 / 前台常驻")
    p.add_argument("--status", action="store_true", help="列出所有计划、下次执行时间与上次结果")
    p.add_argument("--run", type=int, default=0, metavar="ID",
                   help="立即执行指定 id 的计划（不等 cron）")
    p.add_argument("--once", action="store_true", help="立即执行第一条启用中的计划")
    p.set_defaults(func=cmd_schedule)

    p = sub.add_parser("serve", help="启动本地门户：浏览器里登录 / 看下载进度 / 改配置")
    p.add_argument("--host", default="127.0.0.1", help="监听地址，默认只绑本机")
    p.add_argument("--port", type=int, default=8765, help="端口，默认 8765（占用时自动往后找）")
    p.add_argument("--no-browser", action="store_true", help="不自动打开浏览器")
    p.set_defaults(func=cmd_serve)

    p = sub.add_parser("douyin-login", help="旧命令，等同 `python -m app login douyin`")
    p.add_argument("--wait", type=int, default=300, metavar="秒", help="扫码等待秒数")
    p.set_defaults(func=cmd_login, platform="douyin", profile="")

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
