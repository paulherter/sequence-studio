// Swift: AnglesSync.swift
//! Create Angles Clip: what the sync choices need from the files. The matching itself is `sq_core_audio::angles_audio_sync`;
//! the loudness envelope is [`crate::waveform_data::WaveformData::envelope`] (`ENVELOPE_RATE`).

use std::path::Path;

use sq_core_time::Time;

use crate::mxffile::MxfFile;
use crate::source_timecode::{Source, SourceTimecode};

/// Sync inputs read from a file.
pub enum AnglesSync {}

impl AnglesSync {
    /// Time of day of the file's first frame from its start timecode: MXF material package, or a QuickTime/MP4 timecode
    /// track. `None` when the file carries none. `ntsc`: the picture runs at a 1000/1001 rate (23.976, 29.97, 59.94),
    /// which MXF does not say for non-drop timecode.
    // Swift: AnglesSync.swift:19
    pub fn start_timecode(path: &Path, ntsc: bool) -> Option<Time> {
        if MxfFile::is_mxf(path) {
            let tc = MxfFile::open(path).ok()?.timecode?;
            return Self::time(tc.start_frame, tc.base, tc.drop_frame || ntsc);
        }
        let tc = SourceTimecode::read(path).ok().flatten()?;
        (tc.source == Source::Tmcd).then_some(tc.origin)
    }

    /// `frames` timecode frames at `base` per second as time; `slowed` = the real rate is base x 1000/1001.
    // Swift: AnglesSync.swift:30
    pub fn time(frames: i64, base: i64, slowed: bool) -> Option<Time> {
        if base <= 0 {
            return None;
        }
        Some(if slowed { Time::new(frames * 1001, base * 1000) } else { Time::new(frames, base) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timecode_frames_become_exact_time_slowed_for_ntsc() {
        assert_eq!(AnglesSync::time(30, 30, false), Some(Time::new(1, 1)));
        assert_eq!(AnglesSync::time(30, 30, true), Some(Time::new(30030, 30000)));
        assert_eq!(AnglesSync::time(1, 0, false), None);
    }

    #[test]
    fn a_file_without_timecode_gives_none() {
        assert_eq!(AnglesSync::start_timecode(Path::new("/nonexistent/none.mov"), false), None);
    }
}
