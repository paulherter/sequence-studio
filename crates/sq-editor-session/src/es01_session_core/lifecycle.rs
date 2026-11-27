//! Session state accessors, sequence switching and tabs, selection, follow selection, playhead and transport.

use std::collections::BTreeSet;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use sq_core_color::ProjectInputColorExt as _;
use sq_core_edit::playback::{PlaybackRate, ShuttleAction};
use sq_core_edit::playback_bounds::{PlaybackAction, PlaybackBounds};
use sq_core_edit::source_edit_placement::SourceEditPlacementExt;
use sq_core_edit::timeline_bundle::TimelineBundleExt;
use sq_core_edit::timeline_edit_targets::TimelineEditTargetsExt;
use sq_core_edit::timeline_follow_selection::TimelineFollowSelectionExt;
use sq_core_edit::timeline_solo::SoloExt;
use sq_core_edit::timeline_solo_views::ColorSourceFileView;
use sq_core_effects::transition::TimelineTransitions;
use sq_core_model::{Clip, Timeline, TimelineEditMode};
use sq_core_time::{Id, Time, TimeRange};
use sq_playback::engine::preview_rate::PreviewRate;

use crate::{Change, EditorSession, PlayheadStep};

/// What a playhead move asks of the follow evaluation.
// Swift: EditorSession+FollowSelection.swift:21
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FollowTrigger {
    /// One jump: evaluated at once.
    Jump,
    /// One of possibly many frame steps: at once when it stands alone, deferred inside a run.
    Step,
    /// A move of a scrub drag: always deferred.
    Scrub,
}

/// Monotonic time since the first call (Swift `ContinuousClock.now`).
pub(crate) fn mono_now() -> Duration {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed()
}

/// `SQ_FOLLOW_LOG=1`: logs how long a follow evaluation (with every synchronous observer of the selection change) took.
// Swift: EditorSession+FollowSelection.swift:131
pub enum FollowTiming {}

impl FollowTiming {
    // Swift: EditorSession+FollowSelection.swift:134
    pub fn logs() -> bool {
        std::env::var("SQ_FOLLOW_LOG").is_ok_and(|v| v == "1")
    }

    // Swift: EditorSession+FollowSelection.swift:135
    pub fn report(name: &str, since: Duration) {
        let ms = mono_now().saturating_sub(since).as_secs_f64() * 1000.0;
        sq_os::errln!("SQFOLLOW {name} {ms:.3} ms");
    }
}

/// The frame duration of an empty session.
const DEFAULT_FRAME: Time = Time::new(1, 30);

/// `t` rounded down to a whole number of frames.
fn floored(t: Time, frame_duration: Time) -> Time {
    if frame_duration <= Time::ZERO { t } else { frame_duration * t.frame_index(frame_duration) }
}

impl EditorSession {
    // MARK: Plain state

    /// Linked selection: selecting a clip selects its linked partners.
    // Swift: EditorSession.swift:90
    pub fn linked_selection(&self) -> bool {
        self.linked_selection
    }
    /// Sets only the session-side mirror (Swift's plain `linkedSelection` var); `set_linked_selection` is the undoable
    /// sequence setting.
    pub fn set_linked_selection_mirror(&mut self, on: bool) {
        self.linked_selection = on;
    }

    /// Fast Cut "keep attached" override held (the ` key).
    // Swift: EditorSession.swift:109
    pub fn keep_attached_held(&self) -> bool {
        self.keep_attached_held
    }
    pub fn set_keep_attached_held(&mut self, on: bool) {
        self.keep_attached_held = on;
    }

    /// Edit mode of new sequences.
    // Swift: EditorSession.swift:111
    pub fn new_sequence_edit_mode(&self) -> TimelineEditMode {
        self.new_sequence_edit_mode
    }
    pub fn set_new_sequence_edit_mode(&mut self, mode: TimelineEditMode) {
        self.new_sequence_edit_mode = mode;
    }

    /// Sequences dropped or inserted land as their own clips instead of one combined clip.
    // Swift: EditorSession.swift:113
    pub fn place_sequences_as_clips(&self) -> bool {
        self.place_sequences_as_clips
    }
    pub fn set_place_sequences_as_clips(&mut self, on: bool) {
        self.place_sequences_as_clips = on;
    }

    /// The ids plus their linked partners (and the partners a selected-unlinked edit holds back), when Linked
    /// Selection is on.
    // Swift: EditorSession.swift:116
    pub fn expanding_links(&self, ids: &BTreeSet<Id>) -> BTreeSet<Id> {
        let Some(t) = self.active_timeline().filter(|_| self.linked_selection) else { return ids.clone() };
        let all = t.expanding_bundles(ids);
        let held = t.held_back_partners(&all);
        all.union(&held).copied().collect()
    }

    // Swift: EditorSession.swift:127
    pub fn graphic_layer_selection(&self) -> Option<&crate::GraphicLayerSelection> {
        self.graphic_layer_selection.as_ref()
    }
    /// The one store of the picked Graphic layers: the monitor, the Graphics panel and Controls all read and write it.
    pub fn set_graphic_layer_selection(&mut self, s: Option<crate::GraphicLayerSelection>) {
        if self.graphic_layer_selection != s {
            self.graphic_layer_selection = s;
            self.graphic_layer_selection_version += 1;
        }
    }
    /// Bumped by every change of the layer selection (it posts no `Change`); 0 = never set.
    pub fn graphic_layer_selection_version(&self) -> u64 {
        self.graphic_layer_selection_version
    }

    // Swift: EditorSession.swift:131
    pub fn clipboard(&self) -> Option<&sq_core_edit::timeline_clipboard::TimelineClipboard> {
        self.clipboard.as_ref()
    }
    pub fn set_clipboard(&mut self, c: Option<sq_core_edit::timeline_clipboard::TimelineClipboard>) {
        self.clipboard = c;
    }

