// Swift: TimelinePanel+ViewCommands.swift
//! Menu and key commands that need the timeline view's own state (toggles, edge selection, heights, zoom), translated
//! from the Mac AppController+Commands / +TimelineOps and EditorPanels (`setEditMode`, `editMarker`). The edits
//! themselves stay the session's.

use crate::host::{TimelineEditorRequest, TimelineHost};
use crate::panel::TimelinePanel;
use crate::timeline_menus::TimelineMenus;
use sq_core_model::ClipEdge;
use sq_core_model::{TimelineEditMode, TrackKind};
use sq_core_time::step_status;
use sq_editor_session::{EdgeEdits, EditorSession};
use sq_library::library_folder_store::SettingsStore;
use sq_timeline_ui::{ThumbnailMode, ThumbnailPrefs, TrackHeightMode, TrackSizing};
use sq_uikit::editor_command::{EditorCommand, ThumbnailModeChoice};
use std::collections::{BTreeMap, HashSet};

impl TimelinePanel {
    /// Defaults key of the track height preset (the Mac `EditorPanels` uses the same).
    pub const HEIGHT_MODE_DEFAULTS_KEY: &'static str = "sq.trackHeightMode";
    /// Defaults key of Fit All Tracks to Height.
    pub const FIT_TRACKS_DEFAULTS_KEY: &'static str = "sq.fitTracksToHeight";

    /// The Mac status line when an edge command finds no selected edit.
    pub(crate) fn need_edit_line() -> String {
        let p = sq_os::Platform::current();
        format!(
            "Select an edit first (click a clip edge). {}+{}+Left/Right slips the clip.",
            if p.command_is_cmd_key() { "Opt" } else { "Alt" },
            p.command_key_name()
        )
    }

    /// Check marks of the timeline's View and Sequence toggles (the Mac `validateTimelineOpItem`): snapping, linked
    /// selection, Fast Cut, Fit All Tracks and the thumbnail mode.
    pub fn view_checks(&self, s: &EditorSession) -> HashSet<EditorCommand> {
        let mut out = HashSet::new();
        if self.tool_state().snapping {
            out.insert(EditorCommand::ToggleSnapping);
        }
        if self.tool_state().linked_selection {
            out.insert(EditorCommand::ToggleLinkedSelection);
        }
        if s.active_timeline().is_some_and(|t| t.edit_mode() == TimelineEditMode::Magnetic) {
            out.insert(EditorCommand::ToggleMagnetic);
        }
        if self.geometry.fit_all_tracks {
            out.insert(EditorCommand::ToggleFitTracks);
        }
        if let Some(c) = ThumbnailModeChoice::ALL.into_iter().find(|c| c.raw_value() == self.thumbnail_mode.raw_value())
        {
            out.insert(EditorCommand::ThumbnailMode(c));
        }
        out
    }

