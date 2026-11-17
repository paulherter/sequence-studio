// Swift: KeystoneLibrary.swift
//! G1 Keystones in the user library: the built-ins plus the user's `.keystone` presets. A user preset with a built-in's id
//! is that built-in edited (its own curve, say) and replaces it in place; deleting the preset restores the built-in.

use crate::preset_store::{PresetItem, PresetKind};
use sq_core_effects::keystone::Keystone;
use sq_core_time::{Id, Timestamp, text::standard_compare};
use std::collections::HashMap;

/// Built-ins (in their order, overridden where saved) then the user's own, by name. Unreadable payloads are skipped.
pub fn keystones(presets: &[PresetItem]) -> Vec<Keystone> {
    let mut saved: HashMap<Id, Keystone> = HashMap::new();
    let mut own: Vec<Keystone> = Vec::new();
    for item in presets.iter().filter(|i| i.kind == PresetKind::Keystone) {
        let Ok(mut k) = Keystone::from_payload(&item.payload, item.payload_version) else { continue };
        k.id = item.id;
        k.name.clone_from(&item.name);
        if k.is_built_in() {
            saved.insert(k.id, k);
        } else {
            own.push(k);
        }
    }
    own.sort_by(|a, b| standard_compare(&a.name, &b.name));
    // A hidden built-in (hidden_catalog) is not listed, unless the user edited it: then it is theirs.
    let mut out: Vec<Keystone> = Keystone::built_ins()
        .into_iter()
        .filter_map(|b| match saved.remove(&b.id) {
            Some(edited) => Some(edited),
            None => (!Keystone::is_hidden(b.id)).then_some(b),
        })
        .collect();
    out.extend(own);
    out
}

/// One keystone by id: the user's own, a built-in with its saved changes, or the plain built-in, hidden or not. Never
/// `None` for a built-in id, so a reference that outlives the list entry (deleted changes of a hidden built-in) still resolves.
pub fn keystone(id: Id, presets: &[PresetItem]) -> Option<Keystone> {
    keystones(presets)
        .into_iter()
        .find(|k| k.id == id)
        .or_else(|| Keystone::built_ins().into_iter().find(|k| k.id == id))
}

/// A built-in that has a saved override.
pub fn is_customised(id: Id, presets: &[PresetItem]) -> bool {
    presets.iter().any(|p| p.kind == PresetKind::Keystone && p.id == id)
}

