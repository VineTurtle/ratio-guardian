param([int]$Port = 7788)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http | Out-Null

$script:Version        = '1.0.0'
$script:AppDir         = $PSScriptRoot
$script:RootDir        = Split-Path -Parent $script:AppDir
$script:DataDir        = Join-Path $script:RootDir 'data'
$script:PublicDir      = Join-Path $script:AppDir 'public'
$script:DownDir        = Join-Path $script:RootDir 'downloads'
$script:WorkerPath     = Join-Path $script:AppDir 'worker.ps1'
$script:ControllerPath = Join-Path $script:AppDir 'controller.ps1'
$script:Utf8           = New-Object System.Text.UTF8Encoding($false)

foreach ($d in @($script:DataDir, $script:DownDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# stale partial files from an unclean shutdown
try {
    Get-ChildItem -LiteralPath $script:DownDir -Filter '*.bin' -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
} catch { }

# ---------------------------------------------------------------- helpers

function ConvertTo-HashtableDeep {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-HashtableDeep $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $InputObject) { [void]$list.Add((ConvertTo-HashtableDeep $item)) }
        return ,$list.ToArray()
    }
    return $InputObject
}

function Write-JsonFile {
    param([string]$Path, $Object)
    $json = ConvertTo-Json -InputObject $Object -Depth 12
    [System.IO.File]::WriteAllText($Path, $json, $script:Utf8)
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if (-not $text.Trim()) { return $null }
        return ConvertTo-HashtableDeep (ConvertFrom-Json -InputObject $text)
    } catch { return $null }
}

function Add-LogLine {
    param([string]$Message)
    try {
        $line = (Get-Date).ToString('HH:mm:ss') + '  ' + $Message
        $script:Shared.Log.Enqueue($line)
        $discard = $null
        while ($script:Shared.Log.Count -gt 240) {
            if (-not $script:Shared.Log.TryDequeue([ref]$discard)) { break }
        }
    } catch { }
}

function Get-DefaultSources {
    $p = Join-Path $script:AppDir 'defaults\sources.json'
    if (Test-Path -LiteralPath $p) {
        try {
            $arr = ConvertTo-HashtableDeep (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)))
            if ($arr) { return @($arr) }
        } catch { }
    }
    return @()
}

function New-DefaultConfig {
    return @{
        mode               = 'auto'
        targetRatio        = 2.0
        maxRateMBs         = 20
        minRateMBs         = 0.3
        manualRateMBs      = 5
        concurrency        = 3
        chunkMB            = 256
        diskCapMB          = 2048
        keepFiles          = $false
        onlyWhenUploading  = $true
        uploadThresholdKBps = 50
        catchUpWindowMin   = 30
        adapter            = 'auto'
        autoStart          = $true
        heartbeat          = $true
        sources            = @(Get-DefaultSources)
    }
}

