# AeroEnhance Learning Network — real training (v0.5 private alpha)

This folder is the **offline GPU training component** of AeroEnhance Studio. The desktop application and feedback backend are **Rust**. **Python/PyTorch are required only on the training computer**. Nothing here ships to end users. Model training does **not** happen whenever somebody processes a photo; it happens when the operator curates licensed data and launches training. New models are distributed by the existing Ed25519-signed ONNX updater only after evaluation and explicit release approval.

## What actually works in source

- Rust desktop v0.5 adds a *separate unchecked* permission for training-use review of its before/after preview contribution. A quality rating alone gives no image-training permission.
- Rust feedback server accepts v0.4 feedback under legacy consent **without** training rights and stores the v0.5 explicit training permission field when granted. Same 30-day retention and deletion receipt.
- `aero_train.dataset_cli` imports **licensed, genuinely clean** RGB images into private storage (EXIF stripped), or generates a deny-by-default manual review CSV of explicitly opted-in feedback.
- The curation CLI links approved clean `before.png` feedback images by path **without copying** them out of the 30-day feedback store. Any deletion, expiration, license denial or hash mismatch stops their reuse. Never use `after.png` as a clean label.
- `aero_train.pipeline train` trains a residual convolutional denoiser against simulated Poisson/Gaussian sensor noise on CUDA using mixed precision (RTX 3080-compatible), logs validation results and saves checkpoints. Initial model `AeroDenoiseNet` (7 Conv layers, 48 channels) is intentionally *small and experimental*, NOT a retrained SCUNet nor Topaz-quality.
- Hold-out is grouped by photographer/session across **train**, **validation**, and **untouched test**. Validation is used to choose the best epoch; test is used separately for the release gate.
- `evaluate` computes baseline-vs-denoised PSNR and edge-error measures on synthetic noise. A model must improve PSNR without excess edge degradation; **human side-by-side reviews** of real-world photos remain mandatory.
- `export` writes a 256x256, 1x RGB, float32 ONNX model and checks its equivalence against PyTorch using ONNX Runtime CPU. This matches `apps/aeroenhance/src/ai.rs`.
- `candidate` prepares **unsigned** update metadata only if the evaluation gate passed and an operator confirms blind review. The existing **Rust** update signer handles signing; this tooling never uploads or publishes a model.

## 1. Prepare your Windows GPU training computer

Requirements: Windows 10/11, Python 3.12, NVIDIA RTX GPU (10 GB VRAM suitable for initial model), working CUDA-enabled PyTorch. An NVIDIA driver alone does not guarantee `torch.cuda.is_available()`.

From this `training` folder run `install-training-windows.bat`, then follow the displayed <https://pytorch.org/get-started/locally/> CUDA PyTorch installation instructions **inside** `training\.venv` (choose current supported Windows/Pip/Python/CUDA combination).

```powershell
.\.venv\Scripts\python.exe -c "import torch; print(torch.__version__, torch.cuda.is_available()); print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'NO CUDA')"
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```

Use the `.venv\Scripts\python.exe` prefix for all training commands below. If you activate the venv (`.\.venv\Scripts\Activate.ps1`), you can just type `python`.

## 2. Add genuinely clean, licensed reference photos

The input folder must contain images which are **already clean**, not files denoised by SCUNet/AeroEnhance or another model. For an initial test, use your own properly exposed photos at low ISO (best if they have verified clean references). You must have authority to grant training rights. Best results need real clean/noisy pairs or a carefully calibrated raw noise model; this starter only trains using *synthetically generated noise* on RGB, not Bayer-RAW sensor data.

