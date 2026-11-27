//! Picture pixels for an sRGB-tagged window surface. Rec.709 video code values are meant to be decoded the way macOS
//! decodes 1-1-1 video (CoreMedia 709, effective gamma 1.96; Swift `Presenter.displayColorSpace`), but the Rust window
//! surface is tagged sRGB (about 2.2; `sq_platform_mac::tag_surface_srgb`), which would show the same code values darker
//! and harder. Re-encoding the code values as `srgb_oetf(colorsync_709_decode(code ^ (gamma / 1.96)))` gives the
//! luminance the Swift app shows (measured table: docs/rust/COLOR-DISPLAY.md).

use crate::software::RgbaImage;
use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::{Gpu, GpuError};
use sq_gpu::layout::PixelFormat;
use sq_gpu::pipelines::ComputePipeline;
use std::sync::Arc;

/// The gamma macOS decodes Rec.709 video with (Swift `ViewGamma.layerGamma`).
pub const MAC_VIDEO_GAMMA: f32 = 1.96;

/// The transfer curve of `kCGColorSpaceCoreMedia709` as its ICC profile stores it (`curv` 502/256).
const CORE_MEDIA_709_TRC: f32 = 502.0 / 256.0;

/// How ColorSync decodes a CoreMedia709 code value to linear light: the pure-gamma TRC with its slope limit (linear
/// slope 1/16 near black). Fits ColorSync's own CoreMedia709 -> sRGB conversion within 0.001/255 on every gray.
fn core_media_709_decode(x: f32) -> f32 {
    x.powf(CORE_MEDIA_709_TRC).max(x / 16.0)
}

/// sRGB code value of the luminance a display of `gamma` makes of each 8-bit Rec.709 code value: the Swift chain, the
/// code value re-encoded as `code ^ (gamma / 1.96)` (Swift `ViewGamma`) and shown through a CoreMedia709-tagged layer.
pub fn video_to_srgb_lut(gamma: f32) -> [u8; 256] {
    let mut lut = [0u8; 256];
    for (i, out) in lut.iter_mut().enumerate() {
        let lin = core_media_709_decode((i as f32 / 255.0).powf(gamma / MAC_VIDEO_GAMMA));
        let s = if lin <= 0.003_130_8 { 12.92 * lin } else { 1.055 * lin.powf(1.0 / 2.4) - 0.055 };
        *out = (s * 255.0 + 0.5).clamp(0.0, 255.0) as u8;
    }
    lut
}

impl RgbaImage {
    /// The picture with its color channels mapped through `lut` (alpha untouched).
    // shortcut: a CPU table pass per uploaded picture (a few ms at 1080p); move into DrawQuads.slang once slangc is
    // available to rebuild the shipped shaders.
    pub fn mapped(&self, lut: &[u8; 256]) -> RgbaImage {
        let mut pixels = self.pixels.clone();
        for px in pixels.as_chunks_mut::<4>().0 {
            px[0] = lut[px[0] as usize];
            px[1] = lut[px[1] as usize];
            px[2] = lut[px[2] as usize];
        }
        RgbaImage { width: self.width, height: self.height, pixels }
    }
}

/// The same table on the GPU (`DisplayGamma.slang`): maps an 8-bit composite into a display texture the window samples
/// directly, bit-identical to [`RgbaImage::mapped`] with [`video_to_srgb_lut`], without a CPU round trip.
pub struct GpuDisplayGamma {
    gpu: Arc<Gpu>,
    pipeline: Arc<ComputePipeline>,
    table: GpuTexture,
    gamma: Option<f32>,
}

impl GpuDisplayGamma {
    pub fn new(gpu: Arc<Gpu>) -> Result<GpuDisplayGamma, GpuError> {
        let pipeline = gpu.compute_pipeline("DisplayGamma", "displayGamma", PixelFormat::Rgba8Unorm)?;
        let table = gpu.texture(256, 1, PixelFormat::R8Unorm);
        Ok(GpuDisplayGamma { gpu, pipeline, table, gamma: None })
    }

