// Swift: ShellFormat.swift
//! Sequence > Change Format… and Duplicate as Format…, translated from the Mac `ChangeFormatSheet` (SQEditorUI
//! ChangeFormatDialog): Format (shape presets + Custom), Frame Size, Clips, Selected Clips when clips are selected, and
//! for the duplicate a Name. The conform itself is the session's (`change_active_format`, `duplicate_active_sequence`).
//! Also the sequence templates and Clip > Pixel Aspect of the Project selection.
//!
//! Mapping: `projectSelection` is the field [`ShellHost::project_selection`] the Project list keeps current, and the template
//! folder the field [`ShellHost::template_folder`]. `projectModel.setPixelAspect` is not used: the session records the step
//! and the app syncs the model from the session (the Swift host preferred the model so both stayed in step).

use crate::shell_dialog::{DialogForm, FormValue, ShellDialog, Tone};
use crate::shell_flows::ShellRoot;
use crate::shell_form::{NumberField, PopupStyle, Row, ShellForm};
use crate::shell_host::ShellHost;
use crate::shell_menu_bar::{PixelAspectRow, PixelAspectRows};
use sq_core_effects::sequence_conform::{AspectPreset, ConformMode, SequenceConform};
use sq_core_model::{BinItemRef, PixelAspect, SequenceFormat};
use sq_core_project::project_template::{ProjectTemplate, TemplateError};
use sq_core_time::Id;
use sq_core_time::SequentialIds;
use sq_editor_session::{EditorSession, PixelAspectChoices};
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};

/// The chosen format and modes of the Change Format sheet.
#[derive(Clone, Debug, PartialEq)]
pub struct ChangeFormatAnswer {
    /// The new format.
    pub format: SequenceFormat,
    /// Mode for the clips.
    pub mode: ConformMode,
    /// Mode for the selected clips; `None` = same as `mode`.
    pub selected_mode: Option<ConformMode>,
    /// The name of a duplicate.
    pub name: String,
}

/// The Change Format form and its answer (Swift `ShellChangeFormat`).
pub struct ShellChangeFormat;

impl ShellChangeFormat {
    /// The Mac sheet's `SQModal.Size.s` card.
    pub const SHEET_WIDTH: f64 = 440.0;

    fn presets() -> &'static [AspectPreset] {
        &SequenceConform::ASPECT_PRESETS
    }

    /// `name == None`: Change Format; otherwise Duplicate as Format with that suggested name.
    pub fn form(current: &SequenceFormat, has_selection: bool, name: Option<&str>) -> ShellForm {
        let presets = Self::presets();
        // Start on the first shape that differs from the current one (the Mac sheet).
        let start = presets.iter().position(|p| p.width * current.height != p.height * current.width).unwrap_or(0);
        let dims = 1.0..=SequenceFormat::MAX_DIMENSION as f64;
        let mut rows: Vec<Row> = Vec::new();
        if let Some(name) = name {
            rows.push(Row::field("name", "Name", name));
        }
        let mut formats: Vec<String> =
            presets.iter().map(|p| format!("{} ({} × {})", p.name, p.width, p.height)).collect();
        formats.push("Custom".to_string());
        rows.push(Row::Popup { id: "format".into(), label: "Format".into(), options: formats, selected: start as i64 });
        // The Mac "Frame Size" row: width × height in two number fields.
        rows.push(Row::Size {
            label: "Frame Size".into(),
            width: NumberField::new("width", presets[start].width as f64, dims.clone()),
            height: NumberField::new("height", presets[start].height as f64, dims),
        });
        let modes: Vec<String> = ConformMode::ALL.iter().map(|m| m.title().to_string()).collect();
        rows.push(Row::Popup {
            id: "clips".into(),
            label: "Clips".into(),
            options: modes.clone(),
            selected: ConformMode::ALL.iter().position(|m| *m == ConformMode::Fill).unwrap_or(0) as i64,
        });
        if has_selection {
            let mut options = vec!["Same as all clips".to_string()];
            options.extend(modes);
            rows.push(Row::Popup { id: "selected".into(), label: "Selected Clips".into(), options, selected: 0 });
        }
        // The Mac sheet has no note row: "Fill crops, Fit shows bars" is only the Clips popup's tooltip.
        let mut form = ShellForm::new(rows);
        // Board: both size fields 1fr of the 260 pt control column, minus the "×" and two gaps = 117 pt.
        form.plain_size.insert("width".to_string());
        form.control_widths.insert("width".to_string(), 75.0);
        form.on_change = Some(Box::new(|form, id, v| match id {
            "format" => {
                let FormValue::Index(i) = v else { return };
                let Some(p) = usize::try_from(*i).ok().and_then(|i| Self::presets().get(i)) else { return };
                form.set("width", FormValue::Number(p.width as f64));
                form.set("height", FormValue::Number(p.height as f64));
            }
            "width" | "height" => {
                let w = form.number("width").map_or(0, |v| v.round() as i64);
                let h = form.number("height").map_or(0, |v| v.round() as i64);
                let at =
                    Self::presets().iter().position(|p| p.width == w && p.height == h).unwrap_or(Self::presets().len());
                form.set("format", FormValue::Index(at as i64));
            }
            _ => {}
        }));
        form
    }

    /// The chosen format and modes; `None` when the size is not a valid frame.
    pub fn answer(form: &dyn DialogForm, current: &SequenceFormat) -> Option<ChangeFormatAnswer> {
        let (w, h) = (form.number("width")?, form.number("height")?);
        if !w.is_finite() || !h.is_finite() {
            return None;
        }
        let mut f = current.clone();
        f.width = w.round() as i64;
        f.height = h.round() as i64;
        if !f.is_valid() || f.width > SequenceFormat::MAX_DIMENSION || f.height > SequenceFormat::MAX_DIMENSION {
            return None;
        }
        let modes = ConformMode::ALL;
        let mode = modes[form.index("clips").unwrap_or(0).clamp(0, modes.len() as i64 - 1) as usize];
        let s = form.index("selected").unwrap_or(0) - 1;
        let selected_mode = usize::try_from(s).ok().and_then(|s| modes.get(s).copied());
        Some(ChangeFormatAnswer { format: f, mode, selected_mode, name: form.text("name").unwrap_or_default() })
    }
}

