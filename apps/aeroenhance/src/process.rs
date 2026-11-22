use anyhow::{Context, Result};
use image::{imageops, DynamicImage, RgbImage};

/// `image` 0.25 intentionally does not define a `Rgb16Image` type alias.
/// This is its native RGB16 buffer type (three u16 samples per pixel).
pub type Rgb16Image = image::ImageBuffer<image::Rgb<u16>, Vec<u16>>;
#[cfg(test)]
use image::Rgb;
use std::path::Path;
#[cfg(feature = "ai")]
use std::sync::Arc;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AiDevice {
    Auto,
    Cuda,
    Cpu,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Settings {
    pub denoise: f32,
    pub sharpening: f32,
    pub upscale: u32,
    pub ai_enabled: bool,
    pub ai_model_path: String,
    pub ai_blend: f32,
    pub ai_device: AiDevice,
    pub ai_fast_math: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            denoise: 0.0,
            sharpening: 0.15,
            upscale: 1,
            ai_enabled: false,
            ai_model_path: String::new(),
            ai_blend: 1.0,
            ai_device: AiDevice::Auto,
            ai_fast_math: false,
        }
    }
}

fn clamp_u8(v: f32) -> u8 { v.round().clamp(0.0, 255.0) as u8 }

pub fn blend_images(original: &RgbImage, processed: &RgbImage, alpha: f32) -> RgbImage {
    assert_eq!(original.dimensions(), processed.dimensions());
    let strength = alpha.clamp(0.0, 1.0);
    let mut out = original.clone();
    for (dst, (a, b)) in out.pixels_mut().zip(original.pixels().zip(processed.pixels())) {
        for c in 0..3 {
            dst.0[c] = clamp_u8(a.0[c] as f32 * (1.0 - strength) + b.0[c] as f32 * strength);
        }
    }
    out
}

/// Conventional image filters. These are *not* AI models.
pub fn apply_classic(src: &RgbImage, settings: &Settings, resize: bool) -> RgbImage {
    let mut working = src.clone();
    if settings.denoise > 0.001 {
        let blurred = imageops::blur(&working, 0.9 + settings.denoise * 1.3);
        working = blend_images(&working, &blurred, settings.denoise * 0.72);
    }
    if settings.sharpening > 0.001 {
        let blurred = imageops::blur(&working, 1.1);
        let amount = settings.sharpening * 2.0;
        for (p, b) in working.pixels_mut().zip(blurred.pixels()) {
            for c in 0..3 {
                p.0[c] = clamp_u8(p.0[c] as f32 + amount * (p.0[c] as f32 - b.0[c] as f32));
            }
        }
    }
    if resize && settings.upscale > 1 {
        let w = working.width().saturating_mul(settings.upscale);
        let h = working.height().saturating_mul(settings.upscale);
        working = imageops::resize(&working, w, h, imageops::FilterType::Lanczos3);
    }
    working
}

pub struct Processed {
    pub image: RgbImage,
    pub report: Option<String>,
}

/// Whether the import contains native >8-bit source samples. RAW decoding
/// currently returns ImageRgb16; TIFF and PNG can also contain 16-bit samples.
pub fn source_is_high_precision(src: &DynamicImage) -> bool {
    matches!(src, DynamicImage::ImageRgb16(_) | DynamicImage::ImageRgba16(_) |
                  DynamicImage::ImageLuma16(_) | DynamicImage::ImageLumaA16(_))
}

pub fn process_image(src: &DynamicImage, settings: &Settings, resize: bool) -> Result<Processed> {
    // A preview is the ONLY intentional u16 -> u8 conversion for RAW photos:
    // it happens after high-precision AI and filters, for 8-bit GPU display.
    if source_is_high_precision(src) || settings.ai_enabled {
        let processed = process_image_16_with_report(src, settings, resize)?;
        return Ok(Processed {
            image: DynamicImage::ImageRgb16(processed.image).to_rgb8(),
            report: processed.report,
        });
    }
    Ok(Processed { image: apply_classic(&src.to_rgb8(), settings, resize), report: None })
}

