@echo off
setlocal
cd /d "%~dp0"
if "%AERO_UPDATE_PUBLIC_KEY_HEX%"=="" (
  echo.
  echo Set AERO_UPDATE_PUBLIC_KEY_HEX to your publisher public key first.
  echo Example PowerShell: $env:AERO_UPDATE_PUBLIC_KEY_HEX = (Get-Content 'C:\path\to\key.pub').Trim()
  pause
  exit /b 1
)
if not "%AERO_UPDATE_PUBLIC_KEY_HEX:~64,1%"=="" (
  echo ERROR: Public key must be 64 hexadecimal characters.
  pause
  exit /b 1
)
cargo run --release --features ai-cuda
if errorlevel 1 (
 echo Build or run failed.
 pause
 exit /b 1
)
