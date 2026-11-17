// SPDX-License-Identifier: GPL-3.0-or-later
//! Scores found files against offline media.
// Swift: RelinkScoring.swift
//
// `ProjectHealth::make` takes the "is this path inside the project folder" test as an argument: `MediaManagement.isInside`
// and `projectFolder(forProjectAt:)` touch the disk and are not part of this port yet.

use crate::media_path_resolver::MediaPathResolver;
use crate::relink::RelinkCandidate;
use sq_core_model::MediaRef;
use sq_core_time::{Id, Time};
use std::collections::BTreeSet;

/// The signals that agree between an offline item and a found file (Swift `OptionSet`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct Signals(u8);

impl Signals {
    /// Same file name (case-insensitive).
    pub const NAME: Signals = Signals(1);
    /// Same name once a copy suffix ("intro (1)", "intro copy") is removed.
    pub const SIMILAR_NAME: Signals = Signals(2);
    /// Same size.
    pub const SIZE: Signals = Signals(4);
    /// Same length.
    pub const DURATION: Signals = Signals(8);
    /// Same modification date.
    pub const MODIFIED: Signals = Signals(16);
    /// Trailing folder names agree (Day2/ stays Day2/).
    pub const FOLDERS: Signals = Signals(32);

    /// No signal.
    pub const EMPTY: Signals = Signals(0);

    /// Every signal of `other` is set.
    pub const fn contains(self, other: Signals) -> bool {
        self.0 & other.0 == other.0
    }

    /// Sets the signals of `other`.
    pub fn insert(&mut self, other: Signals) {
        self.0 |= other.0;
    }
}

/// Strong matches start ticked; weak ones are shown, never applied by themselves.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Tier {
    /// Safe to apply.
    Strong,
    /// The user ticks it on purpose.
    Weak,
}

/// One proposed match of an offline media item to a found file, with the signals that agree.
#[derive(Clone, Debug, PartialEq)]
pub struct RelinkProposal {
    /// The offline item (also the proposal's identity).
    pub media_id: Id,
    /// The found file.
    pub path: String,
    /// Points of the match.
    pub score: i64,
    /// What agrees.
    pub signals: Signals,
    /// The recorded size is known and the found file has another size.
    pub size_differs: bool,
    /// Another file scored exactly the same for this item: the pick is stable but a guess.
    pub is_ambiguous: bool,
}

impl RelinkProposal {
    /// Strong when the score is high, the size agrees and the pick is not a guess.
    pub fn tier(&self) -> Tier {
        if self.score >= RelinkScorer::STRONG_SCORE && !self.size_differs && !self.is_ambiguous {
            Tier::Strong
        } else {
            Tier::Weak
        }
    }

    /// Only strong matches start ticked; the user ticks weak ones on purpose.
    pub fn is_checked(&self) -> bool {
        self.tier() == Tier::Strong
    }

    /// "name, size, length" for the checklist row.
    pub fn signal_text(&self) -> String {
        let s = self.signals;
        let mut parts: Vec<&str> = Vec::new();
        if s.contains(Signals::NAME) {
            parts.push("name");
        } else if s.contains(Signals::SIMILAR_NAME) {
            parts.push("similar name");
        }
        if s.contains(Signals::SIZE) {
            parts.push("size");
        }
        if s.contains(Signals::DURATION) {
            parts.push("length");
        }
        if s.contains(Signals::MODIFIED) {
            parts.push("date");
        }
        if s.contains(Signals::FOLDERS) {
            parts.push("folders");
        }
        if self.is_ambiguous {
            parts.push("several equal files");
        }
        parts.join(", ")
    }
}

/// What `RelinkScorer::propose` found.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct RelinkScorerResult {
    /// Best first (score, then item path), at most one per item and per file.
    pub proposals: Vec<RelinkProposal>,
    /// Items without a proposal.
    pub unmatched: Vec<Id>,
}

impl RelinkScorerResult {
    /// "Found 11 of 12 missing files".
    pub fn found_text(&self, total: usize) -> String {
        format!("Found {} of {} missing {}", self.proposals.len(), total, if total == 1 { "file" } else { "files" })
    }
}

