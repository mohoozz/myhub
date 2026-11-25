"""``.env`` 的读 / 校验 / 写回，供 Web 门户的「环境配置」页使用。

表单结构（分组、控件类型、说明、是否进阶项）在这里显式声明，
好处是前端不用猜、改配置时顺序稳定；默认值仍从 :class:`Settings` 取，
避免两处各写一份导致漂移。
"""
from __future__ import annotations

import shutil

from app.config import BASE_DIR, Settings, get_settings

ENV_PATH = BASE_DIR / ".env"
BACKUP_PATH = BASE_DIR / ".env.bak"

# 保存后必须重启服务才生效的项（引擎 / 路径在启动时就固化了）
RESTART_KEYS = {"DATA_DIR", "DOWNLOAD_DIR", "OUT_DIR"}


def _groups() -> list[dict]:
    """表单结构：group → items。``type`` 决定前端渲染什么控件。"""
    return [
        {
            "name": "浏览器",
            "help": "三个平台的登录和抖音抓取都走浏览器，一般保持默认即可。",
            "items": [
                {
                    "key": "BROWSER_CHANNEL",
                    "label": "浏览器通道",
                    "type": "select",
                    "options": ["chrome", "msedge", "chromium", ""],
                    "help": "chrome / msedge / chromium；留空用 Playwright 自带 Chromium",
                },
            ],
        },
        {
            "name": "目录",
            "help": "数据目录 / 下载目录改动后需要重启服务；报告目录即时生效。",
            "items": [
                {
                    "key": "DATA_DIR",
                    "label": "数据目录",
                    "type": "text",
                    "help": "数据库、登录态都放这里，默认 data",
                },
                {
                    "key": "DOWNLOAD_DIR",
                    "label": "下载目录",
                    "type": "text",
                    "help": "成品文件平铺存放，留空 = <数据目录>/downloads",
                },
                {
                    "key": "REPORT_DIR",
                    "label": "报告目录",
                    "type": "text",
                    "help": "每日 HTML 报告输出位置，留空 = <数据目录>/reports",
                },
            ],
        },
        {
            "name": "抓取",
            "items": [
                {
                    "key": "REQUEST_INTERVAL",
                    "label": "请求间隔（秒）",
                    "type": "float",
                    "help": "相邻请求 / 相邻作者的间隔，调大更防风控",
                },
                {
                    "key": "MAX_PAGES",
                    "label": "每作者最多翻页",
                    "type": "int",
                    "help": "单个作者最多翻几页动态，默认 5",
                },
            ],
        },
        {
            "name": "YouTube",
            "help": "登录后默认自动采集账号整个订阅列表，这里通常不用填。",
            "items": [
                {
                    "key": "YOUTUBE_CHANNELS",
                    "label": "手填频道",
                    "type": "textarea",
                    "help": "UCxxx / @handle / 频道主页链接，逗号或空格分隔；留空只用账号订阅",
                },
                {
                    "key": "YOUTUBE_SUBSCRIPTIONS",
                    "label": "并入账号订阅列表",
                    "type": "bool",
                    "help": "关掉后只采集上面手填的频道",
                },
                {
                    "key": "YOUTUBE_PROXY",
                    "label": "专用代理",
                    "type": "text",
                    "help": "留空跟随 PROXY",
                },
            ],
        },
        {
            "name": "抖音",
            "items": [
                {
                    "key": "DOUYIN_HEADLESS",
                    "label": "无头运行",
                    "type": "bool",
                    "help": "无头更容易撞验证码，建议保持关闭",
                },
                {
                    "key": "DOUYIN_MAX_SCROLLS",
                    "label": "最多滚动次数",
                    "type": "int",
                    "help": "关注列表 / 作者主页，每次约 20 条",
                },
                {
                    "key": "DOUYIN_PROXY",
                    "label": "专用代理",
                    "type": "text",
                    "help": "留空跟随 PROXY",
                },
                {
                    "key": "DOUYIN_USER_DATA_DIR",
                    "label": "复用本机浏览器目录",
                    "type": "text",
                    "help": "填浏览器 User Data 目录可直接继承登录态；留空用独立 profile",
                    "advanced": True,
                },
                {
                    "key": "DOUYIN_PROFILE_NAME",
                    "label": "Profile 子目录",
                    "type": "text",
                    "help": "Default / Profile 1；留空跟随浏览器上次使用",
                    "advanced": True,
                },
            ],
        },
        {
            "name": "下载",
            "items": [
                {
                    "key": "PROXY",
                    "label": "代理",
                    "type": "text",
                    "help": "direct=直连 / system=跟随系统代理 / http://127.0.0.1:7890",
                },
                {
                    "key": "QUALITY",
                    "label": "清晰度",
                    "type": "select",
                    "options": ["best", "1080", "720", "audio"],
                },
                {"key": "DOWNLOAD_IMAGES", "label": "下载图文图片", "type": "bool"},
                {
                    "key": "MAX_DURATION_MINUTES",
                    "label": "视频时长上限（分钟）",
                    "type": "int",
                    "help": "0 = 不限制；B 站多分 P 按总时长算，超长的只记「跳过」不下载",
                },
                {
                    "key": "KEEP_DAYS",
                    "label": "媒体保留天数",
                    "type": "int",
                    "help": "python -m app clean 使用",
                },
                {
                    "key": "FILE_MTIME_FROM_PUBLISH",
                    "label": "文件时间对齐发布时间",
                    "type": "bool",
                    "help": "下载完成后把修改时间设为发布时间，资源管理器即可按发布顺序排序",
                },
                {
                    "key": "FFMPEG_LOCATION",
                    "label": "ffmpeg 目录",
                    "type": "text",
                    "help": "未加入 PATH 时填这里，留空只从 PATH 找",
                },
            ],
        },
    ]


