// SPDX-License-Identifier: GPL-3.0-or-later
//! Premiere-style presets for the Sequence Settings and New Sequence sheets.
// Swift: SequenceFormatPresets.swift
//
// Already in `sq-core-model` (`sequence_settings.rs`): `SequenceFormat::{PROBE_FALLBACK, MAX_DIMENSION, is_valid,
// sanitized}` and `Project::set_format`.

use sq_core_model::{Clip, DeliveryPlatform, DeliveryTarget, SequenceFormat, Timeline, TrackKind};
use sq_core_time::{Id, Time};
use std::collections::BTreeSet;

/// Swift `DeliveryTarget(platform:)`: the loudness of the platform's group. Both groups (vertical, horizontal) are -14 LUFS
/// and -1 dBTP, the same values a missing key reads as.
pub fn delivery_target(platform: DeliveryPlatform) -> DeliveryTarget {
    DeliveryTarget { platform, target_lufs: -14.0, true_peak_db: -1.0 }
}

/// A frame size in the pop-up.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Size {
    /// Shown name.
    pub name: &'static str,
    /// Width in pixels.
    pub width: i64,
    /// Height in pixels.
    pub height: i64,
}

/// A frame rate in the pop-up.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct FrameRate {
    /// Shown label.
    pub label: &'static str,
    /// Duration of one frame.
    pub frame_duration: Time,
}

/// A New Sequence preset with the platform it is made for.
#[derive(Clone, Debug, PartialEq)]
pub struct Named {
    /// Shown name.
    pub name: String,
    /// Size, frame rate and sample rate.
    pub format: SequenceFormat,
    /// Platform and loudness the preset is made for; `None` = none.
    pub delivery_target: Option<DeliveryTarget>,
}

/// Premiere-style presets for the Sequence Settings and New Sequence sheets.
pub struct SequenceFormatPresets;

impl SequenceFormatPresets {
    /// Frame sizes.
    pub const SIZES: [Size; 7] = [
        Size { name: "1080 × 1920 (9:16)", width: 1080, height: 1920 },
        Size { name: "1920 × 1080 (16:9)", width: 1920, height: 1080 },
        Size { name: "3840 × 2160 (UHD 16:9)", width: 3840, height: 2160 },
        Size { name: "2160 × 3840 (UHD 9:16)", width: 2160, height: 3840 },
        Size { name: "1080 × 1350 (4:5)", width: 1080, height: 1350 },
        Size { name: "1080 × 1080 (1:1)", width: 1080, height: 1080 },
        Size { name: "1440 × 1080 (4:3)", width: 1440, height: 1080 },
    ];

    /// Frame rates.
    pub const FRAME_RATES: [FrameRate; 8] = [
        FrameRate { label: "23.976", frame_duration: Time::new(1001, 24000) },
        FrameRate { label: "24", frame_duration: Time::new(1, 24) },
        FrameRate { label: "25", frame_duration: Time::new(1, 25) },
        FrameRate { label: "29.97", frame_duration: Time::new(1001, 30000) },
        FrameRate { label: "30", frame_duration: Time::new(1, 30) },
        FrameRate { label: "50", frame_duration: Time::new(1, 50) },
        FrameRate { label: "59.94", frame_duration: Time::new(1001, 60000) },
        FrameRate { label: "60", frame_duration: Time::new(1, 60) },
    ];

    /// Audio sample rates.
    pub const SAMPLE_RATES: [i64; 3] = [44_100, 48_000, 96_000];

    /// Largest frame width or height.
    pub const MAX_DIMENSION: i64 = SequenceFormat::MAX_DIMENSION;

    /// The listed size with these dimensions.
    pub fn size(width: i64, height: i64) -> Option<Size> {
        Self::SIZES.into_iter().find(|s| s.width == width && s.height == height)
    }

    /// The listed frame rate with this frame duration.
    pub fn frame_rate(d: Time) -> Option<FrameRate> {
        Self::FRAME_RATES.into_iter().find(|f| f.frame_duration == d)
    }

