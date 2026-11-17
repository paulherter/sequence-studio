// Swift: TimelineMenus.swift
//! The timeline's right-click menus, translated from App/Sources/EditorPanels.swift `timelineMenu(at:)` and its
//! helpers (+TrackMenu, +Markers, +Transitions, +Captions, +ClipMarkers, +Sync, +Angles): the same `sq-timeline-ui`
//! menu specs (`TimelineContextMenu`, `TimelineSideMenus`), the same session calls; only the dialogs go through the host.
//!
//! Swift menu rows capture the session (`[weak s]`). A row's action here cannot borrow the session, so each one pushes a
//! [`MenuEffect`] into the shared [`MenuOutbox`] and the host runs them with [`TimelineMenus::run_all`] after the menu
//! item was chosen (the same turn of the frame loop). The outbox is the one `Rc<RefCell>` of the menus: it is shared by
//! the menu rows (UI thread only) and the host that opens the menu.

use crate::action::TimelineAction;
use crate::host::{TimelineEditorRequest, TimelineHost, TimelinePrompt};
use crate::panel::TimelinePanel;
use crate::session_bridge;
use sq_core_audio::audio_gain::VolumeLineExt as _;
use sq_core_audio::caption_handover::TimelineCaptionsExt as _;
use sq_core_audio::caption_words::CaptionNeighbor;
use sq_core_color::ClipGradeExt as _;
use sq_core_edit::sync_offsets::SyncOffsetsExt as _;
use sq_core_edit::timeline_beat_snap::BeatSnapLevel;
use sq_core_model::fades_curve::FadeCurve;
use sq_core_model::{Clip, LabelColor, TrackKind};
use sq_core_time::{Id, Time};
use sq_editor_session::{
    AudioRoleDefaults, BeatSnapSetting, EdgeRef, EdgeSelection, EditorSession, MarkersPanelModel, SpeedBandKeyHit,
    SpeedBandKeyKind, TrackToggle, TransitionDefaults, TransitionScope, TransitionTimingChange,
};
use sq_timeline_ui::{
    CaptionWordLayout, CaptionWordRef, ClipMarkerFlags, ClipZone, FadeHandle, NestSheet, RulerRangeEntry,
    TimelineContextMenu, TimelineHit, TimelineMenuAction, TimelineSideMenus, TrackHeaderMenu, TransitionLayout,
};
use sq_uikit::command_map::CommandMap;
use sq_uikit::controls_grid::CGPoint;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqmenu_model::{SQMenuItem, SQMenuShortcut};
use std::cell::RefCell;
use std::collections::BTreeSet;
use std::rc::Rc;

/// What a chosen menu row asks of the session, the host or the panel.
#[derive(Clone, Debug, PartialEq)]
pub enum MenuEffect {
    /// A fade handle's curve.
    FadeCurve { clip: Id, handle: FadeHandle, curve: FadeCurve },
    /// "Delete Keyframe" on a volume key.
    DeleteVolumeKey { clip: Id, key: Id },
    /// "Delete Speed Keyframe" / "Remove Speed Transition".
    DeleteSpeedKey { clip: Id, hit: SpeedBandKeyHit },
    /// "Speed Transition Curve…".
    SpeedCurve { clip: Id, segment: usize, at: CGPoint },
    /// "Add Speed Point" at the clicked time.
    AddSpeedKey { clip: Id, time: Time },
    /// "Set Transition Duration…".
    SetTransitionDuration(Id),
    /// The text a duration prompt returned.
    TransitionDurationText { id: Id, text: String },
    /// "Save as Preset…" on a transition.
    SaveTransitionPreset(Id),
    /// "Delete" on a transition.
    RemoveTransition(Id),
    /// A clip marker row.
    EditClipMarker { clip: Id, marker: Id },
    /// "Delete Clip Marker".
    DeleteClipMarker { clip: Id, marker: Id },
    /// A word or caption item of the caption menu (edits through the panel).
    Caption(CaptionEdit),
    /// "Find and Replace in Captions…".
    CaptionFindReplace,
    /// A row of the caption menu that the session runs.
    CaptionRow(TimelineMenuAction),
    /// A track header row.
    Track(TrackEffect),
    /// A row of the ruler menu.
    Ruler(RulerEffect),
    /// A row of the clip menu.
    Clip { action: TimelineMenuAction, selection: BTreeSet<Id>, pointer: Time },
    /// The label submenu.
    SetLabel(Option<LabelColor>),
    /// "Move into Sync".
    MoveIntoSync(Id),
    /// "Slip into Sync".
    SlipIntoSync(Id),
    /// An angle row.
    Angle(AngleEffect),
    /// "Apply Default Transitions" at the edit under the pointer.
    ApplyDefaultTransitions { scope_video: bool, edge: EdgeRef },
    /// "Grade From Previous Clip" (1) / "Grade From Clip Before Previous" (2).
    GradeFromPrevious(i64),
    /// "Grade All From This Camera".
    GradeAllFromCamera,
    /// The text the Combine… prompt returned (with the names it was shown against).
    NestSelection { name: String, existing: Vec<String> },
    /// The text the Rename Clip prompt returned.
    RenameClip(String),
    /// The text the Rename Track prompt returned.
    RenameTrackText { id: Id, text: String },
}

