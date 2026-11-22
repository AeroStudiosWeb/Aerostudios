@echo off
setlocal
cd /d "%~dp0"
if not exist .venv\Scripts\python.exe (
 echo Run install-training-windows.bat first.
 exit /b 1
)
if "%~1"=="" (
 echo Usage: run-training-windows.bat "C:\private\aero-dataset" "C:\private\training-output"
 echo NOTE: Need 3 or more licensed photographer/session groups and at least 20 TRAIN images.
 exit /b 1
)
if "%~2"=="" (
 echo Pass a SECOND path for the output directory.
 exit /b 1
)
.venv\Scripts\python.exe -m aero_train.dataset_cli audit --dataset "%~1"
if errorlevel 1 exit /b 1
.venv\Scripts\python.exe -m aero_train.pipeline train --dataset "%~1" --output "%~2" --device cuda --epochs 20 --batch 4 --steps-per-epoch 200 --patch 128 --amp
if errorlevel 1 exit /b 1
.venv\Scripts\python.exe -m aero_train.pipeline evaluate --dataset "%~1" --checkpoint "%~2\best.pt" --output "%~2\heldout-report.json" --device cuda --patch 256
if errorlevel 1 exit /b 1
.venv\Scripts\python.exe -m aero_train.pipeline export --checkpoint "%~2\best.pt" --output "%~2\aero-denoise.onnx"
if errorlevel 1 exit /b 1
echo Private evaluation and ONNX candidate ready. NOTHING has been published to users.
pause
