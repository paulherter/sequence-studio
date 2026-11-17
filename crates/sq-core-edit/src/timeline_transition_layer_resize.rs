// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TransitionLayer.swift (`Timeline.resizeTransitionLayer`)

use crate::timeline_edits::TimelineEditsExt as _;
use sq_core_effects::transition_layer::ClipTransitionLayer as _;
use sq_core_model::{Clip, ClipEdge, EditError, Timeline, floored_to_frame};
use sq_core_time::{Id, Time};

/// Resizing a transition layer clip by its edges.
pub trait TimelineTransitionLayerResizeExt {
    /// Moves one edge of transition layer `id` by `delta` (positive = right, whole frames). `symmetric` (the plain drag):
    /// the other edge moves the opposite way by the same amount, so the cut keeps its place and both parts change alike;
    /// otherwise (Option) only this edge moves. Neither edge passes the cut, at least one frame stays, and neighbors on
    /// the track and the timeline start stop the drag. Returns how far the dragged edge moved.
    fn resize_transition_layer(
        &mut self,
        id: Id,
        edge: ClipEdge,
        delta: Time,
        symmetric: bool,
    ) -> Result<Time, EditError>;
}

/// Room on the clip's own track before its start and after its end (`None` = unbounded after).
fn room_around(tl: &Timeline, c: &Clip, track: usize) -> (Time, Option<Time>) {
    let others = || tl.tracks[track].clips().iter().filter(|o| o.id != c.id);
    let prev_end =
        others().filter(|o| o.timeline().end() <= c.start).map(|o| o.timeline().end()).max().unwrap_or(Time::ZERO);
    let next = others().filter(|o| o.start >= c.timeline().end()).map(|o| o.start).min();
    (c.start - prev_end, next.map(|n| n - c.timeline().end()))
}

