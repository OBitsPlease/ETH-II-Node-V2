@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-peer-node.ps1"
if errorlevel 1 (
  echo.
  echo Peer node launcher exited with an error.
  pause
)
