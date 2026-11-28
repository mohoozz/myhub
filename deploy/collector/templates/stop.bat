@echo off
chcp 936 >nul
setlocal enabledelayedexpansion
cd /d "%~dp0"

rem 停掉后台运行的门户（开机自启拉起来的那个没有窗口，只能从端口找）
set "PORT=17865"
if exist "%~dp0data\serve.port" set /p PORT=<"%~dp0data\serve.port"

set "TARGET="
for /f "tokens=5" %%p in ('netstat -ano ^| findstr ":%PORT% " ^| findstr "LISTENING"') do set "TARGET=%%p"

if not defined TARGET (
    echo 门户没有在运行（127.0.0.1:%PORT% 无监听）。
    echo.
    pause >nul
    exit /b 0
)

taskkill /f /pid !TARGET! >nul 2>&1
if errorlevel 1 (
    echo [失败] 结束进程 !TARGET! 失败，可能它已经在退出了。
) else (
    echo 已停止门户（进程 !TARGET!，端口 %PORT%）。
    if exist "%~dp0data\serve.port" del /q "%~dp0data\serve.port"
)
echo.
pause >nul
