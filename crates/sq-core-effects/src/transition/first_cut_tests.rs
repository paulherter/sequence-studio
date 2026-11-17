// SPDX-License-Identifier: GPL-3.0-or-later
//! Three clips cut from one source (0-3 s, 3-6 s, 6-9 s) with a dissolve at each cut: both cuts resolve and pair the clips.

use super::tests::{clip, f, fd, ids};
use super::*;
use sq_core_model::{SequenceFormat, Timeline, Track, TrackKind, TransitionAlignment, TransitionKind};
use sq_core_time::Id;

#[test]
fn both_cuts_of_the_middle_clip_resolve_and_pair_their_clips() {
    let mut tr = Track::new(Id::from_u128(900), TrackKind::Video);
    let cs: Vec<_> = (0..3).map(|n| clip(n + 1, n as i64 * 90, n as i64 * 90, 90, 270, TrackKind::Video)).collect();
    for c in &cs {
        tr.overwrite(c.clone(), &mut ids()).unwrap();
    }
    let mut t = Timeline::new(Id::from_u128(901), "t", SequenceFormat::new(fd()), vec![tr]);
    let track = t.tracks[0].id;
    for (o, i) in [(0, 1), (1, 2)] {
        let p = TransitionPoint::Cut { outgoing: cs[o].id, incoming: cs[i].id };
        t.add_transition_at(p, TransitionKind::CrossDissolve, track, f(30), TransitionAlignment::Center, &mut ids())
            .unwrap();
    }
    let spans: Vec<_> = t.resolved_transitions_on(track).iter().map(|r| (r.span.start, r.span.duration)).collect();
    assert_eq!(spans, vec![(f(75), f(30)), (f(165), f(30))]);
    for (cut, o, i) in [(90, 0, 1), (180, 1, 2)] {
        let e = t.tracks[0].video_entries(f(cut), fd());
        let ids: Vec<_> = e.items.iter().map(|(c, _)| c.id).collect();
        assert!(e.pair.is_some() && ids == vec![cs[o].id, cs[i].id], "no pair at frame {cut}");
        assert!(e.items.iter().all(|(_, w)| *w > 0.0 && *w < 1.0), "no mix at frame {cut}");
    }
}
