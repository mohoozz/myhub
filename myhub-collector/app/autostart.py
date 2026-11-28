"""Windows 开机自启：直接写当前用户的 Run 键，客户不用再双击任何脚本。

为什么用 ``pythonw.exe`` 而不是 .vbs：
- ``pythonw`` 不带控制台窗口，开机时不会闪一个黑框；
- 绿色包里就有 ``runtime\\pythonw.exe``，路径相对成立；
- 只用标准库 ``winreg``，不受「组策略禁用 Windows Script Host」影响。

注册表里只放 ``"<pythonw>" "<DATA_DIR>\\autostart.pyw"``，路径逻辑全在那个引导脚本里：
开机时工作目录是 System32，靠它切回项目根、补 sys.path 和 PLAYWRIGHT_BROWSERS_PATH，
再调 ``app.__main__.main``。引导脚本每次开启都会重写，整个目录搬走后重新开关一次即可。
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

from app.config import BASE_DIR, get_settings

try:  # 只有 Windows 有 winreg，其它系统上模块照样能 import
    import winreg  # type: ignore[import-not-found]
except ImportError:  # pragma: no cover
    winreg = None  # type: ignore[assignment]

RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
VALUE_NAME = "MyHubCollector"
BOOTSTRAP_NAME = "autostart.pyw"

_LAUNCHER = '''"""MyHub 采集器开机自启引导脚本 —— 由门户「开机自动启动」开关生成。

删掉也没关系：在门户里把开关关掉再打开一次就会重新生成。
"""

import os
import sys

ROOT = r"{root}"

os.chdir(ROOT)
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

# 打包时带了 Playwright Chromium 的话走包内那份，没带就交给本机 Chrome / Edge
_browsers = os.path.join(ROOT, "runtime", "ms-playwright")
if os.path.isdir(_browsers):
    os.environ.setdefault("PLAYWRIGHT_BROWSERS_PATH", _browsers)

from app.__main__ import main  # noqa: E402

sys.exit(main(["serve", "--no-browser"]))
'''


def supported() -> bool:
    return winreg is not None and os.name == "nt"


def bootstrap_file() -> Path:
    """引导脚本位置：放在数据目录里，跟数据库、日志在一起。"""
    return get_settings().data_path / BOOTSTRAP_NAME


def _pythonw() -> Path | None:
    """当前解释器旁边的 pythonw.exe（绿色包 runtime\\ 和 venv\\Scripts 都有）。"""
    candidate = Path(sys.executable).with_name("pythonw.exe")
    return candidate if candidate.exists() else None


def launcher_command() -> tuple[str, str]:
    """返回 (写进 Run 键的命令, 不可用时的原因)。"""
    pythonw = _pythonw()
    if pythonw is not None:
        return f'"{pythonw}" "{bootstrap_file()}"', ""
    vbs = BASE_DIR / "start-background.vbs"
    if vbs.exists():   # 兜底：绿色包里的隐藏启动脚本
        return f'wscript.exe "{vbs}"', ""
    return "", "找不到 pythonw.exe，也没有 start-background.vbs，无法设置开机自启"


def _read_value() -> str:
    if not supported():
        return ""
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:  # type: ignore[union-attr]
            value, _ = winreg.QueryValueEx(key, VALUE_NAME)  # type: ignore[union-attr]
            return str(value or "")
    except OSError:
        return ""


def _write_value(command: str) -> None:
    with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, RUN_KEY) as key:  # type: ignore[union-attr]
        winreg.SetValueEx(key, VALUE_NAME, 0, winreg.REG_SZ, command)  # type: ignore[union-attr]


def _delete_value() -> None:
    try:
        with winreg.OpenKey(  # type: ignore[union-attr]
            winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE  # type: ignore[union-attr]
        ) as key:
            winreg.DeleteValue(key, VALUE_NAME)  # type: ignore[union-attr]
    except FileNotFoundError:
        pass  # 本来就没开


def _write_bootstrap() -> Path:
    path = bootstrap_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    # 用 REPL 转义，避免路径里的反斜杠被当成转义序列
    text = _LAUNCHER.replace("{root}", str(BASE_DIR))
    path.write_text(text, encoding="utf-8", newline="\n")
    return path


def status() -> dict:
    """给前端用的状态：能否设置、当前是否开启、注册表里存的实际命令。"""
    if not supported():
        return {
            "supported": False,
            "enabled": False,
            "command": "",
            "launcher": "",
            "hint": "当前系统不是 Windows，没有开机自启这一说",
        }
    command, hint = launcher_command()
    current = _read_value()
    return {
        "supported": bool(command),
        "enabled": bool(current),
        "command": current,
        "launcher": command,
        "hint": hint,
        "log": str(get_settings().data_path / "logs" / "myhub-collector.log"),
    }


def set_enabled(enabled: bool) -> dict:
    """开关开机自启，返回开关后的状态；不可用时抛 ValueError（前端直接显示原因）。"""
    if not supported():
        raise ValueError("当前系统不是 Windows，无法设置开机自启")
    if enabled:
        command, hint = launcher_command()
        if not command:
            raise ValueError(hint or "无法生成开机自启命令")
        _write_bootstrap()
        _write_value(command)
    else:
        _delete_value()
    return status()
