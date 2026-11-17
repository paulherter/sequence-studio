//! Sequence format changes (conform) and the pixel aspect choices of the media settings.

use std::collections::BTreeMap;
use std::rc::Rc;

use sq_core_effects::sequence_conform::{ConformMode, ProjectSequenceConformExt, TextBlock};

use sq_core_model::{Clip, MediaRef, PixelAspect, Project, SequenceFormat};
use sq_core_time::Id;
use sq_uikit::sqmenu_model::SQMenuItem;

use crate::EditorSession;

impl EditorSession {
    /// The laid-out size of a text clip, for conforming text to another frame.
    // shortcut: the text layout engine (`TextGenerator`, `TextLayout`) is not in a crate the session depends on yet, so
    // text clips conform by their frame scale only; upgrade when sq-text's layout joins the session's dependencies.
    // Swift: EditorSession+Format.swift:9
    pub fn conform_text_block(_clip: &Clip) -> Option<TextBlock> {
        None
    }

    /// The mode the user picked for the selected clips, per clip (empty without a pick).
    // Swift: EditorSession+Format.swift:21
    pub fn conform_overrides(&self, selected_mode: Option<ConformMode>) -> BTreeMap<Id, ConformMode> {
        match selected_mode {
            Some(m) => self.selection.iter().map(|id| (*id, m)).collect(),
            None => BTreeMap::new(),
        }
    }

    /// Changes the active sequence's format, conforming its clips: one undo step. False when nothing changed.
    // Swift: EditorSession+Format.swift:28
    pub fn change_active_format(
        &mut self,
        format: &SequenceFormat,
        mode: ConformMode,
        selected_mode: Option<ConformMode>,
    ) -> bool {
        let Some(tl) = self.active_timeline().filter(|t| t.format != *format) else { return false };
        let id = tl.id;
        let overrides = self.conform_overrides(selected_mode);
        self.try_perform("Change Format", None, |p| {
            p.change_format(id, format, mode, &overrides, &Self::conform_text_block)
        })
        .is_ok()
    }

    /// Duplicates the active sequence in another format and opens the copy.
    // Swift: EditorSession+Format.swift:42
    pub fn duplicate_active_sequence(
        &mut self,
        format: &SequenceFormat,
        mode: ConformMode,
        selected_mode: Option<ConformMode>,
        name: &str,
    ) -> Option<Id> {
        let id = self.active_timeline_id?;
        let overrides = self.conform_overrides(selected_mode);
        let typed = name.trim();
        let lease = self.lend_ids();
        let ids = &mut lease.source();
        let mut new_id = None;
        let result = self.try_perform("Duplicate as Format", None, |p| {
            new_id = Some(p.duplicate_sequence(
                id,
                format,
                mode,
                &overrides,
                (!typed.is_empty()).then_some(typed),
                &Self::conform_text_block,
                &mut *ids,
            )?);
            Ok::<(), sq_core_model::EditError>(())
        });
        self.return_ids(lease);
        result.ok()?;
        let new_id = new_id?;
        self.set_active_timeline(new_id);
        Some(new_id)
    }
}

/// What the media settings show for the pixel aspect of one or more media items.
// Swift: EditorSession+Format.swift:63
pub enum PixelAspectChoices {}

/// The pixel aspects the files carry and the overrides chosen for them.
// Swift: EditorSession+Format.swift:64
#[derive(Clone, Debug, PartialEq)]
pub struct PixelAspectState {
    // Swift: EditorSession+Format.swift:65
    pub files: Vec<PixelAspect>,
    // Swift: EditorSession+Format.swift:66
    pub overrides: Vec<Option<PixelAspect>>,
}

impl PixelAspectState {
    // Swift: EditorSession+Format.swift:67
    pub fn new(files: Vec<PixelAspect>, overrides: Vec<Option<PixelAspect>>) -> PixelAspectState {
        PixelAspectState { files, overrides }
    }

    /// The one aspect all files share, if they do.
    // Swift: EditorSession+Format.swift:70
    pub fn shared_file(&self) -> Option<PixelAspect> {
        let first = *self.files.first()?;
        self.files.iter().all(|f| *f == first).then_some(first)
    }

    /// No override is set: every item reads its file.
    // Swift: EditorSession+Format.swift:71
    pub fn from_file(&self) -> bool {
        self.overrides.iter().all(Option::is_none)
    }

    /// The one override all items share (none when mixed or unset).
    // Swift: EditorSession+Format.swift:73
    pub fn shared_choice(&self) -> Option<PixelAspect> {
        let first = *self.overrides.first()?;
        self.overrides.iter().all(|o| *o == first).then_some(first).flatten()
    }

    /// The shared override when it is not one of the named choices.
    // Swift: EditorSession+Format.swift:75
    pub fn custom_choice(&self) -> Option<PixelAspect> {
        self.shared_choice().filter(|c| !PixelAspectChoices::named().iter().any(|(_, a)| a == c))
    }
}

