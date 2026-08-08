@echo off
REM dev-flutter.bat - clean, fetch deps and run Flutter Windows desktop
REM Usage: double-click, or run "dev-flutter.bat" in terminal

cd /d "%~dp0myhub_flutter"

echo ==^> flutter clean
call flutter clean || exit /b 1

echo ==^> flutter pub get
call flutter pub get || exit /b 1

echo ==^> flutter run -d windows
call flutter run -d windows --dart-define=API_BASE_URL=http://localhost:8080
