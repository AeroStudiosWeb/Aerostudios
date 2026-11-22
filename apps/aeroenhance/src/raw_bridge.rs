//! The same RAW decoder used by AeroRoom, shared as a Rust library.
//! Develop camera mosaics at full precision, convert to display-referred sRGB16.
//! No embedded JPEG fallback is used for the full-resolution image.

use anyhow::{bail, Context, Result};
use image::DynamicImage;
use std::path::Path;

pub struct ImportedPhoto {
    pub pixels: DynamicImage,
    pub raw: bool,
    pub detail: String,
}

pub fn is_raw_file(path: &Path) -> bool {
    path.extension().and_then(|s| s.to_str()).is_some_and(|ext| {
        matches!(ext.to_ascii_lowercase().as_str(),
            "cr2" | "cr3" | "crw" | "arw" | "srf" | "sr2" | "nef" | "nrw" |
            "dng" | "raf" | "rw2" | "rwl" | "pef" | "orf" | "srw" |
            "mrw" | "erf" | "mef")
    })
}

pub fn open_photo(path: &Path) -> Result<ImportedPhoto> {
    if is_raw_file(path) {
        #[cfg(feature = "aeroroom-raw")]
        { return open_aeroroom_raw(path); }
        #[cfg(not(feature = "aeroroom-raw"))]
        { bail!("RAW support is disabled in this executable. Rebuild with --features aeroroom-raw."); }
    }
    let pixels = image::open(path)
        .with_context(|| format!("Unable to decode image {}", path.display()))?;
    Ok(ImportedPhoto {
        pixels,
        raw: false,
        detail: "Rendered image".to_string(),
    })
}

/// Apply sRGB encoding to *linear* RGB without quantising to 8-bit.
#[cfg(feature = "aeroroom-raw")]
fn linear_to_srgb16(value: f32) -> u16 {
    let linear = if value.is_finite() { value.clamp(0.0, 1.0) } else { 0.0 };
    let encoded = if linear <= 0.0031308 {
        12.92 * linear
    } else {
        1.055 * linear.powf(1.0 / 2.4) - 0.055
    };
    (encoded.clamp(0.0, 1.0) * 65535.0).round() as u16
}

