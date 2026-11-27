// Swift: SQAppShell/EffectsHost.swift (onApply, onDrag), TimelinePanel+Drop.swift (effect drops)
//! The Effects panel as an app host: delegates to [`EffectsPanelHost`], keeps the drag ghost that follows the pointer and
//! turns its events into [`EffectsDeferred`] for the app root, which knows the timeline, the Effect Controls frame and
//! the Library's presets. The session calls of a drop or a double click live here as plain functions.

use sq_app_shell::{AppHost, HostCx};
use sq_core_effects::effect_preset::ApplyMode;
use sq_core_effects::transition::TransitionPoint;
use sq_core_model::{TrackKind, TransitionKind};
use sq_core_time::Id;
use sq_draw::theme::{radius, type_size};
use sq_draw::{A11y, Canvas, DrawTheme, InputEvent, TextAlign};
use sq_draw_library::effects::effects_catalog::EffectsCatalog;
use sq_draw_library::effects::effects_draw_panel::{DragPhase, EffectsDrawPanel, EffectsEvent, EffectsPanelHost};
use sq_draw_timeline::EffectDrop;
use sq_editor_session::{Change, EdgeSelection, EditorSession, EffectDragPayload, TransitionDefaults, TransitionScope};
use sq_library::preset_store::{PresetItem, PresetKind};
use sq_uikit::controls_grid::{CGPoint, CGRect};

/// What the root answers: it holds the timeline, the dock frames and the presets.
#[derive(Clone, Debug)]
pub enum EffectsDeferred {
    /// Double click or Return on an item.
    Apply(String),
    /// The drag moved to `at` (window points).
    Moved(Vec<String>, CGPoint),
    /// The drag was released at `at` (window points).
    Dropped(Vec<String>, CGPoint),
    /// The drag ended without a drop (Escape, back on the panel).
    Canceled,
    /// Any other panel request (menus, folder names).
    Other(EffectsEvent),
}

/// The Effects panel in a dock slot.
pub struct EffectsHost {
    inner: EffectsPanelHost,
    frame: CGRect,
    /// Title and window position of the dragged item, drawn at the cursor.
    ghost: Option<(String, CGPoint)>,
    deferred: Vec<EffectsDeferred>,
    /// The presets the panel lists now, to see when the Library's change.
    listed: Vec<PresetItem>,
}

impl EffectsHost {
    const GHOST_HEIGHT: f64 = 22.0;
    const GHOST_PADDING: f64 = 10.0;
    /// Gap between the cursor and the ghost's corner, so the target under it stays visible.
    const GHOST_OFFSET: f64 = 12.0;

    /// A host around `panel`.
    pub fn new(panel: EffectsDrawPanel) -> EffectsHost {
        EffectsHost {
            inner: EffectsPanelHost::new(panel),
            frame: CGRect::default(),
            ghost: None,
            deferred: Vec::new(),
            listed: Vec::new(),
        }
    }

    /// The panel host (panel and tile atlas).
    pub fn panel_host(&mut self) -> &mut EffectsPanelHost {
        &mut self.inner
    }

    /// Lists the Library's saved `presets` under "Presets"; the rows are rebuilt only when they differ from the last call.
    pub fn list_presets(&mut self, presets: &[PresetItem]) {
        if self.listed == presets {
            return;
        }
        self.listed = presets.to_vec();
        self.inner.panel.set_preset_entries(EffectsCatalog::preset_entries(presets));
    }

    /// Whether a drag runs, so the root keeps drawing frames.
    pub fn is_dragging(&self) -> bool {
        self.ghost.is_some()
    }

    /// What waits for the app root, in the order it happened.
    pub fn take_events(&mut self) -> Vec<EffectsDeferred> {
        std::mem::take(&mut self.deferred)
    }

    /// Queues `event` as if the panel had raised it (tests of the root).
    #[cfg(test)]
    pub(crate) fn defer(&mut self, event: EffectsDeferred) {
        self.deferred.push(event);
    }

    fn title_of(&self, id: &str) -> String {
        self.inner.panel.all_entries().into_iter().find(|e| e.id == id).map_or_else(|| id.to_string(), |e| e.title)
    }

