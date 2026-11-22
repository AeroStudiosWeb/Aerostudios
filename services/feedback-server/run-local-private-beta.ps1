$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (-not $env:AERO_BETA_TOKEN) {
  throw 'Set $env:AERO_BETA_TOKEN to a random token (32+ characters) before running.'
}
if ($env:AERO_BETA_TOKEN.Length -lt 32) { throw 'Beta token too short.' }
Write-Host 'Starting local-only feedback service. Do not expose this port directly.'
cargo run --release
