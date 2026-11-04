param($Shared)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Core | Out-Null

$counters   = @{}
$lastTick   = [DateTime]::UtcNow
$lastSave   = [DateTime]::UtcNow
$lastMeta   = [DateTime]::MinValue
$lastStatus = [DateTime]::MinValue
$lastPrune  = [DateTime]::MinValue
$lastNoSrc  = [DateTime]::MinValue
$health     = @{}
$tickCount  = 0

function Add-ControllerLog {
    param([string]$Message)
    try {
        $line = (Get-Date).ToString('HH:mm:ss') + '  ' + $Message
        $Shared.Log.Enqueue($line)
        $discard = $null
        while ($Shared.Log.Count -gt 240) {
            if (-not $Shared.Log.TryDequeue([ref]$discard)) { break }
        }
    } catch { }
}

function Format-AdapterName {
    param([string]$Name)
    if (-not $Name) { return '' }
    $x = $Name -replace '\[R\]', '' -replace '_', ' '
    $x = $x -replace '\s+', ' '
    return $x.Trim()
}

function Initialize-Counters {
    $names = @()
    try {
        $cat = New-Object System.Diagnostics.PerformanceCounterCategory('Network Interface')
        $names = @($cat.GetInstanceNames())
    } catch {
        return
    }
    foreach ($name in $names) {
        if ($counters.ContainsKey($name)) { continue }
        try {
            $rx = New-Object System.Diagnostics.PerformanceCounter('Network Interface', 'Bytes Received/sec', $name, $true)
            $tx = New-Object System.Diagnostics.PerformanceCounter('Network Interface', 'Bytes Sent/sec', $name, $true)
            $null = $rx.NextSample()
            $null = $tx.NextSample()
            $counters[$name] = @{
                rx = $rx
                tx = $tx
                lastRx = [int64]0
                lastTx = [int64]0
                rxRate = 0.0
                txRate = 0.0
                init = $true
            }
        } catch { }
    }
    foreach ($k in @($counters.Keys)) {
        if ($names -notcontains $k) {
            try { $counters[$k].rx.Dispose() } catch { }
            try { $counters[$k].tx.Dispose() } catch { }
            $counters.Remove($k)
        }
    }
}

function Add-Task {
    param($Cfg)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $enabled = @()
    foreach ($s in @($Cfg.sources)) {
        if (-not $s.enabled) { continue }
        $h = $null
        if ($health.ContainsKey([string]$s.id)) { $h = $health[[string]$s.id] }
        if ($h -and $h.badUntil -gt $now) { continue }
        $enabled += $s
    }
    if ($enabled.Count -eq 0) {
        # 全部数据源都在冷却中时，强制重试冷却最早结束的一个，避免下载完全停摆
        $pick = $null
        $pickUntil = [int64]::MaxValue
        foreach ($s in @($Cfg.sources)) {
            if (-not $s.enabled) { continue }
            $until = [int64]0
            $h = $health[[string]$s.id]
            if ($h) { $until = [int64]$h.badUntil }
            if ($until -lt $pickUntil) { $pickUntil = $until; $pick = $s }
        }
        if ($pick) {
            $enabled = @($pick)
            if (([DateTime]::UtcNow - $script:lastNoSrc).TotalSeconds -gt 60) {
                Add-ControllerLog '数据源都在冷却中，先强制重试冷却最早的一个'
                $script:lastNoSrc = [DateTime]::UtcNow
            }
        } else {
            if (([DateTime]::UtcNow - $script:lastNoSrc).TotalSeconds -gt 30) {
                Add-ControllerLog '没有可用的数据源，请检查数据源设置'
                $script:lastNoSrc = [DateTime]::UtcNow
            }
            return $false
        }
    }
    $src = Get-Random -InputObject $enabled
    $base = [double]$Cfg.chunkMB * 1MB
    $size = [int64]($base * (0.9 + (Get-Random -Minimum 0.0 -Maximum 0.2)))
    if ($size -lt 8MB) { $size = 8MB }
    $url = [string]$src.url
    if ([bool]$src.template) { $url = $url.Replace('{bytes}', [string]$size) }

    $id = [guid]::NewGuid().ToString('N').Substring(0, 10)
    $file = Join-Path $Shared.DownDir ('rg_' + $id + '.bin')
    $task = [hashtable]::Synchronized(@{
        id            = $id
        sourceId      = [string]$src.id
        sourceName    = [string]$src.name
        url           = $url
        file          = $file
        state         = 'queued'
        bytes         = [int64]0
        target        = [int64]$size
        speed         = [int64]0
        error         = ''
        created       = $now
        started       = [int64]0
        finished      = [int64]0
        range         = [bool]$src.range
        healthApplied = $false
        fileDeleted   = $false
    })
    $Shared.Tasks[$id] = $task
    $Shared.Queue.Enqueue($task)
    return $true
}