function Normalize-Config {
    param($InputConfig)
    $defaults = New-DefaultConfig
    $out = @{}
    foreach ($k in $defaults.Keys) { $out[$k] = $defaults[$k] }
    if ($InputConfig) {
        foreach ($k in $InputConfig.Keys) {
            if ($k -eq 'sources') { $out['sources'] = $InputConfig['sources'] }
            elseif ($defaults.ContainsKey($k)) { $out[$k] = $InputConfig[$k] }
        }
    }
    if (@('auto', 'full', 'manual') -notcontains [string]$out.mode) { $out.mode = 'auto' }
    $out.targetRatio         = [Math]::Round([Math]::Max(0.5, [Math]::Min(20.0, [double]$out.targetRatio)), 2)
    $out.maxRateMBs          = [Math]::Round([Math]::Max(0.0, [Math]::Min(500.0, [double]$out.maxRateMBs)), 1)
    $out.minRateMBs          = [Math]::Round([Math]::Max(0.0, [Math]::Min(50.0, [double]$out.minRateMBs)), 2)
    $out.manualRateMBs       = [Math]::Round([Math]::Max(0.0, [Math]::Min(500.0, [double]$out.manualRateMBs)), 1)
    $out.concurrency         = [int][Math]::Max(1, [Math]::Min(8, [int]$out.concurrency))
    $out.chunkMB             = [int][Math]::Max(16, [Math]::Min(4096, [int]$out.chunkMB))
    $out.diskCapMB           = [int][Math]::Max(128, [Math]::Min(1048576, [int]$out.diskCapMB))
    $out.uploadThresholdKBps = [int][Math]::Max(0, [Math]::Min(100000, [int]$out.uploadThresholdKBps))
    $out.catchUpWindowMin    = [int][Math]::Max(1, [Math]::Min(1440, [int]$out.catchUpWindowMin))
    $out.keepFiles           = [bool]$out.keepFiles
    $out.onlyWhenUploading   = [bool]$out.onlyWhenUploading
    $out.autoStart           = [bool]$out.autoStart
    $out.heartbeat           = [bool]$out.heartbeat
    $out.adapter             = [string]$out.adapter
    if (-not $out.adapter) { $out.adapter = 'auto' }

    $sources = @()
    foreach ($s in @($out.sources)) {
        if ($null -eq $s) { continue }
        $url = [string]$s.url
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        $id = [string]$s.id
        if ([string]::IsNullOrWhiteSpace($id)) { $id = [guid]::NewGuid().ToString('N').Substring(0, 8) }
        $name = [string]$s.name
        if ([string]::IsNullOrWhiteSpace($name)) {
            try { $name = ([Uri]$url).Host } catch { $name = '自定义数据源' }
        }
        $enabled = $true
        if ($null -ne $s.enabled) { $enabled = [bool]$s.enabled }
        $template = [bool]($s.template -eq $true)
        $range = -not $template
        if ($s -is [System.Collections.IDictionary]) {
            if ($s.Contains('range') -and $null -ne $s['range']) { $range = [bool]$s['range'] }
        }
        $sources += @{
            id       = $id
            name     = $name
            url      = $url
            template = $template
            range    = $range
            enabled  = $enabled
        }
    }
    $out.sources = $sources
    return $out
}

function New-DefaultStats {
    $month = (Get-Date).ToString('yyyy-MM')
    return @{
        month        = $month
        up           = [int64]0
        down         = [int64]0
        baselineUp   = [int64]0
        baselineDown = [int64]0
        days         = @{}
        history      = @()
        updated      = [int64]0
    }
}

function Normalize-Stats {
    param($InputStats)
    $s = New-DefaultStats
    if ($InputStats) {
        foreach ($k in @('month', 'up', 'down', 'baselineUp', 'baselineDown', 'days', 'history', 'updated')) {
            if ($InputStats.ContainsKey($k) -and $null -ne $InputStats[$k]) { $s[$k] = $InputStats[$k] }
        }
    }
    $s.up = [int64]$s.up
    $s.down = [int64]$s.down
    $s.baselineUp = [int64]$s.baselineUp
    $s.baselineDown = [int64]$s.baselineDown
    if (-not ($s.days -is [System.Collections.IDictionary])) { $s.days = @{} }
    if (-not $s.history) { $s.history = @() }
    $s.month = [string]$s.month
    if ($s.month -ne (Get-Date).ToString('yyyy-MM')) {
        $s.history = @($s.history) + @(@{ month = $s.month; up = $s.up; down = $s.down })
        if (@($s.history).Count -gt 24) { $s.history = @($s.history)[-24..-1] }
        $s.month = (Get-Date).ToString('yyyy-MM')
        $s.up = [int64]0
        $s.down = [int64]0
        $s.baselineUp = [int64]0
        $s.baselineDown = [int64]0
        $s.days = @{}
    }
    return $s
}

# ---------------------------------------------------------------- boot state

$configPath = Join-Path $script:DataDir 'config.json'
$statsPath  = Join-Path $script:DataDir 'stats.json'
$portPath   = Join-Path $script:DataDir 'port.txt'

$config = Normalize-Config (Read-JsonFile $configPath)
$stats  = Normalize-Stats (Read-JsonFile $statsPath)
if (-not (Test-Path -LiteralPath $configPath)) { Write-JsonFile $configPath $config }

