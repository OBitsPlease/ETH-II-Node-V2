param(
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WalletDir = Join-Path $RootDir 'wallet'
$WalletLauncher = Join-Path $WalletDir 'launch-wallet.bat'
$SuiteLauncher = Join-Path $WalletDir 'launch-node.bat'
$IconPath = Join-Path $WalletDir 'assets\ethii2.ico'
if (-not (Test-Path $IconPath)) {
  $IconPath = Join-Path $WalletDir 'assets\ethii.ico'
}

$desktop = [Environment]::GetFolderPath('Desktop')
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$locations = @($desktop, $startMenu)

$wsh = New-Object -ComObject WScript.Shell

function Set-Shortcut {
  param(
    [string]$Folder,
    [string]$Name,
    [string]$Target,
    [string]$WorkingDir,
    [string]$Icon
  )

  if (-not (Test-Path $Folder)) {
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
  }

  $lnkPath = Join-Path $Folder ($Name + '.lnk')
  $shortcut = $wsh.CreateShortcut($lnkPath)
  $shortcut.TargetPath = $Target
  $shortcut.WorkingDirectory = $WorkingDir
  $shortcut.Arguments = ''
  if ($Icon -and (Test-Path $Icon)) {
    $shortcut.IconLocation = "$Icon,0"
  }
  $shortcut.Save()

  if (-not $Quiet) {
    Write-Host "Shortcut repaired: $lnkPath" -ForegroundColor Green
  }
}

if (-not (Test-Path $WalletLauncher)) {
  throw "Missing wallet launcher: $WalletLauncher"
}
if (-not (Test-Path $SuiteLauncher)) {
  throw "Missing suite launcher: $SuiteLauncher"
}

foreach ($folder in $locations) {
  Set-Shortcut -Folder $folder -Name 'ETHII Wallet' -Target $WalletLauncher -WorkingDir $WalletDir -Icon $IconPath
  Set-Shortcut -Folder $folder -Name 'ETH II Wallet' -Target $WalletLauncher -WorkingDir $WalletDir -Icon $IconPath
  Set-Shortcut -Folder $folder -Name 'ETHII Miner Suite' -Target $SuiteLauncher -WorkingDir $WalletDir -Icon $IconPath
}

if (-not $Quiet) {
  Write-Host 'ETHII shortcuts are up to date.' -ForegroundColor Cyan
}
