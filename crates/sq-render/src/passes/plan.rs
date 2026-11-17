//! Planning shared by the GPU passes and the CPU references (Swift `GPUFilterPlan`).

/// Pixels whose centers lie inside a frame (inclusive bounds, texture px), clipped to the image.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PixelRect {
    pub min_x: i32,
    pub min_y: i32,
    pub max_x: i32,
    pub max_y: i32,
}

impl PixelRect {
    /// The rect of the frame at `origin` of `size` (texture px) inside a `width` x `height` image.
    pub fn new(origin: [f32; 2], size: [f32; 2], width: u32, height: u32) -> Self {
        let edge = |o: f32| (o - 0.5).ceil() as i32;
        Self {
            min_x: edge(origin[0]).max(0),
            min_y: edge(origin[1]).max(0),
            max_x: (width as i32 - 1).min(edge(origin[0] + size[0]) - 1),
            max_y: (height as i32 - 1).min(edge(origin[1] + size[1]) - 1),
        }
    }
}

/// Smear taps up to this count run in one pass.
pub const ONE_PASS_TAPS: usize = 32;

/// Largest Gaussian kernel the blur pass takes (2 * radius + 1 weights; `Blur.slang` `BlurW`).
pub const MAX_BLUR_WEIGHTS: usize = 128;

fn ceil_sqrt(n: usize) -> usize {
    (n as f64).sqrt().ceil() as usize
}

/// Taps along the smear: about one per px, at least 2, at most 512. Above [`ONE_PASS_TAPS`] rounded up to a product a x b
/// (a = ceil(sqrt n)), so the GPU runs it as two comb passes with exactly the same taps ([`smear_passes`]).
pub fn smear_taps(d: [f32; 2]) -> usize {
    let n = ((d[0] * d[0] + d[1] * d[1]).sqrt().ceil() as usize + 1).clamp(2, 512);
    if n <= ONE_PASS_TAPS {
        return n;
    }
    let a = ceil_sqrt(n);
    a * n.div_ceil(a)
}

/// Two comb passes for `n` taps (fine: a taps one spacing apart; coarse: b taps a spacings apart), or `None` for one pass.
pub fn smear_passes(n: usize) -> Option<(usize, usize)> {
    if n <= ONE_PASS_TAPS {
        return None;
    }
    let a = ceil_sqrt(n);
    n.is_multiple_of(a).then_some((a, n / a))
}