fn template_options(templates: &[ProjectTemplate]) -> Vec<String> {
    templates.iter().map(|t| format!("{} ({} × {})", t.name, t.format.width, t.format.height)).collect()
}

impl ShellHost {
    fn selected_media_ids(&self) -> Vec<Id> {
        self.project_selection
            .iter()
            .filter_map(|r| if let BinItemRef::Media(id) = r { Some(*id) } else { None })
            .collect()
    }

    /// Clip > Pixel Aspect rows for the Project selection; `None` (rows disabled) unless it is media with a picture.
    pub(crate) fn pixel_aspect_rows(&self, session: &EditorSession) -> Option<PixelAspectRows> {
        let s = PixelAspectChoices::state(session.project(), &self.selected_media_ids())?;
        let file = s
            .shared_file()
            .map_or("From File".to_string(), |a| format!("From File ({})", PixelAspectChoices::ratio_text(&a)));
        let choice = s.shared_choice();
        let mut rows = vec![PixelAspectRow { title: file, aspect: None, checked: s.from_file() }];
        for (title, aspect) in PixelAspectChoices::named() {
            rows.push(PixelAspectRow {
                title: format!("{title} ({})", PixelAspectChoices::ratio_text(&aspect)),
                aspect: Some(aspect),
                checked: choice == Some(aspect),
            });
        }
        let custom = s.custom_choice();
        Some(PixelAspectRows {
            rows,
            custom_title: custom
                .map_or("Custom Ratio…".to_string(), |c| format!("Custom ({})…", PixelAspectChoices::ratio_text(&c))),
            custom_checked: custom.is_some(),
        })
    }

    /// Sets the pixel aspect of the selected media (`None` = From File): one undo step.
    pub(crate) fn set_selection_pixel_aspect(&mut self, session: &mut EditorSession, a: Option<PixelAspect>) {
        let ids = self.selected_media_ids();
        if ids.is_empty() {
            self.flash("Select a clip in the Project panel first.");
            return;
        }
        session.perform("Set Pixel Aspect", None, |p| {
            for id in &ids {
                p.set_pixel_aspect(a, *id);
            }
        });
    }

    /// Built-in templates first, then the saved ones (the Mac `TemplateStore.all`).
    pub(crate) fn all_templates(&mut self) -> Vec<ProjectTemplate> {
        let mut all = ProjectTemplate::built_in();
        if let Some(folder) = &self.template_folder {
            all.extend(folder.load(&mut SequentialIds::default()));
        }
        all
    }

