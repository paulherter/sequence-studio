// SPDX-License-Identifier: GPL-3.0-or-later
//! Scratch textures and constant-block bytes shared by the effect passes.

pub use crate::passes::Scratch;

/// A constant block under construction: little-endian 4-byte fields in HLSL packing order.
#[derive(Default, Clone, Debug)]
pub struct Block(Vec<u8>);

impl Block {
    /// An empty block.
    pub fn new() -> Self {
        Self::default()
    }

    /// Appends floats.
    pub fn f32s(mut self, v: &[f32]) -> Self {
        v.iter().for_each(|x| self.0.extend_from_slice(&x.to_le_bytes()));
        self
    }

    /// Appends unsigned integers.
    pub fn u32s(mut self, v: &[u32]) -> Self {
        v.iter().for_each(|x| self.0.extend_from_slice(&x.to_le_bytes()));
        self
    }

    /// Appends signed integers.
    pub fn i32s(mut self, v: &[i32]) -> Self {
        v.iter().for_each(|x| self.0.extend_from_slice(&x.to_le_bytes()));
        self
    }

    /// Zero-pads to a multiple of 16 bytes (the size of a constant buffer).
    pub fn padded(mut self) -> Self {
        while !self.0.len().is_multiple_of(16) {
            self.0.push(0);
        }
        self
    }

    /// The bytes.
    pub fn bytes(&self) -> &[u8] {
        &self.0
    }
}

/// IEEE half bits of `f`, rounded to nearest even (what the working images hold).
pub fn half(f: f32) -> u16 {
    let bits = f.to_bits();
    let sign = ((bits >> 16) & 0x8000) as u16;
    let exp = ((bits >> 23) & 0xff) as i32;
    let mant = bits & 0x7f_ffff;
    if exp == 0xff {
        return sign | 0x7c00 | if mant != 0 { 0x200 } else { 0 };
    }
    let e = exp - 127 + 15;
    if e >= 0x1f {
        return sign | 0x7c00;
    }
    if e <= 0 {
        if e < -10 {
            return sign;
        }
        let m = mant | 0x80_0000;
        let shift = (14 - e) as u32;
        let halfway = 1u32 << (shift - 1);
        let mut r = m >> shift;
        let rem = m & ((1 << shift) - 1);
        if rem > halfway || (rem == halfway && r & 1 == 1) {
            r += 1;
        }
        return sign | r as u16;
    }
    let mut r = ((e as u32) << 10) | (mant >> 13);
    let rem = mant & 0x1fff;
    if rem > 0x1000 || (rem == 0x1000 && r & 1 == 1) {
        r += 1;
    }
    sign | r as u16
}

/// The value of IEEE half bits `h`.
pub fn unhalf(h: u16) -> f32 {
    let sign = if h & 0x8000 != 0 { -1.0f32 } else { 1.0 };
    let exp = i32::from((h >> 10) & 0x1f);
    let mant = f32::from(h & 0x3ff);
    match exp {
        0 => sign * mant * 2f32.powi(-24),
        31 if mant == 0.0 => sign * f32::INFINITY,
        31 => f32::NAN,
        _ => sign * (1.0 + mant / 1024.0) * 2f32.powi(exp - 15),
    }
}
