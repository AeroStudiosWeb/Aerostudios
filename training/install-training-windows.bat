@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if errorlevel 1 (
  echo Install Python 3.12 x64 and the Python launcher from python.org first.
  exit /b 1
)
if not exist .venv\Scripts\python.exe (
  py -3.12 -m venv .venv
  if errorlevel 1 exit /b 1
)
.venv\Scripts\python.exe -m pip install --upgrade pip
if errorlevel 1 exit /b 1
.venv\Scripts\python.exe -m pip install -r requirements-train.txt
if errorlevel 1 exit /b 1
.venv\Scripts\python.exe -c "import torch; assert torch.cuda.is_available(); print('CUDA READY:', torch.cuda.get_device_name(0))" 2>nul
if not errorlevel 1 goto gpu_ready

echo.
echo Installing official NVIDIA CUDA-enabled PyTorch into training\.venv.
echo Default wheel: CUDA 12.6 (supported by RTX 3080 with compatible NVIDIA driver).
echo To override, set AERO_TORCH_INDEX_URL to the current Windows CUDA wheel URL from:
echo https://pytorch.org/get-started/locally/
if not defined AERO_TORCH_INDEX_URL set "AERO_TORCH_INDEX_URL=https://download.pytorch.org/whl/cu126"
.venv\Scripts\python.exe -m pip install --upgrade torch --index-url "%AERO_TORCH_INDEX_URL%"
if errorlevel 1 (
 echo CUDA PyTorch install failed. Select the current Windows/Pip/CUDA build at https://pytorch.org/get-started/locally/
 exit /b 1
)
.venv\Scripts\python.exe -c "import torch; assert torch.cuda.is_available(); print('CUDA READY:',torch.cuda.get_device_name(0))"
if errorlevel 1 (
 echo The installed torch wheel cannot see CUDA. Check NVIDIA driver / current PyTorch selector.
 exit /b 1
)
:gpu_ready
.venv\Scripts\python.exe -m unittest discover -s tests -v
if errorlevel 1 exit /b 1
echo CUDA training environment READY. No photos have been uploaded or used for training.
exit /b 0
