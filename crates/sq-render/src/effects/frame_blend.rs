// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: FrameBlend.swift
//! Frame Blending (Time Interpolation): a layer shown at a source time between two decoded source frames is the mix of the
//! frame before and the frame after, weighted by the fractional position (`a * (1 - weight) + b * weight`, on the GPU).
//! Only the weight is here; the `FrameBlend` value that carries the second frame waits for the render layer (NOTES-effects.md).

use sq_core_time::Time;

/// Fractional position of `source_time` inside the source frame that starts at `frame_start` and lasts `frame_duration`.
/// 0 = exactly on the frame (no blend needed). Clamped to 0 ... 1.
pub fn weight(source_time: Time, frame_start: Time, frame_duration: Time) -> f32 {
    if frame_duration <= Time::ZERO {
        return 0.0;
    }
    let num = i128::from(source_time.value()) * i128::from(frame_start.timescale())
        - i128::from(frame_start.value()) * i128::from(source_time.timescale());
    let den = i128::from(source_time.timescale()) * i128::from(frame_start.timescale());
    let w = num as f64 * frame_duration.timescale() as f64 / (den as f64 * frame_duration.value() as f64);
    w.clamp(0.0, 1.0) as f32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn weight_is_the_fractional_source_position() {
        let fd = Time::new(1, 30);
        // 50 % speed: timeline frame 1 shows source 0.5 frames in: halfway between A (frame 0) and B (frame 1).
        assert_eq!(weight(Time::new(1, 60), Time::ZERO, fd), 0.5);
        assert_eq!(weight(Time::ZERO, Time::ZERO, fd), 0.0);
        assert_eq!(weight(Time::new(1, 120), Time::ZERO, fd), 0.25);
        let t = Time::reducing(7 * 3 + 1, 90);
        assert!(weight(t, Time::new(7, 30), fd) > 0.33);
        assert_eq!(weight(Time::new(5, 1), Time::ZERO, fd), 1.0);
        assert_eq!(weight(Time::new(1, 60), Time::ZERO, Time::ZERO), 0.0);
    }
}