#[cfg(feature = "aeroroom-raw")]
fn open_aeroroom_raw(path: &Path) -> Result<ImportedPhoto> {
    use image::{Rgb, ImageBuffer};
    use lightcraft_color::{REC2020, SRGB};
    use lightcraft_raw::{color, Method};

    let size = std::fs::metadata(path)?.len();
    if size > 1024 * 1024 * 1024 {
        bail!("RAW file exceeds 1 GiB safety limit");
    }
    let bytes = std::fs::read(path)
        .with_context(|| format!("Could not read RAW file {}", path.display()))?;
    let mut raw = lightcraft_raw::decode(&bytes)
        .with_context(|| format!("AeroRoom RAW engine could not decode {} (unsupported camera/compression or damaged file)", path.display()))?;
    // AeroRoom's camera-look stage tries a JPEG fit before looking up spectral
    // matrices. For cameras without DNG matrices, such as the Canon EOS 7D,
    // the raw decoder alone otherwise uses a generic colour model.
    let fallback_colour = !color::has_matrix(&raw.color);
    let camera_jpeg = if fallback_colour {
        match lightcraft_raw::embedded_preview_color_space(&bytes) {
            Some(lightcraft_raw::PreviewColorSpace::AdobeRgb) |
            Some(lightcraft_raw::PreviewColorSpace::ProPhoto) => None,
            _ => lightcraft_raw::embedded_preview(&bytes)
                .and_then(|jpeg| image::load_from_memory(&jpeg).ok())
                .map(|image| image.to_rgb8()),
        }
    } else { None };
    // Fallback, as in AeroRoom, to the shared measured camera matrices when
    // there's no accepted embedded-JPEG look. This *is* the same upstream table.
    let spectral_camera = if fallback_colour {
        raw.metadata.model.as_deref().and_then(|model|
            lightcraft_raw::spectral::find(raw.metadata.make.as_deref(), model))
    } else { None };
    let mut developed = raw.develop(Method::Ahd)
        .context("AeroRoom demosaicing failed")?;
    // A camera JPEG fit takes priority over spectral matrices, just as the
    // AeroRoom starting-colour stage does. Spectral matrices are applied when
    // no JPEG look can be fitted, below (after the first full-resolution pass).
    let white = color::as_shot_white_xy(&raw);
    let transform = color::camera_transform(&raw, white);
    lightcraft_raw::highlight::reconstruct(&mut developed, transform.wb, 0.99);
    let matrix = REC2020.to_space(&SRGB).mul(&transform.matrix);
    let gain = 2f32.powf(transform.baseline_exposure as f32);
    let oriented = developed.oriented(raw.orientation);
    let (w, h) = (u32::try_from(oriented.width)?, u32::try_from(oriented.height)?);
    if w == 0 || h == 0 || (w as u64) * (h as u64) > 200_000_000 {
        bail!("RAW developed dimensions are invalid or exceed 200 MP safety limit");
    }
    let mut rendered = Vec::with_capacity((w as usize) * (h as usize) * 3);
    for pixel in &oriented.data {
        let linear = matrix.apply_f32([
            pixel[0] * transform.wb[0],
            pixel[1] * transform.wb[1],
            pixel[2] * transform.wb[2],
        ]);
        for channel in linear {
            let v = (channel * gain).max(0.0);
            // Same display-friendly highlight rolloff as AeroRoom rawrender,
            // applied before the sRGB transfer curve.
            let toned = if v < 0.8 { v } else { 0.8 + 0.2 * (1.0 - (-(v - 0.8) / 0.2).exp()) };
            rendered.push(linear_to_srgb16(toned));
        }
    }
    let mut buffer: ImageBuffer<Rgb<u16>, Vec<u16>> = ImageBuffer::from_raw(w, h, rendered)
        .context("RAW colour buffer dimensions did not match")?;
    let mut colour_note = if fallback_colour {
        "generic fallback (no fitted camera look)".to_string()
    } else { "camera colour matrices".to_string() };
    let fitted = if let Some(ref reference) = camera_jpeg {
        crate::raw_look::fit_from_camera_jpeg(&buffer, reference)
    } else { None };
    if let Some(look) = fitted {
        look.apply(&mut buffer);
        colour_note = "AeroRoom-style embedded JPEG colour/tone fit".to_string();
    } else if let Some(camera) = spectral_camera {
        // Re-develop using the measured matrices, not an arbitrary saturation
        // adjustment. JPEG fit has priority, matching AeroRoom's decision tree.
        if camera.fill(&mut raw.color) {
            let calibrated_white = color::as_shot_white_xy(&raw);
            let calibrated = color::camera_transform(&raw, calibrated_white);
            let calibrated_matrix = REC2020.to_space(&SRGB).mul(&calibrated.matrix);
            let calibrated_gain = 2f32.powf(calibrated.baseline_exposure as f32);
            let mut calibrated_developed = raw.develop(Method::Ahd)
                .context("AeroRoom calibrated demosaicing failed")?;
            lightcraft_raw::highlight::reconstruct(
                &mut calibrated_developed, calibrated.wb, 0.99,
            );
            let calibrated_oriented = calibrated_developed.oriented(raw.orientation);
            for (dst, p) in buffer.pixels_mut().zip(&calibrated_oriented.data) {
                let linear = calibrated_matrix.apply_f32([
                    p[0] * calibrated.wb[0],
                    p[1] * calibrated.wb[1],
                    p[2] * calibrated.wb[2],
                ]);
                for c in 0..3 {
                    let v = (linear[c] * calibrated_gain).max(0.0);
                    let toned = if v < 0.8 { v } else {
                        0.8 + 0.2 * (1.0 - (-(v - 0.8) / 0.2).exp())
                    };
                    dst.0[c] = linear_to_srgb16(toned);
                }
            }
            colour_note = "AeroRoom spectral camera calibration".to_string();
        }
    }
    let camera = format!("{} {}",
        raw.metadata.make.as_deref().unwrap_or(""),
        raw.metadata.model.as_deref().unwrap_or("")).trim().to_string();
    let camera = if camera.is_empty() { "unknown camera".to_string() } else { camera };
    Ok(ImportedPhoto {
        pixels: DynamicImage::ImageRgb16(buffer), raw: true,
        detail: format!("RAW · {camera} · {w}×{h} · 16-bit RGB · {colour_note}"),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn extensions_route_raw_files_to_the_raw_engine() {
        for name in ["test.CR2", "shot.cr3", "sony.ARW", "x.nef", "foo.dng"] {
            assert!(is_raw_file(Path::new(name)));
        }
        assert!(!is_raw_file(Path::new("test.jpg")));
    }
    #[cfg(feature = "aeroroom-raw")]
    #[test]
    fn srgb_transfer_has_high_precision() {
        assert_eq!(linear_to_srgb16(0.0), 0);
        assert_eq!(linear_to_srgb16(1.0), 65535);
        assert!(linear_to_srgb16(0.5) > 45000);
    }
}
