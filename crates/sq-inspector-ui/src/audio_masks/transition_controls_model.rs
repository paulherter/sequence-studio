// Swift: TransitionControlsModel.swift (TransitionEaseSource.swift lives in `ec/ease_sources.rs`)
//! What Controls shows while a transition is selected, the rules of the transition controls and their session side.

use std::ops::RangeInclusive;
use std::rc::Rc;

use sq_core_effects::transition::{
    ResolvedTransition, TransitionExt, TransitionKindElement, TransitionKindExt, TransitionMix,
};
use sq_core_effects::transition_custom_curve::TransitionEasing;
use sq_core_model::{TrackKind, Transition, TransitionAlignment, TransitionDirection, TransitionKind};
use sq_core_time::ease_names::ease_name;
use sq_core_time::{EasingCurve, Id, Time};
use sq_editor_session::{EditorSession, TransitionDefaults, TransitionStyleChange, TransitionTimingChange};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqmenu_model::SQMenuItem;

use crate::ec::ease_sources::{TransitionEaseSource, TransitionEaseTarget};

/// The clips a Stinger can play, offered in its Clip menu.
#[derive(Clone, Debug, PartialEq)]
pub struct StingerChoice {
    pub id: Id,
    pub name: String,
}

/// What Controls shows while a transition is selected (the Mac `syncTransitions` inputs of `TransitionControlsView.update`):
/// a clip-edge transition or a transition layer clip, with its resolved length and the menus' choices.
#[derive(Clone, Debug, PartialEq)]
pub struct TransitionControlsShown {
    pub transition: Transition,
    /// None: the transition's cut is gone.
    pub resolved: Option<ResolvedTransition>,
    pub frame_duration: Time,
    /// The clips a Stinger can play (id, name), offered in its Clip menu.
    pub stinger_media: Vec<StingerChoice>,
    /// The kind has a user default (FB-W): shown under the name, and Reset goes back to it.
    pub has_user_default: bool,
    /// A transition layer clip (DECISIONS 2026-10-05): a Type menu instead of the preset and default buttons.
    pub is_layer: bool,
}

impl TransitionControlsShown {
    pub fn new(transition: Transition, resolved: Option<ResolvedTransition>, frame_duration: Time) -> Self {
        TransitionControlsShown {
            transition,
            resolved,
            frame_duration,
            stinger_media: Vec::new(),
            has_user_default: false,
            is_layer: false,
        }
    }
}

/// The rows under the name, in the Mac stack order.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Row {
    Kind,
    Duration,
    Alignment,
    Element(String),
    StingerClip,
    StingerCut,
    Color,
    Easing,
    /// The ☆ My Curves list with Save to My Curves.
    MyCurves,
    Direction,
    Softness,
    Border,
    BorderColor,
    MotionBlur,
}

/// The Stinger Clip menu: titles, ids and the selected index.
#[derive(Clone, Debug, PartialEq)]
pub struct StingerItems {
    pub titles: Vec<String>,
    pub ids: Vec<Option<Id>>,
    pub selected: usize,
}

/// The rules of the transition controls, shared by the Mac `TransitionControlsView` and the draw-list
/// `TransitionControlsDraw`: which rows a kind shows, the slider units, the alignment choices, the held-frame note.
pub struct TransitionControlsLogic;

impl TransitionControlsLogic {
    /// Pop-up item after the presets: opens the curve editor on a hand-drawn curve.
    pub const CUSTOM_EASING_TITLE: &'static str = ease_name::CUSTOM_MENU;
    pub const SOFTNESS_RANGE: RangeInclusive<f64> = 0.0..=50.0;
    pub const BORDER_RANGE: RangeInclusive<f64> = 0.0..=10.0;
    pub const STINGER_CUT_RANGE: RangeInclusive<f64> = 0.0..=100.0;

    /// Curves offered for a transition (hold would turn it into a cut at the end).
    pub fn easings() -> Vec<EasingCurve> {
        EasingCurve::transition_presets()
    }

    /// Index of the Custom item in the easing pop-up.
    pub fn custom_easing_index() -> usize {
        Self::easings().len()
    }

    /// Pop-up index of a curve: its preset, else Custom.
    pub fn easing_index(c: &EasingCurve) -> usize {
        let Some(p) = c.matching_transition_preset() else { return Self::custom_easing_index() };
        Self::easings().iter().position(|e| *e == p).unwrap_or_else(Self::custom_easing_index)
    }

