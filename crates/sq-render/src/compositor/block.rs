//! Byte layout of the Slang constant blocks: fields are written in declaration order with the alignment of the
//! Metal/Slang struct (vectors align to their size, `float3x3` is three padded columns), so a block is exactly the bytes
//! the shader reads. No `unsafe`, no layout attributes: the offsets are checked by tests.

/// Writes one constant block.
#[derive(Default)]
pub(crate) struct Block {
    bytes: Vec<u8>,
}

impl Block {
    pub(crate) fn new() -> Block {
        Block::default()
    }

    /// Pads with zeros to a multiple of `align`.
    pub(crate) fn align(&mut self, align: usize) -> &mut Block {
        while !self.bytes.len().is_multiple_of(align) {
            self.bytes.push(0);
        }
        self
    }

    pub(crate) fn f32(&mut self, v: f32) -> &mut Block {
        self.align(4).bytes.extend_from_slice(&v.to_le_bytes());
        self
    }

    pub(crate) fn u32(&mut self, v: u32) -> &mut Block {
        self.align(4).bytes.extend_from_slice(&v.to_le_bytes());
        self
    }

    pub(crate) fn vec2(&mut self, v: [f32; 2]) -> &mut Block {
        self.align(8);
        v.iter().for_each(|x| {
            self.f32(*x);
        });
        self
    }

    /// A `float3`: 12 bytes, 16-aligned.
    pub(crate) fn vec3(&mut self, v: [f32; 3]) -> &mut Block {
        self.align(16);
        v.iter().for_each(|x| {
            self.f32(*x);
        });
        self
    }

    pub(crate) fn vec4(&mut self, v: [f32; 4]) -> &mut Block {
        self.align(16);
        v.iter().for_each(|x| {
            self.f32(*x);
        });
        self
    }

    pub(crate) fn uvec4(&mut self, v: [u32; 4]) -> &mut Block {
        self.align(16);
        v.iter().for_each(|x| {
            self.u32(*x);
        });
        self
    }

    /// A column-major `float3x3`: three 16-byte columns.
    pub(crate) fn mat3(&mut self, columns: [[f32; 3]; 3]) -> &mut Block {
        self.align(16);
        for c in columns {
            self.vec3(c).align(16);
        }
        self
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.bytes.len()
    }

    /// The bytes, padded to the struct alignment `align`.
    pub(crate) fn finish(mut self, align: usize) -> Vec<u8> {
        self.align(align);
        self.bytes
    }
}
