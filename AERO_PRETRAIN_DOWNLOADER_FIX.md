# General-photo downloader fix (v0.7.1)

- The Wikimedia candidate downloader used to import `aero_train.data` solely to call `sha256_file`.
- `aero_train.data` imports `torch`, so the downloader crashed when PyTorch was not installed in `training\.venv`.
- The shared SHA-256 function now lives in the pure-Python `aero_train.hashutil` module.
- Old code importing `sha256_file` from `aero_train.data` still works.
- Dataset importing and GPU training still require PyTorch; the Windows script now fails with a clearer installation message for that stage.
- The full project, website, Rust apps and release-builder code are otherwise unchanged.

## Download again

```powershell
cd C:\Users\newby\Documents\GitHub\Aerostudios
powershell -NoProfile -ExecutionPolicy Bypass -File .\training\Build-General-Dataset.ps1 `
    -Phase Download -Workspace 'E:\AeroPrivate' -TargetImages 500 `
    -Contact 'YOUR_REAL_EMAIL@example.com' -LicenseMode CC0
```

Existing `E:\AeroPrivate\general-commons` data is reused. You must still review source licences before training.

## Before import and GPU training

```powershell
.\training\install-training-windows.bat
.\training\.venv\Scripts\python.exe -c "import torch; print(torch.cuda.is_available())"
```

Do not delete the existing `.venv`, `dist` or `release-out` folders when replacing the repository source.
