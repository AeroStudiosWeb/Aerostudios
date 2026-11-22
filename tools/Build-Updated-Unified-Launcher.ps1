<#
.SYNOPSIS
  Refresh ONLY AeroStudio-Launcher-Windows.zip, adding AeroEnhance to the existing shared GitHub release.
.DESCRIPTION
  Does not rebuild or alter the three existing applications, the website, or the AeroEnhance binary ZIP.
  Downloads/reads checksum metadata for the three existing app assets, then embeds pinned hashes.
  Replace only the unified launcher asset in your existing GitHub Release.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Updated-Unified-Launcher.ps1 -AeroEnhanceZip '.\dist\AeroEnhance-v0.7.0-beta.1-Windows-x64-CUDA.zip'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$AeroEnhanceZip,
    [string]$Owner = 'AeroStudiosWeb',
    [string]$Repository = 'AeroStudios',
    [string]$Tag = 'v0.1.0-beta.1',
    [string]$OutputDirectory = 'release-out',
    [string]$ExistingAssetsDirectory = 'release-out',
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Owner -notmatch '^[A-Za-z0-9-]+$' -or $Repository -notmatch '^[A-Za-z0-9_.-]+$' -or $Tag -notmatch '^[A-Za-z0-9_.-]+$') {
    throw 'Invalid GitHub owner, repository, or release tag.'
}
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
function Resolve-RepoPath([string]$value) {
    if ([IO.Path]::IsPathRooted($value)) { return $value }
    return Join-Path $Root $value
}
$AeroEnhanceZip = Resolve-RepoPath $AeroEnhanceZip
$OutputDirectory = Resolve-RepoPath $OutputDirectory
$ExistingAssetsDirectory = Resolve-RepoPath $ExistingAssetsDirectory
if (-not (Test-Path -LiteralPath $AeroEnhanceZip -PathType Leaf)) { throw "AeroEnhance release ZIP not found: $AeroEnhanceZip" }
$enhanceAsset = [IO.Path]::GetFileName($AeroEnhanceZip)
if ($enhanceAsset -notmatch '^AeroEnhance-v[\w.+-]+-Windows-x64-(CUDA|CPU)\.zip$') {
    throw 'Choose the compiled AeroEnhance-v...-Windows-x64-CUDA.zip (or CPU.zip), not the source ZIP.'
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$inputZip = [IO.Compression.ZipFile]::OpenRead($AeroEnhanceZip)
try {
    # The installer can handle an extra wrapping folder in a release ZIP.
    # Identify the actual executable and validate the DLLs next to it instead of
    # requiring one exact archive root. Never trust a ZIP based on its filename.
    $files = @($inputZip.Entries | Where-Object { -not $_.FullName.EndsWith('/') })
    $executables = @($files | Where-Object {
        $entryName = $_.FullName.Replace('\', '/')
        [IO.Path]::GetFileName($entryName) -ieq 'AeroEnhance-Studio.exe'
    })
    if ($executables.Count -ne 1) {
        $example = (@($files | Select-Object -First 25 | ForEach-Object { $_.FullName }) -join '; ')
        throw "AeroEnhance ZIP must contain exactly one AeroEnhance-Studio.exe; found $($executables.Count). Selected archive: $AeroEnhanceZip. First entries: $example"
    }
    $executableEntry = $executables[0].FullName.Replace('\', '/')
    $parentPrefix = $executableEntry.Substring(0, $executableEntry.Length - 'AeroEnhance-Studio.exe'.Length)
    if ($enhanceAsset -match '-CUDA\.zip$') {
        foreach ($name in @('onnxruntime_providers_cuda.dll','onnxruntime_providers_shared.dll')) {
            $requiredEntry = "$parentPrefix$name"
            $matching = @($files | Where-Object { $_.FullName.Replace('\', '/') -ieq $requiredEntry })
            if ($matching.Count -ne 1) {
                $dllNames = @($files | Where-Object { $_.FullName -match '(?i)onnxruntime.*\.dll$' } | ForEach-Object { $_.FullName }) -join '; '
                throw "Incomplete CUDA ZIP: expected $requiredEntry beside $executableEntry, found $($matching.Count). DLL entries: $dllNames. Repackage from the compiled build; do not publish this ZIP."
            }
        }
    }
    Write-Host "Validated AeroEnhance executable: $executableEntry" -ForegroundColor Green
} finally { $inputZip.Dispose() }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$Base = "https://github.com/$Owner/$Repository/releases/download/$Tag"
$apps = @('AeroRoom','AeroFilm','AeroPhoto')
$Manifest = [ordered]@{}
$apiAssets = @()
if (-not $Offline) {
    try {
        $api = "https://api.github.com/repos/$Owner/$Repository/releases/tags/$Tag"
        $headers = @{ 'User-Agent'='AeroStudio-Release-Builder'; 'Accept'='application/vnd.github+json' }
        if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
        $release = Invoke-RestMethod -Uri $api -Headers $headers -UseBasicParsing
        if ($release.tag_name -ne $Tag) { throw 'GitHub returned an unexpected release tag.' }
        $apiAssets = @($release.assets)
        Write-Host "Found shared release: $Tag" -ForegroundColor Cyan
    } catch {
        Write-Warning "Cannot read GitHub Release API; falling back to local assets if present: $($_.Exception.Message)"
    }
}
foreach ($id in $apps) {
    $assetName = "$id-Windows.zip"
    $remoteAsset = @($apiAssets | Where-Object {$_.name -eq $assetName} | Select-Object -First 1)
    if ($apiAssets.Count -gt 0 -and $remoteAsset.Count -eq 0) { throw "Existing GitHub Release does not contain $assetName" }
    $hash = $null
    $digest = ''
    if ($remoteAsset.Count -gt 0 -and $remoteAsset[0].PSObject.Properties['digest']) { $digest = [string]$remoteAsset[0].digest }
    if ($digest -match '^sha256:([0-9a-fA-F]{64})$') {
        $hash = $Matches[1].ToLowerInvariant()
        Write-Host "Using GitHub SHA256 digest for $assetName" -ForegroundColor DarkCyan
    } else {
        $local = Join-Path $ExistingAssetsDirectory $assetName
        if ($remoteAsset.Count -gt 0) {
            # Prefer the exact published ZIP over potentially stale local copies.
            $tmp = Join-Path $env:TEMP ('aerostudio-download-' + [guid]::NewGuid().ToString('N') + '.zip')
            try {
                Write-Host "Downloading published $assetName to verify its SHA256..." -ForegroundColor Cyan
                Invoke-WebRequest -Uri $remoteAsset[0].browser_download_url -OutFile $tmp -UseBasicParsing
                $hash = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
            } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        } elseif (Test-Path -LiteralPath $local -PathType Leaf) {
            Write-Warning "Using offline local ZIP for $assetName. Ensure it is byte-for-byte identical to the published release asset."
            $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    if (-not $hash) { throw "Cannot hash $assetName. Connect to GitHub or provide the original published ZIP in $ExistingAssetsDirectory." }
    $Manifest[$id] = [ordered]@{ version=$Tag; url="$Base/$assetName"; sha256=$hash }
}
$enhanceSha = (Get-FileHash -LiteralPath $AeroEnhanceZip -Algorithm SHA256).Hash.ToLowerInvariant()
$Manifest['AeroEnhance'] = [ordered]@{
    version=($enhanceAsset -replace '^AeroEnhance-v','' -replace '-Windows-x64-(CPU|CUDA)\.zip$','')
    url="$Base/$enhanceAsset"
    sha256=$enhanceSha
}
$Template = Join-Path $Root 'launcher-template'
$stage = Join-Path $env:TEMP ('aerostudio-unified-launcher-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
try {
    foreach ($folder in @('Launcher','scripts')) { New-Item -ItemType Directory -Force -Path (Join-Path $stage $folder) | Out-Null }
    Copy-Item -LiteralPath (Join-Path $Template 'AeroStudio.cmd') -Destination (Join-Path $stage 'AeroStudio.cmd')
    Copy-Item -LiteralPath (Join-Path $Template 'Launcher/AeroStudio-Launcher.ps1') -Destination (Join-Path $stage 'Launcher/AeroStudio-Launcher.ps1')
    Copy-Item -LiteralPath (Join-Path $Template 'scripts/Install-App.ps1') -Destination (Join-Path $stage 'scripts/Install-App.ps1')
    $Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $stage 'Launcher/releases.json') -Encoding UTF8
    foreach ($id in $apps) {
        $icon = if ($id -eq 'AeroRoom') {'assets/app-icon/aeroroom.png'} else {'assets/aerostudio/icon.png'}
        $src = Join-Path $Template "Apps/$id/$icon"
        $dst = Join-Path $stage "Apps/$id/$icon"
        New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst
    }
    # Include the AeroEnhance card artwork alongside the three existing app icons.
    $enhanceIcon = 'Apps/AeroEnhance/assets/aerostudio/icon.png'
    $enhanceSrc = Join-Path $Template $enhanceIcon
    $enhanceDst = Join-Path $stage $enhanceIcon
    New-Item -ItemType Directory -Force -Path (Split-Path $enhanceDst -Parent) | Out-Null
    Copy-Item -LiteralPath $enhanceSrc -Destination $enhanceDst
    @(
        'AeroStudio Unified Windows Launcher - four apps',
        'Double-click AeroStudio.cmd.',
        'The launcher installs AeroEnhance with CUDA runtime provider DLLs and model setup scripts.',
        'You must upload the exact AeroEnhance ZIP used to generate this launcher to the same release tag.',
        'Downloads are SHA-256 pinned to their respective release assets.',
        'AeroEnhance uses Install ZIP, not Use EXE, so supporting DLLs are preserved.'
    ) | Set-Content -LiteralPath (Join-Path $stage 'README.txt') -Encoding UTF8
    $out = Join-Path $OutputDirectory 'AeroStudio-Launcher-Windows.zip'
    if (Test-Path -LiteralPath $out) {
        $backup = $out + '.previous'
        Copy-Item -LiteralPath $out -Destination $backup -Force
    }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $out -CompressionLevel Optimal -Force
    $sha = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath ($out+'.sha256') -Value "$sha  AeroStudio-Launcher-Windows.zip" -Encoding Ascii
    # Keep the shared release's published SHA256SUMS.txt consistent with the updated asset.
    $sumFile = Join-Path $OutputDirectory 'SHA256SUMS.txt'
    $sumSource = $null
    if (Test-Path -LiteralPath $sumFile -PathType Leaf) {
        $sumSource = $sumFile
    } else {
        $sumAsset = @($apiAssets | Where-Object {$_.name -eq 'SHA256SUMS.txt'} | Select-Object -First 1)
        if ($sumAsset.Count -gt 0) {
            $sumSource = Join-Path $env:TEMP ('aerostudio-sums-' + [guid]::NewGuid().ToString('N') + '.txt')
            try { Invoke-WebRequest -Uri $sumAsset[0].browser_download_url -OutFile $sumSource -UseBasicParsing }
            catch { Write-Warning "Could not retrieve previous SHA256SUMS.txt: $($_.Exception.Message)"; $sumSource = $null }
        }
    }
    $sums = [ordered]@{}
    if ($sumSource -and (Test-Path -LiteralPath $sumSource)) {
        foreach ($line in (Get-Content -LiteralPath $sumSource)) {
            if ($line -match '^([a-fA-F0-9]{64})\s+\*?([A-Za-z0-9_.+-]+)$') {
                $sums[$Matches[2]] = $Matches[1].ToLowerInvariant()
            }
        }
    }
    foreach ($id in $apps) { $sums["$id-Windows.zip"] = [string]$Manifest[$id].sha256 }
    $sums[$enhanceAsset] = $enhanceSha
    $sums['AeroStudio-Launcher-Windows.zip'] = $sha
    $sumLines = @($sums.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Value)  $($_.Name)" })
    $sumLines | Set-Content -LiteralPath $sumFile -Encoding Ascii
    if ($sumSource -and $sumSource -ne $sumFile) { Remove-Item -LiteralPath $sumSource -Force -ErrorAction SilentlyContinue }
    Write-Host "READY: $out" -ForegroundColor Green
    Write-Host "Updated checksums: $sumFile" -ForegroundColor Green
    Write-Host "Release tag: $Tag"
    Write-Host "Pinned AeroEnhance archive: $enhanceAsset"
    Write-Host 'Replace the AeroStudio-Launcher-Windows.zip AND SHA256SUMS.txt assets in the same GitHub Release.' -ForegroundColor Yellow
    Write-Host 'Upload the compiled AeroEnhance ZIP to the SAME release if it is not uploaded yet.' -ForegroundColor Yellow
    Write-Host 'Do not upload the launcher as a normal source file or delete other application assets.'
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
