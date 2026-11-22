@echo off
rem Compatibility entry point: use the SAME complete workflow, no parallel legacy scripts.
setlocal
cd /d "%~dp0"
if "%~1"=="" (
 echo Usage: run-training-windows.bat "E:\AeroPrivate\CleanDataset" "E:\AeroPrivate\runs\trial01" ["E:\AeroPrivate\Pairs"]
 exit /b 1
)
if "%~2"=="" (
 echo Missing run-output folder.
 exit /b 1
)
call "%~dp0RUN_COMPLETE_TRAINING.bat" %*
exit /b %errorlevel%
