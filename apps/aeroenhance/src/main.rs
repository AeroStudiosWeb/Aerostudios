#![cfg_attr(all(not(debug_assertions), not(test)), windows_subsystem = "windows")]

mod process;
mod raw_bridge;
#[cfg(feature = "aeroroom-raw")]
mod raw_look;
mod network;
#[cfg(feature = "ai")]
mod ai;

use eframe::egui::{self, Color32, TextureHandle, TextureOptions, Vec2};
use image::{DynamicImage, RgbImage, ImageFormat};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use std::io::Cursor;
use process::{AiDevice, Processed, Settings};
use std::{path::{Path, PathBuf}, sync::{mpsc::{self, Receiver, Sender}, Arc}, thread, time::{Duration, Instant}};

struct ExampleReview {
    before_png_b64: String,
    after_png_b64: String,
    before_texture: TextureHandle,
    after_texture: TextureHandle,
}

struct Photo {
    path: PathBuf,
    original: Arc<DynamicImage>,
    raw: bool,
    detail: String,
    before_texture: TextureHandle,
    after_texture: Option<TextureHandle>,
}

enum WorkerResult {
    Preview { job: u64, index: usize, result: Result<Processed, String> },
    ExportFinished { count: usize, errors: Vec<String> },
    UpdateChecked(Result<network::ModelManifest, String>),
    ModelInstalled(Result<PathBuf, String>),
    ContributionSent(Result<network::Receipt, String>),
    ContributionDeleted(Result<(), String>),
}

struct Studio {
    photos: Vec<Photo>,
    selected: usize,
    settings: Settings,
    zoom: f32,
    status: String,
    preview_job: u64,
    preview_busy: bool,
    export_busy: bool,
    pending_preview: Option<Instant>,
    tx: Sender<WorkerResult>,
    rx: Receiver<WorkerResult>,
    prefs: network::Preferences,
    latest_manifest: Option<network::ModelManifest>,
    update_busy: bool,
    update_message: String,
    previous_model: Option<String>,
    beta_token: String, // stays in memory; never written to preferences
    feedback_rating: String,
    feedback_issue: String,
    feedback_note: String,
    review: Option<ExampleReview>,
    approve_example: bool,
    training_permission: bool,
    feedback_busy: bool,
    feedback_message: String,
    last_receipt: Option<network::Receipt>,
    last_processed: Option<(usize, RgbImage)>,
    installed_models: Vec<(String, PathBuf)>,
}

fn to_texture(ctx: &egui::Context, name: String, img: &RgbImage) -> TextureHandle {
    let (w, h) = img.dimensions();
    let color = egui::ColorImage::from_rgb([w as usize, h as usize], img.as_raw());
    ctx.load_texture(name, color, TextureOptions::LINEAR)
}

// The official SCUNet downloader puts the .onnx and its external data file
// together in a `models` folder beside the distributed executable. Cargo
// development runs put the same folder beside the working directory instead.
// Do not pick arbitrary ONNX files: other models may have incompatible shapes.
fn find_default_model() -> Option<PathBuf> {
    let mut roots = Vec::<PathBuf>::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            roots.push(dir.join("models"));
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        let local = cwd.join("models");
        if !roots.contains(&local) {
            roots.push(local);
        }
    }
    roots.into_iter().find_map(|dir| {
        let model = dir.join("scunet_color_real_psnr.onnx");
        let data = dir.join("scunet_color_real_psnr.onnx.data");
        if model.is_file() && data.is_file() { Some(model) } else { None }
    })
}

// Discover SCUNet and locally exported AeroDenoiseNet models. Trained-model
// entries are only offered by the picker when their export sidecar and SHA-256
// match; unsigned models are NOT treated as signed automatic updates.
fn installed_ai_models() -> Vec<(String, PathBuf)> {
    use sha2::{Digest, Sha256};
    use std::io::Read;
    let mut found = Vec::<(String, PathBuf)>::new();
    if let Some(scunet) = find_default_model() {
        found.push(("SCUNet (pretrained)".to_owned(), scunet));
    }
    if let Ok(base) = network::model_dir() {
        if let Ok(versions) = std::fs::read_dir(base.join("aero-denoise")) {
            for entry in versions.flatten() {
                if !entry.file_type().is_ok_and(|kind| kind.is_dir() && !kind.is_symlink()) { continue; }
                let version = entry.file_name().to_string_lossy().into_owned();
                if version.is_empty() || version.len() > 80 ||
                    !version.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-')) {
                    continue;
                }
                let model = entry.path().join("aero-denoise.onnx");
                let proof = entry.path().join("aero-denoise.onnx.validation.json");
                if !model.is_file() || !proof.is_file() { continue; }
                let expected = std::fs::read(&proof).ok()
                    .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
                    .and_then(|value| value.get("sha256").and_then(|s| s.as_str()).map(str::to_owned));
                let Some(expected) = expected else { continue; };
                if expected.len() != 64 || !expected.bytes().all(|b| b.is_ascii_hexdigit()) { continue; }
                let Ok(mut f) = std::fs::File::open(&model) else { continue; };
                let mut hasher = Sha256::new();
                let mut buffer = [0u8; 128 * 1024];
                let mut good = true;
                loop {
                    match f.read(&mut buffer) {
                        Ok(0) => break,
                        Ok(n) => hasher.update(&buffer[..n]),
                        Err(_) => { good = false; break; }
                    }
                }
                if good && hex::encode(hasher.finalize()).eq_ignore_ascii_case(&expected) {
                    found.push((format!("AeroDenoiseNet {version} (local, experimental)"), model));
                }
            }
        }
    }
    found.sort_by(|a,b| a.0.cmp(&b.0));
    found
}