    /// Copied effect; setting one clears the built-in clipboard (Swift `didSet`).
    // Swift: EditorSession.swift:133
    pub fn effect_clipboard(&self) -> Option<&sq_core_model::ClipEffect> {
        self.effect_clipboard.as_ref()
    }
    pub fn set_effect_clipboard(&mut self, e: Option<sq_core_model::ClipEffect>) {
        if e.is_some() {
            self.built_in_clipboard = None;
        }
        self.effect_clipboard = e;
    }

    // Swift: EditorSession.swift:136
    pub fn built_in_clipboard(&self) -> Option<&crate::BuiltInClipboard> {
        self.built_in_clipboard.as_ref()
    }
    pub fn set_built_in_clipboard(&mut self, c: Option<crate::BuiltInClipboard>) {
        self.built_in_clipboard = c;
    }

    // Swift: EditorSession.swift:139
    pub fn effect_defaults(&self) -> &sq_core_model::effect_defaults::EffectDefaults {
        &self.effect_defaults
    }
    pub fn set_effect_defaults(&mut self, d: sq_core_model::effect_defaults::EffectDefaults) {
        self.effect_defaults = d;
    }

    /// The media resolver (probe info, file paths).
    // Swift: EditorSession.swift:164
    pub fn media(&self) -> &std::sync::Arc<dyn crate::SessionMediaResolving> {
        &self.media
    }

    /// Proxy service; setting one syncs it with the project (Swift `didSet`).
    // Swift: EditorSession.swift:166
    pub fn auto_proxy(&self) -> Option<&dyn crate::SessionProxyServing> {
        self.auto_proxy.as_deref()
    }
    pub fn set_auto_proxy(&mut self, proxy: Option<Box<dyn crate::SessionProxyServing>>) {
        self.auto_proxy = proxy;
        let (media, id) = (self.project().media.to_vec(), self.project().id);
        let active = self.active_timeline().cloned();
        if let Some(p) = self.auto_proxy.as_mut() {
            p.sync(&media, Some(id), active.as_ref());
        }
        self.apply_proxy_effects();
    }

    /// Asked before a media drop that would change an empty sequence's format (Swift `confirmFormatChange`).
    // Swift: EditorSession.swift:183
    pub fn set_confirm_format_change(&mut self, f: Option<crate::ConfirmFormatChange>) {
        self.confirm_format_change = f;
    }

    /// The Color page solo clip; a change re-pushes the sequence and notifies the monitor.
    // Swift: EditorSession.swift:191
    pub fn color_solo_clip(&self) -> Option<Id> {
        self.color_solo_clip
    }
    pub fn set_color_solo_clip(&mut self, id: Option<Id>) {
        if self.color_solo_clip == id {
            return;
        }
        self.color_solo_clip = id;
        let before = self.color_source_view.as_ref().map(|v| v.clip_id);
        self.push_timeline(false);
        let after = self.color_source_view.as_ref().map(|v| v.clip_id);
        // The picture on the monitor changed even when no file view came or went: the Scopes panel must re-measure.
        self.notify(if after != before {
            Change::PLAYHEAD | Change::TRANSPORT | Change::MONITOR_PICTURE
        } else {
            Change::MONITOR_PICTURE
        });
    }

    /// The Color page's file view of the solo clip, when it has a file axis.
    // Swift: EditorSession.swift:200
    pub fn color_source_view(&self) -> Option<&ColorSourceFileView> {
        self.color_source_view.as_ref()
    }

    // Swift: EditorSession.swift:207
    pub fn color_matte_preview(&self) -> Option<&crate::ColorMattePreview> {
        self.color_matte_preview.as_ref()
    }
    // set_color_matte_preview: ES4 (Swift `colorMattePreview.didSet`, EditorSession+Variants/ColorMatte).

    /// The render cache; its spans reach the engine through `push_timeline`.
    // Swift: EditorSession.swift:220
    pub fn set_render_cache(&mut self, cache: Option<Box<dyn crate::SessionRenderCaching>>) {
        self.render_cache = cache;
        // shortcut: Swift wires an `onSpansChanged` closure to the session; the app calls `push_timeline(true)` when the
        // cache reports new spans. Swift's `seedFrames` closure (pending-writes frames into the engine's frame cache) is not
        // ported: the app does not attach a render cache yet, so no engine has a seed entry point.
    }

    // MARK: Sequences

    /// Switches the active sequence (a nested one opens in its tab's breadcrumb).
    // Swift: EditorSession.swift:624
    pub fn set_active_timeline(&mut self, id: Id) {
        if self.project().timeline(id).is_none() {
            return;
        }
        self.show_in_tabs(id);
        if Some(id) == self.active_timeline_id {
            return;
        }
        self.stop_for_sequence_change();
        self.active_timeline_id = Some(id);
        self.set_selection_raw(BTreeSet::new());
        self.caption_selection.clear();
        self.sync_media();
        self.push_timeline(true);
        self.clamp_playhead_to_active_sequence();
        self.notify(Change::PROJECT | Change::SELECTION);
    }

    fn show_in_tabs(&mut self, id: Id) {
        if self.sequence_tabs.current() == Some(id) {
            return;
        }
        if self.project().timeline(id).is_some_and(|t| t.is_group()) {
            if self.sequence_tabs.active_index().is_some() {
                self.sequence_tabs.enter(id);
            }
        } else {
            self.sequence_tabs.open(id);
        }
    }

    // Swift: EditorSession.swift:647
    pub fn move_sequence_tab(&mut self, root: Id, index: i64) {
        self.sequence_tabs.move_tab(root, index);
        self.notify(Change::PROJECT);
    }

