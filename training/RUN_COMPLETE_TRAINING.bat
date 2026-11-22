@echo off
setlocal
cd /d "%~dp0"
if "%~1"=="" (
 echo Usage: RUN_COMPLETE_TRAINING.bat "E:\AeroPrivate\CleanDataset" "E:\AeroPrivate\Runs\trial01" ["E:\AeroPrivate\Pairs"]
 exit /b 1
)
if "%~2"=="" (
 echo Missing run output path.
 exit /b 1
)
if "%~3"=="" (
 powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-AeroTraining.ps1" -Dataset "%~1" -Output "%~2"
) else (
 powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-AeroTraining.ps1" -Dataset "%~1" -Output "%~2" -PairedDataset "%~3"
)
exit /b %errorlevel%