    /// Runs `c` when it is a view command: `None` = not one of them (the host goes on), `Some("")` = done, else a status
    /// line. `zooms`: the zoom commands go to the timeline (`CommandRouting.zoomTarget` is `.timeline`); else they pass
    /// on. `owns_delete`: the timeline (or nothing) has the focus, so Delete may close the selected gap; another panel
    /// keeps it.
    pub fn run_view_command(
        &mut self,
        c: &EditorCommand,
        s: &mut EditorSession,
        zooms: bool,
        mut host: Option<&mut TimelineHost>,
        owns_delete: bool,
        defaults: &mut dyn SettingsStore,
    ) -> Option<String> {
        let edges = self.interaction.edge_selection().cloned();
        let need = |edges: &Option<sq_editor_session::EdgeSelection>| edges.clone().ok_or(Self::need_edit_line());
        match c {
            EditorCommand::Tool(tool) => {
                self.tool_state_mut().select(*tool);
                return Some(sq_uikit::localization::SQL10n::string(&EditorCommand::Tool(*tool).title()));
            }
            EditorCommand::SlipKeyframesStayTool => {
                self.tool_state_mut().select_slip_keyframes_stay();
                return Some(sq_uikit::localization::SQL10n::string(&EditorCommand::SlipKeyframesStayTool.title()));
            }
            EditorCommand::Delete | EditorCommand::RippleDelete => {
                // A selected gap closes (the Mac `deleteSelectedGap`, after a selected transition); clips go on to the host.
                if !owns_delete
                    || self.gesture.is_some()
                    || self.selected_transition.is_some()
                    || !s.selection().is_empty()
                    || !s.caption_selection().is_empty()
                {
                    return None;
                }
                let gap = *self.interaction.gap_selection()?;
                s.close_gap(&gap);
                return Some(String::new());
            }
            EditorCommand::ToggleSnapping => {
                let on = !self.tool_state().snapping;
                self.tool_state_mut().snapping = on;
                self.tool_state().store_toggles(defaults);
                let _ = s.set_snapping(on); // saved with the sequence, one undo step
                return Some(if on { "Snapping on" } else { "Snapping off" }.to_string());
            }
            EditorCommand::ToggleLinkedSelection => {
                let on = !self.tool_state().linked_selection;
                self.tool_state_mut().linked_selection = on;
                // The session's mirror flag has no public setter; `set_linked_selection` sets it with the sequence setting.
                let _ = s.set_linked_selection(on); // saved with the sequence, one undo step
                self.tool_state().store_toggles(defaults);
                return Some(if on { "Linked Selection on" } else { "Linked Selection off" }.to_string());
            }
            EditorCommand::ThumbnailMode(choice) => {
                let Some(m) = ThumbnailMode::from_raw(choice.raw_value()) else { return Some(String::new()) };
                self.thumbnail_mode = m;
                // `ThumbnailPrefs.mode` with the given defaults (the Mac menu writes the same key and tells the other views).
                ThumbnailPrefs::set_mode(defaults, m);
                return Some(String::new());
            }
            EditorCommand::ToggleMagnetic => {
                let magnetic = s.active_timeline().is_some_and(|t| t.edit_mode() == TimelineEditMode::Magnetic);
                return Some(
                    self.set_edit_mode(if magnetic { TimelineEditMode::Normal } else { TimelineEditMode::Magnetic }, s),
                );
            }
            EditorCommand::ZoomIn | EditorCommand::ZoomOut | EditorCommand::ZoomFit => {
                if !zooms {
                    return None;
                }
                match c {
                    EditorCommand::ZoomIn => self.zoom_in(),
                    EditorCommand::ZoomOut => self.zoom_out(),
                    _ => self.zoom_to_fit(),
                }
                self.follow.user_scrolled(self.is_playing);
                return Some(String::new());
            }
            EditorCommand::VideoTracksTaller => self.size_tracks(Some(TrackKind::Video), 1, defaults),
            EditorCommand::VideoTracksShorter => self.size_tracks(Some(TrackKind::Video), -1, defaults),
            EditorCommand::AudioTracksTaller => self.size_tracks(Some(TrackKind::Audio), 1, defaults),
            EditorCommand::AudioTracksShorter => self.size_tracks(Some(TrackKind::Audio), -1, defaults),
            EditorCommand::AllTracksTaller => self.size_tracks(None, 1, defaults),
            EditorCommand::AllTracksShorter => self.size_tracks(None, -1, defaults),
            EditorCommand::ToggleFitTracks => {
                let on = !self.geometry.fit_all_tracks;
                self.set_fits_tracks(on, defaults);
            }
            EditorCommand::MinimizeAllTracks => {
                let h = TrackSizing::minimized_all(&self.rows());
                self.apply_manual_heights(h, defaults);
            }
            EditorCommand::ExpandAllTracks => self.apply_manual_heights(TrackSizing::expanded_all(), defaults),
            EditorCommand::TrackHeightSmall => self.set_height_mode(TrackHeightMode::Small, defaults),
            EditorCommand::TrackHeightMedium => self.set_height_mode(TrackHeightMode::Medium, defaults),
            EditorCommand::TrackHeightLarge => self.set_height_mode(TrackHeightMode::Large, defaults),
            EditorCommand::TrackHeightAuto => self.set_height_mode(TrackHeightMode::Auto, defaults),
            EditorCommand::SelectLeftEdge | EditorCommand::SelectRightEdge => {
                let edge = if *c == EditorCommand::SelectLeftEdge { ClipEdge::Head } else { ClipEdge::Tail };
                let Some(sel) = s.edge_selection_of_selection(edge) else {
                    return Some("Select a clip first.".to_string());
                };
                self.interaction.set_edge_selection(Some(sel));
            }
            EditorCommand::ToggleTrimType => {
                let sel = match need(&edges) {
                    Ok(sel) => sel,
                    Err(line) => return Some(line),
                };
                self.interaction.set_edge_selection(Some(EdgeEdits::cycled(&sel, &self.timeline))); // regular, ripple, rolling
            }
            EditorCommand::TrimBackward => return Some(self.trim_line(s, edges, -1, true)),
            EditorCommand::TrimForward => return Some(self.trim_line(s, edges, 1, true)),
            EditorCommand::TrimBackward5 => return Some(self.trim_line(s, edges, -step_status::LARGE, false)),
            EditorCommand::TrimForward5 => return Some(self.trim_line(s, edges, step_status::LARGE, false)),
            EditorCommand::ExtendEdit => {
                let Some(e) = edges else { return Some(Self::need_edit_line()) };
                s.extend_edit(&e);
            }
            EditorCommand::SaveAsTemplate => {
                return Some(Self::open(TimelineEditorRequest::SaveTemplate, host.as_deref_mut()));
            }
            EditorCommand::CreateAnglesClip => {
                return Some(Self::open(TimelineEditorRequest::CreateAnglesClip, host.as_deref_mut()));
            }
            EditorCommand::ToggleAnimationZones => {
                let Some(h) = host else { return Some("Select a title clip first.".to_string()) };
                TimelineMenus::toggle_zones(s, h);
            }
            EditorCommand::EditMarker => {
                let Some(id) = s.marker_at_playhead() else { return Some("No marker at the playhead.".to_string()) };
                return Some(Self::open(TimelineEditorRequest::Marker(id), host));
            }
            EditorCommand::AddMarker => {
                // The Mac (AppController+Commands): M on a marker that is already there opens its editor.
                let Some(r) = s.mark_at_playhead() else { return Some(String::new()) };
                return Some(if r.open_edit {
                    Self::open(TimelineEditorRequest::Marker(r.id), host)
                } else {
                    String::new()
                });
            }
            EditorCommand::AddAndEditMarker => {
                let Some(r) = s.mark_at_playhead() else { return Some(String::new()) };
                return Some(Self::open(TimelineEditorRequest::Marker(r.id), host));
            }
            _ => return None,
        }
        Some(String::new())
    }

