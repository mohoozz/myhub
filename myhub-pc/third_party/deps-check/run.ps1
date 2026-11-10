# 构建并运行原生依赖自检
$ErrorActionPreference = 'Continue'

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$build   = Join-Path $here 'build'
$tp      = Split-Path -Parent $here
$vcvars  = 'C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$qtRoot  = 'C:/Qt/6.8.3/msvc2022_64'
$vcpkgIn = 'C:/vcpkg/installed/x64-windows'
$mpvqt   = ($tp -replace '\\','/') + '/mpvqt-install'
$libmpv  = ($tp -replace '\\','/') + '/libmpv'

Write-Host '=== MSVC environment ==='
$envDump = & cmd.exe /c "call `"$vcvars`" >nul 2>&1 && set"
foreach ($line in $envDump) {
    if ($line -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
}

Remove-Item $build -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '=== Configure ==='
$cmakeArgs = @(
    '-S', $here, '-B', $build, '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release',
    "-DCMAKE_PREFIX_PATH=$qtRoot;$vcpkgIn;$mpvqt",
    "-DLibsmb2_ROOT=$vcpkgIn",
    "-DLibmpv_INCLUDE_DIRS=$libmpv/include",
    "-DLibmpv_LIBRARIES=$libmpv/mpv.lib"
)
$cfg = & cmake @cmakeArgs 2>&1
$cfgExit = $LASTEXITCODE
$cfg | Where-Object { $_ -match 'Found|Could NOT|Configuring|Generating|Error|error' } | ForEach-Object { Write-Host $_ }
Write-Host "configure exit = $cfgExit"
if ($cfgExit -ne 0) { $cfg | Select-Object -Last 25 | ForEach-Object { Write-Host $_ }; exit 1 }

Write-Host ''
Write-Host '=== Build ==='
$bld = & cmake --build $build --parallel 2>&1
$bldExit = $LASTEXITCODE
if ($bldExit -ne 0) { $bld | Select-Object -Last 30 | ForEach-Object { Write-Host $_ } }
else { $bld | Select-Object -Last 3 | ForEach-Object { Write-Host $_ } }
Write-Host "build exit = $bldExit"
if ($bldExit -ne 0) { exit 1 }

Write-Host ''
Write-Host '=== Run ==='
# 运行期需要各 DLL：Qt / vcpkg / libmpv / MpvQt
$env:PATH = ($qtRoot -replace '/','\') + '\bin;' +
            ($vcpkgIn -replace '/','\') + '\bin;' +
            ($libmpv -replace '/','\') + ';' +
            ($mpvqt -replace '/','\') + '\bin;' + $env:PATH
Push-Location $build
Remove-Item 'deps-report.txt' -Force -ErrorAction SilentlyContinue
& (Join-Path $build 'deps_check.exe') 2>&1 | Out-Null
$runExit = $LASTEXITCODE
if (Test-Path 'deps-report.txt') { Get-Content 'deps-report.txt' | ForEach-Object { Write-Host "  $_" } }
else { Write-Host '  deps-report.txt not produced' }
Pop-Location
Write-Host "run exit = $runExit"
