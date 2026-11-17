// Swift: Color/ColorGraphMenus.swift
//! The Color Graph's menus (Step, LUT, add, insert, mixer, canvas), shared by the Pro page and the portable Steps graph
//! (`ColorStepsDraw`). The platform supplies what it shows itself: the file chooser, renaming, Tidy Up (which also refits
//! the view) and the color decision import.
//!
//! Swift's menu items captured the model; `SQMenuItem` actions are `Rc<dyn Fn()>`, so an item here pushes a
//! [`GraphMenuCommand`] into the shared [`MenuSink`] and the host runs `ColorGraphMenus::apply` after the menu closes.

use super::color_inspector_model::{ColorInspectorModel, LUTChoice};
use super::color_inspector_model_graph::GraphLUTSlot;
use sq_core_model::StepKind;
use sq_core_time::Id;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::cell::RefCell;
use std::rc::Rc;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LUTTarget {
    GraphInput,
    GraphOutput,
    Step,
}

/// What a menu row does when it is picked.
#[derive(Clone, Debug, PartialEq)]
pub enum GraphMenuCommand {
    SetLut(LUTTarget, Option<LUTChoice>),
    /// Opens the host's file chooser; the picked path comes back as `SetLut(target, Some(LUTChoice::file(path)))`.
    ChooseLutFile(LUTTarget),
    AddStepBefore(Id),
    AddStep {
        after: Option<Id>,
        kind: StepKind,
    },
    AddStepAtEnd(StepKind),
    Rename(Id),
    ToggleSelectedSteps,
    SetStepEnabled(Id, bool),
    Duplicate(Id),
    SetStepKind(Id, StepKind),
    TidyUp,
    MoveBy(Id, i64),
    ClearStepLut(Id),
    ImportDecision(Id),
    ResetStep(Id),
    DeleteSelectedSteps,
    RemoveMixer(Id),
    ResetMixerPosition(Id),
}

/// The commands menu rows queued, oldest first (ownership: shared by the rows of one open menu and the host that drains it
/// when the menu closes; single thread, see PORTING-NOTES).
pub struct MenuSink<C = GraphMenuCommand>(Rc<RefCell<Vec<C>>>);

impl<C> Clone for MenuSink<C> {
    fn clone(&self) -> MenuSink<C> {
        MenuSink(Rc::clone(&self.0))
    }
}

impl<C> Default for MenuSink<C> {
    fn default() -> MenuSink<C> {
        MenuSink(Rc::new(RefCell::new(Vec::new())))
    }
}

impl<C> MenuSink<C> {
    pub fn new() -> MenuSink<C> {
        MenuSink::default()
    }

    pub fn push(&self, c: C) {
        self.0.borrow_mut().push(c);
    }

    pub fn drain(&self) -> Vec<C> {
        std::mem::take(&mut *self.0.borrow_mut())
    }
}

/// What the host must do after `ColorGraphMenus::apply` (the parts only the platform can do).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GraphMenuHostRequest {
    ChooseLutFile(LUTTarget),
    Rename(Id),
    TidyUp,
    ImportDecision(Id),
}

pub struct ColorGraphMenus {
    pub sink: MenuSink<GraphMenuCommand>,
    /// The platform has a .cube / .3dl file chooser (Choose File… is disabled otherwise).
    pub can_choose_lut_file: bool,
    pub can_rename: bool,
    /// The platform refits the view on Tidy Up: `apply` hands it back instead of calling the model.
    pub custom_tidy_up: bool,
    pub can_import_decision: bool,
}

impl ColorGraphMenus {
    pub fn new(sink: MenuSink<GraphMenuCommand>) -> ColorGraphMenus {
        ColorGraphMenus {
            sink,
            can_choose_lut_file: false,
            can_rename: false,
            custom_tidy_up: false,
            can_import_decision: false,
        }
    }

    fn row(&self, title: &str, c: GraphMenuCommand) -> SQMenuItem {
        let sink = self.sink.clone();
        let mut i = SQMenuItem::new(title);
        i.action = Some(Rc::new(move || sink.push(c.clone())));
        i
    }

    fn enabled(mut i: SQMenuItem, on: bool) -> SQMenuItem {
        i.is_enabled = on;
        i
    }

    fn checked(mut i: SQMenuItem, on: bool) -> SQMenuItem {
        i.is_checked = on;
        i
    }