    /// Trim by `n` frames: the selected edit, or (Fast Cut, Opt+Left/Right with a main-track clip and no edit selected)
    /// Move Clip Left / Right.
    fn trim_line(
        &self,
        s: &mut EditorSession,
        edges: Option<sq_editor_session::EdgeSelection>,
        n: i64,
        move_fallback: bool,
    ) -> String {
        if let Some(e) = edges {
            s.trim_edges(&e, n);
            return step_status::line("Trim", n);
        }
        // Fast Cut: Opt+Left/Right with a main-track clip and no edit selected is Move Clip Left / Right.
        if move_fallback
            && s.fast_cut_command_enabled(if n < 0 {
                EditorCommand::MoveClipLeft
            } else {
                EditorCommand::MoveClipRight
            })
        {
            return s.move_selected_main_clips(i32::try_from(n).unwrap_or(0));
        }
        Self::need_edit_line()
    }

    /// "" when the host opened `r`, else the missing editor's status line.
    fn open(r: TimelineEditorRequest, host: Option<&mut TimelineHost>) -> String {
        let opened = host.and_then(|h| h.open.as_mut()).is_some_and(|open| open(&r));
        if opened { String::new() } else { r.unavailable() }
    }

    /// Normal | Fast Cut (the Mac `EditorPanels.setEditMode`): one undo step and the mode's status line.
    pub fn set_edit_mode(&mut self, mode: TimelineEditMode, s: &mut EditorSession) -> String {
        if !s.set_timeline_edit_mode(mode) {
            return String::new();
        }
        if mode == TimelineEditMode::Magnetic {
            "Fast Cut: the main track closes gaps, clips above and below stay attached".to_string()
        } else {
            "Normal: classic tracks".to_string()
        }
    }

