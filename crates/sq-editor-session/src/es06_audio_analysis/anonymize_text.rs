// Swift: AnonymizeText.swift
//! What the user chose in the Anonymize sheet and the texts of its sheets. The text never promises a result: detection
//! is a guess and the user checks it.

use sq_core_masks::anonymize::{AnonymizeCover, AnonymizePerson};
use sq_core_model::AnonymizeTarget;
use sq_library::library_folder_store::SettingsStore;

use super::anonymize::AnonymizeCheckLine;
use super::settings::{get_string, set_string};

/// What the user chose in the Anonymize sheet.
// Swift: AnonymizeText.swift:5
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct AnonymizeChoice {
    // Swift: AnonymizeText.swift:6
    pub target: AnonymizeTarget,
    // Swift: AnonymizeText.swift:7
    pub cover: AnonymizeCover,
    /// Indices into the found people.
    // Swift: AnonymizeText.swift:9
    pub people: Vec<usize>,
}

const KEY_TARGET: &str = "sq.anonymize.target";
const KEY_COVER: &str = "sq.anonymize.cover";

fn target_name(t: AnonymizeTarget) -> &'static str {
    match t {
        AnonymizeTarget::Face => "face",
        AnonymizeTarget::Person => "person",
        AnonymizeTarget::Skin => "skin",
    }
}

fn cover_name(c: AnonymizeCover) -> &'static str {
    match c {
        AnonymizeCover::Mosaic => "mosaic",
        AnonymizeCover::Blur => "blur",
    }
}

impl AnonymizeChoice {
    // Swift: AnonymizeText.swift:10
    pub fn new(target: AnonymizeTarget, cover: AnonymizeCover, people: Vec<usize>) -> AnonymizeChoice {
        AnonymizeChoice { target, cover, people }
    }

    /// Last target and cover used (Face, Mosaic the first time).
    // Swift: AnonymizeText.swift:18
    pub fn remembered(d: &dyn SettingsStore) -> (AnonymizeTarget, AnonymizeCover) {
        let target = match get_string(d, KEY_TARGET).as_deref() {
            Some("person") => AnonymizeTarget::Person,
            Some("skin") => AnonymizeTarget::Skin,
            _ => AnonymizeTarget::Face,
        };
        let cover = match get_string(d, KEY_COVER).as_deref() {
            Some("blur") => AnonymizeCover::Blur,
            _ => AnonymizeCover::Mosaic,
        };
        (target, cover)
    }

    // Swift: AnonymizeText.swift:22
    pub fn remember(&self, d: &mut dyn SettingsStore) {
        set_string(d, KEY_TARGET, target_name(self.target));
        set_string(d, KEY_COVER, cover_name(self.cover));
    }
}

/// The texts of the Anonymize sheets, one copy for every dialog.
// Swift: AnonymizeText.swift:28
pub enum AnonymizeText {}

impl AnonymizeText {
    // Swift: AnonymizeText.swift:31
    pub const HINT: &'static str = "Detection is a best guess and can miss frames. Frames it was unsure about are listed afterwards. Always check the whole clip before you export.";
    /// At most this many uncritical lines are listed after a run.
    // Swift: AnonymizeText.swift:33
    pub const MAX_LINES: usize = 12;

    /// "Person 2 (center)": numbered left to right, with where they stand on the frame.
    // Swift: AnonymizeText.swift:36
    pub fn person_label(index: usize, p: &AnonymizePerson) -> String {
        let x = p.box_.center().x;
        let side = if x < 1.0 / 3.0 {
            "left"
        } else if x > 2.0 / 3.0 {
            "right"
        } else {
            "center"
        };
        format!("Person {} ({side})", index + 1)
    }

    // Swift: AnonymizeText.swift:40
    pub fn info(clip_name: &str) -> String {
        format!(
            "{clip_name}\nEach person gets a mask that follows them through the clip. The cover is an effect limited to those masks; both stay editable in Effect Controls."
        )
    }

    // Swift: AnonymizeText.swift:44
    pub fn people_note(count: usize) -> String {
        if count == 1 {
            "One person found on this frame:".to_string()
        } else {
            format!("{count} people found on this frame, numbered left to right:")
        }
    }

    /// The text above the list of frames to check: says plainly when a person may be visible.
    // Swift: AnonymizeText.swift:50
    pub fn checks_text(lines: &[AnonymizeCheckLine]) -> String {
        let base = "The cover is applied. On the frames below the detection was unsure, so look at them and correct the mask where needed. Other frames can be off too.";
        if !lines.iter().any(|l| l.critical) {
            return base.to_string();
        }
        "The cover is applied, but a person was not followed through the whole clip. On the first ranges below the cover is only an enlarged estimate of where they were last seen, so they may be visible: check those first and track the mask on from there. On the other frames the detection was unsure. Other frames can be off too.".to_string()
    }

    // Swift: AnonymizeText.swift:55
    pub fn more_note(more: usize) -> String {
        format!("and {more} more ranges where the detection was unsure.")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_masks::anonymize::AnonymizeBox;
    use sq_core_time::Time;
    use sq_library::library_folder_store::MemorySettings;

    fn person_at(x: f64) -> AnonymizePerson {
        AnonymizePerson {
            label: 1,
            point: sq_core_time::Vec2 { x, y: 0.5 },
            box_: AnonymizeBox { x: x - 0.05, y: 0.2, width: 0.1, height: 0.5 },
            face: None,
        }
    }

    #[test]
    fn labels_say_where_the_person_stands() {
        assert_eq!(AnonymizeText::person_label(0, &person_at(0.1)), "Person 1 (left)");
        assert_eq!(AnonymizeText::person_label(1, &person_at(0.5)), "Person 2 (center)");
        assert_eq!(AnonymizeText::person_label(2, &person_at(0.9)), "Person 3 (right)");
    }

    #[test]
    fn notes_and_choice_memory() {
        assert_eq!(AnonymizeText::people_note(1), "One person found on this frame:");
        assert_eq!(AnonymizeText::people_note(3), "3 people found on this frame, numbered left to right:");
        let calm = AnonymizeCheckLine::new(Time::ZERO, "x", false);
        let critical = AnonymizeCheckLine::new(Time::ZERO, "x", true);
        assert!(!AnonymizeText::checks_text(std::slice::from_ref(&calm)).contains("not followed"));
        assert!(AnonymizeText::checks_text(&[calm, critical]).contains("not followed"));
        let mut d = MemorySettings::default();
        assert_eq!(AnonymizeChoice::remembered(&d), (AnonymizeTarget::Face, AnonymizeCover::Mosaic));
        AnonymizeChoice::new(AnonymizeTarget::Skin, AnonymizeCover::Blur, vec![0]).remember(&mut d);
        assert_eq!(AnonymizeChoice::remembered(&d), (AnonymizeTarget::Skin, AnonymizeCover::Blur));
    }
}