def _defaults() -> dict[str, str]:
    """从 Settings 取各键默认值（env 键名 = 字段名大写）。"""
    out: dict[str, str] = {}
    for name, field in Settings.model_fields.items():
        default = field.default
        if isinstance(default, bool):
            out[name.upper()] = "true" if default else "false"
        else:
            out[name.upper()] = "" if default is None else str(default)
    return out


def read_values() -> dict[str, str]:
    """解析现有 ``.env``（不含注释），保留未知键。"""
    values: dict[str, str] = {}
    if not ENV_PATH.exists():
        return values
    for raw in ENV_PATH.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        values[key] = value
    return values


def schema() -> list[dict]:
    """给前端的完整表单：结构 + 当前值 + 默认值。"""
    current = read_values()
    defaults = _defaults()
    groups = _groups()
    for group in groups:
        for item in group["items"]:
            key = item["key"]
            item["default"] = defaults.get(key, "")
            item["value"] = current.get(key, item["default"])
            item["restart"] = key in RESTART_KEYS
            item.setdefault("advanced", False)
            item.setdefault("options", [])
    return groups


def _coerce(item: dict, raw: str) -> str:
    """按控件类型校验并规整成写文件用的字符串。"""
    key = item["key"]
    kind = item.get("type", "text")
    value = (raw if raw is not None else "").strip()
    label = item.get("label") or key

    if kind == "bool":
        low = value.lower()
        if low in ("", "0", "false", "no", "off"):
            return "false"
        if low in ("1", "true", "yes", "on"):
            return "true"
        raise ValueError(f"{label}：只能是 true / false")

    if kind == "int":
        if value == "":
            return str(_defaults().get(key, "") or 0)
        try:
            return str(int(value))
        except ValueError as e:
            raise ValueError(f"{label}：需要整数，收到「{value}」") from e

    if kind == "float":
        if value == "":
            return str(_defaults().get(key, "") or 0)
        try:
            return str(float(value))
        except ValueError as e:
            raise ValueError(f"{label}：需要数字，收到「{value}」") from e

    if kind == "select" and item.get("options"):
        if value not in item["options"]:
            raise ValueError(f"{label}：可选 {' / '.join(o or '（空）' for o in item['options'])}")
        return value

    return value


def _render(groups: list[dict], values: dict[str, str]) -> str:
    """生成带分组注释的 ``.env``；schema 之外的键附在末尾原样保留。"""
    known = {item["key"] for group in groups for item in group["items"]}
    lines = [
        "# myhub-collector 配置（Web 门户生成；也可以手工编辑，保存时会重新排版）",
        "# 登录态不在这里：跑 `python -m app login` 或用门户的「平台登录」页。",
        "",
    ]
    for group in groups:
        lines.append(f"# ---------- {group['name']} ----------")
        if group.get("help"):
            lines.append(f"# {group['help']}")
        for item in group["items"]:
            if item.get("help"):
                lines.append(f"# {item['help']}")
            lines.append(f"{item['key']}={values.get(item['key'], '')}")
        lines.append("")

    extra = {k: v for k, v in values.items() if k not in known}
    if extra:
        lines.append("# ---------- 其他（未在表单中的键，原样保留） ----------")
        lines.extend(f"{key}={value}" for key, value in extra.items())
        lines.append("")

    return "\n".join(lines)


def save(payload: dict[str, str]) -> dict:
    """校验并写回 ``.env``；有改动时刷新 Settings 缓存。

    出错时抛 ``ValueError``（消息直接给前端显示），且**不写入任何内容**。
    """
    groups = _groups()
    current = read_values()
    defaults = _defaults()
    incoming = {str(k).upper(): "" if v is None else str(v) for k, v in (payload or {}).items()}

    errors: list[str] = []
    merged = dict(current)
    for group in groups:
        for item in group["items"]:
            key = item["key"]
            if key not in incoming and key not in current:
                continue
            # 表单没提交、.env 里也没有（或为空）的键，回落到默认值，
            # 否则 select 会拿空串去校验默认值本身就合法的字段
            fallback = defaults.get(key, "")
            raw = incoming.get(key, current.get(key, fallback)) or fallback
            try:
                merged[key] = _coerce(item, raw)
            except ValueError as e:
                errors.append(str(e))
    if errors:
        raise ValueError("；".join(errors))

    # 补全表单外的键，写出的 .env 是完整可读的一份，不会出现 `QUALITY=` 这种空值
    for group in groups:
        for item in group["items"]:
            merged.setdefault(item["key"], defaults.get(item["key"], ""))

    changed = [k for k in merged if current.get(k) != merged.get(k)]
    if not changed:
        return {"changed": [], "restart_required": [], "path": str(ENV_PATH)}

    if ENV_PATH.exists():
        shutil.copyfile(ENV_PATH, BACKUP_PATH)

    ENV_PATH.write_text(_render(groups, merged), encoding="utf-8")
    get_settings.cache_clear()
    return {
        "changed": changed,
        "restart_required": [k for k in changed if k in RESTART_KEYS],
        "path": str(ENV_PATH),
        "backup": str(BACKUP_PATH) if BACKUP_PATH.exists() else "",
    }


def env_status() -> dict:
    return {
        "path": str(ENV_PATH),
        "exists": ENV_PATH.exists(),
        "backup": str(BACKUP_PATH) if BACKUP_PATH.exists() else "",
        "data_dir": str(get_settings().data_path),
        "download_dir": str(get_settings().download_path),
        "report_dir": str(get_settings().report_path),
    }


def sample_text() -> str:
    """``.env.example`` 的内容，供门户「模板参考」用。"""
    path = BASE_DIR / ".env.example"
    return path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
