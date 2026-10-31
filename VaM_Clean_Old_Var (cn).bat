@echo off
setlocal
rem VaM: keep only the highest version of each .var package in AddonPackages and permanently delete the rest.
rem Mode 1 = file names only (fast). Mode 2 = also reads meta.json inside every .var and keeps old versions that other packages depend on by exact version.
rem Put this file in the VaM root folder (next to AddonPackages) and double-click it.
rem Everything below the #PS_BEGIN line is PowerShell code, loaded by the line that starts powershell.exe.
chcp 65001 >nul
set "VAMCLEAN_SELF=%~f0"
set "VAMCLEAN_DIR=%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command "$l=[IO.File]::ReadAllLines($env:VAMCLEAN_SELF,[Text.Encoding]::UTF8); $i=[Array]::IndexOf($l,'#PS_BEGIN'); & ([ScriptBlock]::Create(($l[($i+1)..($l.Length-1)] -join [Environment]::NewLine)))"
echo.
pause
exit /b
#PS_BEGIN
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

function Say([string]$text, [string]$color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Fmt-Size([double]$bytes) {
    if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    return ('{0:N0} KB' -f ($bytes / 1KB))
}
function Short-Name([string]$path) { return [System.IO.Path]::GetFileNameWithoutExtension($path) }

# meta.json 里「精确版本」的依赖写法,形如  "作者.包名.12": {   (.latest 和 .minN 的写法不会匹配)
$metaPattern = '"([^"\\]+\.[^"\\]+)\.(\d+)"\s*:\s*\{'

# 读取一批 var 的 meta.json:只读 zip 末尾的目录和 meta.json 这一个条目,不解压其它内容。
# 只返回命中 $wanted 集合的依赖键(小写包名|补零版本号)。
$readMeta = {
    param([string[]]$paths, [System.Collections.Generic.HashSet[string]]$wanted, [string]$pattern)
    $rx = New-Object System.Text.RegularExpressions.Regex($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($p in $paths) {
        $hits = New-Object System.Collections.Generic.HashSet[string]
        $status = 'ok'
        $fs = $null
        $zip = $null
        try {
            $fs = New-Object System.IO.FileStream($p, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Read)
            $entry = $zip.GetEntry('meta.json')
            if ($null -eq $entry) {
                $status = 'nometa'
            }
            else {
                $sr = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
                try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }
                foreach ($m in $rx.Matches($text)) {
                    $k = $m.Groups[1].Value.ToLowerInvariant() + '|' + $m.Groups[2].Value.TrimStart('0').PadLeft(40, '0')
                    if ($wanted.Contains($k)) { [void]$hits.Add($k) }
                }
            }
        }
        catch { $status = 'error' }
        finally {
            if ($null -ne $zip) { $zip.Dispose() }
            if ($null -ne $fs) { $fs.Dispose() }
        }
        $out.Add([pscustomobject]@{ Path = $p; Status = $status; Hits = @($hits) })
    }
    $out
}

# 多线程读取;并行环节出任何问题就整批改用单线程重读。
function Read-MetaBatch([string[]]$paths, $wanted) {
    $chunkSize = 100
    $total = $paths.Count
    $results = New-Object System.Collections.Generic.List[object]
    $chunks = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $total; $i += $chunkSize) {
        $n = [Math]::Min($chunkSize, $total - $i)
        $chunks.Add([string[]]($paths[$i..($i + $n - 1)]))
    }
    $threads = [Math]::Min(8, [Environment]::ProcessorCount)
    $done = $false
    if ($threads -ge 2 -and $chunks.Count -ge 2) {
        $pool = $null
        try {
            $pool = [runspacefactory]::CreateRunspacePool(1, $threads)
            $pool.Open()
            $jobs = New-Object System.Collections.Generic.List[object]
            foreach ($c in $chunks) {
                $ps = [powershell]::Create()
                $ps.RunspacePool = $pool
                [void]$ps.AddScript($readMeta.ToString()).AddArgument($c).AddArgument($wanted).AddArgument($metaPattern)
                $jobs.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Count = $c.Length })
            }
            while ($true) {
                $doneJobs = 0
                $doneFiles = 0
                foreach ($j in $jobs) { if ($j.Handle.IsCompleted) { $doneJobs++; $doneFiles += $j.Count } }
                Write-Host -NoNewline ("`r  已读取 {0} / {1}  " -f $doneFiles, $total)
                if ($doneJobs -ge $jobs.Count) { break }
                Start-Sleep -Milliseconds 150
            }
            Write-Host ''
            foreach ($j in $jobs) {
                foreach ($r in $j.PS.EndInvoke($j.Handle)) { $results.Add($r) }
                $j.PS.Dispose()
            }
            if ($results.Count -ne $total) { throw 'incomplete results' }
            $done = $true
        }
        catch {
            Write-Host ''
            Say '并行读取出了问题,改用单线程重新读取(会慢一些)。' 'DarkYellow'
            $results.Clear()
        }
        finally {
            if ($null -ne $pool) { try { $pool.Close(); $pool.Dispose() } catch {} }
        }
    }
    if (-not $done) {
        $doneFiles = 0
        foreach ($c in $chunks) {
            foreach ($r in (& $readMeta $c $wanted $metaPattern)) { $results.Add($r) }
            $doneFiles += $c.Length
            Write-Host -NoNewline ("`r  已读取 {0} / {1}  " -f $doneFiles, $total)
        }
        Write-Host ''
    }
    return $results.ToArray()
}

