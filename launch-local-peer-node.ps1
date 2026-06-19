param(
  [switch]$Stop,
  [switch]$Status
)

$ErrorActionPreference = 'Stop'
$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$PeerRoot = Join-Path $env:LOCALAPPDATA 'ETHII\Peer-Node'
$DataDir = Join-Path $PeerRoot 'data'
$LogDir = Join-Path $PeerRoot 'logs'
$NodeLog = Join-Path $LogDir 'node.log'
$RpcPort = 8555
$P2PPort = 30305

$NodeCandidates = @(
  (Join-Path $RootDir 'ethii.exe'),
  (Join-Path $RootDir 'ETH-II-Wallet\ethii.exe'),
  (Join-Path $RootDir 'ETH-II-NODE-ONLY\deploy\windows\ethii.exe')
)
$GenesisCandidates = @(
  (Join-Path $RootDir 'ETH-II-Wallet\wallet\genesis.json'),
  (Join-Path $RootDir 'ETH-II-NODE-ONLY\genesis.json')
)

$NodeExe = $NodeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
$Genesis = $GenesisCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $NodeExe) { throw 'ethii.exe not found. Expected in workspace root or ETH-II-Wallet/ETH-II-NODE-ONLY paths.' }
if (-not $Genesis) { throw 'genesis.json not found for chain 20482.' }

if (-not (Test-Path $PeerRoot)) { New-Item -ItemType Directory -Path $PeerRoot -Force | Out-Null }
if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# Ensure inbound peer port is open for this node.
$fwInTcp = Get-NetFirewallRule -DisplayName 'ETHII Local Peer P2P TCP' -ErrorAction SilentlyContinue
$fwInUdp = Get-NetFirewallRule -DisplayName 'ETHII Local Peer P2P UDP' -ErrorAction SilentlyContinue
if (-not $fwInTcp) {
  try {
    New-NetFirewallRule -DisplayName 'ETHII Local Peer P2P TCP' -Direction Inbound -Protocol TCP -LocalPort $P2PPort -Action Allow -Profile Any | Out-Null
  } catch {
    Write-Host 'WARNING: could not create firewall rule for TCP 30305 (run elevated once to allow inbound peers).' -ForegroundColor Yellow
  }
}
if (-not $fwInUdp) {
  try {
    New-NetFirewallRule -DisplayName 'ETHII Local Peer P2P UDP' -Direction Inbound -Protocol UDP -LocalPort $P2PPort -Action Allow -Profile Any | Out-Null
  } catch {
    Write-Host 'WARNING: could not create firewall rule for UDP 30305 (run elevated once to allow inbound peers).' -ForegroundColor Yellow
  }
}

