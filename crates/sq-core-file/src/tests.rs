// SPDX-License-Identifier: GPL-3.0-or-later
// Swift tests: ProjectFileTests, ProjectFileMigrationTableTests, ProjectFileDirectDecodeTests, ProjectSalvageTests,
// ProjectFileSafeWriteTests (backups), version gate tests, HostileInputTests (file part).

use super::*;
use serde_json::{Value, json};
use sq_core_model::{
    Clip, ClipEffect, MediaFingerprint, MediaRef, Project, SequenceFormat, Timeline, Track, TrackKind,
};
use sq_core_time::{Id, SequentialIds, Time, TimeRange, Timestamp};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

struct TempDir(PathBuf);

impl TempDir {
    /// A fresh folder; packages sit one level below it so `.bak` pruning lists only this folder.
    fn new() -> TempDir {
        static N: AtomicU64 = AtomicU64::new(0);
        let dir =
            std::env::temp_dir().join(format!("sqfile-{}-{}", std::process::id(), N.fetch_add(1, Ordering::Relaxed)));
        fs::create_dir_all(&dir).unwrap();
        TempDir(dir)
    }
    fn package(&self) -> PathBuf {
        let p = self.0.join("pkg.sqproj");
        fs::create_dir_all(&p).unwrap();
        p
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn id(n: u128) -> Id {
    Id::from_u128(n)
}

fn t(v: i64, ts: i64) -> Time {
    Time::new(v, ts)
}

fn range(start: Time, duration: Time) -> TimeRange {
    TimeRange::new(start, duration)
}

fn clip(n: u128, name: &str, media: Id, kind: TrackKind, start: i64) -> Clip {
    Clip::new(id(n), name, media, kind, range(t(0, 1), t(2, 1)), t(start, 1))
}

fn media_ref() -> MediaRef {
    MediaRef::new(id(100), "m.mov", "/x/m.mov", MediaFingerprint::new(42))
}

/// Three clips of one media on a video track of one sequence.
fn sample() -> Project {
    let mut ids = SequentialIds::default();
    let m = media_ref();
    let mut track = Track::new(id(50), TrackKind::Video);
    for (i, name) in ["A", "B", "C"].iter().enumerate() {
        track.overwrite(clip(10 + i as u128, name, m.id, TrackKind::Video, 2 * i as i64), &mut ids).unwrap();
    }
    let tl = Timeline::new(id(20), "Main", SequenceFormat::new(t(1, 30)), vec![track]);
    Project::new(id(1), "P", vec![m], vec![tl])
}

fn effect(kind: &str) -> ClipEffect {
    serde_json::from_value(json!({"id": id(900).to_string(), "kind": kind, "enabled": true, "parameters": {}})).unwrap()
}

fn json_of(p: &Project) -> Value {
    serde_json::from_slice(&ProjectFile::without_fixups().encode(p).unwrap()).unwrap()
}

fn decoded(v: &Value) -> Result<Project, ProjectFileError> {
    ProjectFile::without_fixups().decode(&serde_json::to_vec(v).unwrap(), None)
}

fn format_version(p: &Project) -> i64 {
    json_of(p)["formatVersion"].as_i64().unwrap()
}

// ProjectFileTests

#[test]
fn round_trip() {
    let dir = TempDir::new();
    let pkg = dir.package();
    let p = sample();
    let pf = ProjectFile::without_fixups();
    pf.write(&p, &pkg).unwrap();
    assert_eq!(pf.read(&pkg).unwrap(), p);
    assert!(pkg.join("project.json").is_file());
}

#[test]
fn single_file_project_round_trips_and_keeps_its_form() {
    let dir = TempDir::new();
    let pkg = dir.package();
    let file = dir.0.join("F.sqproj");
    fs::write(&file, "{}").unwrap(); // an existing plain file stays a file
    let (pf, p) = (ProjectFile::without_fixups(), sample());
    pf.write(&p, &file).unwrap();
    assert!(is_single_file(&file));
    assert_eq!(pf.read(&file).unwrap().name, p.name);
    pf.write(&p, &pkg).unwrap(); // an existing package folder stays a package
    assert!(!is_single_file(&pkg));
    let snap = pf.autosave(&p, &file, 10, Timestamp::from_unix_seconds(1_700_000_000.0)).unwrap();
    assert_eq!(snap.parent().unwrap().file_name().unwrap(), "F.sqproj.Autosave");
    assert_eq!(pf.latest_autosave(&file, None).unwrap().name, p.name);
}

#[test]
fn file_shape() {
    let p = sample();
    let text = String::from_utf8(ProjectFile::without_fixups().encode(&p).unwrap()).unwrap();
    assert!(text.contains('\n'));
    let v: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(v["formatVersion"], ProjectFile::written_version(&p));
    assert_eq!(v["appFormat"], CURRENT_VERSION);
    // Keys are sorted: the header comes first, the backup logic reads it from the first 256 bytes.
    assert!(
        text.find("appFormat") < text.find("formatVersion") && text.find("formatVersion") < text.find("\"project\"")
    );
}

#[test]
fn a_project_without_gated_content_is_written_at_the_floor() {
    assert_eq!(ProjectFile::written_version(&sample()), 36);
}

#[test]
fn non_normalized_time_in_file_loads_normalized_and_round_trips() {
    let p = sample();
    let mut v = json_of(&p);
    fn rewrite(v: &mut Value) {
        match v {
            Value::Object(o) => {
                if o.len() == 2 && o.get("value") == Some(&json!(2)) && o.get("timescale") == Some(&json!(1)) {
                    *v = json!({"value": 4, "timescale": 2});
                    return;
                }
                o.values_mut().for_each(rewrite);
            }
            Value::Array(a) => a.iter_mut().for_each(rewrite),
            _ => {}
        }
    }
    rewrite(&mut v);
    assert_ne!(v, json_of(&p));
    let loaded = decoded(&v).unwrap();
    assert_eq!(loaded, p);
    assert_eq!(decoded(&json_of(&loaded)).unwrap(), p);
}

const FD: &str = r#"{"value":1,"timescale":30}"#;

fn old_file(version: i64, tracks: &str) -> String {
    format!(
        r#"{{"formatVersion":{version},"project":{{"id":"{p}","name":"Old","media":[],"activeTimeline":"{tl}",
        "timelines":[{{"id":"{tl}","name":"T","format":{{"width":1920,"height":1080,"frameDuration":{FD},"audioSampleRate":48000}},
        "tracks":[{tracks}]}}]}}}}"#,
        p = id(1),
        tl = id(2)
    )
}

fn track_json(kind: &str, clip_extra: &str) -> String {
    format!(
        r#"{{"id":"{}","kind":"{kind}","clips":[{{"id":"{}","name":"c","media":"{}","kind":"{kind}"{clip_extra},
        "source":{{"start":{{"value":0,"timescale":1}},"duration":{{"value":4,"timescale":1}}}},"start":{{"value":0,"timescale":1}}}}]}}"#,
        id(3),
        id(4),
        id(5)
    )
}

#[test]
fn v1_fixture_loads_as_v2_with_defaults() {
    let v1 = format!(
        r#"{{"formatVersion":1,"project":{{"id":"{}","name":"Old","media":[],
        "timelines":[{{"id":"{}","name":"Main","frameDuration":{{"value":1001,"timescale":30000}},
        "tracks":[{{"id":"{}","kind":"video","isLocked":true,"syncLock":false,"clips":[]}}]}}]}}}}"#,
        id(1),
        id(2),
        id(3)
    );
    let p = ProjectFile::without_fixups().decode(v1.as_bytes(), None).unwrap();
    let tl = &p.timelines[0];
    assert_eq!(tl.format.width, 1920);
    assert_eq!(tl.format.height, 1080);
    assert_eq!(tl.format.frame_duration, t(1001, 30000));
    assert_eq!(tl.format.audio_sample_rate, 48_000);
    assert!(tl.in_out.is_none() && tl.markers.is_empty());
    let tr = &tl.tracks[0];
    assert!(tr.is_locked && !tr.sync_lock);
    assert!(tr.name.is_empty() && tr.is_visible && !tr.is_muted && !tr.is_solo && !tr.is_targeted);
    assert_eq!(tr.height, Track::DEFAULT_HEIGHT);
}

#[test]
fn v2_v4_and_v15_files_load_with_defaults() {
    let pf = ProjectFile::without_fixups();
    let v2 = pf.decode(old_file(2, &track_json("video", "")).as_bytes(), None).unwrap();
    let c = &v2.timelines[0].tracks[0].clips()[0];
    assert_eq!(c.id, id(4));
    assert_eq!(c.animation, sq_core_model::ClipAnimation::default());
    assert!(c.animation.position.track.is_empty());

    let v4 = pf.decode(old_file(4, &track_json("video", "")).as_bytes(), None).unwrap();
    let c = &v4.timelines[0].tracks[0].clips()[0];
    assert!(c.sequence.is_none() && c.effects.is_empty());
    assert!(v4.timelines[0].caption_tracks.is_empty());

    let v15 = pf.decode(old_file(15, &track_json("audio", r#","reversed":true"#)).as_bytes(), None).unwrap();
    let c = &v15.timelines[0].tracks[0].clips()[0];
    assert!(c.reversed && c.audio_gain_db == 0.0);
}

#[test]
fn v3_file_loads_with_everything_in_the_root_bin() {
    let json = format!(
        r#"{{"formatVersion":3,"project":{{"id":"{}","name":"Old","activeTimeline":"{}",
        "media":[{{"id":"{}","name":"a.mov","path":"/x/a.mov","fingerprint":{{"size":1}}}}],
        "timelines":[{{"id":"{}","name":"T","format":{{"width":1920,"height":1080,"frameDuration":{FD},"audioSampleRate":48000}},"tracks":[]}}]}}}}"#,
        id(1),
        id(2),
        id(7),
        id(2)
    );
    let pf = ProjectFile::without_fixups();
    let p = pf.decode(json.as_bytes(), None).unwrap();
    assert!(p.source_marks.is_empty());
    assert_eq!(p.root_bin.children.len(), 2);
    assert_eq!(pf.decode(&pf.encode(&p).unwrap(), None).unwrap(), p);
}

#[test]
fn v16_file_has_no_transitions() {
    let p = ProjectFile::without_fixups().decode(old_file(16, &track_json("video", "")).as_bytes(), None).unwrap();
    assert!(p.timelines[0].tracks[0].transitions.is_empty());
}

