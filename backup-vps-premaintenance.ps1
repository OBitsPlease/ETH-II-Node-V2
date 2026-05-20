param(
  [string]$VpsHost = "91.99.231.217",
  [string]$User = "root",
  [string]$KeyPath = "$env:USERPROFILE\.ssh\ethii_vps",
  [int]$KeepCount = 10,
  [switch]$NoStopService
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupStatusFile = Join-Path $ScriptRoot "BACKUPS\LATEST-BACKUPS.txt"

if (-not (Test-Path $KeyPath)) {
  throw "SSH key not found at $KeyPath"
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$stopService = if ($NoStopService) { "false" } else { "true" }
$keepFrom = [int]$KeepCount + 1
$sshTarget = "$User@$VpsHost"
$remoteTmpPath = "/tmp/ethii-premaintenance-$timestamp.sh"
$localTmpPath = Join-Path $env:TEMP "ethii-premaintenance-$timestamp.sh"

$remoteScript = @"
#!/usr/bin/env bash
set -euo pipefail

BK="/root/ethii-backups/PRE-MAINT-$timestamp"
mkdir -p "`$BK"
WAS_ACTIVE=false

if [ "$stopService" = "true" ]; then
  if systemctl is-active --quiet ethii-node.service; then
    WAS_ACTIVE=true
  fi
  systemctl stop ethii-node.service || true
fi

[ -f /root/ethii ] && cp -a /root/ethii "`$BK/ethii.bin" || true
[ -f /etc/systemd/system/ethii-node.service ] && cp -a /etc/systemd/system/ethii-node.service "`$BK/ethii-node.service" || true
[ -f /root/genesis.json ] && cp -a /root/genesis.json "`$BK/genesis.json" || true
[ -f /root/start-miner.sh ] && cp -a /root/start-miner.sh "`$BK/start-miner.sh" || true

[ -d /root/ethii-data/geth/chaindata ] && tar -C /root/ethii-data/geth -czf "`$BK/chaindata.tar.gz" chaindata || true
[ -d /root/ethii-data/geth/triedb ] && tar -C /root/ethii-data/geth -czf "`$BK/triedb.tar.gz" triedb || true
[ -d /root/ethii-data/geth/blobpool ] && tar -C /root/ethii-data/geth -czf "`$BK/blobpool.tar.gz" blobpool || true
[ -d /root/ethii-data/geth/nodes ] && tar -C /root/ethii-data/geth -czf "`$BK/nodes.tar.gz" nodes || true
[ -f /root/ethii-data/geth/nodekey ] && cp -a /root/ethii-data/geth/nodekey "`$BK/nodekey" || true
[ -f /root/ethii-data/geth/jwtsecret ] && cp -a /root/ethii-data/geth/jwtsecret "`$BK/jwtsecret" || true

if [ -d /root/ethii-backups ]; then
  BACKUP_LIST=`$(ls -1dt /root/ethii-backups/PRE-MAINT-* 2>/dev/null || true)
  if [ -n "`$BACKUP_LIST" ]; then
    echo "`$BACKUP_LIST" | tail -n +$keepFrom | xargs -r rm -rf
  fi
fi

if [ "$stopService" = "true" ] && [ "`$WAS_ACTIVE" = "true" ]; then
  systemctl start ethii-node.service || true
fi

echo "vps_backup=`$BK"
"@

Set-Content -Path $localTmpPath -Value ($remoteScript -replace "`r", "") -Encoding ASCII

function Update-BackupStatusFile {
  param(
    [string]$StatusPath,
    [string]$VpsPath
  )

  $existing = @{}
  if (Test-Path $StatusPath) {
    Get-Content $StatusPath | ForEach-Object {
      if ($_ -match "^([^=]+)=(.*)$") {
        $existing[$matches[1]] = $matches[2]
      }
    }
  }

  $existing["updated"] = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  $existing["vps_backup"] = $VpsPath
  if (-not $existing.ContainsKey("local_backup")) {
    $existing["local_backup"] = ""
  }

  @(
    "updated=" + $existing["updated"]
    "local_backup=" + $existing["local_backup"]
    "vps_backup=" + $existing["vps_backup"]
  ) | Set-Content -Path $StatusPath -Encoding ASCII
}

try {
  scp -i $KeyPath $localTmpPath "${sshTarget}:$remoteTmpPath"
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload remote maintenance backup script."
  }

  $sshOutput = ssh -i $KeyPath $sshTarget "chmod +x $remoteTmpPath && bash $remoteTmpPath"
  if ($LASTEXITCODE -ne 0) {
    throw "VPS backup command failed."
  }

  $vpsPath = ""
  foreach ($line in ($sshOutput | Out-String).Split("`n")) {
    if ($line.Trim() -like "vps_backup=*") {
      $vpsPath = $line.Trim().Substring("vps_backup=".Length)
    }
  }
  if ($vpsPath) {
    Update-BackupStatusFile -StatusPath $BackupStatusFile -VpsPath $vpsPath
  }

  $sshOutput
}
finally {
  Remove-Item -Path $localTmpPath -Force -ErrorAction SilentlyContinue
  ssh -i $KeyPath $sshTarget "rm -f $remoteTmpPath" | Out-Null
}
