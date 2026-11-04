$ErrorActionPreference = 'SilentlyContinue'

$appDir  = $PSScriptRoot
$rootDir = Split-Path -Parent $appDir
$dataDir = Join-Path $rootDir 'data'
$portFile = Join-Path $dataDir 'port.txt'
$pidFile  = Join-Path $dataDir 'pid.txt'

$port = 0
if (Test-Path -LiteralPath $portFile) {
    $raw = (Get-Content -LiteralPath $portFile -Raw).Trim()
    if ($raw -match '^\d+$') { $port = [int]$raw }
}

if ($port -gt 0) {
    try {
        Invoke-WebRequest -Uri ('http://127.0.0.1:' + $port + '/api/control') -Method POST -Body '{"action":"shutdown"}' -ContentType 'application/json' -TimeoutSec 6 -UseBasicParsing | Out-Null
    } catch { }
    Start-Sleep -Milliseconds 1200
}

if (Test-Path -LiteralPath $pidFile) {
    $rawPid = (Get-Content -LiteralPath $pidFile -Raw).Trim()
    if ($rawPid -match '^\d+$') {
        $proc = Get-Process -Id ([int]$rawPid) -ErrorAction SilentlyContinue
        if ($proc) { Stop-Process -Id ([int]$rawPid) -Force -ErrorAction SilentlyContinue }
    }
}

Remove-Item -LiteralPath $portFile -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
