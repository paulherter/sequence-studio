// Swift: EffectControlsModel.swift (Clip, Sections, Zoom, Playhead scrubbing)
//! Which clip is shown, how it follows the session, the zoom of the keyframe area and the ruler scrub.

use sq_core_model::{Clip, ClipEffect, EffectCatalog, Timeline, TrackKind};
use sq_core_time::{Id, Time, Vec2};
use sq_editor_session::{Change, EditorSession, EffectSection};
use sq_uikit::keyframe_viewport::{KeyframeSnap, KeyframeViewport};

use super::core::{EffectControlsEvent, EffectControlsModel, ItemHost};
use super::lane_geometry::KeyframeLaneGeometry;
use crate::ec::prelude::*;
use sq_core_graphics::graphics_layer_projection::GraphicsItemProjectionExt;

fn seconds(t: Time) -> f64 {
    t.value() as f64 / t.timescale().max(1) as f64
}

impl EffectControlsModel {
    /// Sets the clip shown. Never emits an edit. A different clip resets selection; the same clip prunes
    /// selected keys that no longer exist.
    pub fn set_clip(
        &mut self,
        shown: Option<Clip>,
        audio_partner: Option<Clip>,
        new_peers: Vec<Clip>,
        item: Option<ItemHost>,
    ) {
        let mut c = shown.clone();
        let item_changed = item.as_ref().map(|i| i.layer) != self.item_host.as_ref().map(|i| i.layer);
        self.item_host = if shown.is_none() { None } else { item };
        let new_peers = if shown.is_none() { Vec::new() } else { new_peers };
        if new_peers.is_empty()
            && let (Some(v), Some(partner)) = (shown.as_ref(), audio_partner.as_ref())
            && v.kind != TrackKind::Audio
            && partner.kind == TrackKind::Audio
        {
            self.own_volume = Some(v.animation.volume.clone());
            self.audio_partner = Some(partner.clone());
            // Keys are clip-local: an L/J-cut partner starts elsewhere, so its keys move into the video clip's time base.
            let d = partner.start - v.start;
            self.partner_offset = d;
            if let Some(c) = c.as_mut() {
                c.animation.volume = if d == Time::ZERO {
                    partner.animation.volume.clone()
                } else {
                    partner.animation.volume.shifted(d)
                };
                // AUDIO-FX: shown in the Audio group, edits go to the partner
                c.effects.extend(
                    partner
                        .effects
                        .iter()
                        .filter(|e| e.is_audio())
                        .map(|e| if d == Time::ZERO { e.clone() } else { e.shifted(d) }),
                );
            }
        } else {
            self.own_volume = None;
            self.audio_partner = None;
            self.partner_offset = Time::ZERO;
        }
        if c != self.clip {
            self.end_color_gesture(); // undo or an outside edit: the color gesture's base is stale
        }
        let same_id = c.as_ref().map(|x| x.id) == self.clip.as_ref().map(|x| x.id);
        if !same_id || new_peers.iter().map(|p| p.id).ne(self.peers.iter().map(|p| p.id)) {
            self.peer_gesture_base = None;
        }
        if same_id && !item_changed {
            self.rebase_open_gesture(c.as_ref(), &new_peers);
        }
        if new_peers != self.peers {
            self.peers = new_peers;
            self.version += 1;
        }
        if !same_id || item_changed {
            self.set_selection(Default::default());
            self.selected_section = None;
            self.gesture_base = None;
            self.close_emitted_gesture();
            self.zoom_state = None;
            self.defer_emit = false;
            self.deferred_edit_name = None;
            self.revert_pending_frame_steps();
            if self.scrub_began {
                self.scrub_began = false;
                self.events.push(EffectControlsEvent::ScrubEnded); // a lost mouse-up must not leave the scrub open
            }
        }
        if let Some(c) = &c {
            // Follows the clip: a new clip derives it, any later change (undo, redo, external edit) can only switch it off.
            if self.clip.as_ref().map(|x| x.id) != Some(c.id) {
                self.uniform_scale = Self::is_uniform_scale(c, Time::ZERO);
            } else if !Self::is_uniform_scale(c, Time::ZERO) {
                self.uniform_scale = false;
            }
        }
        self.store_clip(c.clone());
        if let Some(c) = &c {
            self.adopt_twirl(c.id);
            self.collapse_new_color_effects(c);
        }
        if let Some(sec) = self.selected_section.clone()
            && (!self.visible_sections().contains(&sec) || !Self::keeps_selection(&sec))
        {
            self.selected_section = None;
        }
        self.prune_selection();
    }