/// Scores found files against offline media (name, size, length, modification date, folder structure) so equal-size
/// files are told apart by more signals, never by scan order, and a weak match is shown, not applied. Pure: the
/// caller scans the disk and probes lengths. (Recorded start timecode is not stored on `MediaRef`: not a signal yet.)
pub struct RelinkScorer;

struct Pair {
    m: usize,
    c: usize,
    score: i64,
    signals: Signals,
    size_differs: bool,
}

/// A hit of `RelinkScorer::score`.
struct Hit {
    points: i64,
    signals: Signals,
    size_differs: bool,
}

impl RelinkScorer {
    const STRONG_SCORE: i64 = 60;
    const WEAK_SCORE: i64 = 20;
    const DURATION_TOLERANCE: Time = Time::new(1, 25);

    /// Whether probing the length of `c` can matter: it shares a name stem or the size with an item.
    pub fn worth_probing(c: &RelinkCandidate, missing: &[MediaRef]) -> bool {
        let candidate_stem = Self::stem_of(&c.path);
        missing.iter().any(|m| {
            candidate_stem == Self::stem_of(&m.path) || (m.fingerprint.size > 0 && m.fingerprint.size == c.size)
        })
    }

    /// The best one-to-one matching of `missing` items to `candidates`.
    pub fn propose(missing: &[MediaRef], candidates: &[RelinkCandidate]) -> RelinkScorerResult {
        let mut per_item: Vec<Vec<Pair>> = Vec::new();
        for (mi, m) in missing.iter().enumerate() {
            let mut list = Vec::new();
            for (ci, c) in candidates.iter().enumerate() {
                if let Some(hit) = Self::score(m, c) {
                    list.push(Pair {
                        m: mi,
                        c: ci,
                        score: hit.points,
                        signals: hit.signals,
                        size_differs: hit.size_differs,
                    });
                }
            }
            per_item.push(list);
        }
        // An item is ambiguous when two different files tie for its best score.
        let mut ambiguous = BTreeSet::new();
        for (mi, list) in per_item.iter().enumerate() {
            if let Some(top) = list.iter().map(|p| p.score).max()
                && list.iter().filter(|p| p.score == top).count() > 1
            {
                ambiguous.insert(mi);
            }
        }
        let mut order: Vec<Pair> = per_item.into_iter().flatten().collect();
        order.sort_by(|a, b| {
            b.score
                .cmp(&a.score)
                .then_with(|| missing[a.m].path.cmp(&missing[b.m].path))
                .then_with(|| candidates[a.c].path.cmp(&candidates[b.c].path))
        });
        let mut used_items = BTreeSet::new();
        let mut used_files = BTreeSet::new();
        let mut out = RelinkScorerResult::default();
        for p in order {
            if used_items.contains(&p.m) || used_files.contains(&p.c) {
                continue;
            }
            used_items.insert(p.m);
            used_files.insert(p.c);
            out.proposals.push(RelinkProposal {
                media_id: missing[p.m].id,
                path: candidates[p.c].path.clone(),
                score: p.score,
                signals: p.signals,
                size_differs: p.size_differs,
                is_ambiguous: ambiguous.contains(&p.m),
            });
        }
        out.unmatched = (0..missing.len()).filter(|i| !used_items.contains(i)).map(|i| missing[i].id).collect();
        out
    }

