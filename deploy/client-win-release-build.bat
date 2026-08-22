@echo off
REM client-win-release-build.bat - clean, fetch deps and build Flutter Windows desktop (release)
REM Usage: double-click, or run "client-win-release-build.bat" in terminal
REM Output: myhub_flutter\build\windows\x64\runner\Release\*.exe

cd /d "%~dp0..\myhub_flutter"

echo ==^> flutter clean
call flutter clean || exit /b 1

echo ==^> flutter pub get
call flutter pub get || exit /b 1

echo ==^> flutter build windows --release
call flutter build windows --release --dart-define=API_BASE_URL=http://localhost:8080 || exit /b 1

echo ==^> 编译完成
for %%F in (build\windows\x64\runner\Release\*.exe) do (
    echo    文件: %%~fF
    echo    大小: %%~zF 字节
    echo    时间: %%~tF
)
