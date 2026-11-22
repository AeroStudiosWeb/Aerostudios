//! Camera-JPEG-guided starting look for RAW formats without DNG colour matrices.
//!
//! AeroRoom's full pipeline uses a fitted camera look for vendor RAW files;
//! `lightcraft-raw` by itself provides the sensor decoder and a neutral fallback.
//! AeroEnhance does not ship AeroRoom's entire editing engine. This deliberately
//! conservative, CPU-side colour-and-tone proxy restores an initial camera look
//! without replacing the full-resolution 16-bit sensor development with an
//! embedded 8-bit JPEG. It is not claimed to be a pixel-identical AeroRoom render.

use image::{ImageBuffer, Rgb, RgbImage, imageops};

pub type Rgb16Image = ImageBuffer<Rgb<u16>, Vec<u16>>;

#[derive(Clone, Debug)]
pub struct CameraLook {
    /// Per-channel sRGB ratio correction (green is kept at unity).
    rgb_gain: [f32; 3],
    /// Relative chroma correction; keeps the pixel's luminance constant.
    saturation: f32,
    /// Monotone 1D tone mapping derived from the camera's embedded JPEG.
    knots: [(f32, f32); 7],
}

fn lum(rgb: [f32; 3]) -> f32 {
    rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
}

fn chroma(rgb: [f32; 3]) -> f32 {
    let hi = rgb[0].max(rgb[1]).max(rgb[2]);
    let lo = rgb[0].min(rgb[1]).min(rgb[2]);
    (hi - lo) / hi.max(0.05)
}

fn median(values: &mut [f32]) -> f32 {
    values.sort_unstable_by(f32::total_cmp);
    values[values.len() / 2]
}

fn percentile(sorted: &[f32], p: f32) -> f32 {
    if sorted.is_empty() { return 0.0; }
    let pos = (p * (sorted.len() - 1) as f32).clamp(0.0, (sorted.len() - 1) as f32);
    let left = pos as usize;
    let right = (left + 1).min(sorted.len() - 1);
    sorted[left] + (sorted[right] - sorted[left]) * (pos - left as f32)
}

/// A lightweight proxy follows the same camera-JPEG reference principle as
/// AeroRoom. The JPEG supplies *only* rendering guidance. Every output pixel
/// comes from the full-resolution, 16-bit demosaiced RAW.
///
/// `preview` is decoded as an sRGB JPEG, after the caller has checked the RAW
/// preview colour-space tag. The fit is rejected unless enough unclipped,
/// reasonably aligned samples survive; no look is better than a wild look.
pub fn fit_from_camera_jpeg(source: &Rgb16Image, preview: &RgbImage) -> Option<CameraLook> {
    let (w, h) = source.dimensions();
    let (jw, jh) = preview.dimensions();
    if w < 32 || h < 32 || jw < 32 || jh < 32 { return None; }
    let raw_aspect = w as f64 / h as f64;
    let jpeg_aspect = jw as f64 / jh as f64;
    if ((raw_aspect / jpeg_aspect) - 1.0).abs() > 0.04 { return None; }

    // 256-pixel proxy. Skip the outer few percent, where sensor and JPEG crops
    // can differ slightly. No 8-bit conversion of the original RAW is made.
    let pw = 256_u32;
    let ph = ((pw as f64 / raw_aspect).round() as u32).max(32);
    let reference = imageops::resize(preview, pw, ph, imageops::FilterType::Triangle);
    let mut ratios_r = Vec::new();
    let mut ratios_b = Vec::new();
    let mut raw_lumas = Vec::new();
    let mut jpeg_lumas = Vec::new();
    let mut src_chromas = Vec::new();
    let mut dst_chromas = Vec::new();
    for gy in (5..ph.saturating_sub(5)).step_by(2) {
        for gx in (5..pw.saturating_sub(5)).step_by(2) {
            let sx = ((gx as f64 + 0.5) * w as f64 / pw as f64).floor() as u32;
            let sy = ((gy as f64 + 0.5) * h as f64 / ph as f64).floor() as u32;
            let s = source.get_pixel(sx.min(w-1), sy.min(h-1));
            let d = reference.get_pixel(gx, gy);
            let src = [s[0] as f32 / 65535.0, s[1] as f32 / 65535.0, s[2] as f32 / 65535.0];
            let dst = [d[0] as f32 / 255.0, d[1] as f32 / 255.0, d[2] as f32 / 255.0];
            let (sl, dl) = (lum(src), lum(dst));
            // Ignore deep shadows (read noise), near-clipped highlights and
            // divergent crop edges. These cannot teach an accurate colour fit.
            if !(0.07..0.90).contains(&sl) || !(0.06..0.94).contains(&dl) { continue; }
            if src.iter().any(|c| *c < 0.02 || *c > 0.975) || dst.iter().any(|c| *c < 0.02 || *c > 0.975) { continue; }
            raw_lumas.push(sl);
            jpeg_lumas.push(dl);
            src_chromas.push(chroma(src));
            dst_chromas.push(chroma(dst));
            if src[1] > 0.06 && dst[1] > 0.06 && src[0] > 0.04 && src[2] > 0.04 {
                let rg = (dst[0] / dst[1]) / (src[0] / src[1]);
                let bg = (dst[2] / dst[1]) / (src[2] / src[1]);
                if rg.is_finite() && bg.is_finite() && (0.25..4.0).contains(&rg) && (0.25..4.0).contains(&bg) {
                    ratios_r.push(rg.ln());
                    ratios_b.push(bg.ln());
                }
            }
        }
    }
    if raw_lumas.len() < 256 || ratios_r.len() < 128 { return None; }
    // A black-and-white in-camera picture style must not make the RAW mono.
    let jpeg_chroma = median(&mut dst_chromas);
    if jpeg_chroma < 0.025 { return None; }
    let raw_chroma = median(&mut src_chromas);
    let rgb_gain = [median(&mut ratios_r).exp().clamp(0.60, 1.75), 1.0,
                    median(&mut ratios_b).exp().clamp(0.60, 1.75)];
    let saturation = (jpeg_chroma / raw_chroma.max(0.03)).clamp(0.75, 1.7);

    raw_lumas.sort_unstable_by(f32::total_cmp);
    jpeg_lumas.sort_unstable_by(f32::total_cmp);
    let ps = [0.0_f32, 0.05, 0.20, 0.50, 0.80, 0.95, 1.0];
    let mut knots = [(0.0_f32, 0.0_f32); 7];
    knots[0] = (0.0, 0.0);
    knots[6] = (1.0, 1.0);
    for i in 1..6 {
        knots[i] = (percentile(&raw_lumas, ps[i]), percentile(&jpeg_lumas, ps[i]));
    }
    // Don't stretch near-uniform clouds or compress all tones into a narrow
    // band. Keep a strictly increasing source axis for safe interpolation.
    if knots[5].0 - knots[1].0 < 0.10 || knots[5].1 - knots[1].1 < 0.08 { return None; }
    for i in 1..7 {
        if knots[i].0 <= knots[i-1].0 || knots[i].1 < knots[i-1].1 { return None; }
    }
    Some(CameraLook { rgb_gain, saturation, knots })
}

