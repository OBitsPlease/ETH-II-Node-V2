@echo off
set SCRIPT=%~dp0launch-local-peer-node.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
