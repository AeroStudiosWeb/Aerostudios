<#
AeroEnhance one-command private training / evaluation / ONNX export / review.
Does NOT publish/sign/upload or automatically retrain from customer photos.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Dataset,
  [Parameter(Mandatory=$true)][string]$Output,
  [string]$PairedDataset = '',
  [string]$ScunetModel = '',
  [string]$AviationDataset = '',
  [int]$Epochs = 20,
  [int]$StepsPerEpoch = 200,
  [int]$Batch = 4,
  [ValidateSet('cuda','cpu')][string]$Device = 'cuda',
  [switch]$SmokeTest,
  [switch]$Resume,
  [string]$InitCheckpoint = ''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$python=Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
  throw "Python training environment missing. Run training\install-training-windows.bat first."
}
if (-not (Test-Path -LiteralPath (Join-Path $Dataset 'manifest.jsonl'))) {
  throw "No curated clean dataset: $Dataset\manifest.jsonl"
}
if ($AviationDataset -and -not (Test-Path -LiteralPath (Join-Path $AviationDataset 'manifest.jsonl'))) {
  throw "Aviation dataset missing: $AviationDataset\manifest.jsonl"
}
if ($PairedDataset -and -not (Test-Path -LiteralPath (Join-Path $PairedDataset 'pairs.jsonl'))) {
  throw "No aligned-pair manifest in $PairedDataset"
}
if ($Epochs -lt 1 -or $StepsPerEpoch -lt 1 -or $Batch -lt 1) { throw 'Training sizes must be positive' }
New-Item -ItemType Directory -Force -Path $Output | Out-Null
Push-Location $PSScriptRoot
try {
  & $python -m aero_train.dataset_cli audit --dataset $Dataset
  if ($LASTEXITCODE -ne 0) {throw 'Clean dataset audit failed'}
  $pairFlags=@()
  if ($PairedDataset) {
    & $python -m aero_train.paired audit --dataset $PairedDataset
    if ($LASTEXITCODE -ne 0) {throw 'Paired dataset audit failed'}
    $pairFlags=@('--paired-dataset',$PairedDataset)
  }
  $trainFlags=@('--min-train-images','20')
  $evalFlags=@('--min-test-images','10')
  if ($SmokeTest) {
    Write-Warning 'SMOKE TEST ONLY: minimum dataset counts are reduced; results are NOT release quality.'
    $trainFlags=@('--min-train-images','1')
    $evalFlags=@('--min-test-images','1','--min-paired-test-images','1')
  }
  if ($Resume -and $InitCheckpoint) { throw 'Use -Resume OR -InitCheckpoint, not both.' }
  if ($InitCheckpoint -and -not (Test-Path -LiteralPath $InitCheckpoint -PathType Leaf)) { throw "Missing incumbent checkpoint: $InitCheckpoint" }
  $resumeFlags=@()
  if ($InitCheckpoint) { $resumeFlags=@('--init-checkpoint',$InitCheckpoint) }
  if ($Resume) {
    $prior=Join-Path $Output 'last.pt'
    if (-not (Test-Path -LiteralPath $prior -PathType Leaf)) {throw "No previous checkpoint at $prior"}
    $resumeFlags=@('--resume',$prior)
  }
  & $python -m aero_train.pipeline train --dataset $Dataset --output $Output --device $Device `
    --epochs $Epochs --steps-per-epoch $StepsPerEpoch --batch $Batch --patch 128 @pairFlags @trainFlags @resumeFlags
  if ($LASTEXITCODE -ne 0) {throw 'GPU training failed'}
  $best=Join-Path $Output 'best.pt'
  $report=Join-Path $Output 'heldout-report.json'
  $model=Join-Path $Output 'aero-denoise.onnx'
  & $python -m aero_train.pipeline evaluate --dataset $Dataset --checkpoint $best --output $report --device $Device --patch 256 @pairFlags @evalFlags
  if ($LASTEXITCODE -ne 0) {throw 'Held-out evaluation failed'}
  & $python -m aero_train.pipeline export --checkpoint $best --output $model
  if ($LASTEXITCODE -ne 0) {throw 'ONNX export or CPU equivalence test failed'}
  $comparison=Join-Path $Output 'review'
  $compare=@('--dataset',$Dataset,'--candidate',$model,'--output',$comparison)
  if ($PairedDataset) {$compare+=@('--paired-dataset',$PairedDataset)}
  if ($ScunetModel) {$compare+=@('--scunet',$ScunetModel)}
  & $python -m aero_train.compare @compare
  if ($LASTEXITCODE -ne 0) {throw 'Private model comparison failed'}
  if ($AviationDataset) {
    Write-Host 'Running separate AVIATION-DETAIL diagnostic. Aviation images are NOT used to fit the model.' -ForegroundColor Cyan
    $aviationFlags=@('--aviation-dataset',$AviationDataset,'--training-dataset',$Dataset,
                     '--candidate',$model,'--output',(Join-Path $Output 'aviation-review'))
    if ($ScunetModel) {$aviationFlags+=@('--scunet',$ScunetModel)}
    & $python -m aero_train.aviation @aviationFlags
    if ($LASTEXITCODE -ne 0) {throw 'Independent aviation diagnostic failed'}
  }
  Write-Host "DONE: $Output" -ForegroundColor Green
  Write-Host 'IMPORTANT: Review heldout-report.json, review\*.png and aviation-review before selecting the ONNX model.'
  Write-Host 'No model has been installed, signed, uploaded, or published.'
} finally {Pop-Location}
