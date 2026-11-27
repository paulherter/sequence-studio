// Swift: EffectControlsModel.swift (Model)
//! State and edit logic of the Effect Controls panel for one clip. Every change produces a new `Clip` value and goes
//! out as an [`EffectControlsEvent`]; the owner applies it (undo snapshot).
//!
//! Coalescing: inside a gesture (`begin_gesture` ... `end_gesture`, e.g. one scrub drag or one lane drag) the first
//! edit has `coalescing == false` and all following ones `true`, so one gesture is one undo step. Inside a gesture
//! every edit is computed from the clip as it was at `begin_gesture`, so steps never drift.
//!
//! Mapping (docs/rust/session-ui-design.md section 2): Swift `onX` hooks are variants of `EffectControlsEvent`
//! pushed to the model's queue (`take_events`); hooks that return a value are `Option<Box<dyn Fn..>>` fields; the weak
//! `speedSession` is a `has_session` flag plus the session facts `sync` copies (`display_picture`).

use std::collections::{BTreeMap, BTreeSet, HashSet};

use sq_core_model::effect_defaults::EffectDefaults;
use sq_core_model::keyframes_clipboard::KeyframeClipboard;
use sq_core_model::keyframes_editing::SummaryMember;
use sq_core_model::{AnimatedProperty, Clip, ClipEffect};
use sq_core_time::{EasingLibrary, Id, IdSource, Interpolation, Keyframe, Time, Vec2};
use sq_editor_session::EffectSection;
use sq_uikit::keyframe_graph_geometry::GraphMode;
use sq_uikit::keyframe_viewport::KeyframeViewport;

use super::property::EffectProperty;
use crate::ec::magic_tracked_frames::MagicTrackedFrames;
use crate::ec::prelude::*;

/// What the model asks its owner to do (Swift's `onEdit`, `onSeek` ... hooks).
#[derive(Clone, Debug)]
pub enum EffectControlsEvent {
    /// `onEdit(clip, actionName, coalescing)`. `base` is the clip the panel believed the session held when it computed
    /// the edit: the session applies only what differs from it onto its live clip, so a change another panel made in
    /// between survives (`None`: write `clip` as it is).
    Edit {
        clip: Clip,
        name: String,
        coalescing: bool,
        base: Option<Clip>,
    },
    /// `onEditMany`: the shown clip and its peers changed together, ONE undo step. `bases` are their clips before the
    /// edit (matched by id, see `Edit::base`).
    EditMany {
        clips: Vec<Clip>,
        name: String,
        coalescing: bool,
        bases: Vec<Clip>,
    },
    /// `onAudioEdit`: edit of the linked audio clip (Volume shown under a video clip); `base` is the partner before.
    AudioEdit {
        clip: Clip,
        name: String,
        coalescing: bool,
        base: Option<Clip>,
    },
    /// `onGestureEnded`: the host ends the session's gesture too.
    GestureEnded,
    /// `onSeek`: jump the playhead (timeline time).
    Seek(Time),
    /// `onLibraryChange`.
    LibraryChange(EasingLibrary),
    /// `onPointerDown`: a press in the ruler stops playback.
    PointerDown,
    ScrubBegan,
    Scrub(Time),
    ScrubEnded,
    /// `onEffectCopied`: the session keeps it for Cmd-V on timeline clips while this panel is closed.
    EffectCopied(ClipEffect),
    /// `onBuiltInCopied`.
    BuiltInCopied {
        section: EffectSection,
        clip: Clip,
    },
    /// `onNotice`: a short message for the status line.
    Notice(String),
    /// `onEffectDefaultsChange`: the app stores them.
    EffectDefaultsChange(EffectDefaults),
    /// `onGraphEditorChanged`.
    GraphEditorChanged(bool),
    /// `onConvertToKeyframes`.
    ConvertToKeyframes {
        clip: Id,
        effect: Id,
    },
    /// `onReopenAsEffect`.
    ReopenAsEffect(Id),
    /// Analyze pressed on a Stabilizer row.
    StabilizeAnalyze(Id),
    StabilizeCancel,
    /// Cancel on a Gyroflow Stabilizer's Analyze row: the host stops the engine's analysis of this clip and options.
    GyroflowCancel {
        clip: Clip,
        options: sq_core_masks::stabilize_effect::GyroflowOptions,
    },
    /// FB-B3: Set Reference / Match of a Color effect was pressed; the host samples the Program frame.
    ColorMatch {
        effect: Id,
        request: crate::ec::color_match::ColorMatchRequest,
    },
    /// Adjust of the Color Graph row was pressed: the host shows the Color page.
    OpenColorPro,
    /// Reset of the Speed section: the host applies the factory speed (`reset_speed_with`).
    ResetSpeed,
    /// The frames the Magic mask delete took out of the matte store: the host registers them as a side step of the
    /// undo step the preceding `Edit` events make (`EditorSession::register_side_step` with the depth read before it).
    FrameSideStep {
        name: String,
        steps: Vec<MagicFrameStep>,
    },
}

