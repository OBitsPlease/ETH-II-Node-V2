param(
  [string]$VpsHost = "91.99.231.217",
  [string]$User = "root",
  [string]$KeyPath = "$env:USERPROFILE\.ssh\ethii_vps",
  [string]$DataDir = "/root/ethii-data",
  [string]$GenesisPath = "/root/genesis.json",
  [string]$EthiiBin = "/root/ethii"
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupScript = Join-Path $ScriptRoot "backup-vps-premaintenance.ps1"

if (-not (Test-Path $BackupScript)) {
  throw "Required backup script not found: $BackupScript"
}

Write-Host "Creating mandatory VPS backup before chain reset..." -ForegroundColor Yellow
powershell -ExecutionPolicy Bypass -File $BackupScript -VpsHost $VpsHost -User $User -KeyPath $KeyPath
if ($LASTEXITCODE -ne 0) {
  throw "Pre-reset VPS backup failed. Reset canceled."
}

Write-Host "Resetting VPS chain state and reinitializing genesis..." -ForegroundColor Yellow
$cmd = @(
  "set -e"
  "systemctl stop ethii-node.service || true"
  "rm -rf $DataDir/geth/chaindata $DataDir/geth/triedb $DataDir/geth/blobpool $DataDir/geth/nodes $DataDir/geth/transactions.rlp $DataDir/geth/LOCK"
  "$EthiiBin --datadir $DataDir init $GenesisPath"
  "systemctl start ethii-node.service"
  "systemctl is-active ethii-node.service"
) -join "; "

ssh -i $KeyPath "$User@$VpsHost" $cmd
if ($LASTEXITCODE -ne 0) {
  throw "VPS reset command failed."
}
