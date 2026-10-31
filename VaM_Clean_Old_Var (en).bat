@echo off
setlocal
rem VaM Clean Old Var - keep only the highest version of each .var package in AddonPackages and permanently delete the rest.
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

# Exact-version dependencies in meta.json look like  "Creator.Package.12": {
# (the .latest and .minN spellings do not match on purpose)
$metaPattern = '"([^"\\]+\.[^"\\]+)\.(\d+)"\s*:\s*\{'

# Reads meta.json from a batch of .var files. Only the zip directory at the end of the file and the
# meta.json entry are read; nothing else is extracted. Returns only the dependency keys found in $wanted
# (lower-case package name | zero-padded version).
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

# Multi-threaded reading. If anything goes wrong in the parallel part, the whole batch is re-read single-threaded.
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
                Write-Host -NoNewline ("`r  Read {0} / {1}  " -f $doneFiles, $total)
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
            Say 'Parallel reading failed. Falling back to single-threaded reading (slower).' 'DarkYellow'
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
            Write-Host -NoNewline ("`r  Read {0} / {1}  " -f $doneFiles, $total)
        }
        Write-Host ''
    }
    return $results.ToArray()
}

# ---------- 1. Locate AddonPackages ----------
$addon = Join-Path $env:VAMCLEAN_DIR 'AddonPackages'
if (-not (Test-Path -LiteralPath $addon -PathType Container)) {
    Say 'Cannot find the AddonPackages folder.' 'Red'
    Say 'Put this .bat in your VaM root folder (the one that contains AddonPackages) and run it again.' 'Red'
    exit 1
}
$addonFull = (Get-Item -LiteralPath $addon).FullName.TrimEnd('\', '/')

if (@(Get-Process -Name 'VaM', 'VaMX' -ErrorAction SilentlyContinue).Count -gt 0) {
    Say 'VaM appears to be running. Close VaM first, otherwise packages that are in use cannot be deleted.' 'Red'
    exit 1
}

# ---------- 2. Scan every .var in all subfolders ----------
Say "Scanning: $addonFull" 'Cyan'
$files = New-Object System.Collections.Generic.List[object]
$skippedLinks = New-Object System.Collections.Generic.List[string]
$stack = New-Object System.Collections.Generic.Stack[string]
$stack.Push($addonFull)
while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    foreach ($e in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
        if ($e.PSIsContainer) {
            # Do not enter symlinked/junction folders, so real files in a linked repository are never deleted
            if ($e.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) { $skippedLinks.Add($e.FullName) }
            else { $stack.Push($e.FullName) }
        }
        elseif ($e.Extension -ieq '.var') {
            $files.Add($e)
        }
    }
}
Say ("Found {0} .var files." -f $files.Count)
if ($files.Count -eq 0) { exit 0 }

# ---------- 3. Parse Creator.Package.Version.var ----------
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
            VerKey = $ver.TrimStart('0').PadLeft(40, '0')   # zero-padded, so string comparison = numeric comparison
            File   = $f
            Depth  = ($rel -split '[\\/]').Count - 1
            Rel    = $rel
        })
    }
    else {
        $unparsed.Add($rel)
    }
}

# ---------- 4. Keep the highest version of each package; everything else goes into the delete plan ----------
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
    Say ("{0} files do not follow the Creator.Package.Version.var naming (for example copies ending in (1)). They were left untouched." -f $unparsed.Count) 'DarkYellow'
}
if ($skippedLinks.Count -gt 0) {
    Say ("{0} linked folders (symlinks/junctions) were not entered." -f $skippedLinks.Count) 'DarkYellow'
}
if ($plan.Count -eq 0) {
    Say 'No package has more than one version. Nothing to clean up.' 'Green'
    exit 0
}

# ---------- 5. Choose a mode ----------
$candCount = 0
foreach ($p in $plan) { $candCount += $p.Delete.Count }
Write-Host ''
Say 'Select a mode:'
Say '  1 = Simple: decide by file name only. Fastest. (Just press Enter to pick this one)'
Say ("  2 = Safe: also read meta.json in the other {0} packages and keep old versions that another package depends on by exact version number" -f ($files.Count - $candCount))
$mode = 1
if ("$(Read-Host 'Enter 1 or 2 and press Enter')".Trim() -eq '2') { $mode = 2 }

$pinnedInfo = New-Object System.Collections.Generic.List[object]
$unreadable = 0