/// One Magic frame delete and how to undo / redo it.
#[derive(Clone, Debug, PartialEq)]
pub struct MagicFrameStep {
    pub snapshot: sq_analysis::magic_matte_store_unavailable::MagicFrameSnapshot,
}

/// Which sections and rows of one clip are open. Session only: nothing is saved with the project or the app.
#[derive(Clone, Debug, PartialEq)]
pub struct TwirlState {
    pub collapsed: HashSet<EffectSection>,
    pub expanded: BTreeSet<EffectProperty>,
}

/// The shown clip's host item: a graphics clip whose layer Controls shows.
#[derive(Clone, Debug, PartialEq)]
pub struct ItemHost {
    pub host: Clip,
    pub layer: Id,
}

/// Summary keys of the sections, valid while `stamp` is the model's current (clip revision, magic revision, frame duration).
#[derive(Default)]
pub(crate) struct SummaryCache {
    pub(crate) stamp: Option<(u64, u64, Time)>,
    pub(crate) by_section: std::collections::HashMap<EffectSection, Vec<sq_core_model::keyframes_editing::SummaryKey>>,
}

/// State and edit logic of the Effect Controls panel for one clip.
pub struct EffectControlsModel {
    pub(crate) clip: Option<Clip>,
    /// Counts changes of `clip`: display caches (lanes, graph) rebuild when it moves, never on playhead ticks.
    pub(crate) clip_revision: u64,
    /// `summary_keys` per section, valid for one (clip revision, tracked-frames revision, frame duration); the draw path asks
    /// for every section every frame.
    pub(crate) summary_cache: std::cell::RefCell<SummaryCache>,
    /// Bumped by every setter that changes what a view reads.
    pub(crate) version: u64,
    /// Timeline time.
    pub(crate) playhead: Time,
    pub frame_duration: Time,
    /// Tracked frames of Magic masks (keys on the mask's row).
    pub magic_frames: MagicTrackedFrames,
    pub(crate) selection: BTreeSet<SummaryMember>,
    pub(crate) expanded: BTreeSet<EffectProperty>,
    pub(crate) collapsed_sections: HashSet<EffectSection>,
    /// Open groups of Color effects ("<effect id>/<switch key>"; Basic Correction, Creative, Curves ...).
    pub open_color_groups: BTreeSet<String>,
    /// Color effects already shown once: a new one starts collapsed.
    pub(crate) seen_color_effects: BTreeSet<Id>,
    /// Scale row: one linked value (chain button on) or Width and Height. Follows the clip when it changes.
    pub uniform_scale: bool,
    /// Property whose row or keys were last used: where a pasted single-property key set lands.
    pub focused_property: Option<EffectProperty>,
    pub(crate) key_clipboard: Option<KeyframeClipboard>,
    pub(crate) effect_clipboard: Option<ClipEffect>,
    pub(crate) last_copy_was_keys: bool,
    /// A built-in effect (Transform, Blend, Volume) copied as a whole: the section and the clip it came from.
    pub(crate) built_in_copy: Option<(EffectSection, Clip)>,
    /// Consulted before the model's own check (the app keeps the copy in the session).
    pub can_paste_built_in: Option<Box<dyn Fn() -> bool>>,
    /// Pastes the built-in copy through the session; true when it did something.
    pub on_paste_built_in: Option<Box<dyn FnMut() -> bool>>,
    /// The timeline the shown clip is in (Picture mask track choices); the app sets it.
    pub timeline: Option<Box<dyn Fn() -> Option<sq_core_model::Timeline>>>,
    /// What Track Forward / Backward follows (the Track choice on the mask row; session only).
    pub mask_track_mode: sq_core_masks::mask_motion::MaskTrackMode,
    /// Twirl-down state per clip (session only); `twirl_clip` is the clip whose state is on screen.
    pub(crate) twirl_clip: Option<Id>,
    pub(crate) twirl_memory: BTreeMap<Id, TwirlState>,
    /// Section header last clicked: Delete removes its effect (when removable) if no keys are selected.
    pub selected_section: Option<EffectSection>,
    pub graph_mode: GraphMode,
    /// Rows that chose their own graph mode; every other row follows `graph_mode`.
    pub graph_mode_by_property: BTreeMap<EffectProperty, GraphMode>,
    /// Graph Editor mode: the keyframe area shows one overlaid speed graph instead of the lanes.
    pub graph_editor: bool,
    /// Property rows selected for the Graph Editor.
    pub graph_properties: BTreeSet<EffectProperty>,
    /// Graph Editor filter: every animated property instead of the selected rows.
    pub graph_show_all: bool,
    /// Graph Editor: key moves snap to the playhead and to other keys.
    pub graph_snap: bool,
    pub easing_library: EasingLibrary,
    /// FB-W: the user's effect defaults ("Reset" goes back to these).
    pub effect_defaults: EffectDefaults,
    /// Multi-select: the other selected clips (as displayed); an edit of `clip` goes to them too.
    pub(crate) peers: Vec<Clip>,
    pub(crate) peer_gesture_base: Option<Vec<Clip>>,
    pub(crate) scrub_began: bool,
    /// Visible part of the clip in the keyframe area (nil = whole clip). Use `viewport`.
    pub(crate) zoom_state: Option<KeyframeViewport>,
    pub(crate) gesture_base: Option<Clip>,
    pub(crate) gesture_emitted: bool,
    /// Which hold (Hold or Hold Ahead) a key was when Toggle Hold last took it out of hold.
    pub(crate) held_kinds: BTreeMap<Id, Interpolation>,
    /// `clip_revision` right after the last Toggle Hold: `held_kinds` is only valid while the clip has not moved since.
    pub(crate) held_kinds_revision: Option<u64>,
    /// Undo name of the gesture's last emitted edit; an Esc cancel reuses it (never "Cancel").
    pub(crate) gesture_name: Option<String>,
    /// Key drag: steps change the shown clip only; the session gets one edit on mouse-up (`end_key_move`).
    pub(crate) defer_emit: bool,
    pub(crate) deferred_edit_name: Option<String>,
    /// Color parameter being dragged in the color panel: its edits share one undo step until anything else happens.
    pub(crate) color_gesture: Option<EffectProperty>,
    pub(crate) committing_color: bool,
    /// Linked audio clip of a video clip. Its Volume is shown (and edited) in the Audio group.
    pub(crate) audio_partner: Option<Clip>,
    /// The video clip's own volume line (restored before an edit is handed to the host).
    pub(crate) own_volume: Option<AnimatedProperty<f64>>,
    /// Partner start minus video start: the partner's keys are shown shifted by it (and shifted back on commit).
    pub(crate) partner_offset: Time,
    /// Graphics clip whose item (layer) Controls shows.
    pub(crate) item_host: Option<ItemHost>,
    /// Frame deletes made during a key drag, waiting for the drag's one undo step.
    pub(crate) pending_frame_steps: Vec<MagicFrameStep>,
    /// A session is wired (Swift `speedSession != nil`): the Speed section shows.
    pub(crate) has_session: bool,
    /// Upright size in px of the picture the shown clip displays (active format variant), copied from the session.
    pub(crate) display_picture: Option<Vec2>,
    /// Stabilizer rows: the running analysis and the host's questions (EffectControlsModel+Stabilize.swift).
    pub(crate) stabilize_run: Option<crate::ec::stabilize::StabilizeRunState>,
    pub(crate) gyroflow_revision: u64,
    pub stabilize_hooks: crate::ec::stabilize::StabilizeHooks,
    pub(crate) events: Vec<EffectControlsEvent>,
    pub(crate) ids: Box<dyn IdSource>,
}

