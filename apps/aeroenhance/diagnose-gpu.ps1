# AeroEnhance CUDA diagnostics. Read-only; doesn't install software or send data.
$ErrorActionPreference = 'Continue'
Write-Host "AeroEnhance Studio - CUDA diagnostics" -ForegroundColor Cyan
Write-Host "==================================="
Write-Host "GPU and NVIDIA driver:"
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    & nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
    Write-Host "Note: nvidia-smi 'CUDA Version' is DRIVER compatibility, not the installed CUDA Toolkit."
} else { Write-Warning "nvidia-smi not found. Check NVIDIA graphics driver installation." }
Write-Host "`nCUDA compiler (optional for runtime inference, useful for diagnostics):"
if (Get-Command nvcc -ErrorAction SilentlyContinue) { & nvcc --version | Select-Object -Last 5 }
else { Write-Warning "nvcc not found on PATH; this does not by itself prove CUDA runtime DLLs are missing." }
Write-Host "`nCUDA runtime/cuDNN DLL visibility on PATH:"
foreach ($pattern in @('cudart64_13.dll','cudnn64_9.dll','cublas64_13.dll','onnxruntime_providers_cuda.dll')) {
    $found = @()
    foreach ($dir in ($env:PATH -split ';' | Where-Object { $_ -and (Test-Path $_ -PathType Container) })) {
        $item = Join-Path $dir $pattern
        if (Test-Path $item) { $found += $item }
    }
    if ($found.Count -gt 0) { Write-Host "  FOUND $pattern : $($found[0])" -ForegroundColor Green }
    else { Write-Host "  Not on PATH: $pattern (may be next to app/loaded by provider)" -ForegroundColor Yellow }
}
Write-Host "`nReminder: ort rc.15 prebuilt CUDA packages target CUDA >=13.2, cuDNN >=9.23."
Write-Host "The reliable test is launching AeroEnhance in CUDA mode and checking its status and NVIDIA GPU activity."
Read-Host "Press Enter to exit"
