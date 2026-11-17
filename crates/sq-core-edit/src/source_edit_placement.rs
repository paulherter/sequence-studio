//! Sequence In/Out marks and where a Source edit lands (Premiere: In and Out both include their own frame, so
//! In = 10 and Out = 20 cover 11 frames; the range is stored half-open, `end = Out frame + one frame`).
// Swift: SourceEditPlacement.swift

use sq_core_model::{ClipSpeed, InOutKind, SourceMarks, Timeline};
use sq_core_time::{Time, TimeRange};

use crate::timeline_source_edit::TimelineSourceEditExt;

/// What a range gesture on the In/Out band picked up.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MarkedRangeDragPart {
    /// A range dragged out on empty track: both marks are set.
    NewRange,
    /// The whole band moved.
    Body,
    InEdge,
    OutEdge,
}

/// What a Source edit places and where (Premiere three- and four-point rules).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SourceEditPlan {
    pub source: TimeRange,
    pub at: Time,
    /// Both sequence marks and both source marks were set: Premiere would ask (Fit Clip); we use the sequence In/Out
    /// and the source In and say so.
    pub used_four_point_default: bool,
}

/// Fit to Fill: the whole marked source range goes into the sequence In..Out range, retimed by constant speed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FitToFillPlan {
    pub source: TimeRange,
    pub at: Time,
    /// Length on the sequence (whole frames).
    pub length: Time,
    pub speed: ClipSpeed,
}

/// Swift `extension Timeline` of SourceEditPlacement.swift. The two `sourceEditPlacement` overloads are
/// `source_edit_placement_from_marks` (static) and `source_edit_placement`.
pub trait SourceEditPlacementExt {
    /// Where a Source edit of `source_duration` starts on the sequence (three-point rule): at the sequence In when one is
    /// set; else, with only a sequence Out, back-timed so the clip ends at the Out (`mark_out` is the stored end, one
    /// frame past the Out frame; never before 0); else at the playhead.
    fn source_edit_placement_from_marks(
        source_duration: Time,
        mark_in: Option<Time>,
        mark_out: Option<Time>,
        playhead: Time,
    ) -> Time;
    /// The explicit sequence marks `(mark_in, mark_out)` (stored Out = one frame past the Out frame).
    fn explicit_marks(&self) -> (Option<Time>, Option<Time>);
    /// The range an export covers by default (Premiere: Sequence In/Out when set). With In only (also older files without
    /// `in_out_kind`) the end is the CURRENT sequence length, not the length at the time In was marked; Out only starts at 0.
    /// None when no In/Out is set.
    fn export_range(&self) -> Option<TimeRange>;
    /// Start of an edit of `source_duration` using this sequence's marks (see the static function).
    fn source_edit_placement(&self, source_duration: Time, playhead: Time) -> Time;
    /// Mark In at `t`. A later Out stays; an Out at or before the new In jumps to the end of the sequence. Allowed
    /// at any frame (Premiere).
    fn mark_in_at(&mut self, t: Time);
    /// Mark Out at `t`: the frame at `t` is the last frame inside the range, so the stored end is `t + one frame`
    /// (allowed at frame 0: a one-frame range). An In after the new Out is dropped (In falls back to 0).
    fn mark_out_at(&mut self, t: Time);
    /// In and Out both set (Mark Clip, Mark Selection, dragging a range).
    fn set_marked_range(&mut self, r: Option<TimeRange>);
    /// Drop of a range gesture whose dragged part is known (monitor strip). A newly dragged range always sets both
    /// marks. A range with both marks stays both. With only an In marked, moving the In edge or the whole band keeps it
    /// In-only (Out keeps following the sequence end); only dragging the Out edge makes a real Out. The same the other
    /// way round for an Out-only mark.
    fn drag_marked_range_part(&mut self, r: TimeRange, part: MarkedRangeDragPart);
    /// Drop of a drag on the ruler's In/Out band, which reports only the range: the dragged part is read from what
    /// changed against the old range. A range with both marks stays both. With only an In
    /// marked, moving the In edge or the whole band keeps it In-only (Out keeps following the sequence end); only
    /// dragging the Out edge makes a real Out. The same the other way round for an Out-only mark.
    fn drag_marked_range(&mut self, r: TimeRange);
    /// Clear In: the In goes away, a marked Out stays (the range then starts at 0).
    fn clear_in(&mut self);
    /// Clear Out: the Out goes away, a marked In stays (the range then runs to the end of the sequence).
    fn clear_out(&mut self);
    /// - Both sequence marks: the sequence range sets the length and position; source In (else Out, else the media start)
    ///   chooses the part of the source. With both source marks too, the source In is used and `used_four_point_default` is set.
    /// - Sequence Out only: the source range ends at that Out; when there is less room before it than the source is long,
    ///   the head of the source is cut so the clip starts at 0.
    /// - Sequence In only, or none: the source range lands at the In (else the playhead).
    ///
    /// Lengths are whole sequence frames; a source shorter than the wanted length shortens the clip. None = nothing to place.
    fn source_edit_plan(
        source_marks: &SourceMarks,
        total: Time,
        sequence_in: Option<Time>,
        sequence_out: Option<Time>,
        playhead: Time,
        fd: Time,
        is_still: bool,
    ) -> Option<SourceEditPlan>;
    /// The source In..Out (the whole media without marks) over the sequence In..Out. None: a sequence mark is missing, the
    /// range is empty or there is no source range.
    fn fit_to_fill_plan(
        source_marks: &SourceMarks,
        total: Time,
        sequence_in: Option<Time>,
        sequence_out: Option<Time>,
        fd: Time,
    ) -> Option<FitToFillPlan>;
}