/// A word edit through the panel.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum CaptionEdit {
    EditWord(CaptionWordRef),
    InsertWord { caption: Id, at: usize },
    DeleteWord(CaptionWordRef),
    SplitBefore { caption: Id, word: usize },
    Join { caption: Id, with: CaptionNeighbor },
}

/// A track header row.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum TrackEffect {
    Add(TrackKind),
    Delete(Id),
    Rename(Id),
    Move { id: Id, up: bool },
    Mix(Id),
    ToggleDucking { id: Id, excluded: bool },
    SequenceVolume,
    SelectAll(Id),
    Toggle(Id, TrackToggle),
}

/// A row of the ruler menu.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum RulerEffect {
    AddMarker(Time),
    EditMarker(Id),
    Range(MarkRange),
    DeleteMarker(Id),
    BeatLevel(BeatSnapLevel),
}

/// Mark In / Out / Remove In and Out.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MarkRange {
    In,
    Out,
    Clear,
}

/// An angle row.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum AngleEffect {
    Set { index: usize, clip: Id },
    Flatten(Id),
    AudioFollowsVideo { clip: Id, on: bool },
    CreateAnglesClip,
}

/// Where chosen menu rows leave their [`MenuEffect`]s.
pub type MenuOutbox = Rc<RefCell<Vec<MenuEffect>>>;

/// A fresh outbox.
pub fn new_outbox() -> MenuOutbox {
    Rc::new(RefCell::new(Vec::new()))
}

fn fx(out: &MenuOutbox, e: MenuEffect) -> Rc<dyn Fn()> {
    let out = Rc::clone(out);
    Rc::new(move || out.borrow_mut().push(e.clone()))
}

fn row(out: &MenuOutbox, title: &str, e: MenuEffect) -> SQMenuItem {
    let mut r = SQMenuItem::new(title);
    r.action = Some(fx(out, e));
    r
}

fn say(host: &mut TimelineHost, msg: &str) {
    if let Some(status) = &mut host.status {
        status(msg);
    }
}

impl TimelinePanel {
    /// A right press (`InputModifiers::SECONDARY`) selects what is under the pointer like the Mac `contextSelect`; the
    /// host then builds the menu with [`TimelineMenus::items`].
    pub fn context_select(&mut self, p: CGPoint) -> Vec<TimelineAction> {
        self.cancel_gesture();
        self.feed_interaction();
        self.interaction.context_select(p, sq_editor_session::GestureModifiers::default());
        self.refresh_from_interaction()
    }
}

/// The timeline's right-click menus.
pub struct TimelineMenus;

impl TimelineMenus {
    /// The menu for a right press at `p` (panel points); `None` = no menu there. Selects like the Mac view first.
    pub fn items(
        p: CGPoint,
        panel: &mut TimelinePanel,
        s: &mut EditorSession,
        host: &mut TimelineHost,
        map: &CommandMap,
        out: &MenuOutbox,
    ) -> Option<Vec<SQMenuItem>> {
        if let Some((clip, handle, current)) = panel.fade_handle_hit(p) {
            return Some(Self::fade_curve_items(clip, handle, current, out));
        }
        if let Some((clip, key)) = panel.volume_key(p) {
            return Some(TimelineSideMenus::volume_key(fx(out, MenuEffect::DeleteVolumeKey { clip, key })));
        }
        if let Some((clip, hit)) = panel.speed_key_hit(p) {
            return Some(Self::speed_key_items(clip, hit, p, out));
        }
        if let Some(clip) = panel.speed_segment_clip(p) {
            let time = panel.geometry.time(p.x);
            return Some(TimelineSideMenus::speed_point(fx(out, MenuEffect::AddSpeedKey { clip, time })));
        }
        if let Some(m) = Self::transition_items(p, panel, s, out) {
            return Some(m);
        }
        if let Some(h) = ClipMarkerFlags::hit(p, &panel.timeline, &panel.geometry) {
            return Some(vec![
                row(out, "Edit Clip Marker…", MenuEffect::EditClipMarker { clip: h.clip, marker: h.marker }),
                SQMenuItem::separator(),
                row(out, "Delete Clip Marker", MenuEffect::DeleteClipMarker { clip: h.clip, marker: h.marker }),
            ]);
        }
        for a in panel.context_select(p) {
            if let Some(m) = session_bridge::apply(a, s, host, Some(panel)) {
                say(host, &m);
            }
        }
        if panel.selection.is_empty() && !panel.caption_selection.is_empty() {
            let words = Self::caption_word_items(p, panel, out);
            let mut rows = words.clone();
            if !words.is_empty() {
                rows.push(SQMenuItem::separator());
            }
            rows.extend(Self::caption_menu(panel, s, map, out));
            return Some(rows);
        }
        let has_clipboard = s.clipboard().is_some();
        let hit = panel.geometry.hit_test(p, &panel.timeline);
        let clip_menu = matches!(hit, TimelineHit::Clip(..) | TimelineHit::Caption(..));
        let items = match hit {
            TimelineHit::Clip(..) | TimelineHit::Caption(..) => {
                let groups: BTreeSet<Id> =
                    s.project().timelines.iter().filter(|t| t.is_group()).map(|t| t.id).collect();
                TimelineContextMenu::items_with_captions(
                    &panel.timeline,
                    &panel.selection,
                    &panel.caption_selection,
                    has_clipboard,
                    &groups,
                    map,
                )
            }
            TimelineHit::Gap(..) if panel.interaction.gap_selection().is_some() => {
                TimelineContextMenu::gap_items(has_clipboard, map)
            }
            TimelineHit::Gap(..) | TimelineHit::CaptionGap(..) => {
                TimelineContextMenu::empty_items(has_clipboard, panel.tool_state().place_sequences_as_clips, map)
            }
            TimelineHit::Header(id) => return Self::track_header_items(id, s, out),
            TimelineHit::Ruler => return Some(Self::ruler_items(p, panel, s, map, out)),
            _ => return None,
        };
        let resolver = s.project().label_resolver();
        let all: Vec<&Clip> = panel.timeline.tracks.iter().flat_map(|t| t.clips().iter()).collect();
        let shared: Vec<LabelColor> =
            s.selection().iter().filter_map(|id| all.iter().find(|c| c.id == *id).map(|c| resolver.label(c))).collect();
        let pointer = panel.geometry.time(p.x);
        let selection = panel.selection.clone();
        let current =
            if shared.len() == 1 || shared.windows(2).all(|w| w[0] == w[1]) { shared.first().copied() } else { None };
        let o = Rc::clone(out);
        let label_out = Rc::clone(out);
        let handler: Rc<dyn Fn(TimelineMenuAction)> = Rc::new(move |action| {
            o.borrow_mut().push(MenuEffect::Clip { action, selection: selection.clone(), pointer });
        });
        let label_handler: Rc<dyn Fn(Option<LabelColor>)> =
            Rc::new(move |l| label_out.borrow_mut().push(MenuEffect::SetLabel(l)));
        let mut rows = TimelineContextMenu::make_sq_items(&items, Some(label_handler), current, handler);
        // Sync, angle and edit-point entries go on top of the clip menu.
        let mut top = Self::sync_items(p, panel, out);
        top.extend(Self::angle_items(p, panel, s, map, out));
        top.extend(Self::edit_point_items(p, panel, out));
        top.extend(rows);
        rows = top;
        // One clip, or a linked video and audio pair that Linked Selection selects together.
        if s.single_selected_clip().is_some_and(|c| c.accepts_color()) {
            rows.push(row(out, "Grade From Previous Clip", MenuEffect::GradeFromPrevious(1)));
            rows.push(row(out, "Grade From Clip Before Previous", MenuEffect::GradeFromPrevious(2)));
            rows.push(row(out, "Grade All From This Camera", MenuEffect::GradeAllFromCamera));
        }
        if clip_menu {
            rows = crate::clip_menu_groups::regroup_clip_menu(rows);
        }
        Some(rows)
    }

