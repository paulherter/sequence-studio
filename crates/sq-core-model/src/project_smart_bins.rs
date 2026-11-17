// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Project+SmartBins.swift, MediaFilterTokens.swift (saved types, moved down; matching and edits: task M-4)

use crate::{LabelColor, Project};
use serde::{Deserialize, Serialize};
use sq_core_time::{Id, Time, TimeRange};

/// Which part of the media list a smart bin shows by use.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SmartBinUsage {
    /// Used and unused.
    Any,
    /// Used in a sequence.
    Used,
    /// Not used.
    Unused,
}

/// Which kind of media a smart bin shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SmartBinKind {
    /// Everything.
    Any,
    /// Picture.
    Video,
    /// Sound.
    Audio,
    /// Still images.
    Image,
}

/// The key of a filter token in the media search field (Swift `MediaFilterToken.Key`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum MediaFilterKey {
    /// `cam:`.
    #[serde(rename = "cam")]
    Camera,
    /// `fps:`.
    #[serde(rename = "fps")]
    Fps,
    /// `day:`.
    #[serde(rename = "day")]
    Day,
    /// `label:`.
    #[serde(rename = "label")]
    Label,
    /// `kind:`.
    #[serde(rename = "kind")]
    Kind,
    /// `used` / `unused`.
    #[serde(rename = "usage")]
    Usage,
}

/// One filter token of the media search field.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct MediaFilterToken {
    /// What the token filters on.
    pub key: MediaFilterKey,
    /// The value to match.
    pub value: String,
}

/// A saved search of the project panel.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SmartBin {
    /// Identity.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// Text the name must contain.
    pub text: String,
    /// Used or unused media.
    pub usage: SmartBinUsage,
    /// Kind of media.
    pub kind: SmartBinKind,
    /// Only media that is offline.
    pub offline_only: bool,
    /// Only media with this label.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<LabelColor>,
    /// Filter tokens, when any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokens: Option<Vec<MediaFilterToken>>,
    /// Also search the spoken words.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub searches_spoken: Option<bool>,
}

impl Project {
    /// The saved smart bins (absent = none).
    pub fn smart_bin_list(&self) -> &[SmartBin] {
        self.smart_bins.as_deref().unwrap_or_default()
    }

    /// The smart bin with `id`.
    pub fn smart_bin(&self, id: Id) -> Option<&SmartBin> {
        self.smart_bin_list().iter().find(|b| b.id == id)
    }

    /// Adds a smart bin; an empty name is refused.
    pub fn add_smart_bin(&mut self, bin: SmartBin) -> bool {
        if bin.name.trim_matches([' ', '\t', '\u{a0}']).is_empty() {
            return false;
        }
        self.smart_bins.get_or_insert_with(Vec::new).push(bin);
        true
    }

    /// Replaces the smart bin with the same id; an empty name and an unknown id are refused.
    pub fn update_smart_bin(&mut self, bin: SmartBin) -> bool {
        if bin.name.trim_matches([' ', '\t', '\u{a0}']).is_empty() {
            return false;
        }
        match self.smart_bins.as_mut().and_then(|l| l.iter_mut().find(|b| b.id == bin.id)) {
            Some(slot) => {
                *slot = bin;
                true
            }
            None => false,
        }
    }

    /// Removes the smart bin; the key goes away with the last one.
    pub fn remove_smart_bin(&mut self, id: Id) -> bool {
        let Some(list) = self.smart_bins.as_mut() else { return false };
        let Some(i) = list.iter().position(|b| b.id == id) else { return false };
        list.remove(i);
        if list.is_empty() {
            self.smart_bins = None;
        }
        true
    }

    /// How many clips in all sequences play `media` (nested sequences and generators do not count): "11 uses".
    pub fn use_count(&self, media: Id) -> usize {
        self.timelines
            .iter()
            .flat_map(|t| t.tracks.iter())
            .flat_map(|tr| tr.clips())
            .filter(|c| c.media == media && !c.is_nested() && !c.is_generator())
            .count()
    }

