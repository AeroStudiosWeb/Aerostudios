# AeroEnhance: download the publicly hosted SCUNet color real PSNR ONNX model.
# Original source: https://huggingface.co/Heliosoph/scunet-onnx
# Model is NOT made by AeroStudios. Read upstream license and model card.
$ErrorActionPreference = "Stop"
$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$modelDir = Join-Path $baseDir "models"
New-Item -ItemType Directory -Path $modelDir -Force | Out-Null
$baseUrl = "https://huggingface.co/Heliosoph/scunet-onnx/resolve/main"
$files = @(
  @{ Name="scunet_color_real_psnr.onnx"; Sha256="231be201ab413dbc999d7951caa9844846b93a12a40a41e037d6b5888ed4e88c" },
  @{ Name="scunet_color_real_psnr.onnx.data"; Sha256="98825ea1210b641c71e5f052f582c70c49fd44b35387ebe2c034268c17df3feb" }
)
foreach ($f in $files) {
    $dest = Join-Path $modelDir $f.Name
    $valid = (Test-Path $dest) -and ((Get-FileHash -Algorithm SHA256 $dest).Hash.ToLowerInvariant() -eq $f.Sha256)
    if ($valid) { Write-Host "Already verified: $($f.Name)"; continue }
    $temp = "$dest.partial"
    if (Test-Path $temp) { Remove-Item $temp -Force }
    Write-Host "Downloading $($f.Name) ..."
    try {
        Invoke-WebRequest -Uri "$baseUrl/$($f.Name)" -OutFile $temp -MaximumRedirection 10
        $actual = (Get-FileHash -Algorithm SHA256 $temp).Hash.ToLowerInvariant()
        if ($actual -ne $f.Sha256) {
            throw "SHA-256 mismatch for $($f.Name): $actual. File has NOT been installed."
        }
        Move-Item $temp $dest -Force
        Write-Host "Verified: $($f.Name)" -ForegroundColor Green
    } finally {
        if (Test-Path $temp) { Remove-Item $temp -Force }
    }
}
Write-Host ""
Write-Host "Denoising model ready:" -ForegroundColor Green
Write-Host (Join-Path $modelDir "scunet_color_real_psnr.onnx")
Write-Host "In AeroEnhance: restart the application or click Detect installed to automatically select the model; then enable neural inference when ready."
Write-Host "Both .onnx and .onnx.data files must remain together."