```powershell
python -m aero_train.dataset_cli import-clean --input "C:\AeroPrivate\CleanSessionA" --dataset "C:\AeroPrivate\DenoiseDataset" --group "photographer01-sessionA" --rights-confirmed
python -m aero_train.dataset_cli import-clean --input "C:\AeroPrivate\CleanSessionB" --dataset "C:\AeroPrivate\DenoiseDataset" --group "photographer01-sessionB" --rights-confirmed
python -m aero_train.dataset_cli import-clean --input "C:\AeroPrivate\CleanSessionC" --dataset "C:\AeroPrivate\DenoiseDataset" --group "photographer02-sessionC" --rights-confirmed
python -m aero_train.dataset_cli audit --dataset "C:\AeroPrivate\DenoiseDataset"
```

**Production expectation:** far more than 3 groups and more than 20 clean train images, with separate photographers, cameras, locations and true held-out photos. The default train command refuses fewer than 20 train records. For *technical smoke testing only*, pass `--min-train-images 1`; that does NOT validate image quality or give publishing permission. The `group` value is a curator-assigned anonymised scene/photographer/session group; keep similar burst photos together.

### Optional: review real beta feedback (never blindly ingest it)

In the desktop beta, a user must (1) enable feedback, (2) approve the exact image previews, (3) tick the *separate* training permission. The original **before** preview is probably noisy and therefore often **not usable as a clean target**. Read the new explicit license copy and obtain proper consent before any internet deployment.

```powershell
python -m aero_train.dataset_cli review-feedback --feedback-dir "C:\Users\YOU\.aero-private\feedback" --output "C:\AeroPrivate\feedback-review.csv"
```

Open that CSV. Inspect each corresponding `before.png` and `metadata.json` locally. Set `clean_confirmed` and `license_checked` to `YES` **only** for references that really are clean and unproblematic; set `group` to group photos by photographer/session. Entries remain `NO` by default. Then:

```powershell
python -m aero_train.dataset_cli curate-feedback --feedback-dir "C:\Users\YOU\.aero-private\feedback" --reviewed-csv "C:\AeroPrivate\feedback-review.csv" --dataset "C:\AeroPrivate\DenoiseDataset" --curator-confirmation
```

Existing v0.4 contributions **cannot** be used for training: those users did not grant this separate permission. If contributions are deleted or expire while training, the next read raises an error rather than silently using stale copies. **No image data is exported to GitHub**. Deletion cannot retroactively remove the influence of weights already trained; explain this clearly to all testers.

## 3. Train on your RTX 3080

```powershell
python -m aero_train.pipeline train --dataset "C:\AeroPrivate\DenoiseDataset" --output "C:\AeroPrivate\runs\test01" --device cuda --epochs 20 --steps-per-epoch 200 --batch 4 --patch 128 --amp
```

This trains the model with synthetic noise, checkpoints `best.pt`/`last.pt`, and writes `training-history.json`. Use `--resume ...\last.pt` only with **your own** checkpoint and unchanged dataset. Change `--batch 4` to `--batch 2` if VRAM is tight. `run-training-windows.bat` combines training/eval/export (from the training folder).

## 4. Evaluate on completely held-out images

```powershell
python -m aero_train.pipeline evaluate --dataset "C:\AeroPrivate\DenoiseDataset" --checkpoint "C:\AeroPrivate\runs\test01\best.pt" --output "C:\AeroPrivate\runs\test01\heldout-report.json" --device cuda --patch 256
```

The default release gate requires **at least 10 independent test images**, +0.3 dB PSNR versus their original simulated noise and at most 1.05× baseline edge error. These thresholds are **initial engineering guardrails, not proof of good human-visible image quality**. Review high-ISO aircraft registrations, panel lines, dark backgrounds, flat areas and signs by eye as well. Test photos must not be reused for choosing hyperparameters or you need a new independent test group.

## 5. Export a candidate ONNX model

```powershell
python -m aero_train.pipeline export --checkpoint "C:\AeroPrivate\runs\test01\best.pt" --output "C:\AeroPrivate\runs\test01\aero-denoise.onnx"
```

