//! AeroEnhance ONNX inference worker.
//! Entirely native Rust. A dedicated thread owns the ONNX environment/session,
//! avoiding concurrent GPU OOMs and expensive model reloads for every preview.
//! 16-bit RGB is normalized directly to float32 without an 8-bit intermediate.
//! Model contract: one float32 NCHW [1,3,256,256] RGB input in [0,1],
//! one float32 NCHW RGB output at 1x, 2x, or 4x scale.

use crate::process::{AiDevice, Rgb16Image};
use anyhow::{anyhow, bail, Context, Result};
use image::Rgb;
use ndarray::Array4;
use ort::{environment::Environment, session::Session, value::TensorRef};
use std::{
    path::{Path, PathBuf},
    sync::{mpsc, Arc, OnceLock},
    thread,
    time::{Instant, SystemTime},
};

#[cfg(feature = "ai-cuda")]
use ort::ep::ExecutionProvider;

const TILE: usize = 256;
const BORDER: usize = 32;
const STEP: usize = TILE - BORDER * 2;
// The CUDA arena is capped; CUDA and cuDNN allocations can exceed this cap.
#[cfg(feature = "ai-cuda")]
const CUDA_ARENA_BYTES: usize = 6 * 1024 * 1024 * 1024;
const MAX_OUTPUT_PIXELS: u64 = 125_000_000; // Float canvas + 16-bit output; memory safety for 32GB PCs

pub struct Inference {
    pub image: Rgb16Image,
    pub report: String,
}

struct Request {
    image: Arc<Rgb16Image>,
    model: PathBuf,
    device: AiDevice,
    fast_math: bool,
    reply: mpsc::Sender<Result<Inference, String>>,
}

// Only a message channel is global. ORT's Environment and Session belong to
// the inference worker thread, not a global static (per ort 2 rc.15 guidance).
static WORKER: OnceLock<mpsc::Sender<Request>> = OnceLock::new();

fn worker_channel() -> &'static mpsc::Sender<Request> {
    WORKER.get_or_init(|| {
        let (tx, rx) = mpsc::channel::<Request>();
        thread::Builder::new()
            .name("aeroenhance-onnx-worker".into())
            .spawn(move || {
                let mut engine = Engine::default();
                for req in rx {
                    let result = engine
                        .run(&req.image, &req.model, req.device, req.fast_math)
                        .map_err(|e| format!("{e:#}"));
                    let _ = req.reply.send(result);
                }
            })
            .expect("failed to start AeroEnhance inference thread");
        tx
    })
}

pub fn infer_tiled(
    source: Arc<Rgb16Image>,
    model: &Path,
    device: AiDevice,
    fast_math: bool,
) -> Result<Inference> {
    let (tx, rx) = mpsc::channel();
    worker_channel().send(Request {
        image: source,
        model: model.to_path_buf(),
        device,
        fast_math,
        reply: tx,
    }).context("AI worker stopped")?;
    rx.recv().context("AI worker disconnected")?.map_err(|e| anyhow!(e))
}

struct Cache {
    model: PathBuf,
    len: u64,
    modified: Option<SystemTime>,
    device: AiDevice,
    fast_math: bool,
    cuda: bool,
    warning: Option<String>,
    session: Session,
}

#[derive(Default)]
struct Engine {
    // Drop cached Session before its Environment on worker shutdown.
    cache: Option<Cache>,
    environment: Option<Environment>,
}

impl Engine {
    fn env(&mut self) -> Result<&Environment> {
        if self.environment.is_none() {
            self.environment = Some(
                ort::init()
                    .with_name("AeroEnhance Studio")
                    .with_telemetry(false)
                    .build()
                    .context("ONNX Runtime initialization failed")?,
            );
        }
        Ok(self.environment.as_ref().expect("initialized"))
    }

