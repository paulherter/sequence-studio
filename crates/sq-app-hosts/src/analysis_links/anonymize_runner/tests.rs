//! Anonymize through the shell's analysis services: the search and the run on workers over a fake detector and tracker, the
//! sheet's answer, the one undo step, a cancel. The real models run on `SQ_REAL_PERSON_CLIP` (skips without it).

use super::*;
use crate::analysis_links::analysis_services::{AnalysisServices, tests::session_of};
use crate::analysis_links::anonymizer::tests::Fake;
use sq_core_masks::anonymize::AnonymizeCover;
use sq_core_masks::anonymize::MagicSelectionAnonymizeExt;
use sq_core_masks::masks::ClipMasksExt;
use sq_core_model::{AnonymizeTarget, ClipEffect};
use sq_draw_shell::ShellServices;
use std::time::{Duration, Instant};

fn services_with(make: MakeSources) -> (AnalysisServices, Arc<FrameMatteStore>) {
    let store = Arc::new(FrameMatteStore::new(None));
    let runner = AnonymizeRunner::new(Arc::clone(&store), make);
    (AnalysisServices::new(Box::new(crate::PortableAnalysisBackend)).with_anonymize(runner), store)
}

fn fake_sources(gone_after: Option<f64>) -> MakeSources {
    Box::new(move |_| Ok(Arc::new(Fake { gone_after }) as Arc<dyn AnonymizeSources>))
}

/// Pumps until `want` returns something from the events, within 30 s.
fn wait_for<T>(
    services: &mut AnalysisServices,
    session: &mut EditorSession,
    mut want: impl FnMut(&AnonymizeEvent) -> Option<T>,
) -> (T, Vec<AnonymizeEvent>) {
    let end = Instant::now() + Duration::from_secs(900);
    let mut all = Vec::new();
    loop {
        assert!(Instant::now() < end, "the worker did not answer: {all:?}");
        services.pump(session);
        for e in services.take_anonymize_events() {
            all.push(e);
        }
        if let Some(v) = all.iter().find_map(&mut want) {
            return (v, all);
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn clip_of(s: &EditorSession, id: Id) -> sq_core_model::Clip {
    s.active_timeline().and_then(|t| t.tracks.iter().find_map(|tr| tr.clip(id))).cloned().expect("clip")
}

#[test]
fn the_flow_finds_two_people_asks_follows_and_writes_one_undo_step() {
    let (mut s, id) = session_of("/nonexistent/m.mov");
    let (mut services, store) = services_with(fake_sources(None));
    assert!(services.run_anonymize(&mut s));
    assert!(services.anonymize_running());
    let (people, _) = wait_for(&mut services, &mut s, |e| match e {
        AnonymizeEvent::Ask { people, .. } => Some(people.clone()),
        _ => None,
    });
    assert_eq!(people.len(), 2, "two people on the clip");
    let before = clip_of(&s, id);
    assert!(before.masks().is_empty());
    services.anonymize_answer(
        &mut s,
        Some(AnonymizeChoice::new(AnonymizeTarget::Person, AnonymizeCover::Blur, vec![0, 1])),
    );
    let (_, events) = wait_for(&mut services, &mut s, |e| match e {
        AnonymizeEvent::Flash(m) if m.starts_with("Anonymize applied") => Some(()),
        AnonymizeEvent::Checks(_) => Some(()),
        _ => None,
    });
    assert!(
        events.iter().any(|e| matches!(e, AnonymizeEvent::Job(Some(l)) if l.contains("following 2 people"))),
        "{events:?}"
    );
    let clip = clip_of(&s, id);
    assert_eq!(clip.masks().len(), 2, "one Magic mask per person");
    assert!(clip.effects.iter().any(|e| e.kind == ClipEffect::GAUSSIAN_BLUR_KIND), "the blur cover is on the clip");
    for m in clip.masks() {
        let sel = m.magic.clone().expect("magic");
        assert!(!store.times(&sel.matte_key(clip.media)).is_empty(), "the matte is under the mask's own key");
    }
    assert!(!services.anonymize_running());
    assert!(s.undo(), "one undo step");
    assert!(clip_of(&s, id).masks().is_empty());
    assert!(!clip_of(&s, id).effects.iter().any(|e| e.kind == ClipEffect::GAUSSIAN_BLUR_KIND));
}

#[test]
fn running_it_again_while_it_works_cancels_and_changes_nothing() {
    let (mut s, id) = session_of("/nonexistent/m.mov");
    let (mut services, _) = services_with(fake_sources(None));
    assert!(services.run_anonymize(&mut s));
    assert!(services.run_anonymize(&mut s), "the second run cancels the first");
    let (_, _) = wait_for(&mut services, &mut s, |e| {
        matches!(e, AnonymizeEvent::Flash(m) if m == "Anonymize canceled.").then_some(())
    });
    assert!(clip_of(&s, id).masks().is_empty());
    assert!(!services.anonymize_running());
}

#[test]
fn a_declined_sheet_writes_nothing() {
    let (mut s, id) = session_of("/nonexistent/m.mov");
    let (mut services, _) = services_with(fake_sources(None));
    services.run_anonymize(&mut s);
    wait_for(&mut services, &mut s, |e| matches!(e, AnonymizeEvent::Ask { .. }).then_some(()));
    services.anonymize_answer(&mut s, None);
    assert!(!services.anonymize_running());
    assert!(clip_of(&s, id).masks().is_empty());
}

#[test]
fn without_a_runner_the_command_is_not_offered() {
    let (mut s, _) = session_of("/nonexistent/m.mov");
    let mut services = AnalysisServices::new(Box::new(crate::PortableAnalysisBackend));
    assert!(!services.run_anonymize(&mut s));
}

/// The real models over a real clip with a person (`SQ_REAL_PERSON_CLIP`; `SQ_PERSON_MODELS`, the EdgeTAM folder and ONNX
/// Runtime on PATH): the search finds someone and a Face run writes masks and a cover.
#[test]
fn a_real_clip_with_a_person_is_anonymized_through_the_real_models() {
    let Ok(path) = std::env::var("SQ_REAL_PERSON_CLIP") else {
        sq_os::errln!("skipped: SQ_REAL_PERSON_CLIP is not set");
        return;
    };
    let support = std::env::temp_dir().join("sq-anonymize-real-support");
    let (mut s, id) = session_of(&path);
    let (mut services, _) = services_with(system_sources(support));
    assert!(services.run_anonymize(&mut s));
    let (people, events) = wait_for(&mut services, &mut s, |e| match e {
        AnonymizeEvent::Ask { people, .. } => Some(people.len()),
        AnonymizeEvent::Info(..) | AnonymizeEvent::Warn(..) => Some(0),
        _ => None,
    });
    sq_os::errln!("real search: {people} people, {events:?}");
    assert!(people >= 1, "{events:?}");
    services
        .anonymize_answer(&mut s, Some(AnonymizeChoice::new(AnonymizeTarget::Face, AnonymizeCover::Mosaic, vec![0])));
    let (_, events) = wait_for(&mut services, &mut s, |e| match e {
        AnonymizeEvent::Flash(m) if m.starts_with("Anonymize") => Some(()),
        AnonymizeEvent::Checks(_) => Some(()),
        _ => None,
    });
    sq_os::errln!("real run: {events:?}");
    let clip = clip_of(&s, id);
    assert_eq!(clip.masks().len(), 1, "{events:?}");
    assert!(clip.effects.iter().any(|e| e.kind == ClipEffect::MOSAIC_KIND), "{events:?}");
    assert!(s.undo());
}
