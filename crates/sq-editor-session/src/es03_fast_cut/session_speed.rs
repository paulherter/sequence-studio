//! Speed/Duration, Reverse, Time Remapping (speed band edits, keys, ramps), speed points and speed presets on the session.
//! Every command is one undo step.

use std::collections::BTreeMap;

use sq_core_edit::timeline_cut_to_beats::TimelineCutToBeatsExt;
use sq_core_edit::timeline_magnetic_moves::MagneticGesturesExt;
use sq_core_edit::timeline_magnetic_ops::MagneticOpsExt;
use sq_core_edit::timeline_solo::SoloExt;
use sq_core_edit::timeline_speed::{SpeedChange, TimelineSpeedExt};
use sq_core_effects::speed_ramp_preset::SpeedRampPreset;
use sq_core_model::{Clip, ClipSpeed, EaseShape, SpeedKeys, Timeline, TrackKind};
use sq_core_time::{EaseSide, EasingCurve, Id, Time};

use super::clip_in;
use super::speed_band::SpeedBand;
use super::speed_dialog::SpeedDialogModel;
use super::speed_edit::{SpeedBandKeyHit, SpeedEdit, SpeedEditPhase};
use crate::EditorSession;

/// What `apply_speed_preset` did.
// Swift: EditorSession+SpeedPresets.swift:6
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpeedPresetOutcome {
    Applied {
        clips: usize,
    },
    NoClip,
    /// Hit on Beat found no beat marker inside the clips.
    NoBeat,
}

impl EditorSession {
    /// Current duration of each sequence of the project (nested clips derive their length limit from it at edit time).
    fn nested_durations(&self) -> BTreeMap<Id, Time> {
        self.project().timelines.iter().map(|t| (t.id, t.duration())).collect()
    }

