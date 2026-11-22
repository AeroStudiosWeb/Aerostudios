<#
Copies a privately trained, integrity-checked ONNX model into AeroEnhance's
per-user model library. Does not publish and does not change user preferences.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Run,
  [string]$Version = '0.1.0-local',
  [switch]$AllowExperimental
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$model=Join-Path $Run 'aero-denoise.onnx'
$proof=$model+'.validation.json'
$evaluation=Join-Path $Run 'heldout-report.json'
if (-not (Test-Path $model -PathType Leaf) -or -not (Test-Path $proof -PathType Leaf)) {
  throw 'Run training and ONNX export before installing.'
}
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?$' -or $Version.Length -gt 80) {
  throw 'Use a semantic model version such as 0.1.0-local.'
}
$validation=Get-Content -LiteralPath $proof -Raw | ConvertFrom-Json
$actual=(Get-FileHash -LiteralPath $model -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $validation.sha256.ToLowerInvariant()) {throw 'ONNX SHA-256 differs from the verified export. Installation blocked.'}
if ($validation.input_shape -ne $null -and (($validation.input_shape -join ',') -ne '1,3,256,256')) {throw 'Unsupported model tensor shape'}
$gate=$false
if (Test-Path -LiteralPath $evaluation -PathType Leaf) {
  $report=Get-Content -LiteralPath $evaluation -Raw | ConvertFrom-Json
  $gate=($report.automatic_gate_passed -eq $true -and $report.checkpoint_sha256 -eq $validation.checkpoint_sha256)
}
if (-not $gate -and -not $AllowExperimental) {
  throw 'Held-out quality gate not passed (or missing). For PRIVATE experiments only, rerun with -AllowExperimental.'
}
if ($AllowExperimental) {Write-Warning 'Experimental model. NOT validated for release; never automatically publish.'}
if (-not $env:APPDATA) {throw 'APPDATA environment variable missing'}
$dir=Join-Path $env:APPDATA ('AeroStudios\AeroEnhance\models\aero-denoise\'+$Version)
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$target=Join-Path $dir 'aero-denoise.onnx'
if (Test-Path $target) {
  $prior=(Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($prior -ne $actual) {throw "Different model already installed at $target. Pick a NEW version; do not overwrite."}
} else {
  $temp=$target+'.partial'
  try {
    Copy-Item -LiteralPath $model -Destination $temp -Force
    if ((Get-FileHash $temp -Algorithm SHA256).Hash.ToLowerInvariant() -ne $actual) {throw 'Copy verification failed'}
    Move-Item -LiteralPath $temp -Destination $target
  } finally {if (Test-Path $temp) {Remove-Item $temp -Force}}
}
Copy-Item -LiteralPath $proof -Destination ($target+'.validation.json') -Force
Write-Host 'Local AI model installed and SHA-256 verified:' -ForegroundColor Green
Write-Host $target
Write-Host 'In AeroEnhance: AI inference > Refresh local models > select the trained model > Enable neural model.'
Write-Host 'SCUNet remains installed and selectable. No model was published to GitHub.'
