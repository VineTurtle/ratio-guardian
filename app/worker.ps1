param($Shared)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http | Out-Null
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$CHUNK = 65536
# 说明：部分镜像站（清华、北外等）会拒绝没有 User-Agent 或伪装成浏览器的请求（返回 403），
# 但接受普通客户端 UA，因此这里使用明确的应用 UA。
$UA = 'RatioGuardian/1.0'

function Add-WorkerLog {
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

function Wait-Active {
    $waited = 0.0
    while ($Shared.Paused -or -not $Shared.Active) {
        if ($Shared.Stop) { throw 'stopped' }
        Start-Sleep -Milliseconds 150
        $waited += 0.15
        if ($waited -gt 120) { throw 'paused-too-long' }
    }
}

function Wait-Tokens {
    param([int64]$Count)
    $rate = [int64]$Shared.Rate
    if ($rate -le 0) { return }
    $cap = [Math]::Max([double]$Count, [double]$rate * 0.5)
    while ($true) {
        if ($Shared.Stop) { throw 'stopped' }
        $waitMs = 5
        [System.Threading.Monitor]::Enter($Shared.Lock)
        try {
            $now = [DateTime]::UtcNow
            $elapsed = ($now - $Shared.LastRefill).TotalSeconds
            if ($elapsed -lt 0) { $elapsed = 0 }
            $Shared.LastRefill = $now
            $Shared.Tokens = [Math]::Min($cap, $Shared.Tokens + $elapsed * [double]$rate)
            if ($Shared.Tokens -ge $Count) {
                $Shared.Tokens -= $Count
                return
            }
            $waitMs = [int](($Count - $Shared.Tokens) / [double]$rate * 1000)
            if ($waitMs -gt 200) { $waitMs = 200 }
            if ($waitMs -lt 5) { $waitMs = 5 }
        } finally { [System.Threading.Monitor]::Exit($Shared.Lock) }
        Start-Sleep -Milliseconds $waitMs
    }
}

function New-Request {
    param([string]$Url, [int64]$Offset, $RangeEnd, [bool]$UseRange)
    $req = New-Object System.Net.Http.HttpRequestMessage
    $req.Method = [System.Net.Http.HttpMethod]::Get
    $req.RequestUri = New-Object System.Uri($Url)
    [void]$req.Headers.TryAddWithoutValidation('User-Agent', $UA)
    if ($UseRange) {
        $req.Headers.Range = New-Object System.Net.Http.Headers.RangeHeaderValue($Offset, $RangeEnd)
    }
    return $req
}

function Send-Following {
    param($Client, [string]$Url, [int64]$Offset, $RangeEnd, [bool]$UseRange)
    $current = $Url
    for ($hop = 0; $hop -le 5; $hop++) {
        $req = New-Request -Url $current -Offset $Offset -RangeEnd $RangeEnd -UseRange $UseRange
        try {
            $resp = $Client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        } finally {
            try { $req.Dispose() } catch { }
        }
        $code = [int]$resp.StatusCode
        if ($code -eq 301 -or $code -eq 302 -or $code -eq 303 -or $code -eq 307 -or $code -eq 308) {
            $loc = $null
            try { $loc = $resp.Headers.Location } catch { }
            try { $resp.Dispose() } catch { }
            if (-not $loc) { throw ('HTTP ' + $code + '（缺少跳转地址）') }
            $next = $loc
            if (-not $loc.IsAbsoluteUri) {
                $next = New-Object System.Uri((New-Object System.Uri($current)), $loc)
            }
            $nextUrl = $next.AbsoluteUri
            if ($nextUrl -eq $current) { throw ('HTTP ' + $code + '（跳转回环）') }
            $current = $nextUrl
            continue
        }
        return @{ response = $resp; url = $current }
    }
    throw 'too-many-redirects'
}

function Test-FatalHttpError {
    param([string]$Message)
    if ($Message -match '^HTTP (403|404|410|418|451)') { return $true }
    if ($Message -match '^HTTP 429') { return $true }
    return $false
}

function Invoke-Transfer {
    param($Task)

    $offset = [int64]$Task.bytes
    $useRange = [bool]$Task.range
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(60)

    $resp = $null
    $stream = $null
    $fs = $null
    try {
        $rangeEnd = $null
        if ($useRange -and [int64]$Task.target -gt 0) { $rangeEnd = [int64]$Task.target - 1 }

        $sent = Send-Following -Client $client -Url ([string]$Task.url) -Offset $offset -RangeEnd $rangeEnd -UseRange $useRange
        $resp = $sent.response
        $code = [int]$resp.StatusCode
        if ($code -ne 200 -and $code -ne 206) {
            throw ('HTTP ' + $code)
        }
        if ($useRange -and $code -eq 200 -and $offset -gt 0) {
            # 服务器忽略 Range，只能从头开始
            $Task.bytes = [int64]0
            $offset = 0
        }

        $mode = [System.IO.FileMode]::Create
        if ($offset -gt 0) { $mode = [System.IO.FileMode]::Append }
        $fs = New-Object System.IO.FileStream([string]$Task.file, $mode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)

        $stream = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $buf = New-Object byte[] $CHUNK
        $cts = New-Object System.Threading.CancellationTokenSource
        $lastTick = [DateTime]::UtcNow
        $lastBytes = [int64]$Task.bytes

        while ([int64]$Task.bytes -lt [int64]$Task.target) {
            Wait-Active
            Wait-Tokens -Count $CHUNK

            $cts.CancelAfter(45000)
            $readTask = $stream.ReadAsync($buf, 0, $buf.Length, $cts.Token)
            if (-not $readTask.Wait(50000)) {
                try { $cts.Cancel() } catch { }
                throw 'read-timeout'
            }
            $n = 0
            try { $n = $readTask.GetAwaiter().GetResult() } catch { throw 'read-failed' }
            if ($n -le 0) { break }

            $fs.Write($buf, 0, $n)
            $Task.bytes = [int64]$Task.bytes + $n

            $now = [DateTime]::UtcNow
            $dt = ($now - $lastTick).TotalSeconds
            if ($dt -gt 0.4) {
                $Task.speed = [int64](($Task.bytes - $lastBytes) / $dt)
                $lastBytes = [int64]$Task.bytes
                $lastTick = $now
            }
        }
        try { $fs.Flush() } catch { }
        $Task.speed = [int64]0
    } finally {
        if ($fs) { try { $fs.Dispose() } catch { } }
        if ($stream) { try { $stream.Dispose() } catch { } }
        if ($resp) { try { $resp.Dispose() } catch { } }
        try { $client.Dispose() } catch { }
    }
}

function Invoke-Task {
    param($Task)

    $Task.state = 'running'
    $Task.started = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $Task.speed = [int64]0

    $attempt = 0
    while ($attempt -lt 5) {
        if ($Shared.Stop) { $Task.state = 'failed'; return }
        $attempt++
        try {
            Invoke-Transfer -Task $Task
            if ([int64]$Task.bytes -ge [int64]$Task.target) {
                $Task.state = 'done'
                $Task.error = ''
                $Task.speed = [int64]0
                $Task.finished = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                [System.Threading.Monitor]::Enter($Shared.Lock)
                try { $Shared.AppDownloaded = [int64]$Shared.AppDownloaded + [int64]$Task.bytes }
                finally { [System.Threading.Monitor]::Exit($Shared.Lock) }
                Add-WorkerLog ('任务完成 ' + [Math]::Round([double]$Task.bytes / 1MB) + ' MB · ' + $Task.sourceName)
                return
            }
            if ([int64]$Task.bytes -gt 0) { continue }
            throw 'empty-response'
        } catch {
            $msg = $_.Exception.Message
            if ($msg -eq 'stopped' -or $Shared.Stop) { $Task.state = 'failed'; $Task.speed = 0; return }
            if ($msg -eq 'paused-too-long') { $Task.error = '暂停超时'; }
            $Task.error = [string]$msg
            $Task.speed = [int64]0
            if (Test-FatalHttpError $msg) { break }
            if ($attempt -ge 5) { break }
            if ($msg -ne 'paused-too-long') {
                Start-Sleep -Milliseconds (350 * $attempt)
            }
        }
    }

    $Task.state = 'failed'
    $Task.speed = [int64]0
    $Task.finished = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if (-not $Task.error) { $Task.error = 'unknown' }
    Add-WorkerLog ('任务失败 ' + $Task.sourceName + ' · ' + $Task.error)
}

# ------------------------------------------------------------------- loop

while (-not $Shared.Stop) {
    try {
        if ($Shared.Paused -or -not $Shared.Active) {
            Start-Sleep -Milliseconds 250
            continue
        }
        $task = $null
        if (-not $Shared.Queue.TryDequeue([ref]$task)) {
            Start-Sleep -Milliseconds 250
            continue
        }
        Invoke-Task -Task $task
    } catch {
        Add-WorkerLog ('工作线程异常: ' + $_.Exception.Message)
        Start-Sleep -Milliseconds 500
    }
}
