@echo off
rem 双击即可：首次初始化（调用同目录的 setup.ps1）
chcp 65001 >nul
setlocal
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
echo.
pause