    /// New Sequence presets, social first: TikTok, Instagram Reels and YouTube Shorts (1080x1920), 4:5, 1:1, then
    /// YouTube 1080p / 4K at 24, 25, 30, 50, 60 fps and 4:3 (1440x1080). Each carries its delivery target.
    pub fn named() -> Vec<Named> {
        let mut out: Vec<Named> = Vec::new();
        let mut add = |name: String, w: i64, h: i64, fps: i64, p: DeliveryPlatform| {
            let mut format = SequenceFormat::new(Time::new(1, fps));
            format.width = w;
            format.height = h;
            out.push(Named { name, format, delivery_target: Some(delivery_target(p)) });
        };
        for fps in [30, 60] {
            add(format!("TikTok 1080×1920 {fps}"), 1080, 1920, fps, DeliveryPlatform::Tiktok);
            add(format!("Instagram Reels 1080×1920 {fps}"), 1080, 1920, fps, DeliveryPlatform::Reels);
            add(format!("YouTube Shorts 1080×1920 {fps}"), 1080, 1920, fps, DeliveryPlatform::Shorts);
        }
        add("Instagram 4:5 1080×1350 30".to_string(), 1080, 1350, 30, DeliveryPlatform::SocialFeed);
        add("Square 1:1 1080×1080 30".to_string(), 1080, 1080, 30, DeliveryPlatform::SocialFeed);
        for (label, w, h) in [("YouTube 1080p", 1920, 1080), ("YouTube 4K", 3840, 2160)] {
            for fps in [24, 25, 30, 50, 60] {
                add(format!("{label} {fps}"), w, h, fps, DeliveryPlatform::Youtube);
            }
        }
        add("Classic 4:3 1440×1080 30".to_string(), 1440, 1080, 30, DeliveryPlatform::Youtube);
        out
    }

    /// The named preset with this size, pixel shape and frame rate.
    pub fn preset_matching(f: &SequenceFormat) -> Option<Named> {
        Self::named().into_iter().find(|n| {
            n.format.width == f.width
                && n.format.height == f.height
                && n.format.pixel_aspect() == f.pixel_aspect()
                && n.format.frame_duration == f.frame_duration
        })
    }
}

/// `extension Timeline` of SequenceFormatPresets.swift.
pub trait TimelinePrimaryClipExt {
    /// The clip Effect Controls shows for a selection: the single selected clip, or for a linked A/V pair its video clip.
    /// Any other multi-selection has none.
    fn primary_clip(&self, ids: &BTreeSet<Id>) -> Option<&Clip>;
}

impl TimelinePrimaryClipExt for Timeline {
    fn primary_clip(&self, ids: &BTreeSet<Id>) -> Option<&Clip> {
        let picked: Vec<&Clip> = self.tracks.iter().flat_map(|t| t.clips()).filter(|c| ids.contains(&c.id)).collect();
        let first = *picked.first()?;
        if picked.len() != ids.len() {
            return None;
        }
        if picked.len() == 1 {
            return Some(first);
        }
        let link = first.link?;
        if !picked.iter().all(|c| c.link == Some(link)) {
            return None;
        }
        Some(picked.iter().copied().find(|c| c.kind != TrackKind::Audio).unwrap_or(first))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{PixelAspect, Track};
    use sq_core_time::TimeRange;

    fn clip(n: u128, kind: TrackKind, link: Option<Id>) -> Clip {
        let mut c = Clip::new(
            Id::from_u128(n),
            "c",
            Id::from_u128(99),
            kind,
            TimeRange::new(Time::seconds(0), Time::seconds(1)),
            Time::seconds(i64::try_from(n).unwrap_or(0) * 2),
        );
        c.link = link;
        c
    }

    fn track(kind: TrackKind, clips: &[Clip]) -> Track {
        let mut json = serde_json::to_value(Track::new(Id::from_u128(500), kind)).unwrap();
        json["clips"] = serde_json::to_value(clips).unwrap();
        serde_json::from_value(json).unwrap()
    }

    #[test]
    fn lists_match_the_swift_tables() {
        assert_eq!(SequenceFormatPresets::SIZES.len(), 7);
        assert_eq!(SequenceFormatPresets::size(1920, 1080).map(|s| s.name), Some("1920 × 1080 (16:9)"));
        assert_eq!(SequenceFormatPresets::size(1, 1), None);
        assert_eq!(SequenceFormatPresets::frame_rate(Time::new(1001, 24000)).map(|f| f.label), Some("23.976"));
        assert_eq!(SequenceFormatPresets::frame_rate(Time::new(1, 31)), None);
    }

    #[test]
    fn named_presets_are_social_first_with_targets() {
        let n = SequenceFormatPresets::named();
        assert_eq!(n.len(), 19);
        assert_eq!(n[0].name, "TikTok 1080×1920 30");
        assert_eq!(n[3].name, "TikTok 1080×1920 60");
        assert_eq!(n[6].name, "Instagram 4:5 1080×1350 30");
        assert_eq!(n[8].name, "YouTube 1080p 24");
        assert_eq!(n[18].name, "Classic 4:3 1440×1080 30");
        assert!(n.iter().all(|p| p.delivery_target.is_some()));
        assert_eq!(n[0].format.frame_duration, Time::new(1, 30));
    }

    #[test]
    fn named_preset_match_takes_the_shape_into_account() {
        let mut classic = SequenceFormat::new(Time::new(1, 30));
        classic.width = 1440;
        classic.height = 1080;
        let hit = SequenceFormatPresets::preset_matching(&classic);
        assert!(hit.is_some_and(|n| n.name.starts_with("Classic 4:3")));
        if let Some(wide) = PixelAspect::new(4, 3) {
            classic.set_pixel_aspect(wide);
        }
        assert_eq!(SequenceFormatPresets::preset_matching(&classic), None);
    }

    #[test]
    fn primary_clip_is_the_single_or_the_video_of_a_pair() {
        let link = Some(Id::from_u128(7));
        let (v, a, other) =
            (clip(1, TrackKind::Video, link), clip(2, TrackKind::Audio, link), clip(3, TrackKind::Video, None));
        let t = Timeline::new(
            Id::from_u128(50),
            "T",
            SequenceFormat::new(Time::new(1, 30)),
            vec![
                track(TrackKind::Video, &[v.clone(), other.clone()]),
                track(TrackKind::Audio, std::slice::from_ref(&a)),
            ],
        );
        let ids = |l: &[u128]| l.iter().map(|n| Id::from_u128(*n)).collect::<BTreeSet<Id>>();
        assert_eq!(t.primary_clip(&ids(&[2])).map(|c| c.id), Some(a.id));
        assert_eq!(t.primary_clip(&ids(&[1, 2])).map(|c| c.id), Some(v.id));
        assert_eq!(t.primary_clip(&ids(&[1, 3])).map(|c| c.id), None);
        assert_eq!(t.primary_clip(&ids(&[1, 99])).map(|c| c.id), None);
        assert_eq!(t.primary_clip(&ids(&[])).map(|c| c.id), None);
    }
}

/// Validation of the New Project sheet's inputs (kept out of the sheet so it is testable).
pub struct NewProjectInput;

impl NewProjectInput {
    /// Name used when nothing usable was typed.
    pub const DEFAULT_NAME: &'static str = "Untitled Project";