impl Studio {
    fn new(ctx: &egui::Context) -> Self {
        ctx.set_visuals(egui::Visuals::dark());
        let (tx, rx) = mpsc::channel();
        let mut prefs = network::load_preferences();
        // Prefer an explicitly selected or previously verified update model.
        // A moved portable install may invalidate the saved absolute path, so
        // fall back to the packaged models folder without enabling AI silently.
        let saved = PathBuf::from(&prefs.active_model_path);
        let selected_model = if !prefs.active_model_path.trim().is_empty() && saved.is_file() {
            Some(saved)
        } else {
            find_default_model()
        };
        let startup_check = prefs.check_updates_at_launch;
        let startup_url = prefs.manifest_url.clone();
        if startup_check {
            let sender = tx.clone();
            let repaint = ctx.clone();
            thread::spawn(move || {
                let result = network::check_updates(&startup_url).map_err(|e| format!("{e:#}"));
                let _ = sender.send(WorkerResult::UpdateChecked(result));
                repaint.request_repaint();
            });
        }
        let mut settings = Settings::default();
        if let Some(model) = selected_model {
            settings.ai_model_path = model.to_string_lossy().into_owned();
            if settings.ai_model_path != prefs.active_model_path {
                prefs.active_model_path = settings.ai_model_path.clone();
                let _ = network::save_preferences(&prefs);
            }
        }
        Self {
            photos: Vec::new(), selected: 0, settings,
            zoom: 1.0, status: "Ready. Open images to get started.".to_owned(),
            preview_job: 0, preview_busy: false, export_busy: false,
            pending_preview: None, tx, rx,
            prefs, latest_manifest: None, update_busy: startup_check,
            update_message: "No update checks yet".into(), previous_model: None,
            beta_token: String::new(), feedback_rating: "Good".into(),
            feedback_issue: "Detail retained".into(), feedback_note: String::new(),
            review: None, approve_example: false, training_permission: false, feedback_busy: false,
            feedback_message: "No feedback sent".into(), last_receipt: None,
            last_processed: None,
            installed_models: installed_ai_models(),
        }
    }

    fn load_paths(&mut self, paths: impl IntoIterator<Item = PathBuf>, ctx: &egui::Context) {
        let mut errors = Vec::new();
        let old_len = self.photos.len();
        for path in paths {
            if !path.is_file() { continue; }
            match raw_bridge::open_photo(&path) {
                Ok(imported) => {
                    let decoded = imported.pixels;
                    // The screen only needs a compact display copy; original pixels are retained.
                    let small = decoded.thumbnail(1700, 1700).to_rgb8();
                    let texture = to_texture(ctx, format!("original:{}", self.photos.len()), &small);
                    self.photos.push(Photo { path, original: Arc::new(decoded), raw: imported.raw, detail: imported.detail, before_texture: texture, after_texture: None });
                },
                Err(err) => errors.push(format!("{}: {}", path.display(), err)),
            }
        }
        if self.photos.len() > old_len {
            self.review = None; self.last_processed = None;
            self.selected = old_len;
            self.schedule_preview(ctx, true);
            self.status = format!("Loaded {} image(s).", self.photos.len() - old_len);
        }
        if !errors.is_empty() {
            self.status = format!("Could not import {} file(s). {}", errors.len(), errors[0]);
        }
    }

    fn schedule_preview(&mut self, ctx: &egui::Context, immediate: bool) {
        self.preview_job = self.preview_job.wrapping_add(1);
        self.review = None;
        self.approve_example = false;
        self.training_permission = false;
        self.last_processed = None;
        self.preview_busy = true;
        if immediate {
            self.start_preview(ctx);
        } else {
            self.pending_preview = Some(Instant::now());
            ctx.request_repaint_after(Duration::from_millis(240));
        }
    }