#[test]
fn missing_and_corrupt() {
    let dir = TempDir::new();
    let pkg = dir.package();
    let pf = ProjectFile::without_fixups();
    assert_eq!(pf.read(&pkg), Err(ProjectFileError::Missing));
    fs::write(pkg.join("project.json"), "{ nope").unwrap();
    assert_eq!(pf.read(&pkg), Err(ProjectFileError::Corrupt));
    fs::write(pkg.join("project.json"), r#"{"formatVersion":3,"project":{"x":1}}"#).unwrap();
    assert_eq!(pf.read(&pkg), Err(ProjectFileError::Corrupt));
}

#[test]
fn newer_version_refused() {
    let dir = TempDir::new();
    let pkg = dir.package();
    fs::write(pkg.join("project.json"), r#"{"formatVersion":99,"project":{}}"#).unwrap();
    assert_eq!(
        ProjectFile::without_fixups().read(&pkg),
        Err(ProjectFileError::NewerVersion { found: 99, supported: CURRENT_VERSION })
    );
}

#[test]
fn migration_from_fake_v0() {
    let pid = id(1);
    let v0 = format!(r#"{{"formatVersion":0,"project":{{"id":"{pid}","title":"Old"}}}}"#);
    let pf = ProjectFile::without_fixups();
    let mut migrations = pf.migrations();
    migrations.insert(
        0,
        Box::new(|mut o: JsonObject| {
            let Some(Value::Object(p)) = o.get_mut("project") else { return Err(ProjectFileError::Corrupt) };
            if let Some(title) = p.remove("title") {
                p.insert("name".into(), title);
            }
            p.insert("media".into(), json!([]));
            p.insert("timelines".into(), json!([]));
            Ok(o)
        }),
    );
    assert_eq!(pf.decode(v0.as_bytes(), Some(&migrations)).unwrap().name, "Old");
    // without a registered step, refuse rather than guess
    let mut only_two = Migrations::new();
    only_two.insert(1, Box::new(migrate_v1_to_v2));
    only_two.insert(2, Box::new(Ok));
    assert_eq!(pf.decode(v0.as_bytes(), Some(&only_two)), Err(ProjectFileError::Corrupt));
}

#[test]
fn overwrite_replaces() {
    let dir = TempDir::new();
    let pkg = dir.package();
    let (pf, mut p) = (ProjectFile::without_fixups(), sample());
    pf.write(&p, &pkg).unwrap();
    p.name = "Second".into();
    pf.write(&p, &pkg).unwrap();
    assert_eq!(pf.read(&pkg).unwrap().name, "Second");
}

#[test]
fn a_failed_write_keeps_the_old_file_and_leaves_no_temp_file() {
    let dir = TempDir::new();
    let pkg = dir.package();
    let (pf, p) = (ProjectFile::without_fixups(), sample());
    pf.write(&p, &pkg).unwrap();
    let file = pkg.join("project.json");
    let fail = || Err(std::io::Error::other("disk full"));
    assert!(files::atomic_write(b"garbage", &file, Some(&fail)).is_err());
    assert_eq!(pf.read(&pkg).unwrap().name, "P");
    let leftovers =
        fs::read_dir(&pkg).unwrap().flatten().filter(|e| e.file_name().to_string_lossy().ends_with(".tmp")).count();
    assert_eq!(leftovers, 0);
}

#[test]
fn autosave_prunes_and_recovers() {
    let dir = TempDir::new();
    let pkg = dir.package();
    let (pf, mut p) = (ProjectFile::without_fixups(), sample());
    for i in 0..5 {
        p.name = format!("v{i}");
        pf.autosave(&p, &pkg, 3, Timestamp::from_unix_seconds(1_700_000_000.0 + f64::from(i) * 0.5)).unwrap();
    }
    let files = ProjectFile::autosaves(&pkg);
    assert_eq!(files.len(), 3);
    assert_eq!(files[0].file_name().unwrap(), "20231114-221321-000.json");
    assert_eq!(pf.latest_autosave(&pkg, None).unwrap().name, "v4");
}

#[test]
fn autosave_after_a_clock_set_back_still_sorts_last() {
    let dir = TempDir::new();
    let pkg = dir.package();
    let (pf, mut p) = (ProjectFile::without_fixups(), sample());
    pf.autosave(&p, &pkg, 10, Timestamp::from_unix_seconds(1_700_000_000.0)).unwrap();
    p.name = "later".into();
    let f = pf.autosave(&p, &pkg, 10, Timestamp::from_unix_seconds(1_600_000_000.0)).unwrap();
    assert_eq!(f.file_name().unwrap(), "20231114-221320-001.json");
    assert_eq!(pf.latest_autosave(&pkg, None).unwrap().name, "later");
}

#[test]
fn latest_autosave_skips_corrupt() {
    let dir = TempDir::new();
    let pkg = dir.package();
    let (pf, mut p) = (ProjectFile::without_fixups(), sample());
    p.name = "good".into();
    pf.autosave(&p, &pkg, 10, Timestamp::from_unix_seconds(1_700_000_000.0)).unwrap();
    let folder = ProjectFile::autosave_folder(&pkg);
    fs::write(folder.join("20231114-221321-000.json"), "garbage").unwrap();
    assert_eq!(pf.latest_autosave(&pkg, None).unwrap().name, "good");
    assert!(pf.latest_autosave(&TempDir::new().package(), None).is_none());
}

#[test]
fn timestamp_names_parse_back() {
    for ms in [0, 1_700_000_000_123, 951_782_400_000, 4_102_444_799_999, 86_399_999] {
        assert_eq!(files::parse_timestamp(&files::timestamp_name(ms)), Some(ms), "{ms}");
    }
    assert_eq!(files::timestamp_name(1_700_000_000_000), "20231114-221320-000");
    assert_eq!(files::parse_timestamp("nonsense"), None);
    assert_eq!(files::parse_timestamp("20231314-221320-000"), None);
}

#[test]
fn extensions_and_converted_path() {
    assert!(is_project_path(Path::new("/a/B.SQPROJ")) && is_project_path(Path::new("/a/B.ssproj")));
    assert!(is_legacy_path(Path::new("/a/B.ssproj")) && !is_legacy_path(Path::new("/a/B.sqproj")));
    assert!(!is_project_path(Path::new("/a/B.mov")));
    let dir = TempDir::new();
    let legacy = dir.0.join("Old.ssproj");
    assert_eq!(converted_path(&legacy), dir.0.join("Old.sqproj"));
    fs::create_dir_all(dir.0.join("Old.sqproj")).unwrap();
    assert_eq!(converted_path(&legacy), dir.0.join("Old 2.sqproj"));
}

// Backups of older files (ProjectFileSafeWriteTests)

fn write_header_file(path: &Path, app: Option<i64>, version: i64) {
    let app = app.map_or(String::new(), |a| format!("\"appFormat\": {a},\n"));
    fs::write(path, format!("{{\n{app}\"formatVersion\": {version},\n\"project\": {{}}\n}}")).unwrap();
}

#[test]
fn a_save_over_an_older_build_file_makes_one_backup_and_keeps_three() {
    let dir = TempDir::new();
    let pkg = dir.package();
    let pf = ProjectFile::without_fixups();
    let p = sample();
    for v in [30, 31, 32, 33] {
        write_header_file(&pkg.join("project.json"), Some(v), v);
        pf.write(&p, &pkg).unwrap();
    }
    let mut baks: Vec<String> = fs::read_dir(&dir.0)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".bak"))
        .collect();
    baks.sort();
    assert_eq!(baks, ["pkg.sqproj.v31.bak", "pkg.sqproj.v32.bak", "pkg.sqproj.v33.bak"]);
    // A save of a file this build wrote makes none.
    let before = fs::read_dir(&dir.0).unwrap().count();
    pf.write(&p, &pkg).unwrap();
    assert_eq!(fs::read_dir(&dir.0).unwrap().count(), before);
}

#[test]
fn a_newer_builds_file_is_backed_up_before_it_is_overwritten() {
    let dir = TempDir::new();
    let pkg = dir.package();
    write_header_file(&pkg.join("project.json"), Some(CURRENT_VERSION + 1), CURRENT_VERSION + 1);
    ProjectFile::without_fixups().write(&sample(), &pkg).unwrap();
    assert!(dir.0.join(format!("pkg.sqproj.v{}.bak", CURRENT_VERSION + 1)).is_file());
}

#[test]
fn a_file_without_app_format_is_backed_up_only_below_the_floor() {
    let dir = TempDir::new();
    let pkg = dir.package();
    let pf = ProjectFile::without_fixups();
    write_header_file(&pkg.join("project.json"), None, 36);
    pf.write(&sample(), &pkg).unwrap();
    assert!(!dir.0.join("pkg.sqproj.v36.bak").exists());
    write_header_file(&pkg.join("project.json"), None, 35);
    pf.write(&sample(), &pkg).unwrap();
    assert!(dir.0.join("pkg.sqproj.v35.bak").is_file());
}

// ProjectFileMigrationTableTests, ProjectFileDirectDecodeTests

#[test]
fn table_has_exactly_one_step_per_older_version() {
    let pf = ProjectFile::without_fixups();
    assert_eq!(pf.migrations().keys().copied().collect::<Vec<_>>(), (1..CURRENT_VERSION).collect::<Vec<_>>());
    assert!(pf.real_migrations().keys().all(|k| (1..CURRENT_VERSION).contains(k)));
    assert!(pf.real_migrations().keys().all(|k| *k < IDENTITY_MIGRATIONS_FROM));
}

#[test]
fn a_file_at_every_older_version_reaches_the_current_one() {
    let pf = ProjectFile::without_fixups();
    let base = json_of(&sample());
    for v in 1..CURRENT_VERSION {
        let mut obj = base.clone();
        obj["formatVersion"] = json!(v);
        if v == 1 {
            // v1 stores the frame duration beside the format.
            let tl = &mut obj["project"]["timelines"][0];
            let fd = tl["format"]["frameDuration"].clone();
            tl.as_object_mut().unwrap().remove("format");
            tl["frameDuration"] = fd;
        }
        let back = pf.decode(&serde_json::to_vec(&obj).unwrap(), Some(&pf.migrations())).unwrap();
        assert_eq!(back.timelines.len(), 1, "from v{v}");
    }
}

#[test]
fn current_files_decode_directly_with_the_same_result() {
    let pf = ProjectFile::without_fixups();
    let data = pf.encode(&sample()).unwrap();
    let direct = pf.decode(&data, None).unwrap();
    assert_eq!(direct, pf.decode(&data, Some(&pf.migrations())).unwrap());
    assert_eq!(direct, sample());
}

#[test]
fn newer_and_hostile_envelopes_are_refused() {
    let pf = ProjectFile::without_fixups();
    let mut obj = json_of(&sample());
    obj["formatVersion"] = json!(CURRENT_VERSION + 1);
    let newer = serde_json::to_vec(&obj).unwrap();
    assert_eq!(
        pf.decode(&newer, None),
        Err(ProjectFileError::NewerVersion { found: CURRENT_VERSION + 1, supported: CURRENT_VERSION })
    );
    for text in [
        r#"{"formatVersion":51,"project":5}"#,
        r#"{"formatVersion":51}"#,
        r#"{"formatVersion":"51","project":{}}"#,
        r#"{"formatVersion":1e300,"project":{}}"#,
        r#"{"formatVersion":99999999999999999999,"project":{}}"#,
        r#"{"formatVersion":-9223372036854775808,"project":{}}"#,
        r#"[]"#,
        r#""x""#,
        "",
    ] {
        assert_eq!(pf.decode(text.as_bytes(), None), Err(ProjectFileError::Corrupt), "{text}");
    }
}

/// The direct path relies on every step from `IDENTITY_MIGRATIONS_FROM` on leaving the object as it is.
#[test]
fn every_step_from_the_identity_version_on_is_identity() {
    let pf = ProjectFile::without_fixups();
    let Value::Object(obj) = json_of(&sample()) else { panic!("object") };
    for v in IDENTITY_MIGRATIONS_FROM..CURRENT_VERSION {
        let steps = pf.migrations();
        assert_eq!(steps[&v](obj.clone()).unwrap(), obj, "v{v}");
    }
}

#[test]
fn v33_step_forgets_a_stored_rec709_of_video_media_only() {
    let item = |info: Value| json!({"id": id(1).to_string(), "info": info});
    let media = vec![
        item(json!({"video": {}, "detectedColorSpace": "rec709"})),
        item(json!({"video": {}, "isStill": true, "detectedColorSpace": "rec709"})),
        item(json!({"video": {}, "detectedColorSpace": "hlgBT2020"})),
        item(json!({"audio": {}, "detectedColorSpace": "rec709"})),
    ];
    let Value::Object(out) =
        migrate_v33_to_v34(json!({"project": {"media": media}}).as_object().unwrap().clone()).into()
    else {
        panic!("object")
    };
    let out = &out["project"]["media"];
    assert!(out[0]["info"].get("detectedColorSpace").is_none());
    assert_eq!(out[1]["info"]["detectedColorSpace"], "rec709");
    assert_eq!(out[2]["info"]["detectedColorSpace"], "hlgBT2020");
    assert_eq!(out[3]["info"]["detectedColorSpace"], "rec709");
}

#[test]
fn v1_step_needs_a_project_object() {
    let Value::Object(no_project) = json!({"formatVersion": 1}) else { panic!("object") };
    assert_eq!(migrate_v1_to_v2(no_project), Err(ProjectFileError::Corrupt));
}

// Fixups

#[derive(Default)]
struct Recorder(std::cell::Cell<u32>);

impl ProjectFixups for Recorder {
    fn prune_unused_groups(&self, p: &mut Project) {
        self.0.set(self.0.get() + 1);
        p.name = "pruned".into();
    }
    fn prune_variant_overrides(&self, _: &mut Project) -> bool {
        self.0.set(self.0.get() + 10);
        false
    }
}

#[test]
fn fixups_run_before_encode_and_on_the_v26_step() {
    let rec = Recorder::default();
    let pf = ProjectFile::with_fixups(&rec);
    let data = pf.encode(&sample()).unwrap();
    assert_eq!(rec.0.get(), 1);
    assert_eq!(pf.decode(&data, None).unwrap().name, "pruned");
    let mut obj = json_of(&sample());
    obj["formatVersion"] = json!(25);
    pf.decode(&serde_json::to_vec(&obj).unwrap(), None).unwrap();
    assert_eq!(rec.0.get(), 11);
}

// Version gates

#[test]
fn gated_content_raises_the_written_version() {
    type Edit = fn(&mut Project);
    fn with_effect(p: &mut Project, kind: &str) {
        let mut c = p.timelines[0].tracks[0].clips()[0].clone();
        c.effects.push(effect(kind));
        p.timelines[0].tracks[0].replace(c);
    }
    let cases: Vec<(&str, i64, Edit)> = vec![
        ("gradient", 51, |p| with_effect(p, "gradient")),
        ("halftone", 61, |p| with_effect(p, "halftone")),
        ("audio.notch", 73, |p| with_effect(p, "audio.notch")),
        ("colorGraph", 78, |p| with_effect(p, "colorGraph")),
        ("trackMask", 90, |p| with_effect(p, "trackMask")),
        ("agedFilm", 86, |p| with_effect(p, "agedFilm")),
        ("notes", 83, |p| p.set_notes("remember")),
        ("master volume", 66, |p| p.timelines[0].master_level = Some(-6.0)),
        ("timecode start", 81, |p| p.timelines[0].timecode_start_store = Some(t(3600, 1))),
        ("fast cut", 67, |p| p.timelines[0].edit_mode_store = Some(sq_core_model::TimelineEditMode::Magnetic)),
        ("source patch", 88, |p| {
            let mut patch = sq_core_model::SourcePatch::default();
            patch.audio.is_connected = false;
            p.timelines[0].source_patch_store = Some(patch);
        }),
        ("snapping off", 91, |p| p.timelines[0].snapping_off_store = Some(true)),
        ("anti-flicker", 92, |p| {
            let mut c = p.timelines[0].tracks[0].clips()[0].clone();
            c.animation.anti_flicker.value = 0.5;
            p.timelines[0].tracks[0].replace(c);
        }),
        ("tilt (written by the encoder)", 84, |p| {
            let mut c = p.timelines[0].tracks[0].clips()[0].clone();
            c.animation.tilt_x.value = 5.0;
            p.timelines[0].tracks[0].replace(c);
        }),
    ];
    let base = sample();
    assert_eq!(format_version(&base), 36);
    for (name, version, edit) in cases {
        let mut p = base.clone();
        edit(&mut p);
        assert_eq!(format_version(&p), version, "{name}");
        // Re-decode equal, and the same version again.
        let back = decoded(&json_of(&p)).unwrap();
        assert_eq!(back, p, "{name}");
        assert_eq!(format_version(&back), version, "{name}");
    }
}

#[test]
fn a_default_source_patch_does_not_gate() {
    let mut p = sample();
    p.timelines[0].source_patch_store = Some(sq_core_model::SourcePatch::default());
    assert_eq!(ProjectFile::written_version(&p), 36);
}

#[test]
fn the_newest_gate_decides() {
    let mut p = sample();
    p.set_notes("x");
    p.timelines[0].master_level = Some(3.0);
    let mut c = p.timelines[0].tracks[0].clips()[0].clone();
    c.effects.push(effect("trackMask"));
    p.timelines[0].tracks[0].replace(c);
    assert_eq!(ProjectFile::written_version(&p), 90);
}

#[test]
fn the_kind_gates_cover_the_old_effect_kinds() {
    for (kind, version) in [
        ("dynamicZoom", 56),
        ("kaleidoscope", 61),
        ("audio.highCut", 60),
        ("trails", 64),
        ("audio.pitchShift", 70),
        ("audio.graphicEQ", 76),
    ] {
        let mut p = sample();
        let mut c = p.timelines[0].tracks[0].clips()[0].clone();
        c.effects.push(effect(kind));
        p.timelines[0].tracks[0].replace(c);
        assert_eq!(ProjectFile::written_version(&p), version, "{kind}");
    }
}

#[test]
fn a_hold_ahead_key_raises_the_version_while_it_is_written() {
    use sq_core_time::{Interpolation, Keyframe};
    let mut p = sample();
    let mut c = p.timelines[0].tracks[0].clips()[0].clone();
    let mut first = Keyframe::new(id(901), t(0, 1), 0.0);
    first.interpolation = Interpolation::HoldAhead;
    c.animation.opacity.track.insert(first);
    c.animation.opacity.track.insert(Keyframe::new(id(902), t(1, 1), 1.0));
    p.timelines[0].tracks[0].replace(c);
    assert_eq!(ProjectFile::written_version(&p), 36); // the gate list does not see it; the encoder does
    assert_eq!(format_version(&p), 77);
    assert_eq!(decoded(&json_of(&p)).unwrap(), p);
}

#[test]
fn compact_keyframes_are_written_only_inside_a_project_file() {
    use sq_core_time::{EncodeContext, Keyframe};
    let mut c = sample().timelines[0].tracks[0].clips()[0].clone();
    c.animation.opacity.track.insert(Keyframe::new(id(901), t(0, 1), 0.5));
    let full = serde_json::to_value(&c).unwrap();
    let compact = {
        let _scope = EncodeContext::project_file();
        serde_json::to_value(&c).unwrap()
    };
    assert_ne!(full, compact);
    assert!(compact.to_string().len() < full.to_string().len());
}

// Fixture written by the Swift app

#[test]
fn the_swift_v71_fixture_decodes_and_re_encodes_to_the_same_content() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQCore/Tests/Fixtures/project-v71.json");
    let bytes = fs::read(path).unwrap();
    let pf = ProjectFile::without_fixups();
    let p = pf.decode(&bytes, None).unwrap();
    assert_eq!(p.name, "P");
    assert_eq!(p.timelines.len(), 1);
    // Re-decode equal, and the file parses to the same project content as the Swift one.
    let again = pf.decode(&pf.encode(&p).unwrap(), None).unwrap();
    assert_eq!(again, p);
    let written = json_of(&p);
    let original: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(written["project"], original["project"]);
    assert_eq!(written["formatVersion"], ProjectFile::written_version(&p));
}