impl PixelAspectChoices {
    /// The rows of the Pixel Aspect submenu. `pick(None)` = From File; `custom` opens the ratio sheet.
    // Swift: PixelAspectChoices+Menu.swift:7
    pub fn items(s: &PixelAspectState, pick: Rc<dyn Fn(Option<PixelAspect>)>, custom: Rc<dyn Fn()>) -> Vec<SQMenuItem> {
        let row = |title: String, checked: bool, action: Rc<dyn Fn()>| {
            let mut item = SQMenuItem::new(&title);
            item.is_checked = checked;
            item.action = Some(action);
            item
        };
        let file_text =
            s.shared_file().map_or("From File".to_string(), |a| format!("From File ({})", Self::ratio_text(&a)));
        let on_file = Rc::clone(&pick);
        let mut rows = vec![row(file_text, s.from_file(), Rc::new(move || on_file(None))), SQMenuItem::separator()];
        let choice = s.shared_choice();
        for (title, aspect) in Self::named() {
            let on_pick = Rc::clone(&pick);
            rows.push(row(
                format!("{title} ({})", Self::ratio_text(&aspect)),
                choice == Some(aspect),
                Rc::new(move || on_pick(Some(aspect))),
            ));
        }
        let custom_choice = s.custom_choice();
        let title = match custom_choice {
            Some(c) => format!("Custom ({})\u{2026}", Self::ratio_text(&c)),
            None => "Custom Ratio\u{2026}".to_string(),
        };
        rows.push(SQMenuItem::separator());
        rows.push(row(title, custom_choice.is_some(), custom));
        rows
    }

    /// The state for these media items; `None` when one has no video info or the list is empty.
    // Swift: EditorSession+Format.swift:79
    pub fn state(project: &Project, media: &[Id]) -> Option<PixelAspectState> {
        let videos: Vec<_> = media
            .iter()
            .filter_map(|id| project.media(*id).and_then(|m: &MediaRef| m.info.as_ref()?.video.as_ref()))
            .collect();
        if media.is_empty() || videos.len() != media.len() {
            return None;
        }
        Some(PixelAspectState::new(
            videos.iter().map(|v| v.pixel_aspect).collect(),
            videos.iter().map(|v| v.pixel_aspect_override).collect(),
        ))
    }

    /// The named choices: the common video shapes first, then the anamorphic presets.
    // Swift: EditorSession+Format.swift:86
    pub fn named() -> Vec<(String, PixelAspect)> {
        let p = |n, d| PixelAspect::new(n, d).unwrap_or(PixelAspect::square());
        let mut rows: Vec<(String, PixelAspect)> = vec![
            ("Square".into(), PixelAspect::square()),
            ("DV NTSC 4:3".into(), p(10, 11)),
            ("DV NTSC 16:9".into(), p(40, 33)),
            ("DV PAL 4:3".into(), p(59, 54)),
            ("DV PAL 16:9".into(), p(118, 81)),
            ("HD 1440 / HDV".into(), p(4, 3)),
        ];
        for a in PixelAspect::PRESETS {
            if !rows.iter().any(|(_, r)| *r == a) {
                rows.push((format!("Anamorphic {}", Self::ratio_text(&a)), a));
            }
        }
        rows
    }

    /// "1.33", "0.909": the ratio with trailing zeros dropped.
    // Swift: EditorSession+Format.swift:100
    pub fn ratio_text(a: &PixelAspect) -> String {
        let v = a.value();
        let s = if v < 1.0 { format!("{v:.3}") } else { format!("{v:.2}") };
        if !s.contains('.') {
            return s;
        }
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    }

    // Swift: EditorSession+Format.swift:108
    pub fn title(a: &PixelAspect) -> String {
        match Self::named().into_iter().find(|(_, r)| r == a) {
            Some((title, _)) => format!("{title} ({})", Self::ratio_text(a)),
            None => format!("Custom ({})", Self::ratio_text(a)),
        }
    }

    /// The ratios a custom value may take.
    // Swift: EditorSession+Format.swift:114
    pub const RATIO_RANGE: std::ops::RangeInclusive<f64> = 0.25..=4.0;