    /// Fraction (0...1) of the media's duration that sequence clips use, ranges merged. 0 = unused, `None` = unknown length.
    pub fn used_fraction(&self, media: Id) -> Option<f64> {
        let total = self.media(media)?.duration.filter(|d| *d > Time::ZERO)?;
        let mut ranges: Vec<TimeRange> = Vec::new();
        for t in &self.timelines {
            for tr in &t.tracks {
                for c in tr.clips() {
                    if c.media == media && !c.is_nested() && !c.is_generator() && !c.source.is_empty() {
                        ranges.push(c.source);
                    }
                }
            }
        }
        if ranges.is_empty() {
            return Some(0.0);
        }
        ranges.sort_by_key(|r| r.start);
        let mut covered = Time::ZERO;
        let mut cur = ranges[0];
        for r in &ranges[1..] {
            if r.start <= cur.end() {
                if r.end() > cur.end() {
                    cur = TimeRange::from_end(cur.start, r.end());
                }
            } else {
                covered += cur.duration;
                cur = *r;
            }
        }
        covered += cur.duration;
        let secs = |t: Time| t.value() as f64 / t.timescale() as f64;
        Some((secs(covered) / secs(total)).clamp(0.0, 1.0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_info::assert_round_trip;
    use serde_json::json;

    fn bin(n: u128, name: &str) -> SmartBin {
        SmartBin {
            id: Id::from_u128(n),
            name: name.to_string(),
            text: String::new(),
            usage: SmartBinUsage::Any,
            kind: SmartBinKind::Any,
            offline_only: false,
            label: None,
            tokens: None,
            searches_spoken: None,
        }
    }

    #[test]
    fn smart_bin_verbs_add_update_remove() {
        let mut p = Project::new(Id::from_u128(9), "P", Vec::new(), Vec::new());
        assert!(!p.add_smart_bin(bin(1, "  ")));
        assert!(p.add_smart_bin(bin(1, "A")));
        assert!(p.add_smart_bin(bin(2, "B")));
        assert!(!p.update_smart_bin(bin(3, "C")));
        assert!(!p.update_smart_bin(bin(1, " ")));
        assert!(p.update_smart_bin(bin(1, "A2")));
        assert_eq!(p.smart_bin(Id::from_u128(1)).map(|b| b.name.as_str()), Some("A2"));
        assert!(p.remove_smart_bin(Id::from_u128(1)));
        assert!(p.remove_smart_bin(Id::from_u128(2)));
        assert!(p.smart_bins.is_none());
        assert!(!p.remove_smart_bin(Id::from_u128(2)));
    }

    #[test]
    fn used_fraction_is_unknown_without_a_length_and_zero_when_unused() {
        use crate::{MediaFingerprint, MediaRef};
        let mut p = Project::new(Id::from_u128(9), "P", Vec::new(), Vec::new());
        let mut m = MediaRef::new(Id::from_u128(1), "a.mov", "/a.mov", MediaFingerprint::new(1));
        p.add(m.clone());
        assert_eq!(p.used_fraction(Id::from_u128(1)), None);
        m.duration = Some(Time::new(10, 1));
        p.media[0] = m;
        assert_eq!(p.used_fraction(Id::from_u128(1)), Some(0.0));
        assert_eq!(p.used_fraction(Id::from_u128(2)), None);
        assert_eq!(p.use_count(Id::from_u128(1)), 0);
    }

    #[test]
    fn smart_bin_round_trips() {
        let bin = json!({"id": "00000000-0000-0000-0000-000000000001", "name": "Used", "text": "", "usage": "used",
                         "kind": "any", "offlineOnly": false});
        assert_round_trip::<SmartBin>(bin.clone());
        let mut full = bin;
        full["label"] = json!("rose");
        full["tokens"] = json!([{"key": "cam", "value": "FX3"}, {"key": "usage", "value": "used"}]);
        full["searchesSpoken"] = json!(true);
        assert_round_trip::<SmartBin>(full);
    }
}
