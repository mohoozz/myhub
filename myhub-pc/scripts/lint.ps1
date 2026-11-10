# myhub-pc 代码规范校验（clang-format / clang-tidy / qmllint）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\lint.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\lint.ps1 -Fix      # 自动格式化
#   powershell -ExecutionPolicy Bypass -File scripts\lint.ps1 -SkipTidy # 跳慢的 clang-tidy
#
# 退出码：0 全部通过；1 有失败项。
#
# 说明：三件套各管一段，互不重叠——
#   clang-format 管「排版」（.clang-format）
#   clang-tidy   管「语义/性能」（.clang-tidy，需 build 目录下的 compile_commands.json）
#   qmllint      管「QML 静态检查」（.qmllint.ini）
param(
    [switch]$Fix,
    [switch]$SkipTidy,
    [string]$Preset   = 'windows-debug',
    [string]$QtRoot   = 'C:/Qt/6.8.3/msvc2022_64',
    [string]$BuildDir = '',
    # LLVM 工具目录（clang-format / clang-tidy）；CI 上一般设在别处
    [string]$LlvmBin  = 'C:\BuildTools\VC\Tools\Llvm\x64\bin'
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $BuildDir) { $BuildDir = Join-Path $root ('build\' + $Preset) }

$clangFormat = Join-Path $LlvmBin 'clang-format.exe'
$clangTidy   = Join-Path $LlvmBin 'clang-tidy.exe'
$qmllint     = Join-Path ($QtRoot -replace '/', '\') 'bin\qmllint.exe'

# 工具缺失时不要静默跳过：静默跳过等于「永远绿」
foreach ($tool in @($clangFormat, $clangTidy, $qmllint)) {
    if (-not (Test-Path $tool)) {
        Write-Host "缺少工具: $tool" -ForegroundColor Red
        exit 1
    }
}

$failures = New-Object System.Collections.Generic.List[string]

# ---------- 1. clang-format ----------
Write-Host '=== clang-format ==='
$cppFiles = Get-ChildItem (Join-Path $root 'src'), (Join-Path $root 'tests') -Recurse -Include *.h, *.cpp
$dirty = @()
foreach ($f in $cppFiles) {
    if ($Fix) {
        & $clangFormat -i $f.FullName
    } else {
        & $clangFormat --dry-run -Werror $f.FullName 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $dirty += $f.FullName }
    }
}
if ($Fix) {
    Write-Host ("  formatted {0} files" -f $cppFiles.Count)
} elseif ($dirty.Count -eq 0) {
    Write-Host ("  OK  {0} files clean" -f $cppFiles.Count)
} else {
    Write-Host ("  FAIL {0} / {1} files need formatting (run with -Fix)" -f $dirty.Count, $cppFiles.Count) -ForegroundColor Red
    $dirty | ForEach-Object { Write-Host ('    ' + $_.Replace($root + '\', '')) }
    $failures.Add("clang-format: $($dirty.Count) files")
}

# ---------- 2. clang-tidy ----------
if ($SkipTidy) {
    Write-Host '=== clang-tidy (skipped) ==='
} else {
    Write-Host '=== clang-tidy ==='
    $cc = Join-Path $BuildDir 'compile_commands.json'
    if (-not (Test-Path $cc)) {
        Write-Host "  FAIL 缺少 $cc，请先构建（scripts\build.ps1 -Preset $Preset）" -ForegroundColor Red
        $failures.Add('clang-tidy: no compile_commands.json')
    } else {
        $tidyFiles = Get-ChildItem (Join-Path $root 'src'), (Join-Path $root 'tests') -Recurse -Filter *.cpp
        $diags = @()
        foreach ($f in $tidyFiles) {
            $out = & $clangTidy -p $BuildDir $f.FullName 2>&1 | Out-String
            # 只保留指回项目源码的告警，Qt/系统头的噪声已被 .clang-tidy 的 SystemHeaders:false 滤掉
            $diags += ($out -split "`r?`n" | Where-Object { $_ -match '[\\/](src|tests)[\\/].*:\d+:\d+: (warning|error):' })
        }
        if ($diags.Count -eq 0) {
            Write-Host ("  OK  {0} translation units, 0 findings" -f $tidyFiles.Count)
        } else {
            Write-Host ("  FAIL {0} findings in {1} translation units" -f $diags.Count, $tidyFiles.Count) -ForegroundColor Red
            $diags | ForEach-Object { Write-Host ('    ' + ($_ -replace ('^.*?' + [regex]::Escape($root + '\')), '')) }
            $failures.Add("clang-tidy: $($diags.Count) findings")
        }
    }
}

# ---------- 3. qmllint ----------
Write-Host '=== qmllint ==='
$importRoot = Join-Path $BuildDir 'qml'
if (-not (Test-Path (Join-Path $importRoot 'MyHub\qmldir'))) {
    Write-Host "  FAIL 找不到 QML 模块 ($importRoot\MyHub)，请先构建" -ForegroundColor Red
    $failures.Add('qmllint: no qml module')
} else {
    $qmlFiles = Get-ChildItem (Join-Path $root 'qml') -Recurse -Filter *.qml
    $qdiags = @()
    # 用 --json 而不是解析人类可读输出：PowerShell 会按控制台宽度折断 stderr，
    # `[missing-property]` 会被切成 `[missing-` + `property]` 两行，按标签统计就会漏数
    # （首版就是这么漏掉 100+ 条的）。JSON 也不受语言/列宽影响。
    foreach ($f in $qmlFiles) {
        $json = & $qmllint --json - -I $importRoot $f.FullName 2>$null | Out-String
        try {
            $report = $json | ConvertFrom-Json
        } catch {
            $qdiags += "$($f.Name): qmllint 输出无法解析为 JSON"
            continue
        }
        foreach ($qf in $report.files) {
            foreach ($w in $qf.warnings) {
                $qdiags += ('{0}:{1}:{2}: {3} [{4}]' -f (Split-Path $qf.filename -Leaf), $w.line, $w.column, $w.message, $w.id)
            }
        }
    }
    if ($qdiags.Count -eq 0) {
        Write-Host ("  OK  {0} qml files clean" -f $qmlFiles.Count)
    } else {
        Write-Host ("  FAIL {0} findings in {1} qml files" -f $qdiags.Count, $qmlFiles.Count) -ForegroundColor Red
        $qdiags | ForEach-Object { Write-Host ('    ' + ($_.Trim() -replace '^qmllint\.exe : ', '')) }
        $failures.Add("qmllint: $($qdiags.Count) findings")
    }
}

# ---------- 汇总 ----------
Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'LINT PASSED' -ForegroundColor Green
    exit 0
}
Write-Host ('LINT FAILED: ' + ($failures -join '; ')) -ForegroundColor Red
exit 1