    /// Runs a queued command on the model; the host-only parts come back as a request.
    pub fn apply(&self, model: &mut ColorInspectorModel, c: GraphMenuCommand) -> Option<GraphMenuHostRequest> {
        match c {
            GraphMenuCommand::SetLut(t, choice) => {
                match t {
                    LUTTarget::GraphInput => model.set_graph_lut(GraphLUTSlot::Input, choice.as_ref()),
                    LUTTarget::GraphOutput => model.set_graph_lut(GraphLUTSlot::Output, choice.as_ref()),
                    LUTTarget::Step => {
                        if let Some(id) = model.selected_step() {
                            model.set_step_lut(id, choice.as_ref());
                        }
                    }
                }
                None
            }
            GraphMenuCommand::ChooseLutFile(t) => Some(GraphMenuHostRequest::ChooseLutFile(t)),
            GraphMenuCommand::AddStepBefore(id) => {
                model.add_step_before(id);
                None
            }
            GraphMenuCommand::AddStep { after, kind } => {
                model.add_step(after, kind);
                None
            }
            GraphMenuCommand::AddStepAtEnd(kind) => {
                model.add_step_at_end(kind);
                None
            }
            GraphMenuCommand::Rename(id) => Some(GraphMenuHostRequest::Rename(id)),
            GraphMenuCommand::ToggleSelectedSteps => {
                model.toggle_selected_steps();
                None
            }
            GraphMenuCommand::SetStepEnabled(id, on) => {
                model.set_step_enabled(id, on);
                None
            }
            GraphMenuCommand::Duplicate(id) => {
                model.duplicate_step(id);
                None
            }
            GraphMenuCommand::SetStepKind(id, k) => {
                model.set_step_kind(id, k);
                None
            }
            GraphMenuCommand::TidyUp => {
                if self.custom_tidy_up {
                    Some(GraphMenuHostRequest::TidyUp)
                } else {
                    model.tidy_up_steps();
                    None
                }
            }
            GraphMenuCommand::MoveBy(id, d) => {
                model.move_step_by(id, d);
                None
            }
            GraphMenuCommand::ClearStepLut(id) => {
                model.set_step_lut(id, None);
                None
            }
            GraphMenuCommand::ImportDecision(id) => Some(GraphMenuHostRequest::ImportDecision(id)),
            GraphMenuCommand::ResetStep(id) => {
                model.reset_step(id);
                None
            }
            GraphMenuCommand::DeleteSelectedSteps => {
                model.remove_selected_steps();
                None
            }
            GraphMenuCommand::RemoveMixer(head) => {
                model.remove_mixer(head);
                None
            }
            GraphMenuCommand::ResetMixerPosition(head) => {
                model.set_mixer_position(head, None);
                None
            }
        }
    }

    /// The entries of a LUT menu (None, Automatic for the In LUT, the library and recents, Choose File…).
    pub fn lut_items(&self, model: &ColorInspectorModel, t: LUTTarget) -> Vec<SQMenuItem> {
        let current: Option<LUTChoice> = match t {
            LUTTarget::GraphInput => model.graph_lut_choice(GraphLUTSlot::Input),
            LUTTarget::GraphOutput => model.graph_lut_choice(GraphLUTSlot::Output),
            LUTTarget::Step => model.selected_step().and_then(|s| model.step_lut_choice(s)),
        };
        let mut items: Vec<SQMenuItem> = Vec::new();
        if t == LUTTarget::GraphInput {
            let i = self.row("Automatic", GraphMenuCommand::SetLut(t, Some(LUTChoice::automatic())));
            let i = i.with_help("The Simple rules: the camera LUT or the built-in conversion");
            items.push(Self::checked(i, current.as_ref() == Some(&LUTChoice::automatic())));
        }
        let none_title = if t == LUTTarget::GraphInput { "None (built-in conversion)" } else { "None" };
        items.push(Self::checked(self.row(none_title, GraphMenuCommand::SetLut(t, None)), current.is_none()));
        let looks = model.look_choices();
        if !looks.is_empty() {
            items.push(SQMenuItem::separator());
            items.push(SQMenuItem::header("Library"));
            for c in looks.iter().take(20) {
                let i = self.row(&c.name, GraphMenuCommand::SetLut(t, Some(c.clone())));
                items.push(Self::checked(i, current.as_ref() == Some(c)));
            }
        }
        items.push(SQMenuItem::separator());
        items.push(Self::enabled(
            self.row("Choose File…", GraphMenuCommand::ChooseLutFile(t)),
            self.can_choose_lut_file,
        ));
        items
    }

