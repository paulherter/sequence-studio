// Swift: Timecode.swift
//! Pure timecode format/parse on rational time. Drop-frame applies to 29.97 and 59.94 only.

use sq_core_time::Time;

/// Foundation's `.whitespaces` set: tab and the space separators (no newlines).
fn is_blank(c: char) -> bool {
    matches!(c, '\t' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}')
}

/// `trimmingCharacters(in: .whitespaces)`.
pub(crate) fn trim_blanks(s: &str) -> &str {
    s.trim_matches(is_blank)
}

fn is_ascii_number(s: &str) -> bool {
    s.chars().all(|c| c.is_ascii_digit())
}

/// Timecode display and entry for one frame rate.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Timecode {
    frame_duration: Time,
    drop_frame: bool,
    /// Sequence Settings "Starts at": the timecode of time zero. Only `position` / `parse_position` use it; lengths do not.
    pub origin: Time,
    /// Sequence Settings "Display: Frames": positions and lengths are plain frame counts.
    pub frames_only: bool,
}

impl Timecode {
    /// Drop-frame is honored only for 1001-based 30 and 60 fps rates.
    pub fn new(frame_duration: Time, drop_frame: bool) -> Timecode {
        let nominal = Timecode::nominal(frame_duration);
        Timecode {
            frame_duration,
            drop_frame: drop_frame && frame_duration.value() == 1001 && (nominal == 30 || nominal == 60),
            origin: Time::ZERO,
            frames_only: false,
        }
    }

    /// Duration of one frame.
    pub fn frame_duration(&self) -> Time {
        self.frame_duration
    }

    /// True when drop-frame counting is on.
    pub fn drop_frame(&self) -> bool {
        self.drop_frame
    }

    pub(crate) fn nominal(fd: Time) -> i64 {
        let v = fd.value().max(1);
        (fd.timescale() * 2 + v) / (v * 2)
    }

    /// Nominal frames per second (30 for 29.97).
    pub fn nominal_fps(&self) -> i64 {
        Timecode::nominal(self.frame_duration)
    }

    /// `;` before the frames in drop-frame, else `:`.
    pub fn separator_before_frames(&self) -> char {
        if self.drop_frame { ';' } else { ':' }
    }

    /// Frames dropped per minute: 2 at 30, 4 at 60.
    fn drop_count(&self) -> i64 {
        self.nominal_fps() / 15
    }

    /// A position on the sequence: the time plus the start timecode.
    pub fn position(&self, time: Time) -> String {
        self.format(time + self.origin)
    }

    /// Entry of a position (the inverse of `position`, so `parse_position(position(t)) == t` for negative `t` too); the
    /// result is relative to time zero and may be negative when the entry lies before the start.
    pub fn parse_position(&self, text: &str) -> Option<Time> {
        self.parse(text).map(|t| t - self.origin)
    }

    /// `hh:mm:ss:ff` of `time` (frame count in frames-only mode).
    pub fn format(&self, time: Time) -> String {
        if self.frames_only {
            return time.frame_index(self.frame_duration).to_string();
        }
        let mut n = time.frame_index(self.frame_duration);
        let negative = n < 0;
        if negative {
            n = -n;
        }
        let fps = self.nominal_fps();
        if self.drop_frame {
            let d = self.drop_count();
            let per10 = fps * 600 - 9 * d;
            let per_min = fps * 60 - d;
            let tens = n / per10;
            let rem = n % per10;
            n += 9 * d * tens;
            if rem > d {
                n += d * ((rem - d) / per_min);
            }
        }
        let f = n % fps;
        let s = (n / fps) % 60;
        let m = (n / (fps * 60)) % 60;
        let h = n / (fps * 3600);
        let p = |v: i64| if v < 10 { format!("0{v}") } else { v.to_string() };
        format!(
            "{}{}:{}:{}{}{}",
            if negative { "-" } else { "" },
            p(h),
            p(m),
            p(s),
            self.separator_before_frames(),
            p(f)
        )
    }

    /// Accepts `hh:mm:ss:ff` (`: ; . ,` as separators), shorter right-aligned forms ("1:01"),
    /// or bare digits right-aligned ("101" = 00:00:01:01). `None` for invalid input or dropped labels.
    pub fn parse(&self, text: &str) -> Option<Time> {
        let mut s = trim_blanks(text);
        let mut negative = false;
        if let Some(rest) = s.strip_prefix('-') {
            negative = true;
            s = rest;
        }
        if s.is_empty() {
            return None;
        }
        if self.frames_only && is_ascii_number(s) {
            if s.len() > 9 {
                return None;
            }
            let n: i64 = s.parse().ok()?;
            let t = self.frame_duration * n;
            return Some(if negative { -t } else { t });
        }
        let is_sep = |c: char| matches!(c, ':' | ';' | '.' | ',');
        let mut fields: Vec<i64> = Vec::new();
        if s.chars().any(is_sep) {
            for part in s.split(is_sep) {
                if part.is_empty() || !is_ascii_number(part) {
                    return None;
                }
                fields.push(part.parse().ok()?);
            }
            if fields.len() > 4 {
                return None;
            }
        } else {
            if !is_ascii_number(s) || s.len() > 8 {
                return None;
            }
            let padded = format!("{}{}", "0".repeat(8 - s.len()), s);
            for i in (0..8).step_by(2) {
                fields.push(padded[i..i + 2].parse().ok()?);
            }
        }
        while fields.len() < 4 {
            fields.insert(0, 0);
        }
        let (h, m, sec, f) = (fields[0], fields[1], fields[2], fields[3]);
        let fps = self.nominal_fps();
        if !(h <= 9_999 && m < 60 && sec < 60 && f < fps) {
            return None; // h capped: the frame maths must not overflow
        }
        let mut frames = fps * (3600 * h + 60 * m + sec) + f;
        if self.drop_frame {
            let d = self.drop_count();
            if sec == 0 && f < d && m % 10 != 0 {
                return None;
            }
            let total_min = 60 * h + m;
            frames -= d * (total_min - total_min / 10);
        }
        let t = self.frame_duration * frames;
        Some(if negative { -t } else { t })
    }