    /// Queues `source` (an `Rgba8Unorm` composite) mapped for a display of `gamma` into `target` (same size,
    /// `Rgba8Unorm`) and submits it without waiting.
    pub fn apply(&mut self, source: &GpuTexture, target: &GpuTexture, gamma: f32) -> Result<(), GpuError> {
        if self.gamma != Some(gamma) {
            self.gpu.upload_texture(&self.table, &video_to_srgb_lut(gamma), 256);
            self.gamma = Some(gamma);
        }
        let mut cmds = self.gpu.commands();
        {
            let mut pass = cmds.compute();
            pass.set_pipeline(&self.pipeline);
            pass.set_input(source, 0)?;
            pass.set_input(&self.table, 1)?;
            pass.set_output(target);
            pass.dispatch(target.width(), target.height())?;
        }
        self.gpu.submit(cmds);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every code value of every channel, through the GPU pass and through the CPU table: byte for byte the same.
    #[test]
    fn gpu_pass_equals_the_cpu_table() {
        let Ok(gpu) = Gpu::new() else {
            sq_os::errln!("skipped: no GPU adapter");
            return;
        };
        let (w, h) = (256usize, 3usize);
        let mut pixels = Vec::with_capacity(w * h * 4);
        for y in 0..h {
            for x in 0..w {
                let v = x as u8;
                let px = [v, v.wrapping_add(85 * y as u8), 255 - v, v.wrapping_mul(7)];
                pixels.extend_from_slice(&px[..]);
            }
        }
        let img = RgbaImage { width: w, height: h, pixels };
        for gamma in [MAC_VIDEO_GAMMA, 2.2, 1.0] {
            let source = gpu.texture(w as u32, h as u32, PixelFormat::Rgba8Unorm);
            gpu.upload_texture(&source, &img.pixels, w as u32 * 4);
            let target = gpu.texture(w as u32, h as u32, PixelFormat::Rgba8Unorm);
            let mut pass = GpuDisplayGamma::new(Arc::clone(&gpu)).expect("pipeline");
            pass.apply(&source, &target, gamma).expect("apply");
            let got = gpu.read_texture(&target).expect("read");
            assert_eq!(got, img.mapped(&video_to_srgb_lut(gamma)).pixels, "gamma {gamma}");
        }
    }

    fn near(a: u8, b: u8) -> bool {
        a.abs_diff(b) <= 3
    }

    /// ColorSync's own conversion of CoreMedia709 grays to sRGB (CGColorCreateCopyByMatchingToColorSpace, macOS 27,
    /// docs/rust/COLOR-DISPLAY.md): the table matches every measured value within rounding (0.5/255), the dark end
    /// included (a pure 1.96 power was 2.8/255 too dark there).
    #[test]
    fn mac_table_equals_colorsync_core_media_709() {
        let measured: [(usize, f32); 14] = [
            (5, 4.04),
            (10, 8.07),
            (13, 10.49),
            (17, 15.41),
            (64, 72.92),
            (107, 118.3),
            (126, 137.2),
            (128, 139.16),
            (148, 158.46),
            (168, 177.28),
            (192, 199.33),
            (215, 219.99),
            (217, 221.77),
            (235, 237.63),
        ];
        let lut = video_to_srgb_lut(MAC_VIDEO_GAMMA);
        for (code, want) in measured {
            assert!((lut[code] as f32 - want).abs() <= 0.5 + 1e-3, "code {code}: {} vs {want}", lut[code]);
        }
        assert_eq!((lut[0], lut[255]), (0, 255));
    }

    /// Swift shows code c as luminance c^1.96 on the sRGB-tagged window: values computed from the Presenter chain
    /// (forward BT.709 OETF of the linear picture, layer decode gamma 1.96, then sRGB encode for the display).
    #[test]
    fn gray_ramp_matches_the_swift_display_values() {
        let lut = video_to_srgb_lut(MAC_VIDEO_GAMMA);
        assert_eq!(lut[0], 0);
        assert_eq!(lut[255], 255);
        // c = 0.502: 0.502^1.96 = 0.2575 -> sRGB 0.5443
        assert!(near(lut[128], 139), "{}", lut[128]);
        // c = 0.251 (64): 0.251^1.96 = 0.0669 -> sRGB 0.2877
        assert!(near(lut[64], 73), "{}", lut[64]);
        // c = 0.753 (192): 0.753^1.96 = 0.5733 -> sRGB 0.7873
        assert!(near(lut[192], 201), "{}", lut[192]);
        assert!(lut.windows(2).all(|w| w[0] <= w[1]));
        assert!((64..200).all(|i| lut[i] >= i as u8), "midtones are lifted");
    }

    /// White text on a mid-gray picture: white stays white, the gray lifts, alpha is untouched.
    #[test]
    fn white_on_gray_keeps_white_and_lifts_gray() {
        let img = RgbaImage { width: 2, height: 1, pixels: vec![255, 255, 255, 255, 128, 128, 128, 200] };
        let out = img.mapped(&video_to_srgb_lut(MAC_VIDEO_GAMMA));
        assert_eq!(&out.pixels[0..4], &[255, 255, 255, 255]);
        assert!(near(out.pixels[4], 139) && out.pixels[4] == out.pixels[5] && out.pixels[5] == out.pixels[6]);
        assert_eq!(out.pixels[7], 200);
    }
}
