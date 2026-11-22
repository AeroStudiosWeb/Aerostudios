# AeroEnhance Studio private-beta packaging for ort 2.0.0-rc.15.
# ort 2.0.0-rc.15 statically links ONNX Runtime into the Rust executable.
# Therefore onnxruntime.dll is NOT required. CUDA EP provider DLLs still are.
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][ValidateSet('CPU','CUDA')][string]$Variant,
 [Parameter(Mandatory=$true)][string]$TargetDir,
 [string]$OutputDir='dist',
 [string]$OrtProviderDir=''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not [IO.Path]::IsPathRooted($TargetDir)) { $TargetDir = Join-Path $repo $TargetDir }
if (-not [IO.Path]::IsPathRooted($OutputDir)) { $OutputDir = Join-Path $repo $OutputDir }
$release = Join-Path $TargetDir 'release'
$exe = Join-Path $release 'aeroenhance-studio.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Compiled EXE missing: $exe" }
$toml = Get-Content -Raw -LiteralPath (Join-Path $repo 'apps/aeroenhance/Cargo.toml')
if ($toml -notmatch '(?m)^version\s*=\s*"([^"\r\n]+)"') { throw 'Cannot find app version in Cargo.toml' }
$version = $Matches[1]
if ($toml -notmatch 'version\s*=\s*"=2\.0\.0-rc\.15"') {
    throw 'This packager expects statically linked ort =2.0.0-rc.15. Review DLL requirements before using with another version.'
}
$name = "AeroEnhance-v$version-Windows-x64-$Variant"