    /// Open, sequence switch, Undo / Redo: the sequence's saved Snapping and Linked Selection drive the timeline (the
    /// Mac `EditorPanels` on `.project`). Call after `sync`.
    pub fn sync_toggles(&mut self, s: &EditorSession) {
        let Some(t) = s.active_timeline() else { return };
        let snapping = t.snapping_off_store != Some(true);
        let linked = t.linked_selection_off_store != Some(true);
        if self.tool_state().snapping == snapping && self.tool_state().linked_selection == linked {
            return;
        }
        let st = self.tool_state_mut();
        st.snapping = snapping;
        st.linked_selection = linked;
        // The session's mirror flag follows through `set_linked_selection` (no public setter, see `run_view_command`).
    }

    /// The track height preset and Fit All Tracks the user picked last (the Mac `EditorPanels` reads the same keys).
    pub fn load_height_prefs(&mut self, defaults: &dyn SettingsStore) {
        self.geometry.height_mode = defaults
            .data(Self::HEIGHT_MODE_DEFAULTS_KEY)
            .and_then(|b| String::from_utf8(b).ok())
            .and_then(|s| TrackHeightMode::from_raw(&s))
            .unwrap_or(TrackHeightMode::Medium);
        self.geometry.fit_all_tracks = defaults.data(Self::FIT_TRACKS_DEFAULTS_KEY).is_some_and(|b| b == b"true");
        self.clamp_scroll();
    }

    /// Height commands: one step taller (+1) or shorter (-1) for the tracks of `kind` (`None` = all).
    fn size_tracks(&mut self, kind: Option<TrackKind>, direction: i64, defaults: &mut dyn SettingsStore) {
        let h = TrackSizing::stepped(&self.rows(), kind, direction);
        self.apply_manual_heights(h, defaults);
    }

    /// Track height preset (Small / Medium / Large / Auto): clears per-track overrides and keeps the mode.
    fn set_height_mode(&mut self, m: TrackHeightMode, defaults: &mut dyn SettingsStore) {
        self.geometry.height_mode = m;
        self.apply_manual_heights(BTreeMap::new(), defaults);
        defaults.set_data(Self::HEIGHT_MODE_DEFAULTS_KEY, m.raw_value().as_bytes().to_vec());
    }

    /// Fit All Tracks: heights follow the panel height. Turning it off keeps the heights as drawn (nothing jumps).
    fn set_fits_tracks(&mut self, on: bool, defaults: &mut dyn SettingsStore) {
        if on == self.geometry.fit_all_tracks {
            return;
        }
        if on {
            self.geometry.fit_all_tracks = true;
            self.clamp_scroll();
        } else {
            let frozen = TrackSizing::frozen(&self.rows());
            self.apply_heights(frozen); // turns the flag off
        }
        defaults.set_data(Self::FIT_TRACKS_DEFAULTS_KEY, if on { b"true".to_vec() } else { b"false".to_vec() });
        self.persist_heights();
    }

    /// A manual height change: Fit All Tracks goes off first (kept in the defaults), the heights are kept per sequence.
    fn apply_manual_heights(&mut self, h: BTreeMap<sq_core_time::Id, f64>, defaults: &mut dyn SettingsStore) {
        if self.geometry.fit_all_tracks {
            defaults.set_data(Self::FIT_TRACKS_DEFAULTS_KEY, b"false".to_vec());
        }
        self.apply_heights(h);
        self.persist_heights();
    }
}