    // Swift: EditorSession.swift:650
    pub fn open_sequence_tab(&mut self, id: Id) {
        self.set_active_timeline(id);
    }

    // Swift: EditorSession.swift:654
    pub fn enter_nested_sequence(&mut self, id: Id) {
        let Some(is_group) = self.project().timeline(id).map(|t| t.is_group()) else { return };
        if is_group {
            self.sequence_tabs.enter(id);
            self.set_active_timeline(id);
        } else {
            self.open_sequence_tab(id);
        }
    }

    // Swift: EditorSession.swift:661
    pub fn pop_sequence(&mut self, id: Id) {
        self.sequence_tabs.pop_to(id);
        let to = self.sequence_tabs.current().unwrap_or(id);
        self.set_active_timeline(to);
    }

    // Swift: EditorSession.swift:667
    pub fn select_sequence_tab(&mut self, root: Id) {
        self.sequence_tabs.select(root);
        if let Some(id) = self.sequence_tabs.current() {
            self.set_active_timeline(id);
        }
    }

    // Swift: EditorSession.swift:673
    pub fn close_sequence_tab(&mut self, root: Id) {
        if self.sequence_tabs.tabs().len() <= 1 {
            return;
        }
        if let Some(id) = self.sequence_tabs.close(root) {
            self.set_active_timeline(id);
        }
        self.notify(Change::PROJECT);
    }

    /// The open sequence tabs.
    pub fn sequence_tabs(&self) -> &super::SequenceTabs {
        &self.sequence_tabs
    }

    fn stop_for_sequence_change(&mut self) {
        if self.is_playing || !self.engine.rate().is_paused() {
            self.engine.pause();
            self.is_playing = false;
            self.reset_follow();
            self.notify(Change::TRANSPORT);
        }
        self.reset_follow();
        let looping = self.bounds.loop_playback;
        self.set_bounds(PlaybackBounds::new(looping, None, None));
    }

    pub(crate) fn stop_for_viewer_switch(&mut self) {
        if self.is_playing || !self.engine.rate().is_paused() {
            self.engine.pause();
            self.is_playing = false;
        }
        let mut b = self.bounds;
        b.set_range(None);
        self.set_bounds(b);
    }

    fn clamp_playhead_to_active_sequence(&mut self) {
        let end = self.active_timeline().map_or(Time::ZERO, Timeline::duration);
        let last = (end - self.frame_duration()).max(Time::ZERO);
        if self.playhead > last {
            self.seek_sequence(last);
        } else if self.color_source_view.is_none() {
            self.engine.seek(self.playhead);
        }
    }

    /// Undo back to `depth` steps (the Trim mode's cancel and gesture rollbacks).
    // Swift: EditorSession.swift:695
    pub fn rewind_undo(&mut self, depth: usize) {
        self.history.rewind(depth);
        self.playhead_steps.retain(|k, _| *k <= depth);
        self.settle_side_steps();
        self.prune_side_steps();
        self.project_did_change();
    }

    /// Folds the steps after `depth` into one named step.
    // Swift: EditorSession.swift:704
    pub fn fold_undo(&mut self, depth: usize, name: &str) {
        self.history.squash(depth, name);
        self.settle_side_steps();
        self.prune_side_steps();
        // The folded steps become the one at `depth + 1`: it keeps their playhead move (first before, last after).
        let folded: Vec<PlayheadStep> =
            self.playhead_steps.iter().filter(|(k, _)| **k > depth).map(|(_, v)| *v).collect();
        self.playhead_steps.retain(|k, _| *k <= depth);
        if let Some(last) = folded.last()
            && let Some(first) = folded.iter().find(|s| s.timeline == last.timeline)
            && self.history.undo_depth() > depth
        {
            self.playhead_steps
                .insert(depth + 1, PlayheadStep { timeline: last.timeline, before: first.before, after: last.after });
        }
    }

    /// Everything that follows a project change: tabs, active sequence, selection, follow state, media, engine.
    // Swift: EditorSession.swift:716
    pub(crate) fn project_did_change(&mut self) {
        let before = self.active_timeline_id;
        let existing: BTreeSet<Id> = self.project().timelines.iter().map(|t| t.id).collect();
        let rootable: BTreeSet<Id> = self.project().timelines.iter().filter(|t| !t.is_group()).map(|t| t.id).collect();
        self.sequence_tabs.prune(&existing, Some(&rootable));
        if let Some(id) = self.active_timeline_id
            && self.project().timeline(id).is_none()
        {
            self.active_timeline_id = None;
        }
        if self.active_timeline_id.is_none() {
            let p = self.project();
            let next = self
                .sequence_tabs
                .current()
                .filter(|id| p.timeline(*id).is_some())
                .or_else(|| p.active_timeline.filter(|id| p.timeline(*id).is_some()))
                .or_else(|| p.timelines.iter().find(|t| !t.is_group()).map(|t| t.id));
            self.active_timeline_id = next;
            if next != before {
                self.stop_for_sequence_change();
            }
        }
        if let Some(id) = self.active_timeline_id
            && self.sequence_tabs.current() != Some(id)
        {
            self.show_in_tabs(id);
        }
        self.prune_selection();
        // An edit does not re-select by itself: the follow state is taken from the edited sequence at the playhead, so
        // the next seek to the same place leaves the selection alone. It re-follows at the next boundary crossing.
        self.follow_state = match self.active_timeline() {
            Some(t)
                if self.selection_follows_playhead
                    && self.color_source_view.is_none()
                    && t.tracks.iter().any(|tr| tr.is_targeted) =>
            {
                Some(t.followed_clips(self.playhead))
            }
            _ => None,
        };
        self.sync_media();
        self.push_timeline(false);
        // Swift's `syncStyleKit()` is not ported here either (captions use `CaptionLookRegistry::library_for_project`).
        if self.active_timeline_id != before {
            self.clamp_playhead_to_active_sequence();
        }
        self.notify(Change::PROJECT | Change::SELECTION);
    }

