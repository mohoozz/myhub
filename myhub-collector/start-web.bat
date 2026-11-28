@echo off
chcp 65001 >nul
cd /d "%~dp0"
set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8

if exist ".venv\Scripts\python.exe" (
    set "PY=.venv\Scripts\python.exe"
) else (
    set "PY=python"
)

rem 只做本地检查：联网下载 40 MB 会卡住启动，需要时手动补装 Deno
echo 正在检查运行环境...
"%PY%" -m app deps --check --quiet
if errorlevel 1 (
    echo.
    echo [提示] 未检测到 Deno，YouTube 下载会只剩预览图。
    echo        需要完整下载时执行一次：python -m app deps
    echo.
)

echo 正在启动 MyHub 采集器门户...
"%PY%" -m app serve --port 17865

echo.
echo 服务已退出。按任意键关闭窗口。
pause >nul