/// A few ids taken from a source ahead of a call that gives the closure no source of its own.
// shortcut: when the reserve runs out ids count down from the maximum; a body needs one or two, upgrade if one needs more.
pub(crate) struct ReservedIds {
    ids: Vec<Id>,
    fallback: u128,
}

impl ReservedIds {
    pub(crate) fn take(from: &mut dyn IdSource, n: usize) -> ReservedIds {
        ReservedIds { ids: (0..n).map(|_| from.next_id()).collect(), fallback: u128::MAX }
    }
}

impl IdSource for ReservedIds {
    fn next_id(&mut self) -> Id {
        if self.ids.is_empty() {
            self.fallback -= 1;
            return Id::from_u128(self.fallback);
        }
        self.ids.remove(0)
    }
}

/// A key at `time` holding `value` with a fresh id (Swift `Keyframe(time:value:)`).
pub(crate) fn new_key<V>(ids: &mut dyn IdSource, time: Time, value: V) -> Keyframe<V> {
    Keyframe::new(ids.next_id(), time, value)
}

impl EffectControlsModel {
    pub fn new(ids: Box<dyn IdSource>) -> EffectControlsModel {
        EffectControlsModel {
            clip: None,
            clip_revision: 0,
            summary_cache: std::cell::RefCell::default(),
            version: 0,
            playhead: Time::ZERO,
            frame_duration: Time::new(1, 30),
            magic_frames: MagicTrackedFrames::new(sq_analysis::magic_matte_store_unavailable::MagicMatteStore::new()),
            selection: BTreeSet::new(),
            expanded: BTreeSet::new(),
            collapsed_sections: HashSet::new(),
            open_color_groups: BTreeSet::new(),
            seen_color_effects: BTreeSet::new(),
            uniform_scale: true,
            focused_property: None,
            key_clipboard: None,
            effect_clipboard: None,
            last_copy_was_keys: true,
            built_in_copy: None,
            can_paste_built_in: None,
            on_paste_built_in: None,
            timeline: None,
            mask_track_mode: sq_core_masks::mask_motion::MaskTrackMode::Position,
            twirl_clip: None,
            twirl_memory: BTreeMap::new(),
            selected_section: None,
            graph_mode: GraphMode::Speed,
            graph_mode_by_property: BTreeMap::new(),
            graph_editor: false,
            graph_properties: BTreeSet::new(),
            graph_show_all: false,
            graph_snap: true,
            easing_library: EasingLibrary::default(),
            effect_defaults: EffectDefaults::default(),
            peers: Vec::new(),
            peer_gesture_base: None,
            scrub_began: false,
            zoom_state: None,
            gesture_base: None,
            gesture_emitted: false,
            held_kinds: BTreeMap::new(),
            held_kinds_revision: None,
            gesture_name: None,
            defer_emit: false,
            deferred_edit_name: None,
            color_gesture: None,
            committing_color: false,
            audio_partner: None,
            own_volume: None,
            partner_offset: Time::ZERO,
            item_host: None,
            pending_frame_steps: Vec::new(),
            has_session: false,
            display_picture: None,
            stabilize_run: None,
            gyroflow_revision: 0,
            stabilize_hooks: crate::ec::stabilize::StabilizeHooks::default(),
            events: Vec::new(),
            ids,
        }
    }

