param(
  [ValidateSet('check','apply','auto')]
  [string]$Mode = 'auto',
  [switch]$SkipSuite,
  [switch]$SkipWallet,
  [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SuiteRepo = 'OBitsPlease/ethii-miner-suite'
$ApiBase = "https://api.github.com/repos/$SuiteRepo"
$Headers = @{ 'User-Agent' = 'ETHII-Updater' }

function Normalize-Version([string]$v) {
  if (-not $v) { return '0.0.0' }
  return ($v -replace '^wallet-v', '' -replace '^v', '').Trim()
}

function Compare-Version([string]$a, [string]$b) {
  $av = [Version](Normalize-Version $a)
  $bv = [Version](Normalize-Version $b)
  return $av.CompareTo($bv)
}

function Get-LatestReleaseByPattern([array]$releases, [string]$pattern) {
  return $releases |
    Where-Object { $_.tag_name -match $pattern -and -not $_.prerelease -and -not $_.draft } |
    Sort-Object -Property published_at -Descending |
    Select-Object -First 1
}

function Get-LocalWalletVersion {
  $pkg = Join-Path $RootDir 'wallet\package.json'
  if (Test-Path $pkg) {
    try {
      $j = Get-Content $pkg -Raw | ConvertFrom-Json
      if ($j.version) { return [string]$j.version }
    } catch { }
  }

  $installed = Join-Path $env:LOCALAPPDATA 'Programs\ETH II Wallet\ETH II Wallet.exe'
  if (Test-Path $installed) {
    try {
      $ver = (Get-Item $installed).VersionInfo.FileVersion
      if ($ver) { return [string]$ver }
    } catch { }
  }

  return '0.0.0'
}

function Get-LocalSuiteVersion {
  $stateFile = Join-Path $RootDir 'suite-version.txt'
  if (Test-Path $stateFile) {
    $raw = (Get-Content $stateFile -Raw).Trim()
    if ($raw) { return (Normalize-Version $raw) }
  }

  $pkg = Join-Path $RootDir 'wallet\package.json'
  if (Test-Path $pkg) {
    return '0.0.0'
  }

  return '0.0.0'
}

function Save-LocalSuiteVersion([string]$tag) {
  $stateFile = Join-Path $RootDir 'suite-version.txt'
  Set-Content -Path $stateFile -Value $tag -Encoding ASCII -NoNewline
}

function New-PreUpdateBackup {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backupRoot = Join-Path $RootDir 'BACKUPS\UPDATER'
  $backupDir = Join-Path $backupRoot ("PRE-UPDATE-" + $stamp)

  New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

  $files = @(
    'ethii.exe',
    'stratum.exe',
    'launch-stratum.ps1',
    'launch-stratum.bat',
    'watchdog-autopilot.ps1',
    'payout.json',
    'workers.json',
    'wallet\main.js',
    'wallet\preload.js',
    'wallet\launch-node.ps1',
    'wallet\launch-wallet.bat',
    'wallet\package.json',
    'wallet\package-lock.json',
    'wallet\renderer\index.html',
    'wallet\renderer\app.js',
    'wallet\renderer\styles.css',
    'wallet\etherbase.txt',
    'wallet\rpc-port.txt',
    'data\geth\config.toml',
    'data\geth\nodekey',
    'data\geth\jwtsecret'
  )

  foreach ($rel in $files) {
    $src = Join-Path $RootDir $rel
    if (Test-Path $src) {
      $dst = Join-Path $backupDir $rel
      $parent = Split-Path $dst -Parent
      if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
      Copy-Item -Path $src -Destination $dst -Force
    }
  }

  $info = @(
    "created=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    'type=pre-update backup',
    "root=$RootDir"
  )
  Set-Content -Path (Join-Path $backupDir 'BACKUP-INFO.txt') -Value $info -Encoding ASCII

  return $backupDir
}

function Download-Asset([string]$url, [string]$dest) {
  $dir = Split-Path $dest -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Invoke-WebRequest -Uri $url -Headers $Headers -OutFile $dest
}

function Confirm-Secrets {
  if ($NonInteractive) { return $true }
  Write-Host ''
  Write-Host 'Before updating wallet components, confirm you have your wallet password and seed phrase backed up.' -ForegroundColor Yellow
  $ans = Read-Host "Type YES to continue wallet update"
  return $ans -eq 'YES'
}

function Apply-SuiteUpdate([object]$suiteRelease) {
  if (-not $suiteRelease) { return $false }

  Write-Host "Applying suite update: $($suiteRelease.tag_name)" -ForegroundColor Cyan

  Get-Process -Name 'ethii','stratum' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1

  $wanted = @{
    'ethii.exe' = (Join-Path $RootDir 'ethii.exe')
    'stratum.exe' = (Join-Path $RootDir 'stratum.exe')
    'launch-stratum.ps1' = (Join-Path $RootDir 'launch-stratum.ps1')
    'watchdog-autopilot.ps1' = (Join-Path $RootDir 'watchdog-autopilot.ps1')
  }

  $tmp = Join-Path $env:TEMP ('ethii-update-' + [Guid]::NewGuid().ToString())
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null

  foreach ($asset in $suiteRelease.assets) {
    if ($wanted.ContainsKey($asset.name)) {
      $tmpFile = Join-Path $tmp $asset.name
      Download-Asset -url $asset.browser_download_url -dest $tmpFile
      Copy-Item -Path $tmpFile -Destination $wanted[$asset.name] -Force
      Write-Host "  Updated $($asset.name)" -ForegroundColor Green
    }
  }

  Save-LocalSuiteVersion -tag $suiteRelease.tag_name
  return $true
}

function Apply-WalletUpdate([object]$walletRelease) {
  if (-not $walletRelease) { return $false }

  $installer = $walletRelease.assets | Where-Object { $_.name -like '*.exe' } | Select-Object -First 1
  if (-not $installer) {
    Write-Host '  Wallet release has no installer asset; skipping wallet auto-install.' -ForegroundColor Yellow
    return $false
  }

  if (-not (Confirm-Secrets)) {
    Write-Host '  Wallet update skipped by user (seed/password confirmation not provided).' -ForegroundColor Yellow
    return $false
  }

  Write-Host "Applying wallet update: $($walletRelease.tag_name)" -ForegroundColor Cyan

  Get-Process -Name 'electron','ETH II Wallet' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1

  $tmpExe = Join-Path $env:TEMP ("ethii-wallet-update-" + $installer.name)
  Download-Asset -url $installer.browser_download_url -dest $tmpExe

  # NSIS silent install
  Start-Process -FilePath $tmpExe -ArgumentList '/S' -Wait
  Write-Host '  Wallet installer applied.' -ForegroundColor Green
  return $true
}

try {
  Write-Host 'Checking GitHub releases for updates...' -ForegroundColor Cyan
  $releases = Invoke-RestMethod -Uri "$ApiBase/releases" -Headers $Headers

  $latestSuite = if ($SkipSuite) { $null } else { Get-LatestReleaseByPattern -releases $releases -pattern '^v\d+\.\d+\.\d+$' }
  $latestWallet = if ($SkipWallet) { $null } else { Get-LatestReleaseByPattern -releases $releases -pattern '^wallet-v\d+\.\d+\.\d+$' }

  $localSuiteVersion = Get-LocalSuiteVersion
  $localWalletVersion = Get-LocalWalletVersion

  $suiteNeedsUpdate = $false
  if ($latestSuite) {
    $suiteNeedsUpdate = (Compare-Version $localSuiteVersion (Normalize-Version $latestSuite.tag_name)) -lt 0
  }

  $walletNeedsUpdate = $false
  if ($latestWallet) {
    $walletNeedsUpdate = (Compare-Version $localWalletVersion (Normalize-Version $latestWallet.tag_name)) -lt 0
  }

  Write-Host "  Suite local/latest: $localSuiteVersion / $($latestSuite.tag_name)" -ForegroundColor Gray
  Write-Host "  Wallet local/latest: $localWalletVersion / $($latestWallet.tag_name)" -ForegroundColor Gray

  if (-not $suiteNeedsUpdate -and -not $walletNeedsUpdate) {
    Write-Host 'No updates available.' -ForegroundColor Green
    exit 0
  }

  if ($Mode -eq 'check') {
    Write-Host 'Updates are available.' -ForegroundColor Yellow
    exit 0
  }

  if (-not $NonInteractive) {
    $summary = @()
    if ($suiteNeedsUpdate) { $summary += "suite -> $($latestSuite.tag_name)" }
    if ($walletNeedsUpdate) { $summary += "wallet -> $($latestWallet.tag_name)" }
    Write-Host ''
    Write-Host ('Updates available: ' + ($summary -join ', ')) -ForegroundColor Yellow
    $ans = Read-Host 'Apply updates now? (y/N)'
    if ($ans -notin @('y','Y','yes','YES')) {
      Write-Host 'Update skipped by user.' -ForegroundColor Yellow
      exit 0
    }
  }

  Write-Host 'Creating pre-update backup...' -ForegroundColor Yellow
  $backupDir = New-PreUpdateBackup
  Write-Host "  Backup saved: $backupDir" -ForegroundColor Green

  $suiteApplied = $false
  $walletApplied = $false

  if ($suiteNeedsUpdate) { $suiteApplied = Apply-SuiteUpdate -suiteRelease $latestSuite }
  if ($walletNeedsUpdate) { $walletApplied = Apply-WalletUpdate -walletRelease $latestWallet }

  if ($suiteApplied -or $walletApplied) {
    Write-Host 'Update process completed.' -ForegroundColor Green
  } else {
    Write-Host 'No update was applied.' -ForegroundColor Yellow
  }

  exit 0
}
catch {
  Write-Host ("Updater error: " + $_.Exception.Message) -ForegroundColor Red
  exit 1
}