    fn start_preview(&mut self, ctx: &egui::Context) {
        self.pending_preview = None;
        let Some(photo) = self.photos.get(self.selected) else { self.preview_busy = false; return; };
        let input = photo.original.thumbnail(1700, 1700);
        let settings = self.settings.clone();
        let tx = self.tx.clone();
        let repaint = ctx.clone();
        let index = self.selected;
        let job = self.preview_job;
        thread::spawn(move || {
            let result = process::process_image(&input, &settings, false).map_err(|e| e.to_string());
            let _ = tx.send(WorkerResult::Preview { job, index, result });
            repaint.request_repaint();
        });
    }

    fn process_messages(&mut self, ctx: &egui::Context) {
        while let Ok(message) = self.rx.try_recv() {
            match message {
                WorkerResult::Preview { job, index, result } if job == self.preview_job && index == self.selected => {
                    self.preview_busy = false;
                    match result {
                        Ok(result) => {
                            self.last_processed = Some((index, result.image.clone()));
                            if let Some(photo) = self.photos.get_mut(index) {
                                photo.after_texture = Some(to_texture(ctx, format!("processed:{index}:{job}"), &result.image));
                                let size = format!("{} × {}", result.image.width(), result.image.height());
                                self.status = match result.report {
                                    Some(report) => format!("{size} | {report}"),
                                    None => format!("Preview updated | {size}"),
                                };
                            }
                        }
                        Err(error) => { self.status = format!("Preview failed: {error}"); }
                    }
                }
                WorkerResult::Preview { .. } => {},
                WorkerResult::ExportFinished { count, errors } => {
                    self.export_busy = false;
                    self.status = if errors.is_empty() {
                        format!("Exported {count} image(s) successfully.")
                    } else {
                        format!("Exported {count}; {} errors. First: {}", errors.len(), errors[0])
                    };
                }
                WorkerResult::UpdateChecked(result) => {
                    self.update_busy = false;
                    match result {
                        Ok(m) => {
                            self.update_message = format!("Signed beta model: {} {} | {}", m.model_id, m.version, m.notes);
                            let auto = self.prefs.auto_install_models;
                            self.latest_manifest = Some(m);
                            if auto { self.start_model_install(ctx); }
                        },
                        Err(error) => { self.update_message = format!("Update check failed: {error}"); }
                    }
                }
                WorkerResult::ModelInstalled(result) => {
                    self.update_busy = false;
                    match result {
                        Ok(p) => {
                            self.previous_model = Some(self.settings.ai_model_path.clone());
                            self.settings.ai_model_path = p.to_string_lossy().to_string();
                            self.prefs.active_model_path = self.settings.ai_model_path.clone();
                            let _ = network::save_preferences(&self.prefs);
                            self.update_message = format!("Verified model installed: {} (not automatically enabled)", p.display());
                            self.schedule_preview(ctx, false);
                        },
                        Err(error) => self.update_message = format!("Installation refused: {error}"),
                    }
                }
                WorkerResult::ContributionSent(result) => {
                    self.feedback_busy = false;
                    match result {
                        Ok(receipt) => {
                            self.feedback_message = format!("Contribution stored, receipt {}", receipt.id);
                            self.last_receipt = Some(receipt);
                            self.review = None;
                            self.approve_example = false;
                            self.training_permission = false;
                        },
                        Err(error) => self.feedback_message = format!("Submission failed: {error}"),
                    }
                }
                WorkerResult::ContributionDeleted(result) => {
                    self.feedback_busy = false;
                    match result {
                        Ok(()) => { self.last_receipt = None; self.feedback_message = "Contribution deleted on server".into(); },
                        Err(error) => self.feedback_message = format!("Deletion failed: {error}"),
                    }
                }
            }
        }
        if let Some(at) = self.pending_preview {
            if at.elapsed() >= Duration::from_millis(220) {
                self.start_preview(ctx);
            } else {
                ctx.request_repaint_after(Duration::from_millis(100));
            }
        }
    }

    fn check_model_updates(&mut self, ctx: &egui::Context) {
        if self.update_busy { return; }
        self.update_busy = true;
        self.update_message = "Checking signed beta update manifest...".into();
        let url = self.prefs.manifest_url.clone();
        let tx = self.tx.clone(); let repaint = ctx.clone();
        thread::spawn(move || {
            let result = network::check_updates(&url).map_err(|e| format!("{e:#}"));
            let _ = tx.send(WorkerResult::UpdateChecked(result)); repaint.request_repaint();
        });
    }