    /// The Step's menu: everything about one Step (kind, effects and LUT live here and in the inspector).
    pub fn step_menu_items(&self, model: &ColorInspectorModel, id: Id) -> Vec<SQMenuItem> {
        let Some(g) = model.graph() else { return Vec::new() };
        let Some(i) = g.steps().iter().position(|s| s.id == id) else { return Vec::new() };
        let s = &g.steps()[i];
        let many = model.selected_steps.len() > 1 && model.selected_steps.contains(&id);
        let n = model.selected_steps.len();
        let selected_all_on = g.steps().iter().filter(|x| model.selected_steps.contains(&x.id)).all(|x| x.enabled);
        let bypass_title = if many {
            if selected_all_on {
                SQL10n::format("Bypass %@ Steps", &[&n.to_string()])
            } else {
                SQL10n::format("Turn On %@ Steps", &[&n.to_string()])
            }
        } else if s.enabled {
            "Bypass".to_string()
        } else {
            "Turn On".to_string()
        };
        let bypass_cmd =
            if many { GraphMenuCommand::ToggleSelectedSteps } else { GraphMenuCommand::SetStepEnabled(id, !s.enabled) };
        let mut joins = SQMenuItem::new("Joins As");
        joins.is_enabled = !many;
        joins.submenu = Some(
            [StepKind::Serial, StepKind::Parallel, StepKind::Layer]
                .into_iter()
                .map(|k| {
                    let r = self.row(&Self::kind_title(k), GraphMenuCommand::SetStepKind(id, k));
                    Self::checked(Self::enabled(r, i > 0 || k == StepKind::Serial), s.kind == k)
                })
                .collect(),
        );
        let mut lut = SQMenuItem::new("LUT");
        lut.is_enabled = !many;
        lut.submenu = Some(self.lut_items(model, LUTTarget::Step));
        let delete_title = if many {
            SQL10n::format("Delete %@ Steps", &[&n.to_string()])
        } else if g.steps().len() > 1 {
            "Delete Step".to_string()
        } else {
            "Delete Step (resets the last one)".to_string()
        };
        vec![
            self.row("Add Step Before", GraphMenuCommand::AddStepBefore(id)).with_help("Serial, in front of this Step"),
            self.row("Add Serial Step", GraphMenuCommand::AddStep { after: Some(id), kind: StepKind::Serial }),
            self.row("Add Parallel Step", GraphMenuCommand::AddStep { after: Some(id), kind: StepKind::Parallel }),
            self.row("Add Layer Step", GraphMenuCommand::AddStep { after: Some(id), kind: StepKind::Layer }),
            SQMenuItem::separator(),
            Self::enabled(self.row("Rename…", GraphMenuCommand::Rename(id)), !many && self.can_rename),
            self.row(&bypass_title, bypass_cmd),
            Self::enabled(self.row("Duplicate", GraphMenuCommand::Duplicate(id)), !many),
            SQMenuItem::separator(),
            joins,
            Self::enabled(
                self.row("Tidy Up", GraphMenuCommand::TidyUp),
                g.steps().iter().any(|x| x.position.is_some()),
            ),
            SQMenuItem::separator(),
            Self::enabled(self.row("Move Left", GraphMenuCommand::MoveBy(id, -1)), !many && i > 0),
            Self::enabled(self.row("Move Right", GraphMenuCommand::MoveBy(id, 1)), !many && i + 1 < g.steps().len()),
            SQMenuItem::separator(),
            lut,
            Self::enabled(self.row("Clear LUT", GraphMenuCommand::ClearStepLut(id)), !many && s.lut.is_some()),
            Self::enabled(
                self.row("Import Color Decision…", GraphMenuCommand::ImportDecision(id))
                    .with_help("ASC CDL (.cdl, .cc, .ccc) or CMX EDL"),
                !many && self.can_import_decision,
            ),
            SQMenuItem::separator(),
            Self::enabled(
                self.row("Reset Step", GraphMenuCommand::ResetStep(id)),
                !many && !sq_core_color::ColorStepExt::is_neutral(s),
            ),
            self.row(&delete_title, GraphMenuCommand::DeleteSelectedSteps),
        ]
    }

    pub fn kind_title(k: StepKind) -> String {
        match k {
            StepKind::Serial => "Serial (after the one before)",
            StepKind::Parallel => "Parallel (averaged)",
            StepKind::Layer => "Layer (over the result)",
        }
        .to_string()
    }

    /// The "+" menu: where and how a new Step joins.
    pub fn add_menu_items(&self, model: &ColorInspectorModel) -> Vec<SQMenuItem> {
        let sel = model.selected_step();
        vec![
            self.row("Serial Step", GraphMenuCommand::AddStep { after: sel, kind: StepKind::Serial }),
            self.row("Parallel Step", GraphMenuCommand::AddStep { after: sel, kind: StepKind::Parallel }),
            self.row("Layer Step", GraphMenuCommand::AddStep { after: sel, kind: StepKind::Layer }),
            SQMenuItem::separator(),
            self.row("Serial Step at the End", GraphMenuCommand::AddStepAtEnd(StepKind::Serial)),
        ]
    }

    /// A "+" on a wire: a new Step behind the column that ends there.
    pub fn insert_menu_items(&self, id: Id) -> Vec<SQMenuItem> {
        vec![
            SQMenuItem::header("Insert here"),
            self.row("Serial Step", GraphMenuCommand::AddStep { after: Some(id), kind: StepKind::Serial }),
            self.row("Parallel Step", GraphMenuCommand::AddStep { after: Some(id), kind: StepKind::Parallel }),
            self.row("Layer Step", GraphMenuCommand::AddStep { after: Some(id), kind: StepKind::Layer }),
        ]
    }

