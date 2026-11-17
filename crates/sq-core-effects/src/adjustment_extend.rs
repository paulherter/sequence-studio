// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AdjustmentExtend.swift (`containsExtendedAdjustments` lives in sq-core-file)
//! "Extend to sequence end": an Adjustment Layer that follows the end of the cut, so a grade that lives on one layer keeps
//! covering the sequence as it grows or shrinks. The editor session applies it after every edit
//! (`extend_adjustment_layers_to_sequence_end`), inside the same undo step as the edit.

use crate::adjustment_clip::ClipAdjustmentExt;
use sq_core_model::{Clip, Project, Timeline};
use sq_core_time::{Id, Time};

/// Swift `extension Clip` in AdjustmentExtend.swift.
pub trait ClipExtendExt {
    /// Only meaningful on Adjustment Layers.
    fn extends_to_sequence_end(&self) -> bool;
    /// Sets the flag (stored only when on).
    fn set_extends_to_sequence_end(&mut self, on: bool);
}

impl ClipExtendExt for Clip {
    fn extends_to_sequence_end(&self) -> bool {
        self.extends_to_end_store == Some(true)
    }

    fn set_extends_to_sequence_end(&mut self, on: bool) {
        self.extends_to_end_store = on.then_some(true);
    }
}

/// The plain tail trim of the edit crate (`Timeline::trim(id, .tail, by)`), errors ignored. Passed in because the edit logic
/// sits above this crate.
pub type TailTrim<'a> = &'a mut dyn FnMut(&mut Timeline, Id, Time);