$existing = Get-CimInstance Win32_Process -Filter "Name='ethii.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like "*--datadir*${DataDir.Replace('\','\\')}*" }

if ($Status) {
  if ($existing) {
    Write-Host "Peer node is RUNNING (PID $($existing.ProcessId))." -ForegroundColor Green
  } else {
    Write-Host 'Peer node is STOPPED.' -ForegroundColor Yellow
  }
  $body = '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
  try {
    $r = Invoke-RestMethod -Uri "http://127.0.0.1:$RpcPort" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 3
    Write-Host "RPC blockNumber: $($r.result) on localhost:$RpcPort" -ForegroundColor Cyan
    $p = Invoke-RestMethod -Uri "http://127.0.0.1:$RpcPort" -Method Post -ContentType 'application/json' -Body '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":2}' -TimeoutSec 3
    Write-Host "RPC peerCount: $($p.result)" -ForegroundColor Cyan
  } catch {
    Write-Host "RPC not responding on localhost:$RpcPort" -ForegroundColor Yellow
  }
  exit 0
}

if ($Stop) {
  if ($existing) {
    $existing | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Host 'Peer node stopped.' -ForegroundColor Green
  } else {
    Write-Host 'Peer node already stopped.' -ForegroundColor Yellow
  }
  exit 0
}

# One-time genesis init for this dedicated peer datadir.
if (-not (Test-Path (Join-Path $DataDir 'geth\chaindata'))) {
  Write-Host 'Initializing local peer genesis...' -ForegroundColor Yellow
  & $NodeExe --datadir $DataDir --state.scheme hash init $Genesis | Out-Null
}

if ($existing) {
  Write-Host "Peer node already running (PID $($existing.ProcessId))." -ForegroundColor Green
  exit 0
}

$bootnodeList = @(
  'enode://05f7f1c669368d16829699b6e1ddffbd8a3fee08a1301cac33922ad05f56fd53aadbca02f326d6b1c863c560c9adf30a75b44d45e7448ebb41d9c47235204fdf@87.99.142.128:30303',
  'enode://348b5a90336ebd6be5f2910910c6870cadb8a6853820211f6a8696cb1446203a8a4fd54c9fcef39b63505bab43b8b3bd3528eb3dccdf4b62274ac191ad1e0ea0@91.99.231.217:30303'
)
$bootnodes = $bootnodeList -join ','

# Persist static/trusted peers into this local peer node config so reconnects survive restarts.
$localCfg = Join-Path $DataDir 'config.toml'
$static = ($bootnodeList | ForEach-Object { '"' + $_ + '"' }) -join ",`n  "
$cfgText = @(
  '[Node.P2P]'
  'StaticNodes = ['
  '  ' + $static
  ']'
  'TrustedNodes = ['
  '  ' + $static
  ']'
) -join "`n"
Set-Content -Path $localCfg -Value $cfgText -Encoding ascii

$args = @(
  '--datadir', ('"' + $DataDir + '"'),
  '--config', ('"' + $localCfg + '"'),
  '--networkid', '20482',
  '--syncmode', 'full',
  '--state.scheme', 'hash',
  '--cache', '256',
  '--maxpeers', '30',
  '--port', $P2PPort,
  '--http', '--http.addr', '127.0.0.1', '--http.port', $RpcPort,
  '--http.api', 'eth,net,web3,admin,debug,ethash',
  '--http.corsdomain', '*', '--http.vhosts', '*',
  '--bootnodes', ('"' + $bootnodes + '"'),
  '--verbosity', '3'
)

Write-Host 'Starting local peer node (no mining, node-only)...' -ForegroundColor Cyan
$proc = Start-Process -FilePath $NodeExe -ArgumentList $args -WindowStyle Hidden -RedirectStandardError $NodeLog -PassThru
Write-Host "Peer node started. PID: $($proc.Id)" -ForegroundColor Green
Write-Host "RPC: http://127.0.0.1:$RpcPort" -ForegroundColor Green
Write-Host "P2P: $P2PPort" -ForegroundColor Green
Write-Host "Log: $NodeLog" -ForegroundColor DarkGray

# Geth writes logs to stderr (redirected to node.log above), so the node's own
# window is always blank. Open a live tail window so logs are visible.
$tailRunning = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*ETHII Local Peer Node Logs*' }
if (-not $tailRunning) {
  $tailCmd = "`$Host.UI.RawUI.WindowTitle = 'ETHII Local Peer Node Logs'; Get-Content -Path '$NodeLog' -Wait -Tail 50"
  Start-Process powershell -ArgumentList '-NoExit', '-Command', $tailCmd
}

# Seed peers immediately so the local peer does not sit at block 0 waiting for discovery.
Start-Sleep -Seconds 2
foreach ($en in $bootnodeList) {
  try {
    $payload = @{ jsonrpc = '2.0'; id = 1; method = 'admin_addPeer'; params = @($en) } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "http://127.0.0.1:$RpcPort" -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 3 | Out-Null
  } catch {}
  try {
    $payload = @{ jsonrpc = '2.0'; id = 2; method = 'admin_addTrustedPeer'; params = @($en) } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri "http://127.0.0.1:$RpcPort" -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 3 | Out-Null
  } catch {}
}

# If still at genesis shortly after startup, request sync toward current public head.
Start-Sleep -Seconds 4
try {
  $local = Invoke-RestMethod -Uri "http://127.0.0.1:$RpcPort" -Method Post -ContentType 'application/json' -Body '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":3}' -TimeoutSec 4
  if ($local.result -eq '0x0') {
    $remote = Invoke-RestMethod -Uri 'https://www.ethii.net/rpc' -Method Post -ContentType 'application/json' -Body '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":4}' -TimeoutSec 8
    $hash = $remote.result.hash
    if ($hash) {
      $payload = @{ jsonrpc = '2.0'; id = 5; method = 'debug_sync'; params = @($hash) } | ConvertTo-Json -Compress
      Invoke-RestMethod -Uri "http://127.0.0.1:$RpcPort" -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 6 | Out-Null
      Write-Host 'Sync nudge: debug_sync triggered from latest public head.' -ForegroundColor DarkGray
    }
  }
} catch {}
