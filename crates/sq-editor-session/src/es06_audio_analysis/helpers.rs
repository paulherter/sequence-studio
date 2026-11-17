//! Small helpers the ES6 flows share.

use sq_core_time::Time;
use sq_uikit::timecode::Timecode;

/// `HH:MM:SS:FF` of the monitor (drop-frame at 29.97 / 59.94), Swift `MarkersPanelModel.timecode`.
pub(crate) fn timecode(t: Time, frame_duration: Time) -> String {
    Timecode::new(frame_duration, true).format(t.max(Time::ZERO))
}