    /// The events since the last call, oldest first (the owner drains them after every call into the model).
    pub fn take_events(&mut self) -> Vec<EffectControlsEvent> {
        std::mem::take(&mut self.events)
    }

    pub(crate) fn notice(&mut self, text: &str) {
        self.events.push(EffectControlsEvent::Notice(text.to_string()));
    }

    // MARK: Observed state (Swift `didSet`s are these setters)

    pub fn clip(&self) -> Option<&Clip> {
        self.clip.as_ref()
    }

    /// The row title of a property: a Magic mask's edge rows read Soft edge, Opacity and Grow / shrink.
    pub fn property_title(&self, p: &super::property::EffectProperty) -> String {
        if let super::property::EffectProperty::Mask(id, m) = p
            && self.clip().and_then(|c| c.mask(*id)).is_some_and(|k| k.source() == sq_core_model::MaskSource::Magic)
        {
            return m.magic_title().to_string();
        }
        p.title()
    }

    pub fn clip_revision(&self) -> u64 {
        self.clip_revision
    }

    pub fn version(&self) -> u64 {
        self.version
    }

    pub fn peers(&self) -> &[Clip] {
        &self.peers
    }

    pub fn playhead(&self) -> Time {
        self.playhead
    }

    pub fn set_playhead(&mut self, t: Time) {
        if self.playhead != t {
            self.playhead = t;
            self.version += 1;
            self.end_color_gesture();
        }
    }

    pub fn selection(&self) -> &BTreeSet<SummaryMember> {
        &self.selection
    }

    pub(crate) fn set_selection(&mut self, s: BTreeSet<SummaryMember>) {
        if self.selection != s {
            self.selection = s;
            self.version += 1;
            self.end_color_gesture();
        }
    }

    pub fn expanded(&self) -> &BTreeSet<EffectProperty> {
        &self.expanded
    }

    pub fn set_expanded(&mut self, e: BTreeSet<EffectProperty>) {
        if self.expanded != e {
            self.expanded = e;
            self.version += 1;
            self.save_twirl();
        }
    }

