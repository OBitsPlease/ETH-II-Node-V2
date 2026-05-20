@echo off
:: Launch ETHII Wallet
:: Clears ELECTRON_RUN_AS_NODE only for this process - does NOT affect system or other apps
set ELECTRON_RUN_AS_NODE=
cd /d "%~dp0"
if exist "..\update-manager.ps1" (
	powershell -NoProfile -ExecutionPolicy Bypass -File "..\update-manager.ps1" -Mode auto -SkipSuite
)
if exist "node_modules\electron\dist\electron.exe" (
	node_modules\electron\dist\electron.exe .
) else if exist "%LOCALAPPDATA%\Programs\ETH II Wallet\ETH II Wallet.exe" (
	start "" "%LOCALAPPDATA%\Programs\ETH II Wallet\ETH II Wallet.exe"
) else (
	echo ERROR: Wallet runtime not found.
	echo Missing: %~dp0node_modules\electron\dist\electron.exe
	echo Missing: %LOCALAPPDATA%\Programs\ETH II Wallet\ETH II Wallet.exe
	pause
	exit /b 1
)
