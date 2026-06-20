param(
  [string]$RpcUrl,
  [string]$RemoteRpcUrl = "http://87.99.142.128:8545",
  [string]$SecondaryRemoteRpcUrl = "http://91.99.231.217:8545"
)

$ErrorActionPreference = "Stop"

function Invoke-Rpc {
  param(
    [string]$Url,
    [string]$Method,
    [object[]]$Params = @(),
    [int]$TimeoutSec = 5
  )

  $body = @{
    jsonrpc = "2.0"
    method  = $Method
    params  = $Params
    id      = 1
  } | ConvertTo-Json -Compress

  return Invoke-RestMethod -Uri $Url -Method Post -Body $body -ContentType "application/json" -TimeoutSec $TimeoutSec
}

function ConvertFrom-HexToInt64 {
  param([string]$Hex)
  if ([string]::IsNullOrWhiteSpace($Hex)) { return $null }
  return [Convert]::ToInt64($Hex, 16)
}

if (-not $RpcUrl) {
  $portFile = Join-Path $PSScriptRoot "wallet\rpc-port.txt"
  $port = "8545"
  if (Test-Path $portFile) {
    $content = (Get-Content $portFile -Raw).Trim()
    if ($content) { $port = $content }
  }
  $RpcUrl = "http://127.0.0.1:$port"
}

Write-Host "ETHII Node Health Check" -ForegroundColor Cyan
Write-Host "Local RPC : $RpcUrl"
Write-Host "Remote RPC: $RemoteRpcUrl"
Write-Host ""

try {
  $client = (Invoke-Rpc -Url $RpcUrl -Method "web3_clientVersion").result
  $chainIdHex = (Invoke-Rpc -Url $RpcUrl -Method "eth_chainId").result
  $syncing = (Invoke-Rpc -Url $RpcUrl -Method "eth_syncing").result
  $peerHex = (Invoke-Rpc -Url $RpcUrl -Method "net_peerCount").result
  $blockHex = (Invoke-Rpc -Url $RpcUrl -Method "eth_blockNumber").result
  $hashrateHex = (Invoke-Rpc -Url $RpcUrl -Method "miner_hashrate").result

  $nodeInfo = (Invoke-Rpc -Url $RpcUrl -Method "admin_nodeInfo").result
  $cfg = $nodeInfo.protocols.eth.config

  $chainIdDec = ConvertFrom-HexToInt64 $chainIdHex
  $peerCount = ConvertFrom-HexToInt64 $peerHex
  $blockNum = ConvertFrom-HexToInt64 $blockHex
  $hashrate = ConvertFrom-HexToInt64 $hashrateHex

  Write-Host "Client               : $client"
  Write-Host "Chain ID             : $chainIdDec ($chainIdHex)"
  Write-Host "Block Height         : $blockNum ($blockHex)"
  Write-Host "Peer Count           : $peerCount ($peerHex)"
  Write-Host "Syncing              : $syncing"
  Write-Host "Local CPU Hashrate   : $hashrate ($hashrateHex)"
  Write-Host "TerminalTotalDiff    : $($cfg.terminalTotalDifficulty)"
  Write-Host "TTD Passed           : $($cfg.terminalTotalDifficultyPassed)"
  Write-Host ""

  if ($chainIdDec -eq 20482) {
    Write-Host "PASS: chainId is 20482." -ForegroundColor Green
  } else {
    Write-Host "WARN: chainId is not 20482." -ForegroundColor Yellow
  }

  if ($peerCount -gt 0) {
    Write-Host "PASS: at least one peer connected." -ForegroundColor Green
  } else {
    Write-Host "WARN: no peers connected yet." -ForegroundColor Yellow
  }

  if ($syncing -eq $false) {
    Write-Host "PASS: node reports fully synced." -ForegroundColor Green
  } else {
    Write-Host "WARN: node still syncing." -ForegroundColor Yellow
  }

  if ($hashrate -eq 0) {
    Write-Host "PASS: local CPU mining is OFF." -ForegroundColor Green
  } else {
    Write-Host "WARN: local mining hashrate is non-zero." -ForegroundColor Yellow
  }

  if ($cfg.terminalTotalDifficulty) {
    Write-Host "WARN: merge/beacon mode flag detected in chain config." -ForegroundColor Yellow
  } else {
    Write-Host "PASS: no merge TTD configured (pure PoW mode)." -ForegroundColor Green
  }

  try {
    $remoteUrls = @($RemoteRpcUrl, $SecondaryRemoteRpcUrl, "https://www.ethii.net/rpc") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    $remoteBlockHex = $null
    $remoteUrlUsed = $null
    foreach ($candidate in $remoteUrls) {
      try {
        $candidateBlockHex = (Invoke-Rpc -Url $candidate -Method "eth_blockNumber" -TimeoutSec 8).result
        if ($candidateBlockHex) {
          $remoteBlockHex = $candidateBlockHex
          $remoteUrlUsed = $candidate
          break
        }
      } catch { }
    }
    if (-not $remoteBlockHex) {
      throw "all remote RPC candidates failed"
    }
    $remoteBlock = ConvertFrom-HexToInt64 $remoteBlockHex
    Write-Host ""
    Write-Host "Remote Source        : $remoteUrlUsed"
    Write-Host "Remote Height        : $remoteBlock ($remoteBlockHex)"
    if ((-not [object]::ReferenceEquals($remoteBlock, $null)) -and (-not [object]::ReferenceEquals($blockNum, $null))) {
      $delta = $remoteBlock - $blockNum
      Write-Host "Height Delta         : $delta"
      if ([Math]::Abs($delta) -le 5) {
        Write-Host "PASS: local height is close to remote." -ForegroundColor Green
      } else {
        Write-Host "WARN: local height differs from remote by more than 5 blocks." -ForegroundColor Yellow
      }
    }
  } catch {
    Write-Host ""
    Write-Host "WARN: could not query remote RPC: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}
catch {
  Write-Host "ERROR: health check failed: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
