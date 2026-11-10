# 由 libmpv-2.dll 生成 MSVC 可链接的导入库 mpv.lib
# libmpv 官方发布包仅提供 MinGW 格式的 libmpv.dll.a，MSVC 需要自行生成 .lib
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$vcvars = 'C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$dll = Join-Path $here 'libmpv-2.dll'

if (-not (Test-Path $dll)) { throw "libmpv-2.dll not found at $dll" }

# 导入 MSVC 环境
$envDump = & cmd.exe /c "call `"$vcvars`" >nul 2>&1 && set"
foreach ($line in $envDump) {
    if ($line -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
}

Write-Host '=== Extracting exported symbols ==='
$exports = & dumpbin.exe /exports $dll

# dumpbin 导出表格式: ordinal hint RVA name
$symbols = @()
foreach ($line in $exports) {
    if ($line -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]{8}\s+(\S+)') {
        $symbols += $Matches[1]
    }
}
Write-Host "symbol count = $($symbols.Count)"
if ($symbols.Count -eq 0) { throw 'No exported symbols parsed from dumpbin output' }

$defPath = Join-Path $here 'mpv.def'
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('LIBRARY libmpv-2.dll')
[void]$sb.AppendLine('EXPORTS')
foreach ($s in ($symbols | Sort-Object -Unique)) {
    [void]$sb.AppendLine("    $s")
}
Set-Content -Path $defPath -Value $sb.ToString() -Encoding ascii
Write-Host "wrote $defPath"

Write-Host '=== Generating import library ==='
$libPath = Join-Path $here 'mpv.lib'
& lib.exe "/def:$defPath" "/out:$libPath" /machine:x64 /nologo
if ($LASTEXITCODE -ne 0) { throw "lib.exe failed with $LASTEXITCODE" }

Write-Host "OK -> $libPath ($([math]::Round((Get-Item $libPath).Length/1KB)) KB)"
