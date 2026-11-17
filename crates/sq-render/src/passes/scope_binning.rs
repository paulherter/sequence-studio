//! The binning half of the scopes (Swift `ScopeBinning`/`ScopeCounts`): the CPU twin of `Scopes.slang` from the output
//! signal on. `color::scopes_reference` feeds it working-linear pixels (through the Rec.709 output encode); the Windows
//! picture path feeds it the decoded Rec.709 signal, which already is the output signal.
//!
//! Mappings (the UI draws graticules and targets with these):
//! - Waveform luma: `luma[row * W + col]`, row 0 = top = Y' 1.0; `level = min(floor(Y' * L), L-1)`, `row = L-1-level`.
//! - Parade: `parade[row * 3W + panel * W + col]`, panel 0/1/2 = R'/G'/B', same level mapping per channel.
//! - Vectorscope (BT.709, full range): `Cb = (B'-Y')/1.8556`, `Cr = (R'-Y')/1.5748`; `col = clamp(floor(Cb*N + N/2 + 0.5))`,
//!   `row = clamp(floor(N/2 - Cr*N + 0.5))` (Cr up, row 0 = top). Gray lands in bin (N/2, N/2).
//! - Histogram: `histogram[channel * 256 + bin]`, channel 0 R', 1 G', 2 B', 3 Y'; `bin = min(floor(v * 256), 255)`.

/// Sizes of the scope accumulation buffers (all scopes read the Rec.709 output signal).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScopeLayout {
    /// Waveform columns (source x maps proportionally: `col = x * waveform_width / source_width`).
    pub waveform_width: usize,
    /// Waveform vertical bins (signal 0...1).
    pub waveform_levels: usize,
    /// The vectorscope is `vectorscope_size` x `vectorscope_size` bins.
    pub vectorscope_size: usize,
}

impl Default for ScopeLayout {
    fn default() -> Self {
        Self { waveform_width: 512, waveform_levels: 256, vectorscope_size: 256 }
    }
}

impl ScopeLayout {
    pub const HISTOGRAM_BINS: usize = 256;

    // Element offsets inside the single counts buffer (u32 elements).
    pub fn waveform_luma_count(&self) -> usize {
        self.waveform_width * self.waveform_levels
    }
    pub fn parade_count(&self) -> usize {
        3 * self.waveform_width * self.waveform_levels
    }
    pub fn vector_count(&self) -> usize {
        self.vectorscope_size * self.vectorscope_size
    }
    pub fn histogram_count(&self) -> usize {
        4 * Self::HISTOGRAM_BINS
    }
    pub fn offset_waveform_luma(&self) -> usize {
        0
    }
    pub fn offset_parade(&self) -> usize {
        self.waveform_luma_count()
    }
    pub fn offset_vector(&self) -> usize {
        self.offset_parade() + self.parade_count()
    }
    pub fn offset_histogram(&self) -> usize {
        self.offset_vector() + self.vector_count()
    }
    pub fn offset_maxima(&self) -> usize {
        self.offset_histogram() + self.histogram_count()
    }
    pub fn total_count(&self) -> usize {
        self.offset_maxima() + 4
    }
}

/// Raw scope counts: what the GPU accumulates and the CPU reference output.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScopeCounts {
    pub layout: ScopeLayout,
    pub waveform_luma: Vec<u32>,
    pub waveform_parade: Vec<u32>,
    pub vectorscope: Vec<u32>,
    pub histogram: Vec<u32>,
    pub max_waveform_luma: u32,
    pub max_waveform_parade: u32,
    pub max_vectorscope: u32,
    pub max_histogram: u32,
}

impl ScopeCounts {
    pub fn new(layout: ScopeLayout) -> Self {
        Self {
            layout,
            waveform_luma: vec![0; layout.waveform_luma_count()],
            waveform_parade: vec![0; layout.parade_count()],
            vectorscope: vec![0; layout.vector_count()],
            histogram: vec![0; layout.histogram_count()],
            max_waveform_luma: 0,
            max_waveform_parade: 0,
            max_vectorscope: 0,
            max_histogram: 0,
        }
    }

    /// Splits the GPU's counts buffer (`layout.total_count()` words, the layout of `Scopes.slang`) into the scopes.
    pub fn from_words(layout: ScopeLayout, words: &[u32]) -> Option<Self> {
        if words.len() < layout.total_count() {
            return None;
        }
        let part = |from: usize, count: usize| words[from..from + count].to_vec();
        let m = layout.offset_maxima();
        Some(Self {
            layout,
            waveform_luma: part(layout.offset_waveform_luma(), layout.waveform_luma_count()),
            waveform_parade: part(layout.offset_parade(), layout.parade_count()),
            vectorscope: part(layout.offset_vector(), layout.vector_count()),
            histogram: part(layout.offset_histogram(), layout.histogram_count()),
            max_waveform_luma: words[m],
            max_waveform_parade: words[m + 1],
            max_vectorscope: words[m + 2],
            max_histogram: words[m + 3],
        })
    }