    /// Motion blur slider: percent of a 360 degree shutter (100 % = one frame).
    pub fn blur_percent(shutter: f64) -> f64 {
        (shutter * 100.0).round()
    }
    pub fn shutter(percent: f64) -> f64 {
        percent.max(0.0) / 100.0
    }
    /// Softness slider: percent of the frame.
    pub fn softness_percent(s: f64) -> f64 {
        (s * 100.0).round()
    }
    /// An element transition blurs through its clip's shutter, which stops at one frame (360 degrees).
    pub fn blur_range(k: TransitionKind) -> RangeInclusive<f64> {
        0.0..=if k.is_element() { 100.0 } else { 200.0 }
    }

    /// Duration field value: the transition's length in whole frames.
    pub fn duration_frames(t: Time, frame_duration: Time) -> f64 {
        t.frame_index(frame_duration) as f64
    }
    /// A field value back to a time: whole frames, at least one.
    pub fn duration(frames: f64, frame_duration: Time) -> Time {
        frame_duration * (frames.round() as i64).max(1)
    }

    /// The length shown: the resolved one (clamped to the media), else the stored one.
    pub fn shown_duration(s: &TransitionControlsShown) -> Time {
        s.resolved.as_ref().map_or(s.transition.duration, |r| r.duration())
    }

    pub fn subtitle(s: &TransitionControlsShown) -> String {
        if s.is_layer {
            return "Transition Layer \u{b7} everything below".to_string();
        }
        let base =
            if s.transition.kind.track_kind() == TrackKind::Video { "Video Transition" } else { "Audio Transition" };
        format!("{base}{}", if s.has_user_default { " \u{b7} Your Default" } else { "" })
    }