    /// `fadeCurveItems`: the curve shapes on a fade handle.
    fn fade_curve_items(clip: Id, handle: FadeHandle, current: Option<FadeCurve>, out: &MenuOutbox) -> Vec<SQMenuItem> {
        let out = Rc::clone(out);
        TimelineSideMenus::fade_curve(
            current,
            Rc::new(move |curve| out.borrow_mut().push(MenuEffect::FadeCurve { clip, handle, curve })),
        )
    }

    /// `speedKeyItems`: a span and its center handle both answer as `.ramp`.
    fn speed_key_items(clip: Id, hit: SpeedBandKeyHit, at: CGPoint, out: &MenuOutbox) -> Vec<SQMenuItem> {
        let (is_ramp, segment) = match hit.hit {
            SpeedBandKeyKind::Ramp(i) => (true, i),
            SpeedBandKeyKind::Key(_) => (false, 0),
        };
        TimelineSideMenus::speed_key(
            hit.title(),
            is_ramp,
            fx(out, MenuEffect::SpeedCurve { clip, segment, at }),
            fx(out, MenuEffect::DeleteSpeedKey { clip, hit }),
        )
    }

    /// `transitionItems`: right-click on a transition box (selects it).
    fn transition_items(
        p: CGPoint,
        panel: &mut TimelinePanel,
        s: &mut EditorSession,
        out: &MenuOutbox,
    ) -> Option<Vec<SQMenuItem>> {
        let hit = TransitionLayout::hit_test(
            p,
            &panel.timeline,
            &panel.geometry,
            sq_timeline_ui::TimelineGeometry::MAX_TRIM_HANDLE_WIDTH,
        )?;
        panel.cancel_gesture();
        panel.selected_transition = Some(hit.id);
        s.select_transition(Some(hit.id), false);
        Some(TimelineSideMenus::transition(
            fx(out, MenuEffect::SetTransitionDuration(hit.id)),
            fx(out, MenuEffect::SaveTransitionPreset(hit.id)),
            fx(out, MenuEffect::RemoveTransition(hit.id)),
        ))
    }

