// SPDX-License-Identifier: GPL-3.0-or-later
//! Rules for decoding a proxy instead of the original (Swift: ProxyPicture.swift, ProxySource.swift).

use sq_media::sample_index::SampleIndex;

use sq_media::video_decoding::DecodeScale;

/// When the monitor decodes a media's proxy instead of the original. Paused frames are always the original's exact
/// frame; export never sees proxies.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct ProxyUse {
    /// While a scrub gesture runs.
    pub scrubbing: bool,
    /// While playing (weak machines, or the `sq.proxy.playback` setting).
    pub playback: bool,
}

impl ProxyUse {
    /// No proxies.
    pub const OFF: ProxyUse = ProxyUse { scrubbing: false, playback: false };
    /// Engine default: proxies for scrubbing once the resolver has one.
    pub const DEFAULT: ProxyUse = ProxyUse { scrubbing: true, playback: false };
}

/// The one playback source rule. Playing at Full (explicit Full, or Auto that has not stepped down) reads originals;
/// below Full (explicit Half/Quarter, or Auto stepped down after sustained lateness) a ready proxy is read. Scrubbing keeps
/// its own switch. Paused and warming frames never ask (they are originals), export has no proxy lookup.
pub fn proxy_read_allowed(scrubbing: bool, playing: bool, u: ProxyUse, quality: DecodeScale) -> bool {
    (scrubbing && u.scrubbing) || (playing && u.playback && quality != DecodeScale::Full)
}

/// A proxy may stand in for the original only when it has the same frames: same count and same first and last
/// presentation time. Otherwise edit points would shift, so the original is used.
pub fn has_original_frame_times(proxy: &SampleIndex, original: &SampleIndex) -> bool {
    let (a, b) = (proxy.entries(), original.entries());
    !a.is_empty()
        && a.len() == b.len()
        && a.first().map(|e| e.pts) == b.first().map(|e| e.pts)
        && a.last().map(|e| e.pts) == b.last().map(|e| e.pts)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Time;
    use sq_media::sample_index::Entry;

    #[test]
    fn playback_source_rule() {
        let u = ProxyUse { scrubbing: true, playback: true };
        assert!(!proxy_read_allowed(false, true, u, DecodeScale::Full), "Full plays originals");
        assert!(proxy_read_allowed(false, true, u, DecodeScale::Half));
        assert!(proxy_read_allowed(false, true, u, DecodeScale::Quarter));
        assert!(!proxy_read_allowed(false, false, u, DecodeScale::Quarter), "paused: original");
        assert!(proxy_read_allowed(true, false, u, DecodeScale::Full), "scrubbing unchanged");
        assert!(!proxy_read_allowed(false, true, ProxyUse::OFF, DecodeScale::Half));
    }

    fn index(n: i64) -> SampleIndex {
        SampleIndex::new(
            (0..n)
                .map(|i| {
                    let t = Time::new(i, 30);
                    Entry { pts: t, dts: t, duration: Time::new(1, 30), is_sync: true, decode_ordinal: i }
                })
                .collect(),
        )
    }

    #[test]
    fn proxy_with_same_frame_times_stands_in() {
        assert!(has_original_frame_times(&index(10), &index(10)));
    }

    #[test]
    fn different_count_or_empty_keeps_the_original() {
        assert!(!has_original_frame_times(&index(9), &index(10)));
        assert!(!has_original_frame_times(&index(0), &index(0)));
    }

    #[test]
    fn proxy_use_defaults_match_swift() {
        let (default, off) = (ProxyUse::DEFAULT, ProxyUse::OFF);
        assert!(default.scrubbing && !default.playback);
        assert!(!off.scrubbing);
    }
}