    fn make_session(&mut self, model: &Path, device: AiDevice, fast_math: bool) -> Result<(Session, bool, Option<String>)> {
        let env = self.env()?;
        let mut builder = Session::builder(env)?;
        let mut cuda = false;
        let mut warning = None;

        #[cfg(feature = "ai-cuda")]
        if device != AiDevice::Cpu {
            let provider = ort::ep::cuda::CUDA::default()
                .with_device_id(0)
                .with_memory_limit(CUDA_ARENA_BYTES)
                // Heuristic avoids large peak-VRAM exhaustive cuDNN searches.
                .with_conv_algorithm_search(ort::ep::cuda::ConvAlgorithmSearch::Heuristic)
                // TF32 is optional because maximum image detail is our priority.
                .with_tf32(fast_math);
            match provider.register(&mut builder) {
                Ok(()) => cuda = true,
                Err(error) if device == AiDevice::Auto => {
                    warning = Some(format!("CUDA registration failed ({error}); using CPU"));
                    builder = Session::builder(env)?;
                }
                Err(error) => bail!("CUDA provider could not start: {error}. Check CUDA 13.2+, cuDNN 9.23+, driver, and PATH. Select CPU or Auto to continue."),
            }
        }

        #[cfg(not(feature = "ai-cuda"))]
        {
            let _ = fast_math;
            if device == AiDevice::Cuda {
                bail!("This executable was not built with CUDA. Run build-ai-cuda.bat, or select CPU/Auto.");
            }
            if device == AiDevice::Auto {
                warning = Some("CPU build; compile with --features ai-cuda for GPU acceleration".into());
            }
        }

        match builder.commit_from_file(model) {
            Ok(session) => Ok((session, cuda, warning)),
            Err(error) if cuda && device == AiDevice::Auto => {
                let cpu = Session::builder(env)?.commit_from_file(model)
                    .with_context(|| format!("CUDA session failed ({error}); CPU session also failed"))?;
                Ok((cpu, false, Some(format!("CUDA session failed ({error}); using CPU"))))
            }
            Err(error) => Err(anyhow!("Unable to load ONNX model {}: {error}", model.display())),
        }
    }

    fn load(&mut self, model: &Path, device: AiDevice, fast_math: bool) -> Result<bool> {
        let meta = std::fs::metadata(model)
            .with_context(|| format!("ONNX model not found: {}", model.display()))?;
        let modified = meta.modified().ok();
        let unchanged = self.cache.as_ref().is_some_and(|c| {
            c.model == model && c.len == meta.len() && c.modified == modified
                && c.device == device && c.fast_math == fast_math
        });
        if unchanged { return Ok(true); }
        // Drop prior session before loading another model to free GPU memory.
        self.cache = None;
        let (session, cuda, warning) = self.make_session(model, device, fast_math)?;
        self.cache = Some(Cache {
            model: model.to_path_buf(), len: meta.len(), modified,
            device, fast_math, cuda, warning, session,
        });
        Ok(false)
    }

    fn run(&mut self, src: &Rgb16Image, model: &Path, device: AiDevice, fast_math: bool) -> Result<Inference> {
        let start = Instant::now();
        let reused = self.load(model, device, fast_math)?;
        let first = {
            let cache = self.cache.as_mut().expect("session is loaded");
            run_tiles(src, &mut cache.session)
        };
        let (image, tiles) = match first {
            Ok(ok) => ok,
            Err(error) if device == AiDevice::Auto && self.cache.as_ref().is_some_and(|c| c.cuda) => {
                // A CUDA failure during inference (including OOM) falls back once
                // to CPU; CPU only when the user explicitly selected Auto.
                self.cache = None;
                self.load(model, AiDevice::Cpu, fast_math)?;
                let cache = self.cache.as_mut().expect("CPU session loaded");
                let retry = run_tiles(src, &mut cache.session)
                    .with_context(|| format!("CUDA inference failed ({error}); CPU retry also failed"))?;
                cache.device = AiDevice::Auto; // cache the fallback for Auto requests
                cache.warning = Some(format!("CUDA inference failed ({error}); using CPU"));
                retry
            }
            Err(error) => return Err(error),
        };
        let cache = self.cache.as_ref().expect("session loaded");
        let device_info = if cache.cuda {
            "CUDA provider registered (some operations may still use CPU)"
        } else {
            "CPU inference"
        };
        let report = format!(
            "{device_info} | {tiles} tiles | 16-bit RGB → float32 ONNX → 16-bit RGB | {:.2}s | {}{}",
            start.elapsed().as_secs_f64(),
            if reused { "cached model" } else { "model loaded" },
            cache.warning.as_ref().map(|w| format!(" | {w}")).unwrap_or_default(),
        );
        Ok(Inference { image, report })
    }
}

/// A single [0,65535] value maps into the float32 model domain without an
/// intermediate u8 conversion. f32 has enough mantissa precision for all u16 values.
#[inline]
fn unit_from_u16(v: u16) -> f32 { f32::from(v) / 65535.0 }