    /// `captionWordMenuItems`: the word and caption items above the caption menu (none on a locked track).
    fn caption_word_items(p: CGPoint, panel: &TimelinePanel, out: &MenuOutbox) -> Vec<SQMenuItem> {
        let TimelineHit::Caption(id, _) = panel.geometry.hit_test(p, &panel.timeline) else { return Vec::new() };
        let Some((row_, _)) = CaptionWordLayout::locate(id, &panel.timeline, &panel.geometry) else {
            return Vec::new();
        };
        let Some(track) = panel.timeline.caption_track(row_.track).filter(|t| !t.is_locked) else { return Vec::new() };
        let edit = |e: CaptionEdit| MenuEffect::Caption(e);
        let mut items: Vec<SQMenuItem> = Vec::new();
        if let Some(hit) = CaptionWordLayout::hit(p, id, &panel.timeline, &panel.geometry) {
            let r = hit.word;
            let mut split = row(
                out,
                "Split Caption Before This Word",
                edit(CaptionEdit::SplitBefore { caption: id, word: r.index }),
            );
            split.is_enabled = r.index > 0;
            items.extend([
                row(out, "Edit Word", edit(CaptionEdit::EditWord(r))),
                row(out, "Insert Word Before", edit(CaptionEdit::InsertWord { caption: id, at: r.index })),
                row(out, "Insert Word After", edit(CaptionEdit::InsertWord { caption: id, at: r.index + 1 })),
                row(out, "Delete Word", edit(CaptionEdit::DeleteWord(r))),
                SQMenuItem::separator(),
                split,
            ]);
        }
        let i = track.items().iter().position(|c| c.id == id).unwrap_or(0);
        let mut prev = row(
            out,
            "Join with Previous Caption",
            edit(CaptionEdit::Join { caption: id, with: CaptionNeighbor::Previous }),
        );
        prev.is_enabled = i > 0;
        let mut next =
            row(out, "Join with Next Caption", edit(CaptionEdit::Join { caption: id, with: CaptionNeighbor::Next }));
        next.is_enabled = i + 1 < track.items().len();
        items.extend([
            prev,
            next,
            SQMenuItem::separator(),
            row(out, "Find and Replace in Captions\u{2026}", MenuEffect::CaptionFindReplace),
        ]);
        items
    }

    /// `captionMenu`.
    fn caption_menu(panel: &TimelinePanel, s: &EditorSession, map: &CommandMap, out: &MenuOutbox) -> Vec<SQMenuItem> {
        let items = TimelineContextMenu::caption_items(&panel.timeline, &panel.caption_selection, s.playhead(), map);
        let o = Rc::clone(out);
        TimelineContextMenu::make_sq_items(
            &items,
            None,
            None,
            Rc::new(move |action| o.borrow_mut().push(MenuEffect::CaptionRow(action))),
        )
    }

    /// `trackHeaderItems`: Add / Delete / Rename / Move, mix, ducking, Select All, the header toggles.
    fn track_header_items(id: Id, s: &EditorSession, out: &MenuOutbox) -> Option<Vec<SQMenuItem>> {
        let track = s.active_timeline()?.track(id)?;
        let t = |e: TrackEffect| fx(out, MenuEffect::Track(e));
        let o = Rc::clone(out);
        Some(TimelineSideMenus::track_header(
            track,
            TrackHeaderMenu {
                add_video: t(TrackEffect::Add(TrackKind::Video)),
                add_audio: t(TrackEffect::Add(TrackKind::Audio)),
                delete: t(TrackEffect::Delete(id)),
                rename: t(TrackEffect::Rename(id)),
                move_up: Some(t(TrackEffect::Move { id, up: true })),
                move_down: Some(t(TrackEffect::Move { id, up: false })),
                mix: t(TrackEffect::Mix(id)),
                toggle_ducking: t(TrackEffect::ToggleDucking { id, excluded: !track.is_excluded_from_live_ducking() }),
                sequence_volume: Some(t(TrackEffect::SequenceVolume)),
                select_all: Some(t(TrackEffect::SelectAll(id))),
                toggle: Some(Rc::new(move |tg| o.borrow_mut().push(MenuEffect::Track(TrackEffect::Toggle(id, tg))))),
            },
        ))
    }

    /// `rulerItems`: marker commands at the pointer, the In/Out entries, Delete Marker, Beat Snap.
    fn ruler_items(
        p: CGPoint,
        panel: &TimelinePanel,
        s: &EditorSession,
        map: &CommandMap,
        out: &MenuOutbox,
    ) -> Vec<SQMenuItem> {
        let t = panel.geometry.time(p.x);
        let marker = panel.marker_id(p);
        let eq = map
            .shown_binding_here(&EditorCommand::AddMarker)
            .and_then(|b| sq_timeline_ui::TimelineMenuItem::portable_key_equivalent(&b));
        let level = panel.beat_level;
        let level_item = |l: BeatSnapLevel, title: &str| {
            let mut r = row(out, title, MenuEffect::Ruler(RulerEffect::BeatLevel(l)));
            r.is_checked = level == l;
            r
        };
        let mut beat_snap = SQMenuItem::new("Beat Snap");
        beat_snap.submenu = Some(vec![
            level_item(BeatSnapLevel::EveryBeat, "Every Beat"),
            level_item(BeatSnapLevel::BarsOnly, "Bars Only"),
        ]);
        let range_out = Rc::clone(out);
        let marker_id = marker;
        let mut rows = TimelineSideMenus::ruler(
            marker.is_some(),
            &RulerRangeEntry::entries(s.active_timeline().is_some_and(|t| t.in_out.is_some()), map),
            &eq.map(|(key, m)| SQMenuShortcut::glyphs(&key, m)).unwrap_or_default(),
            fx(out, MenuEffect::Ruler(RulerEffect::AddMarker(t))),
            Rc::new({
                let o = Rc::clone(out);
                move || {
                    if let Some(m) = marker_id {
                        o.borrow_mut().push(MenuEffect::Ruler(RulerEffect::EditMarker(m)));
                    }
                }
            }),
            Rc::new(move |command| {
                let r = match command {
                    EditorCommand::MarkIn => MarkRange::In,
                    EditorCommand::MarkOut => MarkRange::Out,
                    _ => MarkRange::Clear,
                };
                range_out.borrow_mut().push(MenuEffect::Ruler(RulerEffect::Range(r)));
            }),
            Rc::new({
                let o = Rc::clone(out);
                move || {
                    if let Some(m) = marker_id {
                        o.borrow_mut().push(MenuEffect::Ruler(RulerEffect::DeleteMarker(m)));
                    }
                }
            }),
        );
        rows.push(SQMenuItem::separator());
        rows.push(beat_snap);
        rows
    }

