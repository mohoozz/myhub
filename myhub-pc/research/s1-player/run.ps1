# 构建并运行 S1 预研探针
param(
    [switch]$DecodeOnly,
    [switch]$RenderOnly,
    [switch]$CompatOnly,
    [string]$Backend = ''        # 空=OpenGL（FBO 要求），或 'd3d11' 做对比实验
)

$ErrorActionPreference = 'Continue'

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$root    = Split-Path -Parent (Split-Path -Parent $here)
$build   = Join-Path $here 'build'
$media   = Join-Path $env:TEMP 'myhub-s1-media'
$tp      = Join-Path $root 'third_party'

$vcvars  = 'C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$qtRoot  = 'C:/Qt/6.8.3/msvc2022_64'
$vcpkgIn = 'C:/vcpkg/installed/x64-windows'
$mpvqt   = ($tp -replace '\\','/') + '/mpvqt-install'
$libmpv  = ($tp -replace '\\','/') + '/libmpv'

if (-not (Test-Path (Join-Path $media 'hevc_1080p.mkv'))) {
    Write-Host 'media missing, generating ...'
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'make-media.ps1') | Out-Null
}

Write-Host '=== MSVC environment ==='
$envDump = & cmd.exe /c "call `"$vcvars`" >nul 2>&1 && set"
foreach ($line in $envDump) {
    if ($line -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
}

Write-Host '=== Configure ==='
$cmakeArgs = @(
    '-S', $here, '-B', $build, '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release',
    "-DCMAKE_PREFIX_PATH=$qtRoot;$vcpkgIn;$mpvqt",
    "-DLibmpv_INCLUDE_DIRS=$libmpv/include",
    "-DLibmpv_LIBRARIES=$libmpv/mpv.lib"
)
$cfg = & cmake @cmakeArgs 2>&1
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

# 运行期 DLL
$env:PATH = ($qtRoot -replace '/','\') + '\bin;' +
            ($vcpkgIn -replace '/','\') + '\bin;' +
            ($libmpv -replace '/','\') + ';' +
            ($mpvqt -replace '/','\') + '\bin;' + $env:PATH

Push-Location $build

if (-not $RenderOnly -and -not $CompatOnly) {
    Write-Host ''
    Write-Host '=== Run: decode probe ==='
    Remove-Item 's1-decode-report.txt' -Force -ErrorAction SilentlyContinue
    & (Join-Path $build 'decode_probe.exe') $media 2>&1 | Out-Null
    $decodeExit = $LASTEXITCODE
    if (Test-Path 's1-decode-report.txt') {
        Get-Content 's1-decode-report.txt' | ForEach-Object { Write-Host "  $_" }
    }
    Write-Host "decode exit = $decodeExit"
}

if (-not $DecodeOnly -and -not $CompatOnly) {
    Write-Host ''
    Write-Host '=== Run: render probe ==='
    Remove-Item 's1-render-report.txt' -Force -ErrorAction SilentlyContinue
    & (Join-Path $build 'render_probe.exe') $media $Backend 2>&1 | Out-Null
    $renderExit = $LASTEXITCODE
    if (Test-Path 's1-render-report.txt') {
        Get-Content 's1-render-report.txt' | ForEach-Object { Write-Host "  $_" }
    }
    Write-Host "render exit = $renderExit"
    Get-ChildItem 's1-frame-*.png' -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host ("  frame: {0} ({1:N0} KB)" -f $_.Name, ($_.Length/1KB)) }
}

if (-not $DecodeOnly -and -not $RenderOnly) {
    Write-Host ''
    Write-Host '=== Run: compat probe (libmpv + QtWebEngine) ==='
    Remove-Item 's1-compat-report.txt' -Force -ErrorAction SilentlyContinue
    & (Join-Path $build 'compat_probe.exe') $media 2>&1 | Out-Null
    $compatExit = $LASTEXITCODE
    if (Test-Path 's1-compat-report.txt') {
        Get-Content 's1-compat-report.txt' | ForEach-Object { Write-Host "  $_" }
    }
    Write-Host "compat exit = $compatExit"
}

Pop-Location
