// Swift: TransitionLayout.swift
//! Geometry and drag arithmetic of transition boxes on the timeline. Pure: rational time at the edges.

use crate::timeline_geometry::{TimelineGeometry, TrackRow};
use sq_core_effects::transition::{ResolvedTransition, TimelineTransitions, TransitionKindExt, TransitionPoint};
use sq_core_model::{Clip, ClipEdge, Timeline, Track, TransitionAlignment, TransitionKind};
use sq_core_time::{Id, Time};
use sq_uikit::keyframe_graph_geometry::{Point, Rect};

/// Which part of a transition box the pointer is on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum TransitionZone {
    /// The left edge.
    LeftEdge,
    /// The right edge.
    RightEdge,
    /// The middle.
    Body,
}

/// A transition box under the pointer.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TransitionHit {
    /// The transition.
    pub id: Id,
    /// Its track.
    pub track: Id,
    /// The part under the pointer.
    pub zone: TransitionZone,
}

/// Where a dragged transition would land (drag from the Effects panel).
#[derive(Clone, Debug, PartialEq)]
pub struct TransitionDropTarget {
    /// The track.
    pub track: Id,
    /// The cut or clip edge.
    pub point: TransitionPoint,
    /// Alignment around the edit.
    pub alignment: TransitionAlignment,
    /// Highlight box in view coordinates.
    pub rect: Rect,
    /// FB-G element transitions (Move / Zoom / Pop) dropped on the middle of a clip: In and Out. `point` is then the head
    /// and `tail_rect` highlights the tail.
    pub both_ends: bool,
    /// Highlight of the tail when `both_ends`.
    pub tail_rect: Option<Rect>,
}

/// The values a drag produces; apply with `Timeline::set_transition`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TransitionChange {
    /// New duration.
    pub duration: Time,
    /// New alignment.
    pub alignment: TransitionAlignment,
    /// Time before the cut for a custom alignment.
    pub custom_before: Time,
}

/// Geometry and drag arithmetic of transition boxes on the timeline.
pub struct TransitionLayout;

impl TransitionLayout {
    /// Narrowest box.
    pub const MIN_WIDTH: f64 = 6.0;
    /// Widest edge zone.
    pub const MAX_EDGE_WIDTH: f64 = 6.0;
    /// A dragged transition lands on an edit within this distance (points).
    pub const DROP_REACH: f64 = 36.0;
    /// Pointer within this distance of the cut centers the transition.
    pub const DROP_CENTER_ZONE: f64 = 10.0;

    // MARK: Boxes

    /// The box of a resolved transition in its row.
    pub fn rect(r: &ResolvedTransition, row: &TrackRow, geometry: &TimelineGeometry) -> Rect {
        let x0 = geometry.x(r.span.start);
        let x1 = geometry.x(r.span.end());
        Rect::new(x0, row.y + 1.0, (x1 - x0).max(Self::MIN_WIDTH), (row.height - 2.0).max(1.0))
    }

    /// Width of an edge zone for a box of width `w`.
    pub fn edge_width(w: f64) -> f64 {
        2.0_f64.max(Self::MAX_EDGE_WIDTH.min(w / 3.0))
    }

    /// The transition box under `p` (view coordinates), if any. Boxes sit above the clips, so this is asked before the
    /// clip hit test. `cut_slop` defaults to `TimelineGeometry::MAX_TRIM_HANDLE_WIDTH`.
    pub fn hit_test(
        p: Point,
        timeline: &Timeline,
        geometry: &TimelineGeometry,
        cut_slop: f64,
    ) -> Option<TransitionHit> {
        if p.x < TimelineGeometry::CONTENT_ORIGIN_X {
            return None;
        }
        for row in geometry.rows(timeline) {
            if !(p.y >= row.y && p.y < row.max_y()) {
                continue;
            }
            let track = timeline.track(row.track)?;
            for r in timeline.resolved_transitions_on(track.id) {
                let b = Self::rect(&r, &row, geometry);
                if !(p.x >= b.min_x() && p.x < b.max_x()) {
                    continue;
                }
                // The clip edge at the cut stays trimmable: within the trim handle of it the clips answer, not the box.
                if (p.x - geometry.x(r.cut)).abs() <= cut_slop {
                    continue;
                }
                let e = Self::edge_width(b.width);
                let zone = if p.x < b.min_x() + e {
                    TransitionZone::LeftEdge
                } else if p.x >= b.max_x() - e {
                    TransitionZone::RightEdge
                } else {
                    TransitionZone::Body
                };
                return Some(TransitionHit { id: r.id, track: track.id, zone });
            }
            return None;
        }
        None
    }

