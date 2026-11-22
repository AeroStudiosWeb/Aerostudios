<#
.SYNOPSIS
  Packages AeroStudio Windows builds into GitHub Release ZIPs, including four download launchers.
.DESCRIPTION
  Run on your Windows computer AFTER all three Rust applications have compiled and been
  installed using the AeroStudio development launcher.
  This script does NOT compile applications and does NOT upload anything to GitHub.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Make-Windows-Release.ps1 -Owner YOUR_GITHUB_USERNAME
#>
param(
  [Parameter(Mandatory=$true)][string]$Owner,
  [string]$Repository = 'AeroStudio',
  [string]$Tag = 'v0.1.0-beta.1',
  [string]$AeroRoomExe = "$env:LOCALAPPDATA\AeroStudio\Apps\AeroRoom\AeroRoomStudio.exe",
  [string]$AeroFilmExe = "$env:LOCALAPPDATA\AeroStudio\Apps\AeroFilm\AeroFilmStudio.exe",
  [string]$AeroPhotoExe = "$env:LOCALAPPDATA\AeroStudio\Apps\AeroPhoto\AeroPhotoStudio.exe",
  [string]$AeroEnhanceZip = "",
  [string]$OutputDirectory
)
$ErrorActionPreference='Stop'
if($Owner -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37})$') { throw 'Use your GitHub account name for -Owner (letters, numbers or hyphens).' }
if($Repository -notmatch '^[A-Za-z0-9_.-]+$' -or $Tag -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Invalid repository or release tag.' }
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if(-not $OutputDirectory) { $OutputDirectory = Join-Path $Root 'release-out' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path $OutputDirectory).Path
$Template = Join-Path $Root 'launcher-template'
$Base = "https://github.com/$Owner/$Repository/releases/download/$Tag"
$Applications = @(
  @{Id='AeroRoom'; Target='AeroRoomStudio.exe'; Input=$AeroRoomExe},
  @{Id='AeroFilm'; Target='AeroFilmStudio.exe'; Input=$AeroFilmExe},
  @{Id='AeroPhoto'; Target='AeroPhotoStudio.exe'; Input=$AeroPhotoExe}
)
$Scratch = Join-Path ([IO.Path]::GetTempPath()) ('aerostudio-release-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $Scratch | Out-Null
function New-Stage([string]$Name) {
  $p=Join-Path $Scratch $Name
  New-Item -ItemType Directory -Force -Path $p | Out-Null
  return $p
}
function Zip-Stage([string]$Stage,[string]$Asset) {
  $output=Join-Path $OutputDirectory $Asset
  if(Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }
  Compress-Archive -Path (Join-Path $Stage '*') -DestinationPath $output -CompressionLevel Optimal
  $size=(Get-Item -LiteralPath $output).Length
  Write-Host ('  {0} ({1:N1} MiB)' -f $Asset,($size/1MB)) -ForegroundColor Green
  return $output
}
function Assert-WindowsExecutable([string]$Path,[string]$Name) {
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing $Name binary: $Path. Build or install the app first." }
  $file=Get-Item -LiteralPath $Path
  if($file.Length -lt 100000) { throw "The $Name executable looks too small ($($file.Length) bytes): $Path" }
  $stream=[IO.File]::OpenRead($Path)
  try {
    if($stream.ReadByte() -ne 77 -or $stream.ReadByte() -ne 90){throw "$Name is not a Windows PE executable (MZ header missing)."}
  } finally { $stream.Dispose() }
}
function Copy-LauncherCore([string]$Destination) {
  New-Item -ItemType Directory -Force -Path (Join-Path $Destination 'Launcher') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Destination 'scripts') | Out-Null
  Copy-Item -LiteralPath (Join-Path $Template 'scripts\Install-App.ps1') -Destination (Join-Path $Destination 'scripts\Install-App.ps1')
  foreach($app in $Applications) {
    $icon = if($app.Id -eq 'AeroRoom') { 'assets\app-icon\aeroroom.png' } else { 'assets\aerostudio\icon.png' }
    $source = Join-Path $Template "Apps\$($app.Id)\$icon"
    $dest = Join-Path $Destination "Apps\$($app.Id)\$icon"
    New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent) | Out-Null
    Copy-Item -LiteralPath $source -Destination $dest
  }
  # The four-app launcher renders a matching icon for AeroEnhance, too.
  $enhanceIcon = 'Apps\AeroEnhance\assets\aerostudio\icon.png'
  $enhanceTarget = Join-Path $Destination $enhanceIcon
  New-Item -ItemType Directory -Force -Path (Split-Path $enhanceTarget -Parent) | Out-Null
  Copy-Item -LiteralPath (Join-Path $Template $enhanceIcon) -Destination $enhanceTarget
}
try {
  Write-Host 'Checking Windows executables...' -ForegroundColor Cyan
  foreach($app in $Applications) { Assert-WindowsExecutable $app.Input $app.Id }
  # Create the three application ZIPs before launchers so launchers can pin their SHA-256 digests.
  $Manifest = [ordered]@{}
  foreach($app in $Applications) {
    $stage = New-Stage ("binary-" + $app.Id)
    Copy-Item -LiteralPath $app.Input -Destination (Join-Path $stage $app.Target)
    $licences = Join-Path $stage 'Licences'
    New-Item -ItemType Directory -Force -Path $licences | Out-Null
    $licenseSource = Join-Path $Root "licenses\$($app.Id)"
    if(-not (Test-Path (Join-Path $licenseSource 'LICENSE-MIT')) -or -not (Test-Path (Join-Path $licenseSource 'LICENSE-APACHE'))) { throw "Upstream licences missing for $($app.Id)" }
    Copy-Item -Path (Join-Path $licenseSource '*') -Destination $licences -Force
    @("$($app.Id) | AeroStudio Windows beta",'',"Extract this ZIP and run $($app.Target).",'Keep the included licence and attribution files when redistributing.','This application is a beta. Test with copies of important photographs and projects.') | Set-Content -LiteralPath (Join-Path $stage 'READ-ME-FIRST.txt') -Encoding UTF8
    $name = "$($app.Id)-Windows.zip"
    $archive = Zip-Stage $stage $name
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $Manifest[$app.Id] = [ordered]@{version=$Tag;url="$Base/$name";sha256=$hash}
  }
  # AeroEnhance ships as a FULL distribution, not an EXE-only archive.
  # Optional to retain compatibility with releases containing only the original three apps.
  if ($AeroEnhanceZip) {
    if (-not [IO.Path]::IsPathRooted($AeroEnhanceZip)) { $AeroEnhanceZip = Join-Path $Root $AeroEnhanceZip }
    if (-not (Test-Path -LiteralPath $AeroEnhanceZip -PathType Leaf)) { throw "Missing AeroEnhance packaged ZIP: $AeroEnhanceZip" }
    $enhanceName = [IO.Path]::GetFileName($AeroEnhanceZip)
    if ($enhanceName -notmatch '^AeroEnhance-v[\w.+-]+-Windows-x64-(CUDA|CPU)\.zip$') { throw 'AeroEnhanceZip must be a versioned compiled Windows CPU or CUDA ZIP.' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $inspect = [IO.Compression.ZipFile]::OpenRead($AeroEnhanceZip)
    try {
      $inside = @($inspect.Entries | ForEach-Object { $_.FullName.Replace('\','/') })
      if (-not ($inside -contains 'AeroEnhance-Studio/AeroEnhance-Studio.exe')) { throw 'AeroEnhance release archive is missing the executable.' }
      if ($enhanceName -match '-CUDA\.zip$') {
        foreach ($fn in @('onnxruntime_providers_cuda.dll','onnxruntime_providers_shared.dll')) {
          if (-not ($inside -contains "AeroEnhance-Studio/$fn")) { throw "AeroEnhance CUDA release archive is missing $fn" }
        }
      }
    } finally { $inspect.Dispose() }
    $enhanceDestination = Join-Path $OutputDirectory $enhanceName
    if (([IO.Path]::GetFullPath($AeroEnhanceZip)) -ne ([IO.Path]::GetFullPath($enhanceDestination))) {
      Copy-Item -LiteralPath $AeroEnhanceZip -Destination $enhanceDestination -Force
    }
    $enhanceHash = (Get-FileHash -LiteralPath $enhanceDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    $Manifest['AeroEnhance'] = [ordered]@{version=$Tag;url="$Base/$enhanceName";sha256=$enhanceHash}
  } else {
    $Manifest['AeroEnhance'] = [ordered]@{version=$Tag;url='';sha256=''}
  }
  # Fill the manifest embedded in the launchers with pinned release URLs and hashes.
  $manifestJSON = $Manifest | ConvertTo-Json -Depth 6
  $main = New-Stage 'suite-launcher'
  Copy-LauncherCore $main
  Copy-Item -LiteralPath (Join-Path $Template 'AeroStudio.cmd') -Destination (Join-Path $main 'AeroStudio.cmd')
  Copy-Item -LiteralPath (Join-Path $Template 'Launcher\AeroStudio-Launcher.ps1') -Destination (Join-Path $main 'Launcher\AeroStudio-Launcher.ps1')
  $manifestJSON | Set-Content -LiteralPath (Join-Path $main 'Launcher\releases.json') -Encoding UTF8
  @('AeroStudio Suite Launcher','Double-click AeroStudio.cmd. Choose Download under the application you want.','Apps are downloaded individually and verified by SHA-256 before installation.','Build/Install is unavailable in this lightweight release (it requires the full source checkout).') | Set-Content -LiteralPath (Join-Path $main 'README.txt') -Encoding UTF8
  [void](Zip-Stage $main 'AeroStudio-Launcher-Windows.zip')
  foreach($app in $Applications) {
    $stage = New-Stage ("launcher-" + $app.Id)
    Copy-LauncherCore $stage
    Copy-Item -LiteralPath (Join-Path $Template 'Launcher\AeroStudio-Single.ps1') -Destination (Join-Path $stage 'Launcher\AeroStudio-Single.ps1')
    $manifestJSON | Set-Content -LiteralPath (Join-Path $stage 'Launcher\releases.json') -Encoding UTF8
    $cmd = @(
      '@echo off',
      'setlocal',
      'cd /d "%~dp0"',
      "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Launcher\AeroStudio-Single.ps1`" -App $($app.Id)",
      'if errorlevel 1 pause'
    )
    $cmd | Set-Content -LiteralPath (Join-Path $stage "$($app.Id).cmd") -Encoding Ascii
    @("$($app.Id) individual launcher", "Double-click $($app.Id).cmd to download, install or launch $($app.Id) Studio.", 'This downloader verifies the official release with the SHA-256 fingerprint embedded in Launcher\releases.json.') | Set-Content -LiteralPath (Join-Path $stage 'README.txt') -Encoding UTF8
    [void](Zip-Stage $stage "$($app.Id)-Launcher-Windows.zip")
  }
  if ($AeroEnhanceZip) {
    $stage = New-Stage 'launcher-AeroEnhance'
    Copy-LauncherCore $stage
    Copy-Item -LiteralPath (Join-Path $Template 'Launcher\AeroStudio-Single.ps1') -Destination (Join-Path $stage 'Launcher\AeroStudio-Single.ps1')
    $manifestJSON | Set-Content -LiteralPath (Join-Path $stage 'Launcher\releases.json') -Encoding UTF8
    @('@echo off','setlocal','cd /d "%~dp0"','powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Launcher\AeroStudio-Single.ps1" -App AeroEnhance','if errorlevel 1 pause') | Set-Content -LiteralPath (Join-Path $stage 'AeroEnhance.cmd') -Encoding Ascii
    @('AeroEnhance individual launcher','Run AeroEnhance.cmd to download/launch AeroEnhance Studio.','The full release ZIP is downloaded with its required CUDA provider DLLs.') | Set-Content -LiteralPath (Join-Path $stage 'README.txt') -Encoding UTF8
    [void](Zip-Stage $stage 'AeroEnhance-Launcher-Windows.zip')
  }
  # The website looks up exactly this version tag. It enables only download assets actually uploaded.
  $config = @"
/* Generated by Make-Windows-Release.ps1; keep in sync with the GitHub release tag. */
window.AEROSTUDIO_CONFIG = Object.freeze({
  githubOwner: '$Owner',
  githubRepo: '$Repository',
  releaseTag: '$Tag'
});
"@
  $config | Set-Content -LiteralPath (Join-Path $Root 'docs\config.js') -Encoding UTF8
  $lines = @('AeroStudio Windows beta release '+$Tag,'','Upload all generated .zip assets from this folder to the GitHub Release with tag '+$Tag+'.','','SHA-256 checksums:')
  Get-ChildItem -LiteralPath $OutputDirectory -Filter '*.zip' -File | Sort-Object Name | ForEach-Object {
    $sha = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $lines += "$sha  $($_.Name)"
  }
  $lines | Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding Ascii
  Write-Host ''
  Write-Host 'SUCCESS: AeroStudio release archives prepared.' -ForegroundColor Green
  Write-Host "Output: $OutputDirectory"
  Write-Host 'The website config.js was updated with your GitHub owner, repo and release tag.'
  Write-Host 'Create or edit the matching GitHub Release and upload the generated ZIPs plus SHA256SUMS.txt.'
} finally {
  Remove-Item -LiteralPath $Scratch -Recurse -Force -ErrorAction SilentlyContinue
}