/// Swift `extension Project` in AdjustmentExtend.swift.
pub trait ProjectAdjustmentExtendExt {
    /// Switches the flag (Adjustment Layers only; any other clip is left alone) and applies it right away.
    fn set_extend_to_sequence_end(&mut self, on: bool, clip: Id, trim_tail: TailTrim<'_>);
    /// Trims the tail of every flagged Adjustment Layer to the end of the rest of its sequence (the latest end of any clip
    /// that is not itself a flagged layer). Growing stops at the next clip on the layer's track; a locked track, a sequence
    /// with nothing else in it, or an end at or before the layer's start leaves the layer as it is.
    fn extend_adjustment_layers_to_sequence_end(&mut self, trim_tail: TailTrim<'_>);
}

impl ProjectAdjustmentExtendExt for Project {
    fn set_extend_to_sequence_end(&mut self, on: bool, clip: Id, trim_tail: TailTrim<'_>) {
        let mut found = false;
        for t in self.timelines.iter_mut().flat_map(|tl| tl.tracks.iter_mut()) {
            if t.clips().iter().any(|c| c.id == clip && c.is_adjustment()) {
                t.map_clips_keeping_timing(|c| {
                    let mut c = c.clone();
                    if c.id == clip && c.is_adjustment() {
                        c.set_extends_to_sequence_end(on);
                        found = true;
                    }
                    c
                });
            }
        }
        if found {
            self.extend_adjustment_layers_to_sequence_end(trim_tail);
        }
    }

    fn extend_adjustment_layers_to_sequence_end(&mut self, trim_tail: TailTrim<'_>) {
        for tl in self.timelines.iter_mut() {
            if !tl.tracks.iter().any(|t| t.clips().iter().any(|c| c.extends_to_sequence_end())) {
                continue;
            }
            let clips: Vec<Clip> = tl.tracks.iter().flat_map(|t| t.clips().iter().cloned()).collect();
            let Some(target) = clips.iter().filter(|c| !c.extends_to_sequence_end()).map(|c| c.timeline().end()).max()
            else {
                continue;
            };
            for layer in clips.iter().filter(|c| c.extends_to_sequence_end() && c.is_adjustment()) {
                if target <= layer.start || layer.timeline().end() == target {
                    continue;
                }
                trim_tail(tl, layer.id, target - layer.timeline().end());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adjustment_clip::ProjectAdjustmentExt;
    use sq_core_model::{SequenceFormat, Track, TrackKind};
    use sq_core_time::{IdSource, SequentialIds, TimeRange};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    /// Stand-in for `Timeline::trim`: moves the tail, growing at most up to the next clip on the layer's track.
    fn trim(tl: &mut Timeline, id: Id, by: Time) {
        let Some(m) = tl.find(id) else { return };
        let end = m.clip.timeline().end();
        let room = tl.tracks[m.track].clips().iter().filter(|c| c.start >= end).map(|c| c.start - end).min();
        let g = if by < Time::ZERO { by } else { room.map_or(by, |r| r.min(by)) };
        if g != Time::ZERO {
            let mut c = m.clip;
            c.extend_tail(g);
            tl.tracks[m.track].replace(c);
        }
    }

    fn media_clip(ids: &mut SequentialIds, name: &str, dur: i64, start: i64) -> Clip {
        Clip::new(ids.next_id(), name, ids.next_id(), TrackKind::Video, TimeRange::new(Time::ZERO, s(dur)), s(start))
    }

    /// V1 holds a 10 s clip, V2 an adjustment layer 0..4 s with the flag.
    fn project(ids: &mut SequentialIds, flag: bool) -> (Project, Id, Id, Id, Id, Id) {
        let mut v1 = Track::new(ids.next_id(), TrackKind::Video);
        let v2 = Track::new(ids.next_id(), TrackKind::Video);
        let base = media_clip(ids, "A", 10, 0);
        let base_id = base.id;
        assert!(v1.overwrite(base, ids).is_ok());
        let (v1_id, v2_id) = (v1.id, v2.id);
        let t = Timeline::new(ids.next_id(), "T", SequenceFormat::new(Time::new(1, 30)), vec![v1, v2]);
        let tl = t.id;
        let mut p = Project::new(ids.next_id(), "P", Vec::new(), vec![t]);
        let adj = p.add_adjustment_clip(tl, Time::ZERO, v2_id, s(4), ids).unwrap();
        if flag {
            p.set_extend_to_sequence_end(true, adj, &mut trim);
        }
        (p, tl, v1_id, v2_id, base_id, adj)
    }

    fn clip(p: &Project, id: Id) -> Clip {
        p.timelines
            .iter()
            .flat_map(|t| t.tracks.iter())
            .flat_map(|t| t.clips().iter())
            .find(|c| c.id == id)
            .unwrap()
            .clone()
    }

    fn edit(p: &mut Project, tl: Id, f: impl FnOnce(&mut Timeline)) {
        assert!(
            p.edit(tl, |t| {
                f(t);
                Ok(())
            })
            .is_ok()
        );
    }

    #[test]
    fn flag_only_for_adjustment_layers_and_setting_it_extends_right_away() {
        let mut ids = SequentialIds::default();
        let (mut p, _, _, _, base, adj) = project(&mut ids, false);
        p.set_extend_to_sequence_end(true, base, &mut trim);
        assert!(!clip(&p, base).extends_to_sequence_end());
        p.set_extend_to_sequence_end(true, adj, &mut trim);
        assert!(clip(&p, adj).extends_to_sequence_end());
        assert_eq!(clip(&p, adj).timeline().end(), s(10));
        p.set_extend_to_sequence_end(false, adj, &mut trim);
        assert!(!clip(&p, adj).extends_to_sequence_end());
        assert_eq!(clip(&p, adj).extends_to_end_store, None);
    }

    #[test]
    fn follows_a_growing_and_shrinking_cut() {
        let mut ids = SequentialIds::default();
        let (mut p, tl, v1, _, base, adj) = project(&mut ids, true);
        let extra = media_clip(&mut ids, "B", 5, 10);
        edit(&mut p, tl, |t| {
            let i = t.tracks.iter().position(|x| x.id == v1).unwrap();
            let mut dummy = SequentialIds::default();
            assert!(t.tracks[i].overwrite(extra, &mut dummy).is_ok());
        });
        p.extend_adjustment_layers_to_sequence_end(&mut trim);
        assert_eq!(clip(&p, adj).timeline(), TimeRange::new(Time::ZERO, s(15)));
        edit(&mut p, tl, |t| {
            let i = t.tracks.iter().position(|x| x.id == v1).unwrap();
            let others: Vec<Id> = t.tracks[i].clips().iter().map(|c| c.id).filter(|id| *id != base).collect();
            for id in others {
                t.tracks[i].remove(id);
            }
        });
        p.extend_adjustment_layers_to_sequence_end(&mut trim);
        assert_eq!(clip(&p, adj).timeline().end(), s(10));
    }

    #[test]
    fn unflagged_layer_is_untouched_and_a_layer_alone_does_not_run_away() {
        let mut ids = SequentialIds::default();
        let (mut p, _, _, _, _, adj) = project(&mut ids, false);
        p.extend_adjustment_layers_to_sequence_end(&mut trim);
        assert_eq!(clip(&p, adj).timeline().end(), s(4));

        let (mut p, tl, v1, _, _, adj) = project(&mut ids, true);
        edit(&mut p, tl, |t| {
            let i = t.tracks.iter().position(|x| x.id == v1).unwrap();
            let all: Vec<Id> = t.tracks[i].clips().iter().map(|c| c.id).collect();
            for id in all {
                t.tracks[i].remove(id);
            }
        });
        p.extend_adjustment_layers_to_sequence_end(&mut trim);
        assert_eq!(clip(&p, adj).timeline().end(), s(10));
        p.extend_adjustment_layers_to_sequence_end(&mut trim);
        assert_eq!(clip(&p, adj).timeline().end(), s(10));
    }

    #[test]
    fn stops_at_the_next_clip_on_its_track() {
        let mut ids = SequentialIds::default();
        let (mut p, tl, _, v2, _, adj) = project(&mut ids, false);
        let blocker = media_clip(&mut ids, "T", 2, 7);
        edit(&mut p, tl, |t| {
            let i = t.tracks.iter().position(|x| x.id == v2).unwrap();
            let mut dummy = SequentialIds::default();
            assert!(t.tracks[i].overwrite(blocker, &mut dummy).is_ok());
        });
        p.set_extend_to_sequence_end(true, adj, &mut trim);
        assert_eq!(clip(&p, adj).timeline().end(), s(7));
        let _ = ids.next_id();
    }
}