    fn route(&mut self) {
        for event in self.inner.take_events() {
            // Panel-local points become window points here; the ghost shows at once on the first move.
            let window = |p: CGPoint| CGPoint::new(p.x + self.frame.x, p.y + self.frame.y);
            match event {
                EffectsEvent::Apply(id) => self.deferred.push(EffectsDeferred::Apply(id)),
                EffectsEvent::Drag(ids, DragPhase::Moved, p) => {
                    let at = window(p);
                    let title = match (&self.ghost, ids.first()) {
                        (Some((t, _)), _) => t.clone(),
                        (None, Some(id)) => self.title_of(id),
                        (None, None) => continue,
                    };
                    self.ghost = Some((title, at));
                    self.deferred.push(EffectsDeferred::Moved(ids, at));
                }
                EffectsEvent::Drag(ids, DragPhase::Ended, p) => {
                    self.ghost = None;
                    self.deferred.push(EffectsDeferred::Dropped(ids, window(p)));
                }
                EffectsEvent::Drag(_, DragPhase::Canceled, _) => {
                    self.ghost = None;
                    self.deferred.push(EffectsDeferred::Canceled);
                }
                other => self.deferred.push(EffectsDeferred::Other(other)),
            }
        }
    }

    /// The ghost at the cursor; the root calls it after every panel so it floats on top.
    pub fn draw_ghost(&self, c: &mut Canvas, t: &DrawTheme, cx: &HostCx) {
        let Some((title, at)) = &self.ghost else { return };
        let m = cx.measure();
        let font = type_size::BODY as f64;
        let w = m.width(title, font, m.medium()).ceil() + 2.0 * Self::GHOST_PADDING;
        let r = CGRect::new(at.x + Self::GHOST_OFFSET, at.y + Self::GHOST_OFFSET, w, Self::GHOST_HEIGHT);
        let control = radius::CONTROL as f64;
        let medium = c.medium();
        c.fill_rounded(r, control, t.accent().with_alpha(0.85));
        c.stroke_rounded(r, control, 1.0, t.accent());
        c.draw_text_in(title, r, font, t.label(), TextAlign::Center, 0.0, medium);
    }
}

impl AppHost for EffectsHost {
    fn sync(&mut self, session: &EditorSession) {
        self.inner.sync(session);
    }

    fn layout(&mut self, frame: CGRect, cx: &mut HostCx) {
        self.frame = frame;
        self.inner.layout(frame, cx);
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        self.inner.draw(c, t, cx);
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let taken = self.inner.handle(e, cx);
        self.route();
        taken
    }

    fn a11y(&self, a: &mut A11y) {
        self.inner.a11y(a);
        self.push_nodes(a);
    }

    fn a11y_action(&mut self, id: accesskit::NodeId, action: sq_app_shell::A11yAction, _cx: &mut HostCx) -> bool {
        self.run_action(id, action)
    }

    fn on_change(&mut self, changes: Change, cx: &mut HostCx) {
        self.inner.on_change(changes, cx);
    }
}

/// The library preset an Effects panel id names (`preset.<uuid>`, or the timeline's `preset:<uuid>`).
fn preset_in<'a>(id: &str, presets: &'a [PresetItem]) -> Option<&'a PresetItem> {
    let uuid = id.strip_prefix("preset.").or_else(|| id.strip_prefix("preset:")).and_then(Id::parse)?;
    presets.iter().find(|p| p.id == uuid)
}

/// What an apply needs besides the session: the Library's presets and the remembered defaults.
pub struct EffectsApply<'a> {
    /// The Library's saved presets.
    pub presets: &'a [PresetItem],
    /// The remembered preset apply mode.
    pub mode: ApplyMode,
    /// The transition lengths of Settings.
    pub transitions: TransitionDefaults,
    /// The timeline's selected edges (a transition goes on these, else on the selected clips).
    pub edges: Option<EdgeSelection>,
}

/// Swift `EffectsApply.targetNoun`: what a plain effect needs selected.
fn target_noun(kind: &str) -> &'static str {
    if sq_text::text_presets::TextPresetCatalog::is_text_preset_id(kind) {
        "a text layer"
    } else if sq_core_model::ClipEffect::is_audio_kind(kind) {
        "an audio clip"
    } else {
        "a video clip"
    }
}

fn failure(session: &EditorSession, what: &str) -> String {
    session
        .last_error()
        .filter(|e| !e.is_empty())
        .map_or_else(|| format!("{what} could not be applied."), str::to_string)
}

/// Double click, Return or a drop on Effect Controls: applies `ids` to the selection (Swift `onApply`). Returns the
/// status line when something went wrong.
pub fn apply_to_selection(session: &mut EditorSession, ids: &[String], with: &EffectsApply) -> Option<String> {
    let mut status = None;
    for id in ids {
        let ok = if EffectDragPayload::is_adjustment_layer(id) {
            session.stop_playback();
            session.add_adjustment_layer(None, None, EffectDragPayload::adjustment_layer_duration()).is_some()
        } else if let Some(kind) = EffectDragPayload::transition_kind(id) {
            let scope =
                if kind.track_kind() == TrackKind::Video { TransitionScope::Video } else { TransitionScope::Audio };
            session.stop_playback();
            session.apply_default_transitions(scope, with.edges.as_ref(), Some(kind), &with.transitions) > 0
        } else if let Some(preset) = preset_in(id, with.presets) {
            session.stop_playback();
            if preset.kind == PresetKind::Transition {
                session.apply_transition_preset(preset, with.edges.as_ref())
            } else {
                session.apply_preset(preset, None, with.mode)
            }
        } else {
            session.flush_follow_selection();
            let selected = session.selection().clone();
            if session.add_effect(id, &selected) {
                continue;
            }
            status = Some(format!(
                "Select {} first, then double-click {}.",
                target_noun(id),
                sq_core_model::EffectCatalog::title_for(id)
            ));
            continue;
        };
        if !ok {
            status = Some(failure(session, id));
        }
    }
    status
}

