// Swift: SourceTimelineBuilder.swift
//! The one-clip timeline the Source monitor plays for a media item, and the displayed shape it was built for. The monitor
//! builds it again (without stopping) when the shape changes, for example after a pixel aspect change.

use sq_core_edit::timeline_source_edit::TimelineSourceEditExt;
use sq_core_model::{MediaRef, SequenceFormat, Timeline};
use sq_core_time::{IdSource, Time, TimeRange};

/// What `SourceTimelineBuilder::build` made.
#[derive(Clone, Debug, PartialEq)]
pub struct Built {
    /// The one-clip timeline.
    pub timeline: Timeline,
    /// The media's own format.
    pub format: SequenceFormat,
    /// The whole length.
    pub total: Time,
    /// The media is a still image.
    pub still: bool,
}

/// Builds the Source monitor's timeline.
pub enum SourceTimelineBuilder {}

impl SourceTimelineBuilder {
    /// Displayed size [width, height] of the item's picture; empty for media without one.
    pub fn shape(r: &MediaRef) -> Vec<i64> {
        match r.info.as_ref().and_then(|i| i.video.as_ref()) {
            Some(v) => vec![v.display_width(), v.display_height()],
            None => Vec::new(),
        }
    }

    /// `None` without a readable duration.
    pub fn build(r: &MediaRef, ids: &mut dyn IdSource) -> Option<Built> {
        let still = r.info.as_ref().is_some_and(|i| i.is_still);
        let total = if still { Some(Time::new(5, 1)) } else { r.info.as_ref().map(|i| i.duration).or(r.duration) }?;
        let video = r.info.as_ref().and_then(|i| i.video.as_ref());
        let fd = if still { Time::new(1, 30) } else { video.map_or(Time::new(1, 30), |v| v.nominal_frame_duration) };
        let format = SequenceFormat {
            width: video.map_or(1920, |v| v.display_width()),
            height: video.map_or(1080, |v| v.display_height()),
            frame_duration: fd,
            audio_sample_rate: r.info.as_ref().and_then(|i| i.audio.as_ref()).map_or(48_000, |a| a.sample_rate),
            pixel_aspect_store: None,
            unknown: sq_core_model::UnknownKeys::default(),
        }
        .sanitized(&SequenceFormat::new(Time::new(1, 30)));
        let tl = Timeline::source_timeline(
            r,
            format.clone(),
            video.is_some() || r.info.is_none(),
            r.info.as_ref().is_some_and(|i| i.audio.is_some()),
            total,
            still,
            ids,
        );
        Some(Built { timeline: tl, format, total, still })
    }

    /// The playhead after a rebuild: snapped to the (possibly new) frame rate and kept inside the new length.
    pub fn clamped_position(position: Time, total: Time, frame_duration: Time) -> Time {
        position.snapped(frame_duration).min(Time::ZERO.max(total - frame_duration))
    }

    /// The play In to Out range after a rebuild: cut at the new end; `None` when nothing of it is left.
    pub fn clamped_range(range: Option<TimeRange>, total: Time) -> Option<TimeRange> {
        let range = range?;
        let end = range.end().min(total);
        (range.start < end).then(|| TimeRange::from_end(range.start, end))
    }

    /// Whether a monitor showing `loaded` must be rebuilt for `r`: only media with a picture whose shape moved.
    pub fn needs_reshape(r: &MediaRef, loaded: &[i64]) -> bool {
        r.info.as_ref().is_some_and(|i| i.video.is_some()) && loaded != Self::shape(r).as_slice()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{MediaFingerprint, MediaInfo};
    use sq_core_time::{Id, SequentialIds};

    fn media(info: Option<MediaInfo>, duration: Option<Time>) -> MediaRef {
        let mut m = MediaRef::new(Id::from_u128(5), "clip", "/clip.mov", MediaFingerprint::new(1));
        m.info = info;
        m.duration = duration;
        m
    }

    #[test]
    fn no_duration_builds_nothing_and_unprobed_media_gets_a_default_hd_timeline() {
        let mut ids = SequentialIds::default();
        assert!(SourceTimelineBuilder::build(&media(None, None), &mut ids).is_none());
        let b = SourceTimelineBuilder::build(&media(None, Some(Time::seconds(10))), &mut ids);
        let b = b.unwrap_or_else(|| panic!("built"));
        assert_eq!((b.format.width, b.format.height), (1920, 1080));
        assert_eq!(b.total, Time::seconds(10));
        assert!(!b.still);
        assert!(SourceTimelineBuilder::shape(&media(None, None)).is_empty());
    }

    #[test]
    fn the_playhead_and_range_are_clamped_to_the_new_end() {
        let fd = Time::new(1, 25);
        let total = Time::seconds(2);
        assert_eq!(SourceTimelineBuilder::clamped_position(Time::seconds(5), total, fd), total - fd);
        let r = TimeRange::from_end(Time::seconds(1), Time::seconds(4));
        assert_eq!(
            SourceTimelineBuilder::clamped_range(Some(r), total),
            Some(TimeRange::from_end(Time::seconds(1), total))
        );
        let gone = TimeRange::from_end(Time::seconds(3), Time::seconds(4));
        assert_eq!(SourceTimelineBuilder::clamped_range(Some(gone), total), None);
        assert_eq!(SourceTimelineBuilder::clamped_range(None, total), None);
    }
}
