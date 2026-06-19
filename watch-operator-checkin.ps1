# Watches the EU bootnode for NEW peer connections (e.g. a new pool
# operator bringing their node online). Run it and leave it open.
# Local admin tool only - do not commit/publish.

$ErrorActionPreference = 'Continue'
$VpsIp = '91.99.231.217'
$SshKey = Join-Path $env:USERPROFILE '.ssh\ethii_vps'
$PollSeconds = 30

function Get-Peers {
  $raw = ssh -i $SshKey -o ConnectTimeout=10 "root@$VpsIp" /root/ethii-peers.sh 2>$null
  if (-not $raw) { return $null }
  try { return (($raw -join '') | ConvertFrom-Json).result } catch { return $null }
}

Write-Host 'ETHII operator check-in watcher' -ForegroundColor Cyan
Write-Host "Watching EU bootnode ($VpsIp) for new peers every $PollSeconds s. Ctrl+C to stop." -ForegroundColor DarkGray
Write-Host ''

$baseline = Get-Peers
if ($null -eq $baseline) {
  Write-Host 'ERROR: could not reach EU node (check SSH key / connection).' -ForegroundColor Red
  exit 1
}

$known = @{}
Write-Host ("Current peers ({0}):" -f $baseline.Count) -ForegroundColor Yellow
foreach ($p in $baseline) {
  $ip = ($p.network.remoteAddress -split ':')[0]
  $known[$p.id] = $true
  Write-Host ("  {0,-16} {1}" -f $ip, $p.name) -ForegroundColor DarkGray
}
Write-Host ''
Write-Host 'Waiting for a NEW peer to appear...' -ForegroundColor Cyan

while ($true) {
  Start-Sleep -Seconds $PollSeconds
  $peers = Get-Peers
  if ($null -eq $peers) { Write-Host ("{0:HH:mm:ss} poll failed (ssh/rpc), retrying" -f (Get-Date)) -ForegroundColor DarkYellow; continue }
  foreach ($p in $peers) {
    if (-not $known.ContainsKey($p.id)) {
      $known[$p.id] = $true
      $ip = ($p.network.remoteAddress -split ':')[0]
      Write-Host ''
      Write-Host ("{0:yyyy-MM-dd HH:mm:ss}  NEW PEER CONNECTED" -f (Get-Date)) -ForegroundColor Green
      Write-Host ("  IP:     {0}" -f $ip) -ForegroundColor Green
      Write-Host ("  Client: {0}" -f $p.name) -ForegroundColor Green
      Write-Host ("  Enode id: {0}..." -f $p.id.Substring(0,16)) -ForegroundColor Green
      Write-Host '  A connected peer passed the genesis + network-id handshake (right chain).' -ForegroundColor DarkGray
      Write-Host '  If this is your new operator: wait for their check-in DM, verify the' -ForegroundColor DarkGray
      Write-Host '  identity values match, then register them in the operator registry.' -ForegroundColor DarkGray
      [console]::beep(1000,400)
    }
  }
  Write-Host ("{0:HH:mm:ss} peers: {1}" -f (Get-Date), $peers.Count) -ForegroundColor DarkGray
}
