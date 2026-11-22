# AeroEnhance Studio — end-to-end private AI training (v0.6)

**All source code is provided in the one repository.** Training does not run in the customer app, and no custom model is pre-trained or published. A useful model requires licensed, aligned reference images and a proper NVIDIA GPU run plus human review. The distributed Rust app can load local trained ONNX files; the research tools remain private Python/PyTorch.

## Folder map

- `aero_train/dataset_cli.py`: import your own genuinely clean JPG/PNG/TIFF/16-bit TIFF reference photos, keep EXIF stripped and SHA-256 provenance; review optional opt-in feedback (never auto-ingest)
- `aero_train/paired.py`: optional truly aligned noisy + clean shots, matched by relative filenames and session. Imported as lossless copies with both rights confirmed and hash checks
- `aero_train/pipeline.py`: group-isolated training/validation/held-out test, mixed synthetic + supervised paired training, 16-bit crop reading, resume checkpoints, PSNR/edge metrics and release gate
- `aero_train/compare.py`: same held-out images through noisy baseline, your exported model and optional pretrained SCUNet, with metrics and private contact-sheet previews
- `Run-AeroTraining.ps1` / `RUN_COMPLETE_TRAINING.bat`: single command for dataset audit → train → held-out evaluation → fixed-shape ONNX export → ONNX Runtime parity check → comparison
- `Install-LocalModel.ps1`: SHA-256-checked, private per-user model install with explicit experimental override when quality gate fails. **Never signs/publishes anything**.
- `tests/`: CPU unit/smoke tests for permission enforcement, provenance, 16-bit fidelity, group isolation, model contracts and aligned-pair transforms

## Setup (once, on your Windows RTX 3080)

Install Python 3.12 x64 from <https://www.python.org/downloads/>. In PowerShell in the repository root:

```powershell
cd "C:\Users\newby\Documents\GitHub\Aerostudios\training"
.\install-training-windows.bat
```

This prepares a private `.venv`, installs the training dependencies, and attempts an official **CUDA 12.6 PyTorch** wheel automatically for the RTX 3080. If that wheel is unavailable or cannot see your driver, consult <https://pytorch.org/get-started/locally/> (Windows/Pip/CUDA). Set `AERO_TORCH_INDEX_URL` to the currently supported wheel index and rerun the BAT. The CUDA runtime used for PyTorch training is **separate** from the DLLs packaged with the Rust inference app.

```powershell
.\.venv\Scripts\python.exe -c "import torch; print(torch.cuda.is_available(), torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'NO CUDA')"
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```

## Make your private clean-reference dataset

From the `training` folder, import clean reference shots session by session. Pick genuinely clean originals, not photos that AeroEnhance/SCUNet has already processed. For the best 16-bit reference quality, export clean 16-bit RGB TIFFs from your RAW developer rather than feeding camera RAWs directly to the Python dataset importer.

```powershell
$python = '.\.venv\Scripts\python.exe'
& $python -m aero_train.dataset_cli import-clean --input 'E:\AeroPrivate\clean\sessionA' --dataset 'E:\AeroPrivate\clean-dataset' --group 'sessionA' --rights-confirmed
& $python -m aero_train.dataset_cli import-clean --input 'E:\AeroPrivate\clean\sessionB' --dataset 'E:\AeroPrivate\clean-dataset' --group 'sessionB' --rights-confirmed
& $python -m aero_train.dataset_cli import-clean --input 'E:\AeroPrivate\clean\sessionC' --dataset 'E:\AeroPrivate\clean-dataset' --group 'sessionC' --rights-confirmed
& $python -m aero_train.dataset_cli audit --dataset 'E:\AeroPrivate\clean-dataset'
```

