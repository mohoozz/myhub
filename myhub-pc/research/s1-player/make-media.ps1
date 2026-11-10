# 生成 S1 预研所需的测试素材
#
# 注意：此处的 ffmpeg.exe 仅用于**生成本地测试文件**，不随产品分发，
#       因此其 GPL 构建不影响 MyHub 的许可状态。
$ErrorActionPreference = 'Continue'

$ff  = "$env:TEMP\ffmpeg-bin\ffmpeg.exe"
$out = "$env:TEMP\myhub-s1-media"

if (-not (Test-Path $ff)) { Write-Error "ffmpeg not found: $ff"; exit 1 }
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Invoke-FF($label, [string[]]$ffArgs) {
    Write-Host "=== $label ==="
    $log = & $ff @ffArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAILED ($LASTEXITCODE)"
        $log | Select-Object -Last 8 | ForEach-Object { Write-Host "    $_" }
    } else {
        Write-Host "  ok"
    }
}

# ---- 1) 主素材：1080p HEVC mkv，30s，带音轨 ----
# testsrc2 自带运动、色彩变化与**内置帧计数器**，既能肉眼确认"有画面"而非黑屏，
# 也能验证 seek 是否跳到正确位置。
# 不用 drawtext —— 该滤镜依赖 fontconfig，便携版 ffmpeg 无默认字体配置会失败。
Invoke-FF '1080p HEVC mkv (main)' @(
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=1920x1080:rate=30:duration=30',
    '-f', 'lavfi', '-i', 'sine=frequency=440:duration=30',
    '-c:v', 'libx265', '-preset', 'ultrafast', '-crf', '28', '-pix_fmt', 'yuv420p',
    '-x265-params', 'log-level=none',
    '-c:a', 'aac', '-b:a', '128k',
    "$out\hevc_1080p.mkv"
)

# ---- 2) 多音轨 + 多字幕轨 mkv（验证轨道切换）----
Invoke-FF 'multi-track mkv' @(
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=25:duration=15',
    '-f', 'lavfi', '-i', 'sine=frequency=440:duration=15',
    '-f', 'lavfi', '-i', 'sine=frequency=880:duration=15',
    '-map', '0:v', '-map', '1:a', '-map', '2:a',
    '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '30', '-pix_fmt', 'yuv420p',
    '-c:a', 'aac',
    '-metadata:s:a:0', 'language=jpn', '-metadata:s:a:0', 'title=Japanese',
    '-metadata:s:a:1', 'language=chi', '-metadata:s:a:1', 'title=Chinese',
    "$out\multitrack.mkv"
)

# ---- 3) 其他容器（avi / ts / mp4）----
Invoke-FF 'avi container' @(
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=640x480:rate=25:duration=8',
    '-c:v', 'mpeg4', '-q:v', '5', "$out\sample.avi"
)
Invoke-FF 'ts container' @(
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=25:duration=8',
    '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '30', '-pix_fmt', 'yuv420p',
    '-f', 'mpegts', "$out\sample.ts"
)
Invoke-FF 'mp4 h264' @(
    '-y', '-hide_banner', '-loglevel', 'error',
    '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=30:duration=10',
    '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '30', '-pix_fmt', 'yuv420p',
    "$out\sample.mp4"
)

# ---- 4) 外挂 SRT 字幕 ----
#
# ⚠️ 编码陷阱：PowerShell 5.1 读取**无 BOM 的 UTF-8 脚本**时按 ANSI(GBK) 解析，
#    脚本里的中文字面量在载入阶段就已损坏，再怎么 -Encoding utf8 写出都是乱码。
#    故此处用显式 UTF-8 字节构造，绕开脚本自身的编码问题。
#    同时**不写 BOM** —— 播放器与多数字幕工具对无 BOM UTF-8 支持最一致。
$srtBytes = [byte[]]@(
    # "1\r\n00:00:01,000 --> 00:00:04,000\r\n"
    0x31,0x0D,0x0A,
    0x30,0x30,0x3A,0x30,0x30,0x3A,0x30,0x31,0x2C,0x30,0x30,0x30,0x20,
    0x2D,0x2D,0x3E,0x20,
    0x30,0x30,0x3A,0x30,0x30,0x3A,0x30,0x34,0x2C,0x30,0x30,0x30,0x0D,0x0A,
    # "MyHub S1 字幕测试"
    0x4D,0x79,0x48,0x75,0x62,0x20,0x53,0x31,0x20,
    0xE5,0xAD,0x97,0xE5,0xB9,0x95,0xE6,0xB5,0x8B,0xE8,0xAF,0x95,
    0x0D,0x0A,0x0D,0x0A,
    # "2\r\n00:00:05,000 --> 00:00:09,000\r\nSubtitle line two (ASCII)\r\n"
    0x32,0x0D,0x0A,
    0x30,0x30,0x3A,0x30,0x30,0x3A,0x30,0x35,0x2C,0x30,0x30,0x30,0x20,
    0x2D,0x2D,0x3E,0x20,
    0x30,0x30,0x3A,0x30,0x30,0x3A,0x30,0x39,0x2C,0x30,0x30,0x30,0x0D,0x0A,
    0x53,0x75,0x62,0x74,0x69,0x74,0x6C,0x65,0x20,0x6C,0x69,0x6E,0x65,0x20,
    0x74,0x77,0x6F,0x20,0x28,0x41,0x53,0x43,0x49,0x49,0x29,
    0x0D,0x0A
)
[System.IO.File]::WriteAllBytes("$out\hevc_1080p.srt", $srtBytes)

Write-Host ''
Write-Host '=== generated ==='
Get-ChildItem $out | ForEach-Object {
    Write-Host ("  {0,-22} {1,8:N1} KB" -f $_.Name, ($_.Length / 1KB))
}
Write-Host ''
Write-Host "media dir: $out"
