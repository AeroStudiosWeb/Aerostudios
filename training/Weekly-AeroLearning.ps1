<#
AeroEnhance Community Learning (private operator workflow).

-Phase Review: writes a DENY-BY-DEFAULT review CSV, never replaces edits.
-Phase Train: requires review decisions, explicit operator approval and genuinely
  clean/rights-cleared original examples. Uses the incumbent checkpoint to
  initialize a NEW training run, compares both against a frozen benchmark.
NEVER automatically signs, uploads, distributes or activates a model.

Invoke from trusted PowerShell as the training operator, never from the client.
#>
[CmdletBinding()]
param(
  [ValidateSet('Review','Train')][string]$Phase = 'Review',
  [Parameter(Mandatory=$true)][string]$FeedbackDir,
  [Parameter(Mandatory=$true)][string]$ReviewCsv,
  [string]$BaseDataset = '',
  [string]$BenchmarkDataset = '',
  [string]$IncumbentCheckpoint = '',
  [string]$RunsRoot = '',
  [string]$AviationDataset = '',
  [int]$MinNewExamples = 10,
  [int]$Epochs = 8,
  [int]$StepsPerEpoch = 200,
  [int]$Batch = 4,
  [ValidateSet('cuda','cpu')][string]$Device = 'cuda',
  [switch]$ConfirmCuration
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$python = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
if (!(Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Install training Python environment first.' }
if (!(Test-Path -LiteralPath $FeedbackDir -PathType Container)) { throw 'Feedback directory not found. The live server must be configured separately.' }
$ReviewCsv = [IO.Path]::GetFullPath($ReviewCsv)
Push-Location $PSScriptRoot
try {
  if ($Phase -eq 'Review') {
    & $python -m aero_train.community_review --feedback-dir $FeedbackDir --output $ReviewCsv
    if ($LASTEXITCODE -ne 0) {throw 'Review preparation failed'}
    Write-Host 'Existing curator decisions were preserved, new examples default to NO, expired/withdrawn examples removed.'
    Write-Host 'Review originals and ownership. Set clean_confirmed AND license_checked to YES only where verified.'
    Write-Host 'Enhanced after.png files are NEVER treated as clean targets.'
    exit 0
  }
  if (-not $ConfirmCuration) {throw 'Explicit -ConfirmCuration required; do not automate this approval.'}
  foreach ($p in @($BaseDataset,$BenchmarkDataset,$IncumbentCheckpoint,$RunsRoot)) {
    if (-not $p) {throw 'Train requires -BaseDataset, -BenchmarkDataset, -IncumbentCheckpoint and -RunsRoot'}
  }
  if (!(Test-Path -LiteralPath $ReviewCsv -PathType Leaf)) {throw 'Review CSV missing. Run -Phase Review and review photos first.'}
  if (!(Test-Path -LiteralPath (Join-Path $BaseDataset 'manifest.jsonl') -PathType Leaf)) {throw 'Base dataset manifest missing.'}
  if (!(Test-Path -LiteralPath (Join-Path $BenchmarkDataset 'manifest.jsonl') -PathType Leaf)) {throw 'Independent benchmark dataset missing.'}
  if (!(Test-Path -LiteralPath $IncumbentCheckpoint -PathType Leaf)) {throw 'Incumbent checkpoint missing.'}
  if ($MinNewExamples -lt 10) {throw 'Need at least 10 independently reviewed new examples.'}
  New-Item -ItemType Directory -Path $RunsRoot -Force | Out-Null
  $marker = Join-Path $RunsRoot 'last-reviewed-feedback-fingerprint.txt'
  $approvedRows = @(Import-Csv -LiteralPath $ReviewCsv | Where-Object { $_.clean_confirmed -eq 'YES' -and $_.license_checked -eq 'YES' } | Sort-Object id)
  $approvedSignature = ($approvedRows | ForEach-Object { $_.id + ':' + $_.group }) -join '
'
  $sha = [Security.Cryptography.SHA256]::Create()
  try { $reviewHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($approvedSignature)))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
  if ((Test-Path $marker) -and ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $reviewHash)) {
    Write-Host 'No changes to reviewed feedback CSV since prior completed cycle; skipping.' -ForegroundColor Yellow
    exit 0
  }
  $runId = (Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+([Guid]::NewGuid().ToString('N').Substring(0,8))
  $run = Join-Path $RunsRoot $runId
  $dataset = Join-Path $run 'curated-dataset'
  New-Item -ItemType Directory -Path $dataset -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $BaseDataset 'manifest.jsonl') -Destination (Join-Path $dataset 'manifest.jsonl')
  & $python -m aero_train.dataset_cli curate-feedback --feedback-dir $FeedbackDir --reviewed-csv $ReviewCsv --dataset $dataset --curator-confirmation
  if ($LASTEXITCODE -ne 0) {throw 'Feedback rights/expiry/hash checks failed. Nothing trained.'}
  $lines = @(Get-Content -LiteralPath (Join-Path $dataset 'manifest.jsonl') | Where-Object {$_})
  $new = @($lines | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object {$_.source -eq 'feedback'}).Count
  if ($new -lt $MinNewExamples) {Write-Warning "Only $new eligible curated feedback examples. Not training this week (minimum $MinNewExamples)."; exit 0}
  & $python -m aero_train.dataset_cli audit --dataset $dataset
  if ($LASTEXITCODE -ne 0) {throw 'Curated dataset audit failed'}
  $modelRun = Join-Path $run 'candidate'
  $trainArgs = @{Dataset=$dataset;Output=$modelRun;Epochs=$Epochs;StepsPerEpoch=$StepsPerEpoch;Batch=$Batch;Device=$Device;InitCheckpoint=$IncumbentCheckpoint}
  if ($AviationDataset) {$trainArgs['AviationDataset']=$AviationDataset}
  & (Join-Path $PSScriptRoot 'Run-AeroTraining.ps1') @trainArgs
  if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {throw 'Training or export failed'}
  if (!(Test-Path -LiteralPath (Join-Path $modelRun 'aero-denoise.onnx') -PathType Leaf)) {throw 'Training did not export a validated model'}
  & $python -m aero_train.community_benchmark --candidate (Join-Path $modelRun 'best.pt') `
    --incumbent $IncumbentCheckpoint --benchmark-dataset $BenchmarkDataset --training-dataset $dataset `
    --output (Join-Path $run 'community-benchmark.json') --device $Device
  if ($LASTEXITCODE -ne 0) {throw 'Benchmark failed. The candidate is NOT eligible for publication.'}
  $report = Get-Content -LiteralPath (Join-Path $run 'community-benchmark.json') -Raw | ConvertFrom-Json
  Set-Content -LiteralPath $marker -Value $reviewHash -NoNewline
  Write-Host "Cycle outputs: $run" -ForegroundColor Cyan
  if ($report.gate.passed) {
    Write-Host 'CANDIDATE PASSED SYNTHETIC BENCHMARK, but still requires manual blind image review, staging, signing and deployment.' -ForegroundColor Yellow
  } else {
    Write-Host 'CANDIDATE FAILED; incumbent remains the recommended model. No deployment.' -ForegroundColor Yellow
  }
} finally {Pop-Location}
