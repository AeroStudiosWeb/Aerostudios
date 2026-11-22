# AeroStudio unified launcher — AeroEnhance integration

This update adds AeroEnhance Studio as **the fourth card** in the existing Windows PowerShell launcher, using the **same GitHub Release** and website download button as the three existing applications.

The updated launcher shows AeroRoom, AeroFilm, AeroPhoto and AeroEnhance. For AeroEnhance it can:

- Launch the installed application at `%LOCALAPPDATA%\AeroStudio\Apps\AeroEnhance\AeroEnhance-Studio.exe`.
- Install its **complete packaged ZIP** from your computer, keeping its ONNX CUDA provider DLLs, GPU diagnostics, model downloader and licences.
- Download a release ZIP from the shared GitHub Release after verifying its SHA-256 against the manifest embedded in the launcher.
- Preserve your existing `models` directory during app ZIP updates.

The "Use EXE" button is intentionally disabled for AeroEnhance. This app needs the *whole distribution folder*, not just its executable. The other three apps are unchanged.

## Update the already-published shared release (recommended)

1. Back up your local Git repository. Copy the supplied updated `launcher-template` and `tools` files into your actual AeroStudios repository (merge; don't remove the other folders).
2. Confirm that the **compiled** AeroEnhance CUDA ZIP is in `dist/`. Its name resembles `AeroEnhance-v0.7.0-beta.1-Windows-x64-CUDA.zip`. **Do not** select a source ZIP.
3. In PowerShell at the repository root, run:

```powershell
$zip = Get-ChildItem .\dist\AeroEnhance-v*-Windows-x64-CUDA.zip | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $zip) { throw 'No compiled AeroEnhance CUDA ZIP was found in dist.' }
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Updated-Unified-Launcher.ps1 -AeroEnhanceZip $zip.FullName
```

The script uses SHA-256 digests from the existing GitHub release where available; otherwise it downloads the actual published ZIPs to hash them. If GitHub is unavailable, it can fall back to matching local `release-out/` ZIPs, but you must ensure they are byte-for-byte identical to the published assets. It only produces **an updated unified launcher**, without rebuilding/repackaging the other three applications. If the original app ZIPs have been replaced on GitHub, don't use outdated local copies.

4. In your **existing** GitHub release `v0.1.0-beta.1`, make sure the exact compiled AeroEnhance ZIP selected above is attached. If it's not, upload it alongside the other three apps. Do not rename the ZIP after preparing the launcher: the embedded URL and SHA-256 must match that asset.
5. On that same release, delete the previous `AeroStudio-Launcher-Windows.zip` and `SHA256SUMS.txt` assets, and upload the new `release-out/AeroStudio-Launcher-Windows.zip` and `release-out/SHA256SUMS.txt` files. GitHub doesn't replace assets with the same filename until the old asset has been removed.
6. In GitHub Desktop, commit and push the changed launcher **source**, installer and release-building scripts. Do not commit `dist/`, `release-out/`, `.aero-target/`, signing keys or models.
7. Open the existing website and download the unified launcher. Extract it, run `AeroStudio.cmd` and verify the **fourth card**. Select **Download / Install** under AeroEnhance, then **Launch**. Check that `onnxruntime_providers_cuda.dll`, `onnxruntime_providers_shared.dll` and the model downloader are present in the installed folder.

The website link to `AeroStudio-Launcher-Windows.zip` stays the same: no new webpage is necessary for the unified launcher.

## Creating a brand-new full release later

`tools/Make-Windows-Release.ps1` now accepts an optional `-AeroEnhanceZip` parameter to include the complete AeroEnhance distribution in a new shared release with the other apps. This remains different from the targeted "update just the launcher" script above. You would reupload all generated assets for a new shared release tag.

## Safety / deployment notes

- This integration has been source-reviewed and its ZIP contents checked, but **Windows PowerShell/GUI execution is not available in the build environment**. Test the launcher on Windows before describing it as a verified release.
- An app ZIP is not the same as the Rust source archive. The launcher should reject a source ZIP that lacks `AeroEnhance-Studio/AeroEnhance-Studio.exe`.
- A checksum pinned to a specific release protects against an accidentally changed download, but isn't the same as a publisher code-signing certificate.
- Installing the AeroEnhance ZIP preserves its provider DLLs, but CUDA/cuDNN library compatibility and the actual ONNX model still have to be set up on the user's PC.
- The existing AI learning/feedback backend does **not** get deployed by this launcher update.
