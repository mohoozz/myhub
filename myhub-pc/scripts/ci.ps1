# myhub-pc 本地 CI：构建 → 单测 → 规范校验，一条命令复现流水线
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\ci.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\ci.ps1 -Preset windows-release
#
# 这个脚本同时是 `.github/workflows/ci.yml` 的执行体：workflow 只负责装环境
# （Qt / vcpkg / MSVC），真正的「做什么」都在这里，避免两套逻辑漂移。
param(
    [string]$Preset = 'windows-debug',
    [switch]$SkipLint,
    [switch]$SkipTidy,
    [string]$QtRoot  = 'C:/Qt/6.8.3/msvc2022_64',
    [string]$VcVars  = 'C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat',
    [string]$LlvmBin = 'C:\BuildTools\VC\Tools\Llvm\x64\bin',
    [switch]$SkipVsEnv
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# ---------- 构建 + 单测 ----------
Write-Host '### build + test' -ForegroundColor Cyan
& (Join-Path $root 'scripts\build.ps1') -Preset $Preset -Test -QtRoot $QtRoot -VcVars $VcVars -SkipVsEnv:$SkipVsEnv
if ($LASTEXITCODE -ne 0) { Write-Host 'BUILD/TEST FAILED' -ForegroundColor Red; exit 1 }

# ---------- 规范校验 ----------
if ($SkipLint) {
    Write-Host '### lint (skipped)' -ForegroundColor Yellow
} else {
    Write-Host '### lint' -ForegroundColor Cyan
    & (Join-Path $root 'scripts\lint.ps1') -Preset $Preset -QtRoot $QtRoot -LlvmBin $LlvmBin -SkipTidy:$SkipTidy
    if ($LASTEXITCODE -ne 0) { Write-Host 'LINT FAILED' -ForegroundColor Red; exit 1 }
}

Write-Host ''
Write-Host 'CI PASSED' -ForegroundColor Green
exit 0
