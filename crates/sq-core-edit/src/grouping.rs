//! Groups: a nested sequence used as a layer group; Group, Ungroup, Unnest and the Group Transform effect.
// Swift: Grouping.swift (the group transform evaluation lives in sq-core-effects `effect_transform_stage`)

use crate::timeline_magnetic::{MagneticExt, MagneticScope};
use crate::timeline_magnetic_moves::MagneticGesturesExt;
use crate::timeline_magnetic_ops::MagneticOpsExt;
use sq_core_effects::adjustment_clip::ClipAdjustmentExt;
use sq_core_effects::effect_transform_stage::{ClipEffectStage, ClipStageEval};
use sq_core_model::{AnimatedProperty, MaskSource, TimelineGroup};
use sq_core_model::{
    BinItemRef, Clip, ClipEffect, EditError, EffectCatalog, Project, SequenceFormat, Timeline, Track, TrackKind,
    Transition, TransitionKind,
};
use sq_core_time::{Id, IdSource, Time, TimeRange, Vec2};
use std::collections::{BTreeMap, BTreeSet};

/// The Group Transform of an ungrouped Group on one of its clips (Swift `extension ClipEffect`).
pub trait ClipEffectGroupExt: Sized {
    /// The Group Transform for a clip of group clip `g`: its Motion (when Motion is on) and Opacity (when Opacity is on), every
    /// key moved by `shift` (the group clip's start minus this clip's start). `None` for an audio clip.
    fn group_transform(g: &Clip, shift: Time, ids: &mut dyn IdSource) -> Option<Self>;
    /// A Group Transform that moves nothing and keeps the opacity (no keys, identity values).
    fn is_identity_group_stage(&self) -> bool;
}

impl ClipEffectGroupExt for ClipEffect {
    fn group_transform(g: &Clip, shift: Time, ids: &mut dyn IdSource) -> Option<ClipEffect> {
        if g.kind != TrackKind::Video {
            return None;
        }
        let mut e = ClipEffect::new(ids.next_id(), ClipEffect::GROUP_TRANSFORM_KIND);
        let a = &g.animation;
        if g.motion_enabled {
            e.points.insert(ClipEffect::GROUP_POSITION_KEY.to_string(), a.position.shifted(shift));
            e.points.insert(ClipEffect::GROUP_SCALE_KEY.to_string(), a.scale.shifted(shift));
            e.points.insert(ClipEffect::GROUP_ANCHOR_KEY.to_string(), a.anchor.shifted(shift));
            e.parameters.insert(ClipEffect::GROUP_ROTATION_KEY.to_string(), a.rotation.shifted(shift));
        }
        if g.opacity_enabled {
            e.parameters.insert(ClipEffect::GROUP_OPACITY_KEY.to_string(), a.opacity.shifted(shift));
        }
        Some(e)
    }

    fn is_identity_group_stage(&self) -> bool {
        if self.kind != ClipEffect::GROUP_TRANSFORM_KIND {
            return false;
        }
        let pts: [(&str, Vec2); 3] = [
            (ClipEffect::GROUP_POSITION_KEY, Vec2::ZERO),
            (ClipEffect::GROUP_SCALE_KEY, Vec2::new(1.0, 1.0)),
            (ClipEffect::GROUP_ANCHOR_KEY, Vec2::ZERO),
        ];
        let sc: [(&str, f64); 2] = [(ClipEffect::GROUP_ROTATION_KEY, 0.0), (ClipEffect::GROUP_OPACITY_KEY, 1.0)];
        pts.iter().all(|(k, d)| self.points.get(*k).is_none_or(|p| !p.is_animated() && p.value == *d))
            && sc.iter().all(|(k, d)| self.parameters.get(*k).is_none_or(|p| !p.is_animated() && p.value == *d))
    }
}

/// Clips put back by one Ungroup, per target track.
struct Placed {
    track: usize,
    clips: Vec<Clip>,
    transitions: Vec<Transition>,
}

/// `extension Project` of Grouping.swift.
pub trait ProjectGroupingExt {
    /// The sequences a user can pick (Export, opening, Project panel): everything but the inside of Groups.
    fn pickable_timelines_vec(&self) -> Vec<&Timeline>;

    /// Group: replaces the selected clips (and their linked partners) with one group clip (see the file comment). Transitions
    /// between grouped clips go inside; transitions from a grouped clip to one outside the group are removed (as Nest does).
    /// Errors as `nest`. Returns the group's inner sequence.
    fn group(&mut self, clips: &[Id], in_timeline: Id, ids: &mut dyn IdSource) -> Result<Id, EditError>;

