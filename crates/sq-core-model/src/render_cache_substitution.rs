// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: RenderCacheSubstitution.swift (the span type and `RenderCacheMedia`; `withRenderCache` needs the segment types of sq-core-project)

use sq_core_time::{Id, TimeRange};

/// A stretch of the sequence that playback reads from a rendered cache file instead of compositing. The file holds the
/// segment at sequence size, starting at file time 0. Playback-only: never saved.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct RenderCacheSpan {
    /// The stretch of the sequence.
    pub range: TimeRange,
    /// Media id the file is registered under in the media resolver.
    pub media: Id,
}

/// `enum RenderCacheMedia`.
pub struct RenderCacheMedia;

impl RenderCacheMedia {
    /// The media id of a segment file: the 128 key bits as an id, so the same content always has the same id (the decoded
    /// frames in the frame cache stay valid across edits that keep the key).
    pub fn id_for_key(key: &str) -> Id {
        let digit = |c: u8| if c >= b'a' { c.wrapping_sub(87) } else { c.wrapping_sub(48) };
        let chars = key.as_bytes();
        let mut bytes = [0u8; 16];
        for (i, b) in bytes.iter_mut().enumerate() {
            if i * 2 + 1 < chars.len() {
                *b = digit(chars[i * 2]) << 4 | digit(chars[i * 2 + 1]);
            }
        }
        Id::from_u128(u128::from_be_bytes(bytes))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_key_bits_are_the_id() {
        assert_eq!(RenderCacheMedia::id_for_key("00000000000000000000000000000001"), Id::from_u128(1));
        assert_eq!(RenderCacheMedia::id_for_key("ff000000000000000000000000000000"), Id::from_u128(0xff << 120));
        assert_eq!(
            RenderCacheMedia::id_for_key("abcdef0123456789abcdef0123456789"),
            Id::from_u128(0xabcd_ef01_2345_6789_abcd_ef01_2345_6789)
        );
    }
}
