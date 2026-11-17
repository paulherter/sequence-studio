//! Port of `FourPointFit.swift`: Fit Clip choice for a four-mark Source edit (Fit to Fill by speed is `fitToFill` on the
//! session). Each case drops one of the four marks so the remaining three decide the edit.

use sq_core_model::SourceMarks;
use sq_core_time::Time;

/// Which mark a four-point edit ignores.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FourPointFit {
    /// Default: sequence In/Out set the range, the source In picks the part (the source Out is ignored).
    TrimSourceEnd,
    /// The source Out and the sequence range are used; the source In is ignored.
    IgnoreSourceIn,
    /// Source In/Out give the length, placed at the sequence In; the sequence Out is ignored.
    IgnoreSequenceOut,
    /// Source In/Out give the length, ending at the sequence Out; the sequence In is ignored.
    IgnoreSequenceIn,
}

/// The marks left after dropping one.
#[derive(Clone, Debug, PartialEq)]
pub struct FourPointMarks {
    /// Source marks.
    pub source: SourceMarks,
    /// Sequence In.
    pub sequence_in: Option<Time>,
    /// Sequence Out.
    pub sequence_out: Option<Time>,
}

impl FourPointFit {
    /// Every case, in declaration order (Swift `CaseIterable`).
    pub const ALL: [FourPointFit; 4] = [
        FourPointFit::TrimSourceEnd,
        FourPointFit::IgnoreSourceIn,
        FourPointFit::IgnoreSequenceOut,
        FourPointFit::IgnoreSequenceIn,
    ];

    /// The marks left after dropping one.
    pub fn apply(self, source: &SourceMarks, sequence_in: Option<Time>, sequence_out: Option<Time>) -> FourPointMarks {
        let mut m = source.clone();
        let (mut si, mut so) = (sequence_in, sequence_out);
        match self {
            FourPointFit::TrimSourceEnd => {}
            FourPointFit::IgnoreSourceIn => m.mark_in = None,
            FourPointFit::IgnoreSequenceOut => so = None,
            FourPointFit::IgnoreSequenceIn => si = None,
        }
        FourPointMarks { source: m, sequence_in: si, sequence_out: so }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(n: i64) -> Time {
        Time::new(n, 1)
    }

    #[test]
    fn each_choice_drops_one_mark() {
        let m = SourceMarks { mark_in: Some(s(2)), mark_out: Some(s(4)), ..Default::default() };
        let (si, so) = (Some(s(10)), Some(s(15)));
        let a = FourPointFit::IgnoreSourceIn.apply(&m, si, so);
        assert!(
            a.source.mark_in.is_none()
                && a.source.mark_out == Some(s(4))
                && a.sequence_in == si
                && a.sequence_out == so
        );
        let b = FourPointFit::IgnoreSequenceOut.apply(&m, si, so);
        assert!(b.source == m && b.sequence_in == si && b.sequence_out.is_none());
        let c = FourPointFit::IgnoreSequenceIn.apply(&m, si, so);
        assert!(c.sequence_in.is_none() && c.sequence_out == so);
        let d = FourPointFit::TrimSourceEnd.apply(&m, si, so);
        assert!(d.source == m && d.sequence_in == si && d.sequence_out == so);
        assert_eq!(FourPointFit::ALL.len(), 4);
    }
}