    /// An edit of another panel syncs in while a drag is open: the drag's base takes it over, so the next step and
    /// Escape keep it (a base left as it was computes the whole clip again and puts that edit back).
    fn rebase_open_gesture(&mut self, incoming: Option<&Clip>, new_peers: &[Clip]) {
        if let (Some(incoming), Some(shown), Some(base)) = (incoming, self.clip.as_ref(), self.gesture_base.as_mut())
            && incoming != shown
        {
            *base = Clip::rebased(shown, incoming, base);
        }
        let Some(bases) = self.peer_gesture_base.as_mut() else { return };
        for base in bases {
            let old = self.peers.iter().find(|p| p.id == base.id);
            let new = new_peers.iter().find(|p| p.id == base.id);
            if let (Some(old), Some(new)) = (old, new)
                && old != new
            {
                *base = Clip::rebased(old, new, base);
            }
        }
    }

    /// The Graphic item whose properties the rows show (`None`: the whole clip).
    pub fn item_layer(&self) -> Option<Id> {
        self.item_host.as_ref().map(|h| h.layer)
    }

    /// Follows the session: the selected clip (or the video clip of a selected linked pair), nothing for no or a mixed
    /// selection. Called for every session change; cheap when nothing relevant changed.
    pub fn sync(&mut self, session: &EditorSession, change: Change) {
        self.has_session = true;
        if change.contains(Change::PROJECT) || change.contains(Change::MEDIA) {
            let fd = session.active_timeline().map_or(self.frame_duration, |t| t.frame_duration());
            if fd != self.frame_duration {
                self.frame_duration = fd;
                self.version += 1;
            }
        }
        if change.contains(Change::SELECTION) || change.contains(Change::PROJECT) {
            if self.defer_emit {
                // mid key drag: the scratch copy stays
                self.sync_playhead(session, change);
                self.refresh_display_picture(session);
                return;
            }
            if self.sync_multi(session) {
                self.sync_playhead(session, change);
                self.refresh_display_picture(session);
                return;
            }
            let shown = session.displayed_selected_clip();
            if let Some(shown) = shown.as_ref()
                && let Some(sel) = session.graphic_layer_selection()
                && sel.clip == shown.id
                && shown.is_graphics()
                && let Some(layer) = shown.graphics().and_then(|g| g.shown_item(&sel.layers))
                && let Some(projected) = shown.graphics_item_projection(layer)
            {
                self.set_clip(Some(projected), None, Vec::new(), Some(ItemHost { host: shown.clone(), layer }));
                self.sync_playhead(session, change);
                self.refresh_display_picture(session);
                return;
            }
            let partner = shown.as_ref().and_then(|c| {
                let link = c.link?;
                if c.kind == TrackKind::Audio {
                    return None;
                }
                session
                    .active_timeline()?
                    .tracks
                    .iter()
                    .flat_map(|t| t.clips().iter())
                    .find(|x| x.link == Some(link) && x.kind == TrackKind::Audio)
                    .cloned()
            });
            self.set_clip(shown, partner, Vec::new(), None);
        } // as the active variant shows it (W5.1)
        self.sync_playhead(session, change);
        self.refresh_display_picture(session);
    }

    fn sync_playhead(&mut self, session: &EditorSession, change: Change) {
        if (change.contains(Change::PLAYHEAD) || change.contains(Change::PROJECT))
            && self.playhead != session.playhead()
        {
            self.set_playhead(session.playhead());
        }
    }

    /// Upright size in px of the picture the shown clip displays (active format variant).
    fn refresh_display_picture(&mut self, session: &EditorSession) {
        use sq_core_graphics::format_variants_view::ProjectVariantsExt;
        self.display_picture = self.clip.as_ref().and_then(|c| {
            session
                .project()
                .picture_size_in(c, session.active_variant_id())
                .map(|(w, h)| Vec2::new(w as f64, h as f64))
        });
    }

