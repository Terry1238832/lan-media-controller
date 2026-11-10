@echo off
cd /d "%~dp0"

for /f "tokens=5" %%a in ('netstat -ano ^| findstr :19889 ^| findstr LISTENING') do (
    taskkill /F /PID %%a >nul 2>nul
)

set "NODE_EXE=node"
if exist "C:\Program Files\nodejs\node.exe" (
    set "NODE_EXE=C:\Program Files\nodejs\node.exe"
)

start "LanMediaServer" /min "%NODE_EXE%" "%~dp0desktop\server.js" --open