    fn sheet(title: &str, info: &str, form: ShellForm, ok: &str) -> ShellDialog {
        let mut d = ShellDialog::new(title, info);
        d.width = ShellChangeFormat::SHEET_WIDTH;
        d.form = Some(Box::new(form));
        d.add_button(ok, SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        d
    }

    /// Change Format (`duplicate` false) or Duplicate as Format of the active sequence.
    pub async fn change_format<R: ShellRoot + ?Sized>(h: UiRef<R>, duplicate: bool) {
        let Some(Some((d, current))) = h.with(|r| {
            let p = r.shell_parts();
            let Some(tl) = p.session.active_timeline() else {
                p.shell.flash("Open a sequence first.");
                return None;
            };
            let current = tl.format.clone();
            let form = ShellChangeFormat::form(&current, !p.session.selection().is_empty(), duplicate.then_some(""));
            let (title, info) = if duplicate {
                ("Duplicate as Format", "A reframed copy is added.")
            } else {
                ("Change Format", "Every clip is reframed for the new size.")
            };
            Some((Self::sheet(title, info, form, if duplicate { "Duplicate" } else { "Change" }), current))
        }) else {
            return;
        };
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(form) = p.shell.take_answered_form() else { return };
            let Some(a) = ShellChangeFormat::answer(&*form, &current) else {
                p.shell.flash("That frame size is not valid.");
                return;
            };
            p.session.stop_playback();
            if duplicate {
                if p.session.duplicate_active_sequence(&a.format, a.mode, a.selected_mode, &a.name).is_none() {
                    p.shell.flash("Could not duplicate the sequence.");
                }
            } else if a.format != current && !p.session.change_active_format(&a.format, a.mode, a.selected_mode) {
                p.shell.flash("Could not change the format.");
            }
        });
    }

    // MARK: Sequence templates

    /// File > New Sequence from Template…: pick a template (built-in or saved), name the sequence; it opens next to the others.
    pub async fn new_sequence_from_template<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some((d, templates)) = h
            .with(|r| {
                let p = r.shell_parts();
                let templates = p.shell.all_templates();
                if templates.is_empty() {
                    return None;
                }
                // The Mac accessory box: name field over the template popup, both 300 pt, no labels.
                let mut form = ShellForm::new(vec![
                    Row::field("name", "", &p.session.suggested_sequence_name()),
                    Row::Popup {
                        id: "template".into(),
                        label: String::new(),
                        options: template_options(&templates),
                        selected: 0,
                    },
                ]);
                // `newSequenceFromTemplate`: the popup is 24 pt (`Theme.Row.controlLarge`), 8 pt under the field.
                form.popup_styles
                    .insert("template".to_string(), PopupStyle { height: Some(24.0), ..PopupStyle::default() });
                // the Mac box: field drawn 4 pt above the box top, 8 pt gap to the popup
                form.extra_gap_before = [(0, -4.0), (1, -4.0)].into_iter().collect();
                form.begin_editing("name");
                Some((Self::sheet("New Sequence from Template", "", form, "Create"), templates))
            })
            .flatten()
        else {
            return;
        };
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(form) = p.shell.take_answered_form() else { return };
            let Some(t) = form.index("template").and_then(|i| usize::try_from(i).ok()).and_then(|i| templates.get(i))
            else {
                return;
            };
            p.session.stop_playback();
            p.session.add_sequence_from_template(t, form.text("name").as_deref());
        });
    }

    /// Sequence > Save Sequence as Template…: its format, track counts and variants become a template for new projects.
    pub async fn save_sequence_as_template<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some(d)) = h.with(|r| {
            let p = r.shell_parts();
            let Some(tl) = p.session.active_timeline() else {
                p.shell.flash("Open a sequence first.");
                return None;
            };
            // The Mac accessory: one 260 pt field, no label, focused.
            let mut form = ShellForm::new(vec![Row::field("name", "", &tl.name)]);
            form.begin_editing("name");
            Some(Self::sheet(
                "Save Sequence as Template",
                "New projects start with its format, tracks and variants, its titles, emoji and adjustment layers, and this \
                 project’s Looks. Footage and music are left out.",
                form,
                "Save",
            ))
        }) else {
            return;
        };
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(form) = p.shell.take_answered_form() else { return };
            let typed = form.text("name").unwrap_or_default().trim_matches(|c| c == ' ' || c == '\t').to_string();
            if typed.is_empty() {
                return;
            }
            let taken: Vec<String> = p.shell.all_templates().iter().map(|t| t.name.clone()).collect();
            let name = ProjectTemplate::free_name(&typed, &taken);
            let Some(tl) = p.session.active_timeline() else { return };
            let id = ProjectTemplate::user_id(&mut *p.shell.ids);
            let template = ProjectTemplate::capturing(tl, &name, p.session.project().style_kit.clone(), &id);
            let Some(folder) = &p.shell.template_folder else {
                p.shell.present_message(
                    "Could not save the template",
                    "The template folder is not available.",
                    Some(Tone::Error),
                );
                return;
            };
            match folder.save(&template) {
                Ok(()) => p.shell.flash(&SQL10n::format("Saved template “%@”.", &[&name])),
                Err(e) => {
                    // `TemplateError` has no `Error` impl: the detail is its message or the rule that failed.
                    let detail = match e {
                        TemplateError::Io(m) => m,
                        TemplateError::Invalid(i) => i.to_string(),
                    };
                    p.shell.present_message("Could not save the template", &detail, Some(Tone::Error));
                }
            }
        });
    }

    // MARK: Pixel Aspect

    /// Custom Ratio…: width divided by height of one pixel, 0.25 to 4.
    pub async fn custom_selection_pixel_aspect<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some(d)) = h.with(|r| {
            let p = r.shell_parts();
            let ids = p.shell.selected_media_ids();
            if ids.is_empty() {
                p.shell.flash("Select a clip in the Project panel first.");
                return None;
            }
            let first =
                ids.iter().find_map(|id| p.session.project().pixel_aspect_of(*id)).unwrap_or(PixelAspect::square());
            let form = ShellForm::new(vec![Row::field("ratio", "Ratio", &PixelAspectChoices::ratio_text(&first))]);
            let mut d = ShellDialog::new(
                "Custom Pixel Aspect",
                "Width divided by height of one pixel. 1 is square, 2 is a 2x anamorphic lens.",
            );
            d.width = 360.0;
            d.form = Some(Box::new(form));
            d.add_button("OK", SQDialogRole::Default, false);
            d.add_button("Cancel", SQDialogRole::Cancel, false);
            Some(d)
        }) else {
            return;
        };
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(form) = p.shell.take_answered_form() else { return };
            let a = form
                .number("ratio")
                .filter(|v| PixelAspectChoices::RATIO_RANGE.contains(v))
                .and_then(PixelAspectChoices::aspect_from_ratio);
            match a {
                Some(a) => p.shell.set_selection_pixel_aspect(p.session, Some(a)),
                None => p.shell.flash("Type a ratio from 0.25 to 4."),
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Time;

    fn format(w: i64, h: i64) -> SequenceFormat {
        let mut f = SequenceFormat::new(Time::new(1, 30));
        f.width = w;
        f.height = h;
        f
    }

    #[test]
    fn the_sheet_starts_on_the_first_shape_that_differs() {
        let f = ShellChangeFormat::form(&format(1920, 1080), false, None);
        // 9:16 is the first preset and differs from 16:9
        assert_eq!(f.index("format"), Some(0));
        assert_eq!((f.number("width"), f.number("height")), (Some(1080.0), Some(1920.0)));
        assert!(f.text("name").is_none());
        let f = ShellChangeFormat::form(&format(1080, 1920), true, Some(""));
        assert_eq!(f.index("format"), Some(1));
        assert_eq!(f.text("name").as_deref(), Some(""));
    }

    #[test]
    fn picking_a_shape_fills_the_size_and_a_custom_size_picks_custom() {
        let mut f = ShellChangeFormat::form(&format(1920, 1080), false, None);
        f.choose(0, 1);
        assert_eq!((f.number("width"), f.number("height")), (Some(1920.0), Some(1080.0)));
        f.set("width", FormValue::Number(1000.0));
        f.notify("width", FormValue::Number(1000.0));
        assert_eq!(f.index("format"), Some(SequenceConform::ASPECT_PRESETS.len() as i64));
    }

    #[test]
    fn the_answer_reads_size_and_modes_and_refuses_an_invalid_frame() {
        let current = format(1920, 1080);
        let mut f = ShellChangeFormat::form(&current, true, Some("Copy"));
        f.set("clips", FormValue::Index(0));
        f.set("selected", FormValue::Index(2));
        let a = ShellChangeFormat::answer(&f, &current).expect("valid");
        assert_eq!((a.format.width, a.format.height), (1080, 1920));
        assert_eq!((a.mode, a.selected_mode, a.name.as_str()), (ConformMode::Fit, Some(ConformMode::Fill), "Copy"));
        f.set("width", FormValue::Number(0.0));
        assert!(ShellChangeFormat::answer(&f, &current).is_none());
        f.set("width", FormValue::Number(99999.0));
        assert!(ShellChangeFormat::answer(&f, &current).is_none());
    }
}