    // MARK: Rows on top of the clip menu

    /// `syncMenuItems`.
    fn sync_items(p: CGPoint, panel: &TimelinePanel, out: &MenuOutbox) -> Vec<SQMenuItem> {
        let TimelineHit::Clip(id, _) = panel.geometry.hit_test(p, &panel.timeline) else { return Vec::new() };
        if !panel.timeline.sync_offsets().contains_key(&id) {
            return Vec::new();
        }
        vec![
            row(out, "Move into Sync", MenuEffect::MoveIntoSync(id)),
            row(out, "Slip into Sync", MenuEffect::SlipIntoSync(id)),
            SQMenuItem::separator(),
        ]
    }

    /// `angleMenuItems`.
    fn angle_items(
        p: CGPoint,
        panel: &TimelinePanel,
        s: &EditorSession,
        map: &CommandMap,
        out: &MenuOutbox,
    ) -> Vec<SQMenuItem> {
        let TimelineHit::Clip(id, _) = panel.geometry.hit_test(p, &panel.timeline) else { return Vec::new() };
        let mut rows: Vec<SQMenuItem> = Vec::new();
        if let Some(st) = s.angle_menu_state(id) {
            let angles: Vec<SQMenuItem> = st
                .names
                .iter()
                .enumerate()
                .map(|(i, name)| {
                    let key = if !st.is_audio && i < 9 {
                        map.shown_binding_here(&EditorCommand::SwitchAngle(i64::try_from(i + 1).unwrap_or(0)))
                            .and_then(|b| sq_timeline_ui::TimelineMenuItem::portable_key_equivalent(&b))
                            .map(|(k, m)| SQMenuShortcut::glyphs(&k, m))
                            .unwrap_or_default()
                    } else {
                        String::new()
                    };
                    let mut r = row(
                        out,
                        &format!("{}  {name}", i + 1),
                        MenuEffect::Angle(AngleEffect::Set { index: i, clip: id }),
                    );
                    r.shortcut = key;
                    r.is_checked = i == st.active;
                    r
                })
                .collect();
            let mut parent = SQMenuItem::new(if st.is_audio { "Sound Angle" } else { "Angle" });
            parent.submenu = Some(angles);
            rows.push(parent);
            rows.push(row(out, "Flatten Angles Clip", MenuEffect::Angle(AngleEffect::Flatten(id))));
            if let Some(follows) = st.follows_video {
                let mut r = row(
                    out,
                    "Audio Follows Video",
                    MenuEffect::Angle(AngleEffect::AudioFollowsVideo { clip: id, on: !follows }),
                );
                r.is_checked = follows;
                rows.push(r);
            }
        }
        if s.selection().contains(&id) && s.angle_candidates_of_selection().len() >= 2 {
            rows.push(row(out, "Create Angles Clip…", MenuEffect::Angle(AngleEffect::CreateAnglesClip)));
        }
        if rows.is_empty() {
            return rows;
        }
        rows.push(SQMenuItem::separator());
        rows
    }

    /// `editPointItems`: Apply Default Transitions at the edit under the pointer.
    fn edit_point_items(p: CGPoint, panel: &TimelinePanel, out: &MenuOutbox) -> Vec<SQMenuItem> {
        let TimelineHit::Clip(id, zone) = panel.geometry.hit_test(p, &panel.timeline) else { return Vec::new() };
        if zone == ClipZone::Body {
            return Vec::new();
        }
        let Some(track) = panel.timeline.tracks.iter().find(|t| t.clips().iter().any(|c| c.id == id)) else {
            return Vec::new();
        };
        if track.is_locked {
            return Vec::new();
        }
        let edge = EdgeRef {
            clip: id,
            edge: if zone == ClipZone::Head { sq_core_model::ClipEdge::Head } else { sq_core_model::ClipEdge::Tail },
        };
        vec![
            row(
                out,
                "Apply Default Transitions",
                MenuEffect::ApplyDefaultTransitions { scope_video: track.kind == TrackKind::Video, edge },
            ),
            SQMenuItem::separator(),
        ]
    }

    // MARK: Running the chosen rows

    /// Runs every effect the chosen rows left (a prompt's answer may leave more); returns the status lines.
    pub fn run_all(
        out: &MenuOutbox,
        s: &mut EditorSession,
        host: &mut TimelineHost,
        panel: &mut TimelinePanel,
    ) -> Vec<String> {
        let mut lines = Vec::new();
        loop {
            let batch: Vec<MenuEffect> = std::mem::take(&mut *out.borrow_mut());
            if batch.is_empty() {
                return lines;
            }
            for e in batch {
                if let Some(l) = Self::run(e, out, s, host, panel) {
                    lines.push(l);
                }
            }
        }
    }

