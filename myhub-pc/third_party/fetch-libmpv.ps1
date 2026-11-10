# 获取 libmpv 开发包并生成 MSVC 导入库
#
# libmpv 二进制体积较大（DLL 约 118MB），不纳入版本库，改为由本脚本按锁定版本
# + SHA256 校验获取，保证可复现。
#
# ⚠️ 许可提醒：下方锁定的 shinchiro 预编译包为 **GPL 构建**（内含 x264 / x265 /
#    libdvdcss 等 GPL 组件）。本项目若要按 LGPL 闭源分发，发布前必须替换为
#    自行编译的 LGPL 版 libmpv（mpv --enable-lgpl + FFmpeg 不启用 GPL 组件）。
#    详见 third_party/README.md「许可状态」一节。
$ErrorActionPreference = 'Continue'

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$dstDir  = Join-Path $here 'libmpv'

# ---- 锁定版本 ----
$release = '20261014'
$fileName = "mpv-dev-x86_64-$release-git-ec38361c56.7z"
$url = "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/$release/$fileName"
$sha256 = '325555b4e0b1d87fb7c92c96010776581599c64e4988052cb9d05e130b52f939'
# 说明：选用 x86_64 而非 x86_64-v3，后者要求 AVX2，会牺牲较旧 CPU 的兼容性
#      （需求文档 §8.4 要求支持 Windows 10 1809+ 的广泛硬件）。

$sevenZip = 'C:\Program Files\7-Zip\7z.exe'
if (-not (Test-Path $sevenZip)) {
    Write-Error "7-Zip not found at $sevenZip. Install via: winget install 7zip.7zip"
    exit 1
}

New-Item -ItemType Directory -Force -Path $dstDir | Out-Null
$archive = Join-Path $env:TEMP $fileName

if (-not (Test-Path $archive)) {
    Write-Host "=== Downloading $fileName ==="
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $archive -TimeoutSec 600
}

Write-Host '=== Verifying SHA256 ==='
$actual = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $sha256) {
    Write-Error "SHA256 mismatch!`n  expected: $sha256`n  actual  : $actual"
    exit 1
}
Write-Host "OK: $actual"

Write-Host '=== Extracting ==='
& $sevenZip x $archive "-o$dstDir" -y | Select-Object -Last 2

Write-Host '=== Generating MSVC import library ==='
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dstDir 'make-implib.ps1')

Write-Host ''
Write-Host "Done. libmpv ready at $dstDir"
