@echo off
chcp 65001 >nul
cd /d "%~dp0"

rem 双击即可打包；参数会原样传给 ps1，例如：
rem   build.cmd -IncludeDeno
rem   build.cmd -PythonVersion 3.12.10 -Mirror https://pypi.tuna.tsinghua.edu.cn/simple

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
echo.
pause >nul