    /// Selected clips that can be retimed (media clips and nested sequences; not titles or stills), in track order.
    // Swift: EditorSession+Speed.swift:12
    pub fn retimable_selection(&self) -> Vec<Clip> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        t.tracks
            .iter()
            .flat_map(|tr| tr.clips())
            .filter(|c| self.selection.contains(&c.id) && Timeline::can_retime(c))
            .cloned()
            .collect()
    }

    /// Speed/Duration is available for this selection.
    // Swift: EditorSession+Speed.swift:18
    pub fn can_set_speed(&self) -> bool {
        !self.retimable_selection().is_empty()
    }

    /// Model for the Speed/Duration dialog; `None` without a retimable selection.
    // Swift: EditorSession+Speed.swift:21
    pub fn speed_dialog_model(&self) -> Option<SpeedDialogModel> {
        let fd = self.active_timeline()?.frame_duration();
        SpeedDialogModel::new(&self.retimable_selection(), fd)
    }

    /// The edit of Speed/Duration and Reverse: Fast Cut ripples V1 whatever the Ripple setting, Normal acts on the
    /// selected clips only.
    fn retime_selected(&mut self, name: &str, key: Option<&str>, change: SpeedChange) -> bool {
        let ids: Vec<Id> = self.retimable_selection().iter().map(|c| c.id).collect();
        if ids.is_empty() {
            return false;
        }
        let inner = self.nested_durations();
        let only = self.selection.clone();
        let mut caption_limited = false;
        let ok = self.attempt_keyed_ids(name, key, |t, src| {
            t.refresh_nested_durations(|i| inner.get(&i).copied());
            if t.is_fast_cut() {
                t.magnetic_apply(&change, &ids, src)
            } else {
                let ((), limited) = Self::run_noting_caption_limit(t, |tl| {
                    tl.editing_only(&only, src, |tl, _| tl.apply_speed_change_to_all(&change, &ids))
                })?;
                caption_limited = limited;
                Ok(())
            }
        });
        if ok && caption_limited {
            self.set_error(Self::CAPTION_BLOCKED_MESSAGE.to_string());
        }
        ok
    }

    /// Applies a Speed/Duration result to the selected retimable clips (linked partners with them) as ONE undo step.
    // Swift: EditorSession+Speed.swift:28
    pub fn apply_speed(&mut self, change: SpeedChange) -> bool {
        let key = self.speed_gesture_key.clone();
        self.retime_selected("Speed", key.as_deref(), change)
    }

    /// Speed field gesture: the changes between begin and end are one undo step.
    // Swift: EditorSession+Speed.swift:42
    pub fn begin_speed_gesture(&mut self) {
        self.gesture_counter += 1;
        self.speed_gesture_key = Some(format!("speed:{}", self.gesture_counter));
    }

    // Swift: EditorSession+Speed.swift:43
    pub fn end_speed_gesture(&mut self) {
        self.speed_gesture_key = None;
    }

    /// Clip > Reverse Clip: the first clip decides the direction, so a mixed selection ends uniform.
    // Swift: EditorSession+Speed.swift:48
    pub fn toggle_reverse_selection(&mut self) -> bool {
        let Some(first) = self.retimable_selection().into_iter().next() else { return false };
        self.set_reversed(!first.reversed)
    }

    /// Reverse Clip is available for this selection.
    // Swift: EditorSession+Speed.swift:55
    pub fn can_reverse_selection(&self) -> bool {
        self.can_set_speed()
    }

    /// Reverse Speed on or off for the selected clips (no dialog).
    // Swift: EditorSession+Speed.swift:58
    pub fn set_reversed(&mut self, reversed: bool) -> bool {
        let change = SpeedChange { reversed: Some(reversed), ..SpeedChange::default() };
        self.retime_selected("Reverse Speed", None, change)
    }

    // MARK: Time Remapping

    /// Selected video clips that can show the speed band.
    // Swift: EditorSession+SpeedBand.swift:7
    pub fn remappable_selection(&self) -> Vec<Clip> {
        self.retimable_selection().into_iter().filter(|c| c.kind == TrackKind::Video).collect()
    }

    // Swift: EditorSession+SpeedBand.swift:10
    pub fn can_toggle_time_remapping(&self) -> bool {
        !self.remappable_selection().is_empty()
    }

    // Swift: EditorSession+SpeedBand.swift:12
    pub fn can_remove_time_remapping(&self) -> bool {
        self.retimable_selection().iter().any(|c| c.speed_keys.is_some())
    }

    /// Replaces the speed track of `id` by `edit(keys)`; `None` from `edit` refuses.
    fn edit_keys(
        &mut self,
        name: &str,
        key: Option<&str>,
        id: Id,
        keeping_keys: bool,
        refuse_shortening: bool,
        edit: impl Fn(&SpeedKeys) -> Option<SpeedKeys>,
    ) -> bool {
        self.attempt_keyed_ids(name, key, |t, src| {
            t.magnetic_edit_speed_keys(id, keeping_keys, refuse_shortening, edit, src).map(|_| ())
        })
    }

    /// A drag on the speed band: every `Changed` replaces the clip's speed track (computed from the track at mouse-down,
    /// so it is idempotent); all changes of one drag are one undo step.
    // Swift: EditorSession+SpeedBand.swift:16
    pub fn apply_speed_edit(&mut self, e: &SpeedEdit) {
        match e.phase {
            SpeedEditPhase::Began => self.gesture_counter += 1,
            SpeedEditPhase::Changed => {
                let key = format!("remap:{}:{}", e.clip, self.gesture_counter);
                self.edit_keys("Speed Ramp", Some(&key), e.clip, e.keeping_keys, false, |_| Some(e.keys.clone()));
            }
            SpeedEditPhase::Ended => {}
        }
    }

    /// Esc during a speed band drag: the sequence goes back to `original` (its state at `Began`), which drops the drag's
    /// undo step (the coalesced step returns to its start); the gesture ends.
    // Swift: EditorSession+SpeedBand.swift:27
    pub fn cancel_speed_edit(&mut self, clip: Id, original: Timeline) {
        let key = format!("remap:{}:{}", clip, self.gesture_counter);
        self.attempt_keyed_ids("Speed Ramp", Some(&key), |t, _| {
            *t = original;
            Ok(())
        });
        self.end_gesture();
    }

    /// Delete on a key or a transition of the band.
    // Swift: EditorSession+SpeedBand.swift:33
    pub fn delete_speed_key(&mut self, clip: Id, hit: SpeedBandKeyHit) -> bool {
        let Some(fd) = self.active_timeline().map(Timeline::frame_duration) else { return false };
        self.edit_keys(hit.title(), None, clip, false, false, |k| SpeedBand::deleting(hit.band(), k, fd))
    }

    /// Effect Controls diamond: a speed key at clip-local `local` holding the speed evaluated there (nothing plays
    /// differently). False on a frame that already is a key or outside the clip.
    // Swift: EditorSession+SpeedBand.swift:42
    pub fn add_speed_key(&mut self, id: Id, local: Time) -> bool {
        let Some(tl) = self.active_timeline() else { return false };
        let Some(c) = clip_in(tl, id) else { return false };
        let fd = tl.frame_duration();
        if SpeedKeys::of(c).adding_key(local, fd).is_none() {
            return false;
        }
        self.edit_keys("Add Speed Keyframe", None, id, true, false, |k| k.adding_key(local, fd).map(|(k, _)| k))
    }

    /// Effect Controls Speed field on a keyed clip: the speed at clip-local `local` becomes `v` (a key is added there
    /// when the frame has none). The changes of one field gesture (`begin_speed_gesture`) are one undo step. A value
    /// whose source would run past the media (or below 0) is refused (false): the clip never silently shortens.
    // Swift: EditorSession+SpeedBand.swift:55
    pub fn set_speed_key_value(&mut self, id: Id, local: Time, v: ClipSpeed) -> bool {
        let Some(tl) = self.active_timeline() else { return false };
        if clip_in(tl, id).is_none() {
            return false;
        }
        let fd = tl.frame_duration();
        let key = self.speed_gesture_key.clone();
        self.edit_keys("Speed", key.as_deref(), id, true, true, |k| k.setting_key_speed(local, v, fd))
    }

    /// Segment index of the speed transition the Speed row edits at clip-local `local`: the ramp under the playhead,
    /// else the next one, else the previous one. `None` without any ramp.
    // Swift: EditorSession+SpeedBand.swift:66
    pub fn speed_transition_segment(&self, id: Id, local: Time) -> Option<usize> {
        let k = clip_in(self.active_timeline()?, id)?.speed_keys.as_ref()?;
        let starts = k.boundaries();
        let ramps: Vec<usize> = (0..k.segments.len()).filter(|&i| k.segments[i].is_ramp()).collect();
        if let Some(under) = ramps.iter().find(|&&i| starts[i] <= local && local < starts[i + 1]) {
            return Some(*under);
        }
        ramps.iter().find(|&&i| starts[i] >= local).or(ramps.last()).copied()
    }

    /// Effect Controls diamond on a key: removes the key at `boundary` (segments merge to their average speed).
    // Swift: EditorSession+SpeedBand.swift:75
    pub fn remove_speed_key(&mut self, id: Id, boundary: usize) -> bool {
        let Some(k) = self.active_timeline().and_then(|t| clip_in(t, id)).and_then(|c| c.speed_keys.as_ref()) else {
            return false;
        };
        if k.removing_key(boundary).is_none() {
            return false;
        }
        self.edit_keys("Remove Speed Keyframe", None, id, false, false, |k| k.removing_key(boundary))
    }

    /// The speed curve of ramp `segment` of a remapped clip (linear for a straight ramp); `None` when that is no ramp.
    // Swift: EditorSession+SpeedBand.swift:83
    pub fn speed_ramp_ease(&self, id: Id, segment: usize) -> Option<EaseShape> {
        let k = clip_in(self.active_timeline()?, id)?.speed_keys.as_ref()?;
        k.segments.get(segment).filter(|s| s.is_ramp())?;
        Some(k.ease_of_segment(segment))
    }

    /// Sets the Bezier curve of a speed transition (the curve popover). The clip keeps its length; linked audio follows.
    /// Calls with `continues_gesture` coalesce with the previous one. An unchanged curve (or no ramp at `segment`)
    /// records nothing and returns false.
    // Swift: EditorSession+SpeedBand.swift:93
    pub fn set_speed_ramp_ease(&mut self, shape: &EaseShape, id: Id, segment: usize, continues_gesture: bool) -> bool {
        let Some(k) = self.active_timeline().and_then(|t| clip_in(t, id)).and_then(|c| c.speed_keys.as_ref()) else {
            return false;
        };
        match k.setting_ease(shape, segment) {
            Some(edited) if edited != *k => {}
            _ => return false,
        }
        if !continues_gesture {
            self.gesture_counter += 1;
        }
        let key = format!("remapEase:{id}:{segment}:{}", self.gesture_counter);
        self.edit_keys("Speed Transition Curve", Some(&key), id, false, false, |k| k.setting_ease(shape, segment))
    }

    /// Clip > Remove Speed Ramp: the selected remapped clips play at 100 % over the source they used (the clip length
    /// follows).
    // Swift: EditorSession+SpeedBand.swift:104
    pub fn remove_time_remapping(&mut self) -> bool {
        let ids: Vec<Id> = self.retimable_selection().iter().filter(|c| c.speed_keys.is_some()).map(|c| c.id).collect();
        if ids.is_empty() {
            return false;
        }
        self.attempt_keyed_ids("Remove Speed Ramp", None, |t, src| {
            for id in &ids {
                if clip_in(t, *id).is_some_and(|c| c.speed_keys.is_some()) {
                    t.magnetic_edit_speed_keys(
                        *id,
                        false,
                        false,
                        |k| {
                            let h = k.hull();
                            Some(SpeedKeys::constant(ClipSpeed::NORMAL, false, h.duration, h.start))
                        },
                        src,
                    )?;
                }
            }
            Ok(())
        })
    }

    // MARK: Speed points

    /// The selected video clip the playhead is strictly inside (a point at an edge changes nothing), with the local time.
    fn speed_point_target(&self) -> Option<(Clip, Time)> {
        let ph = self.playhead;
        let c = self.remappable_selection().into_iter().find(|c| c.start < ph && ph < c.timeline().end())?;
        let local = ph - c.start;
        Some((c, local))
    }

    /// Add Speed Point is available: a selected video clip under the playhead that has no point on that frame.
    // Swift: EditorSession+SpeedPoints.swift:15
    pub fn can_add_speed_point(&self) -> bool {
        let (Some((c, local)), Some(t)) = (self.speed_point_target(), self.active_timeline()) else { return false };
        SpeedKeys::of(&c).adding_key(local, t.frame_duration()).is_some()
    }

    /// Adds a point that changes nothing at the playhead of the selected clip (the Effect Controls diamond's key).
    // Swift: EditorSession+SpeedPoints.swift:22
    pub fn add_speed_point_at_playhead(&mut self) -> bool {
        let Some((c, local)) = self.speed_point_target() else { return false };
        self.add_speed_key(c.id, local)
    }

    /// Easy Ease / Ease In / Ease Out on the speed point (or transition) at the playhead of the selected clip. A plain
    /// point between two speeds opens a short transition first. False when the playhead is not on a point or transition
    /// that changes speed.
    // Swift: EditorSession+SpeedPoints.swift:31
    pub fn ease_speed_point_at_playhead(&mut self, curve: &EasingCurve, side: EaseSide) -> bool {
        let (Some((c, local)), Some(fd)) =
            (self.speed_point_target(), self.active_timeline().map(Timeline::frame_duration))
        else {
            return false;
        };
        if SpeedKeys::of(&c).easing_point(local, curve, side, fd).is_none() {
            return false;
        }
        self.edit_keys("Speed Transition Curve", None, c.id, true, false, |k| k.easing_point(local, curve, side, fd))
    }

    /// True when the playhead sits on a speed point or transition of the selected clip that easing can act on.
    // Swift: EditorSession+SpeedPoints.swift:42
    pub fn speed_point_accepts_ease(&self, curve: &EasingCurve, side: EaseSide) -> bool {
        let (Some((c, local)), Some(t)) = (self.speed_point_target(), self.active_timeline()) else { return false };
        SpeedKeys::of(&c).easing_point(local, curve, side, t.frame_duration()).is_some()
    }

    // MARK: Presets and beats

    // Swift: EditorSession+SpeedPresets.swift:12
    pub fn has_beat_markers(&self) -> bool {
        self.active_timeline().is_some_and(|t| !t.beat_times().is_empty())
    }

    /// Why Cut to Beats / Snap to Beats cannot run now (the menu row's help line and the status line); `None` when they can.
    pub fn beat_edit_problem(&self) -> Option<&'static str> {
        if !self.has_beat_markers() {
            Some("Run Markers on Beat on the music first.")
        } else if self.selection.is_empty() {
            Some("Select the clips to edit first.")
        } else {
            None
        }
    }

    /// Applies `preset` to every selected video clip (the clip keeps its source range; its length follows the speeds).
    /// `on_beat`: the peak goes onto the beat marker nearest the clip's middle (clips without a beat inside are skipped).
    // Swift: EditorSession+SpeedPresets.swift:17
    pub fn apply_speed_preset(&mut self, preset: SpeedRampPreset, on_beat: bool) -> SpeedPresetOutcome {
        let Some(tl) = self.active_timeline() else { return SpeedPresetOutcome::NoClip };
        let clips = self.remappable_selection();
        if clips.is_empty() {
            return SpeedPresetOutcome::NoClip;
        }
        let fd = tl.frame_duration();
        let beats = tl.beat_times();
        let mut plan: Vec<(Id, SpeedKeys)> = Vec::new();
        for c in &clips {
            let base = SpeedKeys::of(c);
            let mut peak = None;
            if on_beat {
                let end = c.timeline().end();
                let mid2 = c.start + end; // twice the middle
                let nearest = beats
                    .iter()
                    .copied()
                    .filter(|b| *b > c.start + fd && *b < end - fd)
                    .min_by_key(|b| gap(*b + *b, mid2));
                let Some(beat) = nearest else { continue };
                peak = Some(beat - c.start);
            }
            plan.push((c.id, preset.keys(&base, fd, peak)));
        }
        if plan.is_empty() {
            return SpeedPresetOutcome::NoBeat;
        }
        let name = if on_beat {
            format!("{} Speed Ramp on Beat", preset.title())
        } else {
            format!("{} Speed Ramp", preset.title())
        };
        let mut done = 0;
        self.attempt_keyed_ids(&name, None, |t, src| {
            done = 0;
            for (id, keys) in &plan {
                if clip_in(t, *id).is_some() {
                    t.magnetic_edit_speed_keys(*id, true, false, |_| Some(keys.clone()), src)?;
                    done += 1;
                }
            }
            Ok(())
        });
        if done > 0 { SpeedPresetOutcome::Applied { clips: done } } else { SpeedPresetOutcome::NoClip }
    }

    /// Clip > Cut to Beats: cuts the selected clips (with their linked partners) at every beat marker inside them.
    /// Returns the number of cuts, or `None` when the edit was refused.
    // Swift: EditorSession+SpeedPresets.swift:53
    pub fn cut_to_beats(&mut self) -> Option<usize> {
        let ids = self.selection.clone();
        let mut n = 0;
        let ok = self.attempt_keyed_ids("Cut to Beats", None, |t, src| {
            n = t.cut_to_beats(&ids, src)?;
            Ok(())
        });
        if ok || n == 0 { Some(n) } else { None }
    }

    /// Clip > Snap to Beats: each selected clip's end moves to the nearest beat marker (ripple).
    // Swift: EditorSession+SpeedPresets.swift:62
    pub fn snap_to_beats(&mut self) -> Option<usize> {
        let ids: Vec<Id> = self.selection.iter().copied().collect();
        let mut n = 0;
        let ok = self.attempt_keyed_ids("Snap to Beats", None, |t, src| {
            n = t.snap_to_beats(&ids, src)?;
            Ok(())
        });
        if ok || n == 0 { Some(n) } else { None }
    }
}

fn gap(a: Time, b: Time) -> Time {
    if a > b { a - b } else { b - a }
}
