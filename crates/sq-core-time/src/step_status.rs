// SPDX-License-Identifier: GPL-3.0-or-later
//! The one-line status text for a key-driven frame step (trim, nudge, slip, slide), ported from `StepStatus`.

/// Frames moved by the plain arrow key variant.
pub const SMALL: i64 = 1;
/// Frames moved by the Shift variant.
pub const LARGE: i64 = 10;

/// "Trim: 1 frame earlier", "Slip: 10 frames later".
pub fn line(verb: &str, frames: i64) -> String {
    let n = frames.unsigned_abs();
    format!("{verb}: {n} frame{} {}", if n == 1 { "" } else { "s" }, if frames < 0 { "earlier" } else { "later" })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn singular_and_plural() {
        assert_eq!(line("Trim", -1), "Trim: 1 frame earlier");
        assert_eq!(line("Slip", LARGE), "Slip: 10 frames later");
        assert_eq!(line("Nudge", 0), "Nudge: 0 frames later");
        assert_eq!(line("", i64::MIN), format!(": {} frames earlier", i64::MIN.unsigned_abs()));
    }
}
