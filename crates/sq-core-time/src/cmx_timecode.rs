// SPDX-License-Identifier: GPL-3.0-or-later
//! SMPTE timecode text (`HH:MM:SS:FF`, `;` before the frames for drop frame) as whole frame counts, for EDL
//! interchange. Integer math only. Drop frame skips 2 (30 fps) or 4 (60 fps) frame numbers each minute except
//! every tenth. Ported from `CMXTimecode`.

use crate::Time;

/// Timecode clock: nominal frames per second and drop-frame choice.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CmxTimecode {
    nominal_rate: i64,
    drop_frame: bool,
}

impl CmxTimecode {
    /// Rate below 1 becomes 1; only 30 and 60 (multiples of 30) can drop frames.
    pub fn new(nominal_rate: i64, drop_frame: bool) -> Self {
        CmxTimecode { nominal_rate: nominal_rate.max(1), drop_frame: drop_frame && nominal_rate % 30 == 0 }
    }

    /// The clock rate and drop-frame choice for a sequence frame duration (29.97 / 59.94 give drop frame).
    pub fn from_frame_duration(fd: Time, prefer_drop: bool) -> Self {
        let rate = fd.timescale() as f64 / fd.value().max(1) as f64;
        // Saturating `as` stands in for Swift's trap on absurd rates.
        let nominal = rate.round() as i64;
        let ntsc = fd.value().wrapping_mul(nominal) != fd.timescale();
        Self::new(nominal, prefer_drop && ntsc)
    }

    /// Frames per second as counted on the clock (24, 25, 30, 60...).
    pub fn nominal_rate(&self) -> i64 {
        self.nominal_rate
    }

    /// Whether the clock skips frame numbers (NTSC).
    pub fn drop_frame(&self) -> bool {
        self.drop_frame
    }

    fn dropped(&self) -> i64 {
        if self.drop_frame { self.nominal_rate / 15 } else { 0 }
    }

    /// Frame count of a timecode string; `None` when it is not `HH:MM:SS:FF` / `HH:MM:SS;FF` (`.` also separates).
    /// The separator is not trusted: the receiver's drop-frame flag decides.
    pub fn frames(&self, text: &str) -> Option<i64> {
        let parts: Vec<&str> = text.split([':', ';', '.']).filter(|p| !p.is_empty()).collect();
        if parts.len() != 4 {
            return None;
        }
        let mut v = [0i128; 4];
        for (slot, p) in v.iter_mut().zip(&parts) {
            *slot = i128::from(p.parse::<i64>().ok().filter(|n| *n >= 0)?);
        }
        let rate = i128::from(self.nominal_rate);
        let total_minutes = v[0] * 60 + v[1];
        let n = (v[0] * 3600 + v[1] * 60 + v[2]) * rate + v[3]
            - i128::from(self.dropped()) * (total_minutes - total_minutes / 10);
        i64::try_from(n).ok()
    }

    /// Timecode text of a frame count (negative counts read as 0).
    pub fn string(&self, frames: i64) -> String {
        let mut n = frames.max(0);
        let rate = self.nominal_rate;
        let dropped = self.dropped();
        if self.drop_frame {
            let per_ten = rate * 600 - dropped * 9;
            let per_minute = rate * 60 - dropped;
            let (tens, rest) = (n / per_ten, n % per_ten);
            n += 9 * dropped * tens;
            if rest > dropped {
                n += dropped * ((rest - dropped) / per_minute);
            }
        }
        let (f, s, m, h) = (n % rate, (n / rate) % 60, (n / (rate * 60)) % 60, n / (rate * 3600));
        let sep = if self.drop_frame { ';' } else { ':' };
        format!("{h:02}:{m:02}:{s:02}{sep}{f:02}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_drop_round_trip() {
        let tc = CmxTimecode::new(25, false);
        assert_eq!(tc.frames("01:00:00:00"), Some(90_000));
        assert_eq!(tc.string(90_000), "01:00:00:00");
        assert_eq!(tc.frames("00:00:01:12"), Some(37));
        assert_eq!(tc.string(37), "00:00:01:12");
        assert_eq!(tc.frames("garbage"), None);
    }

    #[test]
    fn drop_frame_known_values() {
        let tc = CmxTimecode::new(30, true);
        // One hour of 29.97 drop frame is 107_892 frames.
        assert_eq!(tc.frames("01:00:00;00"), Some(107_892));
        assert_eq!(tc.string(107_892), "01:00:00;00");
        // Frame numbers 00 and 01 do not exist at 00:01:00 (except every tenth minute).
        assert_eq!(tc.frames("00:01:00;02"), Some(1800));
        assert_eq!(tc.string(1800), "00:01:00;02");
        assert_eq!(tc.string(1799), "00:00:59;29");
        assert_eq!(tc.frames("00:10:00;00"), Some(17_982));
        for n in (0..200_000).step_by(997) {
            assert_eq!(tc.frames(&tc.string(n)), Some(n));
        }
    }

    #[test]
    fn rate_from_frame_duration() {
        let ntsc = CmxTimecode::from_frame_duration(Time::new(1001, 30_000), true);
        assert!(ntsc.nominal_rate() == 30 && ntsc.drop_frame());
        let film = CmxTimecode::from_frame_duration(Time::new(1001, 24_000), true);
        assert!(film.nominal_rate() == 24 && !film.drop_frame());
        let pal = CmxTimecode::from_frame_duration(Time::new(1, 25), true);
        assert!(pal.nominal_rate() == 25 && !pal.drop_frame());
        assert_eq!(CmxTimecode::from_frame_duration(Time::new(1001, 60_000), true).nominal_rate(), 60);
        assert!(!CmxTimecode::from_frame_duration(Time::new(1001, 30_000), false).drop_frame());
    }

    #[test]
    fn rate_is_clamped_and_only_multiples_of_30_drop() {
        assert_eq!(CmxTimecode::new(-3, true), CmxTimecode { nominal_rate: 1, drop_frame: false });
        assert!(!CmxTimecode::new(24, true).drop_frame());
        assert_eq!(CmxTimecode::new(30, false).string(-5), "00:00:00:00");
    }
}