    fn prune_selection(&mut self) {
        let Some(t) = self.active_timeline() else {
            self.set_selection_raw(BTreeSet::new());
            self.caption_selection.clear();
            return;
        };
        let clips: BTreeSet<Id> = t.tracks.iter().flat_map(|tr| tr.clips().iter().map(|c| c.id)).collect();
        let captions: BTreeSet<Id> = t.caption_tracks.iter().flat_map(|tr| tr.items().iter().map(|i| i.id)).collect();
        let transition_gone = self.selected_transition.is_some_and(|id| t.transition(id).is_none());
        let kept: BTreeSet<Id> = self.selection.intersection(&clips).copied().collect();
        self.caption_selection = self.caption_selection.intersection(&captions).copied().collect();
        self.set_selection_raw(kept);
        if transition_gone {
            self.selected_transition = None;
        }
    }

    /// Hands the media list to the resolver and tells the engines about media whose file moved. Runs after every
    /// project change.
    // Swift: EditorSession.swift:909
    pub(crate) fn sync_media(&mut self) {
        // Always: the active sequence's sample rate can change without the media changing.
        // The resolver sees the project input color default applied; the stored detection stays as it is.
        let rate = self.active_timeline().map(|t| t.format.audio_sample_rate);
        let rendering = self.project().media_for_rendering();
        self.media.update(&rendering, rate);
        let infos: std::collections::BTreeMap<Id, Option<sq_core_model::MediaInfo>> =
            rendering.iter().map(|m| (m.id, m.info.clone())).collect();
        if infos != self.rendered_infos {
            // The color resolver rebuilds a layer's pipeline when its media's color space changes; frames are cached
            // decoded (before color), so a redraw of the current frame is enough.
            self.rendered_infos = infos;
            self.engine.redraw();
        }
        let media = self.project().media.to_vec();
        if media == self.media_snapshot.to_vec() {
            return;
        }
        // Media whose file moved (relink to another path, or its undo): the engines reopen them.
        let old: std::collections::BTreeMap<Id, &str> =
            self.media_snapshot.iter().map(|m| (m.id, m.path.as_str())).collect();
        let moved: BTreeSet<Id> =
            media.iter().filter(|m| old.get(&m.id).is_some_and(|p| *p != m.path.as_str())).map(|m| m.id).collect();
        // Pixel aspect, audio channel map and field order changed (source settings, their undo, a probe): the engines
        // hold them with the opened media, so they open it again.
        let shape = |m: &sq_core_model::MediaRef| {
            let v = m.info.as_ref().and_then(|i| i.video.as_ref());
            (
                v.map_or_else(sq_core_model::PixelAspect::square, |v| v.display_pixel_aspect()),
                v.and_then(|v| v.deinterlace_field_order()),
                m.info.as_ref().and_then(|i| i.audio.as_ref()).and_then(|a| a.channel_map.clone()),
            )
        };
        let old_shapes: std::collections::BTreeMap<Id, _> =
            self.media_snapshot.iter().map(|m| (m.id, shape(m))).collect();
        let mut moved = moved;
        for m in media.iter() {
            if old_shapes.get(&m.id).is_some_and(|old| *old != shape(m)) {
                moved.insert(m.id);
            }
        }
        if !moved.is_empty() {
            self.engine.media_changed(&moved);
            if let Some(cache) = self.render_cache.as_mut() {
                cache.media_changed();
            }
            self.auxiliary_engines.retain(|e| e.is_alive());
            for a in &mut self.auxiliary_engines {
                a.media_changed(&moved);
            }
        }
        self.media_snapshot = self.project().media.clone();
        let (list, id) = (self.project().media.to_vec(), self.project().id);
        let active = self.active_timeline().cloned();
        if let Some(p) = self.auto_proxy.as_mut() {
            p.sync(&list, Some(id), active.as_ref());
        }
        self.apply_proxy_effects();
        // shortcut: Swift then prepares the fresh media asynchronously and notifies `.media`; the app calls
        // `media().prepare(..)` for `take_fresh_media()` once ES8 wires the preparation flow.
    }

    /// Makes an undo/redo visible: selects the affected clips, moves the playhead into the affected range when it is
    /// outside, and asks the view to scroll there. Zoom stays as it is.
    // Swift: EditorSession.swift:685
    pub(super) fn reveal_change(&mut self, before: Option<&Timeline>) {
        use sq_core_edit::undo_focus::UndoFocus;
        let Some(focus) = UndoFocus::between(before, self.active_timeline()) else { return };
        // An undo that only changes what clips hold (a grade, an effect value) has nothing to reveal: a clip the user
        // already has selected stays the selection even when linked grades changed other clips too. Otherwise the
        // Color page (which grades one clip) would lose its target after every undo of a grade.
        let holds_only = !focus.timing_changed && !self.selection.is_disjoint(&focus.clips);
        if !focus.clips.is_empty() && !holds_only {
            self.set_selection(focus.clips.clone(), BTreeSet::new());
        }
        if let Some(t) = focus.playhead(self.playhead) {
            self.seek(t);
        }
        self.reveal_range = Some(focus.range);
        self.notify(Change::REVEAL);
    }

    // MARK: Selection

    /// Selects clips and captions by hand: the follow-selection state settles first.
    // Swift: EditorSession.swift:994
    pub fn select(&mut self, clips: BTreeSet<Id>, captions: BTreeSet<Id>) {
        self.settle_follow_for_manual_selection();
        self.set_selection(clips, captions);
    }

