param(
  [string[]]$VpsHosts = @("87.99.142.128", "91.99.231.217"),
  [string]$User = "root",
  [string]$KeyPath = "$env:USERPROFILE\.ssh\ethii_vps",
  [string]$LocalRpcUrl = "http://127.0.0.1:8545",
  [string[]]$VpsEnodes = @(
    "enode://05f7f1c669368d16829699b6e1ddffbd8a3fee08a1301cac33922ad05f56fd53aadbca02f326d6b1c863c560c9adf30a75b44d45e7448ebb41d9c47235204fdf@87.99.142.128:30303",
    "enode://b096bfae7d5e9a7cc985e68726280b75b0a0ef80ce419db5ed5152e9bee7bf83d35ae8b13b34879a0bf36d73a9a674bb61b02f3777745ed770e3150a39c7de5b@91.99.231.217:30303"
  ),
  [string]$NodeLog = ""
)

$ErrorActionPreference = "Stop"

function Write-Status {
  param(
    [string]$Message,
    [string]$Level = "INFO"
  )

  $line = "[sync-vps-peer][$Level] $Message"
  Write-Host $line
  if ($NodeLog -and (Test-Path (Split-Path $NodeLog -Parent))) {
    try { Add-Content -Path $NodeLog -Value $line -ErrorAction SilentlyContinue } catch { }
  }
}

function Invoke-JsonRpc {
  param(
    [string]$Url,
    [string]$Method,
    [object[]]$Params = @(),
    [int]$TimeoutSec = 6
  )

  $body = @{ jsonrpc = "2.0"; method = $Method; params = $Params; id = 1 } | ConvertTo-Json -Compress
  return Invoke-RestMethod -Uri $Url -Method POST -Body $body -ContentType "application/json" -TimeoutSec $TimeoutSec
}

function ConvertFrom-LooseJson {
  param(
    [string]$Text
  )

  if ([string]::IsNullOrWhiteSpace($Text)) {
    throw "Empty JSON input."
  }

  $start = $Text.IndexOf('{')
  $end = $Text.LastIndexOf('}')
  if ($start -lt 0 -or $end -lt 0 -or $end -lt $start) {
    throw "No JSON object found in input."
  }

  $json = $Text.Substring($start, $end - $start + 1)
  return $json | ConvertFrom-Json
}

if (-not (Test-Path $KeyPath)) {
  throw "SSH key not found at $KeyPath"
}

$hostTokens = @()
foreach ($entry in $VpsHosts) {
  if ([string]::IsNullOrWhiteSpace($entry)) { continue }
  $hostTokens += ($entry -split ',')
}
$VpsHosts = @($hostTokens | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
$VpsEnodes = @($VpsEnodes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

if ($VpsHosts.Count -eq 0) {
  throw "No VPS hosts configured."
}

Write-Status "Starting local/VPS peer synchronization for hosts: $($VpsHosts -join ', ')."

$localNodeInfo = Invoke-JsonRpc -Url $LocalRpcUrl -Method "admin_nodeInfo"
$localEnode = [string]$localNodeInfo.result.enode
if ([string]::IsNullOrWhiteSpace($localEnode)) {
  throw "Could not read local enode from $LocalRpcUrl"
}

$localExternalIp = ""
try {
  $localExternalIp = [string](Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 5)
} catch { }

$localEnodeForVps = $localEnode
if ($localExternalIp) {
  $localEnodeForVps = ($localEnodeForVps -replace '@[^:]+:', ("@{0}:" -f $localExternalIp))
}

$localAddCount = 0
foreach ($vpsEnode in $VpsEnodes) {
  try {
    $addLocalPeer = Invoke-JsonRpc -Url $LocalRpcUrl -Method "admin_addPeer" -Params @($vpsEnode)
    Write-Status "Local -> seed addPeer result ($vpsEnode): $($addLocalPeer.result)"
    $localAddCount++
  } catch {
    Write-Status "Local -> seed addPeer failed ($vpsEnode): $($_.Exception.Message)" "WARN"
  }
}

if ($localAddCount -eq 0) {
  Write-Status "No local seed addPeer calls succeeded." "WARN"
}

foreach ($vpsHost in $VpsHosts) {
  $remoteAddPayload = '{"jsonrpc":"2.0","method":"admin_addPeer","params":["' + $localEnodeForVps + '"],"id":1}'
  $remoteAddCmd = "printf '%s' '$remoteAddPayload' | curl -sS --max-time 6 -H 'Content-Type: application/json' --data @- http://127.0.0.1:8545"
  $remoteAddRaw = ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -i $KeyPath "${User}@${vpsHost}" $remoteAddCmd
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($remoteAddRaw)) {
    try {
      $remoteAdd = ConvertFrom-LooseJson -Text $remoteAddRaw
      Write-Status "${vpsHost} -> Local addPeer result: $($remoteAdd.result)"
    } catch {
      Write-Status "${vpsHost} addPeer returned non-JSON output." "WARN"
    }
  } else {
    Write-Status "Could not request ${vpsHost} -> Local peer add (possibly NAT/firewall)." "WARN"
  }
}

try {
  $localPeers = Invoke-JsonRpc -Url $LocalRpcUrl -Method "net_peerCount"
  Write-Status "Local peerCount now: $($localPeers.result)"
} catch {
  Write-Status "Could not read local peerCount after sync." "WARN"
}

Write-Status "Peer synchronization finished." "OK"