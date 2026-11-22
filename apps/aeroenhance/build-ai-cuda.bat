@echo off
setlocal
cd /d "%~dp0"
where cargo >nul 2>nul
if errorlevel 1 ( echo Rust missing. Install from https://rustup.rs/ & pause & exit /b 1 )
echo Building AeroEnhance Studio CUDA Edition (ONNX Runtime CUDA EP) ...
echo First build downloads large GPU-enabled ONNX Runtime binaries.
echo ort rc.15 runtime expects CUDA 13.2+ and cuDNN 9.23+ available to Windows.
cargo build --release --features ai-cuda
if errorlevel 1 ( echo GPU build failed. Read the errors above. & pause & exit /b 1 )
echo Launching CUDA-enabled AeroEnhance Studio...
start "" "target\release\aeroenhance-studio.exe"