    /// Upright size in px of the picture the shown clip displays (active format variant); nil for generators and media
    /// without probe info. Crop is shown in px of it.
    pub fn display_picture(&self) -> Option<Vec2> {
        if self.has_session && self.clip.is_some() { self.display_picture } else { None }
    }

    pub fn visible_sections(&self) -> Vec<EffectSection> {
        let Some(clip) = &self.clip else { return Vec::new() };
        // Applied effects sit below the fixed ones, in list order (= evaluation order).
        // The first Crop is edited by Transform's Crop rows: no section of its own.
        let transform_crop = Self::transform_crop_id(clip);
        // A Color Graph shows only while Pro is the clip's grade; the Color panel's Simple | Pro switch owns the rest.
        let applied: Vec<&sq_core_model::ClipEffect> = clip
            .effects
            .iter()
            .filter(|e| {
                EffectCatalog::spec_for(&e.kind).is_some()
                    && Some(e.id) != transform_crop
                    && (e.kind != ClipEffect::COLOR_GRAPH_KIND || e.color_graph.as_ref().is_some_and(|g| g.is_active))
            })
            .collect();
        let section = |e: &&sq_core_model::ClipEffect| EffectSection::Effect { id: e.id, kind: e.kind.clone() };
        let audio_fx: Vec<EffectSection> = applied.iter().filter(|e| e.is_audio()).map(section).collect();
        if clip.kind == TrackKind::Audio {
            let mut out = vec![EffectSection::Volume];
            if self.is_multi() {
                out.extend(
                    audio_fx.into_iter().filter(|s| s.effect_id().is_some_and(|id| self.shared_by_any_peer(id))),
                );
            } else {
                out.extend(audio_fx);
            }
            return out;
        }
        let mut out = vec![EffectSection::Motion]; // Opacity is a row of Motion, not a section of its own
        if self.is_multi() {
            out.extend(self.shared_custom_sides().into_iter().map(EffectSection::Animation));
            out.extend(applied.iter().filter(|e| !e.is_audio() && self.shared_by_any_peer(e.id)).map(section));
            return out;
        }
        out.extend(self.custom_animation_sections(clip)); // a Custom Intro / Outro: its rows follow the Animation section
        if self.has_session && Timeline::can_retime(clip) {
            out.push(EffectSection::Speed);
        }
        out.extend(clip.masks().iter().map(|m| EffectSection::Mask(m.id))); // every mask follows Motion/Opacity
        out.extend(applied.iter().filter(|e| !e.is_audio()).map(section));
        if self.audio_partner.is_some() {
            out.push(EffectSection::Volume); // Audio group: the linked audio clip's Volume and effects
            out.extend(audio_fx);
        }
        out
    }

    pub fn duration(&self) -> Time {
        self.clip.as_ref().map_or(Time::ZERO, |c| c.duration())
    }

    pub(crate) fn duration_seconds(&self) -> f64 {
        let d = self.duration();
        d.value() as f64 / d.timescale().max(1) as f64
    }

    // MARK: Zoom (keyframe area)

    /// Smallest visible span: a few frames.
    pub fn min_viewport_span(&self) -> f64 {
        4.0 * self.frame_duration.value() as f64 / self.frame_duration.timescale().max(1) as f64
    }

    /// What the lanes, ruler, clip bar, graph and zoom bar show (clip-local seconds).
    pub fn viewport(&self) -> KeyframeViewport {
        let d = self.duration_seconds();
        self.zoom_state.map_or_else(|| KeyframeViewport::full(d), |z| z.clamped(d, self.min_viewport_span()))
    }

    pub fn is_zoomed(&self) -> bool {
        !self.viewport().is_full(self.duration_seconds())
    }

    pub fn set_viewport(&mut self, v: KeyframeViewport) {
        let c = v.clamped(self.duration_seconds(), self.min_viewport_span());
        self.zoom_state = if c.is_full(self.duration_seconds()) { None } else { Some(c) };
        self.version += 1;
    }

