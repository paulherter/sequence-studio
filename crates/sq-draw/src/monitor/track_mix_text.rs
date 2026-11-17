// Swift: TrackMixText.swift
//! Text and parse rules of the track Volume and Pan form (moved from the Mac `TrackMixDialog`): the fader level in dB
//! ("-inf" at the floor) and the pan as "L 30" / "Center" / "R 20" over -100...100.

use sq_core_model::TrackPan;
use sq_core_model::trim_spaces;

/// Track mix text rules.
pub enum TrackMixText {}

fn lowered(text: &str) -> String {
    text.to_lowercase().replace(',', ".")
}

impl TrackMixText {
    /// "-6", "-6 dB", "-inf" -> dB; `None` when it is not a level.
    pub fn parse_volume_db(text: &str) -> Option<f64> {
        let t = text.to_lowercase().replace("db", "").replace(',', ".");
        let t = trim_spaces(&t, false);
        if t.starts_with("-inf") || t.starts_with("-\u{221E}") {
            return Some(TrackPan::MIN_VOLUME_DB);
        }
        t.parse::<f64>().ok()
    }

    /// "L 30", "R 20", "center", "-30", "20" -> pan -100...100; `None` when it is not a pan.
    pub fn parse_pan(text: &str) -> Option<f64> {
        let lowered = lowered(text);
        let t = trim_spaces(&lowered, false);
        if t == "center" || t == "centre" || t == "c" {
            return Some(0.0);
        }
        let rest = |t: &str| t.chars().skip(1).collect::<String>();
        if t.starts_with('l')
            && let Ok(v) = trim_spaces(&rest(t), false).parse::<f64>()
        {
            return Some(-v.abs());
        }
        if t.starts_with('r')
            && let Ok(v) = trim_spaces(&rest(t), false).parse::<f64>()
        {
            return Some(v.abs());
        }
        t.parse::<f64>().ok()
    }

    /// "+3.0 dB", "-inf dB" at the floor.
    pub fn text_volume_db(volume_db: f64) -> String {
        if volume_db <= TrackPan::MIN_VOLUME_DB { "-inf dB".to_string() } else { format!("{volume_db:+.1} dB") }
    }

    /// The number in the capsule: the unit "dB" sits after the capsule (dialog rule), so it is not part of the text.
    pub fn capsule_text(volume_db: f64) -> String {
        if volume_db <= TrackPan::MIN_VOLUME_DB { "-inf".to_string() } else { format!("{volume_db:+.1}") }
    }

    /// "L 30" / "Center" / "R 20".
    pub fn text_pan(pan: f64) -> String {
        let p = pan.round() as i64;
        match p {
            0 => "Center".to_string(),
            p if p < 0 => format!("L {}", -p),
            p => format!("R {p}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pan_round_trips() {
        assert!(
            TrackMixText::text_pan(-50.0) == "L 50"
                && TrackMixText::text_pan(0.0) == "Center"
                && TrackMixText::text_pan(20.0) == "R 20"
        );
        assert!(
            TrackMixText::parse_pan("L 30") == Some(-30.0)
                && TrackMixText::parse_pan("r20") == Some(20.0)
                && TrackMixText::parse_pan("center") == Some(0.0)
        );
    }

    #[test]
    fn volume_text_and_floor() {
        assert_eq!(TrackMixText::parse_volume_db("-6 dB"), Some(-6.0));
        assert_eq!(TrackMixText::parse_volume_db("-inf"), Some(TrackPan::MIN_VOLUME_DB));
        assert!(
            TrackMixText::text_volume_db(TrackPan::MIN_VOLUME_DB) == "-inf dB"
                && TrackMixText::capsule_text(3.0) == "+3.0"
        );
    }
}
