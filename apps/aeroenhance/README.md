# AeroEnhance Studio — v0.7 High-Precision RAW + AI (Rust / CUDA source)

Native Rust Windows desktop app for editing photographs. **This is uncompiled source, not a ready-to-run EXE.** The GPU edition introduces a dedicated long-lived ONNX inference worker, CUDA-first computation, explicit CPU fallback, per-image diagnostics, a 6 GiB CUDA arena limit, optional TF32, and feather-blended overlapping tiles. It does **not** include pretrained weights. It is not yet a full Topaz Photo AI replacement.

## Fast path (you already installed Rust)

1. Extract this entire ZIP into a new folder. Open that folder (the one containing `Cargo.toml`).
2. Run `download-scunet-model.bat` to fetch the SCUNet denoising model (plus its `.onnx.data` companion). This uses HTTPS to Hugging Face and checks SHA-256 hashes.
3. Run `diagnose-gpu.bat`. It displays your GPU, driver, and a few relevant DLL checks; it does not change anything.
4. Install **compatible NVIDIA CUDA and cuDNN runtime DLLs**, if missing. For the GPU binaries downloaded by `ort 2.0.0-rc.15`, check the upstream compatibility notes: **CUDA 13.2+ and cuDNN 9.23+**, with a suitable NVIDIA driver. Make them discoverable via Windows PATH (or the app's DLL loading path). A GPU driver by itself is not sufficient. Read the official NVIDIA/ORT install instructions and do not download DLLs from random sites.
5. Double-click **`build-ai-cuda.bat`**. It compiles `cargo build --release --features ai-cuda` and launches the app after successful build. The first CUDA build may download a large set of runtime binaries. Rust/Python files are not sent to a remote service.
6. Import a small JPEG/TIFF/PNG, click **Browse** under AI and select `models\scunet_color_real_psnr.onnx`, then tick **Enable neural model**.
7. Choose **NVIDIA CUDA (strict)** to test *without silently falling back*. If it fails, the status bar shows the error. Alternatively, choose **Auto (GPU -> CPU)** to permit fallback. Switch classic denoise to zero for a fair comparison.
8. Export to PNG. Launch later using `target\release\aeroenhance-studio.exe` (keep runtime DLLs available).

**Verify GPU use:** open Task Manager → Performance → GPU and select a CUDA/Compute engine view, or open a terminal running `nvidia-smi -l 1` during processing. The status shows whether CUDA *registered* and the elapsed time; it does not prove that every ONNX operator executed on the GPU. An ONNX graph can legally fall back to CPU for unsupported operators.

## Hardware (RTX 3080 10 GB)

- The `ort` prebuilt CUDA kernels support NVIDIA Ampere / RTX 30-series cards.
- The CUDA execution provider's arena is set to **6 GiB**; *total* CUDA/driver/cuDNN memory use can exceed that. The limit is not a hard total-VRAM guarantee.
- cuDNN convolution algorithm search uses the `Heuristic` option to avoid the high overhead and peak VRAM of exhaustive search.
- `TF32` (speed-oriented reduced precision) is user-selectable and **off by default** to prioritize numerical precision and fine aircraft details.
- Inference is queued on a dedicated worker thread. A session remains cached for the same model, model timestamp, backend choice and TF32 setting. Batch exports reuse it. This reduces model reloads and limits overlapping GPU allocation spikes.
- 256×256 model tiles with 32 px overlap and on-the-fly feather blending reduce hard tile boundaries without a float32 full-image accumulation buffer.

## Current limitations

- **No compile or GPU runtime test was possible in the build environment.** Run the build on your Windows PC; send any Cargo/runtime error text to diagnose.
- Model support remains strict: input must be RGB float32 NCHW 256×256, one RGB NCHW output at x1/x2/x4. Arbitrary ONNX weights may not work. The supplied downloader targets a third-party SCUNet export. Review the model license before any public redistribution.
- The CUDA 13.2+ dependency is substantially newer than many installed CUDA 12 environments. If you cannot install those components, compile the CPU edition with `build-ai-cpu.bat`. A future GPU backend version could target a different runtime or DirectML.
- Model registration does **not** establish that all kernels ran on CUDA. Some operators may still use CPU. The initial tensor prep, PNG export and classic filters run on CPU.
- Preview is limited to 1700 px and export processes the full image; high-resolution exports may take considerable time or memory.
- RAW+AI and native 16-bit inputs now process through normalized float32 ONNX tensors and export TIFF16. Camera/ICC tagging and EXIF export are not yet implemented; RAW rendering remains display-referred sRGB16, not sensor-linear processing.
- Local processing is the default. The opt-in feedback panel can send explicitly approved examples to the private Rust server; model training is performed offline in a separate operator-controlled `training/` project (not inside the app).
- New CUDA memory/performance features are intended to be tested and profiled against real aircraft photos before a production release.

## Building without CUDA

- **CPU AI:** `build-ai-cpu.bat` or `cargo run --release --features ai`
- **Classic (no neural inference):** `build-windows.bat` or `cargo run --release`
- **CUDA AI:** `build-ai-cuda.bat` or `cargo run --release --features ai-cuda`

**Warning:** All three commands write `target\release\aeroenhance-studio.exe`. Use the CUDA build last if you want the CUDA version of that executable. To start the CUDA build directly from a terminal: `cargo run --release --features ai-cuda`.

## Upstream references

- https://docs.rs/ort/2.0.0-rc.15/ort/ep/cuda/struct.CUDA.html
- https://github.com/pykeio/ort/blob/main/docs/content/perf/execution-providers.mdx
- https://onnxruntime.ai/docs/execution-providers/CUDA-ExecutionProvider.html
- https://huggingface.co/Heliosoph/scunet-onnx

## v0.5 training integration

The app now has a **separate unchecked training permission** after preview approval. It never sends photos automatically and never trains on the machine of an ordinary user. Run `training/README.md` on the operator GPU machine to produce an experimental, held-out-evaluated ONNX candidate. Existing v0.4 submissions do not grant training rights.


See ../../RAW_INTEGRATION_README.md for AeroRoom RAW engine integration.

## v0.7 specific build

From this directory run `test-high-precision-windows.bat` (CPU ONNX tests), then `build-high-precision-cuda.bat` for the CUDA app. Start with a CR2 export. The full checklist is at project root: `HIGH_PRECISION_RAW_AI.md`. The general instructions at the top of this file were written before v0.6: for RAW+AI exports use 16-bit TIFF, not PNG.
