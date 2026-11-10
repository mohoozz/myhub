# 构建 mpvqt（KDE）并安装到 third_party/mpvqt-install[-debug]
# 依赖：Qt6 Quick、libmpv（third_party/libmpv）、KDE ECM（vcpkg）
# CMake/ECM 会往 stderr 写正常提示，不能用 Stop
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File third_party\build-mpvqt.ps1
#   powershell -ExecutionPolicy Bypass -File third_party\build-mpvqt.ps1 -Config Debug
#   powershell -ExecutionPolicy Bypass -File third_party\build-mpvqt.ps1 -QtRoot D:/Qt/6.8.3/msvc2022_64
#
# **-Config 必须与应用的构建类型一致**：MSVC 下 Debug 应用依赖 Qt6Cored.dll /
# Qt6Quickd.dll，而 Release 版 MpvQt.dll 依赖 Qt6Core.dll / Qt6Quick.dll。
# 两者混用会把两套 Qt 运行时载入同一进程，实例化 MpvAbstractItem 时
# 在其基类构造（QQuickFramebufferObject）里直接崩溃（SIGSEGV，无任何日志）。
param(
    # 默认值等于本机开发环境；换机器 / CI 时显式传入
    [string]$QtRoot         = 'C:/Qt/6.8.3/msvc2022_64',
    [string]$VcpkgInstalled = 'C:/vcpkg/installed/x64-windows',
    [string]$VcVars         = 'C:\BuildTools\VC\Auxiliary\Build\vcvars64.bat',
    [switch]$SkipVsEnv,
    [ValidateSet('Debug', 'Release')]
    [string]$Config         = 'Release'
)
$ErrorActionPreference = 'Continue'

$here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$src       = Join-Path $here 'mpvqt'
# 两种配置各自独立的构建树与安装树，互不覆盖
if ($Config -eq 'Debug') {
    $build   = Join-Path $here 'mpvqt-build-debug'
    $install = Join-Path $here 'mpvqt-install-debug'
} else {
    $build   = Join-Path $here 'mpvqt-build'
    $install = Join-Path $here 'mpvqt-install'
}
$libmpvDir = Join-Path $here 'libmpv'

$vcvars  = $VcVars
$qtRoot  = $QtRoot
$vcpkgIn = $VcpkgInstalled

# ---- 锁定版本 ----
$mpvqtTag  = 'v1.2.0'
$mpvqtRepo = 'https://github.com/KDE/mpvqt.git'   # KDE 官方镜像（invent.kde.org 可能返回 403）
$patchFile = Join-Path $here 'patches\mpvqt-0001-qt68-logging-category.patch'

# ---- 获取源码并应用补丁（源码不入库，见 .gitignore）----
if (-not (Test-Path (Join-Path $src 'CMakeLists.txt'))) {
    Write-Host "=== Cloning mpvqt $mpvqtTag ==="
    Remove-Item $src -Recurse -Force -ErrorAction SilentlyContinue
    & git clone --quiet $mpvqtRepo $src 2>&1 | Out-Null
    if (-not (Test-Path (Join-Path $src 'CMakeLists.txt'))) {
        Write-Error "clone failed: $mpvqtRepo"
        exit 1
    }
    Push-Location $src
    & git checkout --quiet $mpvqtTag 2>&1 | Out-Null
    Write-Host ("checked out: " + (& git describe --tags))

    # Qt 6.8 兼容补丁（Q_STATIC_LOGGING_CATEGORY 需 Qt 6.9+），LGPL 要求公开此修改
    if (Test-Path $patchFile) {
        Write-Host '=== Applying patch for Qt 6.8 compatibility ==='
        & git apply --verbose $patchFile 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { Write-Error 'git apply failed'; Pop-Location; exit 1 }
    } else {
        Write-Warning "patch not found: $patchFile (build will fail on Qt < 6.9)"
    }
    Pop-Location
} else {
    Push-Location $src
    Write-Host ("=== Using existing source: " + (& git describe --tags 2>$null) + " ===")
    Pop-Location
}

if (-not $SkipVsEnv) {
    if (-not (Test-Path $vcvars)) {
        Write-Error "vcvars64.bat not found at $vcvars (CI 上可用 -SkipVsEnv，由 setup 步骤提供 cl.exe)"
        exit 1
    }
    Write-Host '=== Importing MSVC environment ==='
    $envDump = & cmd.exe /c "call `"$vcvars`" >nul 2>&1 && set"
    foreach ($line in $envDump) {
        if ($line -match '^([^=]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}

Remove-Item $build -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "=== Configuring mpvqt ($Config) ==="
$cmakeArgs = @(
    '-S', $src,
    '-B', $build,
    '-G', 'Ninja',
    "-DCMAKE_BUILD_TYPE=$Config",
    "-DCMAKE_INSTALL_PREFIX=$install",
    "-DCMAKE_PREFIX_PATH=$qtRoot;$vcpkgIn",
    # 指向 vendor 的 libmpv（FindLibmpv.cmake 读取这两个变量）
    "-DLibmpv_INCLUDE_DIRS=$($libmpvDir -replace '\\','/')/include",
    "-DLibmpv_LIBRARIES=$($libmpvDir -replace '\\','/')/mpv.lib",
    '-DBUILD_TESTING=OFF'
)
Write-Host ('cmake ' + ($cmakeArgs -join ' '))
$cfg = & cmake @cmakeArgs 2>&1
$cfgExit = $LASTEXITCODE
$cfg | Where-Object { $_ -match 'Libmpv|Qt6|Configuring|Generating|Error|error|Could NOT' } | ForEach-Object { Write-Host $_ }
Write-Host "configure exit = $cfgExit"
if ($cfgExit -ne 0) {
    Write-Host '--- full tail ---'
    $cfg | Select-Object -Last 30 | ForEach-Object { Write-Host $_ }
    exit 1
}

Write-Host ''
Write-Host '=== Building ==='
$bld = & cmake --build $build --parallel 2>&1
$bldExit = $LASTEXITCODE
if ($bldExit -ne 0) { $bld | Select-Object -Last 30 | ForEach-Object { Write-Host $_ } } else { $bld | Select-Object -Last 4 | ForEach-Object { Write-Host $_ } }
Write-Host "build exit = $bldExit"
if ($bldExit -ne 0) { exit 1 }

Write-Host ''
Write-Host '=== Installing ==='
& cmake --install $build 2>&1 | Select-Object -Last 4 | ForEach-Object { Write-Host $_ }
Write-Host "install exit = $LASTEXITCODE"
