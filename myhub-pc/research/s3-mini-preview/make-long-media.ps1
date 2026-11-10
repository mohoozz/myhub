# 为 S3 生成足够长的测试素材。
#
# 为什么需要单独的长素材：
#   S1 的 hevc_1080p.mkv 只有 30 秒。S3 要做「多轮等长稳态对照」，总时长会超过
#   30 秒，开 loop 后视频回绕——而 mpv 在回绕时会**重置 frame-drop-count**，
#   导致丢帧统计出现负数、分项和大于总数等异常，把测量结论彻底污染。
#   改用 180 秒素材，全程不回绕。

$ErrorActionPreference = 'Stop'

$ff  = "$env:TEMP\ffmpeg-bin\ffmpeg.exe"
$out = "$env:TEMP\myhub-s3-media"
$dst = Join-Path $out 'long_1080p.mkv'

if (-not (Test-Path $ff)) {
    Write-Error "ffmpeg not found at $ff - run ..\s1-player\make-media.ps1 first"
    exit 1
}

New-Item -ItemType Directory -Force -Path $out | Out-Null

if (Test-Path $dst) {
    Write-Host "already exists: $dst"
} else {
    Write-Host 'encoding 180s 1080p HEVC (ultrafast) ...'
    & $ff -y -hide_banner -loglevel error `
        -f lavfi -i 'testsrc2=size=1920x1080:rate=30:duration=180' `
        -f lavfi -i 'sine=frequency=440:duration=180' `
        -c:v libx265 -preset ultrafast -crf 30 -pix_fmt yuv420p `
        -c:a aac -b:a 96k `
        -shortest $dst
    if ($LASTEXITCODE -ne 0) { Write-Error 'ffmpeg failed'; exit 1 }
}

$item = Get-Item $dst
Write-Host ("  {0,-18} {1,9:N1} MB" -f $item.Name, ($item.Length/1MB))
Write-Host "media dir: $out"