    /// Ungroup: puts the clips of the group `clip` plays (this clip and its linked partner of the same group) back on the
    /// timeline. Clips return to their source tracks; when one is gone, to the tracks of the same kind counted up from the
    /// group clip's track (new tracks are added on top when there are too few). A copy of a group whose clips are already
    /// on the timeline gets fresh clip ids. The inner sequence is removed once no clip plays it.
    /// Errors: `NotAGroup`, `UngroupLosesLook`, `TrackLocked`, `Collision`. Returns the ids of the clips put back.
    fn ungroup(&mut self, clip: Id, in_timeline: Id, ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError>;

    /// Unnest: replaces a clip that plays an ordinary nested sequence (not a Group) with the sequence's content, under the
    /// same rules as Ungroup. The nested sequence stays in the project; the placed clips are fresh copies. A nested sequence
    /// of another frame size refuses. Throws `NotNested` for a Group or a clip that plays no sequence.
    fn unnest(&mut self, clip: Id, in_timeline: Id, ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError>;

    /// Removes Groups no clip plays any more, until none is left. Run when saving.
    fn prune_unused_groups(&mut self);
}

/// True when everything the group clip `g` does besides its Motion and Opacity is at its default, so Ungroup changes nothing.
fn ungroup_keeps_look(g: &Clip) -> bool {
    if !(g.is_enabled
        && !g.is_retimed()
        && g.hold_frame.is_none()
        && g.effects.is_empty()
        && g.blend_mode == sq_core_model::BlendMode::Normal
        && g.variant_store.as_ref().is_none_or(|s| s.items.is_empty()))
    {
        return false;
    }
    if g.kind == TrackKind::Audio {
        let v = &g.animation.volume;
        return !v.is_animated() && v.value == 1.0 && g.audio_gain_db == 0.0 && g.audio_fades.is_empty();
    }
    true
}

/// Inner track state (visibility, mute, solo, volume, pan, role) that played through the group clip's track `outer` and
/// plays the same from `target` after Ungroup.
fn track_state_carries(inner: &Track, outer: &Track, target: &Track) -> bool {
    if inner.kind == TrackKind::Video {
        return (inner.is_visible && outer.is_visible) == target.is_visible;
    }
    if (inner.is_muted || outer.is_muted) != target.is_muted
        || outer.is_solo != target.is_solo
        || (inner.is_solo && !target.is_solo)
        || (inner.volume_db + outer.volume_db - target.volume_db).abs() >= 1e-9
        || !((inner.pan == 0.0 && outer.pan == target.pan) || (outer.pan == 0.0 && inner.pan == target.pan))
    {
        return false;
    }
    inner.audio_role.or(outer.audio_role) == target.audio_role
}

/// How far (px of the clip's own frame, upper bound at any keyframe) the enabled effects of `c` draw past its picture.
/// Drop Shadow reaches its distance plus twice its softness.
fn frame_bleed(c: &Clip) -> f64 {
    fn peak(p: Option<&AnimatedProperty<f64>>) -> f64 {
        let Some(p) = p else { return 0.0 };
        p.value.abs().max(p.track.keys.iter().map(|k| k.value.abs()).fold(f64::NEG_INFINITY, f64::max))
    }
    let mut reach = 0.0_f64;
    for e in c.effects.iter().filter(|e| e.enabled && e.kind == ClipEffect::DROP_SHADOW_KIND) {
        let defaults = EffectCatalog::param(&e.kind, ClipEffect::SHADOW_DISTANCE_KEY).map_or(0.0, |p| p.default_value);
        let soft = EffectCatalog::param(&e.kind, ClipEffect::SHADOW_SOFTNESS_KEY).map_or(0.0, |p| p.default_value);
        let dk = e.parameters.get(ClipEffect::SHADOW_DISTANCE_KEY);
        let sk = e.parameters.get(ClipEffect::SHADOW_SOFTNESS_KEY);
        let d = if dk.is_none() { defaults } else { peak(dk) };
        let f = if sk.is_none() { soft } else { peak(sk) };
        reach = reach.max(d + 2.0 * f);
    }
    reach
}

/// True when the inner video tracks (cropped to what group clip `g` shows) look the same composited one by one through the
/// group's stage on the canvas as composited into the group picture first (see Swift `keepsPicture`).
fn keeps_picture(
    project: &Project,
    g: &Clip,
    tracks: &[Track],
    canvas: &SequenceFormat,
    ids: &mut dyn IdSource,
) -> bool {
    let clips: Vec<&Clip> = tracks.iter().flat_map(|t| t.clips()).collect();
    if clips.iter().any(|c| c.blend_mode != sq_core_model::BlendMode::Normal) {
        return false;
    }
    let Some(stage) = ClipEffect::group_transform(g, Time::ZERO, ids).filter(|s| !s.is_identity_group_stage()) else {
        return true;
    };
    let transitions: Vec<&Transition> = tracks.iter().flat_map(|t| t.transitions.iter()).collect();
    if transitions.iter().any(|t| t.kind != TransitionKind::CrossDissolve && t.kind != TransitionKind::QuickFade) {
        return false;
    }
    let open = clips.iter().any(|c| {
        c.animation.is_shutter_open_or_keyed()
            || c.effects.iter().any(|e| {
                if !(e.enabled && e.is_transform_stage()) {
                    return false;
                }
                let Some(s) = e.parameters.get(ClipEffect::STAGE_SHUTTER_ANGLE_KEY) else { return false };
                s.value > 0.0 || s.track.keys.iter().any(|k| k.value > 0.0)
            })
    });
    if open {
        return false;
    }
    if let Some(s) = stage.points.get(ClipEffect::GROUP_SCALE_KEY)
        && (s.value.x != s.value.y || s.track.keys.iter().any(|k| k.value.x != k.value.y))
    {
        let rotated = clips.iter().any(|c| {
            c.animation.rotation.value != 0.0 || c.animation.rotation.is_animated() || c.has_transform_stage()
        });
        if rotated {
            return false;
        }
    }
    if let Some(o) = stage.parameters.get(ClipEffect::GROUP_OPACITY_KEY)
        && (o.value != 1.0 || o.is_animated())
    {
        if !transitions.is_empty() {
            return false;
        }
        for (i, a) in clips.iter().enumerate() {
            if clips[i + 1..].iter().any(|c| c.timeline().overlaps(&a.timeline())) {
                return false;
            }
        }
    }
    // Frame corners inside the group frame at every frame (one sample for a clip that does not move). Effects that draw past
    // the picture (Drop Shadow) widen the clip's frame by their reach: the group frame cut that part off.
    let half = Vec2::new(canvas.display_width() as f64 / 2.0 + 0.5, canvas.height as f64 / 2.0 + 0.5);
    let frame = Vec2::new(canvas.display_width() as f64, canvas.height as f64);
    let fd = canvas.frame_duration;
    for c in &clips {
        let size = project.picture_size(c).unwrap_or((canvas.display_width(), canvas.height));
        let bleed = frame_bleed(c);
        let w = size.0 as f64 / 2.0 + bleed;
        let h = size.1 as f64 / 2.0 + bleed;
        let corners = [Vec2::new(-w, -h), Vec2::new(w, -h), Vec2::new(w, h), Vec2::new(-w, h)];
        let a = &c.animation;
        let moves = a.position.is_animated()
            || a.scale.is_animated()
            || a.rotation.is_animated()
            || a.anchor.is_animated()
            || c.has_transform_stage();
        let mut times = vec![c.start];
        if moves && fd > Time::ZERO {
            // Every frame, at most about 600 samples (a long clip is sampled every few frames).
            let mut step = fd;
            while step * 600 < c.source.duration {
                step = step * 2;
            }
            times = Vec::new();
            let mut t = c.start;
            while t < c.timeline().end() {
                times.push(t);
                t += step;
            }
        }
        for t in times {
            let tr = c.render_transform(t, frame);
            for p in corners {
                let q = tr.map(p);
                if q.x.abs() > half.x || q.y.abs() > half.y {
                    return false;
                }
            }
        }
    }
    true
}

/// Every Track Mask effect's track runs through `f` (a `None` result clears it).
fn mapping_track_masks(c: &Clip, f: &dyn Fn(Id) -> Option<Id>) -> Clip {
    let mut n = c.clone();
    for e in n.effects.iter_mut().filter(|e| e.is_track_mask()) {
        if let Some(t) = e.mask_track {
            e.mask_track = f(t);
        }
    }
    n
}

fn next_group_name(project: &Project) -> String {
    let names: BTreeSet<&str> = project.timelines.iter().map(|t| t.name.as_str()).collect();
    let mut n = 1;
    while names.contains(format!("Group {n:02}").as_str()) {
        n += 1;
    }
    format!("Group {n:02}")
}

fn restore_content(
    project: &mut Project,
    clip_id: Id,
    timeline_id: Id,
    plain: bool,
    ids: &mut dyn IdSource,
) -> Result<Vec<Id>, EditError> {
    let oi = project.timelines.iter().position(|t| t.id == timeline_id).ok_or(EditError::TimelineNotFound)?;
    let mut tl = project.timelines[oi].clone();
    let hit = tl.find(clip_id).ok_or(EditError::ClipNotFound)?;
    let (Some(seq_id), true) = (hit.clip.sequence, hit.clip.sequence.is_some_and(|s| project.timeline(s).is_some()))
    else {
        return Err(EditError::NotAGroup);
    };
    let inner = project.timeline(seq_id).ok_or(EditError::NotAGroup)?.clone();
    if plain {
        if inner.group.is_some() || hit.clip.angle.is_some() {
            return Err(EditError::NotNested);
        }
        if inner.format.display_width() != tl.format.display_width() || inner.format.height != tl.format.height {
            return Err(EditError::UngroupLosesLook);
        }
    } else if inner.group.is_none() {
        return Err(EditError::NotAGroup);
    }
    let info = inner.group.clone().unwrap_or(TimelineGroup { source_tracks: BTreeMap::new() });
    let partners: Vec<_> = tl.linked_group(clip_id)?.into_iter().filter(|m| m.clip.sequence == Some(seq_id)).collect();
    if partners.iter().any(|m| tl.tracks[m.track].is_locked) {
        return Err(EditError::TrackLocked);
    }
    let partner_ids: BTreeSet<Id> = partners.iter().map(|m| m.clip.id).collect();
    for m in &partners {
        if !ungroup_keeps_look(&m.clip) {
            return Err(EditError::UngroupLosesLook);
        }
        let touching = tl.tracks[m.track]
            .transitions
            .iter()
            .any(|tr| [tr.outgoing, tr.incoming].iter().any(|e| e.is_some_and(|e| partner_ids.contains(&e))));
        if touching {
            return Err(EditError::UngroupLosesLook);
        }
    }
    // Sequence items Ungroup has nowhere to put (markers, In/Out, captions, Sequence Volume).
    if (!plain
        && (!inner.markers.is_empty()
            || inner.in_out.is_some()
            || inner.caption_tracks.iter().any(|c| !c.items().is_empty())))
        || inner.master_volume_db() != 0.0
        || inner.is_master_volume_keyed()
    {
        return Err(EditError::UngroupLosesLook);
    }
    for m in &partners {
        tl.tracks[m.track].remove(m.clip.id);
    }
    // Track ids, not indices: a track added below for one partner shifts the indices of the next.
    let partner_tracks: Vec<Track> = partners.iter().map(|m| tl.tracks[m.track].clone()).collect();

    // Inner clips per partner, cropped to what the group shows and moved to outer time.
    let mut placed: Vec<Placed> = Vec::new();
    let mut outer_track: BTreeMap<Id, Id> = BTreeMap::new(); // inner video track -> the outer track its clips land on
    for (m, partner_track) in partners.iter().zip(&partner_tracks) {
        let g = &m.clip;
        let kind = g.kind;
        let own = tl.tracks.iter().position(|t| t.id == partner_track.id);
        let window = g.source;
        let kind_tracks: Vec<usize> = (0..tl.tracks.len()).filter(|i| tl.tracks[*i].kind == kind).collect();
        let mut cropped: Vec<Track> = Vec::new();
        for it in inner.tracks.iter().filter(|t| t.kind == kind) {
            let mut scratch = it.clone();
            if window.start > Time::ZERO {
                scratch.clear(TimeRange::from_end(Time::ZERO, window.start), ids);
            }
            if scratch.end() > window.end() {
                let end = scratch.end();
                scratch.clear(TimeRange::from_end(window.end(), end), ids);
            }
            cropped.push(scratch);
        }
        if kind == TrackKind::Video && !keeps_picture(project, g, &cropped, &inner.format, ids) {
            return Err(EditError::UngroupLosesLook);
        }
        for (ordinal, scratch) in cropped.iter().enumerate() {
            if scratch.clips().is_empty() {
                continue;
            }
            let src_index = info
                .source_tracks
                .get(&scratch.id)
                .and_then(|src| tl.tracks.iter().position(|t| t.id == *src))
                .filter(|i| tl.tracks[*i].kind == kind);
            let base = own.and_then(|o| kind_tracks.iter().position(|k| *k == o));
            let target = if let Some(i) = src_index {
                i
            } else if let Some(base) = base.filter(|b| b + ordinal < kind_tracks.len()) {
                kind_tracks[base + ordinal]
            } else {
                let after = tl.tracks.iter().rposition(|t| t.kind == kind).map_or(tl.tracks.len(), |i| i + 1);
                tl.tracks.insert(after, Track::new(ids.next_id(), kind));
                for p in placed.iter_mut().filter(|p| p.track >= after) {
                    p.track += 1;
                }
                after
            };
            if tl.tracks[target].is_locked {
                return Err(EditError::TrackLocked);
            }
            if !track_state_carries(scratch, partner_track, &tl.tracks[target]) {
                return Err(EditError::UngroupLosesLook);
            }
            if kind == TrackKind::Video {
                outer_track.insert(scratch.id, tl.tracks[target].id);
                // An Adjustment Layer only reached the inner layers below it; on the outer timeline it would also reach
                // the outer clips on lower tracks it overlaps.
                for adj in scratch.clips().iter().filter(|c| c.is_adjustment()) {
                    let range = TimeRange::new(adj.start - window.start + g.start, adj.timeline().duration);
                    let reaches = tl.tracks[..target].iter().any(|t| {
                        t.kind == TrackKind::Video
                            && t.is_visible
                            && t.clips().iter().any(|c| c.timeline().overlaps(&range))
                    });
                    if reaches {
                        return Err(EditError::UngroupLosesLook);
                    }
                }
            }
            let mut clips: Vec<Clip> = Vec::new();
            for c in scratch.clips() {
                let mut c = c.clone();
                c.start = c.start - window.start + g.start;
                if kind == TrackKind::Video
                    && let Some(e) = ClipEffect::group_transform(g, g.start - c.start, ids)
                    && !e.is_identity_group_stage()
                {
                    c.effects.push(e);
                }
                clips.push(c);
            }
            placed.push(Placed { track: target, clips, transitions: scratch.transitions.clone() });
        }
    }

    // Picture masks read inner track ids: follow them to the outer tracks the clips landed on; a matte track whose clips
    // were not placed has no outer equivalent, so the mask reads nothing.
    for p in placed.iter_mut().filter(|p| tl.tracks[p.track].kind == TrackKind::Video) {
        let map = |id: Id| outer_track.get(&id).copied();
        p.clips = p
            .clips
            .iter()
            .map(|c| {
                let reads_tracks = c
                    .mask_store
                    .iter()
                    .flatten()
                    .any(|m| m.source() == MaskSource::Picture && m.picture_track.is_some())
                    || c.effects.iter().any(|e| e.is_track_mask() && e.mask_track.is_some());
                if !reads_tracks {
                    return c.clone();
                }
                let mut c = mapping_track_masks(c, &map);
                for m in c.mask_store.iter_mut().flatten() {
                    if m.source() != MaskSource::Picture {
                        continue;
                    }
                    let Some(old) = m.picture_track else { continue };
                    m.picture_track = map(old);
                }
                c
            })
            .collect();
    }

    // A copy of a group whose clips are already back gets fresh ids (and links, so the copies link to each other).
    let existing: BTreeSet<Id> = tl.tracks.iter().flat_map(|t| t.clips()).map(|c| c.id).collect();
    if plain || placed.iter().any(|p| p.clips.iter().any(|c| existing.contains(&c.id))) {
        let mut fresh_ids: BTreeMap<Id, Id> = BTreeMap::new();
        let mut links: BTreeMap<Id, Id> = BTreeMap::new();
        for p in placed.iter_mut() {
            for c in p.clips.iter_mut() {
                let fresh = ids.next_id();
                fresh_ids.insert(c.id, fresh);
                c.id = fresh;
                if let Some(l) = c.link {
                    let n = *links.entry(l).or_insert_with(|| ids.next_id());
                    c.link = Some(n);
                }
            }
        }
        for p in placed.iter_mut() {
            for c in p.clips.iter_mut().filter(|c| c.attachment.is_some()) {
                c.remap_attachment(&fresh_ids);
            }
            for tr in p.transitions.iter_mut() {
                tr.id = ids.next_id();
                tr.outgoing = tr.outgoing.map(|o| fresh_ids.get(&o).copied().unwrap_or(o));
                tr.incoming = tr.incoming.map(|o| fresh_ids.get(&o).copied().unwrap_or(o));
            }
        }
    }

    for p in &placed {
        for c in &p.clips {
            if tl.tracks[p.track].clips().iter().any(|x| x.timeline().overlaps(&c.timeline())) {
                return Err(EditError::Collision);
            }
            tl.tracks[p.track].overwrite(c.clone(), ids)?;
        }
        tl.tracks[p.track].transitions.extend(p.transitions.iter().cloned());
    }
    tl.prune_transitions();
    // Fast Cut: clips attached to the group clip go back to the restored clip under their attach time (nest moved them
    // onto the group clip); with none there they are dropped and re-derived at the next Fast Cut edit.
    let back: BTreeSet<Id> = placed.iter().flat_map(|p| p.clips.iter().map(|c| c.id)).collect();
    for i in 0..tl.tracks.len() {
        if !tl.tracks[i].clips().iter().any(|c| c.attachment.as_ref().is_some_and(|a| partner_ids.contains(&a.host))) {
            continue;
        }
        let snapshot = tl.clone();
        tl.tracks[i].map_clips_keeping_timing(|c| {
            let Some(a) = &c.attachment else { return c.clone() };
            if !partner_ids.contains(&a.host) {
                return c.clone();
            }
            let mut c = c.clone();
            let host = snapshot.attach_host(c.start + a.point);
            c.attachment =
                host.filter(|h| back.contains(h)).map(|h| sq_core_model::ClipAttachment { host: h, point: a.point });
            c
        });
    }
    // One side of an unlinked group: its clips' partners stay inside the other side, so their links point at nothing.
    let restored_links: BTreeSet<Id> = placed.iter().flat_map(|p| p.clips.iter().filter_map(|c| c.link)).collect();
    let mut link_count: BTreeMap<Id, usize> = BTreeMap::new();
    for t in tl.tracks.iter() {
        for c in t.clips() {
            if let Some(l) = c.link.filter(|l| restored_links.contains(l)) {
                *link_count.entry(l).or_insert(0) += 1;
            }
        }
    }
    let restored: BTreeSet<Id> = placed.iter().flat_map(|p| p.clips.iter().map(|c| c.id)).collect();
    for i in 0..tl.tracks.len() {
        let clips: Vec<Clip> = tl.tracks[i].clips().to_vec();
        for mut c in clips.into_iter().filter(|c| restored.contains(&c.id)) {
            if let Some(l) = c.link
                && link_count.get(&l).copied().unwrap_or(0) < 2
            {
                c.link = None;
                tl.tracks[i].replace(c);
            }
        }
    }

    let mut work = project.clone();
    work.timelines[oi] = tl;
    if !plain
        && !work
            .timelines
            .iter()
            .any(|t| t.tracks.iter().any(|tr| tr.clips().iter().any(|c| c.sequence == Some(seq_id))))
    {
        work.timelines.retain(|t| t.id != seq_id);
        work.root_bin.prune(&|r| r != BinItemRef::Sequence(seq_id));
    }
    *project = work;
    Ok(placed.iter().flat_map(|p| p.clips.iter().map(|c| c.id)).collect())
}

impl ProjectGroupingExt for Project {
    fn pickable_timelines_vec(&self) -> Vec<&Timeline> {
        self.pickable_timelines().collect()
    }

    fn group(&mut self, clips: &[Id], in_timeline: Id, ids: &mut dyn IdSource) -> Result<Id, EditError> {
        let tl = self.timeline(in_timeline).ok_or(EditError::TimelineNotFound)?.clone();
        if clips.is_empty() {
            return Err(EditError::EmptyClip);
        }
        let mut selected: BTreeSet<Id> = BTreeSet::new();
        for id in clips {
            for m in tl.linked_group(*id)? {
                selected.insert(m.clip.id);
            }
        }
        // Same track choice as `nest`: every track holding a selected clip, in timeline order.
        let involved: Vec<usize> =
            (0..tl.tracks.len()).filter(|i| tl.tracks[*i].clips().iter().any(|c| selected.contains(&c.id))).collect();
        let inside: Vec<Vec<Transition>> = involved
            .iter()
            .map(|i| {
                tl.tracks[*i]
                    .transitions
                    .iter()
                    .filter(|tr| {
                        let ends: Vec<Id> = [tr.outgoing, tr.incoming].into_iter().flatten().collect();
                        !ends.is_empty() && ends.iter().all(|e| selected.contains(e))
                    })
                    .cloned()
                    .collect()
            })
            .collect();
        let mut work = self.clone();
        let name = next_group_name(&work);
        let seq_id = work.nest(clips, in_timeline, Some(&name), ids)?;
        let si = work.timelines.iter().position(|t| t.id == seq_id).ok_or(EditError::TimelineNotFound)?;
        let oi = work.timelines.iter().position(|t| t.id == in_timeline).ok_or(EditError::TimelineNotFound)?;
        let mut map: BTreeMap<Id, Id> = BTreeMap::new();
        for (k, i) in involved.iter().enumerate() {
            if k < work.timelines[si].tracks.len() {
                map.insert(work.timelines[si].tracks[k].id, tl.tracks[*i].id);
            }
        }
        work.timelines[si].group = Some(TimelineGroup { source_tracks: map });
        for (k, trs) in inside.into_iter().enumerate() {
            if k < work.timelines[si].tracks.len() {
                work.timelines[si].tracks[k].transitions = trs;
            }
        }
        work.root_bin.prune(&|r| r != BinItemRef::Sequence(seq_id));
        work.timelines[oi].prune_transitions();
        *self = work;
        Ok(seq_id)
    }

    fn ungroup(&mut self, clip: Id, in_timeline: Id, ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError> {
        restore_content(self, clip, in_timeline, false, ids)
    }

    fn unnest(&mut self, clip: Id, in_timeline: Id, ids: &mut dyn IdSource) -> Result<Vec<Id>, EditError> {
        let fast_cut = self.timelines.iter().find(|t| t.id == in_timeline).filter(|t| t.is_fast_cut());
        let Some(oi) = self.timelines.iter().position(|t| t.id == in_timeline).filter(|_| fast_cut.is_some()) else {
            return restore_content(self, clip, in_timeline, true, ids);
        };
        // Fast Cut: runs through `magnetic_edit` (attached clips keep their hosts) and closes the holes the content leaves on
        // V1 (a nested sequence whose own main track has gaps), so V1 stays gapless.
        let mut work = self.clone();
        let mut tl = self.timelines[oi].clone();
        let scope = MagneticScope { involving: BTreeSet::from([clip]), ..MagneticScope::default() };
        let restored = tl.magnetic_edit(scope, ids, |w, ids| {
            work.timelines[oi] = w.clone();
            let out = restore_content(&mut work, clip, in_timeline, true, ids)?;
            *w = work.timelines[oi].clone();
            w.close_main_holes()?;
            Ok(out)
        })?;
        work.timelines[oi] = tl;
        *self = work;
        Ok(restored)
    }

    fn prune_unused_groups(&mut self) {
        loop {
            let played: BTreeSet<Id> = self
                .timelines
                .iter()
                .flat_map(|t| t.tracks.iter().flat_map(|tr| tr.clips().iter().filter_map(|c| c.sequence)))
                .collect();
            let unused: BTreeSet<Id> =
                self.timelines.iter().filter(|t| t.is_group() && !played.contains(&t.id)).map(|t| t.id).collect();
            if unused.is_empty() {
                return;
            }
            self.timelines.retain(|t| !unused.contains(&t.id));
            self.root_bin.prune(&|r| match r {
                BinItemRef::Sequence(id) => !unused.contains(&id),
                _ => true,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_magnetic::test_support::dissolve;
    use sq_core_model::{BlendMode, ClipSpeed, MediaRef};
    use sq_core_time::SequentialIds;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    /// Fresh ids far from the fixed fixture ids.
    struct Fresh(u128);
    impl IdSource for Fresh {
        fn next_id(&mut self) -> Id {
            self.0 += 1;
            Id::from_u128(self.0)
        }
    }

    fn fresh() -> Fresh {
        Fresh(10_000)
    }

    fn pic() -> Id {
        Id::from_u128(100)
    }

    /// One 640 x 360 picture every fixture clip plays (so Ungroup can measure their frames).
    fn pic_ref() -> MediaRef {
        let v = serde_json::json!({"id": pic(), "name": "pic", "path": "/pic.mov", "fingerprint": {"size": 1},
            "info": {"duration": {"value": 100, "timescale": 1}, "video": {"width": 640, "height": 360, "codec": "h264",
            "bitDepth": 8, "chroma": "420", "nominalFrameDuration": {"value": 1, "timescale": 30},
            "isVariableFrameRate": false}}});
        serde_json::from_value(v).unwrap()
    }

    fn clip(n: u128, start: i64, dur: i64, src: i64, kind: TrackKind, link: Option<u128>) -> Clip {
        let mut c = Clip::new(Id::from_u128(n), "c", pic(), kind, TimeRange::new(s(src), s(dur)), s(start));
        c.link = link.map(Id::from_u128);
        c.media_duration = Some(s(100));
        c
    }

    fn track(n: u128, clips: Vec<Clip>, kind: TrackKind) -> Track {
        let mut ids = fresh();
        let mut t = Track::new(Id::from_u128(n), kind);
        for c in clips {
            t.overwrite(c, &mut ids).unwrap();
        }
        t
    }

    fn timeline(tracks: Vec<Track>) -> Timeline {
        Timeline::new(Id::from_u128(50), "Main", SequenceFormat::new(Time::new(1, 30)), tracks)
    }

    /// V1: a (0...3) dissolve b (3...6), V2: c (1...4) linked to audio d, V3: e outside the group.
    fn fixture() -> (Project, Timeline) {
        let mut a = clip(1, 0, 3, 10, TrackKind::Video, None);
        let b = clip(2, 3, 3, 20, TrackKind::Video, None);
        a.animation.scale = AnimatedProperty::new(Vec2::new(1.2, 1.2));
        let mut c = clip(3, 1, 3, 0, TrackKind::Video, Some(90));
        c.animation.rotation = AnimatedProperty::new(15.0);
        let d = clip(4, 1, 3, 0, TrackKind::Audio, Some(90));
        let e = clip(5, 10, 2, 0, TrackKind::Video, None);
        let mut v1 = track(61, vec![a, b], TrackKind::Video);
        v1.transitions = vec![dissolve(Id::from_u128(70), Some(Id::from_u128(1)), Some(Id::from_u128(2)))];
        v1.transitions[0].duration = Time::new(10, 30);
        let outer = timeline(vec![
            v1,
            track(62, vec![c], TrackKind::Video),
            track(63, vec![e], TrackKind::Video),
            track(64, vec![d], TrackKind::Audio),
        ]);
        (Project::new(Id::from_u128(999), "P", vec![pic_ref()], vec![outer.clone()]), outer)
    }

    fn cid(n: u128) -> Id {
        Id::from_u128(n)
    }

    fn outer_of(p: &Project) -> &Timeline {
        p.timeline(cid(50)).unwrap()
    }

    fn group_clip(p: &Project, track: usize, seq: Id) -> Clip {
        outer_of(p).tracks[track].clips().iter().find(|c| c.sequence == Some(seq)).unwrap().clone()
    }

    /// Replaces the clip `c` of outer track `track` with `c`.
    fn put(p: &mut Project, track: usize, c: Clip) {
        let i = p.timelines.iter().position(|t| t.id == cid(50)).unwrap();
        p.timelines[i].tracks[track].replace(c);
    }

    fn edit_group(p: &mut Project, track: usize, seq: Id, body: impl FnOnce(&mut Clip)) -> Clip {
        let mut g = group_clip(p, track, seq);
        body(&mut g);
        put(p, track, g.clone());
        g
    }

    fn edit_inner(p: &mut Project, seq: Id, body: impl FnOnce(&mut Timeline)) {
        let i = p.timelines.iter().position(|t| t.id == seq).unwrap();
        body(&mut p.timelines[i]);
    }

    #[test]
    fn group_then_ungroup_restores_the_timeline_exactly() {
        let (mut p, outer) = fixture();
        let bins = p.root_bin.clone();
        let mut ids = fresh();
        let seq = p.group(&[cid(1), cid(2), cid(3)], cid(50), &mut ids).unwrap();

        let inner = p.timeline(seq).unwrap();
        assert!(inner.is_group());
        assert_eq!(inner.name, "Group 01");
        let src = &inner.group.as_ref().unwrap().source_tracks;
        let mapped: Vec<Option<Id>> = inner.tracks.iter().map(|t| src.get(&t.id).copied()).collect();
        assert_eq!(mapped, vec![Some(cid(61)), Some(cid(62)), Some(cid(64))]);
        assert_eq!(inner.tracks[0].transitions.len(), 1);
        // Groups are not filed in the Project panel.
        assert_eq!(p.root_bin.parent_of(BinItemRef::Sequence(seq)), None);
        let gv = group_clip(&p, 0, seq);
        assert_eq!(gv.timeline(), TimeRange::from_end(s(0), s(6)));
        assert!(outer_of(&p).tracks[0].transitions.is_empty());
        assert_eq!(outer_of(&p).tracks[3].clips()[0].sequence, Some(seq));

        let restored = p.ungroup(gv.id, cid(50), &mut ids).unwrap();
        assert_eq!(restored.iter().copied().collect::<BTreeSet<_>>(), BTreeSet::from([cid(1), cid(2), cid(3), cid(4)]));
        assert_eq!(*outer_of(&p), outer);
        assert!(p.timeline(seq).is_none());
        assert_eq!(p.timelines.len(), 1);
        assert_eq!(p.root_bin, bins);
    }

    #[test]
    fn ungroup_from_the_audio_partner_works_too() {
        let (mut p, outer) = fixture();
        let mut ids = fresh();
        let seq = p.group(&[cid(3)], cid(50), &mut ids).unwrap();
        let ga = group_clip(&p, 3, seq);
        p.ungroup(ga.id, cid(50), &mut ids).unwrap();
        assert_eq!(*outer_of(&p), outer);
    }

    #[test]
    fn ungroup_refuses_a_group_with_its_own_sequence_volume() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let seq = p.group(&[cid(1)], cid(50), &mut ids).unwrap();
        let g = group_clip(&p, 0, seq);
        edit_inner(&mut p, seq, |t| t.set_master_volume_db(-6.0));
        let snapshot = p.clone();
        assert_eq!(p.ungroup(g.id, cid(50), &mut ids), Err(EditError::UngroupLosesLook));
        assert_eq!(p, snapshot);
        edit_inner(&mut p, seq, |t| t.set_master_volume_db(0.0));
        p.ungroup(g.id, cid(50), &mut ids).unwrap();
    }

    #[test]
    fn ungroup_refuses_what_it_cannot_keep() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let seq = p.group(&[cid(1)], cid(50), &mut ids).unwrap();
        let mut g = edit_group(&mut p, 0, seq, |g| {
            g.effects = vec![ClipEffect::make(cid(80), ClipEffect::DROP_SHADOW_KIND).unwrap()];
        });
        let snapshot = p.clone();
        assert_eq!(p.ungroup(g.id, cid(50), &mut ids), Err(EditError::UngroupLosesLook));
        assert_eq!(p, snapshot);

        g.effects = vec![];
        g.speed = ClipSpeed::new(2, 1);
        put(&mut p, 0, g.clone());
        assert_eq!(p.ungroup(g.id, cid(50), &mut ids), Err(EditError::UngroupLosesLook));
        // Only groups ungroup: a plain nest does not.
        let (mut q, _) = fixture();
        let nest = q.nest(&[cid(5)], cid(50), None, &mut ids).unwrap();
        let n = group_clip(&q, 2, nest);
        assert_eq!(q.ungroup(n.id, cid(50), &mut ids), Err(EditError::NotAGroup));
    }

    #[test]
    fn ungroup_of_a_trimmed_group_trims_the_children() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let seq = p.group(&[cid(1), cid(2)], cid(50), &mut ids).unwrap();
        let mut g = group_clip(&p, 0, seq);
        // Group 0...6 trimmed to inner 1...4, moved to 20.
        g.source = TimeRange::from_end(s(1), s(4));
        g.start = s(20);
        let i = p.timelines.iter().position(|t| t.id == cid(50)).unwrap();
        p.timelines[i].tracks[0].remove(g.id);
        p.timelines[i].tracks[0].overwrite(g.clone(), &mut ids).unwrap();
        p.ungroup(g.id, cid(50), &mut ids).unwrap();
        let v1 = outer_of(&p).tracks[0].clips();
        let ranges: Vec<TimeRange> = v1.iter().map(Clip::timeline).collect();
        assert_eq!(ranges, vec![TimeRange::from_end(s(20), s(22)), TimeRange::from_end(s(22), s(23))]);
        assert_eq!(v1.iter().map(|c| c.source.start).collect::<Vec<_>>(), vec![s(11), s(20)]);
        assert_eq!(v1[0].id, cid(1));
    }

    #[test]
    fn ungroup_falls_back_when_the_source_track_is_gone() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let seq = p.group(&[cid(3)], cid(50), &mut ids).unwrap(); // from V2 (+ A1)
        let gv = group_clip(&p, 1, seq);
        // Move the group to V3 at 20 and delete V2.
        let i = p.timelines.iter().position(|t| t.id == cid(50)).unwrap();
        let o = &mut p.timelines[i];
        o.tracks[1].remove(gv.id);
        let mut moved = gv.clone();
        moved.start = s(20);
        o.tracks[2].overwrite(moved, &mut ids).unwrap();
        o.tracks.remove(1);
        let mut ga = o.tracks[2].clips().iter().find(|c| c.sequence == Some(seq)).unwrap().clone();
        o.tracks[2].remove(ga.id);
        ga.start = s(20);
        o.tracks[2].overwrite(ga, &mut ids).unwrap();
        p.ungroup(gv.id, cid(50), &mut ids).unwrap();
        let back = outer_of(&p);
        assert!(back.tracks[1].clips().iter().any(|c| c.id == cid(3) && c.start == s(20)));
        assert!(back.tracks[2].clips().iter().any(|c| c.id == cid(4) && c.start == s(20)));
    }

    #[test]
    fn ungroup_refuses_a_collision() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        // c (V2) and e (V3) group onto V2; then something lands on V3 where e would return.
        let seq = p.group(&[cid(3), cid(5)], cid(50), &mut ids).unwrap();
        let gv = group_clip(&p, 1, seq);
        let i = p.timelines.iter().position(|t| t.id == cid(50)).unwrap();
        assert!(p.timelines[i].tracks[2].clips().is_empty());
        p.timelines[i].tracks[2].overwrite(clip(6, 10, 1, 0, TrackKind::Video, None), &mut ids).unwrap();
        let snapshot = p.clone();
        assert_eq!(p.ungroup(gv.id, cid(50), &mut ids), Err(EditError::Collision));
        assert_eq!(p, snapshot);
    }

    #[test]
    fn a_copied_group_keeps_its_sequence_after_the_other_is_ungrouped() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let seq = p.group(&[cid(5)], cid(50), &mut ids).unwrap();
        let g = group_clip(&p, 2, seq);
        let mut copy = g.clone();
        copy.id = cid(77);
        copy.start = s(30);
        let i = p.timelines.iter().position(|t| t.id == cid(50)).unwrap();
        p.timelines[i].tracks[2].overwrite(copy.clone(), &mut ids).unwrap();
        p.ungroup(g.id, cid(50), &mut ids).unwrap();
        assert!(p.timeline(seq).is_some());
        p.ungroup(copy.id, cid(50), &mut ids).unwrap();
        assert!(p.timeline(seq).is_none());
        let v3 = outer_of(&p).tracks[2].clips();
        assert_eq!(v3.iter().map(|c| c.start).collect::<Vec<_>>(), vec![s(10), s(30)]);
        // The second copy got fresh ids (the first already owns the originals).
        assert!(v3[0].id == cid(5) && v3[1].id != cid(5));
    }

    #[test]
    fn group_names_count_up() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let a = p.group(&[cid(5)], cid(50), &mut ids).unwrap();
        let b = p.group(&[cid(3)], cid(50), &mut ids).unwrap();
        assert_eq!(p.timeline(a).unwrap().name, "Group 01");
        assert_eq!(p.timeline(b).unwrap().name, "Group 02");
    }