    /// Runs one effect; a status line when it has one.
    pub fn run(
        e: MenuEffect,
        out: &MenuOutbox,
        s: &mut EditorSession,
        host: &mut TimelineHost,
        panel: &mut TimelinePanel,
    ) -> Option<String> {
        let clip_of = |s: &EditorSession, id: Id| -> Option<Clip> {
            s.active_timeline()?.tracks.iter().flat_map(|t| t.clips().iter()).find(|c| c.id == id).cloned()
        };
        match e {
            MenuEffect::FadeCurve { clip, handle, curve } => {
                let mut c = clip_of(s, clip)?;
                c.set_audio_fade_curve(curve, handle == FadeHandle::Head);
                s.replace_clip(&c, "Fade Curve", false);
            }
            MenuEffect::DeleteVolumeKey { clip, key } => {
                let mut c = clip_of(s, clip)?;
                c.remove_volume_key(key);
                s.replace_clip(&c, "Delete Keyframe", false);
            }
            MenuEffect::DeleteSpeedKey { clip, hit } => {
                s.delete_speed_key(clip, hit);
            }
            MenuEffect::SpeedCurve { clip, segment, at } => {
                return host.request(&TimelineEditorRequest::SpeedCurve { clip, segment, at });
            }
            MenuEffect::AddSpeedKey { clip, time } => {
                let c = clip_of(s, clip)?;
                s.add_speed_key(clip, time - c.start);
            }
            MenuEffect::SetTransitionDuration(id) => return Self::edit_transition_duration(id, out, s, host),
            MenuEffect::TransitionDurationText { id, text } => {
                let fd = s.active_timeline()?.format.frame_duration;
                if let Some(d) = MarkersPanelModel::parse_timecode(&text, fd).filter(|d| *d > Time::ZERO) {
                    s.set_transition(id, &TransitionTimingChange { duration: Some(d), ..Default::default() }, false);
                }
            }
            MenuEffect::SaveTransitionPreset(id) => {
                s.select_transition(Some(id), false);
                return host.request(&TimelineEditorRequest::SaveTransitionPreset(id));
            }
            MenuEffect::RemoveTransition(id) => {
                s.remove_transition(id);
            }
            MenuEffect::EditClipMarker { clip, marker } => {
                return host.request(&TimelineEditorRequest::ClipMarker { clip, marker });
            }
            MenuEffect::DeleteClipMarker { clip, marker } => s.delete_clip_marker(marker, clip),
            MenuEffect::Caption(edit) => {
                let actions = match edit {
                    CaptionEdit::EditWord(r) => panel.begin_word_editing(r),
                    CaptionEdit::InsertWord { caption, at } => panel.begin_word_insert(caption, at),
                    CaptionEdit::DeleteWord(r) => panel.delete_word(r),
                    CaptionEdit::SplitBefore { caption, word } => Some(panel.split_caption(caption, word)),
                    CaptionEdit::Join { caption, with } => Some(panel.join_caption(caption, with)),
                }
                .unwrap_or_default();
                for a in actions {
                    if let Some(m) = session_bridge::apply(a, s, host, Some(panel)) {
                        say(host, &m);
                    }
                }
            }
            MenuEffect::CaptionFindReplace => return host.request(&TimelineEditorRequest::CaptionFindReplace),
            MenuEffect::CaptionRow(action) => match action {
                TimelineMenuAction::EditCaption => {
                    if let Some(id) = s.caption_selection().iter().next().copied() {
                        return host.request(&TimelineEditorRequest::CaptionText(id));
                    }
                }
                TimelineMenuAction::SplitCaption => {
                    s.split_caption(None);
                }
                TimelineMenuAction::MergeCaptions => {
                    s.merge_selected_captions();
                }
                TimelineMenuAction::Delete => {
                    s.delete_selected_captions();
                }
                _ => {}
            },
            MenuEffect::Track(t) => return Self::run_track(t, out, s, host),
            MenuEffect::Ruler(r) => match r {
                RulerEffect::AddMarker(t) => {
                    s.seek(t);
                    if let Some(m) = s.mark_at_playhead().filter(|m| m.open_edit) {
                        return host.request(&TimelineEditorRequest::Marker(m.id));
                    }
                }
                RulerEffect::EditMarker(id) => return host.request(&TimelineEditorRequest::Marker(id)),
                RulerEffect::Range(MarkRange::In) => s.mark_in(),
                RulerEffect::Range(MarkRange::Out) => s.mark_out(),
                RulerEffect::Range(MarkRange::Clear) => s.clear_in_out(),
                RulerEffect::DeleteMarker(id) => s.delete_marker(id),
                RulerEffect::BeatLevel(l) => {
                    panel.beat_level = l;
                    if let Some(store) = &panel.height_store {
                        BeatSnapSetting::store(l, &mut *store.borrow_mut());
                    }
                }
            },
            MenuEffect::Clip { action, selection, pointer } => {
                return Self::perform(action, &selection, pointer, out, s, host, panel);
            }
            MenuEffect::SetLabel(l) => s.set_label(l),
            MenuEffect::MoveIntoSync(id) => s.move_into_sync(id),
            MenuEffect::SlipIntoSync(id) => s.slip_into_sync(id),
            MenuEffect::Angle(a) => match a {
                AngleEffect::Set { index, clip } => {
                    s.set_angle(index, clip);
                }
                AngleEffect::Flatten(clip) => {
                    s.flatten_angles(clip);
                }
                AngleEffect::AudioFollowsVideo { clip, on } => {
                    s.set_audio_follows_video(on, clip);
                }
                AngleEffect::CreateAnglesClip => return host.request(&TimelineEditorRequest::CreateAnglesClip),
            },
            MenuEffect::ApplyDefaultTransitions { scope_video, edge } => {
                let defaults = panel
                    .height_store
                    .as_ref()
                    .map_or(TransitionDefaults::STANDARD, |st| TransitionDefaults::load(&*st.borrow()));
                let roles = panel
                    .height_store
                    .as_ref()
                    .map_or_else(AudioRoleDefaults::standard, |st| AudioRoleDefaults::load(&*st.borrow()));
                s.apply_default_transitions_with_roles(
                    if scope_video { TransitionScope::Video } else { TransitionScope::Audio },
                    Some(&EdgeSelection { edges: vec![edge], ripple: false, linked: false }),
                    None,
                    &defaults,
                    &roles,
                );
            }
            MenuEffect::GradeFromPrevious(back) => {
                s.grade_from_previous_clip(back);
            }
            MenuEffect::GradeAllFromCamera => {
                let n = s.grade_all_from_camera();
                if n > 0 {
                    return Some(SQL10n::plural(
                        n,
                        "Graded %@ clip from this camera.",
                        "Graded %@ clips from this camera.",
                    ));
                }
            }
            MenuEffect::NestSelection { name, existing } => {
                s.nest_selection(&NestSheet::resolved_name(&name, &existing));
            }
            MenuEffect::RenameClip(name) => s.rename_selected_clip(&name),
            MenuEffect::RenameTrackText { id, text } => s.rename_track(id, &text),
        }
        None
    }

