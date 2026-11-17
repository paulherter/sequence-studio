// Swift: ShellNewProject.swift
//! File > New Project, translated from the Mac `NewProjectSheet` and `AppController.createProjectFolder` / `createProject`:
//! the same rows (Name, Start from cards, Frame size with W ⇆ H and the aspect, Frame rate, Audio, the Timeline
//! segments, Outside files, Location with Choose…), 260 pt popups in a 623 pt sheet, the footer summary, the same format
//! resolution (`NewProjectInput::resolve`) and the same `<Name>/<Name>.sqproj` + `Files/` layout that never overwrites.
//! Templates: the built-in ones, then the saved ones (`ShellHost::template_folder`), under "Built in" / "Yours". The header
//! has the close button, the footer band the aspect preview and the two summary lines; the size popup shows its aspect key
//! and lists "1080 × 1920" keys under Social / Wide / Cinema, the rate popup its uses ("Film", "PAL").
//!
//! Mapping: the footer closure of the dialog cannot read the form it does not own, so the form's change reaction keeps a
//! shared [`FooterSummary`] current (single UI thread, `Rc<RefCell>`). The Choose… button is answered by the flow while
//! the dialog is open (`shell_live`).

use crate::shell_dialog::{DialogForm, FooterSummary, FormValue, ShellDialog};
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Chip, NumberField, PopupStyle, Row, ShapeCard, ShellForm};
use crate::shell_host::{ShellEvent, ShellHost};
use crate::shell_live::Live;
use sq_core_file::FILE_EXTENSION;
use sq_core_model::{MediaPolicy, OutsideMediaMode, TimelineEditMode};
use sq_core_project::project_template::ProjectTemplate;
use sq_core_project::sequence_format_presets::{NewProjectInput, SequenceFormatPresets};
use sq_editor_session::{EditorSession, StorageLocations};
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use sq_uikit::sqicon::SQIcon;
use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;

/// What the New Project sheet describes.
#[derive(Clone, Debug, PartialEq)]
pub struct ShellNewProjectAnswer {
    /// The project name.
    pub name: String,
    /// The template with the format the sheet resolved.
    pub template: ProjectTemplate,
    /// `None` = the default policy (the start screen's quick create).
    pub mode: Option<OutsideMediaMode>,
    /// The folder the project folder goes into.
    pub location: PathBuf,
    /// `None` = the template's own timeline mode.
    pub edit_mode: Option<TimelineEditMode>,
}

/// The New Project sheet's form and answer (Swift `ShellNewProject`).
pub struct ShellNewProject;

