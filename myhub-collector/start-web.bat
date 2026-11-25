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

rem 首次运行补齐 Deno（约 40 MB）；已存在时几乎不耗时
echo 正在检查运行环境...
"%PY%" -m app deps --quiet
if errorlevel 1 (
    echo.
    echo [提示] Deno 未就绪，YouTube 下载会只剩预览图。
    echo        网络不通时先在 .env 里设 PROXY，再执行：python -m app deps
    echo.
)

echo 正在启动 MyHub 采集器门户...
"%PY%" -m app serve --port 8765

echo.
echo 服务已退出。按任意键关闭窗口。
pause >nul
