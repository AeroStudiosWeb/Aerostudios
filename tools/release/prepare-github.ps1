# Preparing the repository only needs Cargo, not a Git CLI in PATH.
[CmdletBinding()]
param([switch]$FetchDependencies)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$manifest=Join-Path $repo 'apps/aeroenhance/Cargo.toml'
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {throw 'Cargo not found. Install Rust from https://rustup.rs/'}
if (-not (Test-Path -LiteralPath $manifest)) { throw "Missing $manifest; extract the ZIP at the GitHub repo root" }
$lock = Join-Path $repo 'apps/aeroenhance/Cargo.lock'
if (-not (Test-Path -LiteralPath $lock)) {
  & cargo generate-lockfile --manifest-path $manifest
  if ($LASTEXITCODE -ne 0) {throw 'Cargo.lock generation failed'}
} else { Write-Host 'Keeping existing Cargo.lock' }
if ($FetchDependencies) {
  & cargo fetch --manifest-path $manifest --locked
  if ($LASTEXITCODE -ne 0) {throw 'Cargo fetch failed'}
}
Write-Host "Ready to commit Cargo.lock and the source; no build artifacts or keys." -ForegroundColor Green