    /// Selects clips the way a click does: each clip's linked partners (and its bundle with their partners) join unless
    /// linked selection is off. For callers without a pointer (`--select`, an accessibility click, a tour step).
    pub fn select_with_partners(&mut self, clips: BTreeSet<Id>) {
        let mut all = clips.clone();
        if self.linked_selection
            && let Some(t) = self.active_timeline()
        {
            let every: Vec<&Clip> = t.tracks.iter().flat_map(|tr| tr.clips()).collect();
            let mut with_bundles = clips.clone();
            for c in every.iter().filter(|c| clips.contains(&c.id)) {
                if let Some(b) = c.bundle {
                    with_bundles.extend(every.iter().filter(|o| o.bundle == Some(b)).map(|o| o.id));
                }
            }
            for c in every.iter().filter(|c| with_bundles.contains(&c.id)) {
                all.insert(c.id);
                if let Some(l) = c.link {
                    all.extend(every.iter().filter(|o| o.link == Some(l)).map(|o| o.id));
                }
            }
        }
        self.select(all, BTreeSet::new());
    }

    // Swift: EditorSession.swift:999
    pub fn set_selection(&mut self, clips: BTreeSet<Id>, captions: BTreeSet<Id>) {
        if clips == self.selection && captions == self.caption_selection {
            return;
        }
        if !clips.is_empty() || !captions.is_empty() {
            self.selected_transition = None;
        }
        self.set_selection_raw(clips);
        self.caption_selection = captions;
        self.prune_selection();
        self.notify(Change::SELECTION);
    }

    /// The one selected clip (the primary of a selection of linked partners).
    // Swift: EditorSession.swift:1009
    pub fn single_selected_clip(&self) -> Option<&Clip> {
        use sq_core_project::sequence_format_presets::TimelinePrimaryClipExt;
        self.active_timeline()?.primary_clip(&self.selection)
    }

    // MARK: Follow selection

    /// Whether the selection follows the playhead.
    pub fn selection_follows_playhead(&self) -> bool {
        self.selection_follows_playhead
    }

    /// "Use proxies when exporting" (preference), read by the export snapshot.
    pub fn use_proxies_for_export(&self) -> bool {
        self.use_proxies_for_export
    }

    pub fn set_use_proxies_for_export(&mut self, on: bool) {
        self.use_proxies_for_export = on;
    }

    // Swift: EditorSession+FollowSelection.swift:26
    pub fn set_selection_follows_playhead(&mut self, on: bool) {
        if on == self.selection_follows_playhead {
            return;
        }
        self.selection_follows_playhead = on;
        self.follow_state = None;
        self.cancel_pending_follow();
        if on && !self.is_playing {
            self.follow_playhead();
        }
    }

    /// The playhead moved while parked. Costs a range compare unless a clip boundary was crossed.
    pub(crate) fn playhead_moved(&mut self, trigger: FollowTrigger) {
        if !self.selection_follows_playhead || self.is_playing {
            return;
        }
        if trigger == FollowTrigger::Jump {
            let covered = self.follow_state.as_ref().is_some_and(|f| f.covers(self.playhead));
            if self.follow_pending || !covered {
                self.follow_playhead();
            }
            return;
        }
        let now = mono_now();
        let in_run = trigger == FollowTrigger::Scrub
            || self.follow_last_step.is_some_and(|last| now.saturating_sub(last) < self.follow_step_run);
        if trigger == FollowTrigger::Step {
            self.follow_last_step = Some(now);
        }
        if !self.follow_pending && self.follow_state.as_ref().is_some_and(|f| f.covers(self.playhead)) {
            return; // same clips: nothing is due
        }
        if !in_run {
            self.follow_playhead();
            return;
        }
        // The deferred evaluation runs from `tick_follow`, which the app calls when `next_follow_deadline` passes
        // (Swift slept in a task; the session has no executor handle, so the pump drives the deadline).
        self.follow_pending = true;
        self.follow_deadline = now + self.follow_settle;
    }

    /// When a deferred follow evaluation is due (monotonic time as `follow_now`), if one waits.
    pub fn next_follow_deadline(&self) -> Option<Duration> {
        self.follow_pending.then_some(self.follow_deadline)
    }

    /// Runs the deferred evaluation when its deadline passed. Returns whether it ran.
    pub fn tick_follow(&mut self) -> bool {
        if self.follow_pending && mono_now() >= self.follow_deadline {
            self.flush_follow_selection();
            return true;
        }
        false
    }

    /// Brings the selection up to the playhead now: applies a deferred evaluation (end of a scrub drag), and
    /// evaluates while playing. Called before anything that works on the selection.
    // Swift: EditorSession+FollowSelection.swift:63
    pub fn flush_follow_selection(&mut self) {
        if !self.follow_pending && !self.is_playing {
            return;
        }
        self.follow_playhead();
    }

    /// True while a deferred evaluation waits (tests).
    #[cfg(test)]
    pub(crate) fn is_follow_pending(&self) -> bool {
        self.follow_pending
    }

    fn cancel_pending_follow(&mut self) {
        self.follow_pending = false;
        if let Some(task) = self.follow_task.take() {
            task.cancel();
        }
    }

    /// A manual selection while an evaluation is still due or while playing: the follow state catches up with the
    /// playhead first, so the manual selection is not replaced a moment later.
    pub(crate) fn settle_follow_for_manual_selection(&mut self) {
        self.cancel_pending_follow();
        let Some(t) = self.active_timeline() else { return };
        if !self.selection_follows_playhead
            || self.color_source_view.is_some()
            || !t.tracks.iter().any(|tr| tr.is_targeted)
        {
            return;
        }
        self.follow_state = Some(t.followed_clips(self.playhead));
    }