# Search for provider DLL pairs, preferring DLLs already copied into THIS build's release folder.
# If multiple cached builds exist, verify the reported source path before any public release.
$runtimeFolder = $null
if ($Variant -eq 'CUDA') {
    $roots = @()
    if ($OrtProviderDir) {
        if (-not (Test-Path -LiteralPath $OrtProviderDir -PathType Container)) { throw "ORT provider folder not found: $OrtProviderDir" }
        $roots += [pscustomobject]@{ Path=$OrtProviderDir; Recursive=$false }
    } else {
        $roots += [pscustomobject]@{ Path=$release; Recursive=$false }
        $roots += [pscustomobject]@{ Path=(Join-Path $release 'build'); Recursive=$true }
        $localOrt = Join-Path $env:LOCALAPPDATA 'ort.pyke.io'
        if (Test-Path -LiteralPath $localOrt) { $roots += [pscustomobject]@{ Path=$localOrt; Recursive=$true } }
        $homeOrt = Join-Path $env:USERPROFILE '.cache/ort.pyke.io'
        if (Test-Path -LiteralPath $homeOrt) { $roots += [pscustomobject]@{ Path=$homeOrt; Recursive=$true } }
    }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root.Path -PathType Container)) { continue }
        $doRecurse = [bool]$root.Recursive
        $files = @(Get-ChildItem -LiteralPath $root.Path -File -Filter 'onnxruntime_providers_cuda.dll' -Recurse:$doRecurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
        foreach ($file in $files) {
            $shared = Join-Path $file.DirectoryName 'onnxruntime_providers_shared.dll'
            if (Test-Path -LiteralPath $shared -PathType Leaf) {
                $runtimeFolder = $file.DirectoryName
                break
            }
        }
        if ($runtimeFolder) { break }
    }
    if (-not $runtimeFolder) {
        $where = if ($OrtProviderDir) { $OrtProviderDir } else { "$release; $localOrt; $homeOrt" }
        throw "CUDA provider pair NOT FOUND: onnxruntime_providers_cuda.dll + onnxruntime_providers_shared.dll in one folder. Searched: $where. Because ort rc.15 is statically linked, onnxruntime.dll is NOT needed. Run the DLL diagnostic in the patch README. Do not publish until the CUDA DLLs are located."
    }
    Write-Host "CUDA provider DLLs: $runtimeFolder" -ForegroundColor Cyan
} else {
    Write-Host 'CPU build: ort 2.0.0-rc.15 is statically linked; no ONNX Runtime DLL required.' -ForegroundColor Cyan
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$stage = Join-Path $OutputDir ('.staging-' + $name)
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
$app = Join-Path $stage 'AeroEnhance-Studio'
New-Item -ItemType Directory -Force -Path $app | Out-Null
try {
    Copy-Item -LiteralPath $exe -Destination (Join-Path $app 'AeroEnhance-Studio.exe')
    $required = @()
    if ($Variant -eq 'CUDA') {
        $required = @('onnxruntime_providers_cuda.dll','onnxruntime_providers_shared.dll')
        foreach ($fn in $required) {
            $src = Join-Path $runtimeFolder $fn
            if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "Required CUDA provider missing: $src" }
            Copy-Item -LiteralPath $src -Destination (Join-Path $app $fn)
        }
    }
    $extras = @(
        @('apps/aeroenhance/download-scunet-model.ps1','download-scunet-model.ps1'),
        @('apps/aeroenhance/download-scunet-model.bat','download-scunet-model.bat'),
        @('apps/aeroenhance/diagnose-gpu.ps1','diagnose-gpu.ps1'),
        @('apps/aeroenhance/diagnose-gpu.bat','diagnose-gpu.bat'),
        @('tools/release/USER_INSTALL.txt','READ_ME_FIRST.txt')
    )
    foreach ($pair in $extras) {
        $src = Join-Path $repo $pair[0]
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "Packaging input missing: $src" }
        Copy-Item -LiteralPath $src -Destination (Join-Path $app $pair[1])
    }
    $lic = Join-Path $app 'licenses/AeroRoom-RAW'
    New-Item -ItemType Directory -Force -Path $lic | Out-Null
    foreach ($fn in @('LICENSE-APACHE','LICENSE-MIT','NOTICE','SOURCE_PROVENANCE.md')) {
        $src = Join-Path $repo ('shared/aeroroom-raw-engine/'+$fn)
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "License file missing: $src" }
        Copy-Item -LiteralPath $src -Destination $lic
    }
    Set-Content -LiteralPath (Join-Path $app 'Start-AeroEnhance.bat') -Encoding Ascii -Value '@echo off', 'cd /d "%~dp0"', 'start "" "AeroEnhance-Studio.exe"'
    $provenance = @("Variant: $Variant",'ORT crate: 2.0.0-rc.15, main runtime statically linked',"CUDA provider DLL folder: $runtimeFolder",'NVIDIA CUDA and cuDNN libraries NOT bundled; install compatible runtime separately.')
    foreach ($fn in $required) {
        $checksum = (Get-FileHash -LiteralPath (Join-Path $app $fn) -Algorithm SHA256).Hash.ToLowerInvariant()
        $provenance += "SHA256 ${fn}: $checksum"
    }
    Set-Content -LiteralPath (Join-Path $app 'RUNTIME_DLL_SOURCE.txt') -Encoding UTF8 -Value $provenance
    $zip = Join-Path $OutputDir ($name+'.zip')
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
    # Check the exact delivered ZIP, not just the staging directory.
    $verify = Join-Path $stage '_verify'
    Expand-Archive -LiteralPath $zip -DestinationPath $verify -Force
    foreach ($fn in (@('AeroEnhance-Studio.exe') + $required)) {
        $expected = Join-Path $verify ('AeroEnhance-Studio/'+$fn)
        if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) { throw "Created ZIP missing: $fn" }
    }
    $sha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath ($zip+'.sha256') -Encoding Ascii -Value "$sha  $(Split-Path $zip -Leaf)"
    Write-Host "PACKAGE READY: $zip" -ForegroundColor Green
    Write-Host "SHA256: $sha"
    Write-Warning 'Private beta only. A verified ZIP is not proof that CUDA inference works; run the model and CUDA Strict mode on a clean Windows PC before publishing.'
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
