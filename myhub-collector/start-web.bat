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

echo 正在启动 MyHub 采集器门户...
"%PY%" -m app serve --port 8765

echo.
echo 服务已退出。按任意键关闭窗口。
pause >nul