    /// Transport changed (called before every notification): the stop of a playback evaluates once, a start drops
    /// what a scrub left pending.
    pub(crate) fn follow_transport_changed(&mut self) {
        if self.is_playing == self.follow_was_playing {
            return;
        }
        self.follow_was_playing = self.is_playing;
        if self.is_playing {
            self.cancel_pending_follow();
        } else {
            self.follow_playhead();
        }
    }

    /// Evaluates the playhead position now and replaces the selection when a boundary was crossed.
    pub(crate) fn follow_playhead(&mut self) {
        self.cancel_pending_follow();
        let Some(t) = self.active_timeline() else { return };
        if !self.selection_follows_playhead
            || self.color_source_view.is_some()
            || !t.tracks.iter().any(|tr| tr.is_targeted)
        {
            return;
        }
        if self.follow_state.as_ref().is_some_and(|f| f.covers(self.playhead)) {
            return;
        }
        let started = FollowTiming::logs().then(mono_now);
        let f = t.followed_clips(self.playhead);
        self.follow_evaluations += 1;
        let previous = self.follow_state.take();
        let ids = f.ids.clone();
        self.follow_state = Some(f);
        if previous.is_some_and(|p| p.ids == ids) {
            return;
        }
        let expanded = self.expanding_links(&ids);
        let captions = self.caption_selection.clone();
        self.set_selection(expanded, captions);
        if let Some(started) = started {
            FollowTiming::report("followSelection", started);
        }
    }

    /// Another project or sequence is shown: nothing of the old one is due or remembered.
    pub(crate) fn reset_follow(&mut self) {
        self.cancel_pending_follow();
        self.follow_state = None;
        self.follow_last_step = None;
        self.follow_was_playing = self.is_playing;
    }

    // MARK: Playhead and transport

    fn frame_duration(&self) -> Time {
        self.active_timeline().map_or(DEFAULT_FRAME, Timeline::frame_duration)
    }

    /// Frame duration of what the monitor shows (a Color file view has its own).
    // Swift: EditorSession.swift:1017
    pub fn monitor_frame_duration(&self) -> Time {
        self.color_source_view.as_ref().map_or_else(|| self.frame_duration(), |v| v.timeline.frame_duration())
    }

    /// Moves the playhead (frame-snapped, never before zero) and shows that frame.
    // Swift: EditorSession.swift:1021
    pub fn seek(&mut self, t: Time) {
        self.seek_following(t, FollowTrigger::Jump);
    }

    fn seek_following(&mut self, t: Time, follow: FollowTrigger) {
        if self.color_source_view.is_some() {
            self.end_skim();
            self.source_view_moved(t, true, false);
            return;
        }
        let target = t.snapped(self.frame_duration()).max(Time::ZERO);
        self.playhead = target;
        self.engine.seek(target);
        if let Some(s) = self.skim_time {
            self.engine.scrub(s); // a skim goes on across a playhead move (edit keys, ripple follow)
        }
        self.playhead_moved(follow);
        self.notify(Change::PLAYHEAD);
    }

    /// Moves the sequence playhead (sequence time) even while the monitor shows a source file.
    // Swift: EditorSession.swift:1036
    pub fn seek_sequence(&mut self, t: Time) {
        if self.color_source_view.is_none() {
            self.seek(t);
            return;
        }
        self.playhead = t.snapped(self.frame_duration()).max(Time::ZERO);
        self.playhead_moved(FollowTrigger::Jump);
        self.notify(Change::PLAYHEAD);
    }

    /// The time the monitor shows.
    // Swift: EditorSession.swift:1044
    pub fn monitor_time(&self) -> Time {
        self.color_source_view.as_ref().map_or(self.playhead, |v| v.position)
    }

    // Swift: EditorSession.swift:1046
    pub fn monitor_duration(&self) -> Time {
        match &self.color_source_view {
            Some(v) => v.timeline.duration(),
            None => self.active_timeline().map_or(Time::ZERO, Timeline::duration),
        }
    }

    fn source_view_moved(&mut self, t: Time, engine_seek: bool, scrub: bool) {
        let Some(mut v) = self.color_source_view.take() else { return };
        let vfd = v.timeline.frame_duration();
        let last = (v.timeline.duration() - vfd).max(Time::ZERO);
        let pos = floored(t.max(Time::ZERO).min(last), vfd);
        v.position = pos;
        if engine_seek {
            if scrub {
                self.engine.scrub(pos);
            } else {
                self.engine.seek(pos);
            }
        }
        let fd = self.frame_duration();
        let clip = self
            .active_timeline()
            .and_then(|tl| tl.tracks.iter().flat_map(|tr| tr.clips().iter()).find(|c| c.id == v.clip_id).cloned());
        if let Some(c) = clip.filter(|c| c.duration() > Time::ZERO) {
            let local = if c.speed_keys.is_some() {
                c.timeline_time_for_source(pos, fd) - c.start
            } else if c.reversed {
                c.speed.unscale(c.source.end() - pos) - fd
            } else {
                c.speed.unscale(pos - c.source.start)
            };
            let within = local.max(Time::ZERO).min(c.duration() - fd);
            self.playhead = (c.start + within).snapped(fd);
        }
        self.color_source_view = Some(v);
        self.notify(Change::PLAYHEAD);
    }

    fn engine_loops(&self) -> bool {
        self.engine.loops()
    }

