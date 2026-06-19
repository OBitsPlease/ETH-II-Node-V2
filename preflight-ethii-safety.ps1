$ErrorActionPreference = 'Stop'

$ExpectedNetVersion = '20482'
$ExpectedGenesisHash = '0xce9eec5ec053f791d5f833e7d385a1fd214daa85928ecbaba04381fd1b16b1f2'
$KeyPath = Join-Path $env:USERPROFILE '.ssh\ethii_vps'

function Get-JsonRpcResult {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Method,
        [object[]]$Params = @(),
        [int]$Id = 1,
        [int]$TimeoutSec = 8
    )
    $body = @{ jsonrpc = '2.0'; method = $Method; params = $Params; id = $Id } | ConvertTo-Json -Compress
    $resp = Invoke-RestMethod -Uri $Url -Method Post -ContentType 'application/json' -Body $body -TimeoutSec $TimeoutSec
    return $resp.result
}

function Get-RemoteJsonRpcResult {
    param(
        [Parameter(Mandatory = $true)][string]$RemoteHost,
        [Parameter(Mandatory = $true)][string]$Method,
        [object[]]$Params = @(),
        [int]$Id = 1
    )

    $payload = @{ jsonrpc = '2.0'; method = $Method; params = $Params; id = $Id } | ConvertTo-Json -Compress
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $cmd = "echo $b64 | base64 -d | curl -sS -H 'Content-Type: application/json' --data @- http://127.0.0.1:8545"
    $raw = ssh -i $KeyPath "root@$RemoteHost" $cmd
    if (-not $raw) { throw "No RPC output from $RemoteHost" }
    $obj = $raw | ConvertFrom-Json
    return $obj.result
}

function Validate-Endpoint {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$NetVersion,
        [Parameter(Mandatory = $true)][string]$GenesisHash
    )

    $ok = $true
    if ($NetVersion -ne $ExpectedNetVersion) {
        Write-Host "$Name net_version FAIL: $NetVersion (expected $ExpectedNetVersion)" -ForegroundColor Red
        $ok = $false
    } else {
        Write-Host "$Name net_version OK: $NetVersion" -ForegroundColor Green
    }

    if ($GenesisHash.ToLowerInvariant() -ne $ExpectedGenesisHash.ToLowerInvariant()) {
        Write-Host "$Name genesis FAIL: $GenesisHash (expected $ExpectedGenesisHash)" -ForegroundColor Red
        $ok = $false
    } else {
        Write-Host "$Name genesis OK: $GenesisHash" -ForegroundColor Green
    }

    return $ok
}

Write-Host 'Running ETHII safety preflight...' -ForegroundColor Cyan

$allOk = $true

try {
    $localNet = Get-JsonRpcResult -Url 'http://127.0.0.1:8555' -Method 'net_version' -Id 1
    $localGenesis = Get-JsonRpcResult -Url 'http://127.0.0.1:8555' -Method 'eth_getBlockByNumber' -Params @('0x0', $false) -Id 2
    $allOk = (Validate-Endpoint -Name 'LOCAL' -NetVersion $localNet -GenesisHash $localGenesis.hash) -and $allOk
} catch {
    Write-Host "LOCAL check WARN: $($_.Exception.Message)" -ForegroundColor Yellow
}

try {
    $poolNet = Get-RemoteJsonRpcResult -RemoteHost '87.99.142.128' -Method 'net_version' -Id 3
    $poolGenesis = Get-RemoteJsonRpcResult -RemoteHost '87.99.142.128' -Method 'eth_getBlockByNumber' -Params @('0x0', $false) -Id 4
    $allOk = (Validate-Endpoint -Name 'VPS-POOL-87' -NetVersion $poolNet -GenesisHash $poolGenesis.hash) -and $allOk
} catch {
    Write-Host "VPS-POOL-87 check FAIL: $($_.Exception.Message)" -ForegroundColor Red
    $allOk = $false
}

try {
    $truthNet = Get-RemoteJsonRpcResult -RemoteHost '91.99.231.217' -Method 'net_version' -Id 5
    $truthGenesis = Get-RemoteJsonRpcResult -RemoteHost '91.99.231.217' -Method 'eth_getBlockByNumber' -Params @('0x0', $false) -Id 6
    $allOk = (Validate-Endpoint -Name 'VPS-TRUTH-91' -NetVersion $truthNet -GenesisHash $truthGenesis.hash) -and $allOk
} catch {
    Write-Host "VPS-TRUTH-91 check FAIL: $($_.Exception.Message)" -ForegroundColor Red
    $allOk = $false
}

if (-not $allOk) {
    Write-Host 'SAFETY PREFLIGHT FAILED. Do not perform VPS write actions.' -ForegroundColor Red
    exit 2
}

Write-Host 'SAFETY PREFLIGHT PASSED.' -ForegroundColor Green
exit 0
