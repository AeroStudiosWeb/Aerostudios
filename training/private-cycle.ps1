<#
AeroEnhance PRIVATE optional repeating training cycle. Operator may schedule with
Windows Task Scheduler AFTER configuring a licensed curated dataset. Never
publishes or signs a model. It never reads uncurated live submissions.
#>
param(
  [Parameter(Mandatory=$true)][string]$Dataset,
  [Parameter(Mandatory=$true)][string]$Runs,
  [int]$Epochs = 20,
  [string]$PairedDataset = ''
)
$ErrorActionPreference = 'Stop'
$python = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
if (!(Test-Path $python)) { throw 'Install Python training venv first (install-training-windows.bat)' }
if ($Epochs -lt 1) { throw 'Epochs must be positive' }
New-Item -ItemType Directory -Force $Runs | Out-Null
$manifest = Join-Path $Dataset 'manifest.jsonl'
if (!(Test-Path $manifest)) { throw "No curated dataset: $manifest" }
Push-Location $PSScriptRoot
try {
  & $python -m aero_train.dataset_cli audit --dataset $Dataset
  if ($LASTEXITCODE -ne 0) { throw 'Dataset audit failed. Check withdrawal/expiry/licensing.' }
  $hashes = @((Get-FileHash $manifest -Algorithm SHA256).Hash.ToLowerInvariant())
  if ($PairedDataset) {
    $pairedManifest = Join-Path $PairedDataset 'pairs.jsonl'
    if (!(Test-Path $pairedManifest)) { throw "No paired manifest: $pairedManifest" }
    $hashes += (Get-FileHash $pairedManifest -Algorithm SHA256).Hash.ToLowerInvariant()
  }
  $digest = [Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($hashes -join ':'))
    $hash = ([BitConverter]::ToString($digest.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
  } finally { $digest.Dispose() }
  $marker = Join-Path $Runs 'last-private-cycle-sha256.txt'
  if ((Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq $hash)) {
    Write-Output 'No newly curated manifest; skipping GPU retraining.'
    exit 0
  }
  $run = Join-Path $Runs (Get-Date -Format 'yyyyMMdd-HHmmss')
  New-Item -ItemType Directory -Force $run | Out-Null
  $flags = @('-Dataset',$Dataset,'-Output',$run,'-Epochs',$Epochs,'-Device','cuda')
  if ($PairedDataset) { $flags += @('-PairedDataset',$PairedDataset) }
  & (Join-Path $PSScriptRoot 'Run-AeroTraining.ps1') @flags
  if (-not $?) { throw 'Complete training workflow failed; no cycle marker written' }
  Set-Content -Path $marker -Value $hash -NoNewline
  Write-Output "Private candidate created in $run. Review heldout-report.json. NOTHING was distributed."
}
finally { Pop-Location }