    pub fn reset_tip(has_user_default: bool) -> &'static str {
        if has_user_default { "Reset to Your Default" } else { "Reset to Default" }
    }

    /// Alignment choices: two-sided transitions (and layers) pick center / start / end; Custom only while it is set.
    pub fn alignment_options(s: &TransitionControlsShown) -> Vec<TransitionAlignment> {
        let mut options = if Self::is_two_sided(s) {
            vec![TransitionAlignment::Center, TransitionAlignment::StartAtCut, TransitionAlignment::EndAtCut]
        } else {
            Vec::new()
        };
        if s.transition.alignment == TransitionAlignment::Custom {
            options.push(TransitionAlignment::Custom);
        }
        options
    }
    pub fn is_two_sided(s: &TransitionControlsShown) -> bool {
        s.is_layer || !s.transition.is_single_sided()
    }
    /// The alignment the Alignment box shows. A one-sided transition has no choice (the box stays disabled) but is not
    /// blank: a head fade runs from the clip's start edge on (Start), a tail fade up to its end edge (End).
    pub fn shown_alignment(s: &TransitionControlsShown) -> TransitionAlignment {
        let tr = &s.transition;
        if Self::is_two_sided(s) {
            return tr.alignment;
        }
        if tr.outgoing.is_some() { TransitionAlignment::EndAtCut } else { TransitionAlignment::StartAtCut }
    }

    /// The rows a transition shows, in order.
    pub fn rows(s: &TransitionControlsShown) -> Vec<Row> {
        let k = s.transition.kind;
        let mut out: Vec<Row> = Vec::new();
        if s.is_layer {
            out.push(Row::Kind);
        }
        // Order: Duration, Alignment, Easing, then the options of the kind.
        out.extend([Row::Duration, Row::Alignment]);
        if k.uses_easing() {
            out.push(Row::Easing);
        }
        out.extend(k.element_params().into_iter().map(|p| Row::Element(p.key)));
        if k.is_stinger() {
            out.push(Row::StingerClip);
        }
        if k.is_stinger() && s.transition.stinger.is_some() {
            out.push(Row::StingerCut);
        }
        if k.uses_color() {
            out.push(Row::Color);
        }
        if k.uses_direction() {
            out.push(Row::Direction);
        }
        if k.uses_softness() {
            out.push(Row::Softness);
        }
        // Edge transitions only: a transition layer has no stored border.
        if !s.is_layer && k.uses_border() {
            out.extend([Row::Border, Row::BorderColor]);
        }
        if k.uses_motion_blur() {
            out.push(Row::MotionBlur);
        }
        out
    }

    /// The row titles (the Mac 70 pt right-aligned labels).
    pub fn title(r: &Row, kind: TransitionKind) -> String {
        match r {
            Row::Kind => "Type".to_string(),
            Row::Duration => "Duration".to_string(),
            Row::Alignment => "Alignment".to_string(),
            Row::Element(key) => {
                kind.element_params().into_iter().find(|p| p.key == *key).map_or_else(|| key.clone(), |p| p.title)
            }
            Row::StingerClip => "Clip".to_string(),
            Row::StingerCut => "Cut Point".to_string(),
            Row::Color => "Color".to_string(),
            Row::Easing => "Easing".to_string(),
            Row::MyCurves => "\u{2606} My Curves".to_string(),
            Row::Direction => "Direction".to_string(),
            Row::Softness => "Softness".to_string(),
            Row::Border => "Border".to_string(),
            Row::BorderColor => "Border Color".to_string(),
            Row::MotionBlur => "Motion Blur".to_string(),
        }
    }

    /// The Stinger Clip menu: None, the candidates, and "Missing Clip" for a picked clip that is gone; the index shown.
    pub fn stinger_items(s: &TransitionControlsShown) -> StingerItems {
        let mut titles = vec!["None".to_string()];
        let mut ids: Vec<Option<Id>> = vec![None];
        for m in &s.stinger_media {
            titles.push(m.name.clone());
            ids.push(Some(m.id));
        }
        let Some(id) = s.transition.stinger.as_ref().map(|st| st.media) else {
            return StingerItems { titles, ids, selected: 0 };
        };
        if !s.stinger_media.iter().any(|m| m.id == id) {
            titles.push("Missing Clip".to_string());
            ids.push(Some(id));
        }
        let selected = ids.iter().position(|x| *x == Some(id)).unwrap_or(0);
        StingerItems { titles, ids, selected }
    }

    /// Dip color shown (display-encoded RGB bytes).
    pub fn color(s: &TransitionControlsShown) -> [u8; 3] {
        TransitionMix::dip_color(s.transition.kind, s.transition.color.as_deref())
    }
    pub fn border_color(s: &TransitionControlsShown) -> [u8; 3] {
        s.transition.border_color.as_deref().and_then(|c| <[u8; 3]>::try_from(c).ok()).unwrap_or([255, 255, 255])
    }

    /// The note under the rows while the transition is shortened or holds frames; None when it plays in full.
    pub fn note(s: &TransitionControlsShown) -> Option<&'static str> {
        let r = s.resolved.as_ref().filter(|r| r.is_clamped())?;
        if r.held_before > 0 && r.held_after > 0 {
            return Some("Held frames: neither clip has media beyond the cut, so both edge frames repeat (striped).");
        }
        if r.is_held() {
            return Some(
                "Held frame: a clip has no media beyond the cut on one side, so its edge frame repeats (striped).",
            );
        }
        if s.transition.kind.is_stinger() {
            return Some("Shortened: a clip next to the cut is shorter than the stinger's part on its side.");
        }
        Some("Shortened: the clips do not have enough media beyond the cut for the full length.")
    }

    /// Rows of the right-click menu (FB-W); empty for stingers.
    pub fn context_items(
        kind: TransitionKind,
        has_user_default: bool,
        reset: Rc<dyn Fn()>,
        use_as_default: Rc<dyn Fn()>,
        reset_default_to_factory: Rc<dyn Fn()>,
    ) -> Vec<SQMenuItem> {
        if kind.is_stinger() {
            return Vec::new();
        }
        let mut reset_row = SQMenuItem::new(if has_user_default { "Reset to Your Default" } else { "Reset" });
        reset_row.action = Some(reset);
        let mut use_row = SQMenuItem::new(&SQL10n::format("Use as Default for %@", &[&SQL10n::string(kind.name())]));
        use_row.action = Some(use_as_default);
        let mut factory_row = SQMenuItem::new("Reset Default to Factory");
        factory_row.is_enabled = has_user_default;
        factory_row.action = Some(reset_default_to_factory);
        vec![reset_row, SQMenuItem::separator(), use_row, factory_row]
    }
}

/// The transition controls' session side, translated from the Mac shell wiring (App/Sources/EditorPanels+Transitions.swift):
/// which transition is shown (a clip-edge transition, else the one selected transition layer clip) and every edit, sent
/// to the layer or to the edge transition. Both platforms' hosts call it.
///
/// The Swift class held the session; here every call takes it. The session's selected transition has no public getter,
/// so the host keeps `selected_transition` in step with it (the field is the Swift `session.selectedTransition`).
#[derive(Clone, Debug, Default)]
pub struct TransitionControlsActions {
    /// The selected clip-edge transition of the session.
    pub selected_transition: Option<Id>,
    /// Status line texts (Swift `onStatus`: Use as Default, Reset Default to Factory), in call order.
    status: Vec<String>,
}

