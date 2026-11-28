<#
.SYNOPSIS
  把 myhub-collector 打成「解压即用」的 Windows 绿色包（自带 Python 运行时与全部依赖）。

.DESCRIPTION
  产物默认落在 deploy\dist\myhub-collector-<版本>-win64.zip，里面是一层同名文件夹：
    app\                 程序本体
    runtime\             嵌入版 Python + 全部依赖（不依赖本机 Python）
    start.bat            一键启动门户
    install-autostart.vbs 注册开机后台自启（备用，门户有开关）
    uninstall-autostart.vbs / stop.bat
    .env / README.txt / README.md
    data\                运行时生成（数据库 / 登录态 / 下载 / 报告 / 日志）

  目标机器不需要装 Python，只要 Windows 10/11 64 位 + Chrome 或 Edge。

  包根的 start.bat / stop.bat / *.vbs / README.txt 来自本目录下的 templates\
  （UTF-8 源码，打包时按扩展名转成 GBK 或 UTF-16LE 再落盘；改文案改 templates 里的文件）。

.PARAMETER Version
  版本号，默认读 myhub-collector\pyproject.toml 里的 version。

.PARAMETER PythonVersion
  内置的 Python 版本（完整版本号，如 3.12.10）。默认 3.12.10。

.PARAMETER OutDir
  压缩包输出目录，默认 deploy\dist。

.PARAMETER Mirror
  pip 镜像地址，例如 https://pypi.tuna.tsinghua.edu.cn/simple。
  不填就走本机 pip 配置 / 官方源。

.PARAMETER IncludeDeno
  把本机 data\tools\deno\deno.exe 一起打进去（YouTube 解 JS 挑战用，约 90 MB）。
  不填则首次用到时由程序自动下载。

.PARAMETER IncludeBrowser
  把 Playwright Chromium 一起打进去（约 150 MB）。不填则用目标机器的 Chrome / Edge。

.PARAMETER KeepBuild
  打包后保留 deploy\build 下的临时目录，方便排查。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File deploy\collector\build.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File deploy\collector\build.ps1 -IncludeDeno -Mirror https://pypi.tuna.tsinghua.edu.cn/simple
