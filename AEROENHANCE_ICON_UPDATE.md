# AeroEnhance Studio — Windows Icon Integration

The AeroEnhance AI + brush artwork is now integrated into the existing project:

- `apps/aeroenhance/assets/aeroenhance.ico`: multi-resolution Windows executable icon (16/24/32/48/64/128/256 px).
- `apps/aeroenhance/assets/aeroenhance-icon.png`: transparent 512 px runtime window/taskbar icon.
- `apps/aeroenhance/build.rs`: embeds the ICO into Windows PE resources with `winresource`.
- `apps/aeroenhance/src/main.rs`: supplies the matching icon to the eframe viewport.
- `launcher-template/Apps/AeroEnhance/assets/aerostudio/icon.png`: icon for the fourth app card in the unified launcher.
- Both launcher packaging scripts now copy the AeroEnhance card icon.

## Build and publish (Windows PowerShell, from repository root)

Build the CUDA application and create the versioned release ZIP using your existing E: cache:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\release\build-and-package.ps1 -Variant CUDA -BuildRoot 'E:\AeroBuild'
```

**Important**: A new executable means a new app ZIP checksum. Recreate the unified launcher against the **new** compiled ZIP:

```powershell
$zip = Get-ChildItem .\dist\AeroEnhance-v*-Windows-x64-CUDA.zip -File |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $zip) { throw 'Compiled AeroEnhance CUDA ZIP missing from dist' }
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Updated-Unified-Launcher.ps1 -AeroEnhanceZip $zip.FullName
```

Upload the new AeroEnhance CUDA ZIP plus `release-out/AeroStudio-Launcher-Windows.zip` and `release-out/SHA256SUMS.txt` to the **same** GitHub release. Replace the corresponding old assets; leave AeroRoom, AeroFilm and AeroPhoto assets alone. Do not rename the built ZIP or re-compress it after building the launcher, or SHA-256 verification will fail.

Install the updated AeroEnhance ZIP through the updated launcher. The window/taskbar, Windows executable, and launcher card should now all use the AI + brush icon. If the desktop shortcut still shows a generic icon, recreate it or refresh Windows icon cache. Models stay separate.

## Status

Source, icon files, bundle wiring, and ZIP contents were checked. The Windows Rust build cannot be executed here: validate with your normal Windows/CUDA build before release.
