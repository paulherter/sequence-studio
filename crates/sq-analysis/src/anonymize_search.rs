// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AnonymizeSearch.swift (the `canImport(Vision)` extension `Anonymizer.findEveryone` is Mac-only and not ported)
//! Anonymize search across a clip: people who enter later are found by looking at several frames, and the sightings of the
//! same person on neighboring frames are linked into one entry (so a walking person is listed once, not once per frame).
use sq_core_masks::anonymize::AnonymizePerson;
use sq_core_time::Vec2;
use std::cmp::Ordering;

/// One person to follow: where and when they are picked.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AnonymizeSighting {
    /// The person.
    pub person: AnonymizePerson,
    /// Source seconds of the frame they are picked on.
    pub pts: f64,
    /// Source seconds of the first sampled frame that shows them.
    pub first_seen: f64,
}

/// Searching a clip for everyone.
pub struct AnonymizeSearch;

fn distance(a: Vec2, b: Vec2) -> f64 {
    ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).sqrt()
}

fn cmp(a: f64, b: f64) -> Ordering {
    a.partial_cmp(&b).unwrap_or(Ordering::Equal)
}

impl AnonymizeSearch {
    /// Frames looked at: the anchor and evenly spaced frames across `first...last` at about `interval` seconds, at most
    /// `max_count` in total (the spacing widens for a long clip). Ascending, no duplicates.
    pub fn sample_times(first: f64, last: f64, anchor: f64, interval: f64, max_count: i64) -> Vec<f64> {
        let lo = first.min(last);
        let hi = first.max(last);
        let a = anchor.max(lo).min(hi);
        if !(hi - lo > 1e-6 && max_count > 1 && interval > 0.0) {
            return vec![a];
        }
        let steps = (((hi - lo) / interval).ceil() as i64).max(1).min(max_count - 1);
        let mut times: Vec<f64> = (0..=steps).map(|i| lo + (hi - lo) * i as f64 / steps as f64).collect();
        // The anchor replaces the nearest even sample so it is always one of the frames.
        let mut nearest = 0;
        for i in 1..times.len() {
            if (times[i] - a).abs() < (times[nearest] - a).abs() {
                nearest = i;
            }
        }
        times[nearest] = a;
        times.sort_by(|x, y| cmp(*x, *y));
        times.dedup();
        times
    }

    /// `sample_times` with the defaults of the Swift signature: every 0.5 s, at most 24 frames.
    pub fn default_sample_times(first: f64, last: f64, anchor: f64) -> Vec<f64> {
        Self::sample_times(first, last, anchor, 0.5, 24)
    }