    /// Relative entry: `+10` / `-5` (frames) or `+1:00` / `-0:10` (timecode amount, signed). `None` when `text` does not
    /// start with a sign or the amount is invalid. The result is the signed offset.
    pub fn parse_relative(&self, text: &str) -> Option<Time> {
        let s = trim_blanks(text);
        let sign = s.chars().next().filter(|c| *c == '+' || *c == '-')?;
        let rest = trim_blanks(&s[1..]);
        if rest.is_empty() {
            return None;
        }
        let amount = if is_ascii_number(rest) {
            if rest.len() > 7 {
                return None;
            }
            self.frame_duration * rest.parse::<i64>().ok()?
        } else {
            self.parse(rest)?
        };
        Some(if sign == '-' { Time::ZERO - amount } else { amount })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ntsc(drop: bool) -> Timecode {
        Timecode::new(Time::new(1001, 30000), drop)
    }

    #[test]
    fn drop_frame_only_for_ntsc_30_and_60() {
        assert!(ntsc(true).drop_frame());
        assert!(Timecode::new(Time::new(1001, 60000), true).drop_frame());
        assert!(!Timecode::new(Time::new(1, 30), true).drop_frame());
        assert!(!ntsc(false).drop_frame());
    }

    #[test]
    fn drop_frame_labels_skip_frames_two_to_zero_each_minute() {
        let tc = ntsc(true);
        let fd = tc.frame_duration();
        assert_eq!(tc.format(fd * 1799), "00:00:59;29");
        assert_eq!(tc.format(fd * 1800), "00:01:00;02");
        assert_eq!(tc.format(fd * 17982), "00:10:00;00");
        assert_eq!(tc.parse("00:01:00;02"), Some(fd * 1800));
        assert_eq!(tc.parse("00:01:00;00"), None);
        assert_eq!(tc.parse("00:10:00;00"), Some(fd * 17982));
    }

    #[test]
    fn non_drop_formats_and_parses_round_trip() {
        let tc = Timecode::new(Time::new(1, 24), false);
        let fd = tc.frame_duration();
        assert_eq!(tc.format(fd * 86400), "01:00:00:00");
        assert_eq!(tc.format(-(fd * 25)), "-00:00:01:01");
        for n in [0_i64, 1, 23, 24, 1439, 86399, -7] {
            assert_eq!(tc.parse(&tc.format(fd * n)), Some(fd * n));
        }
    }

    #[test]
    fn short_and_bare_digit_entries_are_right_aligned() {
        let tc = Timecode::new(Time::new(1, 24), false);
        let fd = tc.frame_duration();
        assert_eq!(tc.parse("1:01"), Some(fd * 25));
        assert_eq!(tc.parse("101"), Some(fd * 25));
        assert_eq!(tc.parse("00.00.01,01"), Some(fd * 25));
        assert_eq!(tc.parse("00:00:00:24"), None);
        assert_eq!(tc.parse("1:2:3:4:5"), None);
        assert_eq!(tc.parse("12a"), None);
        assert_eq!(tc.parse(""), None);
    }

    #[test]
    fn origin_shifts_positions_and_round_trips_negative_times() {
        let mut tc = Timecode::new(Time::new(1, 25), false);
        tc.origin = Time::seconds(3600);
        let fd = tc.frame_duration();
        assert_eq!(tc.position(Time::ZERO), "01:00:00:00");
        for n in [0_i64, 40, -40] {
            assert_eq!(tc.parse_position(&tc.position(fd * n)), Some(fd * n));
        }
    }

    #[test]
    fn negative_position_subtracts_the_origin_like_positive_ones() {
        let mut tc = Timecode::new(Time::new(1, 30), false);
        tc.origin = Time::new(3600, 1);
        assert_eq!(tc.parse_position("-00:00:10:00"), Some(Time::new(-3610, 1)));
        assert_eq!(tc.parse_position("01:00:10:00"), Some(Time::new(10, 1)));
        let t = Time::new(-5, 1);
        assert_eq!(tc.parse_position(&tc.position(t)), Some(t));
    }

    #[test]
    fn frames_only_and_relative_entries() {
        let mut tc = Timecode::new(Time::new(1, 24), false);
        let fd = tc.frame_duration();
        assert_eq!(tc.parse_relative("+10"), Some(fd * 10));
        assert_eq!(tc.parse_relative("-5"), Some(-(fd * 5)));
        assert_eq!(tc.parse_relative("+1:00"), Some(fd * 24));
        assert_eq!(tc.parse_relative("10"), None);
        assert_eq!(tc.parse_relative("+"), None);
        tc.frames_only = true;
        assert_eq!(tc.format(fd * 100), "100");
        assert_eq!(tc.parse("-100"), Some(-(fd * 100)));
    }
}
