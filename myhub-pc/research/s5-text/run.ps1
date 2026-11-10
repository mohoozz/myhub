# 构建并运行 S5 文本排版探针（10 万字行级分页 + 锚点往返）
# 纯 QtGui，无窗口：用 offscreen 平台插件即可，避免探针把窗口弹到用户桌面上。
$ErrorActionPreference = 'Continue'

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$build  = Join-Path $here 'build'

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
# 不要设 QT_QPA_PLATFORM=offscreen：offscreen 插件下字体库为空，
# 量出来的行高是假的。探针不建窗口，用默认平台插件也不会弹窗。

Push-Location $build
Write-Host ''
Write-Host '=== Run: text layout probe ==='
Remove-Item 's5-text-report.txt' -Force -ErrorAction SilentlyContinue
& (Join-Path $build 'text_probe.exe') 2>&1 | Out-Null
$code = $LASTEXITCODE
if (Test-Path 's5-text-report.txt') {
    # 报告里含中文，必须按 UTF-8 读；PowerShell 5.1 的默认编码会把中文读成乱码
    Get-Content 's5-text-report.txt' -Encoding UTF8 | ForEach-Object { Write-Host "  $_" }
}
Write-Host "probe exit = $code"
Pop-Location

if ($code -ne 0) { exit $code }
