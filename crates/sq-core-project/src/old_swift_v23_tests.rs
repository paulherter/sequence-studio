// SPDX-License-Identifier: GPL-3.0-or-later
//! A project file written by the old Swift app at format v23 (before the v24 Drop Shadow color fold) must open in the
//! Rust app. `testdata/old_swift_v23.json` was written by the real Swift `ProjectFile.write` at commit 5f45d6833
//! (no media; see notes/proof/w47-old-swift-project/README.md).

use crate::project_file::project_file;
use serde_json::Value;

const FIXTURE: &str = include_str!("../testdata/old_swift_v23.json");

#[test]
fn a_v23_swift_project_loads_migrates_and_keeps_its_content() {
    assert!(FIXTURE.contains("\"formatVersion\" : 23"), "the fixture must stay a v23 file");
    let pf = project_file();
    let project = pf.decode(FIXTURE.as_bytes(), None).expect("a v23 Swift project opens");
    // Look at it through the writer: what the app would save next.
    let out: Value = serde_json::from_slice(&pf.encode(&project).unwrap()).unwrap();
    assert!(out["formatVersion"].as_i64().unwrap() > 23);
    let p = &out["project"];
    assert_eq!(p["name"], "OldSwift");
    assert_eq!(p["media"].as_array().unwrap().len(), 3);
    let tl = &p["timelines"][0];
    let tracks = tl["tracks"].as_array().unwrap();
    let clips = |i: usize| tracks[i]["clips"].as_array().unwrap().clone();
    let (video, audio) = (clips(0), clips(1));
    assert_eq!((video.len(), audio.len()), (2, 1));
    assert_eq!(video[0]["name"], "v1");
    assert_eq!(video[1]["name"], "v2");
    assert_eq!(audio[0]["name"], "a1");

    // Marker.
    let markers = tl["markers"].as_array().unwrap();
    assert_eq!(markers.len(), 1);
    assert_eq!((markers[0]["name"].as_str(), markers[0]["color"].as_str()), (Some("Beat"), Some("red")));

    // Position and opacity keyframes.
    let anim = &video[0]["animation"];
    assert_eq!(anim["opacity"]["track"]["keys"].as_array().unwrap().len(), 2);
    assert_eq!(anim["opacity"]["track"]["keys"][1]["value"], 0.75);
    assert_eq!(anim["position"]["track"]["keys"].as_array().unwrap().len(), 2);

    // Drop Shadow: 200/40/90 (0...255) folded into one color, the three channel parameters gone, the rest kept.
    let fx = &video[0]["effects"][0];
    assert_eq!(fx["kind"], "dropShadow");
    let c = &fx["colors"]["shadowColor"]["value"];
    assert_eq!(c["red"].as_f64().unwrap(), 200.0 / 255.0);
    assert_eq!(c["green"].as_f64().unwrap(), 40.0 / 255.0);
    assert_eq!(c["blue"].as_f64().unwrap(), 90.0 / 255.0);
    let params = fx["parameters"].as_object().unwrap();
    for gone in ["shadowRed", "shadowGreen", "shadowBlue"] {
        assert!(!params.contains_key(gone), "{gone} must be folded away");
    }
    assert_eq!(params["shadowDistance"]["value"], 12.0);
    assert_eq!(params["shadowSoftness"]["value"], 30.0);
}
