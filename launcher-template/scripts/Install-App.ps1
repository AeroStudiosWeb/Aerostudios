param(
    [Parameter(Mandatory=$true)][ValidateSet('AeroRoom','AeroFilm','AeroPhoto')][string]$App,
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
try {
    if ($Method -eq 'Build') {
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
        if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath -PathType Leaf)) { throw 'Select a Windows .exe built from your AeroStudio source.' }
        if ([IO.Path]::GetExtension($ExePath).ToLowerInvariant() -ne '.exe') { throw 'The selected file is not a Windows executable.' }
        Install-Exe $ExePath
    } elseif ($Method -eq 'LocalZip') {
        if (-not $ZipPath -or -not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) { throw 'Select a release ZIP containing the app executable.' }
        $scratch = Join-Path $env:TEMP ("aerostudio-install-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $scratch | Out-Null
        try {
            Expand-Archive -LiteralPath $ZipPath -DestinationPath $scratch
            $matches = @(Get-ChildItem -Path $scratch -Filter $AppInfo.TargetExe -File -Recurse)
            if ($matches.Count -ne 1) { throw "The ZIP must contain exactly one $($AppInfo.TargetExe) binary." }
            Install-Exe $matches[0].FullName
        } finally { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue }
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