    /// The format the choices describe: the template's, with the typed size, the chosen rate and sample rate. A size outside
    /// 1...`MAX_DIMENSION` (either side) keeps the template's size; an unknown rate index keeps its rate.
    pub fn resolve(
        base: &SequenceFormat,
        width: i64,
        height: i64,
        rate_index: usize,
        sample_rate: Option<i64>,
    ) -> SequenceFormat {
        let mut f = base.clone();
        let max = SequenceFormatPresets::MAX_DIMENSION;
        if (1..=max).contains(&width) && (1..=max).contains(&height) {
            f.width = width;
            f.height = height;
        }
        if let Some(rate) = SequenceFormatPresets::FRAME_RATES.get(rate_index) {
            f.frame_duration = rate.frame_duration;
        }
        if let Some(sr) = sample_rate.filter(|s| *s > 0) {
            f.audio_sample_rate = sr;
        }
        f
    }

    /// The typed name, trimmed; empty or whitespace-only falls back to the default.
    pub fn name(typed: &str) -> String {
        let t = sq_core_model::trim_spaces(typed, true);
        if t.is_empty() { Self::DEFAULT_NAME.to_string() } else { t.to_string() }
    }
}

#[cfg(test)]
mod new_project_input_tests {
    use super::*;

    fn base() -> SequenceFormat {
        SequenceFormat::new(Time::new(1, 30))
    }

    #[test]
    fn a_valid_size_rate_and_sample_rate_replace_the_templates() {
        let f = NewProjectInput::resolve(&base(), 1280, 720, 2, Some(96_000));
        assert_eq!((f.width, f.height, f.frame_duration, f.audio_sample_rate), (1280, 720, Time::new(1, 25), 96_000));
    }

    #[test]
    fn a_bad_size_rate_or_sample_rate_keeps_the_templates() {
        let b = base();
        let f = NewProjectInput::resolve(&b, 0, 720, 99, Some(0));
        assert_eq!(f, b);
        assert_eq!(NewProjectInput::resolve(&b, 16_385, 10, 0, None).width, b.width);
    }

    #[test]
    fn the_name_is_trimmed_and_falls_back_to_the_default() {
        assert_eq!(NewProjectInput::name("  My cut \n"), "My cut");
        assert_eq!(NewProjectInput::name(" \t "), "Untitled Project");
        assert_eq!(SequenceFormatPresets::size(1080, 1920).map(|s| s.name), Some("1080 \u{d7} 1920 (9:16)"));
    }
}