pub fn export_png(img: &RgbImage, path: &Path) -> Result<()> {
    img.save_with_format(path, image::ImageFormat::Png)
        .with_context(|| format!("Unable to save PNG: {}", path.display()))
}


/// Float blending between the original u16 samples and the neural output.
/// All inputs and outputs remain high precision; round to u16 only once.
pub fn blend_images16(original: &Rgb16Image, processed: &Rgb16Image, alpha: f32) -> Rgb16Image {
    assert_eq!(original.dimensions(), processed.dimensions());
    let strength = alpha.clamp(0.0, 1.0);
    let mut out = original.clone();
    for (dst, (a, b)) in out.pixels_mut().zip(original.pixels().zip(processed.pixels())) {
        for c in 0..3 {
            dst.0[c] = ((a[c] as f32) * (1.0 - strength)
                + (b[c] as f32) * strength).round().clamp(0.0, 65535.0) as u16;
        }
    }
    out
}

pub struct Processed16 {
    pub image: Rgb16Image,
    pub report: Option<String>,
}

/// Single precision-preserving pipeline for RAW and 16-bit TIFF/PNG inputs.
/// Model input: full 16-bit sRGB development -> normalized f32 NCHW patches.
/// Model output: f32 NCHW -> f32 overlap blending -> u16 RGB.
/// No u8 path exists here, including neural blending and conventional filters.
pub fn process_image_16_with_report(src: &DynamicImage, settings: &Settings, resize: bool) -> Result<Processed16> {
    let rgb16 = src.to_rgb16();
    let (mut image, report) = if settings.ai_enabled {
        #[cfg(feature = "ai")]
        {
            let model_path = Path::new(&settings.ai_model_path);
            if !model_path.is_file() {
                anyhow::bail!("AI model not found. Choose a compatible .onnx file.");
            }
            let original = Arc::new(rgb16);
            let prediction = crate::ai::infer_tiled(
                Arc::clone(&original), model_path, settings.ai_device, settings.ai_fast_math,
            ).with_context(|| "High-precision ONNX inference failed")?;
            let pixels = if original.dimensions() == prediction.image.dimensions() {
                blend_images16(original.as_ref(), &prediction.image, settings.ai_blend)
            } else {
                // Super-resolution models change dimensions; no original-size blend.
                prediction.image
            };
            (pixels, Some(prediction.report))
        }
        #[cfg(not(feature = "ai"))]
        {
            anyhow::bail!("Neural inference unavailable. Compile with --features ai-cuda (or ai for CPU).");
        }
    } else {
        (rgb16, None)
    };

    if settings.denoise > 0.001 {
        let blurred = imageops::blur(&image, 0.9 + settings.denoise * 1.3);
        let strength = (settings.denoise * 0.72).clamp(0.0, 1.0);
        for (dst, smooth) in image.pixels_mut().zip(blurred.pixels()) {
            for c in 0..3 {
                dst.0[c] = ((dst.0[c] as f32) * (1.0 - strength)
                    + (smooth.0[c] as f32) * strength).round().clamp(0.0, 65535.0) as u16;
            }
        }
    }
    if settings.sharpening > 0.001 {
        let blurred = imageops::blur(&image, 1.1);
        let amount = settings.sharpening * 2.0;
        for (dst, smooth) in image.pixels_mut().zip(blurred.pixels()) {
            for c in 0..3 {
                let v = dst.0[c] as f32 + amount * (dst.0[c] as f32 - smooth.0[c] as f32);
                dst.0[c] = v.round().clamp(0.0, 65535.0) as u16;
            }
        }
    }
    if resize && settings.upscale > 1 {
        let width = image.width().checked_mul(settings.upscale).context("Scaled width overflows")?;
        let height = image.height().checked_mul(settings.upscale).context("Scaled height overflows")?;
        if (width as u64) * (height as u64) > 125_000_000 {
            anyhow::bail!("Export exceeds 125 megapixels; reduce upscale factor");
        }
        image = imageops::resize(&image, width, height, imageops::FilterType::Lanczos3);
    }
    Ok(Processed16 { image, report })
}