#[inline]
fn u16_from_unit(v: f32) -> u16 {
    if !v.is_finite() { return 0; }
    (v.clamp(0.0, 1.0) * 65535.0).round() as u16
}

/// Feather the 32-pixel overlaps. Adjacent tiles' axis weights sum to 1.0
/// throughout the overlap; a two-dimensional tile uses their product.
#[inline]
fn axis_weight(global: usize, origin: usize, entire: usize, scale: usize) -> f32 {
    let g = global as f32 + 0.5;
    let overlap = (BORDER * scale) as f32;
    let left = if origin > 0 && global < (origin + BORDER) * scale {
        ((g - (origin * scale) as f32) / overlap).clamp(0.0, 1.0)
    } else { 1.0 };
    let right = if origin + STEP < entire && global >= (origin + STEP) * scale {
        (((origin + STEP + BORDER) * scale) as f32 - g) / overlap
    } else { 1.0 };
    left * right.clamp(0.0, 1.0)
}

struct FloatCanvas {
    w: usize,
    h: usize,
    sum: Vec<[f32; 3]>,
    weight: Vec<f32>,
}

impl FloatCanvas {
    fn new(w: usize, h: usize) -> Result<Self> {
        let n = w.checked_mul(h).context("Image pixel count overflow")?;
        if n as u64 > MAX_OUTPUT_PIXELS {
            bail!("High-precision image exceeds {} pixels. Reduce resolution or upscale factor to avoid exhausting RAM.", MAX_OUTPUT_PIXELS);
        }
        let mut sum = Vec::new();
        sum.try_reserve_exact(n).context("Not enough RAM for float32 AI accumulation")?;
        sum.resize(n, [0.0; 3]);
        let mut weight = Vec::new();
        weight.try_reserve_exact(n).context("Not enough RAM for float32 overlap weights")?;
        weight.resize(n, 0.0);
        Ok(Self { w, h, sum, weight })
    }

    #[inline]
    fn add(&mut self, x: usize, y: usize, rgb: [f32; 3], weight: f32) {
        let index = y * self.w + x;
        self.sum[index][0] += rgb[0] * weight;
        self.sum[index][1] += rgb[1] * weight;
        self.sum[index][2] += rgb[2] * weight;
        self.weight[index] += weight;
    }

    fn finish(self) -> Result<Rgb16Image> {
        if self.weight.iter().any(|&v| !v.is_finite() || v <= 0.0) {
            bail!("Model tile stitching left uncovered pixels");
        }
        let mut out = Rgb16Image::new(self.w as u32, self.h as u32);
        for (i, pixel) in out.pixels_mut().enumerate() {
            let inv = self.weight[i].recip();
            *pixel = Rgb([
                u16_from_unit(self.sum[i][0] * inv),
                u16_from_unit(self.sum[i][1] * inv),
                u16_from_unit(self.sum[i][2] * inv),
            ]);
        }
        Ok(out)
    }
}