    /// `None` when the file has nothing to do with the item.
    fn score(m: &MediaRef, c: &RelinkCandidate) -> Option<Hit> {
        let mut s = Signals::EMPTY;
        let mut points = 0;
        let want_name = MediaPathResolver::file_name_of(&m.path).to_lowercase();
        let have_name = MediaPathResolver::file_name_of(&c.path).to_lowercase();
        if want_name == have_name {
            s.insert(Signals::NAME);
            points += 40;
        } else if Self::stem_of(&m.path) == Self::stem_of(&c.path) {
            s.insert(Signals::SIMILAR_NAME);
            points += 20;
        }
        let known = m.fingerprint.size > 0 && c.size >= 0;
        let size_differs = known && m.fingerprint.size != c.size;
        if known && !size_differs {
            s.insert(Signals::SIZE);
            points += 30;
        }
        let want_duration = m.duration.or(m.info.as_ref().map(|i| i.duration));
        if let (Some(want), Some(have)) = (want_duration, c.duration) {
            let diff = if want > have { want - have } else { have - want };
            if diff <= Self::DURATION_TOLERANCE {
                s.insert(Signals::DURATION);
                points += 20;
            }
        }
        if let (Some(a), Some(b)) = (c.modified, m.fingerprint.modified)
            && (a.unix_seconds() - b.unix_seconds()).abs() < 1.0
        {
            s.insert(Signals::MODIFIED);
            points += 10;
        }
        let want: Vec<String> = MediaPathResolver::folders_of(&m.path).iter().map(|f| f.to_lowercase()).collect();
        let have: Vec<String> = MediaPathResolver::folders_of(&c.path).iter().map(|f| f.to_lowercase()).collect();
        let tail = have.iter().rev().zip(want.iter().rev()).take_while(|(a, b)| a == b).count();
        let head = have.iter().zip(want.iter()).take_while(|(a, b)| a == b).count();
        if tail > 0 {
            s.insert(Signals::FOLDERS);
        }
        points += i64::try_from(tail * 2 + head).unwrap_or(i64::MAX).min(10);
        // Some real link between the two: a name, or size and length together (a renamed copy).
        let linked = s.contains(Signals::NAME)
            || s.contains(Signals::SIMILAR_NAME)
            || (s.contains(Signals::SIZE) && s.contains(Signals::DURATION));
        if !linked || points < Self::WEAK_SCORE {
            return None;
        }
        Some(Hit { points, signals: s, size_differs })
    }

    /// File name without extension, lower-cased, copy suffixes removed: "Intro (1).mov", "intro copy.mov" -> "intro".
    pub(crate) fn stem_of(path: &str) -> String {
        let mut name = MediaPathResolver::file_name_of(path);
        if let Some(dot) = name.rfind('.').filter(|d| *d != 0) {
            name.truncate(dot);
        }
        let mut name = name.to_lowercase();
        let mut changed = true;
        while changed {
            changed = false;
            for suffix in [" - copy", " copy", "_copy"] {
                if name.ends_with(suffix) {
                    name.truncate(name.len() - suffix.len());
                    changed = true;
                }
            }
            if name.ends_with(')')
                && let Some(open) = name.rfind('(').filter(|o| *o != 0)
                && name[..open].ends_with(' ')
                && name[open + 1..name.len() - 1].parse::<i64>().is_ok()
            {
                name.truncate(open - 1);
                changed = true;
            }
        }
        name
    }
}

/// What the Library's health line shows: counts of media in the project folder, outside it, and offline.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ProjectHealth {
    /// Distinct files inside the project folder.
    pub in_folder: usize,
    /// Distinct files outside it.
    pub outside: usize,
    /// Offline items.
    pub missing: usize,
}

impl ProjectHealth {
    /// Nothing outside the folder and nothing offline.
    pub fn is_healthy(&self) -> bool {
        self.outside == 0 && self.missing == 0
    }

    /// Distinct files; offline items count as missing only. `is_inside` tells whether a path lies in the project folder;
    /// `None` (a project without a project folder) has no "outside". The test may touch the disk: call off the UI thread.
    pub fn make(media: &[MediaRef], offline: &BTreeSet<Id>, is_inside: Option<&dyn Fn(&str) -> bool>) -> ProjectHealth {
        let mut h = ProjectHealth::default();
        let Some(is_inside) = is_inside else {
            h.missing = media.iter().filter(|m| offline.contains(&m.id)).count();
            return h;
        };
        let mut seen = BTreeSet::new();
        for m in media {
            if offline.contains(&m.id) {
                h.missing += 1;
                continue;
            }
            if !seen.insert(m.path.as_str()) {
                continue;
            }
            if is_inside(&m.path) {
                h.in_folder += 1;
            } else {
                h.outside += 1;
            }
        }
        h
    }
}

#[cfg(test)]
mod tests;
