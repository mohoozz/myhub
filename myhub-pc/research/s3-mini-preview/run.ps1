# 构建并运行 S3 mini 预览探针
$ErrorActionPreference = 'Continue'

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$root   = Split-Path -Parent (Split-Path -Parent $here)
$build  = Join-Path $here 'build'
$media  = Join-Path $env:TEMP 'myhub-s3-media'
$tp     = Join-Path $root 'third_party'

$vcvars = 'C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$qtRoot = 'C:/Qt/6.8.3/msvc2022_64'
$libmpv = ($tp -replace '\\','/') + '/libmpv'
$mpvqt  = ($tp -replace '\\','/') + '/mpvqt-install'

if (-not (Test-Path (Join-Path $media 'long_1080p.mkv'))) {
    Write-Host '=== Generating long media (one-off) ==='
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $here 'make-long-media.ps1')
    if (-not (Test-Path (Join-Path $media 'long_1080p.mkv'))) {
        Write-Host 'media generation failed'
        exit 1
    }
}

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
    "-DCMAKE_PREFIX_PATH=$qtRoot;$mpvqt" `
    "-DLibmpv_INCLUDE_DIRS=$libmpv/include" `
    "-DLibmpv_LIBRARIES=$libmpv/mpv.lib" 2>&1
if ($LASTEXITCODE -ne 0) {
    $cfg | Select-Object -Last 25 | ForEach-Object { Write-Host $_ }
    exit 1
}
$cfg | Where-Object { $_ -match 'Found Libmpv|Configuring done|Generating done' } |
    ForEach-Object { Write-Host $_ }

Write-Host '=== Build ==='
$bld = & cmake --build $build --parallel 2>&1
if ($LASTEXITCODE -ne 0) {
    $bld | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }
    exit 1
}
Write-Host 'build OK'

$env:PATH = ($qtRoot -replace '/','\') + '\bin;' +
            ($libmpv -replace '/','\') + ';' +
            ($mpvqt  -replace '/','\') + '\bin;' + $env:PATH

Push-Location $build
Write-Host ''
Write-Host '=== Run: mini preview probe ==='
Remove-Item 's3-mini-report.txt' -Force -ErrorAction SilentlyContinue
& (Join-Path $build 'mini_preview_probe.exe') $media 2>&1 | Out-Null
$code = $LASTEXITCODE
if (Test-Path 's3-mini-report.txt') {
    Get-Content 's3-mini-report.txt' | ForEach-Object { Write-Host "  $_" }
}
Write-Host "probe exit = $code"
Get-ChildItem 's3-frame-*.png' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host ("  frame: {0} ({1:N0} KB)" -f $_.Name, ($_.Length/1KB)) }
Pop-Location
