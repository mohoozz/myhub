@echo off
REM client-win-debug-build.bat - clean, fetch deps and run Flutter Windows desktop (debug)
REM Usage: double-click, or run "client-win-debug-build.bat" in terminal

cd /d "%~dp0..\myhub_flutter"

echo ==^> flutter clean
call flutter clean || exit /b 1

echo ==^> flutter pub get
call flutter pub get || exit /b 1

echo ==^> flutter run -d windows (debug)
call flutter run -d windows --dart-define=API_BASE_URL=http://localhost:8080