impl TransitionControlsActions {
    pub fn new() -> Self {
        TransitionControlsActions::default()
    }

    /// The status line texts since the last call.
    pub fn take_status(&mut self) -> Vec<String> {
        std::mem::take(&mut self.status)
    }

    /// The one selected clip when it is a transition layer (and no clip-edge transition is selected).
    pub fn selected_layer(&self, session: &EditorSession) -> Option<Id> {
        if self.selected_transition.is_some() || session.selection().len() != 1 {
            return None;
        }
        let id = *session.selection().iter().next()?;
        session.transition_layer_info(id)?;
        Some(id)
    }

    /// What Controls shows now; None: no transition selected (Controls shows the clip).
    pub fn shown(&self, session: &EditorSession) -> Option<TransitionControlsShown> {
        let fd = session.active_timeline()?.format.frame_duration;
        if let Some(id) = self.selected_layer(session)
            && let Some(info) = session.transition_layer_info(id)
        {
            let mut s = TransitionControlsShown::new(info.transition, Some(info.resolved), fd);
            s.is_layer = true;
            return Some(s);
        }
        let id = self.selected_transition?;
        let info = session.transition_info(id)?;
        let stingers = if info.transition.kind.is_stinger() {
            session.stinger_candidates().into_iter().map(|m| StingerChoice { id: m.id, name: m.name }).collect()
        } else {
            Vec::new()
        };
        let has_user_default = session.has_transition_default(info.transition.kind);
        let mut s = TransitionControlsShown::new(info.transition, info.resolved, fd);
        s.stinger_media = stingers;
        s.has_user_default = has_user_default;
        Some(s)
    }

