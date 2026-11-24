<#
.SYNOPSIS
  myhub-collector 首次初始化：虚拟环境 → 依赖 → 浏览器 → .env → 数据目录 → 自检。

.DESCRIPTION
  跑完后再执行 `python -m app login all` 弹窗登录三个平台即可开始采集。
  重复执行是安全的：已有的 .venv / .env / 依赖都会复用，不会覆盖你的配置。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\setup.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -Login all

.EXAMPLE
  # 已经装过依赖，只想重建自检
  powershell -ExecutionPolicy Bypass -File scripts\setup.ps1 -SkipDeps -SkipBrowser
#>
param(
    [string]$Python = "python",
    [switch]$NoVenv,
    [switch]$Recreate,
    [switch]$SkipDeps,
    [switch]$SkipBrowser,
    [string[]]$Login = @()
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Step([string]$text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Ok([string]$text)   { Write-Host "    $text" -ForegroundColor Green }
function Warn([string]$text) { Write-Host "    $text" -ForegroundColor Yellow }

Write-Host "myhub-collector 初始化" -ForegroundColor Cyan
Write-Host "项目目录：$root"

# ---------- 1. Python ----------
Step "检查 Python"
$verText = & $Python --version 2>&1
if ($LASTEXITCODE -ne 0 -or -not $verText) {
    throw "找不到 Python。先安装 Python 3.10+ 并勾选 Add to PATH，或用 -Python 指定完整路径。"
}
if ("$verText" -notmatch "(\d+)\.(\d+)") {
    throw "无法识别 Python 版本：$verText"
}
$raw = "$($Matches[1]).$($Matches[2])"
if ([version]$raw -lt [version]"3.10") {
    throw "当前 Python $raw 版本过低，需要 3.10 或更高。"
}
Ok "Python $raw"

# ---------- 2. 虚拟环境 ----------
Step "准备虚拟环境 .venv"
$venvDir = Join-Path $root ".venv"
$venvPy = Join-Path $venvDir "Scripts\python.exe"
if ($NoVenv) {
    $venvPy = (Get-Command $Python -ErrorAction Stop).Source
    Ok "跳过 .venv，直接使用 $venvPy"
}
else {
    if ($Recreate -and (Test-Path $venvDir)) {
        Remove-Item $venvDir -Recurse -Force
        Ok "已删除旧 .venv"
    }
    if (-not (Test-Path $venvPy)) {
        & $Python -m venv $venvDir
        if ($LASTEXITCODE -ne 0) { throw "创建虚拟环境失败。" }
        Ok "已创建 .venv"
    }
    else {
        Ok "复用已有 .venv"
    }
}

# ---------- 3. 依赖 ----------
if (-not $SkipDeps) {
    Step "安装依赖（首次约 1-3 分钟）"
    & $venvPy -m pip install --upgrade pip --quiet
    & $venvPy -m pip install -e .
    if ($LASTEXITCODE -ne 0) {
        throw "依赖安装失败。可换国内镜像重试：`n  $venvPy -m pip install -e . -i https://pypi.tuna.tsinghua.edu.cn/simple"
    }
    Ok "依赖安装完成"
}

# ---------- 4. 浏览器 ----------
if (-not $SkipBrowser) {
    Step "安装 Playwright Chromium（约 150 MB，登录 / 抖音抓取要用）"
    & $venvPy -m playwright install chromium
    if ($LASTEXITCODE -ne 0) {
        Warn "Chromium 下载失败；只要本机装了 Chrome 或 Edge 仍可正常使用。"
    }
    else {
        Ok "Chromium 就绪"
    }
}

# ---------- 5. 配置文件 ----------
Step "准备配置文件"
$envFile = Join-Path $root ".env"
$example = Join-Path $root ".env.example"
if (-not (Test-Path $envFile)) {
    if (Test-Path $example) {
        Copy-Item $example $envFile
        Ok "已从 .env.example 生成 .env（需要时再填 PROXY / YOUTUBE_CHANNELS）"
    }
    else {
        Warn "没有 .env.example，跳过（全部使用默认值）"
    }
}
else {
    Ok ".env 已存在，未覆盖"
}

# ---------- 6. 自检 ----------
Step "初始化数据目录并自检"
& $venvPy -m app init
$initCode = $LASTEXITCODE

# ---------- 7. 可选：直接登录 ----------
foreach ($platform in $Login) {
    if (-not $platform) { continue }
    Step "弹窗登录：$platform（窗口里手动登录，成功后自动继续）"
    & $venvPy -m app login $platform
}

# ---------- 8. 收尾 ----------
Write-Host "`n=====================================================" -ForegroundColor Cyan
if ($initCode -eq 0) {
    Write-Host "初始化完成" -ForegroundColor Green
}
else {
    Write-Host "初始化完成，但自检发现问题（见上方「需要先处理」）" -ForegroundColor Yellow
}

if ($NoVenv) {
    $runHint = "接下来依次执行："
    $venvHint = ""
}
else {
    $runHint = @"
建议先激活虚拟环境：
  .\.venv\Scripts\Activate.ps1
  （若提示禁止运行脚本：Set-ExecutionPolicy -Scope CurrentUser RemoteSigned）

接下来依次执行：
"@
    $venvHint = "`n不激活也能用，把 python 换成 .\.venv\Scripts\python.exe -m app ...`n"
}

Write-Host @"

解释器：$venvPy

$runHint
  python -m app status       查看登录态
  python -m app login all    弹窗登录三个平台
  python -m app sync         同步关注 / 频道
  python -m app collect      采集前一天
$venvHint
注册每日计划任务：
  powershell -ExecutionPolicy Bypass -File scripts\register-task.ps1 -Python "$venvPy"
"@

exit $initCode
