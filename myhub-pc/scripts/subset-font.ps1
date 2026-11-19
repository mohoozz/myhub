# 重新生成内置正文字体：思源宋体（Source Han Serif CN）子集
#
# 产物：
#   resources/fonts/serif/SourceHanSerifCN-Subset.otf   ~6.8 MB（U+4E00–9FFF 全量 + 标点 + 假名）
#   resources/fonts/serif/OFL.txt                       SIL OFL 1.1 原文，必须随字体一起分发
#
# 依赖：python + fonttools（pip install fonttools brotli），以及能访问 GitHub raw。
# 平时不用跑这个脚本 —— 产物已在仓库里；只有想换字重/换字面/调整字符范围时才跑。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\subset-font.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\subset-font.ps1 -Weight Bold
param(
    [string]$Weight = "Regular",
    [string]$RawBase = "https://raw.githubusercontent.com/adobe-fonts/source-han-serif/release"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot # myhub-pc/
$outDir = Join-Path $root "resources\fonts\serif"
$workDir = Join-Path $root "build\fontwork"
$srcOtf = Join-Path $workDir "SourceHanSerifCN-$Weight.otf"
$outOtf = Join-Path $outDir "SourceHanSerifCN-Subset.otf"

# 覆盖正文需要的全部字形，同时别把体积撑爆：
#   基本拉丁 + 拉丁补充      ：英文、数字、音标
#   常用标点 U+2000-206F     ：弯引号、破折号、省略号
#   CJK 标点 U+3000-303F     ：全角标点、顿号、书名号
#   假名 U+3040-30FF         ：日文引文/书名
#   CJK 统一汉字 U+4E00-9FFF ：20992 个，小说正文的实际范围
#   全角字符 U+FF00-FFEF     ：全角字母数字
$unicodes = "U+0020-007E,U+00A0-00FF,U+2000-206F,U+3000-303F,U+3040-30FF,U+4E00-9FFF,U+FF00-FFEF"

Write-Host "[1/4] 检查 python / fonttools"
python -c "import fontTools" 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "缺少 fonttools：pip install fonttools"
}

New-Item -ItemType Directory -Force -Path $workDir, $outDir | Out-Null

if (-not (Test-Path $srcOtf)) {
    Write-Host "[2/4] 下载 SourceHanSerifCN-$Weight.otf（约 11 MB）"
    Invoke-WebRequest -Uri "$RawBase/SubsetOTF/CN/SourceHanSerifCN-$Weight.otf" -OutFile $srcOtf -UseBasicParsing
} else {
    Write-Host "[2/4] 复用已下载的源字体：$srcOtf"
}

Write-Host "[3/4] 子集化"
pyftsubset $srcOtf `
    --output-file=$outOtf `
    "--unicodes=$unicodes" `
    "--layout-features=kern,locl,palt,halt,vert,vrt2" `
    --no-hinting `
    --drop-tables+=DSIG `
    --name-IDs="*" --name-languages="*" --name-legacy
if ($LASTEXITCODE -ne 0) {
    throw "子集化失败"
}

Write-Host "[4/4] 落许可证（OFL 要求与字体一同分发）"
Invoke-WebRequest -Uri "$RawBase/LICENSE.txt" -OutFile (Join-Path $outDir "OFL.txt") -UseBasicParsing

$size = [math]::Round((Get-Item $outOtf).Length / 1MB, 2)
Write-Host "完成：resources\fonts\serif\SourceHanSerifCN-Subset.otf ($size MB)"
Write-Host "记得让 resources\fonts.qrc 里登记的文件名与产物一致，然后重新构建。"
