param(
    [Parameter(Mandatory=$true)][ValidateSet('AeroRoom','AeroFilm','AeroPhoto','AeroEnhance')][string]$App,
    [Parameter(Mandatory=$true)][ValidateSet('Build','LocalZip','LocalExe','Download')][string]$Method,
    [string]$ZipPath,
    [string]$ExePath,
    [string]$BuildTargetDir,
    [switch]$PauseOnExit
)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$Definitions = @{
    AeroRoom  = @{ Folder='AeroRoom';  Package='lightcraft'; SourceExe='lightcraft.exe'; TargetExe='AeroRoomStudio.exe'  }
    AeroFilm  = @{ Folder='AeroFilm';  Package='filmcraft';  SourceExe='filmcraft.exe';  TargetExe='AeroFilmStudio.exe'  }
    AeroPhoto = @{ Folder='AeroPhoto'; Package='photocraft'; SourceExe='photocraft.exe';TargetExe='AeroPhotoStudio.exe' }
    AeroEnhance = @{ Folder='AeroEnhance'; Package='aeroenhance-studio'; SourceExe='aeroenhance-studio.exe';TargetExe='AeroEnhance-Studio.exe' }
}
$AppInfo = $Definitions[$App]
$InstallDir = Join-Path $env:LOCALAPPDATA "AeroStudio\Apps\$App"
$Target = Join-Path $InstallDir $AppInfo.TargetExe
$LogDir = Join-Path $env:LOCALAPPDATA 'AeroStudio\Logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
function Install-Exe([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing compiled executable: $path" }
    $item = Get-Item -LiteralPath $path
    if ($item.Length -lt 100000) { throw "Executable appears unusually small: $path" }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $temporary = Join-Path $InstallDir ($AppInfo.TargetExe + '.incoming')
    Copy-Item -LiteralPath $path -Destination $temporary -Force
    # Don't overwrite a running executable. Keep the previous app on any installation failure.
    Move-Item -LiteralPath $temporary -Destination $Target -Force
    Write-Host "Installed $App at $Target" -ForegroundColor Green
}
# AeroEnhance is distributed with sidecar ONNX CUDA DLLs and helper scripts.
# Installing only its .exe would break GPU inference. Keep the package together.
function Install-AeroEnhanceZip([string]$archivePath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $scratch = Join-Path $env:TEMP ('aerostudio-enhance-' + [guid]::NewGuid().ToString('N'))
    $candidate = Join-Path (Split-Path $InstallDir -Parent) ('.AeroEnhance-incoming-' + [guid]::NewGuid().ToString('N'))
    $backup = Join-Path (Split-Path $InstallDir -Parent) ('.AeroEnhance-backup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $scratch | Out-Null
    $oldMoved = $false
    try {
        # Refuse path traversal and unexpectedly huge archives before extraction.
        $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            $basePath = [IO.Path]::GetFullPath($scratch).TrimEnd('\') + '\'
            [long]$total = 0
            foreach ($entry in $archive.Entries) {
                $full = [IO.Path]::GetFullPath((Join-Path $scratch $entry.FullName.Replace('/','\')))
                if (-not $full.StartsWith($basePath,[StringComparison]::OrdinalIgnoreCase)) {
                    throw "Unsafe archive entry path: $($entry.FullName)"
                }
                $total += $entry.Length
                if ($total -gt 10GB) { throw 'The release ZIP expands to more than 10 GiB; refusing to install.' }
            }
            if ($archive.Entries.Count -gt 30000) { throw 'Too many files in archive.' }
        } finally { $archive.Dispose() }
        Expand-Archive -LiteralPath $archivePath -DestinationPath $scratch -Force
        $matches = @(Get-ChildItem -LiteralPath $scratch -File -Filter $AppInfo.TargetExe -Recurse)
        if ($matches.Count -ne 1) { throw 'AeroEnhance ZIP must contain exactly one AeroEnhance-Studio.exe. Select the compiled Windows distribution, NOT the Rust source ZIP.' }
        $source = $matches[0].DirectoryName
        $meta = Join-Path $source 'RUNTIME_DLL_SOURCE.txt'
        if (Test-Path -LiteralPath $meta) {
            $metaText = Get-Content -LiteralPath $meta -Raw
            if ($metaText -match '(?im)^Variant:\s*CUDA\s*$') {
                foreach ($dll in @('onnxruntime_providers_cuda.dll','onnxruntime_providers_shared.dll')) {
                    if (-not (Test-Path -LiteralPath (Join-Path $source $dll) -PathType Leaf)) {
                        throw "CUDA archive is missing $dll. Refusing an incomplete installation."
                    }
                }
            }
        }
        New-Item -ItemType Directory -Force -Path $candidate | Out-Null
        foreach ($entry in @(Get-ChildItem -LiteralPath $source -Force)) {
            Copy-Item -LiteralPath $entry.FullName -Destination $candidate -Recurse -Force
        }
        # Model weights are user's downloaded data. Preserve them across app updates.
        $oldModels = Join-Path $InstallDir 'models'
        if (Test-Path -LiteralPath $oldModels -PathType Container) {
            $newModels = Join-Path $candidate 'models'
            New-Item -ItemType Directory -Force -Path $newModels | Out-Null
            foreach ($modelEntry in @(Get-ChildItem -LiteralPath $oldModels -Force)) {
                $newPath = Join-Path $newModels $modelEntry.Name
                if (-not (Test-Path -LiteralPath $newPath)) {
                    Copy-Item -LiteralPath $modelEntry.FullName -Destination $newPath -Recurse -Force
                }
            }
        }
        if (Test-Path -LiteralPath $InstallDir) {
            Move-Item -LiteralPath $InstallDir -Destination $backup
            $oldMoved = $true
        }
        try {
            Move-Item -LiteralPath $candidate -Destination $InstallDir
            if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) { throw 'Installed executable is missing after copy.' }
        } catch {
            if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
            if ($oldMoved) { Move-Item -LiteralPath $backup -Destination $InstallDir }
            $oldMoved = $false
            throw
        }
        if ($oldMoved) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Host "Installed AeroEnhance with its runtime DLLs/scripts to $InstallDir" -ForegroundColor Green
    } finally {
        if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
try {
    if ($Method -eq 'Build') {
        if ($App -eq 'AeroEnhance') {
            throw 'AeroEnhance is built from the repository with BUILD_AEROENHANCE_CUDA.bat. Use its packaged ZIP in the launcher.'
        }
        if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { throw 'Rust/Cargo is not on PATH. Install rustup and reopen the terminal.' }
        $Project = Join-Path $Root "Apps\$($AppInfo.Folder)"
        if (-not (Test-Path (Join-Path $Project 'Cargo.toml'))) { throw "Source checkout missing: $Project" }
        & (Join-Path $PSScriptRoot 'Restore-SourceFonts.ps1') -App $App
        if (-not $?) { throw 'Font asset restoration failed.' }
        Push-Location $Project
        try {
            if ($BuildTargetDir) { $env:CARGO_TARGET_DIR = Join-Path $BuildTargetDir $App }
            elseif ($env:AEROSTUDIO_BUILD_DIR) { $env:CARGO_TARGET_DIR = Join-Path $env:AEROSTUDIO_BUILD_DIR $App }
            Write-Host "Compiling $App from the existing Rust workspace..." -ForegroundColor Cyan
            & cargo build -p $AppInfo.Package --release
            if ($LASTEXITCODE -ne 0) { throw "Cargo build failed (exit $LASTEXITCODE). Review the Rust diagnostics above." }
            $targetRoot = if ($env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR } else { Join-Path $Project 'target' }
            Install-Exe (Join-Path $targetRoot "release\$($AppInfo.SourceExe)")
        } finally { Pop-Location }
    } elseif ($Method -eq 'LocalExe') {
        if ($App -eq 'AeroEnhance') { throw 'AeroEnhance requires its whole release ZIP (CUDA provider DLLs and setup scripts). Use Install ZIP instead.' }
        if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath -PathType Leaf)) { throw 'Select a Windows .exe built from your AeroStudio source.' }
        if ([IO.Path]::GetExtension($ExePath).ToLowerInvariant() -ne '.exe') { throw 'The selected file is not a Windows executable.' }
        Install-Exe $ExePath
    } elseif ($Method -eq 'LocalZip') {
        if (-not $ZipPath -or -not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw 'Select a release ZIP containing the app executable.' }
        if ($App -eq 'AeroEnhance') {
            Install-AeroEnhanceZip $ZipPath
        } else {
        $scratch = Join-Path $env:TEMP ("aerostudio-install-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $scratch | Out-Null
        try {
            Expand-Archive -LiteralPath $ZipPath -DestinationPath $scratch
            $matches = @(Get-ChildItem -Path $scratch -Filter $AppInfo.TargetExe -File -Recurse)
            if ($matches.Count -ne 1) { throw "The ZIP must contain exactly one $($AppInfo.TargetExe) binary." }
            Install-Exe $matches[0].FullName
        } finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } else {
        $Manifest = Join-Path $Root 'Launcher\releases.json'
        if (-not (Test-Path -LiteralPath $Manifest)) { throw 'No release manifest was found.' }
        $record = (Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json).$App
        if (-not $record.url -or -not $record.sha256) { throw "No official AeroStudio release URL/checksum has been configured for $App. Use Build or Install ZIP until a trusted release is published." }
        if ($record.url -notmatch '^https://') { throw 'The release URL must use HTTPS.' }
        $scratch = Join-Path $env:TEMP ("aerostudio-release-" + [guid]::NewGuid().ToString('N') + '.zip')
        try {
            Write-Host "Downloading $App official release..." -ForegroundColor Cyan
            Invoke-WebRequest -Uri $record.url -OutFile $scratch -UseBasicParsing
            $actual = (Get-FileHash -LiteralPath $scratch -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -ne ([string]$record.sha256).ToLowerInvariant()) { throw 'SHA-256 verification failed. The downloaded file was NOT installed.' }
            & $PSCommandPath -App $App -Method LocalZip -ZipPath $scratch
            if (-not $?) { throw 'ZIP installer failed.' }
        } finally { Remove-Item -LiteralPath $scratch -Force -ErrorAction SilentlyContinue }
    }
    Write-Host 'Installation complete.'
} catch {
    Write-Host "AeroStudio: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
} finally {
    if ($PauseOnExit) { Write-Host 'Press Enter to close this installer.'; [void][Console]::ReadLine() }
}