    fn run_track(t: TrackEffect, out: &MenuOutbox, s: &mut EditorSession, host: &mut TimelineHost) -> Option<String> {
        match t {
            TrackEffect::Add(kind) => s.add_track(kind),
            TrackEffect::Delete(id) => s.delete_track(id),
            TrackEffect::Rename(id) => {
                let track = s.active_timeline()?.track(id)?.clone();
                let o = Rc::clone(out);
                host.ask(
                    TimelinePrompt {
                        title: "Rename Track".to_string(),
                        message: String::new(),
                        text: track.name.clone(),
                        placeholder: if track.kind == TrackKind::Video { "Video" } else { "Audio" }.to_string(),
                    },
                    "Rename is not available here yet",
                    Box::new(move |text| o.borrow_mut().push(MenuEffect::RenameTrackText { id, text })),
                );
            }
            TrackEffect::Move { id, up } => {
                s.move_track(id, up);
            }
            TrackEffect::Mix(id) => return host.request(&TimelineEditorRequest::TrackMix(id)),
            TrackEffect::ToggleDucking { id, excluded } => {
                s.set_track_excluded_from_live_ducking(id, excluded);
            }
            TrackEffect::SequenceVolume => return host.request(&TimelineEditorRequest::SequenceVolume),
            TrackEffect::SelectAll(id) => {
                let ids: BTreeSet<Id> = s.active_timeline()?.track(id)?.clips().iter().map(|c| c.id).collect();
                s.select(ids, BTreeSet::new());
            }
            TrackEffect::Toggle(id, tg) => {
                return session_bridge::apply(
                    TimelineAction::ToggleTrack { track: id, toggle: tg, shift: false, option: false },
                    s,
                    host,
                    None,
                );
            }
        }
        None
    }

