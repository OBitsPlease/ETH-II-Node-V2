param(
  [string]$RegistryPath = (Join-Path $PSScriptRoot 'operator-registry.json')
)

$ErrorActionPreference = 'Stop'

function Get-Registry {
  if (-not (Test-Path $RegistryPath)) {
    return @{ operators = @(); lastUpdatedUtc = '' }
  }
  $raw = Get-Content -Raw -Path $RegistryPath
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return @{ operators = @(); lastUpdatedUtc = '' }
  }
  return ($raw | ConvertFrom-Json -Depth 8)
}

function Save-Registry($reg) {
  $reg.lastUpdatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  $reg | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $RegistryPath
}

function New-OperatorId($reg) {
  $max = 0
  foreach ($o in $reg.operators) {
    if ($o.operatorId -match '^OP-(\d+)$') {
      $n = [int]$Matches[1]
      if ($n -gt $max) { $max = $n }
    }
  }
  return ('OP-{0:D4}' -f ($max + 1))
}

function Add-Operator($reg) {
  $handle = Read-Host 'Contact handle (Discord/Telegram/email)'
  if ([string]::IsNullOrWhiteSpace($handle)) { Write-Host 'Handle is required.' -ForegroundColor Yellow; return }
  $purpose = Read-Host 'Purpose (peer-support or pool-operator)'
  if ([string]::IsNullOrWhiteSpace($purpose)) { $purpose = 'peer-support' }

  $id = New-OperatorId $reg
  $entry = [ordered]@{
    operatorId = $id
    handle = $handle.Trim()
    purpose = $purpose.Trim()
    status = 'approved'
    firstSeenUtc = ''
    publicIp = ''
    enode = ''
    chainNetVersion = ''
    chainId = ''
    genesisHash = ''
    notes = ''
  }
  $reg.operators += $entry
  Save-Registry $reg
  Write-Host "Added $id" -ForegroundColor Green
}

function Record-CheckIn($reg) {
  $id = Read-Host 'Operator ID (example OP-0001)'
  $op = $reg.operators | Where-Object { $_.operatorId -eq $id } | Select-Object -First 1
  if (-not $op) { Write-Host 'Operator ID not found.' -ForegroundColor Yellow; return }

  $ip = Read-Host 'Public IP'
  $enode = Read-Host 'Enode'
  $netv = Read-Host 'net_version (expected 20482)'
  $cid = Read-Host 'eth_chainId (expected 0x800)'
  $gen = Read-Host 'genesis hash'

  $op.publicIp = $ip.Trim()
  $op.enode = $enode.Trim()
  $op.chainNetVersion = $netv.Trim()
  $op.chainId = $cid.Trim()
  $op.genesisHash = $gen.Trim()
  if ([string]::IsNullOrWhiteSpace($op.firstSeenUtc)) {
    $op.firstSeenUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  }

  if ($op.chainNetVersion -ne '20482' -or $op.chainId -ne '0x800' -or $op.genesisHash -ne '0x6836fa7f7ddaf5807ff48b4eb9f4fd63ceaf33d52ae419349bd72b85dd34f8bf') {
    $op.status = 'quarantine'
    $op.notes = 'Auto-quarantined: chain identity mismatch'
    Write-Host 'WARNING: chain mismatch, operator quarantined.' -ForegroundColor Red
  } else {
    if ($op.status -eq 'approved' -or $op.status -eq 'quarantine') { $op.status = 'active' }
    Write-Host 'Check-in recorded and validated.' -ForegroundColor Green
  }

  Save-Registry $reg
}

function Set-OperatorStatus($reg) {
  $id = Read-Host 'Operator ID'
  $op = $reg.operators | Where-Object { $_.operatorId -eq $id } | Select-Object -First 1
  if (-not $op) { Write-Host 'Operator ID not found.' -ForegroundColor Yellow; return }
  $status = Read-Host 'New status (approved|active|paused|blocked|quarantine)'
  if ($status -notin @('approved','active','paused','blocked','quarantine')) {
    Write-Host 'Invalid status.' -ForegroundColor Yellow
    return
  }
  $op.status = $status
  $op.notes = Read-Host 'Notes (optional)'
  Save-Registry $reg
  Write-Host 'Status updated.' -ForegroundColor Green
}

function List-Operators($reg) {
  if (-not $reg.operators -or $reg.operators.Count -eq 0) {
    Write-Host 'No operators recorded yet.' -ForegroundColor Yellow
    return
  }
  $reg.operators |
    Sort-Object operatorId |
    Select-Object operatorId, handle, purpose, status, publicIp, firstSeenUtc |
    Format-Table -AutoSize
}

function Export-Csv($reg) {
  $out = Join-Path $PSScriptRoot ('operator-registry-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
  $reg.operators | Export-Csv -Path $out -NoTypeInformation -Encoding UTF8
  Write-Host "Exported: $out" -ForegroundColor Green
}

function Show-Menu {
  Write-Host ''
  Write-Host 'ETH-II Operator Registry Manager' -ForegroundColor Cyan
  Write-Host '1) Add approved operator'
  Write-Host '2) Record startup check-in'
  Write-Host '3) Update operator status'
  Write-Host '4) List operators'
  Write-Host '5) Export CSV report'
  Write-Host '6) Exit'
}

$reg = Get-Registry
while ($true) {
  Show-Menu
  $choice = Read-Host 'Select option'
  switch ($choice) {
    '1' { Add-Operator $reg; $reg = Get-Registry }
    '2' { Record-CheckIn $reg; $reg = Get-Registry }
    '3' { Set-OperatorStatus $reg; $reg = Get-Registry }
    '4' { List-Operators $reg }
    '5' { Export-Csv $reg }
    '6' { break }
    default { Write-Host 'Invalid option.' -ForegroundColor Yellow }
  }
}
