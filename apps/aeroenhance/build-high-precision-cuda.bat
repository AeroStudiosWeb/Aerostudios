@echo off
setlocal
cd /d "%~dp0"
echo Building AeroEnhance v0.7 High-Precision RAW + ONNX + NVIDIA CUDA...
cargo run --release --features "aeroroom-raw,ai-cuda"
if errorlevel 1 (
  echo.
  echo Build or launch failed. Copy the FIRST error to ChatGPT.
  pause
  exit /b 1
)
endlocal
