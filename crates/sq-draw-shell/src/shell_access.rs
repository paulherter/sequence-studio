//! What assistive tech needs from the shell: the open dialog's buttons and rows, a button press, a row edit, and the
//! top-level menu opening. The app host turns these into nodes and actions.

use crate::shell_dialog::{FormField, FormValue};
use crate::shell_host::{ShellCx, ShellHost};
use crate::shell_start::{Element, LESSONS, ShellStartScreen, StartHit};
use sq_draw::{InputEvent, InputModifiers};
use sq_uikit::controls_grid::CGRect;
use sq_uikit::sqdialog_model::SQDialogResponse;

/// The open dialog as assistive tech sees it.
#[derive(Clone, Debug, PartialEq)]
pub struct DialogFacts {
    /// The title.
    pub title: String,
    /// The note under the title.
    pub note: String,
    /// Button titles in response order, with whether each takes a press.
    pub buttons: Vec<(String, bool)>,
    /// The form rows.
    pub fields: Vec<FormField>,
}

/// One control of the start window as assistive tech sees it.
#[derive(Clone, Debug, PartialEq)]
pub struct StartSpot {
    /// Stable per control (the hit it stands for).
    pub key: String,
    /// The shown name.
    pub label: String,
    /// Where a click lands, window points.
    pub rect: CGRect,
    /// A tab that is the open one.
    pub selected: bool,
    /// A project card or row (the recent list).
    pub is_project: bool,
}

fn hit_label(h: &StartHit) -> String {
    match h {
        StartHit::NewProject | StartHit::EmptyNew => "New Project".into(),
        StartHit::OpenOther | StartHit::EmptyOpen => "Open".into(),
        StartHit::Tab(t) => t.raw().into(),
        StartHit::ReopenLast => "Open last project on launch".into(),
        StartHit::Appearance => "Appearance".into(),
        StartHit::Feedback => "Feedback".into(),
        StartHit::Support(e) => format!("{e:?}"),
        StartHit::ReportIssue => "ReportIssue".into(),
        StartHit::ClearSearch => "Clear search".into(),
        StartHit::Sort => "Sort".into(),
        StartHit::Layout(list) => if *list { "List layout" } else { "Grid layout" }.into(),
        StartHit::ContinueOpen => "Continue".into(),
        StartHit::AllFormats => "All formats".into(),
        other => format!("{other:?}"),
    }
}

impl ShellHost {
    /// The controls of the start window (rail, recent list, templates, buttons); empty while it is not up.
    pub fn a11y_start(&mut self, cx: &ShellCx) -> Vec<StartSpot> {
        let Some(mut s) = self.start.take() else { return Vec::new() };
        let root = crate::shell_platform_text::ShellPlatformText::abbreviating_home(&self.start_projects_root());
        let name = if cx.session.is_empty_untitled() { String::new() } else { cx.session.display_name() };
        let mut out = Vec::new();
        {
            let env = self.start_env(&cx.measure, !cx.session.is_empty_untitled(), &root, &name);
            let spot = |hit: &StartHit, label: String, rect: CGRect, selected: bool, is_project: bool| StartSpot {
                key: format!("{hit:?}"),
                label,
                rect,
                selected,
                is_project,
            };
            let tab = s.tab();
            for (rect, hit) in s.rail_spots() {
                let selected = matches!(&hit, StartHit::Tab(t) if *t == tab);
                out.push(spot(&hit, hit_label(&hit), rect, selected, false));
            }
            for e in s.scrolled_elements(&env) {
                match e {
                    Element::Card(entry, r) | Element::ListRow(entry, r) => {
                        let hit = StartHit::Card(entry.path.clone());
                        out.push(spot(&hit, entry.name, r, false, true));
                    }
                    Element::ContinueBox(_, r) => {
                        let hit = StartHit::ContinueOpen;
                        out.push(spot(&hit, hit_label(&hit), ShellStartScreen::open_rect(r), false, false));
                    }
                    Element::Quick(t, r) => {
                        let hit = t.as_ref().map_or(StartHit::AllFormats, |t| StartHit::QuickSize(t.id.clone()));
                        out.push(spot(&hit, t.map_or_else(|| hit_label(&hit), |t| t.name), r, false, false));
                    }
                    Element::TemplateCard(t, r) => {
                        let hit = StartHit::Template(t.id.clone());
                        out.push(spot(&hit, t.name, r, false, false));
                    }
                    Element::Lesson(i, r) if !LESSONS[i].3.is_empty() => {
                        out.push(spot(&StartHit::Lesson(i), LESSONS[i].0.into(), r, false, false));
                    }
                    Element::Button(label, hit, r, _) => out.push(spot(&hit, label, r, false, false)),
                    _ => {}
                }
            }
        }
        self.start = Some(s);
        out
    }

    /// Clicks the start window control `key` names, like a pointer press in its middle; false when there is none.
    pub fn a11y_start_click(&mut self, cx: &mut ShellCx, key: &str) -> bool {
        let Some(spot) = self.a11y_start(cx).into_iter().find(|s| s.key == key) else { return false };
        let (x, y) = ((spot.rect.x + spot.rect.width / 2.0) as f32, (spot.rect.y + spot.rect.height / 2.0) as f32);
        self.handle_start(cx, &InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, 1.0);
        if self.start.is_some() {
            self.handle_start(cx, &InputEvent::MouseUp { x, y }, 1.0);
        }
        true
    }

    /// The open dialog's title, buttons and rows; `None` without a dialog.
    pub fn a11y_dialog(&self) -> Option<DialogFacts> {
        let d = self.dialog()?;
        Some(DialogFacts {
            title: d.message_text.clone(),
            note: d.informative_text.clone(),
            buttons: d.model.buttons.iter().enumerate().map(|(i, b)| (b.title.clone(), d.is_enabled(i))).collect(),
            fields: d.form.as_ref().map(|f| f.a11y_fields()).unwrap_or_default(),
        })
    }

    /// Presses dialog button `i` like a click; false without a dialog or when the button is disabled.
    pub fn a11y_press_button(&mut self, i: usize) -> bool {
        let Some(d) = self.dialog_mut() else { return false };
        if !d.is_enabled(i) || i >= d.model.buttons.len() {
            return false;
        }
        d.press(SQDialogResponse(i as i64));
        true
    }

    /// Sets the dialog row `id` like the user did and runs what the change triggers.
    pub fn a11y_edit_field(&mut self, cx: &mut ShellCx, id: &str, v: FormValue) -> bool {
        let Some(form) = self.dialog_mut().and_then(|d| d.form.as_mut()) else { return false };
        if !form.a11y_edit(id, v) {
            return false;
        }
        let changes = form.take_changes();
        self.route_form_changes(cx, changes);
        true
    }

    /// Opens the top-level menu `i` of the bar.
    pub fn a11y_open_menu(&mut self, i: usize, cx: &ShellCx) {
        self.menu_bar.open_menu(i, None, false, &cx.measure, &mut None);
    }
}