    /// One clip menu row (`timelineMenu`'s action switch).
    fn perform(
        action: TimelineMenuAction,
        selection: &BTreeSet<Id>,
        pointer: Time,
        out: &MenuOutbox,
        s: &mut EditorSession,
        host: &mut TimelineHost,
        panel: &mut TimelinePanel,
    ) -> Option<String> {
        use TimelineMenuAction as A;
        match action {
            A::Cut => host.run(EditorCommand::Cut),
            A::Copy => host.run(EditorCommand::Copy),
            A::Paste => host.run(EditorCommand::Paste),
            A::PasteInsert => host.run(EditorCommand::PasteInsert),
            A::PasteAttributes => host.run(EditorCommand::PasteAttributes),
            A::Delete => host.run(EditorCommand::Delete),
            A::RippleDelete => host.run(EditorCommand::RippleDelete),
            A::Enable => host.run(EditorCommand::EnableClip),
            A::UseTake => {
                s.use_selected_take_for_range();
            }
            A::Link | A::Unlink => host.run(EditorCommand::Link),
            A::Nest => Self::nest(out, s, host),
            A::Unnest => {
                s.unnest_selection();
            }
            A::Group => host.run(EditorCommand::Group),
            A::Ungroup => host.run(EditorCommand::Ungroup),
            A::Bundle => host.run(EditorCommand::Bundle),
            A::Unbundle => host.run(EditorCommand::Unbundle),
            A::EditOriginal => host.run(EditorCommand::EditOriginal),
            A::RevealInProject => {
                if let Some(id) = s.media_of_selection().first().copied() {
                    return host.request(&TimelineEditorRequest::RevealInProject { media: id });
                }
            }
            A::ExtendToSequenceEnd => host.run(EditorCommand::ExtendToSequenceEnd),
            A::Speed => host.run(EditorCommand::SpeedDuration),
            A::Reverse => host.run(EditorCommand::ReverseClip),
            A::AudioGain => host.run(EditorCommand::AudioGain),
            A::RemoveSilences => host.run(EditorCommand::RemoveSilences),
            A::RemoveFillerWords => host.run(EditorCommand::RemoveFillerWords),
            A::PunchInCuts => host.run(EditorCommand::PunchInCuts),
            A::FitMusicToLength => host.run(EditorCommand::FitMusicToLength),
            A::TimeRemapping => host.run(EditorCommand::ToggleTimeRemapping),
            A::SetToFrameSize => {
                s.set_to_frame_size(None);
            }
            A::SetToFillFrame => {
                s.set_to_fill_frame(None);
            }
            A::Rename => Self::rename_selected_clip(out, s, host),
            A::AddClipMarker => {
                let id = selection.iter().next().copied()?;
                let clip = s.active_timeline()?.tracks.iter().flat_map(|t| t.clips().iter()).find(|c| c.id == id)?;
                let at = if clip.timeline().contains(pointer) { pointer } else { s.playhead() };
                if let Some(m) = s.add_clip_marker(id, at) {
                    return host.request(&TimelineEditorRequest::ClipMarker { clip: id, marker: m });
                }
            }
            A::SaveAsPreset => return host.request(&TimelineEditorRequest::SaveClipPreset),
            A::MakeGraphic => {
                s.make_graphic();
            }
            A::NewColorMatte => {
                if s.active_timeline().is_none() {
                    return Some("Open a sequence first.".to_string());
                }
                return host.request(&TimelineEditorRequest::NewColorMatte);
            }
            A::TogglePlaceSequencesAsClips => {
                let on = !panel.tool_state().place_sequences_as_clips;
                panel.tool_state_mut().place_sequences_as_clips = on;
            }
            A::SaveTitleBlock => return host.request(&TimelineEditorRequest::SaveTitleBlock),
            A::SaveTemplate => return host.request(&TimelineEditorRequest::SaveTemplate),
            A::ToggleZones => Self::toggle_zones(s, host),
            A::SpeedRamp(p, on_beat) => host.run(EditorCommand::SpeedRampPreset(p, on_beat)),
            // captions have their own menu (`caption_menu`)
            A::Label | A::EditCaption | A::SplitCaption | A::MergeCaptions => {}
        }
        None
    }

    // MARK: Dialog flows (the Mac SQDialog sheets, as host prompts)

    /// `requestNest`: Combine… names the new sequence (`NestSheet` rules), then nests the selection.
    fn nest(out: &MenuOutbox, s: &EditorSession, host: &mut TimelineHost) {
        if s.selection().is_empty() {
            return;
        }
        let names: Vec<String> = s.project().timelines.iter().map(|t| t.name.clone()).collect();
        let o = Rc::clone(out);
        let existing = names.clone();
        host.ask(
            TimelinePrompt {
                title: "Combine".to_string(),
                message: "Name of the new sequence:".to_string(),
                text: NestSheet::default_name(&names),
                placeholder: String::new(),
            },
            "Combine is not available here yet",
            Box::new(move |name| o.borrow_mut().push(MenuEffect::NestSelection { name, existing })),
        );
    }

    /// `renameSelectedClip`.
    fn rename_selected_clip(out: &MenuOutbox, s: &EditorSession, host: &mut TimelineHost) {
        let Some(clip) = s.single_selected_clip() else { return };
        let o = Rc::clone(out);
        host.ask(
            TimelinePrompt::new("Rename Clip", &clip.name),
            "Rename is not available here yet",
            Box::new(move |name| o.borrow_mut().push(MenuEffect::RenameClip(name))),
        );
    }

    /// `setTransitionDuration`: the host's own dialog when it has one, else a timecode prompt.
    fn edit_transition_duration(
        id: Id,
        out: &MenuOutbox,
        s: &EditorSession,
        host: &mut TimelineHost,
    ) -> Option<String> {
        if host.open.as_mut().is_some_and(|open| open(&TimelineEditorRequest::EditTransitionDuration(id))) {
            return None;
        }
        let info = s.transition_info(id);
        let fd = s.active_timeline().map(|t| t.format.frame_duration);
        let (true, Some(info), Some(fd)) = (host.prompt.is_some(), info, fd) else {
            return host.request(&TimelineEditorRequest::EditTransitionDuration(id));
        };
        let current = info.resolved.as_ref().map_or(info.transition.duration, |r| r.duration());
        let o = Rc::clone(out);
        host.ask(
            TimelinePrompt {
                title: "Set Transition Duration".to_string(),
                message: sq_core_effects::transition::TransitionKindExt::name(info.transition.kind).to_string(),
                text: MarkersPanelModel::timecode(current, fd),
                placeholder: "00:00:00:00".to_string(),
            },
            "",
            Box::new(move |text| o.borrow_mut().push(MenuEffect::TransitionDurationText { id, text })),
        );
        None
    }

    /// `toggleZonesOfSelection`.
    pub fn toggle_zones(s: &mut EditorSession, host: &mut TimelineHost) {
        let clips = s.selected_zone_clips();
        if clips.is_empty() {
            say(host, "Select a title clip first.");
            return;
        }
        let on = clips.iter().any(|c| c.zones.is_none());
        for c in &clips {
            if !s.set_zones_enabled(on, c.id) {
                let msg = s.last_error().unwrap_or("Zones could not be changed.").to_string();
                say(host, &msg);
                return;
            }
        }
    }
}
