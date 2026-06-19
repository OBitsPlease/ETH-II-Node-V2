$ErrorActionPreference = 'Stop'
$src = 'C:\Users\tourj\ETHII ETH2\tmp\wallet-sendfix\live-wallet-sendfix.asar'
$dst = 'C:\Program Files\ETH II Wallet\resources\app.asar'
$bak = 'C:\Program Files\ETH II Wallet\resources\app.asar.bak-sendfix-20260610'
Get-Process 'ETH II Wallet' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1
if (-not (Test-Path $bak)) { Copy-Item $dst $bak -Force }
Copy-Item $src $dst -Force
"installed: " + (Get-FileHash $dst).Hash.Substring(0,12) | Out-File 'C:\Users\tourj\ETHII ETH2\tmp\wallet-sendfix\install-result.txt'
Start-Process 'C:\Program Files\ETH II Wallet\ETH II Wallet.exe'