**Faster option — batch import a whole library:** make one folder per clean photo session under `E:\AeroPrivate\clean-sessions\`, such as `session01`, `session02`, `session03` (at least three). Then use ONE command instead of invoking `import-clean` for each session:

```powershell
& $python -m aero_train.dataset_cli import-library --input 'E:\AeroPrivate\clean-sessions' --dataset 'E:\AeroPrivate\clean-dataset' --rights-confirmed
```

Folder names are your anonymised group IDs; choose labels that genuinely identify distinct sessions and avoid personal information. Repeated importing skips duplicates by content hash.

Use far more than three independent sessions and at least 20 TRAIN images and ten held-out TEST images for any meaningful gate. Keep burst shots and the same scene in the same group. Because the split is derived from group IDs, **never change/repurpose a group label between rounds**. A random small dataset cannot produce professional denoising.

### Optional — real paired training

If you have a **clean and noisy rendering of the same stationary scene**, accurately aligned pixel-for-pixel, put them in two folders with identical **relative filenames** (extensions can differ), then import as a session:

```powershell
& $python -m aero_train.paired import-pairs --clean 'E:\AeroPrivate\pairs\sessionA\clean' --noisy 'E:\AeroPrivate\pairs\sessionA\noisy' --dataset 'E:\AeroPrivate\pairs-dataset' --group 'sessionA' --rights-confirmed
```

**Batch import pairs:** organise `E:\AeroPrivate\paired-sessions\session01\clean\` and `E:\AeroPrivate\paired-sessions\session01\noisy\` (repeat for `session02`, `session03`, etc.). Then run:

```powershell
& $python -m aero_train.paired import-pair-library --input 'E:\AeroPrivate\paired-sessions' --dataset 'E:\AeroPrivate\pairs-dataset' --rights-confirmed
```

Repeat with independent sessions. This command checks size, bit-depth, matched names and permissions, **but cannot prove optical alignment or clean image quality**. Manually inspect your pairs: misaligned aircraft panel lines would teach the model to blur or hallucinate details. Use several paired sessions so the joint train/validation/test split includes independent paired test images. The minimum real-pair test gate is ten images. Group labels must match the corresponding clean-library session if the photos are related; the split is done jointly to prevent leakage.

## One command: train, test, export and compare

```powershell
cd 'C:\Users\newby\Documents\GitHub\Aerostudios\training'
.\Run-AeroTraining.ps1 -Dataset 'E:\AeroPrivate\clean-dataset' -Output 'E:\AeroPrivate\runs\flight01' -Epochs 20 -StepsPerEpoch 200 -Batch 4 -Device cuda
```

If you have paired training images and the installed pretrained SCUNet ONNX model:

```powershell
.\Run-AeroTraining.ps1 -Dataset 'E:\AeroPrivate\clean-dataset' -PairedDataset 'E:\AeroPrivate\pairs-dataset' -ScunetModel 'C:\Users\newby\AppData\Local\AeroStudio\Apps\AeroEnhance\models\scunet_color_real_psnr.onnx' -Output 'E:\AeroPrivate\runs\flight02' -Epochs 20 -Batch 4
```

The SCUNet comparison is optional (omit `-ScunetModel` if not installed). It requires a fixed 256×256 RGB ONNX model of the same contract; if an upstream file has a different contract, omit the baseline or provide a compatible version. If your GPU runs out of memory, use `-Batch 2`. `-SmokeTest -Epochs 1 -StepsPerEpoch 2` is for technical verification **only**, not a reliable performance estimate.

Outputs include `best.pt`, `last.pt`, `training-history.json`, `heldout-report.json`, `aero-denoise.onnx`, its `.validation.json` and `review/comparison.json` and contact sheets. These are intentionally excluded from Git with `.gitignore`.

The evaluation gate checks independent held-out PSNR gain, gradient-edge error and minimum test count, including real-pair results if supplied. **Passing it is not proof of real-world quality.** Manually inspect full-resolution high-ISO photos in AeroEnhance, especially lettering, panel lines, rivets, fine branches, sky texture and skin tones. The small 7-layer convolutional network remains experimental.

## Install the model privately (no GitHub upload)

```powershell
.\Install-LocalModel.ps1 -Run 'E:\AeroPrivate\runs\flight01' -Version '0.1.0-local'
```

If the gate did not pass, install **only for private experiments** using `-AllowExperimental` and do not distribute it. The installer verifies the export SHA-256 and the evaluation/checkpoint association; it never overwrites different model bytes under an existing version. It copies to `%APPDATA%\AeroStudios\AeroEnhance\models\aero-denoise\<version>\aero-denoise.onnx`.

Open the **newly rebuilt** AeroEnhance Rust app, go to **AI inference / ONNX → Refresh local models → Choose installed AI model**, select `AeroDenoiseNet ... (local, experimental)` and enable neural inference. Switching back to `SCUNet (pretrained)` does not delete models. Selecting a local model never publishes it or enables feedback automatically.

**The user's existing packaged AeroEnhance executable needs rebuilding after this source change.** The Python training tools themselves are not shipped with end-user installer ZIPs.

## Privacy and real limits

- No data collection, automatic user training or public deployment is activated by these scripts. Private images, photos, weights and passwords must stay **outside the GitHub repository** and are ignored by Git by pattern.
- Existing feedback is ineligible for training without the separate explicit rights grant. Contributions can be withdrawn/expire; the training readers re-check the current metadata and hash. Don't claim deletion can undo the influence of already trained weights.
- Never use enhanced output as a ground-truth clean reference. Real aligned pairs can be noisy/clean exposures; check motion and camera changes carefully.
- Never publish a model automatically. Only consider the separate Ed25519-signed update publisher after independent held-out and blind manual review, a source/licensing audit and a deliberate release decision. `candidate` in `pipeline.py` generates **unsigned** metadata; it does not upload or sign anything.
- The training comparison uses private 8-bit contact sheets for convenience. The Rust app still uses float32 ONNX and preserves 16-bit output TIFF when the input is high bit-depth. These are distinct pipelines.
