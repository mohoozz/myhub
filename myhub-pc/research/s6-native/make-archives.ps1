# 生成 S6 漫画解页测试素材
#
# 页名刻意使用混乱顺序（1,2,10,11 + 中文卷名），用于同时验证自然排序。
$ErrorActionPreference = 'Continue'

$ff  = "$env:TEMP\ffmpeg-bin\ffmpeg.exe"
$out = "$env:TEMP\myhub-s6-archives"
$pages = Join-Path $out 'pages'
$sevenZip = 'C:\Program Files\7-Zip\7z.exe'

New-Item -ItemType Directory -Force -Path $pages | Out-Null

# ---- 生成漫画页（不同色块，便于确认解出的是对应页）----
$pageNames = @('page1.jpg','page2.jpg','page10.jpg','page11.jpg','page20.jpg')
$hues = @('red','green','blue','yellow','magenta')

for ($i = 0; $i -lt $pageNames.Count; $i++) {
    $dst = Join-Path $pages $pageNames[$i]
    if (Test-Path $dst) { continue }
    & $ff -y -hide_banner -loglevel error `
        -f lavfi -i "color=c=$($hues[$i]):size=800x1200:duration=1" `
        -frames:v 1 $dst 2>&1 | Out-Null
}

Write-Host '=== pages ==='
Get-ChildItem $pages | ForEach-Object {
    Write-Host ("  {0,-14} {1,7:N1} KB" -f $_.Name, ($_.Length/1KB))
}

# ---- 打包 CBZ（zip）----
$cbz = Join-Path $out 'volume01.cbz'
Remove-Item $cbz -Force -ErrorAction SilentlyContinue
& $sevenZip a -tzip $cbz "$pages\*" 2>&1 | Select-Object -Last 1

# ---- 打包 7z（验证 libarchive 的 7z 读取）----
$sevenZ = Join-Path $out 'volume02.7z'
Remove-Item $sevenZ -Force -ErrorAction SilentlyContinue
& $sevenZip a -t7z $sevenZ "$pages\*" 2>&1 | Select-Object -Last 1

Write-Host ''
Write-Host '=== archives ==='
Get-ChildItem $out -File | ForEach-Object {
    Write-Host ("  {0,-16} {1,8:N1} KB" -f $_.Name, ($_.Length/1KB))
}
Write-Host ''
Write-Host "archive dir: $out"
Write-Host 'note: CBR (rar) must be fetched separately - 7-Zip cannot create rar.'