    fn start_model_install(&mut self, ctx: &egui::Context) {
        if self.update_busy { return; }
        let Some(manifest) = self.latest_manifest.clone() else { return; };
        // Signed manifests are the only source of model filenames and hashes.
        self.update_busy = true;
        self.update_message = format!("Downloading and verifying model {}...", manifest.version);
        let tx = self.tx.clone(); let repaint = ctx.clone();
        thread::spawn(move || {
            let result = network::install_model(&manifest).map_err(|e| format!("{e:#}"));
            let _ = tx.send(WorkerResult::ModelInstalled(result)); repaint.request_repaint();
        });
    }

    fn prepare_example(&mut self, ctx: &egui::Context) -> anyhow::Result<()> {
        let photo = self.photos.get(self.selected).ok_or_else(|| anyhow::anyhow!("Import a photo first"))?;
        let (_, processed) = self.last_processed.as_ref().filter(|(i, _)| *i == self.selected)
            .ok_or_else(|| anyhow::anyhow!("Wait for the enhanced preview to finish"))?;
        let before = photo.original.thumbnail(720, 720).to_rgb8();
        let after = DynamicImage::ImageRgb8(processed.clone()).thumbnail(720, 720).to_rgb8();
        let encode = |img: &RgbImage| -> anyhow::Result<String> {
            let mut out = Cursor::new(Vec::new());
            DynamicImage::ImageRgb8(img.clone()).write_to(&mut out, ImageFormat::Png)?;
            Ok(BASE64.encode(out.into_inner()))
        };
        self.review = Some(ExampleReview {
            before_png_b64: encode(&before)?, after_png_b64: encode(&after)?,
            before_texture: to_texture(ctx, "review-original".into(), &before),
            after_texture: to_texture(ctx, "review-enhanced".into(), &after),
        });
        self.approve_example = false;
        self.training_permission = false;
        Ok(())
    }

    fn send_feedback(&mut self, ctx: &egui::Context) {
        if !self.prefs.contribute_enabled || self.feedback_busy { return; }
        let include = self.review.is_some() && self.approve_example;
        let body = network::Contribution {
            consent_version: network::CONSENT_VERSION.into(),
            app_version: env!("CARGO_PKG_VERSION").into(),
            model_label: self.settings.ai_model_path.rsplit(|c| c == '/' || c == '\\').next().unwrap_or("classic").chars().take(100).collect(),
            rating: self.feedback_rating.clone(), issue: self.feedback_issue.clone(),
            note: self.feedback_note.chars().take(400).collect(),
            before_png_b64: if include { self.review.as_ref().map(|r| r.before_png_b64.clone()) } else { None },
            after_png_b64: if include { self.review.as_ref().map(|r| r.after_png_b64.clone()) } else { None },
            training_permission: include && self.training_permission,
        };
        let url = self.prefs.feedback_url.clone();
        let token = self.beta_token.clone();
        let tx = self.tx.clone(); let repaint = ctx.clone();
        self.feedback_busy = true;
        self.feedback_message = "Submitting approved feedback...".into();
        thread::spawn(move || {
            let result = network::send_contribution(&url, &token, &body).map_err(|e| format!("{e:#}"));
            let _ = tx.send(WorkerResult::ContributionSent(result)); repaint.request_repaint();
        });
    }

    fn delete_feedback(&mut self, ctx: &egui::Context) {
        let Some(receipt) = self.last_receipt.clone() else { return; };
        if self.feedback_busy { return; }
        self.feedback_busy = true;
        let url = self.prefs.feedback_url.clone(); let token = self.beta_token.clone();
        let tx = self.tx.clone(); let repaint = ctx.clone();
        thread::spawn(move || {
            let result = network::delete_contribution(&url, &token, &receipt).map_err(|e| format!("{e:#}"));
            let _ = tx.send(WorkerResult::ContributionDeleted(result)); repaint.request_repaint();
        });
    }