// Salvage (ProjectSalvageTests)

fn edit_clips(obj: &mut Value, edit: impl FnOnce(&mut Vec<Value>)) {
    let clips = obj["project"]["timelines"][0]["tracks"][0]["clips"].as_array_mut().unwrap();
    edit(clips);
}

fn salvage(obj: &Value) -> Result<(Project, ProjectSalvageReport), ProjectFileError> {
    ProjectFile::without_fixups().salvage(&serde_json::to_vec(obj).unwrap())
}

fn clip_names(p: &Project) -> Vec<String> {
    p.timelines[0].tracks[0].clips().iter().map(|c| c.name.clone()).collect()
}

#[test]
fn a_good_file_salvages_with_an_empty_report() {
    let p = sample();
    let (back, report) = salvage(&json_of(&p)).unwrap();
    assert!(report.is_empty());
    assert_eq!(back, p);
}

#[test]
fn a_broken_clip_is_dropped_and_listed() {
    let mut obj = json_of(&sample());
    edit_clips(&mut obj, |c| c[1]["kind"] = json!(7));
    assert!(decoded(&obj).is_err());
    let (p, report) = salvage(&obj).unwrap();
    assert_eq!(clip_names(&p), ["A", "C"]);
    assert_eq!(report.dropped.len(), 1);
    assert!(report.dropped[0].contains('B'));
    assert_eq!(p.media.len(), 1);
}