impl TimelineTransitionLayerResizeExt for Timeline {
    fn resize_transition_layer(
        &mut self,
        id: Id,
        edge: ClipEdge,
        delta: Time,
        symmetric: bool,
    ) -> Result<Time, EditError> {
        let m = self.find(id).ok_or(EditError::ClipNotFound)?;
        if m.clip.transition_layer().is_none() {
            return Err(EditError::ClipNotFound);
        }
        if self.tracks[m.track].is_locked {
            return Err(EditError::TrackLocked);
        }
        let fd = self.frame_duration();
        let r = m.clip.resolved_transition_layer(fd).ok_or(EditError::ClipNotFound)?;
        let (room_before, room_after) = room_around(self, &m.clip, m.track);
        let head = edge == ClipEdge::Head;
        // Growth of the dragged part (positive = longer) and how far it may go.
        let mut g = (if head { Time::ZERO - delta } else { delta }).snapped(fd);
        let (own, other) = if head { (r.before, r.after) } else { (r.after, r.before) };
        let room_on = |head: bool| if head { Some(room_before) } else { room_after };
        let other_edge = if head { ClipEdge::Tail } else { ClipEdge::Head };
        if g > Time::ZERO {
            if let Some(x) = room_on(head) {
                g = g.min(x);
            }
            if symmetric && let Some(x) = room_on(!head) {
                g = g.min(x);
            }
        } else if g < Time::ZERO {
            let mut shrink = own;
            if symmetric {
                shrink = shrink.min(other);
            }
            // At least one frame stays.
            let total = r.span.duration;
            let keep = if symmetric { floored_to_frame(Time::scaled_int(total - fd, 1, 2), fd) } else { total - fd };
            shrink = shrink.min(keep.max(Time::ZERO));
            g = g.max(Time::ZERO - shrink);
        }
        if g == Time::ZERO {
            return Ok(Time::ZERO);
        }
        // Trim each edge (head + = shorter, tail + = longer). A head trim moves the generator's source start with it, so the
        // stored cut keeps its timeline place.
        let signed = |head: bool| if head { Time::ZERO - g } else { g };
        self.trim(id, edge, signed(head))?;
        if symmetric {
            self.trim(id, other_edge, signed(!head))?;
        }
        Ok(signed(head))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::timeline_edits::fixtures::FreshIds;
    use sq_core_effects::transition_layer::ProjectTransitionLayer as _;
    use sq_core_model::TransitionKind;
    use sq_core_model::project_media_ops::GeneratorPlacement;
    use sq_core_model::{Project, SequenceFormat, Track, TrackKind};
    use sq_core_time::TimeRange;

    const TL: Id = Id::from_u128(700);

    fn fd() -> Time {
        Time::new(1, 30)
    }

    fn f(n: i64) -> Time {
        fd() * n
    }

    fn range(a: i64, n: i64) -> TimeRange {
        TimeRange::new(f(a), f(n))
    }

    fn track_id(i: u128) -> Id {
        Id::from_u128(800 + i)
    }

    fn project() -> Project {
        let tracks: Vec<Track> =
            (0..5).map(|i| Track::new(track_id(i), if i < 4 { TrackKind::Video } else { TrackKind::Audio })).collect();
        Project::new(Id::from_u128(1), "P", Vec::new(), vec![Timeline::new(TL, "T", SequenceFormat::new(fd()), tracks)])
    }

    fn at(track: u128, start: i64, frames: i64) -> GeneratorPlacement {
        GeneratorPlacement { timeline: TL, track: track_id(track), start: f(start), duration: f(frames) }
    }

    fn layer(p: &Project, id: Id) -> Clip {
        p.timeline(TL).unwrap().find(id).unwrap().clip
    }

    fn media(n: u128, start: i64, frames: i64, source_start: i64) -> Clip {
        Clip::new(
            Id::from_u128(n),
            "m",
            Id::from_u128(1000 + n),
            TrackKind::Video,
            range(source_start, frames),
            f(start),
        )
    }

    /// A on V1 0..30, B on V1 30..60, a b-roll on V2 over the whole range, a layer on V3 at frames 20..40 (cut 30).
    fn stack() -> (Project, Id) {
        let mut p = project();
        let mut ids = FreshIds;
        p.edit(TL, |t| {
            t.tracks[0].overwrite(media(1, 0, 30, 0), &mut ids)?;
            t.tracks[0].overwrite(media(2, 30, 30, 100), &mut ids)?;
            t.tracks[1].overwrite(media(3, 0, 60, 0), &mut ids)
        })
        .unwrap();
        let id = p.add_transition_layer(TransitionKind::CrossDissolve, at(2, 20, 20), &mut FreshIds).unwrap();
        (p, id)
    }

    fn resize(p: &mut Project, id: Id, edge: ClipEdge, by: Time, symmetric: bool) -> Time {
        let mut moved = Time::ZERO;
        p.edit(TL, |t| {
            moved = t.resize_transition_layer(id, edge, by, symmetric)?;
            Ok(())
        })
        .unwrap();
        moved
    }

    #[test]
    fn symmetric_resize_keeps_the_cut_and_changes_both_parts_alike() {
        let (mut p, id) = stack();
        assert_eq!(resize(&mut p, id, ClipEdge::Head, Time::ZERO - f(4), true), Time::ZERO - f(4));
        assert_eq!(layer(&p, id).timeline(), range(16, 28));
        assert_eq!(layer(&p, id).transition_layer_cut(), Some(f(30)));
        assert_eq!(resize(&mut p, id, ClipEdge::Tail, Time::ZERO - f(6), true), Time::ZERO - f(6));
        assert_eq!(layer(&p, id).timeline(), range(22, 16));
        // Shrinking stops at the cut on the shorter side.
        assert_eq!(resize(&mut p, id, ClipEdge::Head, f(50), true), f(7));
        assert_eq!(layer(&p, id).timeline(), range(29, 2));
    }

    #[test]
    fn symmetric_growth_stops_at_neighbours_on_either_side() {
        let (mut p, id) = stack();
        let blocker = media(9, 42, 5, 0);
        p.edit(TL, |t| t.tracks[2].overwrite(blocker, &mut FreshIds)).unwrap();
        assert_eq!(resize(&mut p, id, ClipEdge::Head, Time::ZERO - f(10), true), Time::ZERO - f(2));
        assert_eq!(layer(&p, id).timeline(), range(18, 24));
        // Timeline start limits the other way.
        let mut q = project();
        let id2 = q.add_transition_layer(TransitionKind::CrossDissolve, at(0, 3, 10), &mut FreshIds).unwrap();
        assert_eq!(resize(&mut q, id2, ClipEdge::Tail, f(9), true), f(3));
        assert_eq!(layer(&q, id2).timeline(), range(0, 16));
    }

    #[test]
    fn free_resize_moves_one_edge_but_never_past_the_cut() {
        let (mut p, id) = stack();
        assert_eq!(resize(&mut p, id, ClipEdge::Tail, f(6), false), f(6));
        assert_eq!(layer(&p, id).timeline(), range(20, 26));
        assert_eq!(layer(&p, id).transition_layer_cut(), Some(f(30)));
        assert_eq!(resize(&mut p, id, ClipEdge::Head, f(40), false), f(10));
        assert_eq!(layer(&p, id).timeline(), range(30, 16));
        // One frame always stays.
        assert_eq!(resize(&mut p, id, ClipEdge::Tail, Time::ZERO - f(40), false), Time::ZERO - f(15));
        assert_eq!(layer(&p, id).timeline(), range(30, 1));
    }
}