# ---------- 1. 定位 AddonPackages ----------
$addon = Join-Path $env:VAMCLEAN_DIR 'AddonPackages'
if (-not (Test-Path -LiteralPath $addon -PathType Container)) {
    Say '找不到 AddonPackages 文件夹。' 'Red'
    Say '请把这个 bat 放在 VaM 根目录(和 AddonPackages 同级的位置)再运行。' 'Red'
    exit 1
}
$addonFull = (Get-Item -LiteralPath $addon).FullName.TrimEnd('\', '/')

if (@(Get-Process -Name 'VaM', 'VaMX' -ErrorAction SilentlyContinue).Count -gt 0) {
    Say '检测到 VaM 正在运行。请先关闭 VaM 再运行本脚本,否则正在使用的 var 删不掉。' 'Red'
    exit 1
}

# ---------- 2. 扫描所有子文件夹里的 .var ----------
Say "正在扫描: $addonFull" 'Cyan'
$files = New-Object System.Collections.Generic.List[object]
$skippedLinks = New-Object System.Collections.Generic.List[string]
$stack = New-Object System.Collections.Generic.Stack[string]
$stack.Push($addonFull)
while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    foreach ($e in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
        if ($e.PSIsContainer) {
            # 不进入符号链接/联接文件夹,避免误删链接指向的仓库里的真实文件
            if ($e.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { $skippedLinks.Add($e.FullName) }
            else { $stack.Push($e.FullName) }
        }
        elseif ($e.Extension -ieq '.var') {
            $files.Add($e)
        }
    }
}
Say ("共找到 {0} 个 .var 文件。" -f $files.Count)
if ($files.Count -eq 0) { exit 0 }

# ---------- 3. 按 作者.包名.版本号.var 解析 ----------
$rx = '^(?<base>.+\..+)\.(?<ver>\d+)\.var$'
$items = New-Object System.Collections.Generic.List[object]
$unparsed = New-Object System.Collections.Generic.List[string]
foreach ($f in $files) {
    $rel = $f.FullName.Substring($addonFull.Length).TrimStart('\', '/')
    if ($f.Name -match $rx) {
        $base = $Matches['base']
        $ver = $Matches['ver']
        $items.Add([pscustomobject]@{
            Key    = $base.ToLowerInvariant()
            Base   = $base
            Ver    = $ver
            VerKey = $ver.TrimStart('0').PadLeft(40, '0')   # 补零后按字符串比较 = 按数值比较
            File   = $f
            Depth  = ($rel -split '[\\/]').Count - 1
            Rel    = $rel
        })
    }
    else {
        $unparsed.Add($rel)
    }
}

# ---------- 4. 每个包保留最高版本,其余进删除计划 ----------
$plan = New-Object System.Collections.Generic.List[object]
foreach ($g in ($items | Group-Object Key)) {
    if ($g.Count -lt 2) { continue }
    $sorted = @($g.Group | Sort-Object `
        @{ Expression = 'VerKey'; Descending = $true }, `
        @{ Expression = { $_.File.Length }; Descending = $true }, `
        @{ Expression = 'Depth'; Descending = $false }, `
        @{ Expression = { $_.File.LastWriteTime }; Descending = $true }, `
        @{ Expression = 'Rel'; Descending = $false })
    $plan.Add([pscustomobject]@{
        Base   = $sorted[0].Base
        Keep   = $sorted[0]
        Delete = @($sorted | Select-Object -Skip 1)
    })
}

if ($unparsed.Count -gt 0) {
    Say ("有 {0} 个文件名不符合「作者.包名.版本号.var」格式(例如带 (1) 的副本),已跳过不动。" -f $unparsed.Count) 'DarkYellow'
}
if ($skippedLinks.Count -gt 0) {
    Say ("有 {0} 个文件夹是符号链接/联接,未进入扫描。" -f $skippedLinks.Count) 'DarkYellow'
}
if ($plan.Count -eq 0) {
    Say '没有发现同一个包的多个版本,不需要清理。' 'Green'
    exit 0
}

# ---------- 5. 选择模式 ----------
$candCount = 0
foreach ($p in $plan) { $candCount += $p.Delete.Count }
Write-Host ''
Say '请选择模式:'
Say '  1 = 简单档:只按文件名判断,最快(直接回车默认选这个)'
Say ("  2 = 安全档:再读取其余 {0} 个 var 里的 meta.json,把被其它包按精确版本号依赖的旧版本也留下" -f ($files.Count - $candCount))
$mode = 1
if ("$(Read-Host '输入 1 或 2 后回车')".Trim() -eq '2') { $mode = 2 }

$pinnedInfo = New-Object System.Collections.Generic.List[object]
$unreadable = 0

if ($mode -eq 2) {
    try {
        Add-Type -AssemblyName System.IO.Compression
        # 候选:每个「版本号不同于保留版本」的待删旧版本;同版本的多份副本里取排序最靠前的一份作代表
        $wanted = New-Object System.Collections.Generic.HashSet[string]
        $candBest = @{}
        $deleteSet = New-Object System.Collections.Generic.HashSet[string]
        foreach ($p in $plan) {
            foreach ($x in $p.Delete) {
                [void]$deleteSet.Add($x.File.FullName.ToLowerInvariant())
                if ($x.VerKey -ne $p.Keep.VerKey) {
                    $ck = $x.Key + '|' + $x.VerKey
                    if (-not $candBest.ContainsKey($ck)) { $candBest[$ck] = $x; [void]$wanted.Add($ck) }
                }
            }
        }
        # 先读所有「不会被删」的 var,看它们精确依赖了哪些候选旧版本
        $toRead = New-Object System.Collections.Generic.List[string]
        foreach ($f in $files) {
            if (-not $deleteSet.Contains($f.FullName.ToLowerInvariant())) { $toRead.Add($f.FullName) }
        }
        Say ("正在读取 {0} 个 var 的 meta.json(多线程)..." -f $toRead.Count) 'Cyan'
        $swMeta = [System.Diagnostics.Stopwatch]::StartNew()
        $refBy = @{}
        $pinnedKeys = New-Object System.Collections.Generic.HashSet[string]
        while ($toRead.Count -gt 0) {
            $batch = $toRead.ToArray()
            foreach ($r in @(Read-MetaBatch $batch $wanted)) {
                if ($r.Status -ne 'ok') { $unreadable++; continue }
                foreach ($hk in $r.Hits) {
                    if (-not $refBy.ContainsKey($hk)) { $refBy[$hk] = New-Object System.Collections.Generic.List[string] }
                    if ($refBy[$hk].Count -lt 3) { $refBy[$hk].Add((Short-Name $r.Path)) }
                }
            }
            # 被依赖的旧版本也会留下来,它自己的依赖同样要检查,直到没有新增为止
            $toRead = New-Object System.Collections.Generic.List[string]
            foreach ($rk in @($refBy.Keys)) {
                if ($candBest.ContainsKey($rk) -and $pinnedKeys.Add($rk)) { $toRead.Add($candBest[$rk].File.FullName) }
            }
        }
        Say ("读取完成,用时 {0:N1} 秒。" -f $swMeta.Elapsed.TotalSeconds) 'Cyan'

        $pinFiles = New-Object System.Collections.Generic.HashSet[string]
        foreach ($pk in $pinnedKeys) {
            $x = $candBest[$pk]
            [void]$pinFiles.Add($x.File.FullName.ToLowerInvariant())
            $pinnedInfo.Add([pscustomobject]@{
                Base = $x.Base
                Ver  = $x.Ver
                Rel  = $x.Rel
                By   = (($refBy[$pk] | Select-Object -Unique) -join '、')
            })
        }
        foreach ($p in $plan) {
            $p.Delete = @($p.Delete | Where-Object { -not $pinFiles.Contains($_.File.FullName.ToLowerInvariant()) })
        }
        $plan = @($plan | Where-Object { $_.Delete.Count -gt 0 })
    }
    catch {
        Say ("安全档出错,为避免误删已经停止,没有删除任何文件: {0}" -f $_.Exception.Message) 'Red'
        exit 1
    }

    if ($pinnedInfo.Count -gt 0) {
        Write-Host ''
        Say ("有 {0} 个旧版本被其它包按精确版本号依赖,已自动保留:" -f $pinnedInfo.Count) 'Cyan'
        foreach ($q in @($pinnedInfo | Sort-Object Base | Select-Object -First 30)) {
            Say ("  {0}.{1}  <-  {2}" -f $q.Base, $q.Ver, $q.By)
        }
        if ($pinnedInfo.Count -gt 30) { Say '  ……其余见日志' }
    }
    if ($unreadable -gt 0) {
        Say ("有 {0} 个 var 读不出 meta.json(文件损坏或格式不标准),它们的依赖没法检查。" -f $unreadable) 'DarkYellow'
    }
    if ($plan.Count -eq 0) {
        Say '所有旧版本都被其它包按精确版本号依赖,没有可以安全删除的。' 'Green'
        exit 0
    }
}

# ---------- 6. 预览 ----------
$delCount = 0
$delBytes = 0.0
Write-Host ''
foreach ($p in ($plan | Sort-Object Base)) {
    $parts = foreach ($x in $p.Delete) {
        if ($x.VerKey -eq $p.Keep.VerKey) { ('.{0}(同版本副本)' -f $x.Ver) } else { ('.{0}' -f $x.Ver) }
    }
    Say ("{0}  保留 .{1}  删除 {2}" -f $p.Base, $p.Keep.Ver, ($parts -join ' '))
    foreach ($x in $p.Delete) { $delCount++; $delBytes += $x.File.Length }
}
Write-Host ''
Say ("共 {0} 个包有多余版本,将永久删除 {1} 个文件,释放约 {2}。" -f $plan.Count, $delCount, (Fmt-Size $delBytes)) 'Yellow'
Say '删除后无法恢复(不会进回收站)。' 'Yellow'
$answer = "$(Read-Host '确认删除请输入 Y 后回车;输入其它内容或直接关闭窗口则取消,不会改动任何文件')".Trim()
if ($answer -ne 'Y') {
    Say '已取消,没有删除任何文件。' 'Green'
    exit 0
}

# ---------- 7. 执行删除并写日志 ----------
$log = New-Object System.Collections.Generic.List[string]
$log.Add('VaM var cleanup log  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$log.Add('AddonPackages: ' + $addonFull)
$log.Add('Mode: ' + $(if ($mode -eq 2) { 'safe (meta.json checked)' } else { 'simple (file names only)' }))
$log.Add('')
$ok = 0; $fail = 0; $freed = 0.0
foreach ($p in ($plan | Sort-Object Base)) {
    $log.Add(('[{0}] KEEP .{1}  {2}' -f $p.Base, $p.Keep.Ver, $p.Keep.Rel))
    foreach ($x in $p.Delete) {
        try {
            Remove-Item -LiteralPath $x.File.FullName -Force -ErrorAction Stop
            $ok++; $freed += $x.File.Length
            $log.Add(('    DELETED .{0}  {1}' -f $x.Ver, $x.Rel))
        }
        catch {
            $fail++
            $log.Add(('    FAILED  .{0}  {1}  ({2})' -f $x.Ver, $x.Rel, $_.Exception.Message))
        }
    }
}
if ($pinnedInfo.Count -gt 0) {
    $log.Add(''); $log.Add('--- Old versions kept because another package depends on that exact version ---')
    foreach ($q in $pinnedInfo) { $log.Add(('{0}.{1}  <-  {2}   ({3})' -f $q.Base, $q.Ver, $q.By, $q.Rel)) }
}
if ($unreadable -gt 0) {
    $log.Add(''); $log.Add(('--- {0} .var files had no readable meta.json (their dependencies were not checked) ---' -f $unreadable))
}
if ($unparsed.Count -gt 0) {
    $log.Add(''); $log.Add('--- Skipped (name does not match Creator.Package.Version.var) ---')
    foreach ($u in $unparsed) { $log.Add($u) }
}
if ($skippedLinks.Count -gt 0) {
    $log.Add(''); $log.Add('--- Skipped linked folders ---')
    foreach ($u in $skippedLinks) { $log.Add($u) }
}
$logPath = Join-Path $env:VAMCLEAN_DIR ('VaM_Clean_Var_Log_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
try { $log | Out-File -LiteralPath $logPath -Encoding UTF8 } catch { $logPath = $null }

Write-Host ''
Say ("完成:已删除 {0} 个文件,释放约 {1}。" -f $ok, (Fmt-Size $freed)) 'Green'
if ($fail -gt 0) {
    Say ("有 {0} 个文件删除失败(可能被占用或没有权限),可关闭 VaM 后重试,或右键以管理员身份运行。" -f $fail) 'Red'
}
if ($logPath) { Say ("详细记录: $logPath") }
exit 0
