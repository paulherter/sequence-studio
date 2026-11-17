//! Finding media by the words spoken in them.
// Swift: Project+SpokenSearch.swift

use std::collections::BTreeSet;

use sq_core_model::Project;
use sq_core_time::{Id, text_search};

/// Swift `Project.mediaIDs(spoken:)`.
pub trait ProjectSpokenSearchExt {
    /// Media whose spoken words contain `text` (case and diacritic insensitive). Media carry no transcript of their own:
    /// the words are the caption items that sit over a clip of that media in any sequence. Empty text = none.
    // Only media already captioned in a sequence are found (the project stores no transcript per media).
    fn media_ids_spoken(&self, text: &str) -> BTreeSet<Id>;
}

impl ProjectSpokenSearchExt for Project {
    fn media_ids_spoken(&self, text: &str) -> BTreeSet<Id> {
        // Swift trims spaces and tabs only (`.whitespaces`).
        let q = text.trim_matches([' ', '\t', '\u{a0}']);
        let mut found = BTreeSet::new();
        if q.is_empty() {
            return found;
        }
        for tl in &self.timelines {
            let hits: Vec<_> = tl
                .caption_tracks
                .iter()
                .flat_map(|t| t.items())
                .filter(|i| !text_search::matches(&i.lines.join("\n"), q, false, false).is_empty())
                .map(|i| i.range)
                .collect();
            if hits.is_empty() {
                continue;
            }
            for track in &tl.tracks {
                for c in track.clips() {
                    if c.is_nested() || c.is_generator() || found.contains(&c.media) {
                        continue;
                    }
                    let r = c.timeline();
                    if hits.iter().any(|h| h.start < r.end() && r.start < h.end()) {
                        found.insert(c.media);
                    }
                }
            }
        }
        found
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{
        CaptionItem, CaptionTrack, Clip, MediaFingerprint, MediaRef, SequenceFormat, Timeline, Track, TrackKind,
    };
    use sq_core_time::{SequentialIds, Time, TimeRange};

    fn project() -> (Project, Id, Id) {
        let mut ids = SequentialIds::default();
        let mk = |n: u128, name: &str| MediaRef::new(Id::from_u128(n), name, "/x", MediaFingerprint::new(1));
        let (a, b) = (mk(10, "A001"), mk(11, "B002"));
        let mut v = Track::new(Id::from_u128(20), TrackKind::Video);
        for (m, start) in [(a.id, 0), (b.id, 10)] {
            let c = Clip::new(
                Id::from_u128(30 + start as u128),
                "c",
                m,
                TrackKind::Video,
                TimeRange::new(Time::ZERO, Time::new(10, 1)),
                Time::new(start, 1),
            );
            v.overwrite(c, &mut ids).unwrap();
        }
        let mut tl = Timeline::new(Id::from_u128(40), "S", SequenceFormat::new(Time::new(1, 30)), vec![v]);
        let item = CaptionItem {
            id: Id::from_u128(50),
            lines: vec!["Das ist ein Café".into()],
            range: TimeRange::new(Time::new(12, 1), Time::new(2, 1)),
            style_ref: String::new(),
            animation_ref: String::new(),
            style_overridden: false,
            words: vec![],
            position: None,
        };
        let ct = serde_json::from_value::<CaptionTrack>(serde_json::json!({
            "id": "00000000-0000-0000-0000-000000000060", "name": "C", "isLocked": false, "syncLock": true,
            "items": [serde_json::to_value(item).unwrap()]
        }))
        .unwrap();
        tl.caption_tracks = vec![ct];
        let (ia, ib) = (a.id, b.id);
        (Project::new(Id::from_u128(70), "P", vec![a, b], vec![tl]), ia, ib)
    }

    #[test]
    fn finds_media_under_matching_caption() {
        let (p, a, b) = project();
        assert_eq!(p.media_ids_spoken("cafe"), BTreeSet::from([b]));
        assert!(p.media_ids_spoken(" ").is_empty());
        assert!(p.media_ids_spoken("nope").is_empty());
        assert!(!p.media_ids_spoken("cafe").contains(&a));
    }
}
