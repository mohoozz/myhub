# myhub-pc 代码规范校验（clang-format / clang-tidy / qmllint）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\lint.ps1              # 只查改动文件（日常）
#   powershell -ExecutionPolicy Bypass -File scripts\lint.ps1 -All         # 全量（提交前 / CI）
#   powershell -ExecutionPolicy Bypass -File scripts\lint.ps1 -Fix         # 就地格式化（同样只改改动文件）
#   powershell -ExecutionPolicy Bypass -File scripts\lint.ps1 -SkipTidy    # 跳过最慢的 clang-tidy
#   powershell -ExecutionPolicy Bypass -File scripts\lint.ps1 -All -Jobs 4 # 指定 clang-tidy 并行度
#
# 退出码：0 全部通过；1 有失败项。
#
# 说明：三件套各管一段，互不重叠——
#   clang-format 管「排版」（.clang-format）
#   clang-tidy   管「语义/性能」（.clang-tidy，需 build 目录下的 compile_commands.json）
#   qmllint      管「QML 静态检查」（.qmllint.ini）
#
# 为什么默认只查改动文件：
#   全量 200 个 C++ 文件 + 110 多个 TU 的 clang-tidy 要几分钟，而这一轮根本没碰其中绝大多数。
#   日常只查 `git diff HEAD` + 未跟踪文件，几秒出结果；提交前与 CI 再跑 -All。
#   **CI 必须显式 -All**：runner 上是干净 checkout，改动集为空，默认模式会直接全绿。
#
# 为什么是批量 + 并行而不是逐文件起进程：
#   逐文件调用等于每个文件一次 CreateProcess（Windows 上还要过一遍杀软），
#   198 次 clang-format 就要半分钟，而 clang-format / qmllint 都支持一次传多个文件。
#   clang-tidy 没有 -j，于是自己开进程池：一个 TU 一个进程，滑窗补位（-Jobs 控制上限）。
param(
    [switch]$Fix,
    [switch]$SkipTidy,
    # 全量检查：忽略 git 改动列表
    [switch]$All,
    # clang-tidy 并行进程数；0 = 自动（CPU 核数，上限 16）
    [int]$Jobs     = 0,
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

# ---------------------------------------------------------------- 工具函数

# 把 $Items 切成最多 $BatchCount 份（用于「一批文件一个进程」）
function Split-Batches {
    param([object[]]$Items, [int]$BatchCount)
    $batches = New-Object System.Collections.ArrayList
    if ($Items.Count -eq 0 -or $BatchCount -lt 1) { return $batches }
    $size = [Math]::Ceiling($Items.Count / $BatchCount)
    for ($i = 0; $i -lt $Items.Count; $i += $size) {
        $end = [Math]::Min($i + $size, $Items.Count) - 1
        $slice = New-Object System.Collections.ArrayList
        for ($j = $i; $j -le $end; ++$j) { [void]$slice.Add($Items[$j]) }
        [void]$batches.Add($slice.ToArray())
    }
    return $batches
}

# 跑外部程序并把 stdout/stderr 留在临时文件里（PowerShell 的 2>&1 会把输出揉成
# 带「所在位置」的 NativeCommandError，解析 clang-format / qmllint 的输出时不划算）
function Invoke-Capture {
    param([string]$Exe, [string[]]$Arguments)
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $proc = Start-Process -FilePath $Exe -ArgumentList $Arguments -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $stdout = Get-Content -Path $outFile -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content -Path $errFile -Raw -ErrorAction SilentlyContinue
    Remove-Item $outFile, $errFile -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = "$stdout"
        StdErr   = "$stderr"
    }
}

# Start-Process 的 -ArgumentList 只做空格拼接，路径含空格时必须自己加引号
function Quote-Args {
    param([string[]]$Paths)
    return @($Paths | ForEach-Object { '"' + $_ + '"' })
}