impl CameraLook {
    fn tonemap(&self, y: f32) -> f32 {
        let v = y.clamp(0.0, 1.0);
        for i in 1..self.knots.len() {
            let (a, b) = (self.knots[i-1], self.knots[i]);
            if v <= b.0 {
                let t = ((v - a.0) / (b.0 - a.0).max(0.00001)).clamp(0.0, 1.0);
                return a.1 + (b.1 - a.1) * t;
            }
        }
        1.0
    }

    /// Apply at full native 16-bit precision. There is no JPEG/image::Rgb8
    /// writeback and no intermediate u8 image in the denoising/export path.
    pub fn apply(&self, image: &mut Rgb16Image) {
        for pixel in image.pixels_mut() {
            let src = [pixel[0] as f32 / 65535.0,
                       pixel[1] as f32 / 65535.0,
                       pixel[2] as f32 / 65535.0];
            let mut p = [src[0] * self.rgb_gain[0], src[1], src[2] * self.rgb_gain[2]];
            let gray = lum(p);
            for c in 0..3 {
                p[c] = (gray + (p[c] - gray) * self.saturation).max(0.0);
            }
            let y = lum(p);
            let desired = self.tonemap(y);
            let gain = if y > 0.0001 { (desired / y).clamp(0.15, 5.0) } else { 1.0 };
            for c in 0..3 {
                pixel.0[c] = (p[c] * gain * 65535.0).round().clamp(0.0, 65535.0) as u16;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn blank_or_mismatched_preview_does_not_recolor_raw() {
        let src = Rgb16Image::from_pixel(64, 64, Rgb([30000, 26000, 24000]));
        assert!(fit_from_camera_jpeg(&src, &RgbImage::new(1,1)).is_none());
        assert!(fit_from_camera_jpeg(&src, &RgbImage::new(128,32)).is_none());
    }
    #[test]
    fn monochrome_camera_style_cannot_desaturate_raw() {
        let src = Rgb16Image::from_fn(256, 128, |x, y| Rgb([
            14000 + (x * 120) as u16, 14000 + (y * 100) as u16, 10000 + (x * 50) as u16]));
        let preview = RgbImage::from_pixel(256, 128, Rgb([120, 120, 120]));
        assert!(fit_from_camera_jpeg(&src, &preview).is_none());
    }
    #[test]
    fn color_look_preserves_16bit_output_and_monotonic_tone() {
        let mut original = Rgb16Image::from_fn(256, 128, |x, y| {
            let base = 9000 + (x * 110 + y * 65) as u16;
            Rgb([base + 2200, base, base - 2500])
        });
        let jpeg = RgbImage::from_fn(256, 128, |x, y| {
            let v = (40 + x / 2 + y / 4).min(230) as u8;
            Rgb([v.saturating_add(20), v, v.saturating_sub(10)])
        });
        let look = fit_from_camera_jpeg(&original, &jpeg).expect("valid synthetic fit");
        let before = original.get_pixel(130, 60).0;
        look.apply(&mut original);
        let after = original.get_pixel(130, 60).0;
        assert_ne!(before, after);
        assert!(after[0] > after[1] && after[1] > after[2]);
        assert!(after.iter().all(|v| *v > 255));
    }
}