/// Effects or one effect preset released on clips (Swift `LibraryDropRoute.dropOnClips`, also the Effect Controls drop):
/// a preset applies with the saved mode, effects are added one by one (a refusal says why). Transitions are skipped.
/// Returns the last status line.
pub fn drop_on_clips(
    session: &mut EditorSession,
    ids: &[String],
    targets: &std::collections::BTreeSet<Id>,
    with: &EffectsApply,
) -> Option<String> {
    let first = ids.first()?;
    if targets.is_empty() || EffectDragPayload::transition_kind(first).is_some() {
        return None;
    }
    // The Adjustment Layer entry is a clip of its own, not an effect for the clips it lands on.
    let ids: Vec<&String> = ids
        .iter()
        .filter(|i| EffectDragPayload::transition_kind(i).is_none() && !EffectDragPayload::is_adjustment_layer(i))
        .collect();
    if let Some(preset) = preset_in(first, with.presets) {
        let preset = preset.clone();
        return (!session.apply_preset(&preset, Some(targets), with.mode))
            .then(|| session.last_error().unwrap_or("The preset could not be applied.").to_string());
    }
    let mut status = None;
    for kind in ids {
        if !session.add_effect(kind, targets) {
            status = Some(format!("{} needs {}.", sq_core_model::EffectCatalog::title_for(kind), target_noun(kind)));
        }
    }
    status
}

/// A release over the timeline: applies `ids` where the hover lit a target (Swift `TimelinePanel+Drop`). Returns the
/// status line when something went wrong.
pub fn apply_drop(
    session: &mut EditorSession,
    ids: &[String],
    drop: EffectDrop,
    with: &EffectsApply,
) -> Option<String> {
    let kind = ids.first().and_then(|id| EffectDragPayload::transition_kind(id));
    let ok = match (drop, kind) {
        (EffectDrop::Clip(hit), _) => {
            let targets = session.effect_drop_targets(hit);
            let mut ok = true;
            for id in ids {
                ok &= match preset_in(id, with.presets) {
                    Some(p) if p.kind == PresetKind::Transition => false,
                    Some(p) => session.apply_preset(p, Some(&targets), with.mode),
                    None => session.add_effect(id, &targets),
                };
            }
            ok
        }
        (EffectDrop::Transition(t), Some(kind)) => drop_transition(session, kind, &t, &with.transitions),
        (EffectDrop::Layer(l), Some(kind)) => {
            session.add_transition_layer(kind, l.track, l.start, l.duration, l.cut).is_some()
        }
        (EffectDrop::Layer(l), None) if ids.first().is_some_and(|i| EffectDragPayload::is_adjustment_layer(i)) => {
            session.stop_playback();
            session.add_adjustment_layer(Some(l.start), Some(l.track), l.duration).is_some()
        }
        _ => false,
    };
    (!ok).then(|| failure(session, ids.first().map_or("The effect", String::as_str)))
}

fn drop_transition(
    session: &mut EditorSession,
    kind: TransitionKind,
    t: &sq_timeline_ui::TransitionDropTarget,
    defaults: &TransitionDefaults,
) -> bool {
    let head = session.add_transition(kind, t.track, t.point, t.alignment, defaults).is_some();
    // An element transition on the middle of a clip gets its Out as well.
    match t.point {
        TransitionPoint::Head(clip) if t.both_ends => {
            head & session.add_transition(kind, t.track, TransitionPoint::Tail(clip), t.alignment, defaults).is_some()
        }
        _ => head,
    }
}

/// The length a transition layer dropped on an empty spot gets.
pub fn layer_duration(session: &EditorSession, ids: &[String], defaults: &TransitionDefaults) -> sq_core_time::Time {
    if ids.first().is_some_and(|i| EffectDragPayload::is_adjustment_layer(i)) {
        return EffectDragPayload::adjustment_layer_duration();
    }
    ids.first()
        .and_then(|id| EffectDragPayload::transition_kind(id))
        .map_or(sq_core_time::Time::seconds(1), |k| session.transition_layer_duration(k, defaults))
}

mod access;

#[cfg(test)]
mod tests;
