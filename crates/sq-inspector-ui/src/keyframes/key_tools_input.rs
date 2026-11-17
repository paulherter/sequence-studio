// Swift: KeyToolsInput.swift
//! Parsing of the numbers typed in the Scale Time and Keyframe Velocity dialogs, and the dialogs as data.

use sq_uikit::localization::SQL10n;

use crate::ec::inspector_text_formats::ControlsNumberText;

/// A ratio num/den.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TimeScaleRatio {
    pub num: i64,
    pub den: i64,
}

/// The three Wiggle fields.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WiggleInput {
    pub per_second: i64,
    pub amount: f64,
    pub seed: u64,
}

/// Parsing of the numbers typed in the Scale Time and Keyframe Velocity dialogs.
pub enum KeyToolsInput {}

impl KeyToolsInput {
    /// "50", "50 %" or "12,5" as a ratio num/den (percent in thousandths); nil unless > 0 and <= 10000 percent.
    pub fn time_scale_ratio(text: &str) -> Option<TimeScaleRatio> {
        let v = Self::number(text)?;
        if !(v > 0.0 && v <= 10_000.0) {
            return None;
        }
        Some(TimeScaleRatio { num: (v * 1000.0).round() as i64, den: 100_000 })
    }

    /// A whole number inside `range`, else nil.
    pub fn whole_number(text: &str, range: std::ops::RangeInclusive<i64>) -> Option<i64> {
        let v = Self::number(text)?;
        if v != v.round() || v < *range.start() as f64 || v > *range.end() as f64 {
            return None;
        }
        Some(v as i64)
    }

    /// The three Wiggle fields: frequency 1...60 per second, amount > 0, seed a whole number >= 0.
    pub fn wiggle(frequency: &str, amount: &str, seed: &str) -> Option<WiggleInput> {
        let f = Self::whole_number(frequency, 1..=60)?;
        let a = Self::number(amount)?;
        if a <= 0.0 {
            return None;
        }
        let s = Self::whole_number(seed, 0..=i64::from(i32::MAX))?;
        Some(WiggleInput { per_second: f, amount: a, seed: s as u64 })
    }

    /// A plain number (comma or point) with an optional trailing "%" or unit text; nil when no number leads.
    pub fn number(text: &str) -> Option<f64> {
        let t = text.trim_matches(|c| c == ' ' || c == '\t').replace(',', ".");
        let lead: String = t.chars().take_while(|c| "0123456789.-".contains(*c)).collect();
        lead.parse::<f64>().ok()
    }
}

/// One field of a key tool dialog.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyToolField {
    pub label: String,
    pub text: String,
}

/// Speed and influence of one side.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SideSpeed {
    pub speed: f64,
    pub influence: f64,
}

/// The answers of `KeyToolPrompt::velocity`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct VelocityAnswer {
    pub incoming: Option<SideSpeed>,
    pub outgoing: Option<SideSpeed>,
}

/// A key tool's dialog as data (title, note, fields, confirm button): the Mac `KeyToolsDialogs` and the shared-toolkit
/// hosts show the same questions and read the answers through the same parsers.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyToolPrompt {
    pub title: String,
    pub informative: String,
    pub confirm: String,
    pub fields: Vec<KeyToolField>,
}

fn field(label: &str, text: &str) -> KeyToolField {
    KeyToolField { label: label.to_string(), text: text.to_string() }
}

impl KeyToolPrompt {
    fn make(title: &str, informative: &str, confirm: &str, fields: Vec<KeyToolField>) -> KeyToolPrompt {
        KeyToolPrompt {
            title: title.to_string(),
            informative: informative.to_string(),
            confirm: confirm.to_string(),
            fields,
        }
    }

    pub fn scale_time() -> KeyToolPrompt {
        Self::make(
            "Scale Time",
            "Scales the distance of the selected keys to the earliest one.",
            "Scale",
            vec![field("Scale", "100 %")],
        )
    }

    pub fn loop_prompt() -> KeyToolPrompt {
        Self::make("Loop", "Repeats the key pattern after its last key.", "Loop", vec![field("Repeats", "1")])
    }

    pub fn wiggle() -> KeyToolPrompt {
        Self::make(
            "Wiggle",
            "Adds random offsets between the first and last selected key.",
            "Wiggle",
            vec![field("Frequency (/s)", "5"), field("Amount", "0.1"), field("Seed", "1")],
        )
    }

    pub fn save_curve() -> KeyToolPrompt {
        Self::make("Save Curve", "Name for the new easing preset.", "Save", vec![field("Name", "Curve")])
    }

    /// A name for a Look or a saved animation (TextBlockView.promptLookName): one field, OK / Cancel.
    pub fn name(title: &str, initial: &str) -> KeyToolPrompt {
        Self::make(title, "", "OK", vec![field("Name", initial)])
    }

    /// R29: turning a parameter's animation off asks before its keys go (no fields; confirm = remove).
    pub fn remove_keyframes(title: &str) -> KeyToolPrompt {
        Self::make(
            &SQL10n::format("Remove all %@ keyframes?", &[&SQL10n::string(title)]),
            "The property keeps the value it has at the playhead.",
            "Remove",
            Vec::new(),
        )
    }