    fn export_to(&mut self, directory: PathBuf, batch: bool, ctx: &egui::Context) {
        if self.export_busy || self.photos.is_empty() { return; }
        let photos: Vec<(PathBuf, Arc<DynamicImage>, bool)> = if batch {
            self.photos.iter().map(|p| (p.path.clone(), Arc::clone(&p.original), p.raw)).collect()
        } else {
            self.photos.get(self.selected).into_iter()
                .map(|p| (p.path.clone(), Arc::clone(&p.original), p.raw)).collect()
        };
        let tx = self.tx.clone();
        let repaint = ctx.clone();
        let settings = self.settings.clone();
        self.export_busy = true;
        self.status = format!("Exporting {} image(s) ...", photos.len());
        thread::spawn(move || {
            let mut successes = 0;
            let mut errors = Vec::new();
            for (source_path, original, is_raw) in photos {
                let name = source_path.file_stem().unwrap_or_default().to_string_lossy();
                // RAW and any high-bit-depth import always export TIFF16, including ONNX AI.
                let keep_16_bit = is_raw || process::source_is_high_precision(&original);
                let extension = if keep_16_bit { "tiff" } else { "png" };
                let output_path = unique_destination(&directory, &format!("{}_aero", name), extension);
                let result = if keep_16_bit {
                    process::process_image_16(&original, &settings, true)
                        .and_then(|img| process::export_tiff16(&img, &output_path))
                } else {
                    process::process_image(&original, &settings, true)
                        .and_then(|processed| process::export_png(&processed.image, &output_path))
                };
                match result {
                    Ok(()) => successes += 1,
                    Err(err) => errors.push(format!("{}: {}", source_path.display(), err)),
                }
            }
            let _ = tx.send(WorkerResult::ExportFinished { count: successes, errors });
            repaint.request_repaint();
        });
    }
}

fn unique_destination(dir: &Path, stem: &str, extension: &str) -> PathBuf {
    let initial = dir.join(format!("{stem}.{extension}"));
    if !initial.exists() { return initial; }
    for n in 2..10_000 {
        let candidate = dir.join(format!("{stem}_{n}.{extension}"));
        if !candidate.exists() { return candidate; }
    }
    dir.join(format!("{stem}_final.{extension}"))
}

fn photo_view(ui: &mut egui::Ui, label: &str, texture: Option<&TextureHandle>, max_width: f32, zoom: f32) {
    ui.strong(label);
    ui.add_space(6.0);
    if let Some(texture) = texture {
        let [tw, th] = texture.size();
        let aspect = th as f32 / (tw as f32).max(1.0);
        let width = (max_width * zoom).max(40.0);
        egui::ScrollArea::both().auto_shrink([false, false]).show(ui, |ui| {
            ui.add(egui::Image::new((texture.id(), Vec2::new(width, width * aspect))));
        });
    } else {
        ui.add_space(40.0);
        ui.label("Rendering preview ...");
    }
}

impl eframe::App for Studio {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        self.process_messages(&ctx);
        let dropped: Vec<PathBuf> = ctx.input(|input| {
            input.raw.dropped_files.iter().map(|file| file.path().to_path_buf()).collect()
        });
        if !dropped.is_empty() { self.load_paths(dropped, &ctx); }

        egui::Panel::top("topbar").show(ui, |ui| {
            ui.add_space(8.0);
            ui.horizontal(|ui| {
                ui.heading(egui::RichText::new("AEROENHANCE").strong().color(Color32::from_rgb(100, 200, 250)));
                ui.label(egui::RichText::new("STUDIO").color(Color32::LIGHT_GRAY));
                ui.separator();
                ui.label("Native Rust / v0.7 High Precision private beta");
                ui.add_space(16.0);
                if ui.button("+ Import photos").clicked() {
                    if let Some(files) = rfd::FileDialog::new()
                        .add_filter("Images + RAW", &["jpg", "jpeg", "png", "tif", "tiff", "bmp", "webp", "cr2", "cr3", "crw", "arw", "srf", "sr2", "nef", "nrw", "dng", "raf", "rw2", "rwl", "pef", "orf", "srw", "mrw"])
                        .pick_files() { self.load_paths(files, &ctx); }
                }
                let export_enabled = !self.export_busy && !self.photos.is_empty();
                if ui.add_enabled(export_enabled, egui::Button::new("Export selected")).clicked() {
                    if let Some(dir) = rfd::FileDialog::new().pick_folder() { self.export_to(dir, false, &ctx); }
                }
                if ui.add_enabled(export_enabled, egui::Button::new("Export all")).clicked() {
                    if let Some(dir) = rfd::FileDialog::new().pick_folder() { self.export_to(dir, true, &ctx); }
                }
            });
            ui.add_space(8.0);
        });

        egui::Panel::left("library").default_size(220.0).min_size(170.0).show(ui, |ui| {
            ui.heading("Library");
            ui.label(egui::RichText::new(format!("{} imported", self.photos.len())).color(Color32::GRAY));
            ui.separator();
            let mut select = None;
            egui::ScrollArea::vertical().show(ui, |ui| {
                for (idx, p) in self.photos.iter().enumerate() {
                    let name = p.path.file_name().unwrap_or_default().to_string_lossy();
                    if ui.selectable_label(idx == self.selected, name.as_ref()).clicked() { select = Some(idx); }
                }
            });
            if let Some(next) = select {
                self.selected = next;
                self.schedule_preview(&ctx, true);
            }
        });