if ($mode -eq 2) {
    try {
        Add-Type -AssemblyName System.IO.Compression
        # Candidates: every to-be-deleted old version whose version differs from the kept one.
        # If the same old version exists in several folders, the first one in sort order represents it.
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
        # First read every package that will NOT be deleted and see which candidate old versions they depend on
        $toRead = New-Object System.Collections.Generic.List[string]
        foreach ($f in $files) {
            if (-not $deleteSet.Contains($f.FullName.ToLowerInvariant())) { $toRead.Add($f.FullName) }
        }
        Say ("Reading meta.json from {0} packages (multi-threaded)..." -f $toRead.Count) 'Cyan'
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
            # A kept old version keeps its own dependencies alive too, so check those as well until nothing new turns up
            $toRead = New-Object System.Collections.Generic.List[string]
            foreach ($rk in @($refBy.Keys)) {
                if ($candBest.ContainsKey($rk) -and $pinnedKeys.Add($rk)) { $toRead.Add($candBest[$rk].File.FullName) }
            }
        }
        Say ("Done reading meta.json in {0:N1} s." -f $swMeta.Elapsed.TotalSeconds) 'Cyan'

        $pinFiles = New-Object System.Collections.Generic.HashSet[string]
        foreach ($pk in $pinnedKeys) {
            $x = $candBest[$pk]
            [void]$pinFiles.Add($x.File.FullName.ToLowerInvariant())
            $pinnedInfo.Add([pscustomobject]@{
                Base = $x.Base
                Ver  = $x.Ver
                Rel  = $x.Rel
                By   = (($refBy[$pk] | Select-Object -Unique) -join ', ')
            })
        }
        foreach ($p in $plan) {
            $p.Delete = @($p.Delete | Where-Object { -not $pinFiles.Contains($_.File.FullName.ToLowerInvariant()) })
        }
        $plan = @($plan | Where-Object { $_.Delete.Count -gt 0 })
    }
    catch {
        Say ("Safe mode failed, so nothing was deleted: {0}" -f $_.Exception.Message) 'Red'
        exit 1
    }

    if ($pinnedInfo.Count -gt 0) {
        Write-Host ''
        Say ("{0} old versions are depended on by exact version number by other packages and will be kept:" -f $pinnedInfo.Count) 'Cyan'
        foreach ($q in @($pinnedInfo | Sort-Object Base | Select-Object -First 30)) {
            Say ("  {0}.{1}  <-  {2}" -f $q.Base, $q.Ver, $q.By)
        }
        if ($pinnedInfo.Count -gt 30) { Say ("  ...and {0} more (all are listed in the log file after cleanup)" -f ($pinnedInfo.Count - 30)) }
    }
    if ($unreadable -gt 0) {
        Say ("{0} packages have no readable meta.json (damaged or non-standard), so their dependencies could not be checked." -f $unreadable) 'DarkYellow'
    }
    if ($plan.Count -eq 0) {
        Say 'Every old version is depended on by exact version number, so there is nothing safe to delete.' 'Green'
        exit 0
    }
}

# ---------- 6. Preview ----------
$delCount = 0
$delBytes = 0.0
Write-Host ''
foreach ($p in ($plan | Sort-Object Base)) {
    $parts = foreach ($x in $p.Delete) {
        if ($x.VerKey -eq $p.Keep.VerKey) { ('.{0}(same-version copy)' -f $x.Ver) } else { ('.{0}' -f $x.Ver) }
    }
    Say ("{0}  keep .{1}  delete {2}" -f $p.Base, $p.Keep.Ver, ($parts -join ' '))
    foreach ($x in $p.Delete) { $delCount++; $delBytes += $x.File.Length }
}
Write-Host ''
Say ("{0} packages have extra versions. {1} files (about {2}) will be PERMANENTLY deleted." -f $plan.Count, $delCount, (Fmt-Size $delBytes)) 'Yellow'
Say 'Deleted files cannot be recovered (they do not go to the Recycle Bin).' 'Yellow'
$answer = "$(Read-Host 'Type Y and press Enter to delete. Anything else (or closing this window) cancels without touching any file')".Trim()
if ($answer -ne 'Y') {
    Say 'Cancelled. No files were deleted.' 'Green'
    exit 0
}

# ---------- 7. Delete and write the log ----------
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
Say ("Done: deleted {0} files, freed about {1}." -f $ok, (Fmt-Size $freed)) 'Green'
if ($fail -gt 0) {
    Say ("{0} files could not be deleted (in use or no permission). Close VaM and retry, or run as administrator." -f $fail) 'Red'
}
if ($logPath) { Say ("Log: $logPath") }
exit 0
