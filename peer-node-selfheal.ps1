$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Launcher = Join-Path $Root 'launch-local-peer-node.ps1'
$StateDir = Join-Path $env:LOCALAPPDATA 'ETHII\Peer-Node'
$StateFile = Join-Path $StateDir 'selfheal-state.json'

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

if (-not (Test-Path $Launcher)) {
  throw "Launcher not found: $Launcher"
}

function Get-State {
  if (Test-Path $StateFile) {
    try { return Get-Content $StateFile -Raw | ConvertFrom-Json } catch {}
  }
  return [pscustomobject]@{ ZeroPeerCount = 0; LastActionUtc = '1970-01-01T00:00:00Z' }
}

function Save-State($s) {
  ($s | ConvertTo-Json -Compress) | Set-Content -Path $StateFile -Encoding ascii
}

$state = Get-State
$now = [DateTime]::UtcNow
$lastAction = [DateTime]::Parse($state.LastActionUtc).ToUniversalTime()

$peerHex = $null
$blockHex = $null
$rpcOk = $false
try {
  $peerHex = (Invoke-RestMethod -Uri 'http://127.0.0.1:8555' -Method Post -ContentType 'application/json' -Body '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' -TimeoutSec 4).result
  $blockHex = (Invoke-RestMethod -Uri 'http://127.0.0.1:8555' -Method Post -ContentType 'application/json' -Body '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":2}' -TimeoutSec 4).result
  $rpcOk = $true
} catch {
  $rpcOk = $false
}

$shouldHeal = $false
if (-not $rpcOk) {
  $shouldHeal = $true
} else {
  $peerCount = [Convert]::ToInt32(($peerHex -replace '^0x',''),16)
  if ($peerCount -le 0) {
    $state.ZeroPeerCount = [int]$state.ZeroPeerCount + 1
  } else {
    $state.ZeroPeerCount = 0
  }
  if ($state.ZeroPeerCount -ge 3) { $shouldHeal = $true }
}

$cooldownOk = (($now - $lastAction).TotalMinutes -ge 10)
if ($shouldHeal -and $cooldownOk) {
  powershell -NoProfile -ExecutionPolicy Bypass -File $Launcher -Stop | Out-Null
  Start-Sleep -Seconds 2
  powershell -NoProfile -ExecutionPolicy Bypass -File $Launcher | Out-Null
  $state.LastActionUtc = [DateTime]::UtcNow.ToString('o')
  $state.ZeroPeerCount = 0
}

Save-State $state