    // MARK: Drag

    /// Result of dragging `zone` of `r` by `n` frames (positive = right). Edges: when the transition is centered the two
    /// edges move symmetrically (the duration changes by twice the drag); with `one_side` (Shift) or any other alignment
    /// only the dragged edge moves. The body moves the transition over the cut. The cut stays inside the transition.
    /// Single-sided transitions only change length at their free edge.
    pub fn drag(r: &ResolvedTransition, zone: TransitionZone, n: i64, one_side: bool) -> TransitionChange {
        let fd = r.frame_duration;
        let b0 = r.before.frame_index(fd);
        let a0 = r.after.frame_index(fd);
        let d0 = b0 + a0;
        let centred = r.alignment == TransitionAlignment::Center && !one_side;
        let mut b = b0;
        let mut a = a0;
        match zone {
            TransitionZone::Body => {
                if !r.is_single_sided() {
                    b = (b0 - n).max(0).min(d0);
                    a = d0 - b;
                }
            }
            TransitionZone::RightEdge => {
                if r.outgoing.is_some() && r.incoming.is_none() {
                    // tail fade: the right edge is the clip end
                } else if r.is_single_sided() {
                    a = 1.max(a0 + n); // head fade grows to the right
                    b = 0;
                } else if centred {
                    let d = 1.max(d0 + 2 * n);
                    b = d / 2;
                    a = d - b;
                } else {
                    a = 0.max(a0 + n);
                    if b + a < 1 {
                        a = 1;
                    }
                }
            }
            TransitionZone::LeftEdge => {
                if r.outgoing.is_none() && r.incoming.is_some() {
                    // head fade: the left edge is the clip start
                } else if r.is_single_sided() {
                    b = 1.max(b0 - n); // tail fade grows to the left
                    a = 0;
                } else if centred {
                    let d = 1.max(d0 - 2 * n);
                    b = d / 2;
                    a = d - b;
                } else {
                    b = 0.max(b0 - n);
                    if b + a < 1 {
                        b = 1;
                    }
                }
            }
        }
        Self::normalized(b, a, r.alignment == TransitionAlignment::Center, r.is_single_sided(), fd, r.alignment)
    }

    pub(crate) fn normalized(
        b: i64,
        a: i64,
        prefer_centre: bool,
        single: bool,
        fd: Time,
        original: TransitionAlignment,
    ) -> TransitionChange {
        let d = b + a;
        let alignment = if single {
            original
        } else if d == 1 {
            if prefer_centre {
                TransitionAlignment::Center
            } else if b == 0 {
                TransitionAlignment::StartAtCut
            } else {
                TransitionAlignment::EndAtCut
            }
        } else if b == d / 2 && prefer_centre {
            TransitionAlignment::Center
        } else if b == 0 {
            TransitionAlignment::StartAtCut
        } else if b == d {
            TransitionAlignment::EndAtCut
        } else if b == d / 2 {
            TransitionAlignment::Center
        } else {
            TransitionAlignment::Custom
        };
        TransitionChange { duration: fd * d, alignment, custom_before: fd * b }
    }

    // MARK: Drop from the Effects panel