    /// Right-click on a mixer box.
    pub fn mixer_menu_items(&self, model: &ColorInspectorModel, head: Id) -> Vec<SQMenuItem> {
        vec![
            self.row("Delete Mixer", GraphMenuCommand::RemoveMixer(head))
                .with_help("Its Steps become serial Steps in a row"),
            Self::enabled(
                self.row("Reset Position", GraphMenuCommand::ResetMixerPosition(head)),
                model.step(head).is_some_and(|s| s.mixer_position.is_some()),
            ),
        ]
    }

    /// Right-click on empty canvas.
    pub fn canvas_menu_items(&self, model: &ColorInspectorModel) -> Vec<SQMenuItem> {
        let mut v = self.add_menu_items(model);
        v.push(SQMenuItem::separator());
        v.push(self.row("Tidy Up", GraphMenuCommand::TidyUp));
        v
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::SequentialIds;

    fn pro() -> (ColorInspectorModel, ColorGraphMenus) {
        let mut m = ColorInspectorModel::new(Box::new(SequentialIds::default()));
        m.start_empty_graph();
        m.take_events();
        (m, ColorGraphMenus::new(MenuSink::new()))
    }

    fn run(menus: &ColorGraphMenus, items: &[SQMenuItem], title: &str) {
        let Some(item) = items.iter().find(|i| i.title == title) else { return };
        if let Some(a) = &item.action {
            a();
        }
        let _ = menus;
    }

    #[test]
    fn the_add_menu_runs_its_commands_on_the_model() {
        let (mut m, menus) = pro();
        let items = menus.add_menu_items(&m);
        run(&menus, &items, "Parallel Step");
        for c in menus.sink.drain() {
            assert!(menus.apply(&mut m, c).is_none());
        }
        assert_eq!(m.graph().map(|g| g.steps().len()), Some(2));
    }

    #[test]
    fn the_step_menu_disables_what_does_not_apply() {
        let (m, menus) = pro();
        let Some(id) = m.selected_step() else { return };
        let items = menus.step_menu_items(&m, id);
        let by = |t: &str| items.iter().find(|i| i.title == t);
        assert_eq!(by("Rename…").map(|i| i.is_enabled), Some(false));
        assert_eq!(by("Move Left").map(|i| i.is_enabled), Some(false));
        assert_eq!(by("Move Right").map(|i| i.is_enabled), Some(false));
        assert_eq!(by("Tidy Up").map(|i| i.is_enabled), Some(false));
        assert_eq!(by("Reset Step").map(|i| i.is_enabled), Some(false));
        assert_eq!(by("Duplicate").map(|i| i.is_enabled), Some(true));
        assert!(by("Delete Step (resets the last one)").is_some());
        let joins = by("Joins As").and_then(|i| i.submenu.clone()).unwrap_or_default();
        assert_eq!(joins.len(), 3);
        assert!(joins[0].is_checked && joins[0].is_enabled && !joins[1].is_enabled);
    }

    #[test]
    fn host_only_rows_come_back_as_requests() {
        let (mut m, mut menus) = pro();
        let Some(id) = m.selected_step() else { return };
        assert_eq!(menus.apply(&mut m, GraphMenuCommand::Rename(id)), Some(GraphMenuHostRequest::Rename(id)));
        assert_eq!(
            menus.apply(&mut m, GraphMenuCommand::ChooseLutFile(LUTTarget::Step)),
            Some(GraphMenuHostRequest::ChooseLutFile(LUTTarget::Step))
        );
        assert_eq!(menus.apply(&mut m, GraphMenuCommand::TidyUp), None);
        menus.custom_tidy_up = true;
        assert_eq!(menus.apply(&mut m, GraphMenuCommand::TidyUp), Some(GraphMenuHostRequest::TidyUp));
    }

    #[test]
    fn the_lut_menu_marks_the_current_choice() {
        let (mut m, menus) = pro();
        m.set_graph_lut(GraphLUTSlot::Input, Some(&LUTChoice::automatic()));
        let items = menus.lut_items(&m, LUTTarget::GraphInput);
        assert_eq!(items[0].title, "Automatic");
        assert!(items[0].is_checked && !items[1].is_checked);
        assert_eq!(items[1].title, "None (built-in conversion)");
        let choose = items.iter().find(|i| i.title == "Choose File…");
        assert_eq!(choose.map(|i| i.is_enabled), Some(false));
    }

    #[test]
    fn kind_titles() {
        assert_eq!(ColorGraphMenus::kind_title(StepKind::Layer), "Layer (over the result)");
    }
}
