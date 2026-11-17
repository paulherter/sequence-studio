//! Learn Noise's capture: the mono samples around the playhead of the shown clip, read from its file with the seeking
//! audio reader (no whole-file decode). The block measures the floor from them (`TrackAudioDraw::learn_noise`).

use sq_core_time::Time;
use sq_media_ffmpeg::shim::AudioReader;
use std::path::Path;

/// Sample rate of the capture (the noise floor needs speech-band energy only).
pub const RATE: i32 = 16_000;
/// Length of the capture in seconds.
pub const SECONDS: f64 = 1.0;

/// The window to read: it starts half a second before `source` and never before 0.
pub fn window_start_frame(source: Time) -> i64 {
    let at = source.value() as f64 / source.timescale().max(1) as f64;
    ((at - SECONDS / 2.0).max(0.0) * f64::from(RATE)).round() as i64
}

/// One second of mono samples at the playhead's source time (`None` when the file has no readable audio there).
pub fn capture(path: &Path, source: Time) -> Option<(Vec<f32>, f64)> {
    let mut reader = AudioReader::open(path, RATE, 1, None).ok()?;
    let mut buf = vec![0f32; (SECONDS * f64::from(RATE)) as usize];
    let n = reader.read(window_start_frame(source), &mut buf).ok()?;
    buf.truncate(n);
    (n > 0).then_some((buf, f64::from(RATE)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_window_starts_half_a_second_before_the_playhead() {
        assert_eq!(window_start_frame(Time::seconds(3)), 40_000);
        assert_eq!(window_start_frame(Time::new(1, 4)), 0, "never before the start of the file");
    }

    #[test]
    fn a_missing_file_gives_no_capture() {
        assert!(capture(Path::new("/nonexistent/none.wav"), Time::ZERO).is_none());
    }
}
