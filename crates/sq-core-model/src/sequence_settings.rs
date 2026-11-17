// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SequenceSettings.swift, SequenceFormatPresets.swift (the validity part of `SequenceFormat`)

use crate::{
    ChannelLayout, DeliveryTarget, EditError, Project, SequenceFormat, SequencePreviewQuality, TimecodeDisplay,
    Timeline, TimelineEditMode,
};
use sq_core_time::{Id, Time};

impl SequenceFormat {
    /// Largest frame width or height a sequence accepts.
    pub const MAX_DIMENSION: i64 = 16_384;

    /// What a probe falls back to for a field it read as 0 or garbage.
    pub const PROBE_FALLBACK: SequenceFormat = SequenceFormat {
        width: 1920,
        height: 1080,
        frame_duration: Time::new(1, 30),
        audio_sample_rate: 48_000,
        pixel_aspect_store: None,
        unknown: crate::UnknownKeys::new(),
    };

    /// Size, frame duration and sample rate are all usable.
    pub fn is_valid(&self) -> bool {
        (1..=Self::MAX_DIMENSION).contains(&self.width)
            && (1..=Self::MAX_DIMENSION).contains(&self.height)
            && self.frame_duration > Time::ZERO
            && self.audio_sample_rate > 0
    }

    /// This format with every field a probe could have read as 0 or garbage (size, frame duration, sample rate) taken from
    /// `fallback`, so a value copied from media info can never make a project the decoder refuses to open.
    pub fn sanitized(&self, fallback: &SequenceFormat) -> SequenceFormat {
        let mut f = self.clone();
        if !(1..=Self::MAX_DIMENSION).contains(&f.width) {
            f.width = fallback.width;
        }
        if !(1..=Self::MAX_DIMENSION).contains(&f.height) {
            f.height = fallback.height;
        }
        if f.frame_duration <= Time::ZERO {
            f.frame_duration = fallback.frame_duration;
        }
        if f.audio_sample_rate <= 0 {
            f.audio_sample_rate = fallback.audio_sample_rate;
        }
        f
    }
}

/// Everything the Sequence Settings dialog edits on one sequence, as one value: the dialog reads `Timeline::settings`, the
/// session writes the result back with `Project::set_settings` in a single undo step.
#[derive(Clone, Debug, PartialEq)]
pub struct SequenceSettings {
    /// Sequence name.
    pub name: String,
    /// Size, frame rate, sample rate and pixel shape.
    pub format: SequenceFormat,
    /// Loudness and platform target.
    pub delivery_target: Option<DeliveryTarget>,
    /// Normal or Fast Cut.
    pub edit_mode: TimelineEditMode,
    /// Timecode of the first frame.
    pub timecode_start: Time,
    /// Timecode or frame numbers.
    pub timecode_display: TimecodeDisplay,
    /// `None` = follow the app setting.
    pub preview_quality: Option<SequencePreviewQuality>,
    /// Output channels.
    pub channel_layout: ChannelLayout,
}

impl Timeline {
    /// The settings the dialog edits.
    pub fn settings(&self) -> SequenceSettings {
        SequenceSettings {
            name: self.name.clone(),
            format: self.format.clone(),
            delivery_target: self.delivery_target.clone(),
            edit_mode: self.edit_mode_store.unwrap_or(TimelineEditMode::Normal),
            timecode_start: self.timecode_start(),
            timecode_display: self.timecode_display(),
            preview_quality: self.preview_quality(),
            channel_layout: self.channel_layout(),
        }
    }
}

