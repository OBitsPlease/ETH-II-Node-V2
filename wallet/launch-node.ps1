# ETHII Miner Suite Launcher
# Starts: Node + Stratum Proxy + Wallet GUI

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir   = Split-Path -Parent $ScriptDir
$BackupStatusFile = Join-Path $RootDir "BACKUPS\LATEST-BACKUPS.txt"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  ETHII Miner Suite - ETH 2.0 Proof of Work" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ── Paths ─────────────────────────────────────────────────────────────────────
$EthiiExe    = Join-Path $RootDir "ethii.exe"
$StratumExe  = Join-Path $RootDir "stratum.exe"
$DataDir     = Join-Path $RootDir "data"
$GenesisFile = Join-Path $ScriptDir "genesis.json"
$ElectronExe = Join-Path $ScriptDir "node_modules\electron\dist\electron.exe"
$AddrFile    = Join-Path $ScriptDir "etherbase.txt"
$InfoFile    = Join-Path $RootDir "ETHII-Mining-Info.txt"

if (-not (Test-Path $EthiiExe))    { Write-Host "ERROR: ethii.exe not found at $EthiiExe" -ForegroundColor Red; Read-Host "Press Enter to exit"; exit 1 }
if (-not (Test-Path $StratumExe))  { Write-Host "ERROR: stratum.exe not found at $StratumExe" -ForegroundColor Red; Read-Host "Press Enter to exit"; exit 1 }
if (-not (Test-Path $ElectronExe)) { Write-Host "ERROR: Electron not found at $ElectronExe" -ForegroundColor Red; Read-Host "Press Enter to exit"; exit 1 }
if (-not (Test-Path $GenesisFile)) { Write-Host "ERROR: genesis.json not found at $GenesisFile" -ForegroundColor Red; Read-Host "Press Enter to exit"; exit 1 }

