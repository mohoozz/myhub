@echo off
chcp 936 >nul
cd /d "%~dp0"
title MyHub 采集器门户
set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8
set "PY=%~dp0runtime\python.exe"
set "PORT=17865"
if exist "%~dp0data\serve.port" set /p PORT=<"%~dp0data\serve.port"

if not exist "%PY%" (
    echo [错误] 找不到 runtime\python.exe
    echo        压缩包可能没有解压完整，请重新解压后再试。
    echo.
    pause >nul
    exit /b 1
)

rem 打包时选了 -IncludeBrowser 才会有自带的 Chromium，有就优先用它
if exist "%~dp0runtime\ms-playwright" set "PLAYWRIGHT_BROWSERS_PATH=%~dp0runtime\ms-playwright"

rem 服务已经在跑（比如开机自启拉起来的），直接打开页面，不要再起第二个
netstat -ano | findstr ":%PORT% " | findstr "LISTENING" >nul 2>&1
if not errorlevel 1 (
    echo 门户已在后台运行，正在打开 http://127.0.0.1:%PORT%/
    start "" "http://127.0.0.1:%PORT%/"
    exit /b 0
)

echo MyHub 采集器门户启动中……
echo 日志文件：%~dp0data\logs\myhub-collector.log
echo 关闭这个窗口即停止服务（后台启动的请运行 stop.bat）。
echo.
"%PY%" -m app serve --port 17865

echo.
echo 服务已退出。按任意键关闭窗口。
echo 排查问题看日志：%~dp0data\logs\myhub-collector.log
pause >nul