    /// Where a transition of `kind` dropped at `p` would go: the track under the pointer (matching kind, unlocked), the nearest
    /// edit within `DROP_REACH`, and the alignment from which side of the cut the pointer is on (left = ends at the cut,
    /// right = starts at it, middle = centered). Clip edges without a neighbor take a one-sided transition.
    pub fn drop_target(
        p: Point,
        kind: TransitionKind,
        timeline: &Timeline,
        geometry: &TimelineGeometry,
    ) -> Option<TransitionDropTarget> {
        if p.x < TimelineGeometry::CONTENT_ORIGIN_X {
            return None;
        }
        let row = geometry.rows(timeline).into_iter().find(|r| p.y >= r.y && p.y < r.max_y())?;
        if row.kind != kind.track_kind() {
            return None;
        }
        let track = timeline.track(row.track).filter(|t| !t.is_locked)?;
        if kind.is_element() {
            return Self::element_drop_target(p, kind, track, &row, timeline, geometry);
        }
        let point = timeline.transition_point_near(geometry.unsnapped_time(p.x), track.id)?;
        let edit_x;
        let alignment;
        match point {
            TransitionPoint::Cut { incoming, .. } => {
                let c = track.clips().iter().find(|c| c.id == incoming)?;
                edit_x = geometry.x(c.start);
                let dx = p.x - edit_x;
                alignment = if dx.abs() <= Self::DROP_CENTER_ZONE {
                    TransitionAlignment::Center
                } else if dx < 0.0 {
                    TransitionAlignment::EndAtCut
                } else {
                    TransitionAlignment::StartAtCut
                };
            }
            TransitionPoint::Head(id) => {
                let c = track.clips().iter().find(|c| c.id == id)?;
                edit_x = geometry.x(c.start);
                alignment = TransitionAlignment::StartAtCut;
            }
            TransitionPoint::Tail(id) => {
                let c = track.clips().iter().find(|c| c.id == id)?;
                edit_x = geometry.x(c.timeline().end());
                alignment = TransitionAlignment::EndAtCut;
            }
        }
        if (p.x - edit_x).abs() > Self::DROP_REACH {
            return None;
        }
        let fd = timeline.format.frame_duration;
        let w = geometry.width(kind.preset_duration(fd).unwrap_or_else(|| Timeline::default_transition_duration(fd)));
        let x0 = match alignment {
            TransitionAlignment::Center => edit_x - w / 2.0,
            TransitionAlignment::EndAtCut => edit_x - w,
            _ => edit_x,
        };
        Some(TransitionDropTarget {
            track: track.id,
            point,
            alignment,
            rect: Rect::new(x0, row.y + 1.0, w, (row.height - 2.0).max(1.0)),
            both_ends: false,
            tail_rect: None,
        })
    }