        egui::Panel::right("tools").default_size(330.0).min_size(270.0).show(ui, |ui| {
            egui::ScrollArea::vertical().show(ui, |ui| {
            ui.heading("Enhancement tools");
            ui.label(egui::RichText::new("All edits are non-destructive").color(Color32::GRAY));
            ui.separator();
            let mut dirty = false;
            ui.heading("Classic processing");
            ui.small("Conventional image filters, not AI models.");
            dirty |= ui.add(egui::Slider::new(&mut self.settings.denoise, 0.0..=1.0).text("Noise reduction")).changed();
            dirty |= ui.add(egui::Slider::new(&mut self.settings.sharpening, 0.0..=1.5).text("Sharpen")).changed();
            ui.add_space(10.0);
            ui.label("Output scaling (Lanczos)");
            egui::ComboBox::from_id_salt("upscale_mode")
                .selected_text(format!("{}×", self.settings.upscale))
                .show_ui(ui, |ui| {
                    for scale in [1, 2, 4] {
                        dirty |= ui.selectable_value(&mut self.settings.upscale, scale, format!("{scale}×")).changed();
                    }
                });
            ui.small("Full scaling applies on export. Preview stays responsive.");
            ui.small("RAW / 16-bit inputs: AI and classic tools export 16-bit TIFF. Display previews are 8-bit only.");
            ui.separator();
            ui.heading("AI inference / ONNX");
            #[cfg(feature = "ai-cuda")]
            { ui.colored_label(Color32::LIGHT_GREEN, "CUDA-capable build; runtime dependencies still required."); }
            #[cfg(all(feature = "ai", not(feature = "ai-cuda")))]
            { ui.colored_label(Color32::YELLOW, "ONNX CPU build. Use build-ai-cuda.bat for GPU."); }
            #[cfg(not(feature = "ai"))]
            { ui.colored_label(Color32::YELLOW, "No AI in this build. Use build-ai-cuda.bat."); }
            dirty |= ui.checkbox(&mut self.settings.ai_enabled, "Enable neural model").changed();
            ui.horizontal(|ui| {
                ui.label("AI compute");
                egui::ComboBox::from_id_salt("ai_device")
                    .selected_text(match self.settings.ai_device {
                        AiDevice::Auto => "Auto (GPU -> CPU)",
                        AiDevice::Cuda => "NVIDIA CUDA (strict)",
                        AiDevice::Cpu => "CPU only",
                    })
                    .show_ui(ui, |ui| {
                        dirty |= ui.selectable_value(&mut self.settings.ai_device, AiDevice::Auto, "Auto (GPU -> CPU)").changed();
                        dirty |= ui.selectable_value(&mut self.settings.ai_device, AiDevice::Cuda, "NVIDIA CUDA (strict)").changed();
                        dirty |= ui.selectable_value(&mut self.settings.ai_device, AiDevice::Cpu, "CPU only").changed();
                    });
            });
            dirty |= ui.checkbox(&mut self.settings.ai_fast_math, "Faster CUDA math (TF32)").changed();
            ui.small("TF32 is optional: try off first for maximum numeric precision. CUDA uses a 6 GB GPU arena cap.");
            ui.label("ONNX model (.onnx)");
            ui.horizontal(|ui| {
                dirty |= ui.text_edit_singleline(&mut self.settings.ai_model_path).changed();
                if ui.button("Browse").clicked() {
                    if let Some(path) = rfd::FileDialog::new().add_filter("ONNX model", &["onnx"]).pick_file() {
                        self.settings.ai_model_path = path.display().to_string();
                        dirty = true;
                    }
                }
                if ui.button("Detect installed").clicked() {
                    if let Some(path) = find_default_model() {
                        self.settings.ai_model_path = path.to_string_lossy().into_owned();
                        self.update_message = format!("Found local SCUNet model: {}", path.display());
                        dirty = true;
                    } else {
                        self.update_message = "No complete local SCUNet installation found. Run download-scunet-model.bat beside AeroEnhance, then click Detect installed.".into();
                    }
                }
            });
            ui.horizontal(|ui| {
                if ui.button("Refresh local models").clicked() {
                    self.installed_models = installed_ai_models();
                    self.update_message = format!("Found {} installed model(s). Locally trained ONNX models require matching export checksums.", self.installed_models.len());
                }
                let models = self.installed_models.clone();
                egui::ComboBox::from_id_salt("local_ai_model_selector")
                    .selected_text("Choose installed AI model")
                    .show_ui(ui, |ui| {
                        for (name, path) in models {
                            let next = path.to_string_lossy().into_owned();
                            if ui.selectable_label(self.settings.ai_model_path == next, &name).clicked() {
                                self.settings.ai_model_path = next;
                                self.update_message = format!("Selected {name}. Enable neural model to use it.");
                                dirty = true;
                            }
                        }
                    });
            });
            ui.small("Select SCUNet or a verified, privately trained AeroDenoiseNet model. Training and publishing never happen inside AeroEnhance.");
            dirty |= ui.add(egui::Slider::new(&mut self.settings.ai_blend, 0.0..=1.0).text("AI blend")).changed();
            ui.small("Model must accept NCHW float32 RGB 256×256 and return RGB at 1×/2×/4×.");
            ui.separator();
            ui.heading("Community AI model updates (opt-in pilot)");
            ui.small("Opt-in, verified model updates. You can receive improvements without contributing photographs.");
            let mut save = false;
            save |= ui.checkbox(&mut self.prefs.check_updates_at_launch, "Check for updates on startup").changed();
            save |= ui.checkbox(&mut self.prefs.auto_install_models, "Automatically install verified beta models").changed();
            ui.label("Signed manifest URL");
            save |= ui.text_edit_singleline(&mut self.prefs.manifest_url).changed();
            if save {
                if let Err(e) = network::save_preferences(&self.prefs) {
                    self.update_message = format!("Could not save preferences: {e}");
                }
            }
            ui.horizontal(|ui| {
                if ui.add_enabled(!self.update_busy, egui::Button::new("Check updates")).clicked() { self.check_model_updates(&ctx); }
                if ui.add_enabled(!self.update_busy && self.latest_manifest.is_some(), egui::Button::new("Install verified model")).clicked() {
                    self.start_model_install(&ctx);
                }
            });
            if let Some(prior) = self.previous_model.clone() {
                if !prior.is_empty() && ui.button("Revert to previous model").clicked() {
                    self.settings.ai_model_path = prior.clone();
                    self.prefs.active_model_path = prior.clone();
                    let _ = network::save_preferences(&self.prefs);
                    self.previous_model = None;
                    dirty = true;
                }
            }
            ui.small(&self.update_message);
            if let Some(m) = &self.latest_manifest {
                if let (Some(v), Some(link)) = (&m.latest_app_version, &m.app_release_url) {
                    ui.label(format!("App release: {v}"));
                    ui.hyperlink_to("Open verified release URL (manual download)", link);
                }
            }
            ui.separator();
            ui.heading("Help train the shared AeroEnhance AI (optional)");
            if ui.checkbox(&mut self.prefs.contribute_enabled, "Allow me to send approved feedback").changed() {
                if let Err(e) = network::save_preferences(&self.prefs) {
                    self.feedback_message = format!("Could not save preferences: {e}");
                }
            }
            ui.small("OFF by default. Only feedback you explicitly submit is sent; photographs are never collected in the background. A pilot invitation token is required.");
            ui.small("Ratings and approved previews are retained for up to 30 days. Training permission requires a separate opt-in. Weekly updates happen only after curation and quality review; withdrawing data cannot undo training already published.");
            ui.add_enabled_ui(self.prefs.contribute_enabled, |ui| {
                ui.label("Community pilot feedback HTTPS URL (or local test server)");
                if ui.text_edit_singleline(&mut self.prefs.feedback_url).changed() {
                    let _ = network::save_preferences(&self.prefs);
                }
                ui.label("Personal pilot access token (memory only)");
                ui.add(egui::TextEdit::singleline(&mut self.beta_token).password(true));
                ui.label("Quality rating");
                egui::ComboBox::from_id_salt("feedback_rating")
                    .selected_text(&self.feedback_rating).show_ui(ui, |ui| {
                        for s in ["Good", "Needs work", "Unusable"] {
                            ui.selectable_value(&mut self.feedback_rating, s.to_owned(), s);
                        }
                    });
                ui.label("What matters?");
                egui::ComboBox::from_id_salt("feedback_issue")
                    .selected_text(&self.feedback_issue).show_ui(ui, |ui| {
                        for s in ["Detail retained", "Lettering damaged", "Over-smoothed", "Colour artifacts", "Halos", "Noise remains", "Invented texture"] {
                            ui.selectable_value(&mut self.feedback_issue, s.to_owned(), s);
                        }
                    });
                ui.label("Optional note (400 chars max)");
                ui.text_edit_multiline(&mut self.feedback_note);
                ui.separator();
                if ui.button("Prepare optional photo example for review").clicked() {
                    if let Err(e) = self.prepare_example(&ctx) { self.feedback_message = format!("Example unavailable: {e}"); }
                }
                if let Some(review) = &self.review {
                    ui.small("Exactly these two reduced, metadata-free PNG previews would be uploaded. Check for faces, names, registrations and private details before approval.");
                    for (label, texture) in [("Before", &review.before_texture), ("After", &review.after_texture)] {
                        ui.label(label);
                        let [w,h] = texture.size();
                        ui.image((texture.id(), Vec2::new(220.0, 220.0 * h as f32 / (w as f32).max(1.0))));
                    }
                    ui.checkbox(&mut self.approve_example, "I explicitly approve uploading these exact images");
                    ui.add_enabled_ui(self.approve_example, |ui| {
                        ui.checkbox(&mut self.training_permission, "Separate permission: I own or can license these images for private AI model training");
                        ui.small("Training is optional and manually curated. These previews are not assumed to be clean reference images. Training effects may not be reversible after publication.");
                    });
                    if !self.approve_example { self.training_permission = false; }
                    if !self.approve_example { ui.small("Without approval, only the rating/note is submitted."); }
                }
                if ui.add_enabled(!self.feedback_busy && self.beta_token.len() >= 16,
                    egui::Button::new(if self.approve_example { "Submit approved example + rating" } else { "Submit rating only" })).clicked() {
                    self.send_feedback(&ctx);
                }
                if let Some(receipt) = self.last_receipt.clone() {
                    ui.horizontal(|ui| {
                        if ui.button("Copy deletion receipt").clicked() {
                            ui.ctx().copy_text(format!("ID: {}\nDeletion secret: {}", receipt.id, receipt.deletion_secret));
                        }
                        if ui.add_enabled(!self.feedback_busy, egui::Button::new("Delete contribution")).clicked() { self.delete_feedback(&ctx); }
                    });
                    ui.small("Save the deletion receipt somewhere private. It will be lost when you close the app.");
                }
                ui.small(&self.feedback_message);
            });
            ui.add_space(10.0);
            if ui.button("Reset settings").clicked() {
                self.settings = Settings::default();
                self.prefs.active_model_path = String::new();
                let _ = network::save_preferences(&self.prefs);
                dirty = true;
            }
            if dirty {
                self.prefs.active_model_path = self.settings.ai_model_path.clone();
                let _ = network::save_preferences(&self.prefs);
                self.schedule_preview(&ctx, false);
            }
            });
        });

