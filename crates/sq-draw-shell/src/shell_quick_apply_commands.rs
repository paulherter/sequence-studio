// Swift: ShellQuickApplyCommands.swift
//! Window > Quick Apply (Option+Space) and Go to Next Weak Tracking on the shared shell; the Mac AppKit window runs the same
//! session code (`EditorSession::apply_quick_apply`, `MagicTrackHealthCache`).

use crate::keys::ShellKeys;
use crate::shell_host::{ShellCx, ShellHost};
use crate::shell_quick_apply::{QuickApplyEvent, QuickApplyPopup};
use sq_draw::{InputEvent, TextMeasure, UiCx};
use sq_editor_session::{
    AnalysisFlows, MagicTrackHealthCache, PresetApplyModeSetting, QuickApplyAction, QuickApplyItem, QuickApplyMacro,
    QuickApplyModel, QuickApplyOutcome, TransitionDefaults, TransitionEnd, WeakJump,
};
use sq_uikit::controls_grid::CGRect;
use sq_uikit::editor_command::EditorCommand;

impl ShellHost {
    pub fn toggle_quick_apply(&mut self, cx: &mut ShellCx) {
        if self.quick_apply.is_some() {
            self.close_quick_apply();
            return;
        }
        let Some(rows) = cx.hooks.quick_apply_items() else {
            self.flash_raw(AnalysisFlows::unavailable("Quick Apply"));
            return;
        };
        let mut model = QuickApplyModel::new(Vec::new(), Box::new(self.bytes_view()));
        model.set_items(rows);
        let mut popup = QuickApplyPopup::new(model);
        popup.open(CGRect::new(0.0, 0.0, self.size().width, self.size().height));
        self.quick_apply = Some(popup);
    }

    /// The text in the palette's field; `None` while it is closed.
    pub fn quick_apply_query(&self) -> Option<&str> {
        self.quick_apply.as_ref().map(|q| q.model.query())
    }

    /// Whether the Quick Apply palette is showing.
    pub fn quick_apply_open(&self) -> bool {
        self.quick_apply.is_some()
    }

    pub(crate) fn close_quick_apply(&mut self) {
        self.quick_apply = None;
    }

    /// What Return applies to the current selection (the Mac `AppController.applyQuickApply`).
    pub(crate) fn apply_quick_apply(&mut self, cx: &mut ShellCx, item: &QuickApplyItem, end: Option<TransitionEnd>) {
        let presets = cx.hooks.library_presets();
        let edges = cx.hooks.edge_selection();
        let store = self.bytes_view();
        let outcome = cx.session.apply_quick_apply(
            item,
            end,
            &presets,
            edges.as_ref(),
            PresetApplyModeSetting::load(&store),
            &TransitionDefaults::load(&store),
        );
        match outcome {
            QuickApplyOutcome::Status { text, .. } => {
                if let Some(line) = text.filter(|l| !l.is_empty()) {
                    self.flash_raw(line);
                }
            }
            QuickApplyOutcome::Command(c) => {
                self.execute(cx, c);
            }
            QuickApplyOutcome::SaveStackAsPreset => {
                if !cx.hooks.save_stack_as_preset() {
                    self.flash_raw(AnalysisFlows::unavailable("Save Effect Stack as Preset"));
                }
            }
            QuickApplyOutcome::Macro(m) => self.run_quick_apply_macro(cx, &m),
        }
    }

    /// A palette macro: its steps run in order and the undo steps they leave fold into one named step. Voice Chain is a
    /// toggle, so a step that would switch it off is skipped.
    // Match Loudness starts its flow but is not awaited (the Swift `await matchLoudness()`), so its undo step can land
    // after the fold(`ShellFlow` cannot report a finished flow back to the macro yet).
    pub(crate) fn run_quick_apply_macro(&mut self, cx: &mut ShellCx, m: &QuickApplyMacro) {
        let rows = cx.hooks.quick_apply_items().unwrap_or_default();
        let steps: Vec<QuickApplyItem> =
            m.steps.iter().filter_map(|id| rows.iter().find(|r| r.id == *id).cloned()).collect();
        let depth = cx.session.undo_step_depth();
        for step in steps {
            match step.action {
                QuickApplyAction::Command(EditorCommand::VoiceChain) if cx.session.voice_chain_active() => {}
                _ => self.apply_quick_apply(cx, &step, None),
            }
        }
        if cx.session.undo_step_depth() > depth + 1 {
            cx.session.fold_undo(depth, &m.name);
        }
    }

    /// Markers > Go to Next Weak Tracking: the next weak stretch of a tracked Magic mask after the playhead.
    pub fn go_to_next_weak_tracking(&mut self, cx: &mut ShellCx) {
        let Some(cache) = self.magic_health.as_mut() else {
            self.flash_raw(MagicTrackHealthCache::message(WeakJump::NoTrackedMask).unwrap_or("").to_string());
            return;
        };
        let jump = cache.next_weak_start(cx.session.playhead(), cx.session.active_timeline());
        if let WeakJump::Found(t) = jump {
            cx.session.seek(t);
            return;
        }
        if let Some(line) = MagicTrackHealthCache::message(jump) {
            self.flash_raw(line.to_string());
        }
    }

    /// Quick Apply takes the event first while it is up and no menu is open; applies what it reports.
    pub(crate) fn handle_quick_apply(&mut self, cx: &mut ShellCx, e: &InputEvent, scale: f32) -> bool {
        if self.menu_bar.controller.is_open() {
            return false;
        }
        if self.quick_apply.is_none() {
            return false;
        }
        // The palette's own key closes it again; every other key is the palette's (a chord is a text edit of its field or
        // nothing, never an editor shortcut behind it).
        if let InputEvent::KeyDown { key, modifiers } = *e
            && ShellKeys::command(key, modifiers, self.focus, &self.map, self.mac_keys)
                == Some(EditorCommand::QuickApply)
        {
            self.close_quick_apply();
            return true;
        }
        let Some(popup) = self.quick_apply.as_mut() else { return false };
        let can_choose_end = !cx.session.quick_apply_transition_clips(popup.model.selected()).is_empty();
        let took = popup.handle(e, scale, can_choose_end, cx.ui);
        let events = popup.take_events();
        for ev in events {
            match ev {
                QuickApplyEvent::Close => self.close_quick_apply(),
                QuickApplyEvent::Choose(item, end) => self.apply_quick_apply(cx, &item, end),
            }
        }
        took
    }

    pub(crate) fn draw_quick_apply(
        &self,
        c: &mut sq_draw::Canvas,
        t: &sq_draw::DrawTheme,
        m: &TextMeasure,
        cx: &mut UiCx,
    ) {
        if let Some(q) = &self.quick_apply {
            q.draw(c, t, m, cx);
        }
    }
}
