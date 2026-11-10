# 构建并运行 S4 浏览器能力探针
$ErrorActionPreference = 'Continue'

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$build  = Join-Path $here 'build'
$dlDir  = Join-Path $env:TEMP 'myhub-s4-download'

$vcvars = 'C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$qtRoot = 'C:/Qt/6.8.3/msvc2022_64'

Write-Host '=== MSVC environment ==='
$envDump = & cmd.exe /c "call `"$vcvars`" >nul 2>&1 && set"
foreach ($line in $envDump) {
    if ($line -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
}

Write-Host '=== Configure ==='
$cfg = & cmake -S $here -B $build -G Ninja `
    -DCMAKE_BUILD_TYPE=Release `
    "-DCMAKE_PREFIX_PATH=$qtRoot" 2>&1
if ($LASTEXITCODE -ne 0) {
    $cfg | Select-Object -Last 25 | ForEach-Object { Write-Host $_ }
    exit 1
}
$cfg | Where-Object { $_ -match 'Configuring done|Generating done' } |
    ForEach-Object { Write-Host $_ }

Write-Host '=== Build ==='
$bld = & cmake --build $build --parallel 2>&1
if ($LASTEXITCODE -ne 0) {
    $bld | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }
    exit 1
}
Write-Host 'build OK'

$env:PATH = ($qtRoot -replace '/','\') + '\bin;' + $env:PATH

Push-Location $build
Write-Host ''
Write-Host '=== Run: browser capabilities probe ==='
Remove-Item 's4-browser-report.txt' -Force -ErrorAction SilentlyContinue
& (Join-Path $build 'browser_probe.exe') 2>&1 | Out-Null
$code = $LASTEXITCODE
if (Test-Path 's4-browser-report.txt') {
    Get-Content 's4-browser-report.txt' | ForEach-Object { Write-Host "  $_" }
}
Write-Host "probe exit = $code"
Get-ChildItem 's4-frame-*.png' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host ("  frame: {0} ({1:N0} KB)" -f $_.Name, ($_.Length/1KB)) }
Pop-Location

# 清理落盘痕迹：下载目录与探针产生的 profile 存储
# 注意：WebEngine 的持久化目录按 QStandardPaths 分配，根目录是
#   %APPDATA%\browser_probe          (AppDataLocation  -> persistentStoragePath)
#   %LOCALAPPDATA%\browser_probe     (AppLocalDataLocation -> cachePath)
# 其中 browser_probe 取自可执行文件名，不是 storageName（storageName 只是子目录）。
if (Test-Path $dlDir) { Remove-Item $dlDir -Recurse -Force -ErrorAction SilentlyContinue }
$profileDirs = @(
    (Join-Path $env:APPDATA 'browser_probe'),
    (Join-Path $env:LOCALAPPDATA 'browser_probe')
)
foreach ($d in $profileDirs) {
    if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host 'cleaned: download dir + webengine profile storage'