fn run_tiles(source: &Rgb16Image, session: &mut Session) -> Result<(Rgb16Image, usize)> {
    let (w, h) = source.dimensions();
    if w == 0 || h == 0 { bail!("Empty image"); }
    let (wu, hu) = (w as usize, h as usize);
    let mut canvas: Option<FloatCanvas> = None;
    let mut scale = 1usize;
    let mut tile_count = 0;

    for y in (0..hu).step_by(STEP) {
        for x in (0..wu).step_by(STEP) {
            let start_x = x.saturating_sub(BORDER);
            let start_y = y.saturating_sub(BORDER);
            let mut tensor = Array4::<f32>::zeros((1, 3, TILE, TILE));
            for ty in 0..TILE {
                for tx in 0..TILE {
                    let xx = (start_x + tx).min(wu - 1) as u32;
                    let yy = (start_y + ty).min(hu - 1) as u32;
                    let p = source.get_pixel(xx, yy);
                    for c in 0..3 { tensor[[0, c, ty, tx]] = unit_from_u16(p[c]); }
                }
            }
            let outputs = session.run(ort::inputs![TensorRef::from_array_view(&tensor)?])
                .context("Model inference failed")?;
            if outputs.len() != 1 { bail!("Expected exactly one ONNX output"); }
            let (shape, data) = outputs[0].try_extract_tensor::<f32>()?;
            if shape.len() != 4 || shape[0] != 1 || shape[1] != 3 {
                bail!("Expected ONNX output shape [1,3,H,W]");
            }
            let (oh, ow) = (shape[2] as usize, shape[3] as usize);
            if oh != ow || ow % TILE != 0 { bail!("Incompatible output tile shape: {ow}x{oh}"); }
            let this_scale = ow / TILE;
            if !matches!(this_scale, 1 | 2 | 4) { bail!("Only 1x, 2x, 4x ONNX output is supported"); }
            if canvas.is_none() {
                scale = this_scale;
                let width = wu.checked_mul(scale).context("Output width overflow")?;
                let height = hu.checked_mul(scale).context("Output height overflow")?;
                if width > u32::MAX as usize || height > u32::MAX as usize {
                    bail!("Output image dimensions exceed u32 limits");
                }
                canvas = Some(FloatCanvas::new(width, height)?);
            } else if this_scale != scale { bail!("Model produced inconsistent scaling"); }

            let output = canvas.as_mut().expect("canvas allocated");
            let end_x = (x + STEP + BORDER).min(wu) * scale;
            let end_y = (y + STEP + BORDER).min(hu) * scale;
            for gy in y * scale..end_y {
                let local_y = gy - start_y * scale;
                if local_y >= oh { bail!("Tile Y outside model output"); }
                let wy = axis_weight(gy, y, hu, scale);
                for gx in x * scale..end_x {
                    let local_x = gx - start_x * scale;
                    if local_x >= ow { bail!("Tile X outside model output"); }
                    let wx = axis_weight(gx, x, wu, scale);
                    let offset = local_y * ow + local_x;
                    let rgb = [
                        data[offset],
                        data[oh * ow + offset],
                        data[oh * ow * 2 + offset],
                    ];
                    output.add(gx, gy, rgb, wx * wy);
                }
            }
            tile_count += 1;
        }
    }
    Ok((canvas.context("No AI output generated")?.finish()?, tile_count))
}

#[cfg(test)]
mod high_bit_depth_tests {
    use super::*;

    #[test]
    fn all_16_bit_codes_roundtrip_through_float() {
        for v in u16::MIN..=u16::MAX {
            assert_eq!(u16_from_unit(unit_from_u16(v)), v, "u16 code {v} lost");
        }
    }

    #[test]
    fn tile_weights_cover_boundaries_and_sum_to_one() {
        for length in [1, 37, 192, 193, 201, 381, 385, 1000] {
            for scale in [1, 2, 4] {
                let mut weights = vec![0f32; length * scale];
                for origin in (0..length).step_by(STEP) {
                    let end = (origin + STEP + BORDER).min(length) * scale;
                    for g in origin * scale..end {
                        weights[g] += axis_weight(g, origin, length, scale);
                    }
                }
                for (pos, weight) in weights.iter().enumerate() {
                    assert!((*weight - 1.0).abs() < 0.0001,
                            "length={length} scale={scale} index={pos} weight={weight}");
                }
            }
        }
    }

    #[test]
    fn overlap_accumulator_reproduces_identity_at_tile_boundaries() {
        let (w, h) = (389usize, 205usize);
        let mut canvas = FloatCanvas::new(w, h).unwrap();
        for y in (0..h).step_by(STEP) {
            for x in (0..w).step_by(STEP) {
                let end_x = (x + STEP + BORDER).min(w);
                let end_y = (y + STEP + BORDER).min(h);
                for gy in y..end_y {
                    for gx in x..end_x {
                        let sample = [
                            unit_from_u16((gx as u16) * 97),
                            unit_from_u16((gy as u16) * 173),
                            unit_from_u16(12345),
                        ];
                        canvas.add(gx, gy, sample,
                            axis_weight(gx, x, w, 1) * axis_weight(gy, y, h, 1));
                    }
                }
            }
        }
        let output = canvas.finish().unwrap();
        for y in 0..h {
            for x in 0..w {
                assert_eq!(output.get_pixel(x as u32, y as u32).0,
                    [(x as u16) * 97, (y as u16) * 173, 12345]);
            }
        }
    }

    #[test]
    fn float_canvas_blends_without_8bit_quantisation() {
        let mut canvas = FloatCanvas::new(1, 1).unwrap();
        canvas.add(0, 0, [unit_from_u16(12001), unit_from_u16(25002), unit_from_u16(37003)], 0.3);
        canvas.add(0, 0, [unit_from_u16(12001), unit_from_u16(25002), unit_from_u16(37003)], 0.7);
        assert_eq!(canvas.finish().unwrap().get_pixel(0, 0).0, [12001, 25002, 37003]);
    }
}
