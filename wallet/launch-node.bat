@echo off
if exist "%~dp0..\repair-shortcuts.ps1" (
	powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\repair-shortcuts.ps1" -Quiet
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launch-node.ps1"