impl Project {
    /// Applies Sequence Settings to one sequence. A blank name keeps the old one. Clips are not touched (they keep their
    /// scale and position); switching to Fast Cut derives the attachments like the timeline header does.
    pub fn set_settings(&mut self, s: &SequenceSettings, timeline: Id) -> Result<(), EditError> {
        if !s.format.is_valid() {
            return Err(EditError::InvalidFormat);
        }
        let t = self.timelines.iter_mut().find(|t| t.id == timeline).ok_or(EditError::TimelineNotFound)?;
        t.format = s.format.clone();
        t.format_locked = true;
        t.delivery_target = s.delivery_target.clone();
        let name = crate::project::trim_spaces(&s.name, true);
        if !name.is_empty() {
            t.name = name.to_string();
        }
        if t.edit_mode() != s.edit_mode {
            t.set_edit_mode(s.edit_mode);
        }
        t.set_timecode_start(s.timecode_start); // after the format: snaps to the new frame rate
        t.set_timecode_display(s.timecode_display);
        t.set_preview_quality(s.preview_quality);
        t.set_channel_layout(s.channel_layout);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nesting::test_util::*;

    #[test]
    fn settings_read_the_defaults_of_the_stored_keys() {
        let mut p = project_json(vec![], vec![timeline_json(1, vec![])]);
        let t = &mut p.timelines[0];
        let s = t.settings();
        assert_eq!(
            (s.name.as_str(), s.edit_mode, s.timecode_start, s.timecode_display, s.preview_quality, s.channel_layout),
            ("T1", TimelineEditMode::Normal, Time::ZERO, TimecodeDisplay::Timecode, None, ChannelLayout::Stereo)
        );
        t.set_channel_layout(ChannelLayout::Mono);
        t.set_timecode_start(Time::new(10, 1));
        t.edit_mode_store = Some(TimelineEditMode::Magnetic);
        let s = t.settings();
        assert_eq!(
            (s.channel_layout, s.timecode_start, s.edit_mode),
            (ChannelLayout::Mono, Time::new(10, 1), TimelineEditMode::Magnetic)
        );
    }

    fn project() -> (Project, Id) {
        let p = project_json(vec![], vec![timeline_json(1, vec![])]);
        (p, id(1))
    }

    #[test]
    fn settings_apply_format_name_and_mode() {
        let (mut p, tid) = project();
        let mut s = p.timelines[0].settings();
        s.name = "  Reel  ".to_string();
        s.format = SequenceFormat {
            width: 1080,
            height: 1920,
            frame_duration: Time::new(1, 25),
            audio_sample_rate: 44_100,
            pixel_aspect_store: None,
            unknown: crate::UnknownKeys::default(),
        };
        s.edit_mode = TimelineEditMode::Magnetic;
        assert_eq!(p.set_settings(&s, tid), Ok(()));
        let t = &p.timelines[0];
        assert_eq!((t.name.as_str(), t.format.width, t.format.audio_sample_rate), ("Reel", 1080, 44_100));
        assert!(t.edit_mode() == TimelineEditMode::Magnetic && t.format_locked);
    }

    #[test]
    fn a_blank_name_keeps_the_old_one_and_a_bad_format_or_sequence_is_refused() {
        let (mut p, tid) = project();
        let mut s = p.timelines[0].settings();
        s.name = "   ".to_string();
        assert_eq!(p.set_settings(&s, tid), Ok(()));
        assert_eq!(p.timelines[0].name, "T1");
        s.format.width = 0;
        assert_eq!(p.set_settings(&s, tid), Err(EditError::InvalidFormat));
        assert_eq!(p.set_settings(&p.timelines[0].settings(), id(404)), Err(EditError::TimelineNotFound));
    }

    #[test]
    fn sanitizing_keeps_valid_fields_and_falls_back_per_field() {
        let current = SequenceFormat {
            width: 1080,
            height: 1920,
            frame_duration: Time::new(1, 25),
            audio_sample_rate: 44_100,
            pixel_aspect_store: None,
            unknown: crate::UnknownKeys::default(),
        };
        let bad = SequenceFormat {
            width: 0,
            height: 720,
            frame_duration: Time::new(1, 60),
            audio_sample_rate: 0,
            pixel_aspect_store: None,
            unknown: crate::UnknownKeys::default(),
        };
        let f = bad.sanitized(&current);
        assert_eq!((f.width, f.height, f.frame_duration, f.audio_sample_rate), (1080, 720, Time::new(1, 60), 44_100));
        assert!(f.is_valid() && !bad.is_valid());
    }
}