function Remove-FileQuiet {
    param([string]$Path)
    try { if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue } } catch { }
}

# --------------------------------------------------------------- main loop

Initialize-Counters
Add-ControllerLog '流量统计已启动'

while (-not $Shared.Stop) {
    $loopStart = [DateTime]::UtcNow
    try {
        $tickCount++
        if (($loopStart - $lastMeta).TotalSeconds -gt 60) {
            Initialize-Counters
            $lastMeta = $loopStart
        }

        $now = [DateTime]::UtcNow
        $dt = ($now - $lastTick).TotalSeconds
        if ($dt -lt 0.25) { $dt = 0.25 }
        if ($dt -gt 30) { $dt = 30 }
        $lastTick = $now

        # ---- sample adapters -------------------------------------------
        $rows = @()
        foreach ($name in @($counters.Keys)) {
            $c = $counters[$name]
            $rxv = [int64]0
            $txv = [int64]0
            try { $rxv = [int64]$c.rx.NextSample().RawValue } catch { continue }
            try { $txv = [int64]$c.tx.NextSample().RawValue } catch { continue }

            $drx = [int64]0
            $dtx = [int64]0
            if ($c.init) {
                $c.lastRx = $rxv
                $c.lastTx = $txv
                $c.init = $false
            } else {
                $drx = $rxv - $c.lastRx
                $dtx = $txv - $c.lastTx
                if ($drx -lt 0) { $drx = [int64]0 }
                if ($dtx -lt 0) { $dtx = [int64]0 }
                $c.lastRx = $rxv
                $c.lastTx = $txv
            }
            $irx = [double]$drx / $dt
            $itx = [double]$dtx / $dt
            $c.rxRate = $c.rxRate * 0.55 + $irx * 0.45
            $c.txRate = $c.txRate * 0.55 + $itx * 0.45

            $rows += @{
                name    = $name
                label   = Format-AdapterName $name
                rxRate  = [double]$c.rxRate
                txRate  = [double]$c.txRate
                rxTotal = $rxv
                txTotal = $txv
                rxDelta = $drx
                txDelta = $dtx
            }
        }

        # ---- pick adapter ----------------------------------------------
        $cfg = $Shared.Config
        $sel = [string]$cfg.adapter
        if (-not $sel) { $sel = 'auto' }
        $resolved = [string]$Shared.ResolvedAdapter
        if ($sel -ne 'auto' -and $sel -ne 'all') {
            $resolved = $sel
        } elseif ($sel -eq 'auto') {
            $exists = $false
            foreach ($r in $rows) { if ($r.name -eq $resolved) { $exists = $true } }
            if (-not $exists) {
                $bestName = ''
                $bestVal = -1.0
                foreach ($r in $rows) {
                    $v = [double]$r.rxTotal + [double]$r.txTotal
                    if ($v -gt $bestVal) { $bestVal = $v; $bestName = $r.name }
                }
                $resolved = $bestName
                $Shared.ResolvedAdapter = $bestName
            }
        }

        $rxRate = 0.0
        $txRate = 0.0
        $rxDelta = [int64]0
        $txDelta = [int64]0
        if ($sel -eq 'all') {
            foreach ($r in $rows) {
                $rxRate += $r.rxRate
                $txRate += $r.txRate
                $rxDelta += $r.rxDelta
                $txDelta += $r.txDelta
            }
        } else {
            foreach ($r in $rows) {
                if ($r.name -eq $resolved) {
                    $rxRate = $r.rxRate
                    $txRate = $r.txRate
                    $rxDelta = $r.rxDelta
                    $txDelta = $r.txDelta
                }
            }
        }

        # ---- accumulate stats ------------------------------------------
        $totalUp = [int64]0
        $totalDown = [int64]0
        $ratio = 0.0
        $todayUp = [int64]0
        $todayDown = [int64]0
        [System.Threading.Monitor]::Enter($Shared.Lock)
        try {
            $st = $Shared.Stats
            $monthNow = (Get-Date).ToString('yyyy-MM')
            if ($st.month -ne $monthNow) {
                $st.history = @($st.history) + @(@{ month = $st.month; up = $st.up; down = $st.down })
                if (@($st.history).Count -gt 24) { $st.history = @($st.history | Select-Object -Last 24) }
                $st.month = $monthNow
                $st.up = [int64]0
                $st.down = [int64]0
                $st.baselineUp = [int64]0
                $st.baselineDown = [int64]0
                $st.days = @{}
                Add-ControllerLog ('进入新的月份 ' + $monthNow + '，统计已重置')
            }
            $st.up = [int64]$st.up + $txDelta
            $st.down = [int64]$st.down + $rxDelta
            $dayKey = (Get-Date).ToString('yyyy-MM-dd')
            if (-not $st.days.ContainsKey($dayKey)) { $st.days[$dayKey] = @{ up = [int64]0; down = [int64]0 } }
            $st.days[$dayKey].up = [int64]$st.days[$dayKey].up + $txDelta
            $st.days[$dayKey].down = [int64]$st.days[$dayKey].down + $rxDelta
            $totalUp = [int64]$st.baselineUp + [int64]$st.up
            $totalDown = [int64]$st.baselineDown + [int64]$st.down
            $todayUp = [int64]$st.days[$dayKey].up
            $todayDown = [int64]$st.days[$dayKey].down
            $st.updated = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        } finally { [System.Threading.Monitor]::Exit($Shared.Lock) }

        if ($totalUp -gt 0) { $ratio = [Math]::Round([double]$totalDown / [double]$totalUp, 3) }

        # ---- engine stats ----------------------------------------------
        $appRate = 0.0
        $runningCount = 0
        foreach ($t in $Shared.Tasks.Values) {
            if ($t.state -eq 'running') {
                $runningCount++
                $appRate += [double]$t.speed
            }
        }
        $otherDown = [Math]::Max(0.0, $rxRate - $appRate)

        # ---- autopilot --------------------------------------------------
        $desired = 0.0
        $active = $false
        if (-not $Shared.Paused) {
            $maxRate = 0.0
            if ([double]$cfg.maxRateMBs -gt 0) { $maxRate = [double]$cfg.maxRateMBs * 1MB }
            switch ([string]$cfg.mode) {
                'full' {
                    $desired = $maxRate
                    $active = $true
                }
                'manual' {
                    $desired = [double]$cfg.manualRateMBs * 1MB
                    $active = ($desired -ge 65536)
                }
                default {
                    $deficit = [double]$cfg.targetRatio * [double]$totalUp - [double]$totalDown
                    $steady = $txRate * [double]$cfg.targetRatio * 1.15
                    $need = [Math]::Max(0.0, $steady - $otherDown)
                    $catch = 0.0
                    if ($deficit -gt 0) { $catch = $deficit / ([double]$cfg.catchUpWindowMin * 60.0) }
                    $desired = $need + $catch
                    $thresh = [double]$cfg.uploadThresholdKBps * 1024.0
                    if ([bool]$cfg.onlyWhenUploading -and $totalUp -gt 0 -and $txRate -lt $thresh -and $deficit -lt (100MB)) {
                        $desired = 0.0
                    }
                    $minRate = [double]$cfg.minRateMBs * 1MB
                    if ($desired -gt 0 -and $desired -lt $minRate) { $desired = $minRate }
                    if ($maxRate -gt 0 -and $desired -gt $maxRate) { $desired = $maxRate }
                    if ($desired -lt 65536) { $desired = 0.0 }
                    $active = ($desired -gt 0)
                }
            }
        }
        $Shared.Rate = [int64]$desired
        $Shared.DesiredRate = [int64]$desired
        $Shared.Active = $active

        # ---- queue ------------------------------------------------------
        @($Shared.Tasks.Values) | ForEach-Object { }
        $pending = $Shared.Queue.Count
        if ($active -and -not $Shared.Paused) {
            $concurrency = [int][Math]::Max(1, [Math]::Min(8, [int]$cfg.concurrency))
            $needCount = $concurrency - $runningCount - $pending
            $adds = 0
            while ($needCount -gt 0 -and $adds -lt 2) {
                if (-not (Add-Task -Cfg $cfg)) { break }
                $needCount--
                $adds++
            }
        }

        # ---- source health ----------------------------------------------
        foreach ($t in @($Shared.Tasks.Values)) {
            if ($t.healthApplied) { continue }
            if ($t.state -eq 'done') {
                $health[[string]$t.sourceId] = @{ fails = 0; badUntil = [int64]0 }
                $t.healthApplied = $true
            } elseif ($t.state -eq 'failed') {
                $h = $health[[string]$t.sourceId]
                if (-not $h) { $h = @{ fails = 0; badUntil = [int64]0 } }
                $h.fails = [int]$h.fails + 1
                $delay = 60.0 * [Math]::Pow(2, [Math]::Min(5, $h.fails - 1))
                if ($delay -gt 1800) { $delay = 1800 }
                $h.badUntil = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + [int64]($delay * 1000)
                if ($h.fails -ge 2 -or $delay -ge 180) {
                    Add-ControllerLog ('数据源冷却 ' + [Math]::Round($delay / 60.0, 0) + ' 分钟：' + $t.sourceName + '（' + [string]$t.error + '）')
                }
                $health[[string]$t.sourceId] = $h
                $t.healthApplied = $true
            }
        }
        $healthCopy = @{}
        foreach ($k in $health.Keys) { $healthCopy[$k] = @{ fails = $health[$k].fails; badUntil = $health[$k].badUntil } }
        $Shared.SourceHealth = $healthCopy

        # ---- files ------------------------------------------------------
        $keepFiles = [bool]$cfg.keepFiles
        foreach ($t in @($Shared.Tasks.Values)) {
            if ($t.state -eq 'done' -and -not $t.fileDeleted -and -not $keepFiles) {
                Remove-FileQuiet ([string]$t.file)
                $t.fileDeleted = $true
            }
        }
        if (($now - $lastPrune).TotalSeconds -gt 8) {
            $lastPrune = $now
            if ($keepFiles) {
                $cap = [double]$cfg.diskCapMB * 1MB
                $files = @(Get-ChildItem -LiteralPath $Shared.DownDir -Filter '*.bin' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
                $totalSize = 0.0
                foreach ($f in $files) { $totalSize += [double]$f.Length }
                $inUse = @{}
                foreach ($t in @($Shared.Tasks.Values)) {
                    if ($t.state -eq 'running' -or $t.state -eq 'queued') { $inUse[[string]$t.file] = $true }
                }
                foreach ($f in $files) {
                    if ($totalSize -le $cap) { break }
                    if ($inUse.ContainsKey($f.FullName)) { continue }
                    $len = [double]$f.Length
                    Remove-FileQuiet $f.FullName
                    $totalSize -= $len
                }
            } else {
                foreach ($t in @($Shared.Tasks.Values)) {
                    if ($t.state -eq 'failed' -and -not $t.fileDeleted) {
                        Remove-FileQuiet ([string]$t.file)
                        $t.fileDeleted = $true
                    }
                }
            }

            # task dictionary cleanup
            if ($Shared.Tasks.Count -gt 120) {
                $done = @($Shared.Tasks.Values | Where-Object { $_.state -eq 'done' -or $_.state -eq 'failed' } | Sort-Object created)
                $removeCount = $Shared.Tasks.Count - 100
                for ($i = 0; $i -lt $done.Count -and $i -lt $removeCount; $i++) {
                    $key = [string]$done[$i].id
                    $removed = $null
                    [void]$Shared.Tasks.TryRemove($key, [ref]$removed)
                }
            }
        }

        # ---- snapshots ---------------------------------------------------
        $Shared.NetSnapshot = @{
            source   = 'perfcounter'
            selected = $sel
            resolved = $resolved
            rxRate   = [double]$rxRate
            txRate   = [double]$txRate
            adapters = @($rows | ForEach-Object {
                @{ name = $_.name; label = $_.label; rxRate = $_.rxRate; txRate = $_.txRate; rxTotal = $_.rxTotal; txTotal = $_.txTotal }
            })
        }
        $Shared.StatsSnapshot = @{
            month        = $Shared.Stats.month
            up           = [int64]$Shared.Stats.up
            down         = [int64]$Shared.Stats.down
            baselineUp   = [int64]$Shared.Stats.baselineUp
            baselineDown = [int64]$Shared.Stats.baselineDown
            totalUp      = [int64]$totalUp
            totalDown    = [int64]$totalDown
            ratio        = [double]$ratio
            todayUp      = [int64]$todayUp
            todayDown    = [int64]$todayDown
            appDownloaded = [int64]$Shared.AppDownloaded
            updated      = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        }

        # ---- persist ------------------------------------------------------
        if (($now - $lastSave).TotalSeconds -gt 10) {
            $lastSave = $now
            try { Write-JsonFile $Shared.StatsPath $Shared.Stats } catch { }
        }

        # ---- status log ---------------------------------------------------
        if (($now - $lastStatus).TotalSeconds -gt 60) {
            $lastStatus = $now
            $modeName = '智能'
            if ($cfg.mode -eq 'full') { $modeName = '全速' }
            if ($cfg.mode -eq 'manual') { $modeName = '手动' }
            $stateName = '待机'
            if ($Shared.Paused) { $stateName = '已暂停' }
            elseif ($active) { $stateName = '下载中' }
            Add-ControllerLog ('[' + $modeName + '/' + $stateName + '] 比例 ' + $ratio + 'x / 目标 ' + $cfg.targetRatio + 'x · 上行 ' + [Math]::Round($txRate / 1MB, 2) + ' MB/s · 下行 ' + [Math]::Round($rxRate / 1MB, 2) + ' MB/s · 限速 ' + [Math]::Round($desired / 1MB, 2) + ' MB/s')
        }
    } catch {
        Add-ControllerLog ('控制线程异常: ' + $_.Exception.Message)
    }

    $elapsed = ([DateTime]::UtcNow - $loopStart).TotalMilliseconds
    $sleep = 1000 - $elapsed
    if ($sleep -lt 30) { $sleep = 30 }
    Start-Sleep -Milliseconds ([int]$sleep)
}

foreach ($k in @($counters.Keys)) {
    try { $counters[$k].rx.Dispose() } catch { }
    try { $counters[$k].tx.Dispose() } catch { }
}
