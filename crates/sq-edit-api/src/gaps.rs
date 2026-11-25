//! `GET /v1/gaps`: every gap between two clips of a track (even one shorter than a frame) and every stretch of the
//! sequence where no picture is under the playhead (a black frame).

use serde::{Deserialize, Serialize};
use sq_core_model::{Timeline, TrackKind};
use sq_core_time::{Id, Time, TimeRange};

/// A gap between two clips of one track.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Gap {
    /// The track.
    pub track: Id,
    /// `video` or `audio`.
    pub kind: String,
    /// Where the earlier clip ends.
    pub start: Time,
    /// Up to where the next clip starts.
    pub duration: Time,
    /// The clip before the gap.
    pub before: Id,
    /// The clip after the gap.
    pub after: Id,
    /// The gap is shorter than one frame of the sequence (invisible on the timeline, still a black frame).
    pub shorter_than_frame: bool,
}

/// What `GET /v1/gaps` answers.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GapReport {
    /// The sequence.
    pub sequence: Id,
    /// Duration of one frame.
    pub frame_duration: Time,
    /// Gaps between clips, track by track.
    pub gaps: Vec<Gap>,
    /// Stretches from 0 to the end of the sequence where no enabled clip of a visible video track shows (black).
    pub black: Vec<TimeRange>,
}

/// Every gap and black stretch of `t`; times stay rational.
pub fn find(t: &Timeline) -> GapReport {
    let fd = t.frame_duration();
    let mut gaps = Vec::new();
    for tr in &t.tracks {
        let mut clips: Vec<_> = tr.clips().iter().collect();
        clips.sort_by_key(|c| c.start);
        for w in clips.windows(2) {
            let end = w[0].timeline().end();
            if w[1].start > end {
                let duration = w[1].start - end;
                gaps.push(Gap {
                    track: tr.id,
                    kind: if tr.kind == TrackKind::Video { "video" } else { "audio" }.to_string(),
                    start: end,
                    duration,
                    before: w[0].id,
                    after: w[1].id,
                    shorter_than_frame: duration < fd,
                });
            }
        }
    }
    let mut shown: Vec<TimeRange> = t
        .tracks
        .iter()
        .filter(|tr| tr.kind == TrackKind::Video && tr.is_visible)
        .flat_map(|tr| tr.clips().iter().filter(|c| c.is_enabled).map(|c| c.timeline()))
        .collect();
    shown.sort_by_key(|r| r.start);
    let (mut black, mut covered) = (Vec::new(), Time::ZERO);
    for r in shown {
        if r.start > covered {
            black.push(TimeRange::from_end(covered, r.start));
        }
        covered = covered.max(r.end());
    }
    let end = t.duration();
    if end > covered {
        black.push(TimeRange::from_end(covered, end));
    }
    GapReport { sequence: t.id, frame_duration: fd, gaps, black }
}

/// The gaps of `after` that `before` did not have (what an edit just opened), as `(track, start)` keys compared.
pub fn opened(before: &Timeline, after: &Timeline) -> Vec<Gap> {
    let old: Vec<(Id, Time, Time)> = find(before).gaps.iter().map(|g| (g.track, g.start, g.duration)).collect();
    find(after).gaps.into_iter().filter(|g| !old.contains(&(g.track, g.start, g.duration))).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::edit_transaction::fixture::{Fixture, s};

    #[test]
    fn a_gap_of_one_sixtieth_at_30_fps_is_reported_and_black_is_listed() {
        let f = Fixture::new();
        let one_frame = Time::new(1, 30);
        let sixtieth = Time::new(1, 60);
        let Some(mut t) = f.project.timeline(f.seq).cloned() else { panic!("sequence") };
        t.set_frame_duration(one_frame);
        let mut b = t.find(f.b).map(|m| m.clip.clone()).expect("b");
        b.start = s(4) + sixtieth;
        let track = t.tracks.iter().position(|tr| tr.id == f.v1).expect("v1");
        t.tracks[track].replace(b);
        let report = find(&t);
        assert_eq!(report.gaps.len(), 1, "{report:?}");
        let g = &report.gaps[0];
        assert_eq!((g.track, g.start, g.duration, g.shorter_than_frame), (f.v1, s(4), sixtieth, true));
        assert_eq!(report.black, vec![TimeRange::from_end(s(4), s(4) + sixtieth)]);
        // Touching clips: no gap, no black.
        let clean = find(&f.project.timeline(f.seq).cloned().expect("t"));
        assert!(clean.gaps.is_empty() && clean.black.is_empty(), "{clean:?}");
    }
}
