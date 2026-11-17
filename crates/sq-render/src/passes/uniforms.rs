//! Constant blocks packed by byte offset, the way the Slang structs lay them out (4-byte words, 16-byte aligned sizes).

/// A constant block built by byte offset; the size is the struct's size in the shader.
#[derive(Clone, Debug, PartialEq)]
pub struct Block {
    words: Vec<u32>,
}

impl Block {
    pub fn new(bytes: usize) -> Self {
        Self { words: vec![0; bytes / 4] }
    }

    fn put(&mut self, at: usize, values: impl Iterator<Item = u32>) -> &mut Self {
        for (word, value) in self.words.iter_mut().skip(at / 4).zip(values) {
            *word = value;
        }
        self
    }

    /// Floats starting at byte `at`.
    pub fn f(&mut self, at: usize, values: &[f32]) -> &mut Self {
        self.put(at, values.iter().map(|v| v.to_bits()))
    }

    /// Unsigned words starting at byte `at`.
    pub fn u(&mut self, at: usize, values: &[u32]) -> &mut Self {
        self.put(at, values.iter().copied())
    }

    /// Signed words starting at byte `at`.
    pub fn i(&mut self, at: usize, values: &[i32]) -> &mut Self {
        self.put(at, values.iter().map(|v| *v as u32))
    }

    pub fn bytes(&self) -> Vec<u8> {
        self.words.iter().flat_map(|w| w.to_le_bytes()).collect()
    }
}

/// `FilterU` in `Filters.slang` (96 bytes).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct FilterU {
    pub a: [f32; 4],
    pub b: [f32; 4],
    pub center: [f32; 2],
    pub frame: [f32; 2],
    pub i: [i32; 4],
    /// Extra rows (the Stabilizer warp's perspective map); zero for every other kernel.
    pub c: [f32; 4],
    pub d: [f32; 4],
}

impl FilterU {
    pub const SIZE: usize = 96;

    pub fn with_frame(center: [f32; 2], frame: [f32; 2]) -> Self {
        Self { center, frame, ..Self::default() }
    }

    pub fn bytes(&self) -> Vec<u8> {
        let mut block = Block::new(Self::SIZE);
        block
            .f(0, &self.a)
            .f(16, &self.b)
            .f(32, &self.center)
            .f(40, &self.frame)
            .i(48, &self.i)
            .f(64, &self.c)
            .f(80, &self.d);
        block.bytes()
    }
}

/// `BlurU` in `Blur.slang` (32 bytes).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct BlurU {
    pub axis: [i32; 2],
    pub radius: i32,
    pub clamp_edges: i32,
    pub lo: [i32; 2],
    pub hi: [i32; 2],
}

impl BlurU {
    pub const SIZE: usize = 32;

    pub fn bytes(&self) -> Vec<u8> {
        let mut block = Block::new(Self::SIZE);
        block.i(0, &self.axis).i(8, &[self.radius, self.clamp_edges]).i(16, &self.lo).i(24, &self.hi);
        block.bytes()
    }
}

/// `FlowU` in `OpticalFlow.slang` (48 bytes): Lucas-Kanade step, interpolation and upscale parameters.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FlowU {
    pub radius: i32,
    pub lambda: f32,
    pub inv_two_sigma2: f32,
    pub max_step: f32,
    pub t: f32,
    pub linearize: u32,
    pub flow_scale: [f32; 2],
    pub sigma: f32,
    pub has_prev: u32,
}

impl Default for FlowU {
    fn default() -> Self {
        Self {
            radius: 0,
            lambda: 0.0,
            inv_two_sigma2: 0.0,
            max_step: 0.0,
            t: 0.0,
            linearize: 0,
            flow_scale: [1.0, 1.0],
            sigma: 0.0,
            has_prev: 0,
        }
    }
}

impl FlowU {
    pub const SIZE: usize = 48;

    pub fn bytes(&self) -> Vec<u8> {
        let mut block = Block::new(Self::SIZE);
        block
            .i(0, &[self.radius])
            .f(4, &[self.lambda, self.inv_two_sigma2, self.max_step, self.t])
            .u(20, &[self.linearize])
            .f(24, &self.flow_scale)
            .f(32, &[self.sigma])
            .u(36, &[self.has_prev]);
        block.bytes()
    }
}
