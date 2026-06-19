$ErrorActionPreference = 'SilentlyContinue'
$KEY = Join-Path $env:USERPROFILE '.ssh\ethii_vps'

function RpcHex([string]$url, [string]$method, [int]$id) {
  $body = @{ jsonrpc = '2.0'; method = $method; params = @(); id = $id } | ConvertTo-Json -Compress
  return (Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 5).result
}

function Probe-Local {
  Write-Host '=== LOCAL-PC ===' -ForegroundColor Cyan
  try {
    $block = RpcHex 'http://127.0.0.1:8555' 'eth_blockNumber' 1
    $peers = RpcHex 'http://127.0.0.1:8555' 'net_peerCount' 2
    Write-Host "block=$block peers=$peers rpc=ok"
  } catch {
    Write-Host 'block=? peers=? rpc=fail'
  }
}

function Probe-Vps([string]$remoteHost, [string]$label) {
  Write-Host "=== $label ===" -ForegroundColor Cyan
  $jsonBlock = '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
  $jsonPeers = '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":2}'
  $b64Block = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($jsonBlock))
  $b64Peers = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($jsonPeers))

  $node = (ssh -i $KEY root@$remoteHost "systemctl is-active ethii-node 2>/dev/null || true") -join ''
  $stratum = (ssh -i $KEY root@$remoteHost "systemctl is-active ethii-stratum 2>/dev/null || true") -join ''
  $blockResp = (ssh -i $KEY root@$remoteHost "echo $b64Block | base64 -d | curl -sS -H 'Content-Type: application/json' --data @- http://127.0.0.1:8545") -join ''
  $peerResp = (ssh -i $KEY root@$remoteHost "echo $b64Peers | base64 -d | curl -sS -H 'Content-Type: application/json' --data @- http://127.0.0.1:8545") -join ''

  $block = ''
  $peers = ''
  try { $block = (($blockResp | ConvertFrom-Json).result) } catch {}
  try { $peers = (($peerResp | ConvertFrom-Json).result) } catch {}

  if (-not $block) { $block = '?' }
  if (-not $peers) { $peers = '?' }
  if (-not $node) { $node = '?' }
  if (-not $stratum) { $stratum = '?' }

  Write-Host "block=$block peers=$peers node=$node stratum=$stratum"
}

Probe-Local
Probe-Vps '87.99.142.128' 'VPS-POOL-87'
Probe-Vps '91.99.231.217' 'VPS-TRUTH-91'