        egui::Panel::bottom("statusbar").show(ui, |ui| {
            ui.horizontal(|ui| {
                if self.preview_busy || self.export_busy { ui.spinner(); }
                ui.label(&self.status);
                ui.separator();
                ui.label("Local photo processing · No automatic photo uploads");
            });
        });

        egui::CentralPanel::default().show(ui, |ui| {
            if self.photos.is_empty() {
                ui.vertical_centered_justified(|ui| {
                    ui.heading("Aircraft detail. Without the noise.");
                    ui.label("Import Canon CR2/CR3, Sony ARW, DNG, NEF, JPEG, PNG or TIFF photographs.");
                    ui.label("You can also drag and drop files into the window.");
                });
                return;
            }
            ui.horizontal(|ui| {
                ui.label("Comparison viewer");
                ui.separator();
                ui.add(egui::Slider::new(&mut self.zoom, 0.4..=3.0).text("Zoom"));
                if ui.button("100%").clicked() { self.zoom = 1.0; }
                if self.preview_busy { ui.spinner(); }
            });
            ui.separator();
            let total_width = ui.available_width();
            let max_width = ((total_width - 18.0) / 2.0).max(100.0);
            if let Some(p) = self.photos.get(self.selected) {
                ui.small(&p.detail);
                ui.columns(2, |cols| {
                    photo_view(&mut cols[0], "ORIGINAL", Some(&p.before_texture), max_width, self.zoom);
                    photo_view(&mut cols[1], "ENHANCED", p.after_texture.as_ref(), max_width, self.zoom);
                });
            }
        });
    }
}

// Use the same artwork for the titlebar/taskbar and the Windows executable icon.
// It is embedded at compile time so model/installer paths are unaffected.
fn app_window_icon() -> egui::IconData {
    let decoded = image::load_from_memory(include_bytes!("../assets/aeroenhance-icon.png"))
        .expect("Bundled AeroEnhance icon PNG must be valid")
        .into_rgba8();
    egui::IconData {
        width: decoded.width(),
        height: decoded.height(),
        rgba: decoded.into_raw(),
    }
}

fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([1420.0, 860.0])
            .with_min_inner_size([960.0, 620.0])
            .with_icon(app_window_icon()),
        ..Default::default()
    };
    eframe::run_native("AeroEnhance Studio — AeroStudios", options,
        Box::new(|cc| Ok(Box::new(Studio::new(&cc.egui_ctx)))))
}
