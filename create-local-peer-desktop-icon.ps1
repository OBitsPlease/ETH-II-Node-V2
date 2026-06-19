$ErrorActionPreference = 'Stop'
$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'ETHII Local Peer Node.lnk'
$targetBat = Join-Path $RootDir 'launch-local-peer-node.bat'
$iconCandidate = Join-Path $RootDir 'wallet\assets\ethii-logo.png'

if (-not (Test-Path $targetBat)) {
  throw "Launcher not found: $targetBat"
}

$wsh = New-Object -ComObject WScript.Shell
$sc = $wsh.CreateShortcut($shortcutPath)
$sc.TargetPath = $targetBat
$sc.WorkingDirectory = $RootDir
$sc.Description = 'Start ETHII local peer node (node-only)'
if (Test-Path $iconCandidate) {
  $sc.IconLocation = $iconCandidate
}
$sc.Save()

Write-Host "Desktop shortcut created: $shortcutPath" -ForegroundColor Green