    fn source_view_played(&mut self, t: Time) {
        let Some(v) = self.color_source_view.as_ref() else { return };
        if !self.is_playing {
            return;
        }
        let (end, vfd, pos) = (v.timeline.duration(), v.timeline.frame_duration(), v.position);
        // A looping engine wraps by itself and never stops at the end.
        let at_end = t + vfd >= end && self.engine.rate().is_forward() && !self.engine_loops();
        if at_end && self.bounds.loop_playback {
            let r = self.engine.rate();
            self.engine.seek(Time::ZERO);
            self.engine.play(r);
            self.source_view_moved(Time::ZERO, false, false);
            return;
        }
        if at_end || self.engine.rate().is_paused() {
            self.engine.pause();
            self.is_playing = false;
            self.source_view_moved(if at_end { end } else { t }, false, false);
            self.notify(Change::TRANSPORT);
            return;
        }
        if t != pos {
            self.source_view_moved(t, false, false);
        }
    }

    /// Reads the engine's position report (the engine's `onPositionChange`) and follows it. The app calls this on its
    /// frame pump.
    pub fn poll_engine_position(&mut self) {
        if let Some(t) = self.engine.take_position_change() {
            self.engine_position_changed(t);
        }
    }

    fn engine_position_changed(&mut self, t: Time) {
        if self.color_source_view.is_some() {
            self.source_view_played(t);
            return;
        }
        if !self.is_playing {
            return;
        }
        let end = self.active_timeline().map_or(Time::ZERO, Timeline::duration);
        let fd = self.frame_duration();
        // Stop at the sequence end: the last presented frame is one frame before `end`.
        let rate = self.engine.rate();
        let looping = self.engine_loops(); // the engine wraps by itself; its position just goes on
        match self.bounds.action(t, rate, fd, end) {
            PlaybackAction::Wrap(_) if looping => {}
            PlaybackAction::Wrap(to) => {
                self.playhead = to;
                self.engine.seek(to);
                self.engine.play(rate);
                self.notify(Change::PLAYHEAD);
                return;
            }
            PlaybackAction::Stop(at) if self.bounds.range().is_some() => {
                // Forward: the range end is exclusive, park on its last frame. Reverse stops at the In frame itself.
                self.engine.pause();
                self.is_playing = false;
                self.playhead = if rate.is_reverse() { at } else { (at - fd).max(Time::ZERO) };
                self.notify(Change::PLAYHEAD | Change::TRANSPORT);
                return;
            }
            PlaybackAction::StopAndReturn(back) => {
                self.engine.pause();
                self.is_playing = false;
                let mut b = self.bounds;
                b.set_range(None);
                self.set_bounds(b);
                self.seek(back);
                self.notify(Change::TRANSPORT);
                return;
            }
            _ => {}
        }
        let at_end = end > Time::ZERO && t + fd >= end && self.engine.rate().is_forward() && !looping;
        if at_end || self.engine.rate().is_paused() {
            // Paused already: the engine reports where a pause parked, and that is the playhead.
            if !self.engine.rate().is_paused() {
                self.engine.pause();
            }
            self.is_playing = false;
            self.playhead = if at_end { end } else { t };
            self.notify(Change::PLAYHEAD | Change::TRANSPORT);
            return;
        }
        if t == self.playhead {
            return;
        }
        self.playhead = t;
        self.notify(Change::PLAYHEAD); // the selection does not follow while playing
    }

    fn restart_if_at_end(&mut self) {
        let end = self.monitor_duration();
        // The last frame counts as the end too: a stop at the end parks on `end`, Go To End on the last frame, and from
        // either Play starts over (a play from the last frame would leave the transport on Pause with nothing running).
        let extra = self.monitor_frame_duration();
        if end > Time::ZERO && self.monitor_time() + extra >= end {
            self.seek(Time::ZERO);
        }
    }

    /// A click in the timeline or ruler: playback stops (and stays stopped until Play / Space / L).
    // Swift: EditorSession.swift:1148
    pub fn stop_playback(&mut self) {
        if !self.is_playing && self.engine.rate().is_paused() {
            return;
        }
        self.engine.pause();
        self.is_playing = false;
        self.notify(Change::TRANSPORT);
    }

    // Swift: EditorSession.swift:1154
    pub fn begin_scrub(&mut self) {
        self.end_skim();
        self.stop_playback();
        self.engine.begin_scrub();
    }

    /// The time hover-skimming shows, if any.
    pub fn skim_time(&self) -> Option<Time> {
        self.skim_time
    }

    /// Where edits land: the skim position, else the playhead.
    // Swift: EditorSession.swift:1163
    pub fn edit_point(&self) -> Time {
        self.skim_time.unwrap_or(self.playhead)
    }

    /// Hover skimming: the monitor shows the frame under the pointer without moving the playhead. `None` ends it.
    // Swift: EditorSession.swift:1168
    pub fn skim(&mut self, t: Option<Time>) {
        let Some(t) =
            t.filter(|_| self.color_source_view.is_none() && !self.is_playing && self.engine.rate().is_paused())
        else {
            self.end_skim();
            return;
        };
        let target = t.snapped(self.frame_duration()).max(Time::ZERO);
        if self.skim_time.is_none() {
            self.engine.begin_scrub();
        }
        if Some(target) == self.skim_time {
            return;
        }
        self.skim_time = Some(target);
        self.engine.scrub(target);
    }

    fn end_skim(&mut self) {
        if self.skim_time.is_none() {
            return;
        }
        self.skim_time = None;
        self.engine.end_scrub();
        self.engine.seek(self.playhead);
    }

    // Swift: EditorSession.swift:1184
    pub fn scrub(&mut self, t: Time) {
        if self.color_source_view.is_some() {
            self.source_view_moved(t, true, true);
            return;
        }
        let target = t.snapped(self.frame_duration()).max(Time::ZERO);
        self.playhead = target;
        self.engine.scrub(target);
        self.playhead_moved(FollowTrigger::Scrub);
        self.notify(Change::PLAYHEAD);
    }

