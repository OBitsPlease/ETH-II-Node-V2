$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $env:LOCALAPPDATA 'ETHII\Peer-Node\logs\node.log'

Write-Host 'ETHII local peer live monitor' -ForegroundColor Cyan
Write-Host 'Press Ctrl+C to stop.' -ForegroundColor DarkGray

while ($true) {
  Write-Host ''
  Write-Host "=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" -ForegroundColor Yellow
  try {
    $b = Invoke-RestMethod -Uri 'http://127.0.0.1:8555' -Method Post -ContentType 'application/json' -Body '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' -TimeoutSec 2
    $p = Invoke-RestMethod -Uri 'http://127.0.0.1:8555' -Method Post -ContentType 'application/json' -Body '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":2}' -TimeoutSec 2
    Write-Host "local block: $($b.result)" -ForegroundColor Green
    Write-Host "local peers: $($p.result)" -ForegroundColor Green
  } catch {
    Write-Host 'local RPC: unavailable' -ForegroundColor Red
  }

  if (Test-Path $log) {
    Write-Host 'last log lines:' -ForegroundColor Cyan
    Get-Content $log -Tail 6
  } else {
    Write-Host "log missing: $log" -ForegroundColor DarkGray
  }

  Start-Sleep -Seconds 5
}