$shared = [hashtable]::Synchronized(@{})
$shared.Stop          = $false
$shared.Paused        = (-not [bool]$config.autoStart)
$shared.Active        = $false
$shared.Rate          = [int64]0
$shared.DesiredRate   = [int64]0
$shared.Config        = $config
$shared.Stats         = $stats
$shared.Tasks         = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
$shared.Queue         = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
$shared.Log           = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$shared.Lock          = New-Object System.Object
$shared.Tokens        = [double]0
$shared.LastRefill    = [DateTime]::UtcNow
$shared.DataDir       = $script:DataDir
$shared.DownDir       = $script:DownDir
$shared.StatsPath     = $statsPath
$shared.StartedAt     = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$shared.LastPing      = $shared.StartedAt
$shared.ResolvedAdapter = ''
$shared.AppDownloaded = [int64]0
$shared.NetSnapshot   = @{
    source = 'none'; selected = 'auto'; resolved = ''; rxRate = 0.0; txRate = 0.0; adapters = @()
}
$shared.StatsSnapshot = @{
    month = $stats.month; up = [int64]0; down = [int64]0
    baselineUp = $stats.baselineUp; baselineDown = $stats.baselineDown
    totalUp = $stats.baselineUp; totalDown = $stats.baselineDown
    ratio = 0.0; todayUp = [int64]0; todayDown = [int64]0
    appDownloaded = [int64]0; updated = [int64]0
}
$shared.SourceHealth = @{}

$script:Shared = $shared

Add-LogLine ('服务已启动 v' + $script:Version + ' · 端口 ' + $Port)

# ---------------------------------------------------------------- state payload

function Build-StatePayload {
    $cfg = $script:Shared.Config
    $cfgCopy = @{}
    foreach ($k in $cfg.Keys) { $cfgCopy[$k] = $cfg[$k] }

    $taskList = New-Object System.Collections.ArrayList
    $running = 0
    foreach ($t in $script:Shared.Tasks.Values) {
        if ($t.state -eq 'running') { $running++ }
        [void]$taskList.Add(@{
            id       = [string]$t.id
            source   = [string]$t.sourceName
            url      = [string]$t.url
            state    = [string]$t.state
            bytes    = [int64]$t.bytes
            target   = [int64]$t.target
            speed    = [int64]$t.speed
            error    = [string]$t.error
            created  = [int64]$t.created
            finished = [int64]$t.finished
        })
    }
    $tasks = @($taskList | Sort-Object -Property created -Descending | Select-Object -First 40)

    $state = @{
        ok       = $true
        version  = $script:Version
        now      = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        uptime   = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $script:Shared.StartedAt)
        port     = $Port
        config   = $cfgCopy
        stats    = $script:Shared.StatsSnapshot
        net      = $script:Shared.NetSnapshot
        health   = $script:Shared.SourceHealth
        tasks    = $tasks
        log      = @($script:Shared.Log.ToArray())
        engine   = @{
            paused     = [bool]$script:Shared.Paused
            active     = [bool]$script:Shared.Active
            rate       = [int64]$script:Shared.Rate
            desired    = [int64]$script:Shared.DesiredRate
            running    = $running
            appDownloaded = [int64]$script:Shared.AppDownloaded
        }
    }
    return $state
}

# ---------------------------------------------------------------- http plumbing