#>
param(
    [string]$Version = "",
    [string]$PythonVersion = "3.12.10",
    [string]$OutDir = "",
    [string]$Mirror = "",
    [string]$PythonExe = "python",
    [switch]$IncludeDeno,
    [switch]$IncludeBrowser,
    [switch]$KeepBuild
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # PS5.1 的 Invoke-WebRequest 不关进度条会慢到离谱

function Step([string]$text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Ok([string]$text)   { Write-Host "    $text" -ForegroundColor Green }
function Warn([string]$text) { Write-Host "    $text" -ForegroundColor Yellow }

function Add-DirToZip {
    param([string]$SourceDir, [string]$ZipPath, [string]$Prefix)

    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $parent = Split-Path -Parent $ZipPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }

    $root = (Resolve-Path -LiteralPath $SourceDir).Path.TrimEnd('\')
    $zip = [IO.Compression.ZipFile]::Open($ZipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in (Get-ChildItem -LiteralPath $root -Recurse -File)) {
            $rel = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
            # 字节码一律不进包：来源可能是开发机的 __pycache__，也可能是冒烟自检现生成的
            if ($rel -like "*__pycache__/*" -or $rel -like "*.pyc") { continue }
            if ($Prefix) { $rel = "$Prefix/$rel" }
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $file.FullName, $rel, [IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally { $zip.Dispose() }
}

# ---------------- 路径与参数 ----------------

$deploy    = Split-Path -Parent $PSScriptRoot   # myhub\deploy
$repo      = Split-Path -Parent $deploy         # myhub
$project   = Join-Path $repo "myhub-collector"
$pyproject = Join-Path $project "pyproject.toml"

if (-not (Test-Path -LiteralPath $pyproject)) {
    throw "找不到 $pyproject。脚本要放在 myhub\deploy\collector\ 目录里运行。"
}
if ($PythonVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "-PythonVersion 要写完整版本号（例如 3.12.10），当前：$PythonVersion"
}

if (-not $Version) {
    $rawPyproject = Get-Content -LiteralPath $pyproject -Raw -Encoding UTF8
    $match = [regex]::Match($rawPyproject, '(?m)^\s*version\s*=\s*"([^"]+)"')
    if ($match.Success) { $Version = $match.Groups[1].Value } else { $Version = "0.0.0" }
}

$pyTag     = (($PythonVersion -split '\.')[0..1] -join '')          # 3.12.10 -> 312
$pyMinor   = (($PythonVersion -split '\.')[0..1] -join '.')         # 3.12.10 -> 3.12
$stageName = "myhub-collector-$Version"
$buildRoot = Join-Path $deploy "build"
$stage     = Join-Path $buildRoot $stageName
$cache     = Join-Path $deploy ".cache"
if ($OutDir) { $dist = $OutDir } else { $dist = Join-Path $deploy "dist" }
$zipPath   = Join-Path $dist "$stageName-win64.zip"

foreach ($dir in @($buildRoot, $dist, $cache)) {
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}

# 只允许清理自己算出来的 stage 目录，避免误删
$stageFull = [IO.Path]::GetFullPath($stage)
$buildFull = [IO.Path]::GetFullPath($buildRoot)
if (-not $stageFull.StartsWith($buildFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "内部错误：临时目录不在 build 下（$stageFull）"
}
if (Test-Path -LiteralPath $stageFull) { Remove-Item -LiteralPath $stageFull -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stageFull | Out-Null

Write-Host "打包 myhub-collector $Version（Python $PythonVersion / win_amd64）" -ForegroundColor Cyan
Write-Host "临时目录：$stageFull"
Write-Host "输出目录：$dist"

# ---------------- 1. 嵌入版 Python ----------------

Step "准备嵌入版 Python $PythonVersion"
$embedFile = Join-Path $cache "python-$PythonVersion-embed-amd64.zip"
if (-not (Test-Path -LiteralPath $embedFile)) {
    $embedUrl = "https://www.python.org/ftp/python/$PythonVersion/python-$PythonVersion-embed-amd64.zip"
    Ok "下载 $embedUrl"
    Invoke-WebRequest -Uri $embedUrl -OutFile $embedFile -UseBasicParsing
}
else {
    Ok "复用缓存 $embedFile"
}
$runtime = Join-Path $stageFull "runtime"
Expand-Archive -LiteralPath $embedFile -DestinationPath $runtime -Force
$pyExe = Join-Path $runtime "python.exe"
if (-not (Test-Path -LiteralPath $pyExe)) { throw "解压后没有找到 runtime\python.exe" }

# 让 python.exe 认识 runtime\Lib\site-packages 和上一层的 app\
$pthLines = @("python$pyTag.zip", ".", "Lib\site-packages", "..")
Set-Content -LiteralPath (Join-Path $runtime "python$pyTag._pth") -Value $pthLines -Encoding ascii
Ok "python.exe 就绪"

# ---------------- 2. 依赖 ----------------

Step "解析依赖并下载 win_amd64 轮子"
$rawPyproject = Get-Content -LiteralPath $pyproject -Raw -Encoding UTF8
$depBlock = [regex]::Match($rawPyproject, '(?ms)^\s*dependencies\s*=\s*\[(.*?)\]')
if (-not $depBlock.Success) { throw "pyproject.toml 里没有找到 dependencies 列表" }
$reqs = @([regex]::Matches($depBlock.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
if ($reqs.Count -eq 0) { throw "dependencies 解析为空" }
Ok ("依赖：" + ($reqs -join "、"))

$wheelDir = Join-Path $cache "wheels-$PythonVersion"
if (Test-Path -LiteralPath $wheelDir) {
    # 清不掉也能继续：pip download 会覆盖同名轮子
    try { Remove-Item -LiteralPath $wheelDir -Recurse -Force -ErrorAction Stop }
    catch { Warn "旧轮子缓存清理失败，继续复用：$($_.Exception.Message)" }
}
New-Item -ItemType Directory -Force -Path $wheelDir | Out-Null

$pipArgs = @(
    "-m", "pip", "download",
    "--only-binary=:all:", "--platform", "win_amd64", "--implementation", "cp",
    "--python-version", $pyMinor, "--dest", $wheelDir
)
if ($Mirror) { $pipArgs += @("-i", $Mirror) }
$pipArgs += $reqs

& $PythonExe @pipArgs | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "依赖下载失败。确认网络可用，或加 -Mirror https://pypi.tuna.tsinghua.edu.cn/simple 重试"
}

Step "安装依赖到 runtime\Lib\site-packages"
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
$site = Join-Path (Join-Path $runtime "Lib") "site-packages"
New-Item -ItemType Directory -Force -Path $site | Out-Null

$wheels = @(Get-ChildItem -LiteralPath $wheelDir -Filter "*.whl")
foreach ($wheel in $wheels) {
    $archive = [IO.Compression.ZipFile]::OpenRead($wheel.FullName)
    try {
        foreach ($entry in $archive.Entries) {
            $relPath = $entry.FullName.Replace('/', '\')
            if (-not $relPath -or $relPath.EndsWith('\')) { continue }
            $dest = Join-Path $site $relPath
            $destDir = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $destDir)) {
                New-Item -ItemType Directory -Force -Path $destDir | Out-Null
            }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        }
    }
    finally { $archive.Dispose() }
}
Ok "$($wheels.Count) 个包已解压"

# ---------------- 3. 程序文件 ----------------

Step "拷贝程序与配置"
$stageApp = Join-Path $stageFull "app"
Copy-Item -LiteralPath (Join-Path $project "app") -Destination $stageApp -Recurse -Force
Get-ChildItem -LiteralPath $stageApp -Recurse -Directory -Filter "__pycache__" | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
}
Get-ChildItem -LiteralPath $stageApp -Recurse -File -Filter "*.pyc" | ForEach-Object {
    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
}

foreach ($name in @(".env.example", "README.md")) {
    $src = Join-Path $project $name
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $stageFull $name) -Force
    }
}
# 首启配置：与 .env.example 一致（相对路径以包根目录为基准）
Copy-Item -LiteralPath (Join-Path $stageFull ".env.example") -Destination (Join-Path $stageFull ".env") -Force
Ok "app\ 与 .env 就绪"

# ---------------- 4. 启动 / 自启脚本 ----------------

Step "写入启动与开机自启脚本"
$tplDir = Join-Path $PSScriptRoot "templates"
if (-not (Test-Path -LiteralPath $tplDir)) { throw "找不到模板目录 $tplDir" }

# 模板在仓库里统一是 UTF-8 / LF，落盘时要转成各解释器认的格式：
#   .bat -> GBK(936) + CRLF：cmd.exe 按控制台代码页读批处理，中文只能用本地代码页，
#           配 chcp 936 才不会出现「rem 行被当成命令」的解析错位（UTF-8 批处理的老坑）
#   .vbs -> UTF-16LE + BOM：wscript 默认按 ANSI 读，只有带 BOM 才能正确显示中文
#   .txt -> UTF-8 + CRLF
function Convert-LineEndings([string]$text) {
    return ($text -replace "`r`n", "`n") -replace "`n", "`r`n"
}

foreach ($tpl in (Get-ChildItem -LiteralPath $tplDir -File)) {
    $dst = Join-Path $stageFull $tpl.Name
    $text = Convert-LineEndings ((Get-Content -LiteralPath $tpl.FullName -Raw -Encoding UTF8).Replace("{{VERSION}}", $Version))
    switch ($tpl.Extension.ToLower()) {
        ".bat" { [IO.File]::WriteAllText($dst, $text, [Text.Encoding]::GetEncoding(936)) }
        ".vbs" { [IO.File]::WriteAllText($dst, $text, [Text.Encoding]::Unicode) }
        ".txt" { [IO.File]::WriteAllText($dst, $text, [Text.UTF8Encoding]::new($false)) }
        default { Copy-Item -LiteralPath $tpl.FullName -Destination $dst -Force }
    }
}
Ok "start.bat / install-autostart.vbs / stop.bat / README.txt"

# ---------------- 5. 可选：Deno / Chromium ----------------

$dataDir = Join-Path $stageFull "data"
New-Item -ItemType Directory -Force -Path (Join-Path $dataDir "logs") | Out-Null

if ($IncludeDeno) {
    $denoSrc = Join-Path $project "data\tools\deno\deno.exe"
    if (Test-Path -LiteralPath $denoSrc) {
        $denoDst = Join-Path $dataDir "tools\deno"
        New-Item -ItemType Directory -Force -Path $denoDst | Out-Null
        Copy-Item -LiteralPath $denoSrc -Destination (Join-Path $denoDst "deno.exe") -Force
        Ok "已打入 Deno（YouTube 完整下载）"
    }
    else {
        Warn "本机没有 data\tools\deno\deno.exe，跳过；目标机首次用到时会自动下载"
    }
}

if ($IncludeBrowser) {
    Step "下载 Playwright Chromium（约 150 MB）"
    $env:PLAYWRIGHT_BROWSERS_PATH = Join-Path $runtime "ms-playwright"
    & $pyExe -m playwright install chromium
    if ($LASTEXITCODE -ne 0) { Warn "Chromium 下载失败，包内不含浏览器，将使用目标机的 Chrome / Edge" }
    else { Ok "Chromium 就绪" }
    Remove-Item Env:\PLAYWRIGHT_BROWSERS_PATH -ErrorAction SilentlyContinue
}

# ---------------- 6. 冒烟自检 ----------------

Step "冒烟自检（用包内 Python 跑一遍）"
Push-Location $stageFull
$oldNoBytecode = $env:PYTHONDONTWRITEBYTECODE
$env:PYTHONDONTWRITEBYTECODE = "1"   # 自检别往 app\ 里写 __pycache__
try {
    & $pyExe -c "import sys, httpx, sqlmodel, pydantic_settings, yt_dlp, playwright; print('依赖导入 OK，Python', sys.version.split()[0])"
    if ($LASTEXITCODE -ne 0) { throw "包内 Python 导入依赖失败，见上方报错" }
    & $pyExe -m app --help > $null
    if ($LASTEXITCODE -ne 0) { throw "包内 python -m app 无法启动" }
}
finally {
    if ($null -eq $oldNoBytecode) { Remove-Item Env:\PYTHONDONTWRITEBYTECODE -ErrorAction SilentlyContinue }
    else { $env:PYTHONDONTWRITEBYTECODE = $oldNoBytecode }
    Pop-Location
}

# 自检会写日志，清掉，让用户拿到干净的包
Get-ChildItem -LiteralPath (Join-Path $dataDir "logs") -Filter "*.log*" -ErrorAction SilentlyContinue |
    ForEach-Object {
        try { [IO.File]::Delete($_.FullName) } catch { Warn "日志清理失败：$($_.Exception.Message)" }
    }
Ok "自检通过"

# ---------------- 7. 压缩 ----------------

Step "压缩"
Add-DirToZip -SourceDir $stageFull -ZipPath $zipPath -Prefix $stageName
$sizeMb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)

if (-not $KeepBuild) {
    # 清理失败不影响产物：某些环境（杀软 / 只读）会锁住临时目录
    try { Remove-Item -LiteralPath $stageFull -Recurse -Force -ErrorAction Stop }
    catch { Warn "临时目录清理失败（产物已生成）：$($_.Exception.Message)" }
}

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "打包完成：$zipPath（$sizeMb MB）" -ForegroundColor Green
Write-Host ""
Write-Host "拿到压缩包的人只需："
Write-Host "  1. 解压到任意目录（不要放 C:\Program Files）"
Write-Host "  2. 双击 start.bat 打开门户"
Write-Host "  3. 在「概览」页把「开机自动启动」开关打开即可（不用跑脚本）"
Write-Host ""
Write-Host "日志：解压目录\data\logs\myhub-collector.log"
if ($KeepBuild) {
    Write-Host "临时文件保留在：$stageFull"
} else {
    Write-Host "临时文件已清理（加 -KeepBuild 可保留）"
}