    /// Adds one output-signal pixel (R'G'B' 0...1, its Y') at source column `x` of `width`.
    pub fn add(&mut self, rgb: [f32; 3], luma: f32, x: usize, width: usize) {
        let l = self.layout;
        let (w, levels, n) = (l.waveform_width, l.waveform_levels, l.vectorscope_size);
        let col = (x * w / width).min(w - 1);
        self.waveform_luma[(levels - 1 - level(luma, levels)) * w + col] += 1;
        for (ch, v) in rgb.iter().enumerate() {
            let row = levels - 1 - level(*v, levels);
            self.waveform_parade[row * 3 * w + ch * w + col] += 1;
        }
        let [cb, cr] = cbcr(rgb);
        let (c, r) = vectorscope_bin(cb, cr, n);
        self.vectorscope[r * n + c] += 1;
        let bins = ScopeLayout::HISTOGRAM_BINS;
        for (ch, v) in rgb.iter().enumerate() {
            self.histogram[ch * bins + level(*v, bins)] += 1;
        }
        self.histogram[3 * bins + level(luma, bins)] += 1;
    }

    /// Fills the four maxima after the last `add`.
    pub fn finish(&mut self) {
        let max = |v: &[u32]| v.iter().copied().max().unwrap_or(0);
        self.max_waveform_luma = max(&self.waveform_luma);
        self.max_waveform_parade = max(&self.waveform_parade);
        self.max_vectorscope = max(&self.vectorscope);
        self.max_histogram = max(&self.histogram);
    }
}

/// BT.709 full-range [Cb, Cr] (+-0.5) of an R'G'B' signal.
pub fn cbcr(rgb: [f32; 3]) -> [f32; 2] {
    let y = rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
    [(rgb[2] - y) / 1.8556, (rgb[0] - y) / 1.5748]
}

/// Histogram or waveform level of `v` (0...1) among `levels`.
pub fn level(v: f32, levels: usize) -> usize {
    ((v * levels as f32) as usize).min(levels - 1)
}

/// (col, row) in the vectorscope of size `n`.
pub fn vectorscope_bin(cb: f32, cr: f32, n: usize) -> (usize, usize) {
    let nf = n as f32;
    let c = (cb * nf + nf / 2.0 + 0.5).floor().clamp(0.0, nf - 1.0);
    let r = (nf / 2.0 - cr * nf + 0.5).floor().clamp(0.0, nf - 1.0);
    (c as usize, r as usize)
}

fn luma_of(rgb: [f32; 3]) -> f32 {
    rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
}

/// Scopes of an 8-bit NV12 picture (luma plane, then interleaved CbCr, stride = width): the decoded Rec.709 signal,
/// converted to R'G'B' with the BT.709 matrix like the D3D12 picture shader. `pixel_stride` N samples every N-th pixel.
pub fn compute_nv12(
    bytes: &[u8],
    width: usize,
    height: usize,
    full_range: bool,
    layout: ScopeLayout,
    pixel_stride: usize,
) -> ScopeCounts {
    let mut out = ScopeCounts::new(layout);
    if width <= 1 || height <= 1 || bytes.len() < width * height * 3 / 2 {
        return out;
    }
    let step = pixel_stride.max(1);
    let chroma = width * height;
    for y in (0..height).step_by(step) {
        for x in (0..width).step_by(step) {
            let mut yy = f32::from(bytes[y * width + x]) / 255.0;
            let ci = chroma + (y / 2) * width + (x / 2) * 2;
            let (mut cb, mut cr) = (f32::from(bytes[ci]) / 255.0, f32::from(bytes[ci + 1]) / 255.0);
            if full_range {
                cb -= 128.0 / 255.0;
                cr -= 128.0 / 255.0;
            } else {
                yy = (yy * 255.0 - 16.0) / 219.0;
                cb = (cb * 255.0 - 128.0) / 224.0;
                cr = (cr * 255.0 - 128.0) / 224.0;
            }
            let r = yy + 1.5748 * cr;
            let g = yy - 0.1873 * cb - 0.4681 * cr;
            let b = yy + 1.8556 * cb;
            let rgb = [r.clamp(0.0, 1.0), g.clamp(0.0, 1.0), b.clamp(0.0, 1.0)];
            out.add(rgb, luma_of(rgb), x, width);
        }
    }
    out.finish();
    out
}

/// Scopes of an 8-bit RGBA picture (R'G'B' as shown, row stride = width * 4): the composited frame the Windows
/// compositor hands over when it draws more than one layer.
pub fn compute_rgba(
    bytes: &[u8],
    width: usize,
    height: usize,
    layout: ScopeLayout,
    pixel_stride: usize,
) -> ScopeCounts {
    let mut out = ScopeCounts::new(layout);
    if width <= 1 || height <= 1 || bytes.len() < width * height * 4 {
        return out;
    }
    let step = pixel_stride.max(1);
    for y in (0..height).step_by(step) {
        for x in (0..width).step_by(step) {
            let o = (y * width + x) * 4;
            let rgb = [f32::from(bytes[o]) / 255.0, f32::from(bytes[o + 1]) / 255.0, f32::from(bytes[o + 2]) / 255.0];
            out.add(rgb, luma_of(rgb), x, width);
        }
    }
    out.finish();
    out
}
