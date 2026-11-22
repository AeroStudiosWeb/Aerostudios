# AeroEnhance v0.7 — General Photo Pretraining + Aviation Detail Review

This is **one integrated source upgrade**, not a set of patches. It adds a separate, larger general-photography training corpus while retaining your 25 aviation images **only for diagnostics**. It does **not** ship a trained model, fetch customer photos, upload any private images, replace SCUNet or silently publish new weights.

## What stays where

```
C:\Users\newby\Documents\GitHub\Aerostudios\training\
    Build-General-Dataset.ps1             # collect and approve the general corpus
    Run-AeroTraining.ps1                  # train/evaluate/export/compare
    Install-LocalModel.ps1                # local-only manual model installation
    aero_train\commons.py                # source API + licence/provenance ledger
    aero_train\aviation.py               # aviation-only diagnostic

E:\AeroPrivate\
    clean-sessions\                      # your original three session folders (unchanged)
    clean-dataset-v2\                    # your existing 25-photo dataset (unchanged)
    general-commons\                     # automatically downloaded general images
        creator-sessions\               # files grouped by credited creator
        source-ledger.jsonl              # unedited provenance data
        SOURCE_LICENSE_REVIEW.csv        # YOU review and approve/reject here
    general-dataset\                    # generated only AFTER rights review
    runs\general01\                     # trained weights and private review reports
```

Keep all photographs, checkpoints and output under `E:\AeroPrivate` **outside Git**. Don't delete your previous `dist`, `release-out`, `.venv`, SCUNet model or aviation dataset. Replacing the source repository ZIP does not include those large/local files.

## Step 1 — Install the training environment, if necessary

From `C:\Users\newby\Documents\GitHub\Aerostudios` in PowerShell:

```powershell
.\training\install-training-windows.bat
```

Then check that GPU training is available:

```powershell
.\training\.venv\Scripts\python.exe -c "import torch; print('CUDA:', torch.cuda.is_available()); print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'NOT AVAILABLE')"
```

The RTX 3080 is sufficient for a starting experiment with batch size 4, provided the matching CUDA PyTorch wheel is installed. GPU training happens on your PC, not in ChatGPT.

## Step 2 — Collect a general-photography corpus

Wikimedia Commons files have **individual licenses**, not a blanket licence. The downloader allows only explicitly allowlisted machine-readable CC0 metadata by default; it keeps a source/license/creator ledger and adds a delay between downloads. **v0.7.2 searches the dedicated CC-Zero category directly** (and then optional text searches), rather than relying entirely on general search keywords that previously yielded just a couple of files. It scans multiple filename ranges, caps accepted files from one creator at 30 by default, and still individually checks licence URLs, creator metadata, resolution and source hosts. It prioritises JPEGs during category scanning to favour photographs, but you must reject non-photographic or poor-quality candidates during human review. The Wikimedia API requires a genuine contact identifier in the User-Agent. The contact email is **sent to Wikimedia in the HTTP User-Agent**, but not written into the dataset files.

```powershell
cd "C:\Users\newby\Documents\GitHub\Aerostudios"
powershell -NoProfile -ExecutionPolicy Bypass -File .\training\Build-General-Dataset.ps1 `
    -Phase Download `
    -Workspace "E:\AeroPrivate" `
    -TargetImages 500 `
    -Contact "YOUR_REAL_CONTACT_EMAIL@example.com" `
    -LicenseMode CC0 `
    -Discovery Auto `
    -MaxPerCreator 30
```

**Replace the example email with your real contact address.** Use the same command after an interruption to resume the previous ledger; it won't re-download ledgered images. The `-Discovery CC0Category` option restricts collection to the specific CC0 category, while `-Discovery Search` returns to the previous keyword-only method. These are discovery strategies, NOT licence guarantees. Candidate collection may take some time and download counts are not guaranteed. The default cap prevents hundreds of pictures from one creator being mistaken for a diverse training set. The script makes live requests to Wikimedia Commons **only when you run this command**. It is rate-limited and resumable. If Commons has insufficient matching CC0 photographs, you can deliberately widen the filter to `-LicenseMode CC0-CCBY`; CC BY requires credit and additional operator review. Unsupported, missing, NC/ND or SA licences are rejected by the importer. Avoid assuming a computer-readable label is definitive legal clearance. Some pages have incorrect or incomplete rights metadata.

Sources: Wikimedia Commons' [reusing images](https://commons.wikimedia.org/wiki/Commons:Reusing_content_outside_Wikimedia), [machine-readable metadata limitations](https://commons.wikimedia.org/wiki/Commons:Machine-readable_data), and [Wikimedia API access](https://www.mediawiki.org/wiki/Wikimedia_APIs/Access_policy). Respect API limits, including 429 responses. The downloader will not bypass them.

## Step 3 — Review and approve the rights ledger (required)

Open:

`E:\AeroPrivate\general-commons\SOURCE_LICENSE_REVIEW.csv`

Each downloaded photo has source page, creator, licence and licence URL. For **each row**, inspect the source page and confirm the photograph's rights and suitability for training. In the `review_status` column, change `REVIEW_REQUIRED` to either `APPROVED` or `REJECTED`. Do not change the other cells. Save as **CSV** (not XLSX). CSV editing in an ordinary text editor is fine; keep UTF-8 CSV encoding.

**Why can't this be skipped?** Wikimedia warns that free-form licences and author metadata can be incomplete or incorrect. Metadata filtering reduces risk but does not grant permission or verify ownership. The importer fails if any row remains unreviewed, a SHA-256/source row is changed, or fewer than 30 approved photos / three independent creators remain.

After the approvals:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\training\Build-General-Dataset.ps1 `
    -Phase Import `
    -Workspace "E:\AeroPrivate" `
    -RightsReviewed
