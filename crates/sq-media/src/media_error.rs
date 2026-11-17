//! Port of `SQMedia/Sources/SQMedia/MediaError.swift`.

use std::fmt;

/// Why a media file could not be opened or decoded.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MediaError {
    Unreadable,
    UnsupportedCodec(String),
    /// Status code of the decoder: `OSStatus` on Darwin, FFmpeg's negative `AVERROR` value elsewhere.
    DecodeFailed(i32),
    Truncated,
}

impl fmt::Display for MediaError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MediaError::Unreadable => f.write_str("unreadable"),
            MediaError::UnsupportedCodec(name) => write!(f, "unsupported codec {name}"),
            MediaError::DecodeFailed(status) => write!(f, "decode failed ({status})"),
            MediaError::Truncated => f.write_str("truncated"),
        }
    }
}

impl std::error::Error for MediaError {}