/// The two single-mark states: an In whose Out follows the sequence end, and an Out that starts at 0.
trait SingleMark {
    fn set_in_only(&mut self, start: Time);
    fn set_out_only(&mut self, end: Time);
}

impl SingleMark for Timeline {
    fn set_in_only(&mut self, start: Time) {
        let end = self.duration().max(start + self.frame_duration());
        self.in_out = Some(TimeRange::from_end(start, end));
        self.in_out_kind = Some(InOutKind::InOnly);
    }

    fn set_out_only(&mut self, end: Time) {
        self.in_out = Some(TimeRange::from_end(Time::ZERO, end));
        self.in_out_kind = Some(InOutKind::OutOnly);
    }
}

impl SourceEditPlacementExt for Timeline {
    fn source_edit_placement_from_marks(
        source_duration: Time,
        mark_in: Option<Time>,
        mark_out: Option<Time>,
        playhead: Time,
    ) -> Time {
        if let Some(i) = mark_in {
            return i;
        }
        if let Some(o) = mark_out {
            return Time::ZERO.max(o - source_duration);
        }
        playhead
    }

    fn explicit_marks(&self) -> (Option<Time>, Option<Time>) {
        let Some(io) = self.in_out else { return (None, None) };
        match self.in_out_kind {
            Some(InOutKind::InOnly) => (Some(io.start), None),
            Some(InOutKind::OutOnly) => (None, Some(io.end())),
            Some(InOutKind::Both) => (Some(io.start), Some(io.end())),
            None => {
                if io.end() >= self.duration() {
                    (Some(io.start), None)
                } else {
                    (Some(io.start), Some(io.end()))
                }
            }
        }
    }

    fn export_range(&self) -> Option<TimeRange> {
        self.in_out?;
        let m = self.explicit_marks();
        let start = m.0.unwrap_or(Time::ZERO);
        let end = m.1.unwrap_or_else(|| self.duration());
        (end > start).then(|| TimeRange::from_end(start, end))
    }

    fn source_edit_placement(&self, source_duration: Time, playhead: Time) -> Time {
        let m = self.explicit_marks();
        Self::source_edit_placement_from_marks(source_duration, m.0, m.1, playhead)
    }

    fn mark_in_at(&mut self, t: Time) {
        match self.explicit_marks().1 {
            Some(o) if o > t => {
                self.in_out = Some(TimeRange::from_end(t, o));
                self.in_out_kind = Some(InOutKind::Both);
            }
            _ => self.set_in_only(t),
        }
    }

