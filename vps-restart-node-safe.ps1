param(
  [string]$VpsHost = "91.99.231.217",
  [string]$User = "root",
  [string]$KeyPath = "$env:USERPROFILE\.ssh\ethii_vps"
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupScript = Join-Path $ScriptRoot "backup-vps-premaintenance.ps1"

if (-not (Test-Path $BackupScript)) {
  throw "Required backup script not found: $BackupScript"
}

Write-Host "Creating mandatory VPS backup before restart..." -ForegroundColor Yellow
powershell -ExecutionPolicy Bypass -File $BackupScript -VpsHost $VpsHost -User $User -KeyPath $KeyPath
if ($LASTEXITCODE -ne 0) {
  throw "Pre-restart VPS backup failed. Restart canceled."
}

Write-Host "Restarting ethii-node.service on VPS..." -ForegroundColor Yellow
ssh -i $KeyPath "$User@$VpsHost" "systemctl restart ethii-node.service; systemctl is-active ethii-node.service"
if ($LASTEXITCODE -ne 0) {
  throw "VPS restart command failed."
}
