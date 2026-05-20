# ETHII Stratum Standalone Launcher

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Auto-update suite components before launching standalone stratum mode.
$UpdaterScript = Join-Path $ScriptDir "update-manager.ps1"
if (Test-Path $UpdaterScript) {
    Write-Host "Checking for suite updates..." -ForegroundColor Cyan
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $UpdaterScript -Mode auto -SkipWallet
    } catch {
        Write-Host "WARNING: updater failed, continuing stratum launch: $_" -ForegroundColor Yellow
    }
    Write-Host ""
}

$RpcPort       = 8545
$StratumPort   = 3335
$DashboardPort = 8082

$StratumExe = Join-Path $ScriptDir "stratum\stratum.exe"
if (-not (Test-Path $StratumExe)) {
    $StratumExe = Join-Path $ScriptDir "stratum.exe"
}
if (-not (Test-Path $StratumExe)) {
    Write-Host "ERROR: stratum.exe not found." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Free fixed ports if already in use
foreach ($port in @($StratumPort, $DashboardPort)) {
    $conn = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
    if ($conn) {
        $ownerPid = ($conn | Select-Object -First 1).OwningProcess
        if ($ownerPid -and $ownerPid -gt 0) {
            Stop-Process -Id $ownerPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
    }
}

$portFile = Join-Path $ScriptDir "stratum-port.txt"
Set-Content -Path $portFile -Value $StratumPort -NoNewline

Write-Host "  RPC Port      : $RpcPort"        -ForegroundColor Green
Write-Host "  Stratum Port  : $StratumPort"    -ForegroundColor Green
Write-Host "  Dashboard Port: $DashboardPort"  -ForegroundColor Green
Write-Host ""
Write-Host "Starting ETHII Stratum Proxy..." -ForegroundColor Cyan
Write-Host "Dashboard will be at: http://127.0.0.1:$DashboardPort" -ForegroundColor Cyan
Write-Host "Keep this window open. Press Ctrl+C to stop." -ForegroundColor Yellow
Write-Host ""

Start-Process -FilePath $StratumExe -ArgumentList "--node `"http://127.0.0.1:$RpcPort`" --stratum `"0.0.0.0:$StratumPort`" --dashboard `"0.0.0.0:$DashboardPort`"" -WindowStyle Normal -PassThru | Out-Null
Start-Sleep -Seconds 2
Start-Process "http://127.0.0.1:$DashboardPort"

Write-Host "Dashboard opened in browser." -ForegroundColor Green
Write-Host "Press Ctrl+C in the stratum window to stop mining."
Read-Host "Press Enter to close this window"