#[test]
fn a_broken_effect_is_dropped_and_the_clip_stays() {
    let mut p = sample();
    let mut c = p.timelines[0].tracks[0].clips()[0].clone();
    c.effects.push(effect("roundedCorners"));
    p.timelines[0].tracks[0].replace(c);
    let mut obj = json_of(&p);
    edit_clips(&mut obj, |cl| cl[0]["effects"][0]["id"] = json!("not-a-uuid"));
    let (back, report) = salvage(&obj).unwrap();
    assert_eq!(back.timelines[0].tracks[0].clips().len(), 3);
    assert!(back.timelines[0].tracks[0].clips()[0].effects.is_empty());
    assert_eq!(report.dropped.iter().filter(|l| l.starts_with("Effect")).count(), 1);
}

#[test]
fn a_broken_media_item_becomes_an_offline_placeholder() {
    let p = sample();
    let mut obj = json_of(&p);
    obj["project"]["media"][0]["fingerprint"] = json!("garbage");
    let (back, report) = salvage(&obj).unwrap();
    assert_eq!(back.media.len(), 1);
    assert_eq!(back.media[0].id, p.media[0].id);
    assert_eq!(back.media[0].path, "/x/m.mov");
    assert_eq!(back.timelines[0].tracks[0].clips().len(), 3);
    assert_eq!(report.dropped.len(), 1);
}

fn with_second_sequence() -> (Project, Id) {
    let mut p = sample();
    let second =
        Timeline::new(id(21), "Second", SequenceFormat::new(t(1, 30)), vec![Track::new(id(51), TrackKind::Video)]);
    p.timelines.push(second);
    (p, id(21))
}

#[test]
fn a_broken_sequence_is_dropped_the_rest_opens() {
    let (p, _) = with_second_sequence();
    let mut obj = json_of(&p);
    obj["project"]["timelines"][1]["format"] = json!("nope");
    let (back, report) = salvage(&obj).unwrap();
    assert_eq!(back.timelines.iter().map(|t| t.name.as_str()).collect::<Vec<_>>(), ["Main"]);
    assert_eq!(report.dropped.len(), 1);
    assert!(report.dropped[0].contains("Second"));
}

