// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SequenceTimecode.swift (types and the Timeline accessors: task M-4)
//
// v81: per-sequence timecode start / display and preview quality. Each is stored only when not the default, so untouched
// sequences encode as before.

use crate::Timeline;
use serde::{Deserialize, Serialize};
use sq_core_time::Time;

/// How a sequence shows positions.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TimecodeDisplay {
    /// HH:MM:SS:FF.
    Timecode,
    /// Frame numbers.
    Frames,
}

/// Playback resolution of a sequence.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SequencePreviewQuality {
    /// Full resolution.
    Full,
    /// Half resolution.
    Half,
    /// Quarter resolution.
    Quarter,
}

impl Timeline {
    /// Timecode of the first frame (default 0): shifts the shown positions only; clips, markers and export keep their times.
    /// Never negative, kept on a whole frame.
    pub fn timecode_start(&self) -> Time {
        self.timecode_start_store.unwrap_or(Time::ZERO)
    }

    /// Sets the timecode start, snapped to a whole frame of the current format (set it after the format).
    pub fn set_timecode_start(&mut self, start: Time) {
        let t = if start < Time::ZERO { Time::ZERO } else { start.snapped(self.frame_duration()) };
        self.timecode_start_store = (t != Time::ZERO).then_some(t);
    }

    /// How positions are shown (default timecode).
    pub fn timecode_display(&self) -> TimecodeDisplay {
        self.timecode_display_store.unwrap_or(TimecodeDisplay::Timecode)
    }

    /// Sets the position display; timecode is stored as absent.
    pub fn set_timecode_display(&mut self, display: TimecodeDisplay) {
        self.timecode_display_store = (display != TimecodeDisplay::Timecode).then_some(display);
    }

    /// Preview resolution the sequence asks for; `None` = follow the app setting.
    pub fn preview_quality(&self) -> Option<SequencePreviewQuality> {
        self.preview_quality_store
    }

    /// Sets the preview resolution; `None` = follow the app setting.
    pub fn set_preview_quality(&mut self, quality: Option<SequencePreviewQuality>) {
        self.preview_quality_store = quality;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::nesting::test_util::*;

    #[test]
    fn timecode_start_is_never_negative_and_snaps_to_a_frame() {
        let mut p = project_json(vec![], vec![timeline_json(1, vec![])]);
        let t = &mut p.timelines[0];
        assert_eq!(t.timecode_start(), Time::ZERO);
        t.set_timecode_start(Time::new(3600, 1));
        assert_eq!((t.timecode_start(), t.timecode_start_store), (Time::new(3600, 1), Some(Time::new(3600, 1))));
        t.set_timecode_start(Time::new(1, 25));
        assert_eq!(t.timecode_start(), Time::new(1, 30), "snapped to the 30 fps frame grid");
        t.set_timecode_start(Time::new(-5, 1));
        assert_eq!((t.timecode_start(), t.timecode_start_store), (Time::ZERO, None));
        t.set_timecode_start(Time::new(1, 1000));
        assert_eq!(t.timecode_start_store, None, "less than half a frame is zero");
    }

    #[test]
    fn display_and_quality_store_only_non_defaults() {
        let mut p = project_json(vec![], vec![timeline_json(1, vec![])]);
        let t = &mut p.timelines[0];
        assert_eq!((t.timecode_display(), t.preview_quality()), (TimecodeDisplay::Timecode, None));
        t.set_timecode_display(TimecodeDisplay::Frames);
        t.set_preview_quality(Some(SequencePreviewQuality::Half));
        assert_eq!(t.timecode_display_store, Some(TimecodeDisplay::Frames));
        assert_eq!(t.preview_quality(), Some(SequencePreviewQuality::Half));
        t.set_timecode_display(TimecodeDisplay::Timecode);
        assert_eq!(t.timecode_display_store, None);
    }
}
