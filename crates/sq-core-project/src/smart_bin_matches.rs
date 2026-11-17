// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: Project+SmartBins.swift (`SmartBin.matches`; the type and the `Project` verbs live in sq-core-model)

//! Whether a media item passes the rules of a smart bin.

use std::collections::BTreeSet;

use crate::media_filter_tokens::{Calendar, MediaFilterQuery};
use sq_core_model::{MediaKind, MediaRef, SmartBin, SmartBinKind, SmartBinUsage};
use sq_core_time::text::ci_contains;
use sq_core_time::{Id, Timestamp};

/// `SmartBin.matches`.
pub trait SmartBinMatchExt {
    /// Whether `media` passes the rules. `is_used` and `is_offline` come from the caller (offline needs the file system);
    /// `spoken` is the set of media whose spoken words contain the text.
    fn matches(
        &self,
        media: &MediaRef,
        is_used: bool,
        is_offline: bool,
        spoken: &BTreeSet<Id>,
        now: Timestamp,
        calendar: &dyn Calendar,
    ) -> bool;
}

impl SmartBinMatchExt for SmartBin {
    fn matches(
        &self,
        media: &MediaRef,
        is_used: bool,
        is_offline: bool,
        spoken: &BTreeSet<Id>,
        now: Timestamp,
        calendar: &dyn Calendar,
    ) -> bool {
        let q = self.text.trim_matches([' ', '\t', '\u{a0}']);
        if !q.is_empty()
            && !ci_contains(&media.name, q)
            && !(self.searches_spoken == Some(true) && spoken.contains(&media.id))
        {
            return false;
        }
        match self.usage {
            SmartBinUsage::Any => {}
            SmartBinUsage::Used if !is_used => return false,
            SmartBinUsage::Unused if is_used => return false,
            _ => {}
        }
        if self.offline_only && !is_offline {
            return false;
        }
        if self.label.is_some() && media.label != self.label {
            return false;
        }
        if let Some(tokens) = self.tokens.as_ref().filter(|t| !t.is_empty()) {
            let query = MediaFilterQuery { text: String::new(), tokens: tokens.clone() };
            if !query.matches(media, is_used, now, calendar) {
                return false;
            }
        }
        matches!(
            (self.kind, media.kind()),
            (SmartBinKind::Any, _)
                | (SmartBinKind::Video, MediaKind::Video | MediaKind::VideoAudio)
                | (SmartBinKind::Audio, MediaKind::Audio)
                | (SmartBinKind::Image, MediaKind::Image)
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::media_filter_tokens::FixedOffsetCalendar;
    use sq_core_model::MediaFingerprint;

    fn bin() -> SmartBin {
        SmartBin {
            id: Id::from_u128(1),
            name: "B".to_string(),
            text: String::new(),
            usage: SmartBinUsage::Any,
            kind: SmartBinKind::Any,
            offline_only: false,
            label: None,
            tokens: None,
            searches_spoken: None,
        }
    }

    fn check(b: &SmartBin, m: &MediaRef, used: bool, offline: bool, spoken: &BTreeSet<Id>) -> bool {
        b.matches(m, used, offline, spoken, Timestamp::from_unix_seconds(0.0), &FixedOffsetCalendar::default())
    }

    #[test]
    fn name_usage_offline_and_spoken_rules() {
        let m = MediaRef::new(Id::from_u128(5), "Interview A.mov", "/a.mov", MediaFingerprint::new(1));
        let none = BTreeSet::new();
        let mut b = bin();
        assert!(check(&b, &m, false, false, &none));
        b.text = " interview ".to_string();
        assert!(check(&b, &m, false, false, &none));
        b.text = "boom".to_string();
        assert!(!check(&b, &m, false, false, &none));
        b.searches_spoken = Some(true);
        assert!(check(&b, &m, false, false, &BTreeSet::from([m.id])));
        b.text = String::new();
        b.usage = SmartBinUsage::Used;
        assert!(!check(&b, &m, false, false, &none));
        assert!(check(&b, &m, true, false, &none));
        b.usage = SmartBinUsage::Any;
        b.offline_only = true;
        assert!(!check(&b, &m, false, false, &none));
        assert!(check(&b, &m, false, true, &none));
    }
}
