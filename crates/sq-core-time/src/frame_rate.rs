// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: FrameRate.swift

use crate::Time;

/// Frame rate choice for a clip or sequence (pure, rational).
pub struct FrameRate;

impl FrameRate {
    /// 23.976, 24, 25, 29.97, 30, 50, 59.94, 60.
    pub const STANDARD_FRAME_DURATIONS: [Time; 8] = [
        Time::new(1001, 24000),
        Time::new(1, 24),
        Time::new(1, 25),
        Time::new(1001, 30000),
        Time::new(1, 30),
        Time::new(1, 50),
        Time::new(1001, 60000),
        Time::new(1, 60),
    ];

    /// Frame duration from the average rate (`frame_count` over `duration`): the nearest standard rate when within 1 %,
    /// else `duration / frame_count`; 1/30 for no frames or no duration.
    pub fn sequence_frame_duration(frame_count: i64, duration: Time) -> Time {
        if frame_count <= 0 || duration <= Time::ZERO {
            return Time::new(1, 30);
        }
        let n = frame_count;
        let fps = n as f64 * duration.timescale() as f64 / duration.value() as f64;
        let mut best: Option<(Time, f64)> = None;
        for fd in Self::STANDARD_FRAME_DURATIONS {
            let std = fd.timescale() as f64 / fd.value() as f64;
            let rel = (fps - std).abs() / std;
            if rel <= 0.01 && rel < best.map_or(f64::INFINITY, |b| b.1) {
                best = Some((fd, rel));
            }
        }
        if let Some(best) = best {
            return best.0;
        }
        match duration.timescale().checked_mul(n) {
            Some(v) => Time::new(duration.value(), v),
            None => Time::reducing(duration.value() as i128, duration.timescale() as i128 * n as i128),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_standard_rate_within_one_percent() {
        assert_eq!(FrameRate::sequence_frame_duration(2997, Time::new(100, 1)), Time::new(1001, 30000));
        assert_eq!(FrameRate::sequence_frame_duration(0, Time::new(1, 1)), Time::new(1, 30));
        assert_eq!(FrameRate::sequence_frame_duration(12, Time::new(1, 1)), Time::new(1, 12));
    }
}
