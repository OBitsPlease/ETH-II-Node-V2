@echo off
:: Launch ETHII Wallet
:: Clears ELECTRON_RUN_AS_NODE only for this process - does NOT affect system or other apps
set ELECTRON_RUN_AS_NODE=
cd /d "%~dp0"
node_modules\electron\dist\electron.exe .
