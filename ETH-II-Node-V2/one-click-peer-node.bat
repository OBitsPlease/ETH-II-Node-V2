@echo off
setlocal
color 0B
echo =======================================================
echo     ETH-II Windows Peer Node - One-Click Installer
echo =======================================================
echo.
echo This script will automatically download the ETH-II node
echo and start it to help support the network.
echo.

set /p KEY="Enter your ETHII Passkey (e.g. ETHII-XXXX): "
if "%KEY%"=="" (
  echo Error: Passkey is required!
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-peer-node.ps1" -Passkey "%KEY%"
if errorlevel 1 (
  echo.
  echo Peer node launcher exited with an error.
  pause
)