```

This imports only approved source photos into `E:\AeroPrivate\general-dataset`, retaining creator grouping and provenance. It excludes rejected photos and does not overwrite your 25 aviation photos. Running import again skips previously imported originals.

Once imported, inspect the dataset split:

```powershell
.\training\.venv\Scripts\python.exe -m aero_train.dataset_cli audit --dataset "E:\AeroPrivate\general-dataset"
```

Run that command from inside the `training` directory (or use `cd .\training` first). For a useful experiment, aim for **hundreds to thousands of diverse photos**, ideally many independent creators and at least 20 training / 10 held-out test images. Fifty photos can pass a minimum gate but will not produce a competitive commercial denoiser. Sharp, clean 16-bit references are better than recompressed thumbnails; Wikimedia is a convenience bootstrap, **not** a high-quality RAW sensor-noise ground-truth dataset.

## Step 4 — Train the general denoiser and evaluate aviation separately

From the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\training\Run-AeroTraining.ps1 `
    -Dataset "E:\AeroPrivate\general-dataset" `
    -AviationDataset "E:\AeroPrivate\clean-dataset-v2" `
    -Output "E:\AeroPrivate\runs\general01" `
    -Epochs 40 `
    -StepsPerEpoch 300 `
    -Batch 4 `
    -Device cuda
```

This trains on the larger **general** corpus only, validates and tests on independent general-photo creators, exports a fixed-shape 256×256 float32 ONNX model, runs CPU ONNX equivalence checks, writes comparison previews, then separately measures detail retention on your **25 aviation photos** (not training examples). Your aviation set can be smaller than the general training minimum. Its synthetic-noise diagnostic **is not a release gate** and cannot by itself establish real-camera noise performance.

Optionally add this parameter to the above command to compare the same images against the installed pretrained SCUNet, if you have that exact file:

```powershell
-ScunetModel "C:\Users\newby\AppData\Local\AeroStudio\Apps\AeroEnhance\models\scunet_color_real_psnr.onnx"
```

If an ONNX/SCUNet contract is incompatible with the comparison tool, omit the optional baseline; it does not prevent training. If CUDA runs out of memory, use `-Batch 2`.

### Interrupted run / resume

Once a successful `last.pt` checkpoint exists, increase the total epoch target and add `-Resume`, using the **same input dataset and Output folder**:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\training\Run-AeroTraining.ps1 `
    -Dataset "E:\AeroPrivate\general-dataset" `
    -AviationDataset "E:\AeroPrivate\clean-dataset-v2" `
    -Output "E:\AeroPrivate\runs\general01" `
    -Epochs 60 -StepsPerEpoch 300 -Batch 4 -Device cuda -Resume
```

Resume fails closed if training data or split assignment has changed; train in a new run folder in that case. The previous v0.6 smoke-test checkpoint is **not** compatible with this v0.7 fingerprint/schema change: start a new general run, don't reuse the old smoke checkpoint.

## Step 5 — Read the reports *before* installing anything

```
E:\AeroPrivate\runs\general01\
    best.pt
    last.pt
    training-history.json
    heldout-report.json
    aero-denoise.onnx
    aero-denoise.onnx.validation.json
    review\comparison.json
    review\*.png
    aviation-review\aviation-report.json
    aviation-review\aviation-*.png
```

The main `heldout-report.json` includes automated noise-removal / edge-error criteria on independently held-out general-photo sources. Review the **aviation** report and previews separately, particularly small lettering, panel lines, rivets and sky noise. A model can pass synthetic PSNR while damaging real-world aircraft detail. Do not treat CC0 download count, synthetic PSNR, or an exported ONNX as proof of SCUNet/Topaz parity.

## Step 6 — Install a model only for private testing

