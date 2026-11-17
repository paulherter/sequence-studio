// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: PRImportResult+Canonical.swift. The result as sorted-key JSON with every UUID replaced by its
//! first-appearance number (`#0`, `#1`, ...): two maps of the same document give the same string although each run
//! draws fresh ids. For differential tests and the import probe.

use crate::prmapper::PRImportResult;
use std::collections::HashMap;

impl PRImportResult {
    /// Sorted-key JSON of project and report, ids renumbered.
    pub fn canonical_json(&self) -> String {
        // `serde_json::Value` objects are `BTreeMap`s here (no `preserve_order`), so keys come out sorted.
        let enc = |v: Result<serde_json::Value, serde_json::Error>| {
            v.ok().and_then(|v| serde_json::to_string(&v).ok()).unwrap_or_else(|| "?".to_string())
        };
        let p = enc(serde_json::to_value(&self.project));
        let r = enc(serde_json::to_value(&self.report));
        renumber_uuids(&format!("{p}\n{r}"))
    }

    /// Stable 64-bit FNV-1a of `canonical_json()`, hex.
    pub fn canonical_digest(&self) -> String {
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for b in self.canonical_json().bytes() {
            h = (h ^ u64::from(b)).wrapping_mul(0x100_0000_01b3);
        }
        format!("{h:x}")
    }
}

/// Matches `8-4-4-4-12` hex at the start of `b`.
fn uuid_len_at(b: &[u8]) -> bool {
    const GROUPS: [usize; 5] = [8, 4, 4, 4, 12];
    let mut p = 0;
    for (gi, g) in GROUPS.iter().enumerate() {
        if gi > 0 {
            if b.get(p) != Some(&b'-') {
                return false;
            }
            p += 1;
        }
        for _ in 0..*g {
            if !b.get(p).is_some_and(u8::is_ascii_hexdigit) {
                return false;
            }
            p += 1;
        }
    }
    true
}

pub(crate) fn renumber_uuids(s: &str) -> String {
    let b = s.as_bytes();
    let mut seen: HashMap<String, usize> = HashMap::new();
    let mut out = String::new();
    let (mut last, mut i) = (0, 0);
    while i + 36 <= b.len() {
        if uuid_len_at(&b[i..]) {
            out.push_str(&s[last..i]);
            let u = s[i..i + 36].to_ascii_uppercase();
            let next = seen.len();
            let n = *seen.entry(u).or_insert(next);
            out.push_str(&format!("#{n}"));
            i += 36;
            last = i;
        } else {
            i += 1;
        }
    }
    out.push_str(&s[last..]);
    out
}

#[cfg(test)]
mod tests {
    use super::renumber_uuids;

    #[test]
    fn same_ids_get_the_same_number_in_order_of_appearance() {
        let a = "x 00000000-0000-0000-0000-00000000000A y 00000000-0000-0000-0000-00000000000b z 00000000-0000-0000-0000-00000000000a";
        assert_eq!(renumber_uuids(a), "x #0 y #1 z #0");
    }
}