    /// The curve popover's source for Easing > Custom.
    pub fn ease_source<'a>(&self, session: &'a mut EditorSession) -> Option<TransitionEaseSource<'a>> {
        if let Some(id) = self.selected_layer(session) {
            return Some(TransitionEaseSource::new(session, TransitionEaseTarget::Layer(id)));
        }
        let id = self.selected_transition?;
        Some(TransitionEaseSource::new(session, TransitionEaseTarget::Edge(id)))
    }

    pub fn set_kind(&self, session: &mut EditorSession, k: TransitionKind) {
        let Some(id) = self.selected_layer(session) else { return };
        session.set_transition_layer_kind(id, k);
    }

    pub fn set_duration(&self, session: &mut EditorSession, d: Time) {
        if let Some(id) = self.selected_layer(session) {
            session.set_transition_layer_duration(id, d);
            return;
        }
        let Some(id) = self.selected_transition else { return };
        session.set_transition(id, &TransitionTimingChange { duration: Some(d), ..Default::default() }, false);
    }

    /// A custom alignment keeps its offset; the named ones are fully described by the alignment itself.
    pub fn set_alignment(&self, session: &mut EditorSession, a: TransitionAlignment) {
        if let Some(id) = self.selected_layer(session) {
            session.set_transition_layer_alignment(id, a);
            return;
        }
        let Some(id) = self.selected_transition else { return };
        session.set_transition(id, &TransitionTimingChange { alignment: Some(a), ..Default::default() }, false);
    }

    pub fn set_easing(&self, session: &mut EditorSession, c: EasingCurve) {
        if let Some(id) = self.selected_layer(session) {
            session.set_transition_layer_style(id, "Easing", false, |l| l.easing = Some(c));
            return;
        }
        let Some(id) = self.selected_transition else { return };
        session.set_transition_style(id, &TransitionStyleChange { easing: Some(c), ..Default::default() }, false);
    }

    pub fn set_direction(&self, session: &mut EditorSession, d: TransitionDirection) {
        if let Some(id) = self.selected_layer(session) {
            session.set_transition_layer_style(id, "Direction", false, |l| l.direction = Some(d));
            return;
        }
        let Some(id) = self.selected_transition else { return };
        session.set_transition_style(id, &TransitionStyleChange { direction: Some(d), ..Default::default() }, false);
    }

    pub fn set_reversed(&self, session: &mut EditorSession, on: bool) {
        if let Some(id) = self.selected_layer(session) {
            session
                .set_transition_layer_style(id, "Reverse", false, |l| l.reversed = if on { Some(true) } else { None });
            return;
        }
        let Some(id) = self.selected_transition else { return };
        session.set_transition_style(id, &TransitionStyleChange { reversed: Some(on), ..Default::default() }, false);
    }

    pub fn set_softness(&self, session: &mut EditorSession, s: f64, continues_gesture: bool) {
        if let Some(id) = self.selected_layer(session) {
            session.set_transition_layer_style(id, "Softness", continues_gesture, |l| l.softness = Some(s));
            return;
        }
        let Some(id) = self.selected_transition else { return };
        session.set_transition_style(
            id,
            &TransitionStyleChange { softness: Some(s), ..Default::default() },
            continues_gesture,
        );
    }

    pub fn set_motion_blur(&self, session: &mut EditorSession, b: f64, continues_gesture: bool) {
        if let Some(id) = self.selected_layer(session) {
            session.set_transition_layer_style(id, "Motion Blur", continues_gesture, |l| l.motion_blur = Some(b));
            return;
        }
        let Some(id) = self.selected_transition else { return };
        session.set_transition_style(
            id,
            &TransitionStyleChange { motion_blur: Some(b), ..Default::default() },
            continues_gesture,
        );
    }

    pub fn set_color(&self, session: &mut EditorSession, rgb: Vec<u8>, continues_gesture: bool) {
        if let Some(id) = self.selected_layer(session) {
            session.set_transition_layer_style(id, "Color", continues_gesture, |l| l.color = Some(rgb));
            return;
        }
        let Some(id) = self.selected_transition else { return };
        session.set_transition_style(
            id,
            &TransitionStyleChange { color: Some(rgb), ..Default::default() },
            continues_gesture,
        );
    }

    pub fn set_border_width(&self, session: &mut EditorSession, w: f64, continues_gesture: bool) {
        let Some(id) = self.selected_transition else { return };
        session.set_transition_style(
            id,
            &TransitionStyleChange { border_width: Some(w), ..Default::default() },
            continues_gesture,
        );
    }

    pub fn set_border_color(&self, session: &mut EditorSession, rgb: Vec<u8>, continues_gesture: bool) {
        let Some(id) = self.selected_transition else { return };
        session.set_transition_style(
            id,
            &TransitionStyleChange { border_color: Some(rgb), ..Default::default() },
            continues_gesture,
        );
    }

    pub fn set_stinger_media(&self, session: &mut EditorSession, m: Option<Id>) {
        let Some(id) = self.selected_transition else { return };
        session.set_transition_stinger(id, m, None, false);
    }

    pub fn set_stinger_cut(&self, session: &mut EditorSession, c: f64, continues_gesture: bool) {
        let Some(id) = self.selected_transition else { return };
        let Some(media) = session.transition_info(id).and_then(|i| i.transition.stinger).map(|s| s.media) else {
            return;
        };
        session.set_transition_stinger(id, Some(media), Some(c), continues_gesture);
    }

    /// A typed or picked element parameter (FB-G).
    pub fn set_element_param(&self, session: &mut EditorSession, key: &str, value: f64) {
        if let Some(id) = self.selected_layer(session) {
            session.set_transition_layer_param(id, key, value, false);
            return;
        }
        let Some(id) = self.selected_transition else { return };
        session.set_transition_params(id, &[(key.to_string(), value)].into(), false);
    }

    /// A dragged element parameter: every change as it moves; `continues_gesture` false for the first.
    pub fn set_element_param_live(&self, session: &mut EditorSession, key: &str, value: f64, continues_gesture: bool) {
        if let Some(id) = self.selected_layer(session) {
            session.set_transition_layer_param(id, key, value, continues_gesture);
            return;
        }
        let Some(id) = self.selected_transition else { return };
        session.set_transition_params(id, &[(key.to_string(), value)].into(), continues_gesture);
    }

    /// FB-W: the shown transition becomes the default of its kind.
    pub fn use_as_default(&mut self, session: &mut EditorSession) {
        let Some(id) = self.selected_transition else { return };
        let Some(kind) = session.transition_info(id).map(|i| i.transition.kind) else { return };
        if session.use_transition_as_default(id) {
            self.status
                .push(SQL10n::format("New %@ transitions now start with this look.", &[&SQL10n::string(kind.name())]));
        }
    }

    /// Reset; `defaults` are the preferences' standard lengths (Swift reads them from the app settings).
    pub fn reset(&self, session: &mut EditorSession, defaults: &TransitionDefaults) {
        let Some(id) = self.selected_transition else { return };
        session.reset_transition(id, defaults);
    }

    pub fn reset_default_to_factory(&mut self, session: &mut EditorSession) {
        let Some(id) = self.selected_transition else { return };
        let Some(kind) = session.transition_info(id).map(|i| i.transition.kind) else { return };
        session.reset_transition_default_to_factory(kind);
        self.status.push(SQL10n::format("%@ is back to its built-in default.", &[&SQL10n::string(kind.name())]));
    }
}