The exporter uses opset 17 and verifies ONNX Runtime vs PyTorch output on a full 256-pixel tile (max absolute difference <= 2e-4). Unlike SCUNet, this is a **new independent architecture**: do not reuse SCUNet weights/checkpoints. The exported `.onnx` is compatible with the app's existing tiled `ai.rs` pipeline. Browse to it from AeroEnhance, choose CUDA (strict) and test on local photos.

## 6. Gate and sign an update only after real testing

```powershell
python -m aero_train.pipeline candidate --model "C:\AeroPrivate\runs\test01\aero-denoise.onnx" --evaluation "C:\AeroPrivate\runs\test01\heldout-report.json" --version "0.5.0-beta.2" --url "https://YOUR-TRUSTED-HOST/aero-denoise.onnx" --output "C:\AeroPrivate\runs\test01\unsigned-manifest.json" --confirm "I HAVE REVIEWED THE HELD-OUT IMAGES"
```

This **fails** if the automatic gate is red, the ONNX's verified hash differs, or the evaluated checkpoint is different from the exported one. The candidate is *unsigned*: use `tools/update-signer` from the v0.4 package, verify with your baked-in public key, publish the ONNX bytes at the exact URL, then host the signed manifest over HTTPS. Test with one private beta machine before wider rollout. There is **no auto-publishing or background training loop** in this version.

## Safety/quality/limitations

- No feedback, image data or training weights should be committed to the public repository, or placed in GitHub Actions logs/artifacts.
- Synthetic noise is not representative of every camera sensor, JPEG artefact or motion blur; a measured RAW sensor noise pipeline is future work.
- Real data may contain faces, private location clues, aircraft registrations and copyright material. Obtain express permission; avoid using sensitive samples; store with encryption and limited access before public beta.
- The 30-day feedback store must remain available to satisfy delete/expiry checks; existing model weights cannot be untrained on request. Manual dataset review and human-approved publication are necessary.
- Actual private deployment needs real accounts, HTTPS, secure storage, per-user permissions and operational data deletion. Do not expose the test server directly.
- This is a small-from-scratch model, **not a fully trained model**. Without your dataset and meaningful training it will barely change the input. No claims of Topaz-quality denoising should be made yet.

## Optional recurring private retraining (after local acceptance testing)

`private-cycle.ps1` checks the curated dataset audit, compares its manifest hash with the prior successful cycle, and trains/evaluates/exports a **new private candidate** only when the curated manifest changes. You can later schedule it in Windows Task Scheduler if desired, but do **not** start recurring jobs before manual testing, monitoring disk use and confirming consent handling.

```powershell
powershell -ExecutionPolicy Bypass -File .\private-cycle.ps1 -Dataset "C:\AeroPrivate\DenoiseDataset" -Runs "C:\AeroPrivate\runs" -Epochs 20
```

It does **not** automatically import fresh contributions, update a deployed model, sign a release, or upload private data. New feedback only joins the curated dataset through the explicit review/rights workflow above. That separation is intentional: users improve the future training corpus, but cannot directly change weights on everyone else's computers.

## v0.7: 16-bit TIFF training references

Clean RGB16 `.tif`/`.tiff` images imported with `dataset_cli import-clean` now remain `uint16` TIFFs and are normalized directly with `/65535.0` in the PyTorch dataset. Ordinary JPEG/PNG and consented feedback preview PNGs retain the previous 8-bit behavior. This avoids destroying fine tones in licensed clean training references. No arbitrary RAW mosaic or DNG is admitted to the trainer: develop it in AeroRoom/AeroEnhance and export a clean 16-bit TIFF first.

`install-training-windows.bat` must be rerun to install `tifffile`. `python -m unittest discover -s tests -v` includes a new RGB16 import + reader regression test. RGB16 TIFFs with non-normal EXIF orientation or unsupported channel layouts are rejected instead of silently quantized. Clean-image licensing/consent and holdout rules remain unchanged.
