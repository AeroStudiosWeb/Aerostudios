@echo off
setlocal
cd /d "%~dp0"
echo Compiling AeroEnhance with AeroRoom RAW support and CUDA...
cargo run --release --features "aeroroom-raw,ai-cuda"
if errorlevel 1 (echo. & echo Build failed; copy the FIRST compiler error. & pause & exit /b 1)
endlocal
