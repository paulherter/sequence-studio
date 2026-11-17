// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift `Data` in JSON: `JSONEncoder`'s default `.base64` (standard alphabet, padded; decoding is strict like
//! `Data(base64Encoded:)`). Use as `#[serde(with = "sq_core_time::base64")]`, `base64::option` for `Option<Vec<u8>>`.

use serde::{Deserialize, Deserializer, Serializer};
use std::borrow::Cow;

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Padded standard base64.
pub fn encode(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = u32::from(b[0]) << 16 | u32::from(b[1]) << 8 | u32::from(b[2]);
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(char::from(ALPHABET[(n >> (18 - 6 * i) & 63) as usize]));
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// Strict decode: length a multiple of 4, padding only at the end, no whitespace.
pub fn decode(s: &str) -> Option<Vec<u8>> {
    let s = s.as_bytes();
    if !s.len().is_multiple_of(4) {
        return None;
    }
    let mut out = Vec::with_capacity(s.len() / 4 * 3);
    for (ci, chunk) in s.chunks(4).enumerate() {
        let last = ci + 1 == s.len() / 4;
        let pad = chunk.iter().rev().take_while(|&&c| c == b'=').count();
        if pad > 2 || (pad > 0 && !last) {
            return None;
        }
        let mut n = 0u32;
        for &c in &chunk[..4 - pad] {
            n = n << 6 | ALPHABET.iter().position(|&a| a == c)? as u32;
        }
        n <<= 6 * pad as u32;
        out.extend_from_slice(&[(n >> 16) as u8, (n >> 8) as u8, n as u8][..3 - pad]);
    }
    Some(out)
}

/// Serde: bytes as a base64 string.
pub fn serialize<S: Serializer>(bytes: &[u8], s: S) -> Result<S::Ok, S::Error> {
    s.serialize_str(&encode(bytes))
}

/// Serde: a base64 string to bytes.
pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<u8>, D::Error> {
    let s = Cow::<'de, str>::deserialize(d)?;
    decode(&s).ok_or_else(|| serde::de::Error::custom("invalid base64 data"))
}

/// The same for optional data (pair with `skip_serializing_if = "Option::is_none"` and `default`).
pub mod option {
    use super::*;

    /// See `base64::serialize`.
    pub fn serialize<S: Serializer>(bytes: &Option<Vec<u8>>, s: S) -> Result<S::Ok, S::Error> {
        match bytes {
            Some(b) => s.serialize_str(&encode(b)),
            None => s.serialize_none(),
        }
    }

    /// See `base64::deserialize`.
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Vec<u8>>, D::Error> {
        let s = Option::<Cow<'de, str>>::deserialize(d)?;
        s.map(|s| decode(&s).ok_or_else(|| serde::de::Error::custom("invalid base64 data"))).transpose()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_and_rejects_loose_input() {
        for (raw, text) in
            [(&b""[..], ""), (b"f", "Zg=="), (b"fo", "Zm8="), (b"foo", "Zm9v"), (b"\xff\x00\x10", "/wAQ")]
        {
            assert_eq!(encode(raw), text);
            assert_eq!(decode(text).as_deref(), Some(raw));
        }
        assert_eq!(decode("Zg="), None);
        assert_eq!(decode("Zg==Zg=="), None);
        assert_eq!(decode("Zm 9"), None);
    }
}
