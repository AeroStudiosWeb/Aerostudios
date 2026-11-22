<#
Manual, OFFLINE staging only. The stage function requires passed synthetic
benchmark, correct ONNX export, held-out gate and explicit blind review.
This script NEVER uploads a model, signs a manifest, or edits the live feed.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$WeeklyRun,
  [Parameter(Mandatory=$true)][string]$Version,
  [Parameter(Mandatory=$true)][string]$ModelUrl,
  [Parameter(Mandatory=$true)][string]$Output,
  [switch]$HumanReviewed
)
$ErrorActionPreference='Stop'
if (-not $HumanReviewed) {throw 'Inspect your benchmark and blind photo comparisons, then rerun with -HumanReviewed.'}
$python=Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
$run=Join-Path $WeeklyRun 'candidate'
$flags=@('-m','aero_train.community_release','--benchmark',(Join-Path $WeeklyRun 'community-benchmark.json'),
  '--heldout',(Join-Path $run 'heldout-report.json'),
  '--model',(Join-Path $run 'aero-denoise.onnx'),
  '--validation',(Join-Path $run 'aero-denoise.onnx.validation.json'),
  '--version',$Version,'--url',$ModelUrl,'--output',$Output,
  '--confirm','I REVIEWED THE IMAGES AND APPROVE THIS CANDIDATE')
Push-Location $PSScriptRoot
try {
  & $python @flags
  if ($LASTEXITCODE -ne 0) {throw 'Candidate staging failed. Incumbent remains active.'}
} finally {Pop-Location}
Write-Host 'NEXT, OFFLINE: sign this exact JSON with tools/update-signer, verify signature, upload the SAME ONNX to the release URL and only then publish the signed manifest to GitHub Pages.'
Write-Host 'Never put the private Ed25519 signing key in the repository or GitHub Actions.'