function Send-Bytes {
    param($Stream, [int]$Status, [string]$ContentType, [byte[]]$Body)
    if ($null -eq $Body) { $Body = New-Object byte[] 0 }
    $statusText = 'OK'
    switch ($Status) {
        200 { $statusText = 'OK' }
        204 { $statusText = 'No Content' }
        400 { $statusText = 'Bad Request' }
        404 { $statusText = 'Not Found' }
        405 { $statusText = 'Method Not Allowed' }
        500 { $statusText = 'Internal Server Error' }
    }
    $head = "HTTP/1.1 $Status $statusText`r`n"
    if ($ContentType) { $head += "Content-Type: $ContentType`r`n" }
    $head += "Content-Length: $($Body.Length)`r`n"
    $head += "Cache-Control: no-store, no-cache, must-revalidate`r`n"
    $head += "X-Content-Type-Options: nosniff`r`n"
    $head += "Connection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb, 0, $hb.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Send-Json {
    param($Stream, $Object, [int]$Status = 200)
    $json = ConvertTo-Json -InputObject $Object -Depth 12 -Compress
    Send-Bytes -Stream $Stream -Status $Status -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Send-Text {
    param($Stream, [string]$Text, [int]$Status = 200, [string]$ContentType = 'text/plain; charset=utf-8')
    Send-Bytes -Stream $Stream -Status $Status -ContentType $ContentType -Body ([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Read-HttpRequest {
    param($Stream)
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 4096
    $headerEnd = -1
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        $n = 0
        try { $n = $Stream.Read($buf, 0, $buf.Length) } catch { break }
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
        $arr = $ms.ToArray()
        for ($i = 0; $i -le $arr.Length - 4; $i++) {
            if ($arr[$i] -eq 13 -and $arr[$i + 1] -eq 10 -and $arr[$i + 2] -eq 13 -and $arr[$i + 3] -eq 10) {
                $headerEnd = $i
                break
            }
        }
        if ($headerEnd -ge 0) { break }
        if ($arr.Length -gt 65536) { break }
    }
    if ($headerEnd -lt 0) { return $null }

    $all = $ms.ToArray()
    $headerText = [System.Text.Encoding]::UTF8.GetString($all, 0, $headerEnd)
    $lines = $headerText -split "`r`n"
    $requestLine = $lines[0] -split ' '
    if ($requestLine.Count -lt 2) { return $null }

    $method = $requestLine[0].ToUpper()
    $target = $requestLine[1]
    $path = $target.Split('?')[0]
    try { $path = [System.Uri]::UnescapeDataString($path) } catch { }

    $contentLength = 0
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(?i)content-length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
    }

    $bodyStart = $headerEnd + 4
    $bodyMs = New-Object System.IO.MemoryStream
    $already = $all.Length - $bodyStart
    if ($already -gt 0) { $bodyMs.Write($all, $bodyStart, $already) }
    $remaining = $contentLength - $already
    while ($remaining -gt 0) {
        $want = [Math]::Min($buf.Length, $remaining)
        $n = 0
        try { $n = $Stream.Read($buf, 0, $want) } catch { break }
        if ($n -le 0) { break }
        $bodyMs.Write($buf, 0, $n)
        $remaining -= $n
    }
    $bodyText = ''
    if ($bodyMs.Length -gt 0) {
        $bodyText = [System.Text.Encoding]::UTF8.GetString($bodyMs.ToArray())
    }

    return @{ Method = $method; Path = $path; Body = $bodyText }
}

function Get-ContentType {
    param([string]$Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLower()) {
        '.html' { return 'text/html; charset=utf-8' }
        '.js'   { return 'application/javascript; charset=utf-8' }
        '.css'  { return 'text/css; charset=utf-8' }
        '.json' { return 'application/json; charset=utf-8' }
        '.svg'  { return 'image/svg+xml' }
        '.png'  { return 'image/png' }
        '.ico'  { return 'image/x-icon' }
        '.woff2' { return 'font/woff2' }
        default { return 'application/octet-stream' }
    }
}

# ---------------------------------------------------------------- api

function Set-ConfigFromBody {
    param($Body)
    $current = $script:Shared.Config
    $merged = @{}
    foreach ($k in $current.Keys) { $merged[$k] = $current[$k] }
    if ($Body) {
        foreach ($k in $Body.Keys) { $merged[$k] = $Body[$k] }
    }
    $norm = Normalize-Config $merged
    Write-JsonFile $configPath $norm
    $script:Shared.Config = $norm
    return $norm
}

function Handle-ApiPost {
    param($Stream, [string]$Path, [string]$BodyText)
    $body = $null
    if ($BodyText -and $BodyText.Trim()) {
        try { $body = ConvertTo-HashtableDeep (ConvertFrom-Json -InputObject $BodyText) } catch { $body = $null }
    }

    switch ($Path) {
        '/api/config' {
            $cfg = Set-ConfigFromBody $body
            Add-LogLine ('设置已更新 · 目标比例 ' + $cfg.targetRatio + 'x')
            Send-Json $Stream @{ ok = $true; config = $cfg }
            return
        }
        '/api/control' {
            $action = ''
            if ($body -and $body.action) { $action = [string]$body.action }
            switch ($action) {
                'pause' {
                    $script:Shared.Paused = $true
                    $script:Shared.Active = $false
                    $script:Shared.Rate = [int64]0
                    Add-LogLine '已暂停下载'
                }
                'start' {
                    $script:Shared.Paused = $false
                    Add-LogLine '已继续下载'
                }
                'clean' {
                    $removed = 0
                    Get-ChildItem -LiteralPath $script:DownDir -Filter '*.bin' -ErrorAction SilentlyContinue | ForEach-Object {
                        try { Remove-Item -LiteralPath $_.FullName -Force; $removed++ } catch { }
                    }
                    Add-LogLine ('已清理 ' + $removed + ' 个缓存文件')
                }
                'clear-tasks' {
                    $script:Shared.Tasks.Clear()
                }
                'shutdown' {
                    $script:Shared.Stop = $true
                    Send-Json $Stream @{ ok = $true; message = 'shutdown' }
                    return
                }
            }
            Send-Json $Stream @{ ok = $true; action = $action }
            return
        }
        '/api/baseline' {
            [System.Threading.Monitor]::Enter($script:Shared.Lock)
            try {
                $st = $script:Shared.Stats
                if ($body -and $body.reset -eq $true) {
                    $st.up = [int64]0
                    $st.down = [int64]0
                    $st.baselineUp = [int64]0
                    $st.baselineDown = [int64]0
                    $st.days = @{}
                    Add-LogLine '统计已清零'
                } else {
                    if ($body -and $null -ne $body.up) { $st.baselineUp = [int64]$body.up }
                    if ($body -and $null -ne $body.down) { $st.baselineDown = [int64]$body.down }
                    Add-LogLine ('校准已保存 · 上行 ' + [Math]::Round($st.baselineUp / 1GB, 2) + ' GB / 下行 ' + [Math]::Round($st.baselineDown / 1GB, 2) + ' GB')
                }
            } finally { [System.Threading.Monitor]::Exit($script:Shared.Lock) }
            Write-JsonFile $statsPath $script:Shared.Stats
            Send-Json $Stream @{ ok = $true }
            return
        }
        '/api/sources' {
            $cfg = $script:Shared.Config
            $sources = @($cfg.sources)
            $action = ''
            if ($body -and $body.action) { $action = [string]$body.action }
            if ($action -eq 'add') {
                $url = [string]$body.url
                if ([string]::IsNullOrWhiteSpace($url)) { Send-Json $Stream @{ ok = $false; error = 'URL 不能为空' }; return }
                if ($url -notmatch '^https?://') { Send-Json $Stream @{ ok = $false; error = '只支持 http/https 链接' }; return }
                $name = [string]$body.name
                if ([string]::IsNullOrWhiteSpace($name)) {
                    try { $name = ([Uri]$url).Host } catch { $name = '自定义数据源' }
                }
                $srcs = @()
                foreach ($s in $sources) { $srcs += $s }
                $srcs += @{
                    id = [guid]::NewGuid().ToString('N').Substring(0, 8)
                    name = $name
                    url = $url
                    template = [bool]($url -match '\{bytes\}')
                    range = -not ($url -match '\{bytes\}')
                    enabled = $true
                }
                $newCfg = @{}
                foreach ($k in $cfg.Keys) { $newCfg[$k] = $cfg[$k] }
                $newCfg.sources = $srcs
                $norm = Normalize-Config $newCfg
                Write-JsonFile $configPath $norm
                $script:Shared.Config = $norm
                Add-LogLine ('已添加数据源 ' + $name)
            } elseif ($action -eq 'remove') {
                $id = [string]$body.id
                $srcs = @()
                foreach ($s in $sources) { if ([string]$s.id -ne $id) { $srcs += $s } }
                $newCfg = @{}
                foreach ($k in $cfg.Keys) { $newCfg[$k] = $cfg[$k] }
                $newCfg.sources = $srcs
                $norm = Normalize-Config $newCfg
                Write-JsonFile $configPath $norm
                $script:Shared.Config = $norm
            } elseif ($action -eq 'toggle') {
                $id = [string]$body.id
                $enabled = [bool]$body.enabled
                $srcs = @()
                foreach ($s in $sources) {
                    if ([string]$s.id -eq $id) { $s.enabled = $enabled }
                    $srcs += $s
                }
                $newCfg = @{}
                foreach ($k in $cfg.Keys) { $newCfg[$k] = $cfg[$k] }
                $newCfg.sources = $srcs
                $norm = Normalize-Config $newCfg
                Write-JsonFile $configPath $norm
                $script:Shared.Config = $norm
            }
            Send-Json $Stream @{ ok = $true; config = $script:Shared.Config }
            return
        }
        '/api/ping' {
            $script:Shared.LastPing = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            Send-Json $Stream @{ ok = $true }
            return
        }
        default {
            Send-Json $Stream @{ ok = $false; error = 'unknown endpoint' } 404
            return
        }
    }
}

function Handle-Client {
    param($Client)
    $stream = $null
    try {
        $Client.ReceiveTimeout = 8000
        $Client.SendTimeout = 15000
        $stream = $Client.GetStream()
        # browsers open speculative sockets that never send anything - do not block on those
        $wait = 0
        while (-not $stream.DataAvailable) {
            Start-Sleep -Milliseconds 10
            $wait += 10
            if ($wait -ge 1200) { return }
            if ($script:Shared.Stop) { return }
        }
        $req = Read-HttpRequest $stream
        if ($null -eq $req) { return }
        $path = [string]$req.Path
        $method = [string]$req.Method

        if ($method -eq 'POST') {
            if ($path.StartsWith('/api/')) {
                Handle-ApiPost -Stream $stream -Path $path -BodyText $req.Body
                return
            }
            Send-Json $stream @{ ok = $false; error = 'not found' } 404
            return
        }

        if ($method -ne 'GET') {
            Send-Json $stream @{ ok = $false; error = 'method not allowed' } 405
            return
        }

        if ($path -eq '/api/state') {
            Send-Json $stream (Build-StatePayload)
            return
        }
        if ($path -eq '/api/health') {
            Send-Json $stream @{ ok = $true; version = $script:Version }
            return
        }
        if ($path -eq '/favicon.ico') {
            Send-Bytes -Stream $stream -Status 204 -ContentType $null -Body (New-Object byte[] 0)
            return
        }

        if ($path -eq '/' -or $path -eq '') { $path = '/index.html' }
        $relative = $path.TrimStart('/').Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $full = [System.IO.Path]::GetFullPath((Join-Path $script:PublicDir $relative))
        $publicFull = [System.IO.Path]::GetFullPath($script:PublicDir)
        if (-not $full.StartsWith($publicFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            Send-Text $stream 'forbidden' 404
            return
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            Send-Text $stream 'not found' 404
            return
        }
        $bytes = [System.IO.File]::ReadAllBytes($full)
        Send-Bytes -Stream $stream -Status 200 -ContentType (Get-ContentType $full) -Body $bytes
    } catch {
        # client went away - ignore
    } finally {
        if ($stream) { try { $stream.Dispose() } catch { } }
        try { $Client.Close() } catch { }
    }
}

# ---------------------------------------------------------------- runspaces

$runspaces = New-Object System.Collections.ArrayList

function Start-Background {
    param([string]$Path, [string]$Label)
    $ps = [powershell]::Create()
    try {
        $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        [void]$ps.AddScript($text)
        [void]$ps.AddParameter('Shared', $script:Shared)
        [void]$ps.BeginInvoke()
        [void]$runspaces.Add(@{ ps = $ps; label = $Label })
        return $true
    } catch {
        Add-LogLine ('无法启动 ' + $Label + ': ' + $_.Exception.Message)
        return $false
    }
}

Start-Background -Path $script:ControllerPath -Label 'controller' | Out-Null
for ($i = 1; $i -le 8; $i++) {
    Start-Background -Path $script:WorkerPath -Label ('worker' + $i) | Out-Null
}

# ---------------------------------------------------------------- listen

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
try {
    $listener.Start(64)
} catch {
    Add-LogLine ('端口 ' + $Port + ' 被占用')
    exit 1
}
try { $listener.Server.NoDelay = $true } catch { }
[System.IO.File]::WriteAllText($portPath, [string]$Port, $script:Utf8)
$pidPath = Join-Path $script:DataDir 'pid.txt'
try { [System.IO.File]::WriteAllText($pidPath, [string]$PID, $script:Utf8) } catch { }

Add-LogLine ('监听 http://127.0.0.1:' + $Port)

$lastHeartbeatCheck = [DateTime]::UtcNow
while (-not $script:Shared.Stop) {
    if ($listener.Pending()) {
        try {
            $client = $listener.AcceptTcpClient()
            Handle-Client -Client $client
        } catch { }
    } else {
        Start-Sleep -Milliseconds 12
    }
    if (([DateTime]::UtcNow - $lastHeartbeatCheck).TotalSeconds -ge 5) {
        $lastHeartbeatCheck = [DateTime]::UtcNow
        $cfg = $script:Shared.Config
        if ([bool]$cfg.heartbeat) {
            $idle = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [int64]$script:Shared.LastPing
            if ($idle -gt 45000) { $script:Shared.Stop = $true }
        }
    }
}

# ---------------------------------------------------------------- shutdown

$script:Shared.Stop = $true
$script:Shared.Active = $false
try { $listener.Stop() } catch { }
Start-Sleep -Milliseconds 700
foreach ($r in $runspaces) {
    try { [void]$r.ps.Stop() } catch { }
    try { $r.ps.Dispose() } catch { }
}
try {
    $script:Shared.Stats.updated = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Write-JsonFile $statsPath $script:Shared.Stats
} catch { }
try { Remove-Item -LiteralPath $portPath -Force -ErrorAction SilentlyContinue } catch { }
try { Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue } catch { }