pub fn process_image_16(src: &DynamicImage, settings: &Settings, resize: bool) -> Result<Rgb16Image> {
    Ok(process_image_16_with_report(src, settings, resize)?.image)
}

pub fn export_tiff16(img: &Rgb16Image, path: &Path) -> Result<()> {
    DynamicImage::ImageRgb16(img.clone())
        .save_with_format(path, image::ImageFormat::Tiff)
        .with_context(|| format!("Unable to save 16-bit TIFF: {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn defaults_preserve_size() {
        let source = RgbImage::from_pixel(17, 19, Rgb([60, 120, 180]));
        let processed = apply_classic(&source, &Settings::default(), true);
        assert_eq!(source.dimensions(), processed.dimensions());
    }
    #[test]
    fn high_precision_processing_retains_16_bit_values() {
        let source = Rgb16Image::from_pixel(2, 3, image::Rgb([12345, 23456, 34567]));
        let result = process_image_16(&DynamicImage::ImageRgb16(source.clone()),
            &Settings { sharpening: 0.0, ..Settings::default() }, false).unwrap();
        assert_eq!(result, source);
    }
    #[test]
    fn ai_disabled_high_precision_preview_only_quantises_at_end() {
        let original = Rgb16Image::from_pixel(2, 3, image::Rgb([12001, 25002, 37003]));
        let input = DynamicImage::ImageRgb16(original.clone());
        let settings = Settings { sharpening: 0.0, ..Settings::default() };
        let full = process_image_16(&input, &settings, false).unwrap();
        assert_eq!(full, original);
        let preview = process_image(&input, &settings, false).unwrap().image;
        // The 8-bit preview is a rounded conversion of the processed 16-bit
        // image. 12001/65535*255 rounds to 47, not 46.
        let expected_preview = DynamicImage::ImageRgb16(full).to_rgb8();
        assert_eq!(preview, expected_preview);
        assert_eq!(preview.get_pixel(0, 0).0, [47, 97, 144]);
    }
    #[test]
    fn sixteen_bit_tiff_roundtrip() {
        let original = Rgb16Image::from_fn(7, 9, |x, y| {
            image::Rgb([1001 + 29 * x as u16, 25000 + 47 * y as u16, 60000 - x as u16])
        });
        let path = std::env::temp_dir().join(format!("aeroenhance_{}_{}_precision.tiff", std::process::id(), 42));
        export_tiff16(&original, &path).unwrap();
        let opened = image::open(&path).unwrap().to_rgb16();
        let _ = std::fs::remove_file(path);
        assert_eq!(opened, original);
    }
    #[test]
    fn ai_blend16_preserves_sub_eight_bit_values() {
        let a = Rgb16Image::from_pixel(1, 1, image::Rgb([12001, 32003, 40007]));
        let b = Rgb16Image::from_pixel(1, 1, image::Rgb([12003, 32005, 40009]));
        assert_eq!(blend_images16(&a, &b, 0.5).get_pixel(0, 0).0, [12002, 32004, 40008]);
    }
    #[test]
    fn blending_extremes() {
        let a = RgbImage::from_pixel(3, 4, Rgb([0, 50, 100]));
        let b = RgbImage::from_pixel(3, 4, Rgb([250, 250, 250]));
        assert_eq!(blend_images(&a, &b, 0.0), a);
        assert_eq!(blend_images(&a, &b, 1.0), b);
    }
    #[test]
    fn ai_defaults_to_auto_with_precise_math() {
        let settings = Settings::default();
        assert_eq!(settings.ai_device, AiDevice::Auto);
        assert!(!settings.ai_fast_math);
    }
    #[test]
    fn cpu_upscale_changes_dimensions() {
        let source = RgbImage::from_pixel(3, 5, Rgb([8, 16, 32]));
        let s = Settings { upscale: 2, ..Settings::default() };
        assert_eq!(apply_classic(&source, &s, true).dimensions(), (6, 10));
    }
}