# 改动 = 相对 HEAD 的增删改（含已暂存）+ 未跟踪文件。
# 返回 HashSet，路径为绝对路径；不在 git 仓库里返回 $null（调用方退回全量）。
function Get-ChangedFileSet {
    param([string]$Root)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $null }
    $repo = @(& git -C $Root rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or $repo.Count -eq 0) { return $null }
    $repoRoot = ($repo | Select-Object -First 1).Trim() -replace '/', '\'

    $relative = New-Object System.Collections.ArrayList
    foreach ($p in @(& git -C $repoRoot diff --name-only --diff-filter=ACMR HEAD 2>$null)) {
        [void]$relative.Add($p)
    }
    foreach ($p in @(& git -C $repoRoot ls-files --others --exclude-standard 2>$null)) {
        [void]$relative.Add($p)
    }

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $relative) {
        if (-not $p -or -not $p.Trim()) { continue }
        [void]$set.Add((Join-Path $repoRoot ($p.Trim() -replace '/', '\')))
    }
    return $set
}

# 全量 or 改动集过滤
function Select-Scope {
    param([object[]]$Files, $Changed, [bool]$Full)
    if ($Full -or $null -eq $Changed) { return @($Files) }
    return @($Files | Where-Object { $Changed.Contains($_.FullName) })
}

# 报告里的范围后缀：按「本段真正检查了多少」说，而不是 git 改动总数
function Format-Scope {
    param([int]$Count, $Changed, [bool]$Full)
    if ($Full -or $null -eq $Changed) { return "全量 $Count" }
    return "改动 $Count"
}

# ---------------------------------------------------------------- 检查范围

$changed = $null
if (-not $All) {
    $changed = Get-ChangedFileSet -Root $root
    if ($null -eq $changed) {
        Write-Host '不在 git 仓库（或 git 不可用）：退回全量检查' -ForegroundColor Yellow
    }
}
$scope = if ($All -or $null -eq $changed) { '全量' } else { "改动 $($changed.Count) 个文件" }
Write-Host ("检查范围：{0}" -f $scope)

# ---------------------------------------------------------------- 1. clang-format

Write-Host '=== clang-format ==='
$cppAll = @(Get-ChildItem (Join-Path $root 'src'), (Join-Path $root 'tests') -Recurse -Include *.h, *.cpp -File)
$cppFiles = @(Select-Scope -Files $cppAll -Changed $changed -Full ([bool]$All))

if ($cppFiles.Count -eq 0) {
    Write-Host '  无改动的 C++ 文件，跳过（-All 查全量）'
} elseif ($Fix) {
    $done = 0
    foreach ($batch in @(Split-Batches -Items $cppFiles -BatchCount ([Math]::Ceiling($cppFiles.Count / 60)))) {
        & $clangFormat -i @($batch | ForEach-Object { $_.FullName })
        if ($LASTEXITCODE -ne 0) { $failures.Add('clang-format: 格式化失败') }
        $done += $batch.Count
        Write-Host ("  {0}/{1}" -f $done, $cppFiles.Count)
    }
    Write-Host ("  formatted {0} files ({1})" -f $cppFiles.Count, (Format-Scope $cppFiles.Count $changed ([bool]$All)))
} else {
    # --dry-run -Werror 一次可传多个文件；有文件不合规时退出码非 0，
    # 且 stderr 每行自带文件名（`<file>:<line>:<col>: error: code should be clang-formatted`）
    # clang-format 会为同一个文件输出多条 error（每条替换各一行），必须按文件去重
    $dirty = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($batch in @(Split-Batches -Items $cppFiles -BatchCount ([Math]::Ceiling($cppFiles.Count / 60)))) {
        $paths = @($batch | ForEach-Object { $_.FullName })
        $r = Invoke-Capture -Exe $clangFormat -Arguments (@('--dry-run', '-Werror') + (Quote-Args $paths))
        if ($r.ExitCode -eq 0) { continue }
        $found = $false
        foreach ($line in ($r.StdErr -split "`r?`n")) {
            if ($line -match '^(.*?):\d+:\d+: error: code should be clang-formatted') {
                [void]$dirty.Add($matches[1].Trim())
                $found = $true
            }
        }
        if (-not $found) { $failures.Add('clang-format: 执行出错（见上方输出）') }
    }
    if ($dirty.Count -eq 0) {
        Write-Host ("  OK  {0} files clean ({1})" -f $cppFiles.Count, (Format-Scope $cppFiles.Count $changed ([bool]$All)))
    } else {
        Write-Host ("  FAIL {0} / {1} files need formatting (run with -Fix)" -f $dirty.Count, $cppFiles.Count) -ForegroundColor Red
        $dirty | Sort-Object | ForEach-Object { Write-Host ('    ' + ($_ -replace ('^' + [regex]::Escape($root + '\')), '')) }
        $failures.Add("clang-format: $($dirty.Count) files")
    }
}

# ---------------------------------------------------------------- 2. clang-tidy

if ($SkipTidy) {
    Write-Host '=== clang-tidy (skipped) ==='
} else {
    Write-Host '=== clang-tidy ==='
    $cc = Join-Path $BuildDir 'compile_commands.json'
    if (-not (Test-Path $cc)) {
        Write-Host "  FAIL 缺少 $cc，请先构建（scripts\build.ps1 -Preset $Preset）" -ForegroundColor Red
        $failures.Add('clang-tidy: no compile_commands.json')
    } else {
        $tidyAll = @(Get-ChildItem (Join-Path $root 'src'), (Join-Path $root 'tests') -Recurse -Filter *.cpp -File)
        $tidyFiles = @(Select-Scope -Files $tidyAll -Changed $changed -Full ([bool]$All))

        # clang-tidy 对不在 compile_commands.json 里的文件会静默退出 0（一条输出都没有），
        # 于是「新加的文件还没构建」就会变成假绿。这里自己比对一遍，缺失的单独列出来。
        $unbuildable = @()
        if ($tidyFiles.Count -gt 0) {
            $known = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            # 注意：PS 5.1 的 ConvertFrom-Json 把顶层数组当成「一个对象」输出，
            # 外面再套 @() 会得到「1 个元素（整个数组）」，$entry.file 就成了拼接字符串
            $db = Get-Content -Path $cc -Raw | ConvertFrom-Json
            foreach ($entry in $db) {
                $f = [string]$entry.file
                if (-not [System.IO.Path]::IsPathRooted($f)) { $f = Join-Path ([string]$entry.directory) $f }
                [void]$known.Add((([System.IO.Path]::GetFullPath($f)) -replace '/', '\'))
            }
            $unbuildable = @($tidyFiles | Where-Object { -not $known.Contains($_.FullName) })
            $tidyFiles = @($tidyFiles | Where-Object { $known.Contains($_.FullName) })
        }

        if ($unbuildable.Count -gt 0) {
            $unbuildable | ForEach-Object {
                Write-Host ('    不在编译数据库（未构建，跳过分析）: ' + ($_.FullName -replace ('^' + [regex]::Escape($root + '\')), ''))
            }
            # 全量模式下列表里可能有平台/条件编译才编的文件，提示即可；
            # 改动集里出现就是真问题：这个文件根本没被检查过
            if ($null -ne $changed -and -not $All) {
                $failures.Add("clang-tidy: $($unbuildable.Count) 个改动文件不在编译数据库里，请先构建")
            }
        }

        if ($tidyFiles.Count -eq 0) {
            Write-Host '  无需要检查的 TU（没有改动，或改动文件都不在编译数据库里）'
        } else {
            # 实测（24 核 / Windows）：16 进程处理 16 个 TU 约 23s，串行约 92s；
            # 再往上加进程收益递减（每个 clang-tidy 都要展开整套 Qt 头，内存与磁盘先饱和）。
            # 机器小就按核数走，机器大也封顶 16，别把内存吃光。
            $parallel = $Jobs
            if ($parallel -le 0) { $parallel = [Math]::Min([Environment]::ProcessorCount, 16) }
            $parallel = [Math]::Max(1, [Math]::Min($parallel, $tidyFiles.Count))
            Write-Host ("  {0} 个 TU，最多 {1} 个进程并行（{2}）" -f $tidyFiles.Count, $parallel, (Format-Scope $tidyFiles.Count $changed ([bool]$All)))

            $diags = New-Object System.Collections.Generic.List[string]

            # 一个进程只负责一个 TU：进程内串行处理多个 TU 会让 AST 累积（内存翻倍），
            # 而且一个慢 TU 会拖住整批。滑动窗口让慢的留在跑、完成一个立刻补位。
            $queue = New-Object System.Collections.Queue
            foreach ($f in $tidyFiles) { $queue.Enqueue($f) }

            $running = New-Object System.Collections.ArrayList
            $done = 0

            while ($queue.Count -gt 0 -or $running.Count -gt 0) {
                while ($running.Count -lt $parallel -and $queue.Count -gt 0) {
                    $file = $queue.Dequeue()
                    $outFile = [System.IO.Path]::GetTempFileName()
                    $errFile = [System.IO.Path]::GetTempFileName()
                    $proc = Start-Process -FilePath $clangTidy `
                        -ArgumentList (@('-p', $BuildDir, ('"' + $file.FullName + '"'))) `
                        -NoNewWindow -PassThru `
                        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
                    [void]$running.Add([pscustomobject]@{
                        Process = $proc
                        Out     = $outFile
                        Err     = $errFile
                    })
                }

                # 轮询而不是"等第一个"：等待顺序与完成顺序无关，才能真正并行
                $finishedAt = -1
                for ($i = 0; $i -lt $running.Count; ++$i) {
                    if ($running[$i].Process.HasExited) { $finishedAt = $i; break }
                }
                if ($finishedAt -lt 0) {
                    Start-Sleep -Milliseconds 120
                    continue
                }

                $job = $running[$finishedAt]
                $job.Process.WaitForExit()

                # 只保留指回项目源码的告警：Qt/系统头的噪声已被 .clang-tidy 的 SystemHeaders:false 滤掉，
                # 但 clang 前端对 Qt 头的 diagnostic-error 仍会出现，同样不归项目代码管
                $hits = Select-String -Path $job.Out, $job.Err `
                    -Pattern '[\\/](src|tests)[\\/].*:\d+:\d+: (warning|error):' -ErrorAction SilentlyContinue
                foreach ($hit in $hits) { [void]$diags.Add($hit.Line) }

                Remove-Item $job.Out, $job.Err -ErrorAction SilentlyContinue
                [void]$running.RemoveAt($finishedAt)
                ++$done
                if ($done % 10 -eq 0 -or $done -eq $tidyFiles.Count) {
                    Write-Host ("  {0}/{1} 个 TU 完成" -f $done, $tidyFiles.Count)
                }
            }

            # 同一处告警可能在 stdout/stderr 各出现一次：按整行去重后再计数
            $diags = @($diags | Select-Object -Unique)

            if ($diags.Count -eq 0) {
                Write-Host ("  OK  {0} translation units, 0 findings ({1})" -f $tidyFiles.Count, (Format-Scope $tidyFiles.Count $changed ([bool]$All)))
            } else {
                Write-Host ("  FAIL {0} findings in {1} translation units" -f $diags.Count, $tidyFiles.Count) -ForegroundColor Red
                $diags | ForEach-Object { Write-Host ('    ' + ($_ -replace ('^.*?' + [regex]::Escape($root + '\')), '')) }
                $failures.Add("clang-tidy: $($diags.Count) findings")
            }
        }
    }
}

# ---------------------------------------------------------------- 3. qmllint

Write-Host '=== qmllint ==='
$importRoot = Join-Path $BuildDir 'qml'
if (-not (Test-Path (Join-Path $importRoot 'MyHub\qmldir'))) {
    Write-Host "  FAIL 找不到 QML 模块 ($importRoot\MyHub)，请先构建" -ForegroundColor Red
    $failures.Add('qmllint: no qml module')
} else {
    $qmlAll = @(Get-ChildItem (Join-Path $root 'qml') -Recurse -Filter *.qml -File)
    $qmlFiles = @(Select-Scope -Files $qmlAll -Changed $changed -Full ([bool]$All))

    if ($qmlFiles.Count -eq 0) {
        Write-Host '  无改动的 QML 文件，跳过（-All 查全量）'
    } else {
        # qmllint 一次可吃多个文件，--json <file> 把全部报告写进一个 JSON。
        # 用 JSON 而不是解析人类可读输出：PowerShell 会按控制台宽度折断 stderr，
        # `[missing-property]` 会被切成 `[missing-` + `property]` 两行，按标签统计就会漏数
        # （首版就是这么漏掉 100+ 条的）。JSON 也不受语言/列宽影响。
        $qdiags = New-Object System.Collections.Generic.List[string]
        $jsonFile = [System.IO.Path]::GetTempFileName()
        $r = Invoke-Capture -Exe $qmllint `
            -Arguments (@('--json', $jsonFile, '-I', $importRoot) + (Quote-Args @($qmlFiles | ForEach-Object { $_.FullName })))
        try {
            $report = Get-Content -Path $jsonFile -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($qf in $report.files) {
                foreach ($w in $qf.warnings) {
                    [void]$qdiags.Add(('{0}:{1}:{2}: {3} [{4}]' -f (Split-Path $qf.filename -Leaf), $w.line, $w.column, $w.message, $w.id))
                }
            }
        } catch {
            [void]$qdiags.Add("qmllint 输出无法解析为 JSON（exit=$($r.ExitCode)）")
        }
        Remove-Item $jsonFile -ErrorAction SilentlyContinue

        if ($qdiags.Count -eq 0) {
            Write-Host ("  OK  {0} qml files clean ({1})" -f $qmlFiles.Count, (Format-Scope $qmlFiles.Count $changed ([bool]$All)))
        } else {
            Write-Host ("  FAIL {0} findings in {1} qml files" -f $qdiags.Count, $qmlFiles.Count) -ForegroundColor Red
            $qdiags | ForEach-Object { Write-Host ('    ' + $_.Trim()) }
            $failures.Add("qmllint: $($qdiags.Count) findings")
        }
    }
}

# ---------------------------------------------------------------- 汇总

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'LINT PASSED' -ForegroundColor Green
    exit 0
}
Write-Host ('LINT FAILED: ' + ($failures -join '; ')) -ForegroundColor Red
exit 1