    /// FB-G: an element transition goes on the clip under the pointer (or the clip edge within `DROP_REACH`): its head zone
    /// = In, its tail zone = Out, the middle = both. Each edge zone is a third of the clip, at most twice the transition's
    /// length (and never less than `2 * DROP_REACH`), so long clips still have a wide middle.
    pub(crate) fn element_drop_target(
        p: Point,
        kind: TransitionKind,
        track: &Track,
        row: &TrackRow,
        timeline: &Timeline,
        geometry: &TimelineGeometry,
    ) -> Option<TransitionDropTarget> {
        let fd = timeline.format.frame_duration;
        let w = geometry.width(kind.preset_duration(fd).unwrap_or_else(|| Timeline::default_transition_duration(fd)));
        let mut best: Option<(&Clip, Option<ClipEdge>, f64)> = None;
        for c in track.clips() {
            let x0 = geometry.x(c.start);
            let x1 = geometry.x(c.timeline().end());
            if p.x >= x0 && p.x < x1 {
                best = Some((c, None, 0.0));
                break;
            }
            let d = if p.x < x0 { x0 - p.x } else { p.x - x1 };
            if d <= Self::DROP_REACH && best.is_none_or(|b| d < b.2) {
                best = Some((c, Some(if p.x < x0 { ClipEdge::Head } else { ClipEdge::Tail }), d));
            }
        }
        let (c, outside, _) = best?;
        let x0 = geometry.x(c.start);
        let x1 = geometry.x(c.timeline().end());
        let zone = ((x1 - x0) / 3.0).min((2.0 * Self::DROP_REACH).max(2.0 * w));
        let edge = outside.or(if p.x < x0 + zone {
            Some(ClipEdge::Head)
        } else if p.x >= x1 - zone {
            Some(ClipEdge::Tail)
        } else {
            None
        });
        let bw = w.min(x1 - x0);
        let h = (row.height - 2.0).max(1.0);
        let head_rect = Rect::new(x0, row.y + 1.0, bw, h);
        let tail_rect = Rect::new(x1 - bw, row.y + 1.0, bw, h);
        Some(match edge {
            Some(ClipEdge::Head) => TransitionDropTarget {
                track: track.id,
                point: TransitionPoint::Head(c.id),
                alignment: TransitionAlignment::StartAtCut,
                rect: head_rect,
                both_ends: false,
                tail_rect: None,
            },
            Some(ClipEdge::Tail) => TransitionDropTarget {
                track: track.id,
                point: TransitionPoint::Tail(c.id),
                alignment: TransitionAlignment::EndAtCut,
                rect: tail_rect,
                both_ends: false,
                tail_rect: None,
            },
            None => TransitionDropTarget {
                track: track.id,
                point: TransitionPoint::Head(c.id),
                alignment: TransitionAlignment::StartAtCut,
                rect: head_rect,
                both_ends: true,
                tail_rect: Some(tail_rect),
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::*;
    use sq_core_model::TrackKind;
    use sq_core_time::{SequentialIds, TimeRange};

    const F30: Time = Time::new(1, 30);

    fn f(n: i64) -> Time {
        F30 * n
    }

    fn clip(start: i64) -> Clip {
        let mut c = Clip::new(uid(), "c", uid(), TrackKind::Video, TimeRange::new(f(30), f(60)), f(start));
        c.media_duration = Some(f(300));
        c
    }

    fn timeline_of(track: Track) -> Timeline {
        Timeline::new(uid(), "t", sq_core_model::SequenceFormat::new(F30), vec![track])
    }

    fn resolved(alignment: TransitionAlignment, frames: i64) -> (ResolvedTransition, Timeline) {
        let (a, b) = (clip(0), clip(60));
        let mut tr = Track::new(uid(), TrackKind::Video);
        let mut ids = SequentialIds::default();
        tr.overwrite(a.clone(), &mut ids).unwrap();
        tr.overwrite(b.clone(), &mut ids).unwrap();
        let mut t = timeline_of(tr.clone());
        t.add_transition_at(
            TransitionPoint::Cut { outgoing: a.id, incoming: b.id },
            TransitionKind::CrossDissolve,
            tr.id,
            f(frames),
            alignment,
            &mut ids,
        )
        .unwrap();
        (t.resolved_transitions_on(tr.id).remove(0), t)
    }

    fn g10() -> TimelineGeometry {
        TimelineGeometry::with_points_per_frame(F30, 10.0)
    }

    #[test]
    fn centred_drag_is_symmetric_and_shift_moves_one_side() {
        let (r, _) = resolved(TransitionAlignment::Center, 20);
        let right = TransitionLayout::drag(&r, TransitionZone::RightEdge, 3, false);
        assert!(right.duration == f(26) && right.alignment == TransitionAlignment::Center);
        let left = TransitionLayout::drag(&r, TransitionZone::LeftEdge, -3, false);
        assert!(left.duration == f(26) && left.alignment == TransitionAlignment::Center);
        let shift_right = TransitionLayout::drag(&r, TransitionZone::RightEdge, 3, true);
        assert!(
            shift_right.duration == f(23)
                && shift_right.alignment == TransitionAlignment::Custom
                && shift_right.custom_before == f(10)
        );
        let shift_left = TransitionLayout::drag(&r, TransitionZone::LeftEdge, -4, true);
        assert!(
            shift_left.duration == f(24)
                && shift_left.alignment == TransitionAlignment::Custom
                && shift_left.custom_before == f(14)
        );
        // never below one frame
        assert_eq!(TransitionLayout::drag(&r, TransitionZone::RightEdge, -50, false).duration, f(1));
    }

    #[test]
    fn non_centred_edges_move_only_the_dragged_side() {
        let (r, _) = resolved(TransitionAlignment::StartAtCut, 20);
        let longer = TransitionLayout::drag(&r, TransitionZone::RightEdge, 5, false);
        assert!(longer.duration == f(25) && longer.alignment == TransitionAlignment::StartAtCut);
        let left = TransitionLayout::drag(&r, TransitionZone::LeftEdge, -5, false); // pulls the start before the cut
        assert!(left.duration == f(25) && left.alignment == TransitionAlignment::Custom && left.custom_before == f(5));
        let (e, _) = resolved(TransitionAlignment::EndAtCut, 20);
        assert_eq!(TransitionLayout::drag(&e, TransitionZone::RightEdge, -4, false).duration, f(20)); // the cut stays inside
    }

    #[test]
    fn body_drag_moves_alignment_over_the_cut() {
        let (r, _) = resolved(TransitionAlignment::Center, 20);
        let right = TransitionLayout::drag(&r, TransitionZone::Body, 4, false);
        assert!(
            right.alignment == TransitionAlignment::Custom && right.custom_before == f(6) && right.duration == f(20)
        );
        let al = |n| TransitionLayout::drag(&r, TransitionZone::Body, n, false).alignment;
        assert_eq!(al(10), TransitionAlignment::StartAtCut);
        assert_eq!(al(99), TransitionAlignment::StartAtCut);
        assert_eq!(al(-10), TransitionAlignment::EndAtCut);
        assert_eq!(al(0), TransitionAlignment::Center);
    }

    #[test]
    fn single_sided_only_changes_length_at_the_free_edge() {
        let a = clip(0);
        let mut tr = Track::new(uid(), TrackKind::Video);
        let mut ids = SequentialIds::default();
        tr.overwrite(a.clone(), &mut ids).unwrap();
        let mut t = timeline_of(tr.clone());
        for (point, _) in [(TransitionPoint::Head(a.id), 0), (TransitionPoint::Tail(a.id), 1)] {
            t.add_transition_at(point, TransitionKind::DipToBlack, tr.id, f(10), TransitionAlignment::Center, &mut ids)
                .unwrap();
        }
        let rs = t.resolved_transitions_on(tr.id);
        let head = rs.iter().find(|r| r.outgoing.is_none()).unwrap();
        let tail = rs.iter().find(|r| r.incoming.is_none()).unwrap();
        let d = |r, z, n| TransitionLayout::drag(r, z, n, false).duration;
        assert_eq!(d(head, TransitionZone::RightEdge, 5), f(15));
        assert_eq!(d(head, TransitionZone::LeftEdge, -5), f(10));
        assert_eq!(d(head, TransitionZone::Body, 5), f(10));
        assert_eq!(d(tail, TransitionZone::LeftEdge, -5), f(15));
        assert_eq!(d(tail, TransitionZone::RightEdge, 5), f(10));
    }

    #[test]
    fn boxes_are_hit_over_the_clips_with_edge_zones() {
        let (r, t) = resolved(TransitionAlignment::Center, 20);
        let g = g10();
        let row = g.rows(&t)[0].clone();
        let b = TransitionLayout::rect(&r, &row, &g);
        assert!((b.min_x() - g.x(f(50))).abs() < 1e-9 && (b.width - 200.0).abs() < 1e-9);
        let y = row.y + row.height / 2.0;
        let slop = TimelineGeometry::MAX_TRIM_HANDLE_WIDTH;
        let hit = |x: f64| TransitionLayout::hit_test(pt(x, y), &t, &g, slop);
        assert_eq!(hit(b.mid_x() - 30.0).map(|h| h.zone), Some(TransitionZone::Body));
        assert!(hit(b.mid_x() + 4.0).is_none()); // the clip edge at the cut wins
        assert!(hit(b.mid_x() - 4.0).is_none());
        assert_eq!(hit(b.min_x() + 1.0).map(|h| h.zone), Some(TransitionZone::LeftEdge));
        assert_eq!(hit(b.max_x() - 1.0).map(|h| h.zone), Some(TransitionZone::RightEdge));
        assert!(hit(b.min_x() - 2.0).is_none());
        assert!(TransitionLayout::hit_test(pt(b.mid_x(), row.max_y() + 5.0), &t, &g, slop).is_none());
        // a one-frame transition at a very low zoom stays clickable
        let thin = TimelineGeometry::with_points_per_frame(F30, 0.2);
        let (one, t1) = resolved(TransitionAlignment::Center, 1);
        let r1 = TransitionLayout::rect(&one, &thin.rows(&t1)[0], &thin);
        assert!(r1.width >= TransitionLayout::MIN_WIDTH);
    }

    #[test]
    fn drop_target_picks_side_from_pointer_and_matches_track_kind() {
        let (_, t) = resolved(TransitionAlignment::Center, 20);
        let g = g10();
        let row = g.rows(&t)[0].clone();
        let cut_x = g.x(f(60));
        let y = row.y + 5.0;
        let at = |x: f64, k| TransitionLayout::drop_target(pt(x, y), k, &t, &g);
        let cd = TransitionKind::CrossDissolve;
        assert_eq!(at(cut_x + 3.0, cd).map(|d| d.alignment), Some(TransitionAlignment::Center));
        assert_eq!(at(cut_x - 20.0, cd).map(|d| d.alignment), Some(TransitionAlignment::EndAtCut));
        assert_eq!(at(cut_x + 20.0, cd).map(|d| d.alignment), Some(TransitionAlignment::StartAtCut));
        assert!(at(cut_x + 200.0, cd).is_none()); // far from any edit
        assert!(at(cut_x, TransitionKind::ConstantPower).is_none()); // audio onto video
        let head = at(g.x(Time::ZERO) + 4.0, TransitionKind::DipToWhite).unwrap();
        assert_eq!(head.alignment, TransitionAlignment::StartAtCut);
        assert!(matches!(head.point, TransitionPoint::Head(_)));
    }

    #[test]
    fn drop_ghost_is_as_long_as_the_kinds_preset_duration() {
        let (_, t) = resolved(TransitionAlignment::Center, 20);
        let g = g10();
        let row = g.rows(&t)[0].clone();
        let p = pt(g.x(f(60)) + 3.0, row.y + 5.0);
        let quick = TransitionLayout::drop_target(p, TransitionKind::QuickFade, &t, &g).unwrap();
        assert!((quick.rect.width - g.width(TransitionKind::QuickFade.preset_duration(F30).unwrap())).abs() < 0.5);
        let slide = TransitionLayout::drop_target(p, TransitionKind::Slide, &t, &g).unwrap();
        assert!((slide.rect.width - g.width(f(30))).abs() < 0.5);
    }

    #[test]
    fn drop_on_a_clip_picks_head_tail_or_both() {
        let (a, b) = (clip(0), clip(60));
        let mut tr = Track::new(uid(), TrackKind::Video);
        let mut ids = SequentialIds::default();
        tr.overwrite(a.clone(), &mut ids).unwrap();
        tr.overwrite(b.clone(), &mut ids).unwrap();
        let t = timeline_of(tr);
        let g = g10();
        let y = g.rows(&t)[0].y + 5.0;
        let target = |x: f64| TransitionLayout::drop_target(pt(x, y), TransitionKind::Move, &t, &g);
        let head = target(g.x(f(60)) + 20.0).unwrap();
        assert!(
            head.point == TransitionPoint::Head(b.id)
                && !head.both_ends
                && head.alignment == TransitionAlignment::StartAtCut
        );
        assert!((head.rect.min_x() - g.x(f(60))).abs() < 0.5 && (head.rect.width - g.width(f(24))).abs() < 0.5);
        assert_eq!(target(g.x(f(120)) - 20.0).unwrap().point, TransitionPoint::Tail(b.id));
        // left of the cut: A's tail, never the cut
        assert_eq!(target(g.x(f(60)) - 20.0).unwrap().point, TransitionPoint::Tail(a.id));
        let mid = target(g.x(f(90))).unwrap();
        assert!(mid.point == TransitionPoint::Head(b.id) && mid.both_ends);
        assert!((mid.tail_rect.map_or(0.0, |r| r.max_x()) - g.x(f(120))).abs() < 0.5);
        assert!(target(g.x(f(200))).is_none()); // far from any clip
    }
}