# ── Ensure firewall allows inbound connections on stratum and RPC ports ────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$fwStratum = Get-NetFirewallRule -DisplayName "ETHII Stratum" -ErrorAction SilentlyContinue
$fwRpc     = Get-NetFirewallRule -DisplayName "ETHII RPC"     -ErrorAction SilentlyContinue
if (-not $fwStratum -or -not $fwRpc) {
    if ($isAdmin) {
        if (-not $fwStratum) {
            New-NetFirewallRule -DisplayName "ETHII Stratum" -Direction Inbound -Protocol TCP -LocalPort 3335 -Action Allow -Profile Any | Out-Null
            Write-Host "  Firewall: opened port 3335 (Stratum)" -ForegroundColor Green
        }
        if (-not $fwRpc) {
            New-NetFirewallRule -DisplayName "ETHII RPC" -Direction Inbound -Protocol TCP -LocalPort 8545 -Action Allow -Profile Any | Out-Null
            Write-Host "  Firewall: opened port 8545 (RPC)" -ForegroundColor Green
        }
    } else {
        Write-Host "  Firewall: adding rules requires elevation - launching elevated helper..." -ForegroundColor Yellow
        $tmpScript = [System.IO.Path]::GetTempFileName() + ".ps1"
        $fwLines = "New-NetFirewallRule -DisplayName 'ETHII Stratum' -Direction Inbound -Protocol TCP -LocalPort 3335 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null`nNew-NetFirewallRule -DisplayName 'ETHII RPC' -Direction Inbound -Protocol TCP -LocalPort 8545 -Action Allow -Profile Any -ErrorAction SilentlyContinue | Out-Null"
        Set-Content -Path $tmpScript -Value $fwLines -Encoding UTF8
        Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$tmpScript`"" -Verb RunAs -Wait -ErrorAction SilentlyContinue
        Remove-Item $tmpScript -ErrorAction SilentlyContinue
        Write-Host "  Firewall: rules applied." -ForegroundColor Green
    }
}

# ── Auto-init chain if data directory doesn't exist ──────────────────────────
if (-not (Test-Path (Join-Path $DataDir "geth\chaindata"))) {
    Write-Host "Initializing ETHII chain from genesis..." -ForegroundColor Yellow
    & $EthiiExe --datadir $DataDir "--state.scheme" hash init $GenesisFile
    if ($LASTEXITCODE -ne 0) { Write-Host "ERROR: Failed to initialize chain." -ForegroundColor Red; Read-Host "Press Enter to exit"; exit 1 }
}

# ── Kill any stale ethii/stratum processes so the datadir lock is released ─────
$stale = Get-Process -Name "ethii","stratum" -ErrorAction SilentlyContinue
if ($stale) {
    Write-Host "Stopping previous ethii/stratum processes..." -ForegroundColor Yellow
    $stale | ForEach-Object { $_.Kill(); $_.WaitForExit(3000) }
}
# Free fixed ports only if held by our own processes (ethii/stratum) so we
# don't disrupt other Ethereum nodes a miner may be running simultaneously.
foreach ($fixedPort in @(3335, 8082)) {
    $conn = Get-NetTCPConnection -LocalPort $fixedPort -ErrorAction SilentlyContinue
    if ($conn) {
        $pid_ = ($conn | Select-Object -First 1).OwningProcess
        if ($pid_ -and $pid_ -ne $PID) {
            $procName = (Get-Process -Id $pid_ -ErrorAction SilentlyContinue).Name
            if ($procName -match "ethii|stratum|electron") {
                Write-Host "  Freeing port $fixedPort (PID $pid_)..." -ForegroundColor Yellow
                Stop-Process -Id $pid_ -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
Start-Sleep -Seconds 1

function New-LocalPreLaunchBackup {
  param(
    [string]$BaseDir,
    [int]$KeepCount = 7
  )

  $backupRoot = Join-Path $BaseDir "BACKUPS\AUTO-LAUNCH"
  if (-not (Test-Path $backupRoot)) {
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
  }

  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $backupDir = Join-Path $backupRoot ("PRE-LAUNCH-" + $stamp)
  New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

  $relativeFiles = @(
    "ethii.exe",
    "stratum.exe",
    "wallet\launch-node.ps1",
    "wallet\genesis.json",
    "wallet\etherbase.txt",
    "wallet\rpc-port.txt",
    "data\geth\config.toml",
    "data\geth\nodekey",
    "data\geth\jwtsecret",
    "node.log",
    "node.out.log"
  )

  foreach ($rel in $relativeFiles) {
    $src = Join-Path $BaseDir $rel
    if (Test-Path $src) {
      $dst = Join-Path $backupDir $rel
      $dstParent = Split-Path $dst -Parent
      if (-not (Test-Path $dstParent)) {
        New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
      }
      Copy-Item -Path $src -Destination $dst -Force
    }
  }

  $relativeDirs = @(
    "data\geth\chaindata",
    "data\geth\triedb",
    "data\geth\blobpool",
    "data\geth\nodes"
  )

  foreach ($relDir in $relativeDirs) {
    $srcDir = Join-Path $BaseDir $relDir
    if (Test-Path $srcDir) {
      $dstDir = Join-Path $backupDir $relDir
      $dstParent = Split-Path $dstDir -Parent
      if (-not (Test-Path $dstParent)) {
        New-Item -ItemType Directory -Path $dstParent -Force | Out-Null
      }
      Copy-Item -Path $srcDir -Destination $dstDir -Recurse -Force
    }
  }

  $infoFile = Join-Path $backupDir "BACKUP-INFO.txt"
  @(
    "created=" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    "type=automatic pre-launch backup"
    "source=" + $BaseDir
  ) | Set-Content -Path $infoFile -Encoding ASCII

  $existing = Get-ChildItem -Path $backupRoot -Directory |
    Where-Object { $_.Name -like "PRE-LAUNCH-*" } |
    Sort-Object LastWriteTime -Descending
  if ($existing.Count -gt $KeepCount) {
    $existing | Select-Object -Skip $KeepCount | ForEach-Object {
      Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  return $backupDir
}

function Update-BackupStatusFile {
  param(
    [string]$StatusPath,
    [string]$LocalPath
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
  $existing["local_backup"] = $LocalPath
  if (-not $existing.ContainsKey("vps_backup")) {
    $existing["vps_backup"] = ""
  }

  @(
    "updated=" + $existing["updated"]
    "local_backup=" + $existing["local_backup"]
    "vps_backup=" + $existing["vps_backup"]
  ) | Set-Content -Path $StatusPath -Encoding ASCII
}

Write-Host "Creating automatic pre-launch backup..." -ForegroundColor Yellow
try {
  $autoBackupPath = New-LocalPreLaunchBackup -BaseDir $RootDir -KeepCount 7
  Update-BackupStatusFile -StatusPath $BackupStatusFile -LocalPath $autoBackupPath
  Write-Host "  Backup created: $autoBackupPath" -ForegroundColor Green
} catch {
  Write-Host "ERROR: Automatic pre-launch backup failed: $_" -ForegroundColor Red
  Write-Host "Refusing to start without a rollback point." -ForegroundColor Red
  Read-Host "Press Enter to exit"
  exit 1
}

# ── Ports ─────────────────────────────────────────────────────────────────────
# Stratum and dashboard are fixed - external miners depend on these.
# RPC and P2P scan for the first free port so we don't collide with other nodes.
function Find-FreePort([int[]]$candidates) {
    foreach ($p in $candidates) {
        $used = Get-NetTCPConnection -LocalPort $p -ErrorAction SilentlyContinue
        if (-not $used) { return $p }
    }
    return $candidates[0]
}

$RpcPort       = Find-FreePort @(8545..8555)
$P2pPort       = Find-FreePort @(30303..30313)
$StratumPort   = 3335   # Fixed - external miners (ASICs, GPUs) depend on this
$DashboardPort = 8082   # Fixed - bookmarked URL stays consistent
$BootnodeEnode = "enode://b096bfae7d5e9a7cc985e68726280b75b0a0ef80ce419db5ed5152e9bee7bf83d35ae8b13b34879a0bf36d73a9a674bb61b02f3777745ed770e3150a39c7de5b@91.99.231.217:30303"
$PublicRpcUrl = "http://91.99.231.217:8545"

# Ensure inbound P2P is open on the selected port so this node can accept peers.
$fwP2pTcpName = "ETHII P2P TCP $P2pPort"
$fwP2pUdpName = "ETHII P2P UDP $P2pPort"
if ($isAdmin) {
  if (-not (Get-NetFirewallRule -DisplayName $fwP2pTcpName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $fwP2pTcpName -Direction Inbound -Protocol TCP -LocalPort $P2pPort -Action Allow -Profile Any | Out-Null
  }
  if (-not (Get-NetFirewallRule -DisplayName $fwP2pUdpName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $fwP2pUdpName -Direction Inbound -Protocol UDP -LocalPort $P2pPort -Action Allow -Profile Any | Out-Null
  }
} else {
  Write-Host "  Firewall: P2P inbound on $P2pPort requires elevation (TCP+UDP)." -ForegroundColor Yellow
}

# Write the chosen RPC port to a file so the wallet always knows which port to use
$RpcPortFile = Join-Path $ScriptDir "rpc-port.txt"
Set-Content -Path $RpcPortFile -Value "$RpcPort" -NoNewline

# Force a direct persistent peer connection to the VPS node.
# Newer geth versions ignore static-nodes.json, so write config.toml instead.
$gethDir = Join-Path $DataDir "geth"
if (-not (Test-Path $gethDir)) { New-Item -ItemType Directory -Path $gethDir | Out-Null }
$configTomlPath = Join-Path $gethDir "config.toml"
$configToml = @"
[Node.P2P]
StaticNodes = [
  "$BootnodeEnode"
]
"@
Set-Content -Path $configTomlPath -Value $configToml -Encoding ASCII

Write-Host "Scanning for available ports..." -ForegroundColor Yellow
Write-Host "  RPC Port      : $RpcPort"        -ForegroundColor Green
Write-Host "  P2P Port      : $P2pPort"        -ForegroundColor Green
Write-Host "  Stratum Port  : $StratumPort"    -ForegroundColor Green
Write-Host "  Dashboard Port: $DashboardPort"  -ForegroundColor Green
Write-Host ""

# ── Mining address ────────────────────────────────────────────────────────────
$Etherbase = ""
if (Test-Path $AddrFile) {
    $Etherbase = (Get-Content $AddrFile -Raw).Trim()
    Write-Host "  Saved address: $Etherbase" -ForegroundColor Green
}
if ($Etherbase -eq "") {
    Write-Host ""
    $Etherbase = Read-Host "Enter your ETHII mining address (0x...)"
    $Etherbase = $Etherbase.Trim()
    if ($Etherbase -eq "") { Write-Host "ERROR: No address provided." -ForegroundColor Red; Read-Host "Press Enter to exit"; exit 1 }
    Set-Content -Path $AddrFile -Value $Etherbase -NoNewline
    Write-Host "  Address saved for next launch." -ForegroundColor Green
}

# ── Get local IP ──────────────────────────────────────────────────────────────
# Prefer a real physical/wireless adapter; skip virtual adapters (WSL, Hyper-V, VPN, loopback)
$LocalIP = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
        $_.IPAddress -notmatch "^127\." -and
        $_.IPAddress -notmatch "^169\.254\." -and
        $_.PrefixOrigin -ne "WellKnown" -and
        $_.InterfaceAlias -notmatch "vEthernet|Loopback|Pseudo|Teredo|isatap|Bluetooth"
    } |
    Sort-Object { if ($_.InterfaceAlias -match "Ethernet") { 0 } elseif ($_.InterfaceAlias -match "Wi-Fi|WiFi|Wireless") { 1 } else { 2 } } |
    Select-Object -First 1).IPAddress
if (-not $LocalIP) { $LocalIP = "YOUR_LOCAL_IP" }

# ── Write info file and open it ───────────────────────────────────────────────
$info = @"
============================================================
  ETHII MINING SETUP GUIDE
  ETH 2.0 Proof of Work  |  Chain ID 2048
  Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
============================================================

  Welcome!  This guide has everything you need to start mining ETHII.
  All addresses and port numbers below are specific to THIS machine
  right now.  Just copy and paste -- no math required.


------------------------------------------------------------
  STEP 1 -- YOUR REWARD ADDRESS
------------------------------------------------------------

  All block rewards will be sent to this address:

    $Etherbase

  Write it down or save it somewhere safe.  This is your wallet.
  If you lose it you lose access to your coins.


------------------------------------------------------------
  STEP 2 -- START THE CPU MINER (built in, easiest option)
------------------------------------------------------------

  The ETHII Wallet app opened automatically when you launched the
  Miner Suite.  In the wallet:

    1. Go to the Mining tab
    2. Use the slider to choose how many CPU threads to use
       (more threads = more hashrate, but uses more CPU)
    3. Click  Start Mining

  That's it.  The wallet will show your hashrate and block count.
  Rewards appear in your balance automatically.


------------------------------------------------------------
  STEP 3 -- CONNECT A GPU OR ASIC MINER  (optional)
------------------------------------------------------------

  If you want to connect an external GPU rig or ASIC miner,
  point it at the stratum address below.

  IMPORTANT:
    - Use  ETHASH  algorithm
    - For the username/wallet field, enter any short worker name
      like  rig1  or  gpu2  or  asic1  (NOT your wallet address --
      the server handles rewards automatically)
    - For the password field, enter  x

  ── ON THIS SAME MACHINE ────────────────────────────────────
  Use this address if the miner software is running on this PC:

    stratum+tcp://127.0.0.1:$StratumPort

  ── ON ANOTHER MACHINE ON YOUR NETWORK ─────────────────────
  Use this address if your miner is a separate rig on your LAN:

    stratum+tcp://${LocalIP}:$StratumPort

  ── COPY/PASTE COMMANDS FOR COMMON MINERS ──────────────────

  T-Rex (NVIDIA):
    t-rex.exe -a ethash -o stratum+tcp://${LocalIP}:$StratumPort -u rig1 -p x

  lolMiner (AMD / NVIDIA):
    lolMiner.exe --algo ETHASH --pool stratum+tcp://${LocalIP}:$StratumPort --user rig1

  PhoenixMiner:
    PhoenixMiner.exe -pool stratum+tcp://${LocalIP}:$StratumPort -wal rig1 -pass x

  GMiner:
    miner.exe --algo ethash --server ${LocalIP} --port $StratumPort --user rig1

  Rigel:
    rigel.exe -a ethash -o stratum+tcp://${LocalIP}:$StratumPort -u rig1 -p x

  Claymore / ASIC (ethproxy protocol):
    Use the same stratum address.  The server auto-detects the protocol.


------------------------------------------------------------
  LIVE STATS DASHBOARD
------------------------------------------------------------

  Open this URL in your browser to see all connected miners,
  hashrates, shares accepted/rejected, and pool stats:

    http://127.0.0.1:$DashboardPort

  NOTE: The dashboard only counts EXTERNAL miners (GPUs/ASICs
  connected via stratum).  The built-in CPU miner in the wallet
  app does not appear here -- that is normal.  Check the wallet's
  Mining tab for CPU miner stats.


------------------------------------------------------------
  TECHNICAL DETAILS  (for advanced users)
------------------------------------------------------------

  Node RPC URL  : http://127.0.0.1:$RpcPort
  Stratum Port  : $StratumPort
  P2P Port      : $P2pPort
  Dashboard     : http://127.0.0.1:$DashboardPort
  Node log      : $RootDir\node.log

  NOTE ON RPC PORT: This node is using port $RpcPort (not always 8545).
  If another Ethereum node was already running on this machine, ETHII
  picked the next available port automatically to avoid conflicts.
  The wallet app reads this port from rpc-port.txt and connects
  correctly regardless of which port was chosen.


------------------------------------------------------------
  TROUBLESHOOTING
------------------------------------------------------------

  MINER SHOWS "DEAD POOL" OR CAN'T CONNECT
    The IP  ${LocalIP}  was auto-detected as your LAN IP.
    If it doesn't work, find your real IP manually:
      - Open Command Prompt and type:  ipconfig
      - Look for Ethernet adapter or Wi-Fi adapter
      - Use the IPv4 Address (usually 192.168.x.x or 10.x.x.x)
    Then replace ${LocalIP} in the stratum address with that IP.

  WINDOWS FIREWALL BLOCKING THE STRATUM PORT
    Open PowerShell as Administrator and run this command:
      netsh advfirewall firewall add rule name="ETHII Stratum" ^
        dir=in action=allow protocol=TCP localport=$StratumPort
    Then reconnect your miner.

  WALLET SHOWS "NODE OFFLINE"
    Make sure the black terminal window (the Miner Suite launcher)
    is still open.  Closing it stops the node.  If it closed by
    accident, just run Start-ETHII-Miner.ps1 again.

  STRATUM SHOWS "NO PENDING WORK"
    The node needs the CPU miner started before it produces work
    for external miners.  Open the wallet, go to Mining tab, and
    click  Start Mining.  Within a few seconds the stratum will
    start serving work to all connected miners.

  BALANCE NOT UPDATING IN WALLET
    Block rewards take one confirmation to show up.  If you have
    mined blocks but see zero balance, click the Refresh button
    in the wallet.  If it still shows zero, make sure the wallet
    is connected to the correct RPC port ($RpcPort).

============================================================
"@
Set-Content -Path $InfoFile -Value $info
Start-Process notepad $InfoFile

# ── Launch Node FIRST (background) ───────────────────────────────────────────
Write-Host ""
Write-Host "Starting ETHII node..." -ForegroundColor Cyan
$NodeLog = Join-Path $RootDir "node.log"
$NodeOutLog = Join-Path $RootDir "node.out.log"
$nodeProc = Start-Process -FilePath $EthiiExe -ArgumentList (
    "--datadir `"$DataDir`"",
  "--config `"$configTomlPath`"",
    "--networkid 2048",
    "--syncmode full",
    "--gcmode archive",
    "--state.scheme hash",
    "--http",
    "--http.addr 0.0.0.0",
    "--http.port $RpcPort",
    "--http.api eth,net,web3,miner,ethash,txpool,admin,debug",
    "--http.corsdomain *",
    "--http.vhosts *",
    "--port $P2pPort",
    "--miner.etherbase $Etherbase",
    "--miner.pending.feeRecipient $Etherbase",
    "--bootnodes $BootnodeEnode",
    "--verbosity 3"
  ) -WindowStyle Normal -RedirectStandardOutput $NodeOutLog -RedirectStandardError $NodeLog -PassThru
Write-Host "  Node PID: $($nodeProc.Id)" -ForegroundColor Green

# ── Wait for node RPC to be ready (up to 30 seconds) ─────────────────────────
Write-Host "Waiting for node RPC on port $RpcPort..." -ForegroundColor Yellow
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$RpcPort" `
            -Method POST `
            -Body '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' `
            -ContentType "application/json" `
            -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch { }
    Write-Host "  ...waiting ($($i+1)s)" -ForegroundColor DarkGray
}
if (-not $ready) {
    Write-Host "ERROR: Node did not start within 30 seconds. Check node.log for details:" -ForegroundColor Red
    Get-Content $NodeLog -Tail 20 | Write-Host
    Read-Host "Press Enter to exit"
    exit 1
}
Write-Host "  Node is ready!" -ForegroundColor Green

# Force-add the VPS peer over RPC on startup. This makes peering reliable even
# when discovery is slow or static peer config is not yet effective.
try {
  Invoke-RestMethod -Uri "http://127.0.0.1:$RpcPort" -Method POST `
    -Body ('{"jsonrpc":"2.0","method":"admin_addPeer","params":["' + $BootnodeEnode + '"],"id":1}') `
    -ContentType "application/json" -TimeoutSec 3 | Out-Null
  Write-Host "  Requested connection to VPS peer." -ForegroundColor Green
} catch {
  Write-Host "  WARNING: Could not request VPS peer connection: $_" -ForegroundColor Yellow
}

# Kick off sync explicitly to the current VPS head hash (ETHII sync override service).
try {
  $vpsHead = Invoke-RestMethod -Uri $PublicRpcUrl -Method POST `
    -Body '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' `
    -ContentType "application/json" -TimeoutSec 5
  $targetHash = $vpsHead.result.hash
  if ($targetHash) {
    Invoke-RestMethod -Uri "http://127.0.0.1:$RpcPort" -Method POST `
      -Body ('{"jsonrpc":"2.0","method":"debug_sync","params":["' + $targetHash + '"],"id":1}') `
      -ContentType "application/json" -TimeoutSec 5 | Out-Null
    Write-Host "  Requested full sync to VPS head: $targetHash" -ForegroundColor Green
  }
} catch {
  Write-Host "  WARNING: Could not trigger debug_sync: $_" -ForegroundColor Yellow
}

# Keep nudging sync in the background for a short period. Some ETHII builds
# only advance to the last explicitly requested target hash when using the
# sync override service.
$syncNudgeJob = Start-Job -ArgumentList $RpcPort,$PublicRpcUrl,$BootnodeEnode,$nodeProc.Id -ScriptBlock {
  param($LocalRpcPort, $RemoteRpcUrl, $Bootnode, $NodePid)
  while ($true) {
    if (-not (Get-Process -Id $NodePid -ErrorAction SilentlyContinue)) {
      break
    }
    try {
      $peerCount = 0
      $localNumHex = (Invoke-RestMethod -Uri ("http://127.0.0.1:" + $LocalRpcPort) -Method POST `
        -Body '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' `
        -ContentType "application/json" -TimeoutSec 3).result
      $peerHex = (Invoke-RestMethod -Uri ("http://127.0.0.1:" + $LocalRpcPort) -Method POST `
        -Body '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' `
        -ContentType "application/json" -TimeoutSec 3).result
      if ($peerHex) {
        $peerCount = [Convert]::ToInt32($peerHex, 16)
      }
      $remoteLatest = Invoke-RestMethod -Uri $RemoteRpcUrl -Method POST `
        -Body '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' `
        -ContentType "application/json" -TimeoutSec 5
      $remoteNumHex = $remoteLatest.result.number
      $remoteHash = $remoteLatest.result.hash
      if ($localNumHex -and $remoteNumHex -and $remoteHash) {
        $localNum = [Convert]::ToInt64($localNumHex, 16)
        $remoteNum = [Convert]::ToInt64($remoteNumHex, 16)
        if ($peerCount -eq 0 -and $Bootnode) {
          Invoke-RestMethod -Uri ("http://127.0.0.1:" + $LocalRpcPort) -Method POST `
            -Body ('{"jsonrpc":"2.0","method":"admin_addPeer","params":["' + $Bootnode + '"],"id":1}') `
            -ContentType "application/json" -TimeoutSec 3 | Out-Null
        }
        if ($localNum -lt $remoteNum) {
          Invoke-RestMethod -Uri ("http://127.0.0.1:" + $LocalRpcPort) -Method POST `
            -Body ('{"jsonrpc":"2.0","method":"debug_sync","params":["' + $remoteHash + '"],"id":1}') `
            -ContentType "application/json" -TimeoutSec 5 | Out-Null
        }
      }
    } catch { }
    Start-Sleep -Seconds 15
  }
}

# Wait briefly for at least one peer before enabling mining work.
# This avoids mining on an isolated local fork after startup.
$peerReady = $false
for ($j = 0; $j -lt 20; $j++) {
  Start-Sleep -Seconds 1
  try {
    $peerResp = Invoke-RestMethod -Uri "http://127.0.0.1:$RpcPort" -Method POST `
      -Body '{"jsonrpc":"2.0","method":"net_peerCount","params":[],"id":1}' `
      -ContentType "application/json" -TimeoutSec 2 -ErrorAction Stop
    $peerHex = $peerResp.result
    $peerCount = [Convert]::ToInt32($peerHex, 16)
    if ($peerCount -gt 0) { $peerReady = $true; break }
  } catch { }
}

# Start the PoW miner via RPC (--mine flag is deprecated in this geth version)
# Pass 0 threads to enable work generation (remote sealer) without CPU mining,
# since all block production comes from GPU/ASIC via the stratum proxy.
if ($peerReady) {
  try {
    Invoke-RestMethod -Uri "http://127.0.0.1:$RpcPort" -Method POST `
      -Body '{"jsonrpc":"2.0","method":"miner_start","params":[0],"id":1}' `
      -ContentType "application/json" | Out-Null
    Write-Host "  PoW miner started!" -ForegroundColor Green
  } catch {
    Write-Host "  WARNING: Could not auto-start miner via RPC: $_" -ForegroundColor Yellow
  }
} else {
  Write-Host "  WARNING: 0 peers detected. Skipping auto-miner start to avoid isolated-chain mining." -ForegroundColor Yellow
  Write-Host "           Once peers connect, start mining from the Wallet Mining tab." -ForegroundColor Yellow
}
Write-Host ""

# ── Launch Stratum Proxy ──────────────────────────────────────────────────────
Write-Host "Launching Stratum Proxy on port $StratumPort..." -ForegroundColor Yellow
$stratumArgs = "--node `"http://127.0.0.1:$RpcPort`" --stratum `"0.0.0.0:$StratumPort`" --dashboard `"0.0.0.0:$DashboardPort`" --interval 500ms --etherbase `"$Etherbase`""
Start-Process -FilePath $StratumExe -ArgumentList $stratumArgs -WindowStyle Normal
Start-Sleep -Seconds 2
Write-Host "  Dashboard: http://127.0.0.1:$DashboardPort" -ForegroundColor Cyan

# ── Launch Wallet GUI ─────────────────────────────────────────────────────────
Write-Host "Launching ETHII Wallet..." -ForegroundColor Yellow
# Use ProcessStartInfo to explicitly remove ELECTRON_RUN_AS_NODE.
# VS Code (and other Electron apps) set this in their process environment, and
# it propagates to child processes. If set, electron.exe treats itself as a
# plain Node.js process - app.* APIs are undefined and the wallet crashes.
$walletStartInfo = New-Object System.Diagnostics.ProcessStartInfo($ElectronExe, "`"$ScriptDir`"")
$walletStartInfo.UseShellExecute = $false
$walletStartInfo.EnvironmentVariables.Remove("ELECTRON_RUN_AS_NODE")
[System.Diagnostics.Process]::Start($walletStartInfo) | Out-Null
Write-Host "  Wallet launched. Use Mining tab once peers are connected." -ForegroundColor Green

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  All services running. Keep this window open." -ForegroundColor Cyan
Write-Host "  Node log: $NodeLog" -ForegroundColor Cyan
Write-Host "  Press Ctrl+C to stop everything." -ForegroundColor Yellow
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Keep window open and wait for the node to exit
try { $nodeProc.WaitForExit() } catch { }

if ($syncNudgeJob) {
  Stop-Job -Job $syncNudgeJob -ErrorAction SilentlyContinue
  Remove-Job -Job $syncNudgeJob -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Node stopped." -ForegroundColor Yellow
Read-Host "Press Enter to close"
