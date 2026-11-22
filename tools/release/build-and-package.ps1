# AeroEnhance: one reproducible private-beta build path.
# Never publishes a release; creates a test ZIP in dist/.
[CmdletBinding()]
param(
  [ValidateSet('CPU','CUDA')][string]$Variant = 'CUDA',
  [string]$BuildRoot = '',
  [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$manifest = Join-Path $repo 'apps/aeroenhance/Cargo.toml'
if (-not (Test-Path -LiteralPath $manifest)) { throw "Missing Cargo manifest: $manifest" }
foreach ($tool in @('cargo','rustc')) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Missing $tool. Install Rust from https://rustup.rs/" }
}
if ($BuildRoot) {
  if (-not [IO.Path]::IsPathRooted($BuildRoot)) { throw '-BuildRoot must be an absolute path, e.g. D:\AeroBuild' }
  $targetBase = Join-Path $BuildRoot 'AeroEnhance'
} else {
  $targetBase = Join-Path $repo '.aero-target'
}
$env:CARGO_TARGET_DIR = Join-Path $targetBase $Variant
New-Item -ItemType Directory -Force -Path $env:CARGO_TARGET_DIR | Out-Null
# Optimise for reliable Windows builds with smaller PDBs and lower link/RAM pressure.
$env:CARGO_PROFILE_RELEASE_DEBUG = '0'
$env:CARGO_PROFILE_RELEASE_STRIP = 'debuginfo'
$env:CARGO_PROFILE_RELEASE_LTO = 'false'
$env:CARGO_PROFILE_RELEASE_CODEGEN_UNITS = '8'
$env:CARGO_INCREMENTAL = '0'
$env:CARGO_BUILD_JOBS = '2'
$env:RUST_BACKTRACE = '1'
Write-Host "AeroEnhance $Variant private build" -ForegroundColor Cyan
Write-Host "Cargo target: $env:CARGO_TARGET_DIR"
$drive = [IO.Path]::GetPathRoot($env:CARGO_TARGET_DIR)
try {
  $driveInfo = [System.IO.DriveInfo]::new($drive)
  $freeGiB = [math]::Round($driveInfo.AvailableFreeSpace / 1GB, 1)
  Write-Host "Free space on build drive: $freeGiB GiB"
  if ($driveInfo.AvailableFreeSpace -lt 8GB) {
    throw "Build drive has under 8 GiB free. Clear space or use -BuildRoot 'D:\AeroBuild' (if D: has space)."
  }
  if ($driveInfo.AvailableFreeSpace -lt 20GB) {
    Write-Warning 'Under 20 GiB available. Large Rust first-time builds may run out of space. Consider -BuildRoot on another SSD.'
  }
} catch [System.IO.IOException] { Write-Warning "Cannot read free space for $drive" }
$lock = Join-Path $repo 'apps/aeroenhance/Cargo.lock'
if (-not (Test-Path $lock)) {
  Write-Host 'Generating Cargo.lock (commit this file to GitHub)...'
  & cargo generate-lockfile --manifest-path $manifest
  if ($LASTEXITCODE -ne 0) { throw 'Could not generate Cargo.lock' }
}
if (-not $SkipTests) {
  # Test the RAW + image + network logic without loading ORT native DLLs.
  # CUDA-specific runtime testing is a separate post-build smoke test on an NVIDIA PC.
  Write-Host 'Running release-mode core tests (no ONNX Runtime DLL dependency)...' -ForegroundColor Cyan
  & cargo test --release --locked --manifest-path $manifest --no-default-features --features aeroroom-raw -- --nocapture
  if ($LASTEXITCODE -ne 0) { throw 'Core tests failed; see the first FAILED test above.' }
} else { Write-Warning 'Skipping all unit tests (requested). Do not distribute before testing.' }
$features = if ($Variant -eq 'CUDA') { 'aeroroom-raw,ai-cuda' } else { 'aeroroom-raw,ai' }
Write-Host "Building full $Variant AI application..." -ForegroundColor Cyan
& cargo build --release --locked --manifest-path $manifest --no-default-features --features $features
if ($LASTEXITCODE -ne 0) { throw 'AI application build failed; see Cargo output above.' }
Write-Host 'Packaging and verifying ONNX Runtime DLLs...' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'package-aeroenhance.ps1') -Variant $Variant -TargetDir $env:CARGO_TARGET_DIR
if (-not $?) { throw 'Packaging failed.' }
Write-Host 'Build package ready in dist/. This is a PRIVATE test build, not a public release.' -ForegroundColor Green