    // Swift: EditorSession.swift:1193
    pub fn end_scrub(&mut self) {
        self.engine.end_scrub();
        self.flush_follow_selection();
    }

    /// The preview speed of Play.
    pub fn preview_rate(&self) -> PreviewRate {
        self.preview_rate
    }

    // Swift: EditorSession.swift:1199
    pub fn set_preview_rate(&mut self, r: PreviewRate) {
        if r == self.preview_rate {
            return;
        }
        self.preview_rate = r;
        if self.is_playing && self.engine.rate().is_forward() {
            self.apply_shuttle(ShuttleAction::SetRate(r.rate));
        }
    }

    // Swift: EditorSession.swift:1206
    pub fn play_pause(&mut self) {
        self.end_skim();
        if self.is_playing || !self.engine.rate().is_paused() {
            self.engine.pause();
            self.is_playing = false;
        } else {
            if self.monitor_duration() <= Time::ZERO {
                return; // nothing to play: an empty sequence never enters the playing state
            }
            self.engine.set_look_preview(None);
            let mut b = self.bounds;
            b.set_range(None);
            self.set_bounds(b);
            self.restart_if_at_end();
            self.engine.play(self.preview_rate.rate);
            self.is_playing = true;
        }
        self.follow_transport_changed();
        self.notify(Change::TRANSPORT);
    }

    // Swift: EditorSession.swift:1221
    pub fn apply_shuttle(&mut self, action: ShuttleAction) {
        match action {
            ShuttleAction::SetRate(r) => {
                if r.is_paused() {
                    self.engine.pause();
                    self.is_playing = false;
                } else {
                    if self.monitor_duration() <= Time::ZERO {
                        return; // nothing to play
                    }
                    self.engine.set_look_preview(None);
                    let mut b = self.bounds;
                    b.set_range(None);
                    self.set_bounds(b);
                    if r.is_forward() {
                        self.restart_if_at_end();
                    }
                    self.engine.play(r);
                    self.is_playing = true;
                }
                self.follow_transport_changed();
                self.notify(Change::TRANSPORT);
            }
            ShuttleAction::Step(n) => self.step_frames(n),
            ShuttleAction::None => {}
        }
    }

    // Swift: EditorSession.swift:1231
    pub fn step_frames(&mut self, n: i64) {
        self.end_skim();
        if self.is_playing {
            self.engine.pause();
            self.is_playing = false;
            self.follow_transport_changed();
            self.notify(Change::TRANSPORT);
        }
        let to = self.monitor_time() + self.monitor_frame_duration() * n;
        self.seek_following(to, FollowTrigger::Step);
    }

    // Swift: EditorSession.swift:1237
    pub fn go_to_start(&mut self) {
        self.seek(Time::ZERO);
    }

    /// Parks on the sequence end (after the last frame), where Insert, Overwrite and Paste append; Swift parked on the
    /// last frame, so those edits split the last clip. A source view clamps to its own last frame in `source_view_moved`.
    // Swift: EditorSession.swift:1240 (deviates on purpose, Premiere's Go to Sequence End)
    pub fn go_to_end(&mut self) {
        self.seek(self.monitor_duration());
    }

    fn jump_points(&self) -> Vec<Time> {
        if let Some(r) = self.source_view_clip_range() {
            return vec![r.start, r.end()];
        }
        self.active_timeline().map(|t| t.edit_points(&self.selection)).unwrap_or_default()
    }

    // Swift: EditorSession.swift:1248
    pub fn go_to_next_edit_point(&mut self) {
        let now = self.monitor_time();
        if let Some(t) = self.jump_points().into_iter().find(|t| *t > now) {
            self.seek(t);
        }
    }

    // Swift: EditorSession.swift:1252
    pub fn go_to_previous_edit_point(&mut self) {
        let now = self.monitor_time();
        if let Some(t) = self.jump_points().into_iter().rev().find(|t| *t < now) {
            self.seek(t);
        }
    }

    /// The source range of the clip shown in the Color file view.
    // Swift: EditorSession.swift:1258
    pub fn source_view_clip_range(&self) -> Option<TimeRange> {
        let v = self.color_source_view.as_ref()?;
        let c = self.active_timeline()?.tracks.iter().flat_map(|tr| tr.clips().iter()).find(|c| c.id == v.clip_id)?;
        Some(c.source)
    }

    // Swift: EditorSession.swift:1265
    pub fn go_to_in(&mut self) {
        if self.color_source_view.is_some() {
            if let Some(r) = self.source_view_clip_range() {
                self.seek(r.start);
            }
            return;
        }
        if let Some(io) = self.active_timeline().and_then(|t| t.in_out) {
            self.seek(io.start);
        }
    }

    // Swift: EditorSession.swift:1270
    pub fn go_to_out(&mut self) {
        if self.color_source_view.is_some() {
            if let Some(r) = self.source_view_clip_range() {
                let to = (r.end() - self.monitor_frame_duration()).max(r.start);
                self.seek(to);
            }
            return;
        }
        // In only: the Out follows the current sequence end (`export_range`), not the end when In was marked.
        if let Some(io) = self.active_timeline().and_then(|t| t.export_range()) {
            self.seek((io.end() - self.frame_duration()).max(io.start));
        }
    }

    /// The Play from Start command: the playhead goes to the sequence start and plays forward.
    // Swift: EditorSession+ShortcutRest.swift:10
    pub fn play_from_start(&mut self) {
        if self.active_timeline().is_none() {
            return;
        }
        if self.is_playing {
            self.stop_playback();
        }
        self.seek(Time::ZERO);
        self.apply_shuttle(ShuttleAction::SetRate(PlaybackRate::FORWARD));
    }
}
