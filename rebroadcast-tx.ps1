$ErrorActionPreference = 'Stop'
$tx = '0xac718e57d9d8cc6baf6e16912a6bdfa231f43bed8e078b948529815e1809ddbb'
$key = Join-Path $env:USERPROFILE '.ssh\ethii_vps'

function Invoke-Rpc {
  param([string]$Url,[string]$Method,[object[]]$Params)
  $body = @{ jsonrpc='2.0'; id=1; method=$Method; params=$Params } | ConvertTo-Json -Compress
  Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 10
}

$rawResp = Invoke-Rpc -Url 'https://ethii.net/rpc' -Method 'eth_getRawTransactionByHash' -Params @($tx)
if (-not $rawResp.result) { throw 'No raw tx returned by public RPC.' }
$raw = $rawResp.result
Write-Host "raw tx bytes (hex chars): $($raw.Length)"

$send = @{ jsonrpc='2.0'; id=7; method='eth_sendRawTransaction'; params=@($raw) } | ConvertTo-Json -Compress
$get  = @{ jsonrpc='2.0'; id=8; method='eth_getTransactionByHash'; params=@($tx) } | ConvertTo-Json -Compress
$rc   = @{ jsonrpc='2.0'; id=9; method='eth_getTransactionReceipt'; params=@($tx) } | ConvertTo-Json -Compress
$bs = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($send))
$bg = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($get))
$br = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rc))

$cmd = "echo $bs | base64 -d | curl -sS -H 'Content-Type: application/json' --data @- http://127.0.0.1:8545; echo; " +
       "echo $bg | base64 -d | curl -sS -H 'Content-Type: application/json' --data @- http://127.0.0.1:8545; echo; " +
       "echo $br | base64 -d | curl -sS -H 'Content-Type: application/json' --data @- http://127.0.0.1:8545; echo"

ssh -i $key root@87.99.142.128 $cmd