    /// Keyframe Velocity: speed (display units per second) and influence (percent) per side that exists.
    pub fn velocity(incoming: Option<SideSpeed>, outgoing: Option<SideSpeed>, unit: &str) -> KeyToolPrompt {
        let mut f: Vec<KeyToolField> = Vec::new();
        if let Some(i) = incoming {
            f.push(field(&format!("In speed ({unit}/s)"), &ControlsNumberText::format(i.speed, 2)));
            f.push(field("In influence (%)", &ControlsNumberText::format(i.influence * 100.0, 0)));
        }
        if let Some(o) = outgoing {
            f.push(field(&format!("Out speed ({unit}/s)"), &ControlsNumberText::format(o.speed, 2)));
            f.push(field("Out influence (%)", &ControlsNumberText::format(o.influence * 100.0, 0)));
        }
        Self::make(
            "Keyframe Velocity",
            "Speed and influence of the incoming and outgoing side of the selected keys.",
            "Apply",
            f,
        )
    }

    /// The answers of `velocity(...)`: per side (speed, influence 0...1), nil where the side is absent or unreadable.
    pub fn velocity_answer(texts: &[String], has_incoming: bool, has_outgoing: bool) -> VelocityAnswer {
        let read = |i: usize| -> Option<SideSpeed> {
            if i + 1 >= texts.len() {
                return None;
            }
            let sp = KeyToolsInput::number(&texts[i])?;
            let inf = KeyToolsInput::number(&texts[i + 1])?;
            Some(SideSpeed { speed: sp.abs(), influence: (inf / 100.0).clamp(0.0001, 1.0) })
        };
        VelocityAnswer {
            incoming: if has_incoming { read(0) } else { None },
            outgoing: if has_outgoing { read(if has_incoming { 2 } else { 0 }) } else { None },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn numbers_take_comma_percent_and_units() {
        assert_eq!(KeyToolsInput::number("12,5"), Some(12.5));
        assert_eq!(KeyToolsInput::number(" 50 %"), Some(50.0));
        assert_eq!(KeyToolsInput::number("abc"), None);
        assert_eq!(KeyToolsInput::number(""), None);
    }

    #[test]
    fn time_scale_ratio_is_in_thousandths_of_a_percent() {
        assert_eq!(KeyToolsInput::time_scale_ratio("50"), Some(TimeScaleRatio { num: 50_000, den: 100_000 }));
        assert_eq!(KeyToolsInput::time_scale_ratio("0"), None);
        assert_eq!(KeyToolsInput::time_scale_ratio("10001"), None);
        assert_eq!(KeyToolsInput::time_scale_ratio("12,5 %"), Some(TimeScaleRatio { num: 12_500, den: 100_000 }));
    }

    #[test]
    fn whole_numbers_and_wiggle_are_range_checked() {
        assert_eq!(KeyToolsInput::whole_number("3", 1..=5), Some(3));
        assert_eq!(KeyToolsInput::whole_number("3.5", 1..=5), None);
        assert_eq!(KeyToolsInput::whole_number("9", 1..=5), None);
        assert_eq!(KeyToolsInput::wiggle("5", "0.1", "1"), Some(WiggleInput { per_second: 5, amount: 0.1, seed: 1 }));
        assert_eq!(KeyToolsInput::wiggle("61", "0.1", "1"), None);
        assert_eq!(KeyToolsInput::wiggle("5", "0", "1"), None);
        assert_eq!(KeyToolsInput::wiggle("5", "1", "-1"), None);
    }

    #[test]
    fn velocity_prompt_lists_the_sides_that_exist() {
        let p = KeyToolPrompt::velocity(
            Some(SideSpeed { speed: 12.0, influence: 0.33 }),
            Some(SideSpeed { speed: 3.5, influence: 1.0 }),
            "px",
        );
        let labels: Vec<&str> = p.fields.iter().map(|f| f.label.as_str()).collect();
        assert_eq!(labels, ["In speed (px/s)", "In influence (%)", "Out speed (px/s)", "Out influence (%)"]);
        assert_eq!(p.fields[0].text, "12.00");
        assert_eq!(p.fields[1].text, "33");
    }

    #[test]
    fn velocity_answer_reads_absolute_speed_and_clamps_influence() {
        let texts: Vec<String> = ["-4", "250", "2", "0"].iter().map(|s| s.to_string()).collect();
        let a = KeyToolPrompt::velocity_answer(&texts, true, true);
        assert_eq!(a.incoming, Some(SideSpeed { speed: 4.0, influence: 1.0 }));
        assert_eq!(a.outgoing, Some(SideSpeed { speed: 2.0, influence: 0.0001 }));
        let out_only = KeyToolPrompt::velocity_answer(&texts, false, true);
        assert_eq!(out_only.incoming, None);
        assert_eq!(out_only.outgoing, Some(SideSpeed { speed: 4.0, influence: 1.0 }));
    }
}
