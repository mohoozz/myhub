@echo off
REM build-server.bat - 打包 myhub 后端为最新可执行文件
REM 用法：双击运行，或在终端执行 "build-server.bat"
REM 输出：myhub-server\bin\myhub-server.exe

cd /d "%~dp0..\myhub-server"

echo ==^> go mod tidy
call go mod tidy || exit /b 1

echo ==^> go build -o bin\myhub-server.exe ./cmd/server
call go build -o bin\myhub-server.exe ./cmd/server || exit /b 1

echo ==^> 编译完成
for %%F in (bin\myhub-server.exe) do (
    echo    文件: %%~fF
    echo    大小: %%~zF 字节
    echo    时间: %%~tF
)