impl ShellNewProject {
    /// `StartTemplatesModel.outsideChoices` (SQEditorUI, not a dependency here).
    pub(crate) const OUTSIDE_CHOICES: [(OutsideMediaMode, &'static str); 4] = [
        (OutsideMediaMode::Ask, "Ask each time"),
        (OutsideMediaMode::Copy, "Copy into project"),
        (OutsideMediaMode::Move, "Move into project"),
        (OutsideMediaMode::Leave, "Leave in place"),
    ];
    /// `NewProjectSheet.baseAudioRates`.
    const AUDIO_RATES: [i64; 3] = [48_000, 44_100, 96_000];
    /// The "Start from" cards of the redesigned sheet: aspect, size and what it is for. The last card is Custom.
    pub(crate) const SHAPES: [(&'static str, i64, i64, &'static str); 4] = [
        ("9:16", 1080, 1920, "TikTok, Reels, Shorts"),
        ("16:9", 1920, 1080, "YouTube, TV"),
        ("1:1", 1080, 1080, "Feed posts"),
        ("4:5", 1080, 1350, "Instagram feed"),
    ];
    /// `NewProjectSheet.rateNotes`: the use of each frame rate, the rate popup's key column.
    const RATE_NOTES: [&'static str; 8] = ["Film NTSC", "Film", "PAL", "NTSC", "Social", "", "", ""];
    /// `NewProjectSheet` metrics: sheet 623 (kit), popups 260, W/H fields 84, Normal | Fast Cut segments 84.
    pub const SHEET_WIDTH: f64 = 623.0;
    const POP_WIDTH: f64 = 260.0;
    const SIZE_FIELD_WIDTH: f64 = 84.0;
    /// The rows under "More options" while it is closed.
    const FOLDED: [&'static str; 1] = ["outside"];

    /// Popup extras of the Mac menus (`templateItems`, `sizeItems`, `rateItems`).
    pub(crate) fn popup_styles() -> BTreeMap<String, PopupStyle> {
        let mut rate =
            PopupStyle { keys: Self::RATE_NOTES.iter().map(|s| (*s).to_string()).collect(), ..PopupStyle::default() };
        // `NewProjectSheet` rows are 28 pt with 28 pt popups.
        rate.height = Some(28.0);
        rate.font_size = Some(12.0);
        let tall = PopupStyle { height: Some(28.0), font_size: Some(12.0), ..PopupStyle::default() };
        [("rate", rate), ("audio", tall.clone()), ("outside", tall)]
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect()
    }

    fn audio_title(rate: i64) -> String {
        if rate % 1000 == 0 { format!("{} kHz", rate / 1000) } else { format!("{:.1} kHz", rate as f64 / 1000.0) }
    }

    /// `NewProjectSheet.aspectText`: "9:16", "16:9", "2.39:1".
    pub(crate) fn aspect_text(width: i64, height: i64) -> String {
        if width <= 0 || height <= 0 {
            return String::new();
        }
        let (mut a, mut b) = (width, height);
        while b != 0 {
            (a, b) = (b, a % b);
        }
        let (rw, rh) = (width / a, height / a);
        if rw <= 32 && rh <= 32 {
            return format!("{rw}:{rh}");
        }
        format!("{:.2}:1", width as f64 / height as f64)
    }

    /// `NewProjectSheet.tildePath`.
    pub(crate) fn tilde_path(path: &Path) -> String {
        sq_os::paths::tilde_here(path)
    }

    /// The card that matches a size: its index, or the Custom card (4) for any other size.
    pub(crate) fn shape_index(width: i64, height: i64) -> usize {
        Self::SHAPES.iter().position(|s| s.1 == width && s.2 == height).unwrap_or(Self::SHAPES.len())
    }

    fn rate_index(t: &ProjectTemplate) -> Option<usize> {
        SequenceFormatPresets::FRAME_RATES.iter().position(|r| r.frame_duration == t.format.frame_duration)
    }

    /// The form for `templates`; `fast_cut` is the Preferences default (`AppSettings.newSequenceEditMode`).
    pub fn form(templates: &[ProjectTemplate], preferred: usize, location: &Path, fast_cut: bool) -> ShellForm {
        let t = templates.get(preferred).unwrap_or(&templates[0]);
        let rate = Self::rate_index(t).unwrap_or(4);
        let audio = Self::AUDIO_RATES.iter().position(|r| *r == t.format.audio_sample_rate).unwrap_or(0);
        let dims = 1.0..=SequenceFormatPresets::MAX_DIMENSION as f64;
        let field = |id: &str, v: i64| NumberField {
            default_value: Some(v as f64),
            ..NumberField::new(id, v as f64, dims.clone())
        };
        let popup = |id: &str, label: &str, options: Vec<String>, selected: usize| Row::Popup {
            id: id.into(),
            label: label.into(),
            options,
            selected: selected as i64,
        };
        let shape = Self::shape_index(t.format.width, t.format.height);
        let mut shape_row =
            Row::segmented("shape", "Start from", &["9:16", "16:9", "1:1", "4:5", "Custom"], shape as i64, 0.0);
        if let Row::Segmented { segment_width, .. } = &mut shape_row {
            *segment_width = 0.0;
        }
        let mut form = ShellForm::new(vec![
            // The first free name in the folder: a taken "Untitled Project" would end in "already exists" on Create.
            Row::field("name", "Name", &free_folder_name(NewProjectInput::DEFAULT_NAME, |n| location.join(n).exists())),
            shape_row,
            Row::Size {
                label: "Frame size".into(),
                width: field("width", t.format.width),
                height: field("height", t.format.height),
            },
            popup(
                "rate",
                "Frame rate",
                SequenceFormatPresets::FRAME_RATES.iter().map(|r| format!("{} fps", r.label)).collect(),
                rate,
            ),
            popup(
                "audio",
                "",
                Self::AUDIO_RATES.iter().map(|r| format!("{} · Stereo", Self::audio_title(*r))).collect(),
                audio,
            ),
            Row::segmented("timeline", "Timeline", &["Normal", "Fast Cut"], i64::from(fast_cut), 84.0),
            Row::buttons("location", "Location", &Self::tilde_path(location), &["Choose\u{2026}"]),
            Row::check("more", "More options", false),
            popup("outside", "Outside files", Self::OUTSIDE_CHOICES.iter().map(|c| SQL10n::string(c.1)).collect(), 0),
        ]);
        form.shape_cards = [(
            "shape".to_string(),
            Self::SHAPES
                .iter()
                .map(|s| ShapeCard { title: s.0.into(), width: s.1, height: s.2 })
                .chain([ShapeCard { title: "Custom".into(), width: 0, height: 0 }])
                .collect(),
        )]
        .into_iter()
        .collect();
        form.disclosures.insert("more".to_string());
        form.beside.insert("audio".to_string(), "Audio".to_string());
        form.pill_hints.insert("width".to_string());
        form.hidden = Self::FOLDED.iter().map(|s| (*s).to_string()).collect();
        form.control_widths.insert("outside".to_string(), Self::POP_WIDTH);
        form.control_widths.insert("rate".to_string(), 120.0);
        form.control_widths.insert("audio".to_string(), 150.0);
        form.control_widths.insert("width".to_string(), Self::SIZE_FIELD_WIDTH);
        // `NewProjectSheet`: 24 pt side padding, 4 pt more before Frame size and Location, a 22 pt name field.
        form.side_pad = 24.0;
        form.label_inset = 2.0; // `NewProjectSheet` labels are NSTextFields: 2 pt cell padding
        // The redesign's rows: 30 high on a 42 pitch (`.fr` min-height 30, margin 12), the name a little further from the cards.
        form.dialog_row = Some(30.0);
        form.extra_gap_before = (1..=7).map(|i| (i, 8.0)).collect();
        // Measured against the kit frame (card 623 x 502): Name 92 pt under the card top, rows 42 apart, the Frame size row 1 closer.
        form.extra_gap_before.extend([(0, 9.0), (3, 7.0), (7, 11.0)]);
        form.field_heights.insert("name".to_string(), 22.0);
        form.dialog_field_font_size = 12.0;
        form.dialog_font_size = Some(12.0);
        form.labeled_field_bleed = false;
        form.popup_styles = Self::popup_styles();
        form.chips.insert("location".to_string(), Chip { icon: SQIcon::Folder, button_width: 92.0 });
        form.swap_between.insert("width".to_string());
        form.set("location", FormValue::Text(location.to_string_lossy().into_owned()));
        Self::refresh(&mut form, templates);
        // A card fills W and H; typed sizes pick their card or Custom.
        let templates = templates.to_vec();
        form.on_change = Some(Box::new(move |form, id, v| {
            if let ("shape", FormValue::Index(i)) = (id, v)
                && let Some(s) = usize::try_from(*i).ok().and_then(|i| Self::SHAPES.get(i))
            {
                form.set("width", FormValue::Number(s.1 as f64));
                form.set("height", FormValue::Number(s.2 as f64));
            }
            Self::refresh(form, &templates);
        }));
        form
    }

    /// `NewProjectSheet.refresh`: the template summary, the size preset and the aspect hint follow the choices.
    fn refresh(form: &mut ShellForm, _templates: &[ProjectTemplate]) {
        let w = form.number("width").unwrap_or(0.0).round() as i64;
        let h = form.number("height").unwrap_or(0.0).round() as i64;
        // The card follows the size fields (a typed size picks its card or Custom), like the preset of Sequence Settings.
        let shape = Self::shape_index(w, h);
        form.set("shape", FormValue::Index(shape as i64));
        let rate = usize::try_from(form.index("rate").unwrap_or(-1))
            .ok()
            .and_then(|r| SequenceFormatPresets::FRAME_RATES.get(r))
            .map_or("", |r| r.label);
        let uses = Self::SHAPES.get(shape).map_or("Your own size", |s| s.3);
        form.hints.insert("shape".to_string(), format!("{w} × {h}, {rate} fps. {uses}."));
        form.hints.insert("width".to_string(), Self::aspect_text(w, h));
        let fast = form.index("timeline") == Some(1);
        form.hints.insert(
            "timeline".to_string(),
            (if fast { "Gaps close by themselves." } else { "Delete leaves a gap." }).to_string(),
        );
        // "More options" unfolds the outside-files rule.
        let open = form.bool("more") == Some(true);
        form.hidden = if open { BTreeSet::new() } else { Self::FOLDED.iter().map(|s| (*s).to_string()).collect() };
    }

    /// The footer of the Mac sheet: "1080 × 1920 · 30 fps", "9:16 · 48 kHz Stereo · Normal timeline" and the aspect box.
    pub fn summary(form: &dyn DialogForm, templates: &[ProjectTemplate]) -> FooterSummary {
        let Some(a) = Self::answer(form, templates) else {
            return FooterSummary { line1: String::new(), line2: String::new(), aspect: 9.0 / 16.0 };
        };
        let f = &a.template.format;
        let rate = SequenceFormatPresets::FRAME_RATES
            .iter()
            .find(|r| r.frame_duration == f.frame_duration)
            .map_or("", |r| r.label);
        FooterSummary {
            line1: format!("{} × {} · {rate} fps", f.width, f.height),
            line2: format!(
                "{} · {} Stereo · {} timeline",
                Self::aspect_text(f.width, f.height),
                Self::audio_title(f.audio_sample_rate),
                if a.edit_mode == Some(TimelineEditMode::Magnetic) { "Fast Cut" } else { "Normal" }
            ),
            aspect: if f.height > 0 { f.width as f64 / f.height as f64 } else { 1.0 },
        }
    }

    /// A folder picked with Choose….
    pub(crate) fn set_location(form: &mut dyn DialogForm, path: &Path) {
        form.set_value("location", FormValue::Text(path.to_string_lossy().into_owned()));
        form.set_row_detail("location", &Self::tilde_path(path));
    }

    /// `NewProjectSheet.create`: the answer the form describes.
    pub fn answer(form: &dyn DialogForm, templates: &[ProjectTemplate]) -> Option<ShellNewProjectAnswer> {
        let rounded = |id: &str| form.number(id).unwrap_or(0.0).round() as i64;
        // The template with this size (a 16:9 card brings Horizontal); another size keeps the first template.
        let size_of = |t: &ProjectTemplate| (t.format.width, t.format.height);
        let mut template = templates
            .iter()
            .find(|t| size_of(t) == (rounded("width"), rounded("height")))
            .or(templates.first())?
            .clone();
        let audio = form.index("audio").unwrap_or(0).clamp(0, Self::AUDIO_RATES.len() as i64 - 1) as usize;
        template.format = NewProjectInput::resolve(
            &template.format,
            rounded("width"),
            rounded("height"),
            usize::try_from(form.index("rate").unwrap_or(-1)).unwrap_or(usize::MAX),
            Some(Self::AUDIO_RATES[audio]),
        );
        let path = form.text("location").unwrap_or_default().trim_matches([' ', '\t']).to_string();
        if path.is_empty() {
            return None;
        }
        let outside = form.index("outside").unwrap_or(0).clamp(0, Self::OUTSIDE_CHOICES.len() as i64 - 1) as usize;
        Some(ShellNewProjectAnswer {
            name: NewProjectInput::name(&form.text("name").unwrap_or_default()),
            template,
            mode: Some(Self::OUTSIDE_CHOICES[outside].0),
            location: PathBuf::from(path),
            edit_mode: Some(if form.index("timeline") == Some(1) {
                TimelineEditMode::Magnetic
            } else {
                TimelineEditMode::Normal
            }),
        })
    }

    /// The sheet: the form, the footer band and the buttons.
    pub(crate) fn dialog(templates: &[ProjectTemplate], location: &Path, fast_cut: bool) -> ShellDialog {
        let mut form = Self::form(templates, 0, location, fast_cut);
        let shared = Rc::new(RefCell::new(Self::summary(&form, templates)));
        let inner = form.on_change.take();
        let (cell, all) = (Rc::clone(&shared), templates.to_vec());
        form.on_change = Some(Box::new(move |form, id, v| {
            if let Some(f) = &inner {
                f(form, id, v);
            }
            *cell.borrow_mut() = Self::summary(form, &all);
        }));
        let mut d = ShellDialog::new("New project", "Settings can change later in Sequence Settings.");
        d.width = Self::SHEET_WIDTH;
        d.form = Some(Box::new(form));
        d.footer_summary = Some(Box::new(move || shared.borrow().clone()));
        d.close_button = true;
        d.heading_font_size = Some(15.0);
        d.add_button("Create", SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        d.button_widths = [(0, 104.0), (1, 76.0)].into_iter().collect();
        d.button_hints = [(0, "\u{23CE}".to_string())].into_iter().collect();
        d
    }
}

/// `MediaManagement.sanitized`: a file-system safe folder name: no path separators or colons, no leading dots, never empty.
// shortcut: local copy of the Swift helper; delete it when `MediaManagement` lands in sq-core-project.
fn sanitized(name: &str) -> String {
    let s = name.replace(['/', ':'], "-");
    let s = s.trim_matches(|c: char| c.is_whitespace());
    let s = s.trim_start_matches('.');
    if s.is_empty() { NewProjectInput::DEFAULT_NAME.to_string() } else { s.to_string() }
}

/// `MediaManagement.freeFolderName`: the first free folder name "Reel", "Reel 2", ...
fn free_folder_name(base: &str, exists: impl Fn(&str) -> bool) -> String {
    let clean = sanitized(base);
    let mut name = clean.clone();
    let mut n = 1;
    while exists(&name) {
        n += 1;
        name = format!("{clean} {n}");
    }
    name
}

impl ShellHost {
    /// `AppController.quickCreate`: a size tile or a template card makes "Untitled Project" (a free name) in the projects folder;
    /// a user template asks for the video's name first.
    pub async fn quick_create<R: ShellRoot + ?Sized>(h: UiRef<R>, template_id: String, ask_name: bool) {
        if !Self::confirm_discard_changes(h.clone()).await {
            return;
        }
        let Some(Some((template, parent))) = h.with(|r| {
            let shell = &mut *r.shell_parts().shell;
            let template = shell.all_templates().into_iter().find(|t| t.id == template_id)?;
            let parent = StorageLocations::load(&*shell.defaults).projects_root();
            // A failure shows when the project is created.
            let _ = std::fs::create_dir_all(&parent);
            Some((template, parent))
        }) else {
            return;
        };
        let free = |base: &str| free_folder_name(base, |n| parent.join(n).exists());
        let mut name = free(NewProjectInput::DEFAULT_NAME);
        if ask_name || template.id.starts_with("user-") {
            let mut d = ShellDialog::new(
                "Name this video",
                &SQL10n::format("From “%@”. Its folder is created in the projects folder.", &[&template.name]),
            );
            d.form = Some(Box::new(ShellForm::new(vec![Row::field("name", "Name", &name)])));
            d.add_button("Create", SQDialogRole::Default, false);
            d.add_button("Cancel", SQDialogRole::Cancel, false);
            if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
                return;
            }
            let typed = h
                .with(|r| r.shell_parts().shell.take_answered_form().and_then(|f| f.text("name")))
                .flatten()
                .unwrap_or_default();
            let typed = typed.trim_matches(|c: char| c.is_whitespace());
            name = free(if typed.is_empty() { &name } else { typed });
        }
        let answer = ShellNewProjectAnswer { name, template, mode: None, location: parent, edit_mode: None };
        let _ = h.with(|r| {
            let p = r.shell_parts();
            p.shell.create_project(p.session, &answer);
        });
    }

    /// The sheet over the start window for the `--pose new-project` shot; nothing answers it.
    pub fn present_sample_new_project(&mut self) -> bool {
        let templates = self.all_templates();
        let location = self.new_project_start_folder();
        drop(self.present(ShellNewProject::dialog(&templates, &location, false)));
        true
    }

    /// `createProjectFolder`: the form, then `create_project`.
    pub async fn new_project_form<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        if !Self::confirm_discard_changes(h.clone()).await {
            return;
        }
        let Some((d, templates)) = h.with(|r| {
            let shell = &mut *r.shell_parts().shell;
            let templates = shell.all_templates();
            let fast_cut = sq_editor_session::AppSettings::load(&*shell.defaults).new_sequence_edit_mode
                == TimelineEditMode::Magnetic;
            (ShellNewProject::dialog(&templates, &shell.new_project_start_folder(), fast_cut), templates)
        }) else {
            return;
        };
        let Some(mut live) = Self::present_live(&h, d) else { return };
        loop {
            match live.next(&h).await {
                None => return,
                Some(Live::Changed(changes)) => {
                    if !changes.iter().any(|(id, _)| id == "location") {
                        continue;
                    }
                    let Some(ask) = h.with(|r| r.shell_parts().files.choose_folder(&SQL10n::string("Choose"))) else {
                        return;
                    };
                    if let Some(url) = ask.await {
                        let _ = h.with(|r| {
                            if let Some(form) = r.shell_parts().shell.dialog_mut().and_then(|d| d.form.as_mut()) {
                                ShellNewProject::set_location(&mut **form, &url);
                            }
                        });
                    }
                }
                Some(Live::Answered(a)) => {
                    if a != SQDialogResponse::FIRST {
                        return;
                    }
                    break;
                }
            }
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(form) = p.shell.take_answered_form() else { return };
            let Some(answer) = ShellNewProject::answer(&*form, &templates) else { return };
            if let Err(e) = std::fs::create_dir_all(&answer.location) {
                p.shell.present_error("Could not create the location folder", &e);
                return;
            }
            p.shell.new_project_location = Some(answer.location.clone());
            p.shell.create_project(p.session, &answer);
        });
    }

    /// `createProject`: `<parent>/<Name>/<Name>.sqproj` and `Files/` from the template, then opens it. Nothing existing
    /// is overwritten.
    pub fn create_project(&mut self, session: &mut EditorSession, a: &ShellNewProjectAnswer) {
        let project_name = sanitized(&a.name);
        // `MediaManagement.layout`
        let folder = a.location.join(&project_name);
        let project_file = folder.join(&project_name).with_extension(FILE_EXTENSION);
        let files_folder = folder.join("Files");
        if folder.exists() {
            self.present_message(
                &SQL10n::format("A folder named “%@” already exists there", &[&project_name]),
                &SQL10n::string("Choose another name or location. Nothing was changed."),
                None,
            );
            return;
        }
        if let Err(e) = std::fs::create_dir_all(&files_folder) {
            self.present_error("Could not create the project", &e);
            return;
        }
        let mut p = a.template.make_project(&project_name, &mut *self.ids);
        if let Some(mode) = a.edit_mode
            && !p.timelines.is_empty()
        {
            p.timelines[0].set_edit_mode_stored(mode);
        }
        p.media_policy = Some(MediaPolicy {
            outside: a.mode,
            watch_folder: Some(session.media_policy_defaults().watch_folder),
            ..MediaPolicy::default()
        });
        session.new_project(p);
        match session.save_as(&project_file) {
            Ok(()) => {
                self.note_recent(&project_file);
                self.emit(ShellEvent::ProjectChanged);
            }
            Err(e) => self.present_error("Could not create the project", &*e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::Rig;
    use sq_core_time::Time;
    use sq_uikit::editor_command::EditorCommand;

    fn dir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("sq-shell-{name}-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&d);
        d
    }

    /// Kit frame `New Project`: the card is 623 x 502 pt (+-2); the 640 x 400 window still clamps it.
    #[test]
    fn the_new_project_card_matches_the_kit_size_and_still_fits_a_small_window() {
        let templates = ProjectTemplate::built_in();
        let mut d = ShellNewProject::dialog(&templates, &dir("np-size"), false);
        d.layout(sq_uikit::controls_grid::CGRect::new(0.0, 0.0, 1440.0, 900.0), &crate::tests::measure());
        let card = d.card();
        assert!((card.width - 623.0).abs() <= 2.0, "width {}", card.width);
        assert!((card.height - 502.0).abs() <= 2.0, "height {}", card.height);
        let small = sq_uikit::controls_grid::CGRect::new(0.0, 0.0, 640.0, 400.0);
        d.layout(small, &crate::tests::measure());
        let card = d.card();
        assert!(card.min_x() >= 0.0 && card.max_x() <= 640.0 && card.min_y() >= 0.0 && card.max_y() <= 400.0);
    }

    #[test]
    fn the_new_project_name_starts_on_the_first_free_one() {
        let templates = ProjectTemplate::built_in();
        let root = dir("np-free");
        let _ = std::fs::remove_dir_all(root.join("Untitled Project"));
        let _ = std::fs::remove_dir_all(root.join("Untitled Project 2"));
        let name = |root: &Path| ShellNewProject::form(&templates, 0, root, false).text("name");
        assert_eq!(name(&root).as_deref(), Some("Untitled Project"));
        std::fs::create_dir_all(root.join("Untitled Project")).expect("taken");
        assert_eq!(name(&root).as_deref(), Some("Untitled Project 2"));
        std::fs::create_dir_all(root.join("Untitled Project 2")).expect("taken");
        assert_eq!(name(&root).as_deref(), Some("Untitled Project 3"));
    }

    #[test]
    fn new_project_form_resolves_the_format_like_the_mac_sheet() {
        let templates = ProjectTemplate::built_in();
        let mut form = ShellNewProject::form(&templates, 0, &dir("np1"), false);
        form.set("name", FormValue::Text("  Trip  ".into()));
        form.choose(1, 1); // the 16:9 card fills W and H
        form.set("rate", FormValue::Index(2)); // 25 fps
        form.set("audio", FormValue::Index(1)); // 44.1 kHz
        form.set("timeline", FormValue::Index(1)); // Fast Cut
        form.set("outside", FormValue::Index(3)); // Leave in place
        let a = ShellNewProject::answer(&form, &templates).expect("answer");
        assert_eq!(a.name, "Trip");
        assert_eq!((a.template.format.width, a.template.format.height), (1920, 1080));
        assert_eq!(a.template.format.frame_duration, Time::new(1, 25));
        assert_eq!(a.template.format.audio_sample_rate, 44_100);
        assert_eq!((a.edit_mode, a.mode), (Some(TimelineEditMode::Magnetic), Some(OutsideMediaMode::Leave)));
        assert_eq!(a.location, dir("np1"));
    }

    #[test]
    fn size_hints_and_footer_follow_the_choices() {
        let templates = ProjectTemplate::built_in();
        let mut form = ShellNewProject::form(&templates, 0, &dir("np2"), true);
        form.choose(1, 0); // the 9:16 card
        assert_eq!((form.number("width"), form.number("height")), (Some(1080.0), Some(1920.0)));
        assert_eq!(form.hints.get("width").map(String::as_str), Some("9:16"));
        form.set("width", FormValue::Number(1920.0));
        form.set("height", FormValue::Number(1080.0));
        form.notify("width", FormValue::Number(1920.0));
        assert_eq!(form.index("shape"), Some(1)); // the 16:9 card
        form.choose(5, 1);
        assert_eq!(form.index("timeline"), Some(1));
        let sum = ShellNewProject::summary(&form, &templates);
        assert!(sum.line2.ends_with("Stereo · Fast Cut timeline"));
        assert!(sum.line1.starts_with("1920 × 1080 · ") && sum.line1.ends_with(" fps"));
        assert!((sum.aspect - 16.0 / 9.0).abs() < 0.001);
        let other = dir("np2").join("Elsewhere");
        ShellNewProject::set_location(&mut form, &other);
        assert_eq!(ShellNewProject::answer(&form, &templates).map(|a| a.location), Some(other));
    }

    #[test]
    fn choosing_a_template_takes_its_rate() {
        let templates = ProjectTemplate::built_in();
        let mut form = ShellNewProject::form(&templates, 0, &dir("np3"), false);
        form.set("rate", FormValue::Index(0));
        form.choose(1, 1);
        let a = ShellNewProject::answer(&form, &templates).expect("answer");
        assert_eq!(a.template.id, templates[1].id, "a 16:9 card brings the Horizontal template");
        assert!(form.index("template").is_none() && form.index("size").is_none(), "Template and Size preset are gone");
    }

    #[test]
    fn the_shape_card_follows_the_size_fields_and_sets_them() {
        let templates = ProjectTemplate::built_in();
        let mut form = ShellNewProject::form(&templates, 0, &dir("np4"), false);
        assert_eq!(form.index("shape"), Some(0), "the first template is 9:16");
        form.choose(1, 1); // the 16:9 card fills W and H
        assert_eq!((form.number("width"), form.number("height")), (Some(1920.0), Some(1080.0)));
        assert!(
            form.hints
                .get("shape")
                .is_some_and(|h| h.starts_with("1920 × 1080, ") && h.ends_with(" fps. YouTube, TV."))
        );
        form.set("width", FormValue::Number(1234.0));
        form.notify("width", FormValue::Number(1234.0));
        assert_eq!(form.index("shape"), Some(4), "an odd size is the Custom card");
        assert!(form.hints.get("shape").is_some_and(|h| h.ends_with("Your own size.")));
        assert_eq!(ShellNewProject::shape_index(1080, 1350), 3);
    }

    #[test]
    fn the_timeline_hint_follows_the_segment_and_more_options_unfolds_one_row() {
        let templates = ProjectTemplate::built_in();
        let mut form = ShellNewProject::form(&templates, 0, &dir("np5"), false);
        assert_eq!(form.hints.get("timeline").map(String::as_str), Some("Delete leaves a gap."));
        form.choose(5, 1);
        assert_eq!(form.hints.get("timeline").map(String::as_str), Some("Gaps close by themselves."));
        assert_eq!(form.hidden.len(), 1, "outside files is folded");
        form.set("more", FormValue::Bool(true));
        form.notify("more", FormValue::Bool(true));
        assert!(form.hidden.is_empty());
        form.set("more", FormValue::Bool(false));
        form.notify("more", FormValue::Bool(false));
        assert_eq!(form.hidden.len(), 1);
    }

    #[test]
    fn a_folded_row_still_answers_with_its_default() {
        let templates = ProjectTemplate::built_in();
        let form = ShellNewProject::form(&templates, 0, &dir("np6"), false);
        let a = ShellNewProject::answer(&form, &templates).expect("answer");
        assert_eq!(a.mode, Some(OutsideMediaMode::Ask));
        assert_eq!(a.template.id, templates[0].id);
    }

    #[test]
    fn more_options_hold_only_outside_files() {
        assert_eq!(ShellNewProject::FOLDED, ["outside"]);
        let names: Vec<&str> = ShellNewProject::OUTSIDE_CHOICES.iter().map(|c| c.1).collect();
        assert_eq!(names, ["Ask each time", "Copy into project", "Move into project", "Leave in place"]);
    }

    #[test]
    fn new_project_popups_are_28_points_like_the_mac_sheet() {
        let styles = ShellNewProject::popup_styles();
        for id in ["rate", "audio", "outside"] {
            assert_eq!(styles[id].height, Some(28.0), "{id}");
        }
        assert_eq!(styles["rate"].keys[2], "PAL");
    }

    #[test]
    fn aspect_text_names_common_shapes_and_falls_back_to_a_ratio() {
        assert_eq!(ShellNewProject::aspect_text(1080, 1920), "9:16");
        assert_eq!(ShellNewProject::aspect_text(4096, 1716), "2.39:1");
        assert_eq!(ShellNewProject::aspect_text(0, 10), "");
    }

    #[test]
    fn create_project_makes_the_folder_and_never_overwrites() {
        let rig = Rig::new();
        let root = dir("np4");
        let templates = ProjectTemplate::built_in();
        let mut form = ShellNewProject::form(&templates, 0, &root, false);
        form.set("name", FormValue::Text("Holiday".into()));
        form.set("timeline", FormValue::Index(1));
        let a = ShellNewProject::answer(&form, &templates).expect("answer");
        rig.with(|r| r.shell.create_project(&mut r.session, &a));
        let file = root.join("Holiday/Holiday.sqproj");
        assert!(file.exists());
        assert!(root.join("Holiday/Files").is_dir());
        assert_eq!(rig.with(|r| r.session.file_url().map(Path::to_path_buf)), Some(file.clone()));
        assert_eq!(
            rig.with(|r| r.session.project().timelines.first().map(|t| t.edit_mode())),
            Some(TimelineEditMode::Magnetic)
        );
        assert!(rig.with(|r| r.shell.recents.entries().iter().any(|e| e.path.ends_with("Holiday.sqproj"))));
        // Same name again: nothing is replaced.
        rig.with(|r| r.session.close_project());
        rig.with(|r| r.shell.create_project(&mut r.session, &a));
        assert!(rig.with(|r| r.session.file_url().is_none()));
        assert!(rig.has_dialog());
    }

    #[test]
    fn creating_a_project_opens_it_and_the_start_screen_follows() {
        let rig = Rig::new();
        let root = dir("np6");
        let templates = ProjectTemplate::built_in();
        let mut form = ShellNewProject::form(&templates, 0, &root, false);
        form.set("name", FormValue::Text("Opened".into()));
        let a = ShellNewProject::answer(&form, &templates).expect("answer");
        rig.cx(|h, cx| h.show_start(cx));
        rig.with(|r| r.shell.create_project(&mut r.session, &a));
        // No input event and no layout in between: the follow step alone moves the start screen on.
        rig.cx(|h, cx| h.sync_start(cx));
        assert!(!rig.with(|r| r.shell.is_start_shown()));
        assert_eq!(rig.with(|r| r.shell.start_open_name.clone()), "Opened");
        assert!(
            rig.with(|r| r.session.project().timelines.iter().all(|t| t.tracks.iter().all(|tr| tr.clips().is_empty())))
        );
    }

    #[test]
    fn the_new_project_command_asks_for_the_form() {
        let rig = Rig::new();
        let root = dir("np5");
        rig.with(|r| r.shell.new_project_location = Some(root.clone()));
        assert!(rig.execute(EditorCommand::NewProject));
        rig.run_flows();
        let (title, location) = rig.with(|r| {
            let d = r.shell.dialog();
            (d.map(|d| d.message_text.clone()), d.and_then(|d| d.form.as_ref().and_then(|f| f.text("location"))))
        });
        assert_eq!(title.as_deref(), Some("New project"));
        assert_eq!(location, Some(root.to_string_lossy().into_owned()));
        rig.answer(SQDialogResponse::SECOND);
        assert!(!rig.has_dialog());
    }

    /// The sheet opens in the stored Projects folder, not the built-in default: an offscreen run's own folder (or a
    /// folder chosen in Preferences) is what File > New Project suggests before anything was picked in the sheet.
    #[test]
    fn the_new_project_form_starts_in_the_stored_projects_folder() {
        let rig = Rig::new();
        let root = dir("np6");
        rig.with(|r| {
            let mut stored = StorageLocations::load(&*r.shell.defaults);
            stored.projects_folder = Some(root.clone());
            stored.save(&mut *r.shell.defaults);
            assert_eq!(r.shell.new_project_location, None);
        });
        assert!(rig.execute(EditorCommand::NewProject));
        rig.run_flows();
        let location = rig.with(|r| r.shell.dialog().and_then(|d| d.form.as_ref().and_then(|f| f.text("location"))));
        assert_eq!(location, Some(root.to_string_lossy().into_owned()));
        rig.answer(SQDialogResponse::SECOND);
    }

    #[test]
    fn a_free_folder_name_counts_up() {
        let taken = ["Reel", "Reel 2"];
        assert_eq!(free_folder_name("Reel", |n| taken.contains(&n)), "Reel 3");
        assert_eq!(sanitized("  ..a/b:c "), "a-b-c");
        assert_eq!(sanitized("..."), "Untitled Project");
    }
}
