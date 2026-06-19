$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptPath = Join-Path $Root 'peer-node-selfheal.ps1'
if (-not (Test-Path $ScriptPath)) { throw "Missing script: $ScriptPath" }

$taskName = 'ETHII-LocalPeer-SelfHeal'
$runtimeDir = Join-Path $env:LOCALAPPDATA 'ETHII\Peer-Node'
New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
$runnerPath = Join-Path $runtimeDir 'run-selfheal.cmd'
$runner = @(
	'@echo off',
	'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
) -join "`r`n"
Set-Content -Path $runnerPath -Value $runner -Encoding ASCII

# Create/update a simple recurring task every 5 minutes (non-admin compatible).
& schtasks.exe /Create /TN $taskName /TR $runnerPath /SC MINUTE /MO 5 /F /RL LIMITED | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to create scheduled task ($LASTEXITCODE)." }

# Run once immediately to seed state.
& schtasks.exe /Run /TN $taskName | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to run scheduled task ($LASTEXITCODE)." }

Write-Host "Installed scheduled task: $taskName (every 5 minutes)" -ForegroundColor Green
