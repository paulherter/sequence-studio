use crate::shim::{DECODER_NOT_FOUND, ShimError};
use sq_media::media_error::MediaError;

/// `AVERROR(ENOENT)`, `AVERROR(EACCES)` and `AVERROR_INVALIDDATA` (not a media file): the file is not there, not readable
/// or not a container FFmpeg knows.
const UNREADABLE: [i32; 3] = [-2, -13, -1_094_995_529];

/// The neutral error for a failed shim call on `codec` ("" when none): a missing decoder, an unreadable file, or the
/// FFmpeg code. The text stays in `ShimError` (log it before converting).
pub fn media_error(e: &ShimError, codec: &str) -> MediaError {
    if e.code == DECODER_NOT_FOUND {
        MediaError::UnsupportedCodec(codec.to_string())
    } else if UNREADABLE.contains(&e.code) {
        MediaError::Unreadable
    } else {
        MediaError::DecodeFailed(e.code)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn codes_map_to_the_neutral_errors() {
        let e = |code| ShimError { code, message: String::new() };
        assert_eq!(media_error(&e(DECODER_NOT_FOUND), "xyz"), MediaError::UnsupportedCodec("xyz".into()));
        assert_eq!(media_error(&e(-2), ""), MediaError::Unreadable);
        assert_eq!(media_error(&e(-5), ""), MediaError::DecodeFailed(-5));
        assert_eq!(media_error(&e(-1_094_995_529), ""), MediaError::Unreadable);
    }
}
