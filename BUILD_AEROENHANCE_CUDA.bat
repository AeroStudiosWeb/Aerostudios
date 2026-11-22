@echo off
setlocal
cd /d "%~dp0"
echo AeroEnhance fresh private-beta build for NVIDIA CUDA
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\tools\release\build-and-package.ps1" -Variant CUDA
if errorlevel 1 (
  echo.
  echo Build failed. Read the FIRST error above; source has not been deleted.
) else (
  echo.
  echo Build ZIPs are in the dist folder.
)
pause
endlocal