    /// A pixel aspect from a typed ratio (four decimals); `None` for a value that is not a positive number.
    // Swift: EditorSession+Format.swift:117
    pub fn aspect_from_ratio(v: f64) -> Option<PixelAspect> {
        if !v.is_finite() || v <= 0.0 {
            return None;
        }
        PixelAspect::new((v * 10_000.0).round() as i64, 10_000)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::SessionDeps;
    use sq_core_time::SequentialIds;

    fn aspect(n: i64, d: i64) -> PixelAspect {
        PixelAspect::new(n, d).expect("aspect")
    }

    #[test]
    fn the_pixel_aspect_menu_checks_from_file_or_the_shared_choice() {
        use std::cell::RefCell;
        let picked: Rc<RefCell<Vec<Option<PixelAspect>>>> = Rc::default();
        let log = Rc::clone(&picked);
        let pick: Rc<dyn Fn(Option<PixelAspect>)> = Rc::new(move |a| log.borrow_mut().push(a));
        let from_file = PixelAspectState::new(vec![PixelAspect::square()], vec![None]);
        let rows = PixelAspectChoices::items(&from_file, Rc::clone(&pick), Rc::new(|| {}));
        assert_eq!(rows.len(), PixelAspectChoices::named().len() + 4);
        assert!(rows[0].is_checked && rows[0].title == "From File (1)");
        assert!(rows.iter().skip(2).all(|r| !r.is_checked));
        if let Some(action) = rows[0].action.as_ref() {
            action();
        }
        let wide = PixelAspect::new(4, 3).unwrap_or(PixelAspect::square());
        let chosen = PixelAspectState::new(vec![PixelAspect::square()], vec![Some(wide)]);
        let rows = PixelAspectChoices::items(&chosen, pick, Rc::new(|| {}));
        assert!(!rows[0].is_checked && rows.iter().filter(|r| r.is_checked).count() == 1);
        assert_eq!(*picked.borrow(), vec![None]);
    }

    #[test]
    fn ratio_text_drops_trailing_zeros() {
        assert_eq!(PixelAspectChoices::ratio_text(&PixelAspect::square()), "1");
        assert_eq!(PixelAspectChoices::ratio_text(&aspect(4, 3)), "1.33");
        assert_eq!(PixelAspectChoices::ratio_text(&aspect(10, 11)), "0.909");
        assert_eq!(PixelAspectChoices::ratio_text(&aspect(2, 1)), "2");
    }

    #[test]
    fn titles_name_known_shapes_and_custom_ones() {
        assert_eq!(PixelAspectChoices::title(&PixelAspect::square()), "Square (1)");
        assert_eq!(PixelAspectChoices::title(&aspect(10, 11)), "DV NTSC 4:3 (0.909)");
        assert_eq!(PixelAspectChoices::title(&aspect(7, 5)), "Custom (1.4)");
        assert_eq!(PixelAspectChoices::named()[0].0, "Square");
        assert!(PixelAspectChoices::aspect_from_ratio(0.0).is_none());
        assert!(PixelAspectChoices::aspect_from_ratio(f64::NAN).is_none());
        assert_eq!(PixelAspectChoices::aspect_from_ratio(1.5), Some(aspect(15000, 10000)));
        assert!(PixelAspectChoices::RATIO_RANGE.contains(&1.0));
    }

    #[test]
    fn state_reads_shared_file_and_choice() {
        let sq = PixelAspect::square();
        let s = PixelAspectState::new(vec![sq, sq], vec![None, None]);
        assert_eq!((s.shared_file(), s.from_file(), s.shared_choice()), (Some(sq), true, None));
        let mixed = PixelAspectState::new(vec![sq, aspect(4, 3)], vec![Some(aspect(7, 5)), Some(aspect(7, 5))]);
        assert_eq!((mixed.shared_file(), mixed.from_file()), (None, false));
        assert_eq!(mixed.custom_choice(), Some(aspect(7, 5)));
        let named = PixelAspectState::new(vec![sq], vec![Some(aspect(4, 3))]);
        assert_eq!(named.custom_choice(), None);
        assert!(PixelAspectChoices::state(&Project::new(Id::from_u128(1), "P", Vec::new(), Vec::new()), &[]).is_none());
    }

    #[test]
    fn change_format_is_one_undo_step_and_duplicate_opens_the_copy() {
        let mut ids = SequentialIds::default();
        let dir = std::env::temp_dir().join(format!("sq-es01-format-{}", std::process::id()));
        let mut s = EditorSession::new(EditorSession::make_untitled(&mut ids), SessionDeps::headless(dir));
        s.ids = Box::new(sq_core_time::SequentialIds::default());
        for _ in 0..1000 {
            s.ids.next_id();
        }
        let mut f = s.active_timeline().map(|t| t.format.clone()).expect("format");
        assert!(!s.change_active_format(&f, ConformMode::Fit, None));
        f.width = 1080;
        f.height = 1920;
        assert!(s.change_active_format(&f, ConformMode::Fit, None));
        assert_eq!(s.undo_name(), Some("Change Format"));
        let same = s.active_timeline().map(|t| t.format.width);
        assert_eq!(same, Some(1080));
        f.width = 1280;
        f.height = 720;
        let first = s.active_timeline_id().expect("first");
        let copy = s.duplicate_active_sequence(&f, ConformMode::Fit, None, "  Wide ").expect("copy");
        assert_eq!(s.active_timeline_id(), Some(copy));
        assert_eq!(s.active_timeline().map(|t| t.format.width), Some(1280));
        assert_ne!(Some(copy), Some(first));
        assert_eq!(s.undo_name(), Some("Duplicate as Format"));
    }
}