    #[test]
    fn group_transform_effect_is_a_no_op_at_identity() {
        let g = Clip::new(cid(1), "g", cid(2), TrackKind::Video, TimeRange::new(Time::ZERO, s(2)), Time::ZERO);
        let e = ClipEffect::group_transform(&g, Time::ZERO, &mut SequentialIds::default()).unwrap();
        assert!(e.is_identity_group_stage());
        let audio = Clip::new(cid(1), "g", cid(2), TrackKind::Audio, TimeRange::new(Time::ZERO, s(2)), Time::ZERO);
        assert!(ClipEffect::group_transform(&audio, Time::ZERO, &mut SequentialIds::default()).is_none());
    }

    #[test]
    fn group_transform_survives_ungroup_as_one_effect_per_video_clip() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let seq = p.group(&[cid(1), cid(2), cid(3)], cid(50), &mut ids).unwrap();
        let g = edit_group(&mut p, 0, seq, |g| {
            g.animation.scale = AnimatedProperty::new(Vec2::new(0.8, 0.8));
            g.animation.anchor = AnimatedProperty::new(Vec2::new(40.0, 20.0));
        });
        p.ungroup(g.id, cid(50), &mut ids).unwrap();
        let back = outer_of(&p);
        let a = back.tracks[0].clips().iter().find(|c| c.id == cid(1)).unwrap();
        assert_eq!(
            a.effects.iter().map(|e| e.kind.as_str()).collect::<Vec<_>>(),
            vec![ClipEffect::GROUP_TRANSFORM_KIND]
        );
        // Audio children get no picture effect.
        assert!(back.tracks[3].clips()[0].effects.is_empty());
    }

    #[test]
    fn ungroup_refuses_non_uniform_scale_over_a_rotated_clip() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let seq = p.group(&[cid(1), cid(2), cid(3)], cid(50), &mut ids).unwrap(); // c is rotated 15 degrees
        let g = edit_group(&mut p, 0, seq, |g| g.animation.scale = AnimatedProperty::new(Vec2::new(1.2, 0.8)));
        assert_eq!(p.ungroup(g.id, cid(50), &mut ids), Err(EditError::UngroupLosesLook));
        // Without a rotated clip the same scale is exact.
        let (mut q, _) = fixture();
        let seq2 = q.group(&[cid(5)], cid(50), &mut ids).unwrap();
        let g2 = edit_group(&mut q, 2, seq2, |g| g.animation.scale = AnimatedProperty::new(Vec2::new(1.2, 0.8)));
        q.ungroup(g2.id, cid(50), &mut ids).unwrap();
    }

    #[test]
    fn ungroup_refuses_group_opacity_over_overlapping_clips() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let seq = p.group(&[cid(1), cid(2), cid(3)], cid(50), &mut ids).unwrap();
        let g = edit_group(&mut p, 0, seq, |g| g.animation.opacity = AnimatedProperty::new(0.5));
        assert_eq!(p.ungroup(g.id, cid(50), &mut ids), Err(EditError::UngroupLosesLook));
        // One clip alone: the opacity multiplies exactly.
        let (mut q, _) = fixture();
        let seq2 = q.group(&[cid(5)], cid(50), &mut ids).unwrap();
        let g2 = edit_group(&mut q, 2, seq2, |g| g.animation.opacity = AnimatedProperty::new(0.5));
        q.ungroup(g2.id, cid(50), &mut ids).unwrap();
    }

    #[test]
    fn ungroup_refuses_content_the_group_frame_cut_off() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        // e is 640 x 360 at 400 %: wider than the 1920 x 1080 group frame, which cuts it.
        let mut e = outer_of(&p).tracks[2].clips()[0].clone();
        e.animation.scale = AnimatedProperty::new(Vec2::new(4.0, 4.0));
        put(&mut p, 2, e);
        let seq = p.group(&[cid(5)], cid(50), &mut ids).unwrap();
        let mut untouched = p.clone();
        let g = edit_group(&mut p, 2, seq, |g| g.animation.scale = AnimatedProperty::new(Vec2::new(0.5, 0.5)));
        assert_eq!(p.ungroup(g.id, cid(50), &mut ids), Err(EditError::UngroupLosesLook));
        // An untouched group cuts at the canvas edge, as the canvas does.
        untouched.ungroup(g.id, cid(50), &mut ids).unwrap();
    }

    #[test]
    fn ungroup_refuses_inner_blend_modes_and_dips() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let seq = p.group(&[cid(5)], cid(50), &mut ids).unwrap();
        edit_inner(&mut p, seq, |t| {
            let mut e = t.tracks[0].clips()[0].clone();
            e.blend_mode = BlendMode::Multiply;
            t.tracks[0].replace(e);
        });
        let g = group_clip(&p, 2, seq);
        assert_eq!(p.ungroup(g.id, cid(50), &mut ids), Err(EditError::UngroupLosesLook));

        // A dip inside a moved group filled the group frame, not the canvas.
        let (mut q, _) = fixture();
        let seq2 = q.group(&[cid(1), cid(2), cid(3)], cid(50), &mut ids).unwrap();
        edit_inner(&mut q, seq2, |t| t.tracks[0].transitions[0].kind = TransitionKind::DipToBlack);
        let mut still = q.clone();
        let g2 = edit_group(&mut q, 0, seq2, |g| g.animation.position = AnimatedProperty::new(Vec2::new(50.0, 0.0)));
        assert_eq!(q.ungroup(g2.id, cid(50), &mut ids), Err(EditError::UngroupLosesLook));
        still.ungroup(g2.id, cid(50), &mut ids).unwrap();
    }

    #[test]
    fn ungroup_refuses_inner_track_state_and_sequence_items() {
        let (base0, _) = fixture();
        let mut ids = fresh();
        let mut base = base0.clone();
        let seq = base.group(&[cid(5)], cid(50), &mut ids).unwrap();
        let g = group_clip(&base, 2, seq);
        let mut hidden = base.clone();
        edit_inner(&mut hidden, seq, |t| t.tracks[0].is_visible = false);
        assert_eq!(hidden.ungroup(g.id, cid(50), &mut ids), Err(EditError::UngroupLosesLook));
        let mut marked = base.clone();
        edit_inner(&mut marked, seq, |t| {
            t.markers = vec![
                serde_json::from_value(serde_json::json!({"id": cid(9), "time": {"value": 1, "timescale": 1}}))
                    .unwrap(),
            ]
        });
        assert_eq!(marked.ungroup(g.id, cid(50), &mut ids), Err(EditError::UngroupLosesLook));
        let mut ranged = base.clone();
        edit_inner(&mut ranged, seq, |t| t.in_out = Some(TimeRange::from_end(s(0), s(1))));
        assert_eq!(ranged.ungroup(g.id, cid(50), &mut ids), Err(EditError::UngroupLosesLook));
        // Grouped from a muted track: inside and outside are muted alike, so Ungroup keeps the sound.
        let mut q = base0.clone();
        let i = q.timelines.iter().position(|t| t.id == cid(50)).unwrap();
        q.timelines[i].tracks[3].is_muted = true;
        let seq2 = q.group(&[cid(3)], cid(50), &mut ids).unwrap();
        let g2 = group_clip(&q, 1, seq2);
        q.ungroup(g2.id, cid(50), &mut ids).unwrap();
        assert!(outer_of(&q).tracks[3].is_muted);
    }

    #[test]
    fn ungroup_checks_locks_on_the_destination_tracks() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        // c (V2) and e (V3) group onto V2; then V3 is locked.
        let seq = p.group(&[cid(3), cid(5)], cid(50), &mut ids).unwrap();
        let i = p.timelines.iter().position(|t| t.id == cid(50)).unwrap();
        p.timelines[i].tracks[2].is_locked = true;
        let g = group_clip(&p, 1, seq);
        let snapshot = p.clone();
        assert_eq!(p.ungroup(g.id, cid(50), &mut ids), Err(EditError::TrackLocked));
        assert_eq!(p, snapshot);
    }

    #[test]
    fn ungroup_maps_reordered_and_added_inner_tracks_by_id() {
        let (mut p, outer) = fixture();
        let mut ids = fresh();
        let seq = p.group(&[cid(1), cid(2), cid(3)], cid(50), &mut ids).unwrap();
        edit_inner(&mut p, seq, |t| {
            t.tracks.swap(0, 1);
            t.tracks.insert(0, Track::new(cid(555), TrackKind::Video));
        });
        let g = group_clip(&p, 0, seq);
        p.ungroup(g.id, cid(50), &mut ids).unwrap();
        assert_eq!(*outer_of(&p), outer);
    }

    #[test]
    fn ungrouping_one_unlinked_side_clears_dangling_links() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let seq = p.group(&[cid(3)], cid(50), &mut ids).unwrap();
        let i = p.timelines.iter().position(|t| t.id == cid(50)).unwrap();
        for t in 0..p.timelines[i].tracks.len() {
            let clips: Vec<Clip> = p.timelines[i].tracks[t].clips().to_vec();
            for mut c in clips.into_iter().filter(|c| c.sequence == Some(seq)) {
                c.link = None;
                p.timelines[i].tracks[t].replace(c);
            }
        }
        let gv = group_clip(&p, 1, seq);
        p.ungroup(gv.id, cid(50), &mut ids).unwrap();
        let back = outer_of(&p);
        assert_eq!(back.tracks[1].clips().iter().find(|c| c.id == cid(3)).unwrap().link, None);
        assert_eq!(back.tracks[3].clips()[0].sequence, Some(seq)); // the audio side is still a group
        assert!(p.timeline(seq).is_some());
    }

    #[test]
    fn groups_are_not_sequences_to_pick() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let seq = p.group(&[cid(5)], cid(50), &mut ids).unwrap();
        assert_eq!(p.timelines.len(), 2);
        assert_eq!(p.pickable_timelines_vec().iter().map(|t| t.id).collect::<Vec<_>>(), vec![cid(50)]);
        assert!(!p.pickable_timelines().any(|t| t.id == seq));
    }

    #[test]
    fn pruning_drops_groups_nothing_plays() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let seq = p.group(&[cid(5)], cid(50), &mut ids).unwrap();
        let i = p.timelines.iter().position(|t| t.id == cid(50)).unwrap();
        let played: Vec<Id> = p.timelines[i].tracks[2].clips().iter().map(|c| c.id).collect();
        for c in played {
            p.timelines[i].tracks[2].remove(c);
        }
        let mut kept = fixture().0;
        let kept_seq = kept.group(&[cid(5)], cid(50), &mut ids).unwrap();
        kept.prune_unused_groups();
        assert!(kept.timeline(kept_seq).is_some());
        p.prune_unused_groups();
        assert!(p.timeline(seq).is_none());
        assert_eq!(p.timelines.iter().map(|t| t.id).collect::<Vec<_>>(), vec![cid(50)]);
    }

    #[test]
    fn unnest_replaces_a_nest_by_its_content_and_keeps_the_sequence() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let seq = p.nest(&[cid(5)], cid(50), None, &mut ids).unwrap();
        let n = group_clip(&p, 2, seq);
        let back = p.unnest(n.id, cid(50), &mut ids).unwrap();
        assert_eq!(back.len(), 1);
        let o = outer_of(&p);
        assert!(!o.tracks.iter().flat_map(|t| t.clips()).any(|c| c.sequence == Some(seq)));
        let c = o.tracks.iter().flat_map(|t| t.clips()).find(|c| c.id == back[0]).unwrap();
        assert!(c.start == s(10) && c.media == pic());
        assert!(p.timeline(seq).is_some());
    }

    #[test]
    fn unnest_refuses_a_group() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let g = p.group(&[cid(1)], cid(50), &mut ids).unwrap();
        let gc = group_clip(&p, 0, g);
        assert_eq!(p.unnest(gc.id, cid(50), &mut ids), Err(EditError::NotNested));
    }

    #[test]
    fn unnest_of_a_trimmed_nest_shows_only_what_played() {
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let seq = p.nest(&[cid(1), cid(2)], cid(50), None, &mut ids).unwrap();
        let n = edit_group(&mut p, 0, seq, |n| n.source = TimeRange::from_end(s(1), s(4)));
        p.unnest(n.id, cid(50), &mut ids).unwrap();
        let clips = outer_of(&p).tracks[0].clips();
        assert_eq!(clips.first().map(|c| c.start), Some(n.start));
        assert!(clips.last().unwrap().timeline().end() <= n.timeline().end());
    }

    #[test]
    fn unnest_maps_picture_masks_to_the_outer_tracks_and_drops_unplaced_ones() {
        use sq_core_model::{ClipMask, MaskPath, MaskShapeKind};
        let (mut p, _) = fixture();
        let mut ids = fresh();
        let seq = p.nest(&[cid(3), cid(5)], cid(50), None, &mut ids).unwrap();
        let mut inner_ids: Vec<Id> = Vec::new();
        edit_inner(&mut p, seq, |t| {
            inner_ids = t.tracks.iter().map(|x| x.id).collect();
            let extra = Track::new(cid(556), TrackKind::Video);
            t.tracks.push(extra);
            inner_ids.push(cid(556));
            let mut e = t.tracks[1].clips()[0].clone();
            let picture = |id: u128, track: Id| {
                let mut m = ClipMask::new(cid(id), "m", MaskShapeKind::Bezier, MaskPath { vertices: vec![] });
                m.set_source(MaskSource::Picture);
                m.picture_track = Some(track);
                m
            };
            e.mask_store = Some(vec![picture(601, inner_ids[0]), picture(602, cid(556))]);
            t.tracks[1].replace(e);
        });
        let n = outer_of(&p)
            .tracks
            .iter()
            .flat_map(|t| t.clips())
            .find(|c| c.sequence == Some(seq) && c.kind == TrackKind::Video)
            .unwrap()
            .clone();
        let back = p.unnest(n.id, cid(50), &mut ids).unwrap();
        let o = outer_of(&p);
        let with_mask = o
            .tracks
            .iter()
            .flat_map(|t| t.clips())
            .find(|c| back.contains(&c.id) && c.mask_store.as_ref().is_some_and(|m| !m.is_empty()))
            .unwrap();
        let matte = o
            .tracks
            .iter()
            .find(|t| {
                t.clips().iter().any(|c| back.contains(&c.id) && c.mask_store.is_none() && c.kind == TrackKind::Video)
            })
            .unwrap();
        let masks = with_mask.mask_store.as_ref().unwrap();
        assert_eq!(masks[0].picture_track, Some(matte.id));
        assert!(!inner_ids.contains(&masks[0].picture_track.unwrap()));
        assert_eq!(masks[1].picture_track, None);
    }
}
