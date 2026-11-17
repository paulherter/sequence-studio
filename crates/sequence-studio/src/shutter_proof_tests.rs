//! Proof of the Shutter Angle on a text clip in the running app (the app's own headless harness: the real root, the real
//! Controls panel, real mouse and key events). Runs only with `SQ_PROOF_DIR=<dir>`; writes the two projects, the shots and a
//! text report there. Case A: a title with an In animation (Scale 400 % to 100 %). Case B: a text clip with Scale keyframed in
//! Motion (400 % to 100 % over 10 frames). `SQ_PROOF_STEPS=<steps>` (`;` separated `--step` specs) drives the field.

use crate::cli::{Mode, Pose};
use sq_core_model::anchored_animation::{AnimationAnchor, AnimationSet, AnimationTrack, KeyframeTemplate};
use sq_core_model::{AnimatedProperty, MediaFingerprint, MediaRef};
use sq_core_time::{Id, IdSource, Keyframe, KeyframeTrack, SequentialIds, Time, Vec2};
use sq_text::text_generator::TextGenerator;
use sq_text::text_style::TextStyle;
use sq_text::text_template::TextTemplate;
use std::path::{Path, PathBuf};

fn scale_keys() -> AnimatedProperty<Vec2> {
    let mut ids = SequentialIds::default();
    let from = Vec2::new(4.0, 4.0);
    let t = KeyframeTrack::with_keys(vec![
        Keyframe::new(ids.next_id(), Time::ZERO, from),
        Keyframe::new(ids.next_id(), Time::new(10, 25), Vec2::new(1.0, 1.0)),
    ]);
    AnimatedProperty { value: from, track: t }
}

fn in_animation() -> KeyframeTemplate {
    let mut ids = SequentialIds::default();
    let track = KeyframeTrack::with_keys(vec![
        Keyframe::new(ids.next_id(), Time::ZERO, 4.0_f64),
        Keyframe::new(ids.next_id(), Time::new(10, 25), 1.0_f64),
    ]);
    let mut a = KeyframeTemplate::none();
    a.tracks = vec![AnimationTrack::new("scale".into(), track)];
    a.duration = Time::new(10, 25);
    a.anchor = AnimationAnchor::Start;
    a
}

/// Saves a project with one text clip named `t` on V1 (4 s from zero) and returns its file.
fn write_project(dir: &Path, case: char) -> PathBuf {
    let (mut session, _) = crate::untitled_session(dir);
    let template = TextTemplate::new("t", "SHUTTER", TextStyle::default());
    let id =
        session.add_text_clip(&template, Some(Time::ZERO), None, Time::seconds(4), None, true).expect("the text clip");
    session.perform("Setup", None, |p| {
        // An offline media entry makes the shot wait for the monitor picture (a project with no media does not wait).
        p.media = vec![MediaRef::new(Id::from_u128(100), "m", "/nonexistent/m.mp4", MediaFingerprint::new(1))].into();
        for tl in &mut p.timelines {
            for tr in &mut tl.tracks {
                if let Some(mut c) = tr.clip(id).cloned() {
                    if case == 'A' {
                        let set = AnimationSet::single(Some(&in_animation()));
                        c.generator = Some(TextGenerator::make_ref(&template, set.as_ref()).expect("ref"));
                    } else {
                        c.animation.scale = scale_keys();
                    }
                    tr.replace(c);
                }
            }
        }
    });
    let file = dir.join(format!("{case}.sqproj"));
    session.save_as(&file).expect("save");
    file
}

fn shot(file: &Path, out: &Path, steps: &[String], playhead_ms: i64) {
    let mut pose = Pose { select: Some("t".into()), ..Pose::default() };
    pose.steps = steps.iter().map(|s| crate::cli::parse_step(s).expect("step")).collect();
    let mode = Mode::UiShot { out: out.to_path_buf(), width: 1440, height: 900, scale: 1.0, playhead_ms, pose };
    let fonts = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
    assert_eq!(crate::headless::run(&mode, Some(file), &fonts), Ok(()));
}

#[test]
fn the_shutter_proof_shots() {
    let Some(dir) = std::env::var_os("SQ_PROOF_DIR").map(PathBuf::from) else { return };
    std::fs::create_dir_all(&dir).expect("dir");
    let steps: Vec<String> = std::env::var("SQ_PROOF_STEPS")
        .map(|s| s.split(';').filter(|p| !p.is_empty()).map(String::from).collect())
        .unwrap_or_default();
    let ms: i64 = std::env::var("SQ_PROOF_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(200);
    let tag = std::env::var("SQ_PROOF_TAG").unwrap_or_else(|_| "look".into());
    for case in ['A', 'B'] {
        let work = dir.join(format!("work-{case}"));
        let file = write_project(&work, case);
        shot(&file, &dir.join(format!("{case}-{tag}.png")), &steps, ms);
    }
}
