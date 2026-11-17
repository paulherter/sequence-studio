//! The panel-host commands of the shell's handler chain (Swift `shell.commandHandlers` and the chained `shell.onCommand` of
//! `MonitorCardHost`, `SourceHost`, `GraphicsHost`, `InspectorHost`, `ProjectListView`). [`crate::timeline_commands::TimelineHooks`]
//! answers `ShellHooks::command_handler` by queueing the command; the root runs it here against the host that owns the state.

use super::AppRoot;
use sq_app_shell::HostCx;
use sq_core_edit::timeline_match_frame::TimelineMatchFrameExt;
use sq_editor_session::EditAction;
use sq_inspector_ui::ec::effect_controls_model::property::StopwatchOutcome;
use sq_uikit::editor_command::EditorCommand as C;
use sq_uikit::panel_id::PanelID;

impl AppRoot {
    /// Runs the panel action of an Edit > Delete / Select All with the Graphics or Captions panel focused (Swift
    /// `SharedUIController+ShellHooks` `editActions`).
    pub(super) fn run_edit_action(&mut self, cx: &mut HostCx, a: EditAction) {
        match a {
            EditAction::DeleteGraphicsLayers | EditAction::SelectAllGraphicsLayers => {
                let Some(g) = self.graphics.as_mut() else { return };
                g.panel().with_session(cx.session, |p| {
                    if a == EditAction::DeleteGraphicsLayers {
                        p.delete_selected_layers(cx.ui);
                    } else {
                        p.select_all(cx.ui);
                    }
                });
            }
            EditAction::DeleteCaptions => {
                cx.session.delete_selected_captions();
            }
            EditAction::FallThrough
            | EditAction::Swallow
            | EditAction::EffectControls
            | EditAction::DeleteProjectItems
            | EditAction::PasteMedia => {}
        }
    }

    /// Runs one queued panel-host command; the status line it left, if any.
    pub(super) fn run_host_command(&mut self, cx: &mut HostCx, c: C) -> Option<String> {
        match c {
            C::NewBin => {
                self.dock.show(PanelID::Project);
                self.dock.set_focused(Some(PanelID::Project));
                self.project.new_folder(cx);
                None
            }
            C::SetPosterFrame | C::ClearPosterFrame => {
                let at = self.source.as_ref().and_then(|s| {
                    let core = s.core();
                    core.media_id().map(|m| (m, core.current_time()))
                });
                self.project.poster_frame(cx, c == C::ClearPosterFrame, at)
            }
            C::MatchFrame => self.match_frame(cx),
            C::ReverseMatchFrame => self.reverse_match_frame(cx),
            C::SelectLayerAbove | C::SelectLayerBelow => {
                let up = c == C::SelectLayerAbove;
                let stepped = self.graphics.as_mut().is_some_and(|g| {
                    g.panel().with_session(cx.session, |p| {
                        let h = &mut p.host;
                        h.editor.step_layer_selection(&mut h.session, up)
                    })
                });
                (!stepped).then(|| "No Graphic with layers is open.".to_string())
            }
            C::AddKeyframe => {
                let model = &mut self.inspector.controls().model;
                let Some(p) = model.focused_property.clone() else {
                    return Some("Select a property in Effect Controls first.".to_string());
                };
                (model.add_key_at_playhead(&p) == StopwatchOutcome::Unavailable)
                    .then(|| "There is already a keyframe here, or the playhead is outside the clip.".to_string())
            }
            C::EaseLinear | C::EasyEase | C::EaseIn | C::EaseOut => {
                use sq_core_time::{EaseSide, EasingCurve};
                let (curve, side) = match c {
                    C::EaseLinear => (EasingCurve::linear(), EaseSide::Both),
                    C::EasyEase => (EasingCurve::ease_in_out(), EaseSide::Both),
                    C::EaseIn => (EasingCurve::ease_in(), EaseSide::In),
                    _ => (EasingCurve::ease_out(), EaseSide::Out),
                };
                let model = &mut self.inspector.controls().model;
                if !model.selection().is_empty() {
                    model.apply_easing(&curve, side);
                    None
                } else {
                    // No keys selected: the speed point at the playhead.
                    (!cx.session.ease_speed_point_at_playhead(&curve, side)).then(|| {
                        "Select keyframes in Effect Controls, or put the playhead on a speed point.".to_string()
                    })
                }
            }
            C::ToggleHoldInterpolation => {
                let model = &mut self.inspector.controls().model;
                if model.selection().is_empty() {
                    Some("Select keyframes in Effect Controls first.".to_string())
                } else {
                    model.toggle_hold();
                    None
                }
            }
            // Only queued while Controls has the focus (`ShellHooks::edit_effect_controls`): the selected keys, effect or
            // mask. The model's edit reaches the session now, as one undo step.
            C::Delete | C::RippleDelete | C::Cut | C::Copy | C::Paste => {
                let model = &mut self.inspector.controls().model;
                match c {
                    C::Cut => model.cut_focused(),
                    C::Copy => {
                        model.copy_focused();
                    }
                    C::Paste => {
                        model.paste_focused();
                    }
                    _ => model.delete_selection_or_effect(),
                }
                self.inspector.route_model(cx);
                None
            }
            C::EditDynamicZoom => (!self.monitor.toggle_dynamic_zoom_edit(cx.session))
                .then(|| "Select a video clip and put the playhead on it to edit its zoom.".to_string()),
            _ => None,
        }
    }

    /// Show in Source (F): the media under the playhead opens in the Source monitor, parked on the same frame.
    fn match_frame(&mut self, cx: &mut HostCx) -> Option<String> {
        let hit =
            cx.session.active_timeline().and_then(|t| t.match_frame(cx.session.playhead(), cx.session.selection()));
        let Some(m) = hit else { return Some("No clip with media under the playhead to match.".to_string()) };
        let Some(source) = &mut self.source else {
            return Some("The Source monitor is not available here yet.".to_string());
        };
        if source.open_at(cx, m.media, m.source_time) {
            self.dock.show(PanelID::SourceMonitor);
            self.dock.set_focused(Some(PanelID::SourceMonitor));
        }
        None
    }

    /// Show in Timeline (Shift+R): the playhead goes to the frame the Source monitor shows, inside the clip that uses it.
    fn reverse_match_frame(&mut self, cx: &mut HostCx) -> Option<String> {
        let Some((id, at)) =
            self.source.as_ref().and_then(|s| s.core().media_id().map(|m| (m, s.core().current_time())))
        else {
            return Some("Open a clip in the Source monitor first.".to_string());
        };
        let found = cx
            .session
            .active_timeline()
            .and_then(|t| t.reverse_match_frame(id, at, cx.session.playhead(), cx.session.selection()));
        let Some(time) = found else { return Some("That frame is not used in the sequence.".to_string()) };
        cx.session.seek(time);
        self.dock.show(PanelID::ProgramMonitor);
        self.dock.set_focused(Some(PanelID::Timeline));
        None
    }
}