If you have run the new Rust AeroEnhance build that includes the local model selector:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\training\Install-LocalModel.ps1 `
    -Run "E:\AeroPrivate\runs\general01" `
    -Version "0.2.0-local"
```

If the quality gate did not pass, the installer will refuse without `-AllowExperimental`. That flag is for **private testing only** and does not mean the model is publication-ready. In AeroEnhance: **AI inference / ONNX → Refresh local models → Choose installed model → Enable neural model**. SCUNet remains selectable. Do not upload checkpoints, training images, licence CSVs, ONNX models or private evaluation sheets to GitHub by default.

## What is genuinely automated and what isn't?

| Part | Status |
|---|---|
| Finding candidate public photographs, checking allowlisted metadata, downloading | Implemented; live API/network access needed on your PC |
| Credit/licence ledger, SHA-256 checks, per-creator grouping | Implemented |
| Human rights/quality review | **Required, cannot be automated into legal certainty** |
| General training on NVIDIA GPU, restartable checkpoint | Implemented; requires actual GPU run |
| Synthetic evaluation, ONNX export, ONNX CPU equivalence | Implemented; requires dependencies and run on PC |
| Separate aviation-domain review, optional SCUNet comparison | Implemented; synthetic-noise diagnostic only |
| Real paired high-ISO RAW training and professional-grade validation | Still requires accurately matched real data and additional work |
| Publishing a model or retraining from customers' uploads | **Not enabled** |

### Verification performed while preparing v0.7

The included offline test suite was executed and passed, and the small CPU trainer was exercised. The full live Wikimedia download, Windows PowerShell scripts, NVIDIA CUDA training, full ONNX export and post-release installation cannot be validated in this environment. Those are the remaining real-world checks, not missing source-code patches.


## Troubleshooting: `No module named 'torch'` during general-photo download

The v0.7.1 downloader no longer imports PyTorch just to hash downloaded files.
For **Download**, the active `training\.venv` only needs Python and Pillow.
For **Import**, training and ONNX evaluation, run
`training\install-training-windows.bat` from the repository root to install
CUDA PyTorch and the full training requirements into the **same** virtual environment.
Check it using:

```powershell
.\training\.venv\Scripts\python.exe -c "import torch; print(torch.__version__); print('CUDA:', torch.cuda.is_available())"
```

If you replaced the repository folder and deleted `.venv`, the previously
working PyTorch installation will not have carried over; run the installer again.
Do not install packages into a different Python interpreter by accident.

## v0.7.2 — Fix for only 2 images downloaded

The original downloader searched general keywords such as "landscape photograph". Most results did not match its strict CC0 allowlist, even though Commons maintains a huge dedicated [CC-Zero](https://commons.wikimedia.org/wiki/Category:CC-Zero) file category. `-Discovery Auto` now scans that category across multiple filename ranges before ordinary keyword searches. It still fetches and verifies each file's own licence information: category membership alone does not constitute copyright clearance. The operation uses Wikimedia's documented `generator=categorymembers` with per-file `imageinfo`, honors rate limits, retains existing `source-ledger.jsonl` and operator approvals, and prints diagnostics.

From the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\training\Build-General-Dataset.ps1 `
    -Phase Download -Workspace "E:\AeroPrivate" -TargetImages 500 `
    -Contact "YOUR_REAL_EMAIL@example.com" -LicenseMode CC0 `
    -Discovery Auto -MaxPerCreator 30
```

If the download is interrupted, run that same command again. Do not remove `E:\AeroPrivate\general-commons`. Once downloaded, continue the existing manual photo/rights review and Import step. **A full dataset will still require reviewing suitable, genuinely clean photographs, and no amount of random JPEGs alone guarantees a professional denoiser.**

Offline tests exercise the category API parameters, pagination, creator limits, resuming, and strict licence rejection. The live Commons API and Windows PowerShell run must still be tested on the user's machine.

## v0.7.3 — Partial CC0 download with only 1–2 creators

Prior versions blocked resuming an unfinished source ledger because the
integrity check also demanded three independent creators. The download
phase now **verifies all existing image hashes and source paths** without
requiring three creators *yet*. The independent-creator minimum remains
mandatory before importing any approved photographs for training.

If you received `Only 2 independent creators; need at least 3`, **keep**
`E:\AeroPrivate\general-commons`, including the source ledger and review
CSV. Replace repository source files with this version, then rerun the
existing `Build-General-Dataset.ps1 -Phase Download ...` command. No reset,
manual editing of the ledger, or loosening licence checks is required.

A successful download command may still end below the target if Wikimedia
searches yield no additional eligible images. In that case inspect the
printed `diagnostics` (especially `metadata_filtered`, `not_jpeg`,
`media_failed`, and `creator_limit`). Those counts distinguish poor discovery
from image download failures; *two creators* alone does not tell us which.
