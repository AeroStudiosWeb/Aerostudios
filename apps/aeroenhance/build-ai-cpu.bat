@echo off
setlocal
cd /d "%~dp0"
where cargo >nul 2>nul
if errorlevel 1 ( echo Install Rust from https://rustup.rs/ & pause & exit /b 1 )
echo Building AeroEnhance with ONNX CPU inference...
cargo build --release --features ai
if errorlevel 1 ( pause & exit /b 1 )
start "" "target\release\aeroenhance-studio.exe"