/// The preset that stores `keystone` (same id, so saving again updates it).
pub fn preset_item(keystone: &Keystone, created_at: Timestamp) -> Result<PresetItem, serde_json::Error> {
    Ok(PresetItem::new(
        keystone.id,
        PresetKind::Keystone,
        &keystone.name,
        created_at,
        keystone.payload()?,
        keystone.written_payload_version(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::folder_scanner::test_dir::TempDir;
    use crate::preset_store::{PresetFile, PresetFileError, PresetStore};
    use sq_core_effects::keystone::KeystoneAnchor;
    use sq_core_time::{EasingCurve, Keyframe, KeyframeTrack, SequentialIds, Time};

    const NOW: Timestamp = Timestamp::from_reference_seconds(800_000_000.0);

    fn mine(name: &str) -> Keystone {
        let mut k = Keystone::new(Id::from_u128(0xABCDEF), name, Time::new(1, 1), KeystoneAnchor::Free);
        k.rotation = Some(KeyframeTrack::with_keys(vec![
            Keyframe::new(Id::from_u128(1), Time::ZERO, 0.0),
            Keyframe::new(Id::from_u128(2), Time::new(1, 1), 45.0),
        ]));
        k
    }

    fn shown() -> Vec<Keystone> {
        Keystone::built_ins().into_iter().filter(|b| !Keystone::is_hidden(b.id)).collect()
    }

    fn ids(list: &[Keystone]) -> Vec<Id> {
        list.iter().map(|k| k.id).collect()
    }

    fn punch_edited() -> Keystone {
        let mut punch = Keystone::built_in_named("Punch In").unwrap_or_else(|| panic!("Punch In"));
        punch.easing = Some(EasingCurve::ease_in_out());
        punch
    }

    fn item(k: &Keystone) -> PresetItem {
        preset_item(k, NOW).unwrap_or_else(|e| panic!("{e}"))
    }

    #[test]
    fn hidden_built_ins_are_not_listed_unless_the_user_edited_them() {
        assert_eq!(ids(&keystones(&[])), ids(&shown()));
        let punch = punch_edited();
        let edited = ids(&keystones(&[item(&punch)]));
        let mut expected = ids(&shown());
        if !expected.contains(&punch.id) {
            expected.push(punch.id);
        }
        assert!(edited.contains(&punch.id));
        let (mut a, mut b) = (edited.clone(), expected);
        a.sort();
        b.sort();
        assert_eq!(a, b);
    }

    #[test]
    fn deleting_the_changes_of_a_hidden_built_in_reverts_it_without_a_dangling_entry() {
        let punch = punch_edited();
        let saved = [item(&punch)];
        assert_eq!(keystone(punch.id, &saved).map(|k| k.easing), Some(punch.easing.clone()));
        let after_delete: Vec<PresetItem> = saved.iter().filter(|p| p.id != punch.id).cloned().collect();
        assert_eq!(ids(&keystones(&after_delete)), ids(&keystones(&[])));
        assert!(!is_customised(punch.id, &after_delete));
        let plain = Keystone::built_in_named("Punch In");
        assert_eq!(keystone(punch.id, &after_delete), plain);
        assert_eq!(keystone(Id::from_u128(42), &after_delete), None);
    }

    #[test]
    fn built_ins_come_first_then_user_keystones() {
        let k = mine("Mine");
        let items = [item(&k)];
        let all = keystones(&items);
        let shown = shown();
        assert_eq!(ids(&all[..shown.len()]), ids(&shown));
        assert_eq!(all.last(), Some(&k));
        assert_eq!((items[0].kind, items[0].id, items[0].name.as_str()), (PresetKind::Keystone, k.id, "Mine"));
    }

    #[test]
    fn saved_built_in_replaces_it_in_place() {
        let punch = punch_edited();
        let all = keystones(&[item(&punch)]);
        let extra = usize::from(Keystone::is_hidden(punch.id));
        assert_eq!(all.len(), shown().len() + extra);
        assert_eq!(all.iter().find(|k| k.id == punch.id).map(|k| k.easing.clone()), Some(punch.easing.clone()));
        assert!(is_customised(punch.id, &[item(&punch)]));
    }

    #[test]
    fn other_kinds_and_damaged_payloads_are_skipped() {
        let junk = PresetItem::new(Id::from_u128(1), PresetKind::Keystone, "bad", NOW, b"{}".to_vec(), 1);
        let other = PresetItem::new(Id::from_u128(2), PresetKind::Effect, "fx", NOW, b"{}".to_vec(), 1);
        assert_eq!(keystones(&[junk, other]).len(), shown().len());
    }

    #[test]
    fn keystone_round_trips_through_preset_file() {
        let k = mine("Spin");
        let file = PresetFile::encode(&item(&k)).unwrap_or_default();
        let back = PresetFile::decode(&file, &mut SequentialIds::default(), NOW).unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(back.kind, PresetKind::Keystone);
        let decoded = Keystone::from_payload(&back.payload, back.payload_version).ok();
        assert_eq!(decoded.as_ref().map(|d| (d.duration, d.rotation.clone())), Some((k.duration, k.rotation.clone())));
    }

    #[test]
    fn damaged_keystone_file_is_rejected() {
        let file = format!(
            r#"{{"format":"{}","formatVersion":1,"kind":"keystone","name":"x","payloadVersion":1,"payload":{{"nope":1}}}}"#,
            PresetFile::FORMAT_NAME
        );
        let result = PresetFile::decode(file.as_bytes(), &mut SequentialIds::default(), NOW);
        assert_eq!(result, Err(PresetFileError::DamagedPayload));
    }

    #[test]
    fn store_keeps_keystones() {
        let dir = TempDir::new();
        let mut store = PresetStore::open(dir.path(), false, NOW).unwrap_or_else(|e| panic!("{e}"));
        assert!(store.add(item(&mine("Mine"))).is_ok());
        let reopened = PresetStore::open(dir.path(), false, NOW).unwrap_or_else(|e| panic!("{e}"));
        let list = keystones(&reopened.presets(Some(PresetKind::Keystone), ""));
        assert_eq!(list.last().map(|k| k.name.as_str()), Some("Mine"));
    }
}