    /// `factor` > 1 zooms in. The anchor (clip-local seconds) stays where it is on screen; default: the playhead when
    /// visible, else the window center.
    pub fn zoom(&mut self, factor: f64, anchor: Option<f64>) {
        let v = self.viewport();
        let ph = seconds(self.local_playhead());
        let (lo, hi) = v.range();
        let a = anchor.unwrap_or(if ph >= lo && ph <= hi { ph } else { v.start + v.span / 2.0 });
        self.set_viewport(v.zoomed(factor, a, self.duration_seconds(), self.min_viewport_span()));
    }

    pub fn zoom_in(&mut self) {
        self.zoom(1.6, None);
    }

    pub fn zoom_out(&mut self) {
        self.zoom(1.0 / 1.6, None);
    }

    pub fn zoom_to_fit(&mut self) {
        self.zoom_state = None;
        self.version += 1;
    }

    pub fn pan_viewport(&mut self, by_seconds: f64) {
        let v = self.viewport().panned(by_seconds, self.duration_seconds(), self.min_viewport_span());
        self.set_viewport(v);
    }

    pub(crate) fn reveal_playhead(&mut self, t: Time) {
        let Some(c) = &self.clip else { return };
        if self.zoom_state.is_none() {
            return;
        }
        let local = t - c.start;
        let v = self.viewport().revealing(seconds(local), self.duration_seconds(), self.min_viewport_span());
        self.set_viewport(v);
    }

    /// Geometry of a lane-like view of the given width (same mapping everywhere).
    pub fn lane_geometry(&self, width: f64) -> KeyframeLaneGeometry {
        KeyframeLaneGeometry::with(width, self.duration(), 10.0, self.zoom_state.map(|_| self.viewport()))
    }

    // MARK: Playhead scrubbing (ruler)

    /// Clip-local times the playhead sticks to while Shift is held: every key of every property, plus the clip ends.
    pub fn snap_targets(&self) -> Vec<Time> {
        let Some(c) = &self.clip else { return Vec::new() };
        let mut out = vec![Time::ZERO, c.duration()];
        for t in Self::tracks_of(c).values() {
            out.extend(t.times().into_iter().map(|(_, time)| time));
        }
        out
    }

    /// Timeline time for a ruler position (clip-local, frame-snapped). With `snap` the time sticks to keyframes
    /// within `threshold_seconds`.
    pub fn scrub_target(&self, local: Time, snap: bool, threshold_seconds: f64) -> Time {
        let l = if snap { KeyframeSnap::snapped(local, &self.snap_targets(), threshold_seconds) } else { local };
        self.clip.as_ref().map_or(Time::ZERO, |c| c.start) + l
    }

    pub fn scrub_down(&mut self, t: Time) {
        self.scrub_began = false;
        self.events.push(EffectControlsEvent::PointerDown);
        self.events.push(EffectControlsEvent::Seek(t));
    }

    /// Swift: with an `onScrub` hook the scrub goes there, else it is a seek. The owner decides when it drains
    /// `Scrub`; a host without a scrub handler treats it as `Seek`.
    pub fn scrub_drag(&mut self, t: Time) {
        if !self.scrub_began {
            self.scrub_began = true;
            self.events.push(EffectControlsEvent::ScrubBegan);
        }
        self.events.push(EffectControlsEvent::Scrub(t));
    }

    pub fn scrub_up(&mut self) {
        if self.scrub_began {
            self.events.push(EffectControlsEvent::ScrubEnded);
        }
        self.scrub_began = false;
    }

    pub fn local_playhead(&self) -> Time {
        self.playhead - self.clip.as_ref().map_or(Time::ZERO, |c| c.start)
    }

    pub fn playhead_in_clip(&self) -> bool {
        self.clip.is_some() && self.local_playhead() >= Time::ZERO && self.local_playhead() <= self.duration()
    }

    pub(crate) fn clip_id(&self) -> Option<Id> {
        self.clip.as_ref().map(|c| c.id)
    }

    /// A video clip is shown together with its linked audio clip (Volume and audio effects belong to that one).
    pub(crate) fn shows_audio_partner(&self) -> bool {
        self.audio_partner.is_some()
    }
}