    fn mark_out_at(&mut self, t: Time) {
        let end = t + self.frame_duration();
        match self.explicit_marks().0 {
            Some(i) if i <= t => {
                self.in_out = Some(TimeRange::from_end(i, end));
                self.in_out_kind = Some(InOutKind::Both);
            }
            _ => self.set_out_only(end),
        }
    }

    fn set_marked_range(&mut self, r: Option<TimeRange>) {
        self.in_out = r;
        self.in_out_kind = r.map(|_| InOutKind::Both);
    }

    fn drag_marked_range_part(&mut self, r: TimeRange, part: MarkedRangeDragPart) {
        if self.in_out.is_none() || part == MarkedRangeDragPart::NewRange {
            self.set_marked_range(Some(r));
            return;
        }
        let m = self.explicit_marks();
        match (m.0.is_some(), m.1.is_some()) {
            (true, false) if part != MarkedRangeDragPart::OutEdge => self.set_in_only(r.start),
            (false, true) if part != MarkedRangeDragPart::InEdge => self.set_out_only(r.end()),
            _ => self.set_marked_range(Some(r)),
        }
    }

    fn drag_marked_range(&mut self, r: TimeRange) {
        let Some(old) = self.in_out else {
            self.set_marked_range(Some(r));
            return;
        };
        let m = self.explicit_marks();
        match (m.0.is_some(), m.1.is_some()) {
            (true, false) if !(r.start == old.start && r.end() != old.end()) => self.set_in_only(r.start),
            (false, true) if !(r.end() == old.end() && r.start != old.start) => self.set_out_only(r.end()),
            _ => self.set_marked_range(Some(r)),
        }
    }

    fn clear_in(&mut self) {
        let Some(io) = self.in_out else { return };
        let m = self.explicit_marks();
        if m.0.is_none() {
            return;
        }
        if m.1.is_some() {
            self.set_out_only(io.end());
        } else {
            self.set_marked_range(None);
        }
    }

    fn clear_out(&mut self) {
        if self.in_out.is_none() {
            return;
        }
        let m = self.explicit_marks();
        if m.1.is_none() {
            return;
        }
        match m.0 {
            Some(i) => self.set_in_only(i),
            None => self.set_marked_range(None),
        }
    }

    fn source_edit_plan(
        m: &SourceMarks,
        total: Time,
        sequence_in: Option<Time>,
        sequence_out: Option<Time>,
        playhead: Time,
        fd: Time,
        is_still: bool,
    ) -> Option<SourceEditPlan> {
        let whole = |t: Time| t.snapped(fd).max(fd);
        let fit = |start: Time, d: Time| -> Option<TimeRange> {
            let mut d = d;
            if !is_still && start + d > total {
                d = (total - start).snapped(fd);
                if start + d > total {
                    d -= fd;
                }
            }
            (d > Time::ZERO).then(|| TimeRange::new(start, d))
        };
        if let (Some(si), Some(so)) = (sequence_in, sequence_out)
            && so > si
        {
            let want = whole(so - si);
            let start = match (m.mark_in, m.mark_out) {
                (Some(i), _) => i,
                (None, Some(o)) => Time::ZERO.max(o - want),
                (None, None) => Time::ZERO,
            };
            // A lone source Out is the last frame wanted: a shorter source is not padded past it.
            let wanted = match (m.mark_in, m.mark_out) {
                (None, Some(o)) => want.min((o.snapped(fd) - start).max(fd)),
                _ => want,
            };
            let src = fit(start, wanted)?;
            return Some(SourceEditPlan {
                source: src,
                at: si,
                used_four_point_default: m.mark_in.is_some() && m.mark_out.is_some(),
            });
        }
        let range = if is_still { TimeRange::new(Time::ZERO, total) } else { Timeline::source_edit_range(m, total)? };
        let mut d = whole(range.duration);
        if !is_still && range.start + d > total {
            d -= fd;
        }
        if d <= Time::ZERO {
            return None;
        }
        let plan = |source: TimeRange, at: Time| Some(SourceEditPlan { source, at, used_four_point_default: false });
        if let Some(si) = sequence_in {
            return plan(TimeRange::new(range.start, d), si);
        }
        if let Some(so) = sequence_out {
            if so >= d {
                return plan(TimeRange::new(range.start, d), so - d);
            }
            // Not enough room before the Out: cut the head of the source, the clip starts at 0 and still ends at the Out.
            let keep = whole(so);
            let start = range.start + d - keep;
            return plan(TimeRange::new(start, keep), Time::ZERO);
        }
        plan(TimeRange::new(range.start, d), playhead.snapped(fd))
    }

