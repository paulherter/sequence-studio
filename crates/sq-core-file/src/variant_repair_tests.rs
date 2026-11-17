// SPDX-License-Identifier: GPL-3.0-or-later

use super::*;
use serde_json::{Value, json};
use sq_core_model::{
    BlendMode, Clip, LabelColor, MediaFingerprint, MediaRef, Project, SequenceFormat, Timeline, Track, TrackKind,
};
use sq_core_time::{Id, SequentialIds, Time, TimeRange};

fn id(n: u128) -> Id {
    Id::from_u128(n)
}

/// Two sequences; the first has markers of every color, a labeled, blended clip and an effect.
fn rich() -> Project {
    let mut ids = SequentialIds::default();
    let m = MediaRef::new(id(100), "m.mov", "/x/m.mov", MediaFingerprint::new(42));
    let mut track = Track::new(id(50), TrackKind::Video);
    let mut c = Clip::new(
        id(10),
        "A",
        m.id,
        TrackKind::Video,
        TimeRange::new(Time::new(0, 1), Time::new(2, 1)),
        Time::new(0, 1),
    );
    c.blend_mode = BlendMode::Multiply;
    c.label = Some(LabelColor::Violet);
    track.overwrite(c, &mut ids).unwrap();
    let mut main = Timeline::new(id(20), "Main", SequenceFormat::new(Time::new(1, 30)), vec![track]);
    for (i, color) in ["red", "purple", "orange", "yellow", "white", "blue", "cyan"].iter().enumerate() {
        main.markers.push(
            serde_json::from_value(
                json!({"id": id(300 + i as u128).to_string(), "time": {"value": i, "timescale": 1}, "name": "M", "color": color}),
            )
            .unwrap(),
        );
    }
    let other = Timeline::new(
        id(21),
        "Other",
        SequenceFormat::new(Time::new(1, 30)),
        vec![Track::new(id(51), TrackKind::Audio)],
    );
    Project::new(id(1), "P", vec![m], vec![main, other])
}

fn file_of(p: &Project) -> Value {
    serde_json::from_slice(&ProjectFile::without_fixups().encode(p).unwrap()).unwrap()
}

fn salvage(v: &Value) -> Result<(Project, ProjectSalvageReport), ProjectFileError> {
    ProjectFile::without_fixups().salvage(&serde_json::to_vec(v).unwrap())
}

/// Every string leaf as a JSON pointer.
fn string_leaves(v: &Value, at: &mut Vec<String>, out: &mut Vec<String>) {
    match v {
        Value::String(_) => out.push(format!("/{}", at.join("/"))),
        Value::Array(a) => {
            for (i, x) in a.iter().enumerate() {
                at.push(i.to_string());
                string_leaves(x, at, out);
                at.pop();
            }
        }
        Value::Object(o) => {
            for (k, x) in o {
                at.push(k.clone());
                string_leaves(x, at, out);
                at.pop();
            }
        }
        _ => {}
    }
}

#[test]
fn an_unknown_marker_color_keeps_the_sequence_and_the_marker() {
    let mut obj = file_of(&rich());
    obj["project"]["timelines"][0]["markers"][0]["color"] = json!("pink");
    assert!(ProjectFile::without_fixups().decode(&serde_json::to_vec(&obj).unwrap(), None).is_err());
    let (p, report) = salvage(&obj).unwrap();
    assert_eq!(p.timelines.len(), 2);
    assert_eq!(p.timelines[0].markers.len(), 7);
    assert_eq!(report.dropped.len(), 1);
    assert!(report.dropped[0].contains("pink"), "{:?}", report.dropped);
}

#[test]
fn every_enum_value_in_a_project_file_may_be_unknown_without_losing_data() {
    let good = rich();
    let base = file_of(&good);
    let mut leaves = Vec::new();
    string_leaves(&base, &mut Vec::new(), &mut leaves);
    let mut checked = 0;
    for pointer in leaves {
        let original = base.pointer(&pointer).and_then(Value::as_str).unwrap().to_string();
        let mut obj = base.clone();
        *obj.pointer_mut(&pointer).unwrap() = json!("zzUnknownValue");
        if ProjectFile::without_fixups().decode(&serde_json::to_vec(&obj).unwrap(), None).is_ok() {
            continue; // free text, not an enum
        }
        if original.contains('-') || original.contains('/') || original.contains('.') {
            continue; // an id, a path or a name: its loss is reported, not repaired
        }
        let (p, report) = salvage(&obj).unwrap_or_else(|e| panic!("{pointer}: {e:?}"));
        assert_eq!(p.timelines.len(), good.timelines.len(), "{pointer}: a sequence vanished");
        assert_eq!(p.timelines[0].markers.len(), 7, "{pointer}");
        assert_eq!(p.timelines[0].tracks[0].clips().len(), 1, "{pointer}: a clip vanished");
        assert!(!report.is_empty(), "{pointer}: the repair was not reported");
        checked += 1;
    }
    assert!(checked >= 9, "only {checked} enum fields were exercised");
}

#[test]
fn the_nearest_known_value_wins() {
    let known: Vec<String> = ["green", "red", "purple"].iter().map(ToString::to_string).collect();
    assert_eq!(variant_repair::nearest("Purple2", &known), "purple");
    assert_eq!(variant_repair::nearest("zzz", &known), "red");
}