    /// Links the people of consecutive sampled frames: a person whose box center is within `reach` (frame fractions) of an
    /// open chain's last sighting continues it. One sighting per chain: the frame at `anchor` when they are on it, else
    /// the largest box. Ordered by first appearance, then left to right.
    pub fn link(samples: &[(f64, Vec<AnonymizePerson>)], anchor: f64, reach: f64) -> Vec<AnonymizeSighting> {
        let mut chains: Vec<Vec<(f64, AnonymizePerson)>> = Vec::new();
        let mut open: Vec<usize> = Vec::new(); // chains seen on the previous sample
        let mut ordered: Vec<&(f64, Vec<AnonymizePerson>)> = samples.iter().collect();
        ordered.sort_by(|a, b| cmp(a.0, b.0));
        for sample in ordered {
            let mut free = open.clone();
            let mut next: Vec<usize> = Vec::new();
            let mut people: Vec<&AnonymizePerson> = sample.1.iter().collect();
            people.sort_by(|a, b| cmp(a.box_.center().x, b.box_.center().x));
            for p in people {
                let c = p.box_.center();
                let last_center = |i: usize| chains[i].last().map(|l| l.1.box_.center()).unwrap_or(Vec2::ZERO);
                let mut best: Option<usize> = None;
                for &i in &free {
                    if best.is_none_or(|b| distance(last_center(i), c) < distance(last_center(b), c)) {
                        best = Some(i);
                    }
                }
                if let Some(b) = best
                    && distance(last_center(b), c) <= reach
                {
                    chains[b].push((sample.0, *p));
                    free.retain(|&i| i != b);
                    next.push(b);
                } else {
                    chains.push(vec![(sample.0, *p)]);
                    next.push(chains.len() - 1);
                }
            }
            open = next;
        }
        let mut out: Vec<AnonymizeSighting> = chains
            .iter()
            .filter(|chain| !chain.is_empty())
            .map(|chain| {
                let at_anchor = chain.iter().find(|c| (c.0 - anchor).abs() < 1e-6);
                let area = |c: &(f64, AnonymizePerson)| c.1.box_.width * c.1.box_.height;
                // Swift's `max(by:)` keeps the first of equal maxima.
                let largest =
                    chain.iter().skip(1).fold(&chain[0], |best, c| if area(best) < area(c) { c } else { best });
                let pick = at_anchor.unwrap_or(largest);
                AnonymizeSighting { person: pick.1, pts: pick.0, first_seen: chain[0].0 }
            })
            .collect();
        out.sort_by(|a, b| {
            cmp(a.first_seen, b.first_seen).then(cmp(a.person.box_.center().x, b.person.box_.center().x))
        });
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_masks::anonymize::AnonymizeBox;

    fn person(cx: f64, size: f64) -> AnonymizePerson {
        AnonymizePerson {
            label: 1,
            point: Vec2::new(cx, 0.5),
            box_: AnonymizeBox { x: cx - size / 2.0, y: 0.4, width: size, height: size },
            face: None,
        }
    }

    fn link(samples: &[(f64, Vec<AnonymizePerson>)], anchor: f64) -> Vec<AnonymizeSighting> {
        AnonymizeSearch::link(samples, anchor, 0.2)
    }

    #[test]
    fn sample_times_include_the_anchor_and_respect_the_cap() {
        let t = AnonymizeSearch::sample_times(0.0, 10.0, 3.3, 0.5, 8);
        assert!(t.len() <= 8);
        assert!(t.contains(&3.3));
        assert!(t.windows(2).all(|w| w[0] < w[1]));
        assert_eq!(AnonymizeSearch::default_sample_times(2.0, 2.0, 2.0), vec![2.0]);
        assert!(AnonymizeSearch::default_sample_times(0.0, 1.0, 5.0).contains(&1.0));
    }

    #[test]
    fn a_person_walking_across_frames_is_one_entry() {
        let s =
            link(&[(0.0, vec![person(0.1, 0.2)]), (0.5, vec![person(0.25, 0.2)]), (1.0, vec![person(0.4, 0.2)])], 0.5);
        assert_eq!(s.len(), 1);
        assert!(s[0].pts == 0.5 && s[0].first_seen == 0.0);
    }

    #[test]
    fn a_person_who_enters_later_is_added_with_their_own_frame() {
        let s = link(
            &[
                (0.0, vec![person(0.2, 0.2)]),
                (1.0, vec![person(0.2, 0.2)]),
                (2.0, vec![person(0.2, 0.2), person(0.8, 0.3)]),
                (3.0, vec![person(0.2, 0.2), person(0.8, 0.4)]),
            ],
            0.0,
        );
        assert_eq!(s.len(), 2);
        assert!(s[0].first_seen == 0.0 && s[0].pts == 0.0);
        assert!(s[1].first_seen == 2.0 && s[1].pts == 3.0); // not on the anchor frame: the largest box
    }

    #[test]
    fn a_jump_beyond_reach_is_another_person() {
        assert_eq!(link(&[(0.0, vec![person(0.1, 0.2)]), (0.5, vec![person(0.9, 0.2)])], 0.0).len(), 2);
        assert!(link(&[(0.0, vec![])], 0.0).is_empty());
    }
}