    fn fit_to_fill_plan(
        m: &SourceMarks,
        total: Time,
        sequence_in: Option<Time>,
        sequence_out: Option<Time>,
        fd: Time,
    ) -> Option<FitToFillPlan> {
        let (si, so) = (sequence_in?, sequence_out?);
        if so <= si {
            return None;
        }
        let src = Timeline::source_edit_range(m, total)?;
        let length = (so - si).snapped(fd).max(fd);
        Some(FitToFillPlan { source: src, at: si, length, speed: ClipSpeed::from_source_over(src.duration, length) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{Clip, SequenceFormat, Track, TrackKind};
    use sq_core_time::{Id, SequentialIds};

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }
    fn fd() -> Time {
        Time::new(1, 30)
    }
    fn range(a: Time, b: Time) -> TimeRange {
        TimeRange::from_end(a, b)
    }
    fn marks(i: Option<i64>, o: Option<i64>) -> SourceMarks {
        SourceMarks { mark_in: i.map(s), mark_out: o.map(s), ..SourceMarks::default() }
    }

    /// One video clip of 2 s (or `duration` s when starting at 0) at second `at`.
    fn with_clip(duration: i64, at: i64) -> Timeline {
        let mut ids = SequentialIds::default();
        let mut v = Track::new(Id::from_u128(900), TrackKind::Video);
        let src = TimeRange::new(Time::ZERO, s(duration));
        let c = Clip::new(Id::from_u128(901), "c", Id::from_u128(902), TrackKind::Video, src, s(at));
        v.overwrite(c, &mut ids).unwrap();
        Timeline::new(Id::from_u128(903), "T", SequenceFormat::new(fd()), vec![v])
    }
    fn timeline(duration: i64) -> Timeline {
        with_clip(duration, 0)
    }
    fn sparse(at: i64) -> Timeline {
        with_clip(2, at)
    }

    #[test]
    fn export_range_follows_current_length_for_in_only() {
        let mut ids = SequentialIds::default();
        let mut t = timeline(10);
        assert_eq!(t.export_range(), None);
        t.mark_in_at(s(2));
        let src = TimeRange::new(Time::ZERO, s(5));
        let d = Clip::new(Id::from_u128(910), "d", Id::from_u128(911), TrackKind::Video, src, s(10));
        t.tracks[0].overwrite(d, &mut ids).unwrap();
        assert_eq!(t.duration(), s(15));
        assert_eq!(t.export_range(), Some(range(s(2), s(15))));
        t.mark_out_at(s(6));
        assert_eq!(t.export_range(), Some(range(s(2), s(6) + fd())));
        // Older file without a kind whose stored end reaches the sequence end reads as In only.
        let mut old = timeline(10);
        old.in_out = Some(range(s(3), s(10)));
        old.in_out_kind = None;
        assert_eq!(old.export_range(), Some(range(s(3), s(10))));
        let mut o = timeline(10);
        o.mark_out_at(s(4));
        assert_eq!(o.export_range(), Some(range(Time::ZERO, s(4) + fd())));
    }

    #[test]
    fn out_includes_its_own_frame() {
        let mut t = timeline(10);
        t.mark_in_at(fd() * 10);
        t.mark_out_at(fd() * 20);
        assert_eq!(t.in_out, Some(range(fd() * 10, fd() * 21)));
        assert_eq!(t.in_out.map(|r| r.duration), Some(fd() * 11));
        assert_eq!(t.explicit_marks().0, Some(fd() * 10));
    }

    #[test]
    fn out_at_frame_zero_and_same_frame_are_one_frame_ranges() {
        let mut t = timeline(10);
        t.mark_out_at(Time::ZERO);
        assert_eq!(t.in_out, Some(range(Time::ZERO, fd())));
        let mut u = timeline(10);
        u.mark_in_at(fd() * 5);
        u.mark_out_at(fd() * 5);
        assert_eq!(u.in_out.map(|r| r.duration), Some(fd()));
    }

    #[test]
    fn in_after_out_moves_out_to_the_end_and_out_before_in_drops_in() {
        let mut t = timeline(10);
        t.mark_in_at(fd() * 10);
        t.mark_out_at(fd() * 20);
        t.mark_in_at(fd() * 40);
        assert_eq!(t.in_out, Some(range(fd() * 40, s(10))));
        let mut u = timeline(10);
        u.mark_in_at(fd() * 100);
        u.mark_out_at(fd() * 20);
        assert_eq!(u.in_out, Some(range(Time::ZERO, fd() * 21)));
        assert_eq!(u.explicit_marks(), (None, Some(fd() * 21)));
    }

    #[test]
    fn out_only_is_remembered_until_an_in_is_set() {
        let mut t = timeline(10);
        t.mark_out_at(fd() * 59);
        assert_eq!(t.explicit_marks(), (None, Some(fd() * 60)));
        t.mark_in_at(fd() * 30);
        assert_eq!(t.explicit_marks(), (Some(fd() * 30), Some(fd() * 60)));
        assert_eq!(t.in_out, Some(range(fd() * 30, fd() * 60)));
    }

    #[test]
    fn placement_with_only_out_is_back_timed() {
        let p = |i, o, ph| Timeline::source_edit_placement_from_marks(s(4), i, o, ph);
        assert_eq!(p(None, Some(s(10)), s(1)), s(6));
        assert_eq!(p(None, Some(s(3)), s(1)), Time::ZERO);
        assert_eq!(p(Some(s(2)), Some(s(10)), s(1)), s(2));
        assert_eq!(p(None, None, s(7)), s(7));
    }

    #[test]
    fn timeline_placement_uses_the_marks() {
        let mut t = timeline(10);
        assert_eq!(t.source_edit_placement(s(4), s(1)), s(1));
        t.mark_out_at(s(10) - fd());
        assert_eq!(t.source_edit_placement(s(4), s(1)), s(6));
        t.mark_in_at(s(2));
        assert_eq!(t.source_edit_placement(s(4), s(1)), s(2));
    }

    #[test]
    fn mark_clip_after_an_out_only_mark_makes_both_explicit() {
        let mut t = timeline(10);
        t.mark_out_at(fd() * 59);
        t.set_marked_range(Some(range(Time::ZERO, fd() * 60)));
        assert_eq!(t.explicit_marks(), (Some(Time::ZERO), Some(fd() * 60)));
        assert_eq!(t.in_out_kind, Some(InOutKind::Both));
    }

    #[test]
    fn clear_in_and_out_keep_the_other_mark() {
        let mut t = timeline(10);
        t.mark_in_at(s(2));
        t.mark_out_at(s(5));
        t.clear_in();
        assert_eq!(t.explicit_marks(), (None, Some(s(5) + fd())));
        t.clear_in();
        assert_eq!(t.explicit_marks().1, Some(s(5) + fd()));
        t.mark_in_at(s(1));
        t.clear_out();
        assert_eq!(t.explicit_marks(), (Some(s(1)), None));
        t.clear_out();
        assert_eq!(t.explicit_marks().0, Some(s(1)));
        t.mark_out_at(s(3));
        t.clear_in();
        t.clear_out();
        assert!(t.in_out.is_none() && t.in_out_kind.is_none());
    }

    #[test]
    fn dragging_an_in_only_or_out_only_mark_keeps_its_kind() {
        let mut t = sparse(8);
        let end = t.duration();
        t.mark_in_at(s(2));
        assert_eq!(t.in_out_kind, Some(InOutKind::InOnly));
        t.drag_marked_range(range(s(3), end));
        assert!(t.in_out_kind == Some(InOutKind::InOnly) && t.explicit_marks() == (Some(s(3)), None));
        assert_eq!(t.in_out.map(|r| r.end()), Some(end));
        t.drag_marked_range(range(s(4), end + s(1)));
        assert!(t.in_out_kind == Some(InOutKind::InOnly) && t.in_out.map(|r| r.start) == Some(s(4)));
        let in_only_end = t.in_out.map(|r| r.end()).unwrap();
        t.drag_marked_range(range(s(4), in_only_end + s(2)));
        assert!(t.in_out_kind == Some(InOutKind::Both) && t.in_out == Some(range(s(4), in_only_end + s(2))));
        t.set_marked_range(None);
        t.mark_out_at(s(5));
        assert_eq!(t.in_out_kind, Some(InOutKind::OutOnly));
        let stored = t.in_out.map(|r| r.end()).unwrap();
        t.drag_marked_range(range(Time::ZERO, stored + s(1)));
        assert!(t.in_out_kind == Some(InOutKind::OutOnly) && t.explicit_marks().0.is_none());
        assert_eq!(t.in_out, Some(range(Time::ZERO, stored + s(1))));
        t.drag_marked_range(range(s(1), stored + s(1)));
        assert!(t.in_out_kind == Some(InOutKind::Both) && t.in_out.map(|r| r.start) == Some(s(1)));
        t.drag_marked_range(range(s(2), s(3)));
        assert!(t.in_out_kind == Some(InOutKind::Both) && t.in_out == Some(range(s(2), s(3))));
    }

    #[test]
    fn a_newly_dragged_range_sets_both_marks_and_parts_keep_the_kind() {
        use MarkedRangeDragPart::{Body, InEdge, NewRange, OutEdge};
        let mut t = sparse(8);
        let end = t.duration();
        t.mark_in_at(s(2));
        t.drag_marked_range_part(range(s(4), s(6)), NewRange);
        assert!(t.in_out_kind == Some(InOutKind::Both) && t.in_out == Some(range(s(4), s(6))));
        t.set_marked_range(None);
        t.mark_out_at(s(5));
        let stored = t.in_out.map(|r| r.end()).unwrap();
        t.drag_marked_range_part(range(s(1), s(3)), NewRange);
        assert!(t.in_out_kind == Some(InOutKind::Both) && t.in_out == Some(range(s(1), s(3))));
        t.set_marked_range(None);
        t.mark_out_at(s(5));
        t.drag_marked_range_part(range(s(1), stored), NewRange);
        assert!(t.in_out_kind == Some(InOutKind::Both) && t.in_out == Some(range(s(1), stored)));
        t.set_marked_range(None);
        t.mark_in_at(s(2));
        t.drag_marked_range_part(range(s(3), end + s(1)), Body);
        assert!(t.in_out_kind == Some(InOutKind::InOnly) && t.in_out.map(|r| r.start) == Some(s(3)));
        t.drag_marked_range_part(range(s(4), end), InEdge);
        assert!(t.in_out_kind == Some(InOutKind::InOnly) && t.in_out.map(|r| r.start) == Some(s(4)));
        t.drag_marked_range_part(range(s(4), s(7)), OutEdge);
        assert!(t.in_out_kind == Some(InOutKind::Both) && t.in_out == Some(range(s(4), s(7))));
        t.set_marked_range(None);
        t.mark_out_at(s(5));
        t.drag_marked_range_part(range(s(1), s(7)), Body);
        assert!(t.in_out_kind == Some(InOutKind::OutOnly) && t.in_out == Some(range(Time::ZERO, s(7))));
        t.drag_marked_range_part(range(Time::ZERO, s(6)), OutEdge);
        assert!(t.in_out_kind == Some(InOutKind::OutOnly) && t.in_out == Some(range(Time::ZERO, s(6))));
        t.drag_marked_range_part(range(s(1), s(6)), InEdge);
        assert!(t.in_out_kind == Some(InOutKind::Both) && t.in_out == Some(range(s(1), s(6))));
    }

    fn plan(m: &SourceMarks, si: Option<i64>, so: Option<i64>, ph: i64) -> Option<SourceEditPlan> {
        Timeline::source_edit_plan(m, s(10), si.map(s), so.map(s), s(ph), fd(), false)
    }

    #[test]
    fn out_only_back_times_and_cuts_the_source_head_when_there_is_no_room() {
        let m = marks(Some(2), Some(8));
        let roomy = plan(&m, None, Some(20), 1).unwrap();
        assert!(roomy.at == s(14) && roomy.source == range(s(2), s(8)));
        let tight = plan(&m, None, Some(4), 1).unwrap();
        assert_eq!(tight.at, Time::ZERO);
        assert_eq!(tight.source, range(s(4), s(8)));
    }

    #[test]
    fn sequence_in_and_out_set_the_length_and_source_in_chooses_the_part() {
        let p = plan(&marks(Some(3), None), Some(10), Some(14), 1).unwrap();
        assert!(p.at == s(10) && p.source == range(s(3), s(7)) && !p.used_four_point_default);
        assert_eq!(plan(&marks(None, None), Some(10), Some(14), 1).unwrap().source, range(s(0), s(4)));
        assert_eq!(plan(&marks(None, Some(9)), Some(10), Some(14), 1).unwrap().source, range(s(5), s(9)));
    }

    #[test]
    fn four_point_uses_sequence_range_and_source_in_and_says_so() {
        let p = plan(&marks(Some(2), Some(9)), Some(10), Some(13), 1).unwrap();
        assert!(p.used_four_point_default && p.source == range(s(2), s(5)) && p.at == s(10));
        let lone =
            Timeline::source_edit_plan(&marks(None, Some(4)), s(10), Some(s(10)), Some(s(15)), Time::ZERO, fd(), false);
        assert_eq!((lone.map(|p| p.source), lone.map(|p| p.at)), (Some(range(s(0), s(4))), Some(s(10))));
    }

    #[test]
    fn short_source_shortens_the_clip_and_plain_cases_stay_as_before() {
        let short = plan(&marks(Some(8), None), Some(0), Some(5), 1).unwrap();
        assert!(short.source.duration <= s(2));
        let in_only = plan(&marks(Some(2), Some(5)), Some(7), None, 1).unwrap();
        assert!(in_only.at == s(7) && in_only.source.duration == s(3));
        assert_eq!(plan(&marks(Some(2), Some(5)), None, None, 4).unwrap().at, s(4));
        assert_eq!(plan(&marks(Some(5), Some(5)), None, None, 1), None);
    }

    fn fill(m: &SourceMarks, si: Option<i64>, so: Option<i64>, total: i64) -> Option<FitToFillPlan> {
        Timeline::fit_to_fill_plan(m, s(total), si.map(s), so.map(s), fd())
    }

    #[test]
    fn fit_to_fill_speeds_and_slows_to_the_sequence_range() {
        let p = fill(&marks(Some(2), Some(10)), Some(5), Some(9), 20).unwrap();
        assert_eq!(p.source, range(s(2), s(10)));
        assert!(p.at == s(5) && p.length == s(4) && p.speed == ClipSpeed::new(2, 1));
        assert_eq!(fill(&marks(Some(0), Some(2)), Some(0), Some(8), 20).unwrap().speed, ClipSpeed::new(1, 4));
        assert_eq!(fill(&marks(Some(0), Some(2)), Some(0), None, 20), None);
        assert_eq!(fill(&marks(Some(0), Some(2)), None, Some(4), 20), None);
        let whole = fill(&marks(None, None), Some(1), Some(11), 5).unwrap();
        assert!(whole.source == TimeRange::new(Time::ZERO, s(5)) && whole.speed == ClipSpeed::new(1, 2));
    }
}
