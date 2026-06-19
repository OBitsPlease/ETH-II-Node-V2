$ErrorActionPreference = 'Stop'

$sourceAsar = 'C:\Users\tourj\ETHII ETH2\tmp\live-wallet-patched.asar'
$targetAsar = 'C:\Program Files\ETH II Wallet\resources\app.asar'
$backupAsar = 'C:\Program Files\ETH II Wallet\resources\app.asar.bak-hotfix-20260609'

if (-not (Test-Path $sourceAsar)) { throw "Missing source: $sourceAsar" }
if (-not (Test-Path $targetAsar)) { throw "Missing target: $targetAsar" }

Get-Process 'ETH II Wallet' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

if (-not (Test-Path $backupAsar)) {
  Copy-Item -Path $targetAsar -Destination $backupAsar -Force
}
Copy-Item -Path $sourceAsar -Destination $targetAsar -Force

$srcHash = (Get-FileHash $sourceAsar -Algorithm SHA256).Hash
$dstHash = (Get-FileHash $targetAsar -Algorithm SHA256).Hash
Write-Host "source hash: $srcHash"
Write-Host "target hash: $dstHash"

Start-Process -FilePath 'C:\Program Files\ETH II Wallet\ETH II Wallet.exe'
Write-Host 'Wallet hotfix installed and wallet relaunched.'
