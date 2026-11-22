@echo off
setlocal
cd /d "%~dp0"
echo Running AeroEnhance high-precision Rust regression tests...
cargo test --release --features "aeroroom-raw,ai"
if errorlevel 1 (
  echo.
  echo Tests failed. Copy the first compiler or test error here.
  pause
  exit /b 1
)
echo High precision tests passed. CUDA still requires separate GPU verification.
pause
endlocal
