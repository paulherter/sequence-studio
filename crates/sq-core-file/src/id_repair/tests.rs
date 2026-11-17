// SPDX-License-Identifier: GPL-3.0-or-later

use super::*;
use serde_json::json;

fn project() -> Value {
    let (a, b, c) = ("00000000-0000-0000-0000-000000000015", "00000000-0000-0000-0000-000000000002", "x");
    json!({"timelines": [{"name": "S", "tracks": [
        {"id": b, "clips": [{"id": a, "n": 1}, {"id": a, "n": 2}]},
        {"id": b, "clips": [{"id": a, "n": 3, "futureKey": c}, {"id": "00000000-0000-0000-0000-000000000016"}]},
    ]}]})
}

#[test]
fn repeated_clip_and_track_ids_get_fresh_ones_and_the_first_holder_keeps_its_id() {
    let mut p = project();
    let notes = repair_duplicate_ids(&mut p);
    assert_eq!(notes.len(), 3, "{notes:?}");
    let t = &p["timelines"][0]["tracks"];
    assert_eq!(t[0]["clips"][0]["id"], "00000000-0000-0000-0000-000000000015");
    assert_eq!(t[0]["id"], "00000000-0000-0000-0000-000000000002");
    let ids: Vec<&str> = [&t[0]["clips"][0], &t[0]["clips"][1], &t[1]["clips"][0], &t[1]["clips"][1]]
        .iter()
        .filter_map(|c| c["id"].as_str())
        .collect();
    assert_eq!(ids.iter().collect::<BTreeSet<_>>().len(), 4, "{ids:?}");
    assert_ne!(t[1]["id"], t[0]["id"]);
    assert_eq!(t[1]["clips"][0]["futureKey"], "x", "other keys stay with the element");
}

#[test]
fn a_repaired_project_needs_no_second_repair() {
    let mut p = project();
    repair_duplicate_ids(&mut p);
    assert!(repair_duplicate_ids(&mut p).is_empty());
}
