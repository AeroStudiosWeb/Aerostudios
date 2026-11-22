<#
AeroEnhance PRIVATE optional repeating training cycle. Operator may schedule with
Windows Task Scheduler AFTER configuring a licensed curated dataset. Never
publishes or signs a model. It never reads uncurated live submissions.
#>
param(
  [Parameter(Mandatory=$true)][string]$Dataset,
  [Parameter(Mandatory=$true)][string]$Runs,
  [int]$Epochs = 20
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
  $hash = (Get-FileHash $manifest -Algorithm SHA256).Hash.ToLowerInvariant()
  $marker = Join-Path $Runs 'last-private-cycle-sha256.txt'
  if ((Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq $hash)) {
    Write-Output 'No newly curated manifest; skipping GPU retraining.'
    exit 0
  }
  $run = Join-Path $Runs (Get-Date -Format 'yyyyMMdd-HHmmss')
  New-Item -ItemType Directory -Force $run | Out-Null
  & $python -m aero_train.pipeline train --dataset $Dataset --output $run --device cuda --epochs $Epochs --steps-per-epoch 200 --batch 4 --patch 128 --amp
  if ($LASTEXITCODE -ne 0) { throw 'Training failed; no cycle marker written' }
  & $python -m aero_train.pipeline evaluate --dataset $Dataset --checkpoint (Join-Path $run 'best.pt') --output (Join-Path $run 'heldout-report.json') --device cuda --patch 256
  if ($LASTEXITCODE -ne 0) { throw 'Evaluation failed; no cycle marker written' }
  & $python -m aero_train.pipeline export --checkpoint (Join-Path $run 'best.pt') --output (Join-Path $run 'aero-denoise.onnx')
  if ($LASTEXITCODE -ne 0) { throw 'ONNX export failed; no cycle marker written' }
  Set-Content -Path $marker -Value $hash -NoNewline
  Write-Output "Private candidate created in $run. Review heldout-report.json. NOTHING was distributed."
}
finally { Pop-Location }
