# 诊断：输出构建的完整错误信息
param([string]$Preset = 'windows-debug', [string]$Target = '')

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$vcvars = 'C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat'

$envDump = & cmd.exe /c "call `"$vcvars`" >nul 2>&1 && set"
foreach ($line in $envDump) {
    if ($line -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
}

$buildDir = Join-Path $root "build\$Preset"
$args = @('--build', $buildDir)
if ($Target) { $args += @('--target', $Target) }

$out = & cmake @args 2>&1
$out | Select-Object -Last 60 | ForEach-Object { Write-Host $_ }
Write-Host "exit = $LASTEXITCODE"
