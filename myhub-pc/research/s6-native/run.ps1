# 构建并运行 S6 原生依赖探针
param([switch]$SkipSmb)

$ErrorActionPreference = 'Continue'

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$root    = Split-Path -Parent (Split-Path -Parent $here)
$build   = Join-Path $here 'build'
$arch    = Join-Path $env:TEMP 'myhub-s6-archives'
$media   = Join-Path $env:TEMP 'myhub-s1-media'
$tp      = Join-Path $root 'third_party'

$vcvars  = 'C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$qtRoot  = 'C:/Qt/6.8.3/msvc2022_64'
$vcpkgIn = 'C:/vcpkg/installed/x64-windows'
$libmpv  = ($tp -replace '\\','/') + '/libmpv'

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
    "-DCMAKE_PREFIX_PATH=$qtRoot;$vcpkgIn" `
    "-DLibsmb2_ROOT=$vcpkgIn" `
    "-DLibmpv_INCLUDE_DIRS=$libmpv/include" `
    "-DLibmpv_LIBRARIES=$libmpv/mpv.lib" 2>&1
if ($LASTEXITCODE -ne 0) { $cfg | Select-Object -Last 25 | ForEach-Object { Write-Host $_ }; exit 1 }
$cfg | Where-Object { $_ -match 'Found Lib|Configuring done|Generating done' } |
    ForEach-Object { Write-Host $_ }

Write-Host '=== Build ==='
$bld = & cmake --build $build --parallel 2>&1
if ($LASTEXITCODE -ne 0) { $bld | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }; exit 1 }
Write-Host 'build OK'

$env:PATH = ($qtRoot -replace '/','\') + '\bin;' +
            ($vcpkgIn -replace '/','\') + '\bin;' +
            ($libmpv -replace '/','\') + ';' + $env:PATH

Push-Location $build

# ---- S6-A：libarchive ----
Write-Host ''
Write-Host '=== S6-A: libarchive comic pages ==='
Remove-Item 's6-archive-report.txt' -Force -ErrorAction SilentlyContinue
& (Join-Path $build 'archive_probe.exe') $arch 2>&1 | Out-Null
$a = $LASTEXITCODE
if (Test-Path 's6-archive-report.txt') {
    Get-Content 's6-archive-report.txt' | ForEach-Object { Write-Host "  $_" }
}
Write-Host "archive exit = $a"

# ---- S6-B：libsmb2 ----
if (-not $SkipSmb) {
    $credFile = Join-Path $env:TEMP 'myhub-s6-cred.txt'
    if (Test-Path $credFile) {
        $cred = Get-Content $credFile
        $u = $cred[0]; $p = $cred[1]
        Write-Host ''
        Write-Host '=== S6-B: libsmb2 SMB2/3 ==='
        Remove-Item 's6-smb-report.txt' -Force -ErrorAction SilentlyContinue
        & (Join-Path $build 'smb_probe.exe') '127.0.0.1' 'myhub_s6_share' $u $p 2>&1 | Out-Null
        $s = $LASTEXITCODE
        if (Test-Path 's6-smb-report.txt') {
            Get-Content 's6-smb-report.txt' | ForEach-Object { Write-Host "  $_" }
        }
        Write-Host "smb exit = $s"
    } else {
        Write-Host ''
        Write-Host "=== S6-B skipped: run smb-setup.ps1 first (as admin) ==="
    }
}

# ---- S6-C：回环 HTTP ----
Write-Host ''
Write-Host '=== S6-C: loopback HTTP Range ==='
Remove-Item 's6-loopback-report.txt' -Force -ErrorAction SilentlyContinue
& (Join-Path $build 'loopback_probe.exe') (Join-Path $media 'hevc_1080p.mkv') 2>&1 | Out-Null
$l = $LASTEXITCODE
if (Test-Path 's6-loopback-report.txt') {
    Get-Content 's6-loopback-report.txt' | ForEach-Object { Write-Host "  $_" }
}
Write-Host "loopback exit = $l"

Pop-Location
