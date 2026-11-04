$ErrorActionPreference = 'Stop'

$appDir  = $PSScriptRoot
$rootDir = Split-Path -Parent $appDir
$dataDir = Join-Path $rootDir 'data'
if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
$logPath  = Join-Path $dataDir 'launcher.log'
$portFile = Join-Path $dataDir 'port.txt'

function Write-LauncherLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $logPath -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $Message) -Encoding UTF8
    } catch { }
}

function Test-LocalPort {
    param([int]$Port)
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(350)
        if (-not $ok) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        if ($client) { try { $client.Close() } catch { } }
    }
}

function Open-AppWindow {
    param([int]$Port)
    $url = 'http://127.0.0.1:' + $Port + '/'
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
        (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe')
    )
    $browser = $null
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { $browser = $c; break }
    }
    if ($browser) {
        $profileDir = Join-Path $env:LOCALAPPDATA 'RatioGuardian\window'
        try {
            Start-Process -FilePath $browser -ArgumentList @(
                "--app=$url",
                '--window-size=1440,950',
                '--window-position=90,50',
                "--user-data-dir=`"$profileDir`"",
                '--no-first-run',
                '--no-default-browser-check',
                '--disable-features=Translate,msEdgeSplitScreen'
            ) | Out-Null
            return
        } catch {
            Write-LauncherLog ('app window failed: ' + $_.Exception.Message)
        }
    }
    Start-Process $url | Out-Null
}

try {
    Write-LauncherLog 'launcher started'

    $existing = 0
    if (Test-Path -LiteralPath $portFile) {
        $raw = ''
        try { $raw = (Get-Content -LiteralPath $portFile -Raw).Trim() } catch { }
        if ($raw -match '^\d+$') { $existing = [int]$raw }
    }

    if ($existing -gt 0 -and (Test-LocalPort $existing)) {
        Write-LauncherLog ('reusing running server on port ' + $existing)
        Open-AppWindow -Port $existing
        exit 0
    }

    $port = 0
    for ($p = 7788; $p -le 7810; $p++) {
        if (-not (Test-LocalPort $p)) { $port = $p; break }
    }
    if ($port -eq 0) { throw '没有可用的本地端口（7788-7810 都被占用）' }

    $serverPath = Join-Path $appDir 'server.ps1'
    Write-LauncherLog ('starting server on port ' + $port)
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', "`"$serverPath`"",
        '-Port', $port
    ) | Out-Null

    $ready = $false
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline) {
        if (Test-LocalPort $port) { $ready = $true; break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $ready) { throw '后台服务启动超时，详见 data\launcher.log' }

    Write-LauncherLog 'server ready, opening window'
    Open-AppWindow -Port $port
    exit 0
} catch {
    Write-LauncherLog ('ERROR: ' + $_.Exception.Message)
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            "启动失败：`r`n" + $_.Exception.Message,
            '比例守护',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch { }
    exit 1
}
