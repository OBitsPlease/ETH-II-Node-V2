param(
  [string]$DataDir = "$env:USERPROFILE\ETHII\peer-node\data",
  [string]$Passkey = ""
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$EthiiExe = Join-Path $RepoRoot 'ethii-windows-amd64.exe'
$Genesis = Join-Path $RepoRoot 'genesis.json'
$StaticNodes = Join-Path $RepoRoot 'p2p\static-nodes.json'
$TrustedNodes = Join-Path $RepoRoot 'p2p\trusted-nodes.json'
$LogPath = Join-Path $DataDir 'peer-node.log'
$RpcUrl = 'http://127.0.0.1:8545'

if (-not (Test-Path $EthiiExe)) {
  if ([string]::IsNullOrWhiteSpace($Passkey)) {
    throw "Missing binary: $EthiiExe and no passkey provided. Please provide a passkey to download it automatically."
  }
  Write-Host "Downloading ETH-II Node binary from secure server..." -ForegroundColor Cyan
  $DlUrl = "https://www.ethii.net/dl/ethii-windows-amd64.exe?key=$Passkey"
  try {
    Invoke-WebRequest -Uri $DlUrl -OutFile $EthiiExe -UseBasicParsing
  } catch {
    throw "Failed to download node binary. Please check your passkey and internet connection. Error: $_"
  }
  Write-Host "Download complete!" -ForegroundColor Green
}

if (-not (Test-Path $Genesis)) { throw "Missing genesis.json" }
if (-not (Test-Path $StaticNodes)) { throw "Missing p2p/static-nodes.json" }
if (-not (Test-Path $TrustedNodes)) { throw "Missing p2p/trusted-nodes.json" }

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DataDir 'geth') | Out-Null

Copy-Item $StaticNodes (Join-Path $DataDir 'geth\static-nodes.json') -Force
Copy-Item $TrustedNodes (Join-Path $DataDir 'geth\trusted-nodes.json') -Force

$chainData = Join-Path $DataDir 'geth\chaindata'
if (-not (Test-Path $chainData)) {
  Write-Host 'Initializing genesis...' -ForegroundColor Yellow
  & $EthiiExe --datadir $DataDir --state.scheme hash init $Genesis
}

$existing = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '^ethii(\.exe)?$' -and $_.CommandLine -match [Regex]::Escape($DataDir) }
if ($existing) {
  Write-Host 'Peer node already running for this datadir.' -ForegroundColor Green
  Write-Host "DataDir: $DataDir"
  exit 0
}

$extIp = $null
foreach ($url in @('https://api.ipify.org','https://ifconfig.me','https://icanhazip.com')) {
  try {
    $candidate = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5).Content.Trim()
    if ($candidate -match '^\d+\.\d+\.\d+\.\d+$') { $extIp = $candidate; break }
  } catch { }
}
$natFlag = if ($extIp) { "extip:$extIp" } else { 'any' }

$args = @(
  '--datadir', $DataDir,
  '--networkid', '20482',
  '--syncmode', 'full',
  '--gcmode', 'archive',
  '--state.scheme', 'hash',
  '--http', '--http.addr', '127.0.0.1', '--http.port', '8545',
  '--http.api', 'eth,net,web3,admin,debug,ethash',
  '--http.corsdomain', '*', '--http.vhosts', '*',
  '--port', '30303',
  '--maxpeers', '50',
  '--nat', $natFlag,
  '--verbosity', '3'
)

Write-Host 'Starting peer-support node (no stratum, no pool)...' -ForegroundColor Cyan
$proc = Start-Process -FilePath $EthiiExe -ArgumentList $args -WindowStyle Minimized -RedirectStandardError $LogPath -PassThru
Write-Host "Started ethii PID: $($proc.Id)"
Write-Host "Log: $LogPath"

$rpcReady = $false
for ($i = 0; $i -lt 40; $i++) {
  Start-Sleep -Seconds 2
  try {
    $body = @{ jsonrpc='2.0'; method='eth_blockNumber'; params=@(); id=1 } | ConvertTo-Json -Compress
    $resp = Invoke-RestMethod -Uri $RpcUrl -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 3
    if ($resp.result) { $rpcReady = $true; break }
  } catch { }
}

if (-not $rpcReady) {
  Write-Warning 'RPC did not become ready in time. Check peer-node.log.'
  exit 1
}

Write-Host 'Node RPC is ready.' -ForegroundColor Green
Write-Host 'Verifying canonical chain identity...' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'verify-chain.ps1') -RpcUrl $RpcUrl
Write-Host 'Peer-support node is running.' -ForegroundColor Green
Write-Host 'This mode supports network peers only. It does not run a public pool.' -ForegroundColor Yellow
Write-Host ''
Write-Host 'Press any key to exit this window (the node will continue running in the background).' -ForegroundColor White
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
