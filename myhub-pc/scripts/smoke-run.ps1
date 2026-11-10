# 冒烟运行：启动应用若干秒，捕获 QML 运行期错误后退出
param([int]$Seconds = 6, [string]$Preset = 'windows-debug')

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$exe  = Join-Path $root "build\$Preset\MyHub.exe"

if (-not (Test-Path $exe)) {
    Write-Host "executable not found: $exe"
    exit 1
}

$env:PATH = 'C:\Qt\6.8.3\msvc2022_64\bin;' + $env:PATH
# 让 QML 的警告/错误输出到 stderr 而非调试器
$env:QT_FORCE_STDERR_LOGGING = '1'
$env:QT_LOGGING_RULES = 'qt.qml.*=true'

$outFile = Join-Path $env:TEMP 'myhub-smoke-out.txt'
$errFile = Join-Path $env:TEMP 'myhub-smoke-err.txt'
Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue

$p = Start-Process -FilePath $exe -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile

Write-Host "started PID=$($p.Id), waiting ${Seconds}s ..."
Start-Sleep -Seconds $Seconds

$alive = -not $p.HasExited
if ($alive) {
    Write-Host 'process still running (good: no startup crash)'
    $p.CloseMainWindow() | Out-Null
    Start-Sleep -Seconds 2
    if (-not $p.HasExited) { $p.Kill() }
} else {
    Write-Host "process exited early with code $($p.ExitCode)"
}

Write-Host ''
Write-Host '=== stderr (QML warnings / errors) ==='
if (Test-Path $errFile) {
    $err = Get-Content $errFile -Encoding UTF8
    if ($err) { $err | ForEach-Object { Write-Host "  $_" } }
    else { Write-Host '  (empty)' }
}

Write-Host ''
Write-Host '=== stdout ==='
if (Test-Path $outFile) {
    $out = Get-Content $outFile -Encoding UTF8
    if ($out) { $out | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" } }
    else { Write-Host '  (empty)' }
}

Write-Host ''
Write-Host '=== app log tail ==='
$logDir = Join-Path $env:APPDATA 'MyHub\Logs'
$log = Get-ChildItem $logDir -Filter 'myhub-*.log' -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($log) {
    Get-Content $log.FullName -Tail 25 -Encoding UTF8 | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "  no log file in $logDir"
}

if (-not $alive) { exit 1 }
