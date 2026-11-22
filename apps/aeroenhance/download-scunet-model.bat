@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0download-scunet-model.ps1"
if errorlevel 1 (
  echo Model download failed. Scroll up for the error.
  pause
  exit /b 1
)
pause
