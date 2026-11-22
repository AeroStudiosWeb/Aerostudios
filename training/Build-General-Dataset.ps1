<#
Two-phase, explicit-rights local dataset preparation.
  -Phase Download: downloads limited candidate photos and produces a rights ledger.
  -Phase Import: requires an operator to have reviewed the ledger and sources.
No remote model upload, publishing, or consent to unreviewed image use.
#>
[CmdletBinding()]
param(
  [ValidateSet('Download','Import')][string]$Phase='Download',
  [string]$Workspace='E:\AeroPrivate',
  [string]$Contact='',
  [ValidateRange(30,10000)][int]$TargetImages=500,
  [ValidateSet('CC0','CC0-CCBY')][string]$LicenseMode='CC0',
  [ValidateSet('Auto','Search','CC0Category')][string]$Discovery='Auto',
  [ValidateRange(1,1000)][int]$MaxPerCreator=30,
  [switch]$RightsReviewed
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$python=Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
if (!(Test-Path -LiteralPath $python -PathType Leaf)) {throw 'Run training\install-training-windows.bat first.'}
$source=Join-Path $Workspace 'general-commons'
$dataset=Join-Path $Workspace 'general-dataset'
Push-Location $PSScriptRoot
try {
  if ($Phase -eq 'Download') {
    if (-not $Contact) {throw 'For Wikimedia API access, specify -Contact with a real email address for your User-Agent.'}
    $mode='cc0';if ($LicenseMode -eq 'CC0-CCBY') {$mode='cc0-by'}
    $discoveryMode='auto'
    if ($Discovery -eq 'Search') {$discoveryMode='search'}
    if ($Discovery -eq 'CC0Category') {$discoveryMode='cc0-category'}
    & $python -m aero_train.commons download --output $source --contact $Contact --target $TargetImages --license-mode $mode --discovery $discoveryMode --max-per-creator $MaxPerCreator
    if ($LASTEXITCODE -ne 0) {throw 'General-photo download did not finish. Retry to resume the existing ledger.'}
    Write-Host "REVIEW REQUIRED: $source\SOURCE_LICENSE_REVIEW.csv" -ForegroundColor Yellow
    Write-Host 'Open the CSV; check source pages, rights and attribution. Set EACH review_status to APPROVED or REJECTED.'
    Write-Host 'No training dataset has been imported. Run again with -Phase Import -RightsReviewed after review.'
  } else {
    if (-not $RightsReviewed) {
      throw 'Import refused. Review SOURCE_LICENSE_REVIEW.csv and the linked source pages, then explicitly pass -RightsReviewed.'
    }
    # Downloading Commons candidates needs Pillow but intentionally not PyTorch.
    # Importing into the curated training dataset DOES require the training packages.
    & $python -c 'import torch, numpy, tifffile'
    if ($LASTEXITCODE -ne 0) {
      throw 'Training packages are missing from training\.venv. Run training\install-training-windows.bat before -Phase Import (the Download phase does not need torch).'
    }
    & $python -m aero_train.commons approved --output $source --minimum 30
    if ($LASTEXITCODE -ne 0) {throw 'Source ledger verification failed'}
    & $python -m aero_train.dataset_cli import-approved --source $source `
      --dataset $dataset --rights-confirmed
    if ($LASTEXITCODE -ne 0) {throw 'Clean-library import failed'}
    & $python -m aero_train.dataset_cli audit --dataset $dataset
    if ($LASTEXITCODE -ne 0) {throw 'General dataset audit failed'}
    Write-Host "READY FOR PRETRAINING: $dataset" -ForegroundColor Green
    Write-Host 'Data remains private. Credit/source details stay in the source ledger; do not commit them.'
  }
} finally {Pop-Location}
