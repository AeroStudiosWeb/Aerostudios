@echo off
setlocal
cd /d "%~dp0"
echo AeroEnhance fresh private-beta CPU build
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\tools\release\build-and-package.ps1" -Variant CPU
if errorlevel 1 (
  echo.
  echo Build failed. Read the FIRST error above.
) else (
  echo.
  echo Build ZIPs are in the dist folder.
)
pause
endlocal
