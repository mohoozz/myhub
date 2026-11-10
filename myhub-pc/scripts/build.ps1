# MyHub 构建脚本（Windows）
#
# 作用：导入 MSVC 环境 → CMake 配置 → 构建 →（可选）跑单测
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\build.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\build.ps1 -Preset windows-release -Test
param(
    [string]$Preset = 'windows-debug',
    [switch]$Test,
    [switch]$Clean,
    [switch]$Run,
    [string]$Target = '',
    # 以下三项是为了能在 CI / 别人的机器上跑：默认值等于本机开发环境
    [string]$QtRoot = 'C:/Qt/6.8.3/msvc2022_64',
    [string]$VcVars = 'C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat',
    [switch]$SkipVsEnv
)

$ErrorActionPreference = 'Continue'

$root   = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$vcvars = $VcVars
$qtDir  = $QtRoot

if (-not $SkipVsEnv) {
    if (-not (Test-Path $vcvars)) {
        Write-Error "vcvars64.bat not found at $vcvars (CI 上可用 -SkipVsEnv，由 setup 步骤提供 cl.exe)"
        exit 1
    }
    Write-Host '=== Importing MSVC environment ===' -ForegroundColor Cyan
    $envDump = & cmd.exe /c "call `"$vcvars`" >nul 2>&1 && set"
    foreach ($line in $envDump) {
        if ($line -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}

$buildDir = Join-Path $root "build\$Preset"
if ($Clean) {
    Write-Host "=== Cleaning $buildDir ===" -ForegroundColor Cyan
    Remove-Item $buildDir -Recurse -Force -ErrorAction SilentlyContinue
}

Push-Location $root

Write-Host "=== Configure ($Preset) ===" -ForegroundColor Cyan
$cfg = & cmake --preset $Preset 2>&1
$cfgExit = $LASTEXITCODE
$cfg | Where-Object { $_ -match 'Found|Could NOT|LicenseGuard|Configuring|Generating|Error|error:' } |
    ForEach-Object { Write-Host $_ }
if ($cfgExit -ne 0) {
    Write-Host '--- configure output tail ---' -ForegroundColor Yellow
    $cfg | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }
    Pop-Location
    exit 1
}

Write-Host '=== Build ===' -ForegroundColor Cyan
$buildArgs = @('--build', '--preset', $Preset, '--parallel')
if ($Target) { $buildArgs += @('--target', $Target) }
$bld = & cmake @buildArgs 2>&1
$bldExit = $LASTEXITCODE
if ($bldExit -ne 0) {
    $bld | Where-Object { $_ -match 'error|Error|FAILED' } | Select-Object -First 40 |
        ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Write-Host "build exit = $bldExit" -ForegroundColor Red
    Pop-Location
    exit 1
}
$bld | Select-Object -Last 3 | ForEach-Object { Write-Host $_ }
Write-Host 'build OK' -ForegroundColor Green

if ($Test) {
    Write-Host ''
    Write-Host '=== Tests ===' -ForegroundColor Cyan
    Push-Location $buildDir
    & ctest --output-on-failure 2>&1 | Select-Object -Last 25 | ForEach-Object { Write-Host $_ }
    $testExit = $LASTEXITCODE
    Pop-Location
    if ($testExit -ne 0) { Pop-Location; exit 1 }
}

if ($Run) {
    Write-Host ''
    Write-Host '=== Run ===' -ForegroundColor Cyan
    $exe = Join-Path $buildDir 'MyHub.exe'
    if (Test-Path $exe) {
        $env:PATH = ($qtDir -replace '/','\') + '\bin;' + $env:PATH
        & $exe
    } else {
        Write-Host "executable not found: $exe" -ForegroundColor Red
    }
}

Pop-Location
