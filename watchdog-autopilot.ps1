$ErrorActionPreference = "SilentlyContinue"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$NodeExe = Join-Path $Root "ethii.exe"
$StratumExe = Join-Path $Root "stratum.exe"
$DataDir = Join-Path $Root "data"

# Read mining address from etherbase.txt (never hardcode wallet addresses)
$EtherbaseFile = Join-Path $Root "wallet\etherbase.txt"
$Etherbase = if (Test-Path $EtherbaseFile) { (Get-Content $EtherbaseFile -Raw).Trim() } else { "" }
if ($Etherbase -eq "") {
    Write-Host "WARNING: wallet\etherbase.txt not found. Node will start without fee recipient." -ForegroundColor Yellow
}
$NodeUrl = "http://127.0.0.1:8545"
$StatsUrl = "http://127.0.0.1:8082/api/stats"
$MinersUrl = "http://127.0.0.1:8082/api/miners"
$AsicIp = "YOUR_ASIC_IP"
$AsicBase = "http://$AsicIp"
$LogFile = Join-Path $Root "watchdog-autopilot.log"

$lastAccepted = -1
$lastRejected = -1
$lastProgressAt = Get-Date
$lastRebootAt = [datetime]::MinValue

function Log($msg) {
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts] $msg"
    Add-Content -Path $LogFile -Value $line
    Write-Host $line
}

function Test-NodeRpc {
    try {
        $body = '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
        $r = Invoke-RestMethod -Uri $NodeUrl -Method Post -Body $body -ContentType "application/json" -TimeoutSec 5
        return [bool]$r.result
    } catch {
        return $false
    }
}

function Restart-Node {
    Log "Restarting node on RPC 8545"
    Get-Process -Name ethii -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    $feeArg = if ($Etherbase) { " --miner.pending.feeRecipient $Etherbase" } else { "" }
    Start-Process -FilePath $NodeExe -ArgumentList "--datadir `"$DataDir`" --networkid 2048 --gcmode archive --state.scheme hash --http --http.addr 0.0.0.0 --http.port 8545 --http.api eth,net,web3,miner,ethash,txpool --http.corsdomain * --http.vhosts * --port 30303$feeArg --verbosity 3 --miner.recommit 30s" -WindowStyle Normal
}

function Restart-Stratum {
    Log "Restarting stratum"
    Get-Process -Name stratum -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    Start-Process -FilePath $StratumExe -ArgumentList '--node http://127.0.0.1:8545 --stratum 0.0.0.0:3335 --dashboard 0.0.0.0:8082' -WindowStyle Normal
}

function Get-Stats {
    try {
        return Invoke-RestMethod -Uri $StatsUrl -Method Get -TimeoutSec 5
    } catch {
        return $null
    }
}

function Get-Miners {
    try {
        return Invoke-RestMethod -Uri $MinersUrl -Method Get -TimeoutSec 5
    } catch {
        return @()
    }
}

function Reboot-Asic {
    Log "Rebooting ASIC via digest auth endpoint"
    $result = & curl.exe --digest -u root:root -s -o NUL -w "%{http_code}" "$AsicBase/cgi-bin/reboot.cgi"
    Log "ASIC reboot HTTP status: $result"
    $script:lastRebootAt = Get-Date
}

Log "Autopilot watchdog started"

while ($true) {
    $now = Get-Date

    if (-not (Test-NodeRpc)) {
        Log "Node RPC down"
        Restart-Node
        Start-Sleep -Seconds 6
        Restart-Stratum
        Start-Sleep -Seconds 10
        continue
    }

    $stats = Get-Stats
    if ($null -eq $stats) {
        Log "Dashboard unavailable"
        Restart-Stratum
        Start-Sleep -Seconds 8
        continue
    }

    $miners = Get-Miners
    $minerCount = [int]$stats.pool.miners
    $accepted = [int64]$stats.pool.accepted
    $rejected = [int64]$stats.pool.rejected
    $sharesPerMin = [double]$stats.pool.sharesPerMin

    $hr = 0
    if ($miners -and $miners.Count -gt 0) {
        $hr = [double]$miners[0].hashrate
    }

    if ($accepted -ne $lastAccepted -or $rejected -ne $lastRejected) {
        $lastProgressAt = $now
        $lastAccepted = $accepted
        $lastRejected = $rejected
    }

    $idleMinutes = ($now - $lastProgressAt).TotalMinutes
    Log "State miners=$minerCount acc=$accepted rej=$rejected spm=$sharesPerMin hr=$hr idleMin=$([math]::Round($idleMinutes,1))"

    $rebootCooldownOk = ($now - $lastRebootAt).TotalMinutes -ge 15
    $stalled = ($minerCount -eq 0) -or (($hr -le 0) -and ($sharesPerMin -le 0) -and ($idleMinutes -ge 8))

    if ($stalled -and $rebootCooldownOk) {
        Reboot-Asic
    }

    Start-Sleep -Seconds 30
}
