# AeroEnhance — AeroRoom RAW colour-development correction (experimental)

## What was actually wrong

AeroEnhance **already used** `shared/aeroroom-raw-engine` (the low-level decoder and demosaicer taken from the user's AeroRoom / LightCraft fork). But `apps/aeroenhance/src/raw_bridge.rs` bypassed AeroRoom's **camera-specific starting-colour/preview fitting** stage. For some vendor RAW files, notably Canon EOS 7D `.CR2`, the decoder supplies neither a full DNG colour matrix nor a matching measured spectral profile, so the basic generic camera→sRGB transform produces a muted/flat rendering. This is separate from ONNX model quality.

## What this version changes

- For RAW files with real camera matrices (DNG etc.), leaves the original full-precision colour transform unchanged.
- For vendor RAW files without camera matrices, tries a conservative starting look based on the embedded camera JPEG, similar to the *purpose* of AeroRoom's camera-preview look fit. Only **colour/tone parameters** come from the JPEG; the output image still uses **full-resolution, demosaiced 16-bit RAW pixels**. No JPEG pixels are substituted into the AI input or export.
- Refuses unusable, monochrome-picture-style, wrong-aspect or non-sRGB-tagged reference previews rather than forcibly desaturating a RAW.
- If a measured camera matrix exists in the shared upstream spectral table but the JPEG look is unusable, uses the measured camera matrix as a fallback. Otherwise explicitly labels the remaining generic fallback in the import detail.
- Adds tests for colour-look fitting and precision. Does not modify model weights or training data.

**This is NOT a byte-for-byte port of AeroRoom's full photo-development pipeline.** The actual AeroRoom engine also has camera-profile look libraries, hue/saturation mapping, camera-JPEG fit acceptance gates, lens warp alignment, advanced tone curves, profile corrections, and a broader scene-linear GPU rendering stack. The change addresses the most obvious missing stage while retaining AeroEnhance's independent Rust + ONNX/16-bit workflow. Pixel-perfect parity is a separate larger integration task. The resulting look has not been verified against an actual Canon EOS 7D `.CR2` in this environment.

## Build / test (Windows)

Back up the current repository first. Merge the updated source **without deleting** `dist`, `release-out`, `training\.venv`, or your data on `E:`.

Open PowerShell in the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
    -File .\tools\release\build-and-package.ps1 `
    -Variant CUDA `
    -BuildRoot "E:\AeroBuild"
```

The script runs Rust core tests first, then builds and packages the CUDA app. **Do not replace your release assets until this build and manual RAW tests pass.** Open the same Canon `.CR2` in both AeroRoom and AeroEnhance. Test with AI **disabled first**, then enabled. Compare actual colour, contrast, neutral clouds, registration detail, 16-bit TIFF export and a regular JPEG input. If the import detail still says `generic fallback`, this camera's JPEG look was not acceptable — a sample `.CR2` will be needed to improve the fit safely.

Rebuild the unified launcher **after** testing and using the final AeroEnhance ZIP:

```powershell
$zip = Get-ChildItem .\dist\AeroEnhance-v*-Windows-x64-CUDA.zip |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
powershell -NoProfile -ExecutionPolicy Bypass `
    -File .\tools\Build-Updated-Unified-Launcher.ps1 `
    -AeroEnhanceZip $zip.FullName
```

If you update GitHub Releases, upload the exact `dist` AeroEnhance ZIP used for the launcher build; replace the launcher ZIP and checksum file together. Prior mismatched checksums were caused by uploading a different AeroEnhance ZIP.

## Unrelated issue

The screenshot also showed ONNX CPU fallback due to CUDA provider-registration failure. This colour correction does not change ONNX Runtime DLLs or NVIDIA CUDA setup. Diagnose the provider separately after RAW development is confirmed.