    pub fn collapsed_sections(&self) -> &HashSet<EffectSection> {
        &self.collapsed_sections
    }

    pub fn set_collapsed_sections(&mut self, c: HashSet<EffectSection>) {
        if self.collapsed_sections != c {
            self.collapsed_sections = c;
            self.version += 1;
            self.save_twirl();
        }
    }

    /// Swift `clip`'s `didSet`.
    pub(crate) fn store_clip(&mut self, new: Option<Clip>) {
        let old = std::mem::replace(&mut self.clip, new);
        if self.clip != old {
            self.clip_revision += 1;
            self.version += 1;
            self.close_curves_without_keys(old.as_ref());
        }
    }

    /// An opened curve row with fewer than two keys left has no curve to show: it closes itself (its arrow is gone too).
    fn close_curves_without_keys(&mut self, old: Option<&Clip>) {
        let (Some(old), Some(c)) = (old, self.clip.as_ref()) else { return };
        if old.id != c.id || self.expanded.is_empty() {
            return;
        }
        let gone: Vec<EffectProperty> = self
            .expanded
            .iter()
            .filter(|p| {
                let n = self.track(p, Some(c)).map_or(0, |t| t.key_ids().len());
                n < 2 && n < self.track(p, Some(old)).map_or(0, |t| t.key_ids().len())
            })
            .cloned()
            .collect();
        if !gone.is_empty() {
            let mut next = self.expanded.clone();
            for p in &gone {
                next.remove(p);
            }
            self.set_expanded(next);
        }
    }

    // MARK: Clip

    pub(crate) fn collapse_new_color_effects(&mut self, c: &Clip) {
        for e in &c.effects {
            if e.is_color() && self.seen_color_effects.insert(e.id) {
                self.collapsed_sections.insert(EffectSection::Effect { id: e.id, kind: e.kind.clone() });
                for k in sq_core_color::ColorEffectGroups::open_by_default() {
                    self.open_color_groups.insert(Self::color_group_id(e.id, k));
                }
            }
        }
        self.save_twirl();
    }

    pub fn color_group_id(effect: Id, key: &str) -> String {
        format!("{effect}/{key}")
    }

    pub fn toggle_color_group(&mut self, effect: Id, key: &str) {
        let g = Self::color_group_id(effect, key);
        if !self.open_color_groups.remove(&g) {
            self.open_color_groups.insert(g);
        }
        self.version += 1;
    }

    pub(crate) const MULTIBAND_PARAMETERS_KEY: &'static str = super::MULTIBAND_PARAMETERS_KEY;

    /// "All Parameters" of a Multiband Compressor: closed until the user opens it.
    pub fn is_multiband_parameters_open(&self, effect: Id) -> bool {
        self.open_color_groups.contains(&Self::color_group_id(effect, Self::MULTIBAND_PARAMETERS_KEY))
    }

    pub fn toggle_multiband_parameters(&mut self, effect: Id) {
        self.toggle_color_group(effect, Self::MULTIBAND_PARAMETERS_KEY);
    }

    /// Name of the clip that carries the effect (the shown clip, or its linked audio clip), nil when it is gone.
    pub fn multiband_clip_name(&self, effect: Id) -> Option<String> {
        if let Some(c) = &self.clip
            && c.effects.iter().any(|e| e.id == effect)
        {
            return Some(c.name.clone());
        }
        if let Some(p) = &self.audio_partner
            && p.effects.iter().any(|e| e.id == effect)
        {
            return Some(p.name.clone());
        }
        None
    }

    /// The curves of a Color effect (neutral when it has none).
    pub fn color_curves(&self, effect: Id) -> sq_core_model::RGBCurves {
        self.clip
            .as_ref()
            .and_then(|c| c.effects.iter().find(|e| e.id == effect))
            .map(|e| e.color_data().curves)
            .unwrap_or_default()
    }

    /// Writes the curves of a Color effect (a drag is one undo step through begin/end_gesture).
    pub fn set_color_curves(&mut self, effect: Id, curves: sq_core_model::RGBCurves) {
        let Some(mut c) = self.working_clip() else { return };
        let Some(i) = c.effects.iter().position(|e| e.id == effect) else { return };
        if !c.effects[i].is_color() {
            return;
        }
        let mut g = c.effects[i].color_data();
        if g.curves == curves {
            return;
        }
        g.curves = curves;
        c.effects[i].grade = Some(g);
        self.commit(c, "Edit Curves", None);
    }
}