#[test]
fn a_file_that_is_not_a_project_stays_corrupt() {
    assert_eq!(ProjectFile::without_fixups().salvage(b"{}"), Err(ProjectFileError::Corrupt));
    assert_eq!(ProjectFile::without_fixups().salvage(b"nonsense"), Err(ProjectFileError::Corrupt));
    assert_eq!(
        ProjectFile::without_fixups().salvage(br#"{"formatVersion":50,"project":[]}"#),
        Err(ProjectFileError::Corrupt)
    );
}

#[test]
fn a_newer_file_is_still_refused_by_salvage() {
    let mut obj = json_of(&sample());
    obj["formatVersion"] = json!(CURRENT_VERSION + 1);
    assert_eq!(
        salvage(&obj),
        Err(ProjectFileError::NewerVersion { found: CURRENT_VERSION + 1, supported: CURRENT_VERSION })
    );
}

#[test]
fn read_salvaging_never_writes_the_original() {
    let dir = TempDir::new();
    let pkg = dir.package();
    let mut obj = json_of(&sample());
    edit_clips(&mut obj, |c| c[0]["kind"] = json!(7));
    let bytes = serde_json::to_vec(&obj).unwrap();
    fs::write(pkg.join("project.json"), &bytes).unwrap();
    let (_, report) = ProjectFile::without_fixups().read_salvaging(&pkg).unwrap();
    assert_eq!(report.dropped.len(), 1);
    assert_eq!(fs::read(pkg.join("project.json")).unwrap(), bytes);
    assert_eq!(fs::read_dir(&pkg).unwrap().count(), 1);
    assert_eq!(
        ProjectFile::without_fixups().read_salvaging(&dir.0.join("none.sqproj")),
        Err(ProjectFileError::Missing)
    );
}

#[test]
fn an_attachment_to_a_dropped_clip_is_cleared() {
    let mut obj = json_of(&sample());
    edit_clips(&mut obj, |cl| {
        cl[1]["kind"] = json!(7); // B is dropped
        let (host, point) = (cl[1]["id"].clone(), cl[2]["start"].clone());
        cl[2]["attachment"] = json!({"host": host, "point": point});
    });
    let (p, _) = salvage(&obj).unwrap();
    assert_eq!(clip_names(&p), ["A", "C"]);
    assert!(p.timelines[0].tracks[0].clips()[1].attachment.is_none());
}

#[test]
fn a_clip_of_unlisted_media_points_at_an_offline_placeholder() {
    let mut obj = json_of(&sample());
    let stray = id(777);
    edit_clips(&mut obj, |cl| {
        cl[0]["kind"] = json!(7); // forces the salvage path
        cl[2]["media"] = json!(stray.to_string());
    });
    let (p, report) = salvage(&obj).unwrap();
    assert!(p.media.iter().any(|m| m.id == stray));
    assert_eq!(p.timelines[0].tracks[0].clips().len(), 2);
    assert!(report.dropped.iter().any(|l| l.starts_with("Media for clip")));
}

#[test]
fn a_nested_sequence_clip_of_a_dropped_sequence_is_dropped() {
    let (p, second) = with_second_sequence();
    let mut obj = json_of(&p);
    obj["project"]["timelines"][1]["format"] = json!("nope"); // Second is dropped
    edit_clips(&mut obj, |cl| cl[1]["sequence"] = json!(second.to_string()));
    let (back, _) = salvage(&obj).unwrap();
    assert_eq!(back.timelines.len(), 1);
    assert_eq!(clip_names(&back), ["A", "C"]);
}

#[test]
fn the_active_sequence_falls_back_when_it_was_dropped() {
    let (mut p, second) = with_second_sequence();
    p.active_timeline = Some(second);
    let mut obj = json_of(&p);
    obj["project"]["timelines"][1]["format"] = json!("nope");
    let (back, _) = salvage(&obj).unwrap();
    assert_eq!(back.active_timeline, None);
}

#[test]
fn back_up_damaged_keeps_the_original_and_never_overwrites_a_backup() {
    let dir = TempDir::new();
    let pkg = dir.package();
    fs::write(pkg.join("project.json"), "one").unwrap();
    let a = ProjectFile::back_up_damaged(&pkg).unwrap().unwrap();
    fs::write(pkg.join("project.json"), "two").unwrap();
    let b = ProjectFile::back_up_damaged(&pkg).unwrap().unwrap();
    assert_ne!(a, b);
    assert_eq!(fs::read(a).unwrap(), b"one");
    assert_eq!(fs::read(b).unwrap(), b"two");
    assert_eq!(ProjectFile::back_up_damaged(&dir.0.join("none.sqproj")).unwrap(), None);
}

// Hostile input: errors, never a panic.

fn visit_paths(v: &Value, path: &mut Vec<String>, out: &mut Vec<Vec<String>>) {
    out.push(path.clone());
    match v {
        Value::Object(o) => {
            for (k, x) in o {
                path.push(k.clone());
                visit_paths(x, path, out);
                path.pop();
            }
        }
        Value::Array(a) => {
            for (i, x) in a.iter().enumerate() {
                path.push(i.to_string());
                visit_paths(x, path, out);
                path.pop();
            }
        }
        _ => {}
    }
}

fn set_at(root: &mut Value, path: &[String], new: Value) {
    let mut cur = root;
    for key in path {
        let next = match cur {
            Value::Object(o) => o.get_mut(key),
            Value::Array(a) => key.parse::<usize>().ok().and_then(|i| a.get_mut(i)),
            _ => None,
        };
        let Some(next) = next else { return };
        cur = next;
    }
    *cur = new;
}

#[test]
fn truncated_files_are_errors() {
    let pf = ProjectFile::without_fixups();
    let data = pf.encode(&sample()).unwrap();
    for cut in (0..data.len()).step_by(7) {
        assert!(pf.decode(&data[..cut], None).is_err(), "cut at {cut}");
        assert!(pf.salvage(&data[..cut]).is_err(), "salvage cut at {cut}");
    }
}

#[test]
fn every_value_replaced_by_something_hostile_never_panics() {
    let pf = ProjectFile::without_fixups();
    let mut p = sample();
    p.set_notes("notes");
    let base = json_of(&p);
    let mut paths = Vec::new();
    visit_paths(&base, &mut Vec::new(), &mut paths);
    let hostile = [
        json!(null),
        json!("x"),
        json!(-1),
        json!(0),
        json!(1e300),
        json!(-1e300),
        json!(9_223_372_036_854_775_807_i64),
        json!(-9_223_372_036_854_775_808_i64),
        json!(18_446_744_073_709_551_615_u64),
        json!([]),
        json!({}),
        json!("NaN"),
        json!([[[[]]]]),
    ];
    let mut errors = 0;
    for path in &paths {
        for h in &hostile {
            let mut v = base.clone();
            set_at(&mut v, path, h.clone());
            let bytes = serde_json::to_vec(&v).unwrap();
            errors += usize::from(pf.decode(&bytes, None).is_err());
            let _ = pf.salvage(&bytes);
        }
    }
    assert!(errors > 100, "{errors}");
}

#[test]
fn huge_and_deeply_nested_json_is_an_error() {
    let pf = ProjectFile::without_fixups();
    let deep = format!(r#"{{"formatVersion":50,"project":{}{}}}"#, "[".repeat(100_000), "]".repeat(100_000));
    assert_eq!(pf.decode(deep.as_bytes(), None), Err(ProjectFileError::Corrupt));
    assert!(pf.salvage(deep.as_bytes()).is_err());
    let deep_obj = format!(r#"{{"formatVersion":50,"project":{}1{}}}"#, r#"{"a":"#.repeat(5_000), "}".repeat(5_000));
    assert_eq!(pf.decode(deep_obj.as_bytes(), None), Err(ProjectFileError::Corrupt));
    let long_digits = format!(r#"{{"formatVersion":{},"project":{{}}}}"#, "9".repeat(100_000));
    assert_eq!(pf.decode(long_digits.as_bytes(), None), Err(ProjectFileError::Corrupt));
}

#[test]
fn a_time_with_a_hostile_scale_is_rejected() {
    let mut obj = json_of(&sample());
    edit_clips(&mut obj, |c| c[0]["start"] = json!({"value": 1, "timescale": 0}));
    assert!(decoded(&obj).is_err());
    edit_clips(&mut obj, |c| {
        c[0]["start"] = json!({"value": 9_223_372_036_854_775_807_i64, "timescale": -9_223_372_036_854_775_808_i64})
    });
    assert!(decoded(&obj).is_err());
}

#[test]
fn write_then_read_keeps_unicode_and_extreme_numbers() {
    let dir = TempDir::new();
    let pkg = dir.package();
    let mut p = sample();
    p.name = "Ünïcode ✓ \"quotes\" / slash".into();
    let mut c = p.timelines[0].tracks[0].clips()[0].clone();
    c.audio_gain_db = 1e-300;
    c.start = t(0, 1);
    c.animation.opacity.value = 0.123_456_789_012_345;
    p.timelines[0].tracks[0].replace(c);
    let pf = ProjectFile::without_fixups();
    pf.write(&p, &pkg).unwrap();
    assert_eq!(pf.read(&pkg).unwrap(), p);
}

/// v26 kept the grade inside `color`; v27 moves it into Color effects (Swift `Clip.adoptLegacyGrade`, ProjectFile+V27).
#[test]
fn v26_grade_in_color_becomes_color_effects() {
    use sq_core_color::{ClipEffectColorExt, ClipGradeExt};
    let color = r#","color":{"source":"rec709","useEmbeddedLUT":false,"effects":[
        {"id":1,"inputLUT":null,"basic":{"exposure":1.5,"contrast":20}},{"id":2,"basic":{"temperature":-10}}]}"#;
    let pf = ProjectFile::without_fixups();
    let p = pf.decode(old_file(26, &track_json("video", color)).as_bytes(), None).unwrap();
    let c = &p.timelines[0].tracks[0].clips()[0];
    assert_eq!(c.footage_color.source, Some(sq_core_model::ColorSpaceID::Rec709));
    assert!(!c.footage_color.use_embedded_lut && c.footage_color.legacy_effects.is_none());
    let grades = c.color_grade_effects();
    assert_eq!(grades.len(), 2);
    assert_eq!(c.effects.len(), 2);
    let first = grades[0].color_effect(None, 1);
    assert_eq!((first.basic.exposure, first.basic.contrast, first.input_lut.clone()), (1.5, 20.0, None));
    assert_eq!(grades[1].color_effect(None, 2).basic.temperature, -10.0);
    // The result survives a save and load, and the stored `color` no longer holds effects.
    let bytes = pf.encode(&p).unwrap();
    let text = String::from_utf8(bytes.clone()).unwrap();
    assert!(!text.contains("\"basic\":{\"exposure\"") || text.contains("\"kind\""));
    let again = pf.decode(&bytes, None).unwrap();
    assert_eq!(again.timelines[0].tracks[0].clips()[0].color_grade_effects().len(), 2);
}

#[test]
fn v26_neutral_grade_and_existing_color_effects_add_nothing() {
    use sq_core_color::ClipGradeExt;
    let pf = ProjectFile::without_fixups();
    let neutral = r#","color":{"useEmbeddedLUT":true}"#;
    let p = pf.decode(old_file(26, &track_json("video", neutral)).as_bytes(), None).unwrap();
    assert!(p.timelines[0].tracks[0].clips()[0].effects.is_empty());
    // An audio clip takes no color: its old grade is dropped.
    let graded = r#","color":{"effects":[{"id":1,"basic":{"exposure":2}}]}"#;
    let p = pf.decode(old_file(26, &track_json("audio", graded)).as_bytes(), None).unwrap();
    assert!(p.timelines[0].tracks[0].clips()[0].color_grade_effects().is_empty());
}

// ProjectFileV67Tests: Fast Cut (`Timeline.edit_mode`, `Clip.attachment`) is v67; Normal-only projects are written exactly
// as the v66 build wrote them (apart from the writing build's `appFormat`).

/// The Swift fixture's ids: `00000000-0000-0000-0000-<n as 12 decimal digits>`.
fn v67_id(n: u128) -> Id {
    Id::parse(&format!("00000000-0000-0000-0000-{n:012}")).unwrap()
}

/// A fixed Normal-mode project (fixed ids): main track, a linked b-roll pair, a title on V2, a nested sequence, a transition.
fn v67_fixture() -> Project {
    let fd = t(1, 30);
    let mk = |n: u128,
              name: &str,
              media: u128,
              kind: TrackKind,
              src: (i64, i64),
              start: i64,
              link: Option<u128>,
              md: i64| {
        let mut c = Clip::new(v67_id(n), name, v67_id(media), kind, range(t(src.0, 1), t(src.1, 1)), t(start, 1));
        c.link = link.map(v67_id);
        c.media_duration = Some(t(md, 1));
        c
    };
    let a = mk(1, "A", 100, TrackKind::Video, (0, 4), 0, Some(50), 20);
    let a_sound = mk(2, "A", 100, TrackKind::Audio, (0, 4), 0, Some(50), 20);
    let b = mk(3, "B", 101, TrackKind::Video, (2, 3), 4, None, 20);
    let title = mk(4, "T", 102, TrackKind::Video, (0, 2), 5, None, 10);
    let roll = mk(5, "R", 103, TrackKind::Video, (0, 1), 1, Some(51), 10);
    let roll_sound = mk(6, "R", 103, TrackKind::Audio, (0, 2), 1, Some(51), 10);
    let mut ids = SequentialIds::default();
    let mut track = |n: u128, kind, clips: Vec<Clip>, targeted: bool| {
        let mut tr = Track::new(v67_id(n), kind);
        for c in clips {
            tr.overwrite(c, &mut ids).unwrap();
        }
        tr.is_targeted = targeted;
        tr
    };
    let mut v1 = track(10, TrackKind::Video, vec![a, b], true);
    v1.transitions.push(
        serde_json::from_value(json!({
            "id": v67_id(60).to_string(), "kind": "crossDissolve", "duration": serde_json::to_value(t(1, 1)).unwrap(),
            "alignment": "center", "customBefore": serde_json::to_value(Time::ZERO).unwrap(),
            "outgoing": v67_id(1).to_string(), "incoming": v67_id(3).to_string(),
        }))
        .unwrap(),
    );
    let v2 = track(11, TrackKind::Video, vec![roll, title], false);
    let a1 = track(12, TrackKind::Audio, vec![a_sound], true);
    let a2 = track(13, TrackKind::Audio, vec![roll_sound], false);
    let top = Timeline::new(v67_id(20), "Sequence 01", SequenceFormat::new(fd), vec![v1, v2, a1, a2]);
    let inner =
        Timeline::new(v67_id(21), "Nested", SequenceFormat::new(fd), vec![track(14, TrackKind::Video, vec![], false)]);
    Project::new(v67_id(30), "Fixture", Vec::new(), vec![top, inner])
}

/// SHA-256 as in the Swift test's portable fallback.
fn sha256(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98,
        0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8,
        0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
        0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut h: [u32; 8] =
        [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    let mut msg = data.to_vec();
    let bits = (msg.len() as u64) * 8;
    msg.push(0x80);
    while msg.len() % 64 != 56 {
        msg.push(0);
    }
    msg.extend_from_slice(&bits.to_be_bytes());
    for chunk in msg.chunks(64) {
        let mut w = [0u32; 64];
        for (i, b) in chunk.chunks(4).enumerate() {
            w[i] = u32::from_be_bytes([b[0], b[1], b[2], b[3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let mut v = h;
        for i in 0..64 {
            let s1 = v[4].rotate_right(6) ^ v[4].rotate_right(11) ^ v[4].rotate_right(25);
            let ch = (v[4] & v[5]) ^ (!v[4] & v[6]);
            let t1 = v[7].wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = v[0].rotate_right(2) ^ v[0].rotate_right(13) ^ v[0].rotate_right(22);
            let maj = (v[0] & v[1]) ^ (v[0] & v[2]) ^ (v[1] & v[2]);
            let t2 = s0.wrapping_add(maj);
            v = [t1.wrapping_add(t2), v[0], v[1], v[2], v[3].wrapping_add(t1), v[4], v[5], v[6]];
        }
        for (x, y) in h.iter_mut().zip(v) {
            *x = x.wrapping_add(y);
        }
    }
    h.iter().map(|x| format!("{x:08x}")).collect()
}

/// serde's pretty text in Foundation's layout: `"key" : value`, and `[` / `{` with nothing inside spread over two lines
/// (the content of the file is the same either way; only this hash check needs the Swift bytes).
fn foundation_layout(text: &str) -> String {
    let mut out = Vec::new();
    for line in text.lines() {
        let indent = line.len() - line.trim_start().len();
        let body = line.trim_start();
        let body = match body.strip_prefix('"').and_then(|b| b.split_once("\": ")) {
            Some((key, rest)) => format!("\"{key}\" : {rest}"),
            None => body.to_string(),
        };
        let pad = " ".repeat(indent);
        let spread = |open: &str, close: &str, out: &mut Vec<String>| {
            let head =
                body.strip_suffix(&format!("{open}{close}")).or_else(|| body.strip_suffix(&format!("{open}{close},")));
            let comma = if body.ends_with(',') { "," } else { "" };
            head.map(|h| {
                out.push(format!("{pad}{h}{open}"));
                out.push(String::new());
                out.push(format!("{pad}{close}{comma}"));
            })
            .is_some()
        };
        if !(spread("[", "]", &mut out) || spread("{", "}", &mut out)) {
            out.push(format!("{pad}{body}"));
        }
    }
    out.join("\n")
}

/// SHA-256 of the fixture as the Swift v66 build wrote it (appFormat 66, formatVersion 36).
const V66_FIXTURE_SHA256: &str = "5fff30b978ed97b5f20485de3446c44adcaba3123f0a592f46d3748cad813d2d";

#[test]
fn v67_normal_project_is_byte_identical_to_the_swift_v66_output() {
    let pf = ProjectFile::without_fixups();
    let p = v67_fixture();
    let data = pf.encode(&p).unwrap();
    let text = String::from_utf8(data.clone()).unwrap();
    assert!(!text.contains("editMode") && !text.contains("attachment"));
    let as_v66 =
        foundation_layout(&text).replace(&format!("\"appFormat\" : {CURRENT_VERSION},"), "\"appFormat\" : 66,");
    assert_eq!(sha256(as_v66.as_bytes()), V66_FIXTURE_SHA256, "bytes differ from the Swift v66 writer:\n{as_v66}");
    // Decode and encode again (direct and through the migration chain): still the same bytes.
    assert_eq!(pf.encode(&pf.decode(&data, None).unwrap()).unwrap(), data);
    assert_eq!(pf.encode(&pf.decode(&data, Some(&pf.migrations())).unwrap()).unwrap(), data);
}

#[test]
fn v67_mode_back_to_normal_without_attachments_is_byte_identical() {
    use sq_core_model::TimelineEditMode;
    let p = v67_fixture();
    let mut q = p.clone();
    q.timelines[0].set_edit_mode_stored(TimelineEditMode::Magnetic);
    q.timelines[0].set_edit_mode_stored(TimelineEditMode::Normal);
    let pf = ProjectFile::without_fixups();
    assert_eq!(pf.encode(&q).unwrap(), pf.encode(&p).unwrap());
}

#[test]
fn v67_fast_cut_sequence_writes_v67_and_round_trips() {
    use sq_core_model::TimelineEditMode;
    let mut p = v67_fixture();
    let top = p.timelines[0].id;
    p.set_edit_mode(TimelineEditMode::Magnetic, top).unwrap();
    assert_eq!(ProjectFile::written_version(&p), 67);
    let pf = ProjectFile::without_fixups();
    let data = pf.encode(&p).unwrap();
    let obj: Value = serde_json::from_slice(&data).unwrap();
    assert_eq!(obj["formatVersion"], 67);
    assert_eq!(obj["appFormat"], CURRENT_VERSION);
    let back = pf.decode(&data, None).unwrap();
    assert_eq!(back, p);
    assert_eq!(back.timelines[0].edit_mode(), TimelineEditMode::Magnetic);
    assert_eq!(back.timelines[1].edit_mode(), TimelineEditMode::Normal);
    assert!(back.timelines[0].tracks.iter().flat_map(|t| t.clips()).any(|c| c.attachment.is_some()));
    assert_eq!(pf.encode(&back).unwrap(), data);
    assert_eq!(pf.decode(&data, Some(&pf.migrations())).unwrap(), p);
}

/// An attachment alone (a Normal sequence that was in Fast Cut before) also needs v67.
#[test]
fn v67_attachment_alone_writes_v67() {
    use sq_core_model::TimelineEditMode;
    let mut p = v67_fixture();
    p.timelines[0].set_edit_mode(TimelineEditMode::Magnetic);
    p.timelines[0].set_edit_mode(TimelineEditMode::Normal);
    assert_eq!(p.timelines[0].edit_mode(), TimelineEditMode::Normal);
    assert_eq!(ProjectFile::written_version(&p), 67);
    let pf = ProjectFile::without_fixups();
    let data = pf.encode(&p).unwrap();
    assert!(!String::from_utf8_lossy(&data).contains("editMode"));
    assert_eq!(pf.decode(&data, None).unwrap(), p);
}

#[test]
fn v67_nested_sequence_in_fast_cut_gates_too_and_wins_over_older_gates() {
    use sq_core_model::TimelineEditMode;
    let mut p = v67_fixture();
    p.timelines[1].set_edit_mode_stored(TimelineEditMode::Magnetic);
    assert_eq!(ProjectFile::written_version(&p), 67);
    let mut q = v67_fixture();
    q.timelines[0].set_master_volume_db(-6.0);
    assert_eq!(ProjectFile::written_version(&q), 66);
    q.timelines[0].set_edit_mode_stored(TimelineEditMode::Magnetic);
    assert_eq!(ProjectFile::written_version(&q), 67);
}

#[test]
fn v67_v66_file_still_opens_and_a_newer_one_is_refused() {
    let pf = ProjectFile::without_fixups();
    let p = v67_fixture();
    let mut obj = json_of(&p);
    obj["formatVersion"] = json!(66);
    obj["appFormat"] = json!(66);
    let back = pf.decode(&serde_json::to_vec(&obj).unwrap(), Some(&pf.migrations())).unwrap();
    assert_eq!(back, p);
    assert!(back.timelines.iter().all(|t| t.edit_mode() == sq_core_model::TimelineEditMode::Normal));
    obj["formatVersion"] = json!(CURRENT_VERSION + 1);
    let newer = serde_json::to_vec(&obj).unwrap();
    let err = ProjectFileError::NewerVersion { found: CURRENT_VERSION + 1, supported: CURRENT_VERSION };
    assert_eq!(pf.decode(&newer, Some(&pf.migrations())), Err(err.clone()));
    assert_eq!(pf.decode(&newer, None), Err(err));
}

/// Saving over a file a v66 build wrote keeps a backup of it, like every earlier version step.
#[test]
fn v67_saving_over_a_v66_file_backs_it_up() {
    use sq_core_model::TimelineEditMode;
    let dir = TempDir::new();
    let pkg = dir.package();
    let mut obj = json_of(&v67_fixture());
    obj["appFormat"] = json!(66);
    fs::write(pkg.join("project.json"), serde_json::to_vec(&obj).unwrap()).unwrap();
    let mut p = v67_fixture();
    p.timelines[0].set_edit_mode(TimelineEditMode::Magnetic);
    let pf = ProjectFile::without_fixups();
    pf.write(&p, &pkg).unwrap();
    let backups: Vec<String> = fs::read_dir(&dir.0)
        .unwrap()
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    assert!(backups.iter().any(|n| n.ends_with(".v36.bak")), "{backups:?}");
    assert_eq!(pf.read(&pkg).unwrap(), p);
}

/// An unknown future edit mode opens as Normal instead of failing the whole file.
#[test]
fn v67_unknown_edit_mode_decodes_as_normal() {
    let tl = Timeline::new(id(1), "S", SequenceFormat::new(t(1, 30)), Vec::new());
    let mut obj = serde_json::to_value(&tl).unwrap();
    obj["editMode"] = json!("storyline");
    let back: Timeline = serde_json::from_value(obj).unwrap();
    assert_eq!(back.edit_mode(), sq_core_model::TimelineEditMode::Normal);
}

// W7.6 audit: version gates from the Swift ProjectFileV*Tests (plain projects keep their version, defaults store nothing,
// settings write the gate version and round trip).

fn first_clip(p: &Project) -> Clip {
    p.timelines[0].tracks[0].clips()[0].clone()
}

fn replace_first(p: &mut Project, f: impl FnOnce(&mut Clip)) {
    let mut c = first_clip(p);
    f(&mut c);
    p.timelines[0].tracks[0].replace(c);
}

fn bytes(p: &Project) -> Vec<u8> {
    ProjectFile::without_fixups().encode(p).unwrap()
}

fn round_trips(p: &Project, version: i64, what: &str) {
    assert_eq!(format_version(p), version, "{what}");
    let back = decoded(&json_of(p)).unwrap();
    assert_eq!(&back, p, "{what}");
}

#[test]
fn a_new_blend_mode_is_written_as_v41_but_the_old_ones_keep_the_lowest_version() {
    use sq_core_model::BlendMode;
    let mut p = sample();
    replace_first(&mut p, |c| c.blend_mode = BlendMode::Screen);
    assert_eq!(ProjectFile::written_version(&p), 36);
    replace_first(&mut p, |c| c.blend_mode = BlendMode::Difference);
    assert_eq!(ProjectFile::written_version(&p), 41);
    let back = decoded(&json_of(&p)).unwrap();
    assert_eq!(first_clip(&back).blend_mode, BlendMode::Difference);
}

#[test]
fn clip_markers_bump_to_v60_and_round_trip_and_clips_without_markers_keep_their_version() {
    use sq_core_model::{Marker, MarkerColor};
    let mut p = sample();
    replace_first(&mut p, |c| c.markers = Some(vec![]));
    assert_eq!(ProjectFile::written_version(&p), 36);
    let m = Marker {
        id: id(700),
        time: t(3, 1),
        name: "Beat".into(),
        color: MarkerColor::Red,
        comment: "hit".into(),
        duration: t(1, 2),
    };
    replace_first(&mut p, |c| c.markers = Some(vec![m.clone()]));
    round_trips(&p, 60, "markers");
    assert_eq!(first_clip(&decoded(&json_of(&p)).unwrap()).markers, Some(vec![m]));
}

#[test]
fn new_effect_kinds_write_their_gate_version_and_round_trip_and_plain_projects_keep_theirs() {
    for (kinds, version) in
        [(&["halftone", "tile", "kaleidoscope"][..], 61), (&["trails", "alphaOutline", "longShadow"][..], 64)]
    {
        for kind in kinds {
            let mut p = sample();
            replace_first(&mut p, |c| c.effects.push(effect(kind)));
            round_trips(&p, version, kind);
        }
    }
    let mut blur = sample();
    replace_first(&mut blur, |c| c.effects.push(effect("gaussianBlur")));
    assert_eq!(ProjectFile::written_version(&blur), 36);
}

#[test]
fn an_adjustment_layer_with_a_blur_and_extend_to_sequence_end_round_trips() {
    use sq_core_model::GeneratorRef;
    let mut p = sample();
    replace_first(&mut p, |c| {
        c.generator = Some(GeneratorRef { kind: "adjustment".into(), payload: Vec::new(), payload_version: 1 });
        c.effects.push(effect("gaussianBlur"));
        c.extends_to_end_store = Some(true);
    });
    let version = ProjectFile::written_version(&p);
    assert!(version > 36, "the adjustment layer gates the file version");
    round_trips(&p, version, "adjustment layer");
    assert_eq!(first_clip(&decoded(&json_of(&p)).unwrap()).extends_to_end_store, Some(true));
}

#[test]
fn an_adjustment_zoom_with_keyed_motion_scale_round_trips() {
    use sq_core_model::GeneratorRef;
    use sq_core_time::{Keyframe, Vec2};
    let mut p = sample();
    replace_first(&mut p, |c| {
        c.generator = Some(GeneratorRef { kind: "adjustment".into(), payload: Vec::new(), payload_version: 1 });
        c.animation.scale.track.insert(Keyframe::new(id(911), t(0, 1), Vec2::new(1.0, 1.0)));
        c.animation.scale.track.insert(Keyframe::new(id(912), t(1, 2), Vec2::new(1.1, 1.1)));
        c.animation.scale.track.insert(Keyframe::new(id(913), t(1, 1), Vec2::new(1.0, 1.0)));
    });
    let version = ProjectFile::written_version(&p);
    assert!(version > 36, "the adjustment layer gates the file version");
    round_trips(&p, version, "adjustment zoom");
    let back = first_clip(&decoded(&json_of(&p)).unwrap());
    assert_eq!(back.animation.scale.track.keys.len(), 3);
    assert_eq!(back.animation.scale.value_at_local(t(1, 2)), Vec2::new(1.1, 1.1));
}

#[test]
fn animation_zones_bump_to_v58_and_round_trip() {
    use sq_core_model::{AnimationZones, ZoneMiddle};
    let mut p = sample();
    replace_first(&mut p, |c| {
        c.zones = Some(AnimationZones {
            intro_end: t(1, 2),
            outro_length: t(1, 2),
            middle: ZoneMiddle::Stretch,
            design_duration: Some(t(3, 1)),
        })
    });
    round_trips(&p, 58, "zones");
}

#[test]
fn timecode_and_preview_settings_write_v81_and_defaults_store_nothing() {
    use sq_core_model::{SequencePreviewQuality, TimecodeDisplay};
    let mut p = sample();
    let before = bytes(&p);
    p.timelines[0].set_timecode_start(t(3600, 1));
    p.timelines[0].set_timecode_start(Time::ZERO);
    p.timelines[0].set_timecode_display(TimecodeDisplay::Frames);
    p.timelines[0].set_timecode_display(TimecodeDisplay::Timecode);
    p.timelines[0].set_preview_quality(Some(SequencePreviewQuality::Half));
    p.timelines[0].set_preview_quality(None);
    assert_eq!(bytes(&p), before);
    let text = String::from_utf8(before).unwrap();
    assert!(!text.contains("timecodeStart") && !text.contains("previewQuality"));
    assert!(ProjectFile::written_version(&p) < 81);

    p.timelines[0].set_timecode_start(t(3600, 1));
    p.timelines[0].set_timecode_display(TimecodeDisplay::Frames);
    p.timelines[0].set_preview_quality(Some(SequencePreviewQuality::Quarter));
    round_trips(&p, 81, "v81");
    let back = decoded(&json_of(&p)).unwrap();
    assert_eq!(back.timelines[0].timecode_start(), t(3600, 1));
    assert_eq!(back.timelines[0].timecode_display(), TimecodeDisplay::Frames);
    assert_eq!(back.timelines[0].preview_quality(), Some(SequencePreviewQuality::Quarter));
}

#[test]
fn channel_layout_and_pixel_shape_write_v82_and_defaults_store_nothing() {
    use sq_core_model::{ChannelLayout, PixelAspect};
    let mut p = sample();
    let before = bytes(&p);
    p.timelines[0].set_channel_layout(ChannelLayout::Mono);
    p.timelines[0].set_channel_layout(ChannelLayout::Stereo);
    p.timelines[0].format.set_pixel_aspect(PixelAspect::new(2, 1).unwrap());
    p.timelines[0].format.set_pixel_aspect(PixelAspect::square());
    assert_eq!(bytes(&p), before);
    let text = String::from_utf8(before).unwrap();
    assert!(!text.contains("channelLayout") && !text.contains("pixelAspect"));
    assert!(ProjectFile::written_version(&p) < 82);

    p.timelines[0].set_channel_layout(ChannelLayout::Mono);
    round_trips(&p, 82, "mono");
    assert_eq!(decoded(&json_of(&p)).unwrap().timelines[0].channel_layout(), ChannelLayout::Mono);
    let mut q = sample();
    q.timelines[0].format.set_pixel_aspect(PixelAspect::new(2, 1).unwrap());
    round_trips(&q, 82, "pixel shape");
}

#[test]
fn notes_write_v83_and_empty_notes_store_nothing() {
    let mut p = sample();
    let before = bytes(&p);
    p.set_notes("x");
    p.set_notes("");
    assert_eq!(bytes(&p), before);
    assert!(!String::from_utf8(before).unwrap().contains("\"notes\""));
    assert!(ProjectFile::written_version(&p) < 83);
    p.set_notes("Client wants captions in yellow.\nDeliver Friday.");
    round_trips(&p, 83, "notes");
    assert_eq!(decoded(&json_of(&p)).unwrap().notes(), "Client wants captions in yellow.\nDeliver Friday.");
}

#[test]
fn live_ducking_settings_are_written_as_v43_and_round_trip() {
    use sq_core_model::ProjectLiveDucking;
    let mut p = sample();
    assert_eq!(ProjectFile::written_version(&p), 36);
    p.live_ducking = Some(ProjectLiveDucking { is_on: true, amount_db: 15.0, timing: None });
    round_trips(&p, 43, "ducking");
    p.live_ducking = None;
    p.timelines[0].tracks[0].set_excluded_from_live_ducking(true);
    round_trips(&p, 43, "excluded track");
    let back = decoded(&json_of(&p)).unwrap();
    assert!(back.timelines[0].tracks[0].is_excluded_from_live_ducking());
}

#[test]
fn off_toggles_write_v91_and_on_toggles_keep_the_version() {
    let mut p = sample();
    p.timelines[0].snapping_off_store = Some(true);
    assert_eq!(ProjectFile::written_version(&p), 91);
    let back = decoded(&json_of(&p)).unwrap();
    assert!(
        back.timelines[0].snapping_off_store == Some(true)
            && back.timelines[0].linked_selection_off_store != Some(true)
    );
    let mut q = sample();
    q.timelines[0].linked_selection_off_store = Some(true);
    round_trips(&q, 91, "linked selection off");
    q.timelines[0].linked_selection_off_store = None;
    assert_eq!(ProjectFile::written_version(&q), 36);
}

#[test]
fn old_effect_kinds_keep_their_version() {
    let mut blur = sample();
    replace_first(&mut blur, |c| c.effects.push(effect("gaussianBlur")));
    assert_eq!(ProjectFile::written_version(&blur), 36);
    // An audio effect of the v39 set stays at v39 (Swift: audioCompressor on an audio clip).
    let mut audio = sample();
    let mut au = clip(30, "au", id(100), TrackKind::Audio, 0);
    au.effects.push(effect("audio.compressor"));
    let mut tr = Track::new(id(51), TrackKind::Audio);
    tr.overwrite(au, &mut SequentialIds::default()).unwrap();
    audio.timelines[0].tracks.push(tr);
    assert_eq!(ProjectFile::written_version(&audio), 39);
}

/// D4: a newer file's extra keys at the top level, project, sequence, clip and media item survive open and save.
#[test]
fn keys_this_build_does_not_know_are_written_back() {
    let mut with_effect = sample();
    replace_first(&mut with_effect, |c| c.effects.push(effect("gaussianBlur")));
    let mut v = json_of(&with_effect);
    v["project"]["timelines"][0]["format"]["zzFutureFormat"] = json!([1]);
    v["project"]["timelines"][0]["tracks"][0]["zzFutureTrack"] = json!("t");
    v["project"]["timelines"][0]["tracks"][0]["clips"][0]["animation"]["zzFutureAnimation"] = json!({"k": null});
    v["project"]["rootBin"]["zzFutureBin"] = json!(2);
    v["project"]["timelines"][0]["tracks"][0]["clips"][0]["effects"][0]["zzFutureEffect"] = json!({"y": [true]});
    v["zzFutureTop"] = json!({"a": [1, 2]});
    v["project"]["zzFutureProject"] = json!("p");
    v["project"]["timelines"][0]["zzFutureTimeline"] = json!(7);
    v["project"]["timelines"][0]["tracks"][0]["clips"][1]["zzFutureClip"] = json!({"x": 1.5});
    v["project"]["media"][0]["zzFutureMedia"] = json!(true);
    let project = decoded(&v).unwrap();
    // An edit on the clip next to it does not matter; the file the editor saves has every key again.
    let saved = json_of(&project);
    assert_eq!(saved["zzFutureTop"], json!({"a": [1, 2]}));
    assert_eq!(saved["project"]["zzFutureProject"], json!("p"));
    assert_eq!(saved["project"]["timelines"][0]["zzFutureTimeline"], json!(7));
    assert_eq!(saved["project"]["timelines"][0]["tracks"][0]["clips"][1]["zzFutureClip"], json!({"x": 1.5}));
    assert_eq!(saved["project"]["media"][0]["zzFutureMedia"], json!(true));
    assert_eq!(saved["project"]["timelines"][0]["format"]["zzFutureFormat"], json!([1]));
    assert_eq!(saved["project"]["timelines"][0]["tracks"][0]["zzFutureTrack"], json!("t"));
    assert_eq!(
        saved["project"]["timelines"][0]["tracks"][0]["clips"][0]["animation"]["zzFutureAnimation"],
        json!({"k": null})
    );
    assert_eq!(saved["project"]["rootBin"]["zzFutureBin"], json!(2));
    assert_eq!(
        saved["project"]["timelines"][0]["tracks"][0]["clips"][0]["effects"][0]["zzFutureEffect"],
        json!({"y": [true]})
    );
    assert_eq!(
        saved["project"]["timelines"][0]["tracks"][0]["clips"][0].get("zzFutureClip"),
        None,
        "only where it was"
    );
    // The file the format owns is still the format's.
    assert_eq!(saved["appFormat"], CURRENT_VERSION);
    assert_eq!(saved, json_of(&decoded(&saved).unwrap()), "a second round trip changes nothing");
}

// Unknown keys at every level (round 4 of the Linux test: ten of 23 injected values were lost and the file opened as a repaired copy).

/// Keys under these names hold data (a map from names to values), not a struct, so no extra key may go in.
const DATA_MAPS: [&str; 4] = ["parameters", "sourceMarks", "activeVariants", "settings"];

/// The paths of every struct-like object (not a data map).
fn object_paths(v: &Value, path: &mut Vec<String>, out: &mut Vec<Vec<String>>) {
    match v {
        Value::Object(o) => {
            if !path.last().is_some_and(|k| DATA_MAPS.contains(&k.as_str())) {
                out.push(path.clone());
            }
            for (k, child) in o {
                path.push(k.clone());
                object_paths(child, path, out);
                path.pop();
            }
        }
        Value::Array(a) => {
            for (i, child) in a.iter().enumerate() {
                path.push(i.to_string());
                object_paths(child, path, out);
                path.pop();
            }
        }
        _ => {}
    }
}

fn at_path_mut<'v>(v: &'v mut Value, path: &[String]) -> Option<&'v mut Value> {
    path.iter().try_fold(v, |v, k| match v {
        Value::Array(a) => a.get_mut(k.parse::<usize>().ok()?),
        _ => v.get_mut(k),
    })
}

fn at_path<'v>(v: &'v Value, path: &[String]) -> Option<&'v Value> {
    path.iter().try_fold(v, |v, k| match v {
        Value::Array(a) => a.get(k.parse::<usize>().ok()?),
        _ => v.get(k),
    })
}

fn rich_project() -> Project {
    use sq_core_time::{Interpolation, Keyframe};
    let mut p = sample();
    let mut ids = SequentialIds::default();
    let outer = p.new_bin("Outer", None, &mut ids).unwrap();
    p.new_bin("Inner", Some(outer), &mut ids).unwrap();
    replace_first(&mut p, |c| {
        c.effects.push(effect("gaussianBlur"));
        let mut k = Keyframe::new(id(901), t(0, 1), 0.0);
        k.interpolation = Interpolation::Linear;
        c.animation.opacity.track.insert(k);
        c.animation.opacity.track.insert(Keyframe::new(id(902), t(1, 1), 1.0));
    });
    p
}

#[test]
fn extra_keys_at_every_level_open_as_a_normal_file_and_survive_a_save() {
    let base = json_of(&rich_project());
    let mut paths = Vec::new();
    object_paths(&base, &mut Vec::new(), &mut paths);
    // A bin item is an enum wrapper (`{"media": ...}`): a key beside its tag has no meaning, so it is not a place.
    paths.retain(|p| !p.len().checked_sub(2).is_some_and(|i| p[i] == "children"));
    assert!(paths.len() > 25, "the project should have many objects, has {}", paths.len());
    let pf = ProjectFile::without_fixups();
    let mut problems = Vec::new();
    for path in &paths {
        let mut v = base.clone();
        let extra = json!({"n": 1, "list": [1, {"deep": true}]});
        if let Some(o) = at_path_mut(&mut v, path).and_then(Value::as_object_mut) {
            o.insert("zzExtra".into(), extra.clone());
        }
        let here = path.join("/");
        let Ok((mut project, report)) = pf.salvage(&serde_json::to_vec(&v).unwrap()) else {
            problems.push(format!("{here}: does not open"));
            continue;
        };
        if !report.is_empty() {
            problems.push(format!("{here}: opens as a repaired copy"));
        }
        // Change one thing, save: the extra key is still at its place.
        project.name = "Renamed".into();
        replace_first(&mut project, |c| c.name = "Edited".into());
        let saved: Value = serde_json::from_slice(&pf.encode(&project).unwrap()).unwrap();
        let mut at = path.clone();
        at.push("zzExtra".into());
        if at_path(&saved, &at) != Some(&extra) {
            problems.push(format!("{here}: lost on save"));
        }
    }
    assert!(problems.is_empty(), "{} of {} places: {problems:#?}", problems.len(), paths.len());
}

#[test]
fn an_unknown_enum_value_still_opens_as_a_repaired_copy() {
    let mut v = json_of(&sample());
    v["project"]["timelines"][0]["tracks"][0]["kind"] = json!("hologram");
    let (_, report) = ProjectFile::without_fixups().salvage(&serde_json::to_vec(&v).unwrap()).unwrap();
    assert!(!report.is_empty());
}

#[test]
fn an_unknown_effect_keeps_its_payload_through_a_save() {
    let mut v = json_of(&sample());
    v["project"]["timelines"][0]["tracks"][0]["clips"][0]["effects"] = json!([{
        "id": id(777).to_string(), "kind": "zzFutureEffect", "enabled": true, "parameters": {},
        "zzPayload": {"lut": [1, 2, 3], "nested": {"on": true}}
    }]);
    let pf = ProjectFile::without_fixups();
    let (mut project, report) = pf.salvage(&serde_json::to_vec(&v).unwrap()).unwrap();
    assert!(report.is_empty(), "{:?}", report.dropped);
    project.name = "Changed".into();
    let saved: Value = serde_json::from_slice(&pf.encode(&project).unwrap()).unwrap();
    let effect = &saved["project"]["timelines"][0]["tracks"][0]["clips"][0]["effects"][0];
    assert_eq!(effect["zzPayload"], json!({"lut": [1, 2, 3], "nested": {"on": true}}));
    assert_eq!(effect["kind"], json!("zzFutureEffect"));
}

/// A project file as Swift writes it: 17-digit floats in the animation values, unknown keys at several levels.
fn file_with_long_floats(digits: &[String]) -> Vec<u8> {
    let mut v = json_of(&sample());
    v["unknownEnvelope"] = json!({"a": 1});
    v["project"]["zzProject"] = json!([1, 2]);
    let tl = &mut v["project"]["timelines"][0];
    tl["zzTimeline"] = json!({"deep": {"er": true}});
    for (i, clip) in tl["tracks"][0]["clips"].as_array_mut().unwrap().iter_mut().enumerate() {
        clip["zzClip"] = json!(format!("c{i}"));
        clip["animation"]["position"]["value"] = json!({"x": 1000.5 + i as f64, "y": 2000.5 + i as f64});
    }
    let mut text = String::from_utf8(serde_json::to_vec(&v).unwrap()).unwrap();
    for (i, d) in digits.iter().enumerate() {
        text = text.replace(&format!("{}.5", 1000 + i), d).replace(&format!("{}.5", 2000 + i), d);
    }
    text.into_bytes()
}

/// 17-significant-digit float texts like Swift's encoder writes them.
fn long_float_texts() -> Vec<String> {
    let mut seed = 0x9E37_79B9_7F4A_7C15_u64;
    (0..3)
        .map(|_| {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let mantissa = 1.0 + (seed >> 11) as f64 / (1u64 << 53) as f64;
            format!("-{:.16e}", mantissa * 4.8e-14)
        })
        .chain(["-4.8960835385969403e-14".to_string()])
        .collect()
}

#[test]
fn save_reopen_save_is_byte_identical_with_17_digit_floats_and_unknown_keys() {
    let pf = ProjectFile::without_fixups();
    let mut texts = long_float_texts();
    texts.truncate(3);
    let file = file_with_long_floats(&texts);
    let first = pf.encode(&pf.decode(&file, None).unwrap()).unwrap();
    let second = pf.encode(&pf.decode(&first, None).unwrap()).unwrap();
    let third = pf.encode(&pf.decode(&second, None).unwrap()).unwrap();
    assert_eq!(String::from_utf8_lossy(&first), String::from_utf8_lossy(&second));
    assert_eq!(second, third);
    let saved: Value = serde_json::from_slice(&second).unwrap();
    assert_eq!(saved["unknownEnvelope"], json!({"a": 1}));
    assert_eq!(saved["project"]["zzProject"], json!([1, 2]));
    assert_eq!(saved["project"]["timelines"][0]["zzTimeline"], json!({"deep": {"er": true}}));
    assert_eq!(saved["project"]["timelines"][0]["tracks"][0]["clips"][1]["zzClip"], json!("c1"));
}

#[test]
fn the_exact_flipping_value_is_stable_across_save_cycles() {
    let pf = ProjectFile::without_fixups();
    let file = file_with_long_floats(&["-4.8960835385969403e-14".to_string()]);
    let mut bytes = file;
    let mut seen = Vec::new();
    for _ in 0..4 {
        bytes = pf.encode(&pf.decode(&bytes, None).unwrap()).unwrap();
        seen.push(bytes.clone());
    }
    assert!(seen.windows(2).all(|w| w[0] == w[1]), "every save writes the same bytes");
}

#[test]
fn a_value_edited_in_the_model_wins_over_the_old_file_value_on_save() {
    let pf = ProjectFile::without_fixups();
    let file = file_with_long_floats(&["-4.8960835385969403e-14".to_string()]);
    let mut project = pf.decode(&file, None).unwrap();
    let mut clips = project.timelines[0].tracks[0].clips().to_vec();
    clips[0].animation.position.value.x = 0.123_456_789_012_345_67;
    project.timelines[0].tracks[0].set_clips(clips);
    let saved: Value = serde_json::from_slice(&pf.encode(&project).unwrap()).unwrap();
    let x = &saved["project"]["timelines"][0]["tracks"][0]["clips"][0]["animation"]["position"]["value"]["x"];
    assert_eq!(x.as_f64(), Some(0.123_456_789_012_345_67));
    assert_eq!(saved["project"]["timelines"][0]["tracks"][0]["clips"][0]["zzClip"], json!("c0"));
}

// Windows media paths: an earlier build stored `canonicalize`'s verbatim spelling, which the shell cannot open.

fn media_path_in_file(path: &str) -> Value {
    let mut obj = json_of(&sample());
    obj["project"]["media"][0]["path"] = json!(path);
    obj
}

#[test]
fn an_old_project_with_verbatim_media_paths_opens_with_plain_paths() {
    let back = decoded(&media_path_in_file("//?/C:/sq-w47-light/pl-4k-hevc.mp4")).unwrap();
    assert_eq!(back.media[0].path, "C:/sq-w47-light/pl-4k-hevc.mp4");
    let back = decoded(&media_path_in_file("\\\\?\\C:\\sq-w47-light\\pl-4k-hevc.mp4")).unwrap();
    assert_eq!(back.media[0].path, "C:/sq-w47-light/pl-4k-hevc.mp4");
}

#[test]
fn share_paths_open_as_plain_share_paths_and_posix_paths_stay() {
    let back = decoded(&media_path_in_file("//?/UNC/server/share/clips/a.mp4")).unwrap();
    assert_eq!(back.media[0].path, "//server/share/clips/a.mp4");
    let back = decoded(&media_path_in_file("\\\\server\\share\\a.mp4")).unwrap();
    assert_eq!(back.media[0].path, "//server/share/a.mp4");
    assert_eq!(decoded(&media_path_in_file("/Users/p/we\\ird.mov")).unwrap().media[0].path, "/Users/p/we\\ird.mov");
}

#[test]
fn a_verbatim_path_in_memory_is_written_plain() {
    let mut p = sample();
    p.media[0].path = "//?/C:/Media/a.mp4".to_string();
    assert_eq!(json_of(&p)["project"]["media"][0]["path"], json!("C:/Media/a.mp4"));
}

#[test]
fn a_project_saved_on_windows_round_trips_between_systems_unchanged() {
    let mut p = sample();
    p.media[0].path = "C:/Media/clip one.mp4".to_string();
    let first = ProjectFile::without_fixups().encode(&p).unwrap();
    let back = ProjectFile::without_fixups().decode(&first, None).unwrap();
    assert_eq!(back.media[0].path, "C:/Media/clip one.mp4");
    assert_eq!(ProjectFile::without_fixups().encode(&back).unwrap(), first);
}
