@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>nul
if errorlevel 1 (
  echo Install Python 3.11 or 3.12 and the Python launcher first.
  exit /b 1
)
py -3.12 -m venv .venv
if errorlevel 1 (
  echo Could not make venv with Python 3.12; install 3.12 and retry.
  exit /b 1
)
.venv\Scripts\python.exe -m pip install --upgrade pip
if errorlevel 1 exit /b 1
.venv\Scripts\python.exe -m pip install -r requirements-train.txt
if errorlevel 1 exit /b 1
echo.
echo Now install the CURRENT NVIDIA CUDA-enabled PyTorch build from:
echo https://pytorch.org/get-started/locally/
echo Run the install command using: .venv\Scripts\python.exe -m pip install ...
echo Then verify:
echo .venv\Scripts\python.exe -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'NO CUDA')"
echo.
pause
