@echo off
setlocal
cd /d "%~dp0"
where cargo >nul 2>nul
if errorlevel 1 (
  echo Rust/Cargo is not installed. Get rustup from https://rustup.rs/ then reopen this terminal.
  pause
  exit /b 1
)
echo Building AeroEnhance Studio in release mode...
cargo build --release
if errorlevel 1 (
  echo Build failed. Scroll up for the compiler error.
  pause
  exit /b 1
)
echo Build complete: target\release\aeroenhance-studio.exe
start "" "target\release\aeroenhance-studio.exe"
