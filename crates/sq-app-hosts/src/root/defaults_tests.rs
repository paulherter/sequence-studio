//! Edit API "Copy" and Preferences > Editing > Restore Factory (Swift `shell.copyText`, `effectDefaultsLibrary.update`):
//! the address reaches the clipboard, a changed default is stored in the library file and shown by the session, Effect
//! Controls and Preferences, and Restore Factory takes it out of all four.

use super::tests::{root, session};
use super::*;
use sq_core_effects::transition::TransitionPresetExt;
use sq_core_model::TransitionKind;
use sq_core_model::effect_defaults::{EffectDefaults, TransitionPreset};
use sq_editor_session::{EffectDefaultsEntry, SessionEvent};

fn event(r: &mut AppRoot, rig: &mut crate::test_rig::Rig, e: sq_draw_shell::ShellEvent) {
    r.shell.deferred.push(crate::ShellDeferred::Event(e));
    r.answer(&mut rig.cx());
}

#[test]
fn copy_text_reaches_the_clipboard() {
    let mut r = root();
    let mut rig = crate::test_rig::Rig::new(session());
    event(&mut r, &mut rig, sq_draw_shell::ShellEvent::CopyText("127.0.0.1:4567".to_string()));
    assert_eq!(rig.ui.clipboard.read().as_deref(), Some("127.0.0.1:4567"));
}

#[test]
fn a_changed_default_is_stored_and_restore_factory_removes_it_everywhere() {
    let dir = crate::test_rig::unique_dir("sq-app-hosts-effect-defaults");
    std::fs::create_dir_all(&dir).expect("dir");
    let mut r = root().with_prefs(&dir);
    let mut rig = crate::test_rig::Rig::new(session());
    r.answer(&mut rig.cx());
    let mut d = EffectDefaults::default();
    d.set_default_transition(TransitionPreset::new(TransitionKind::CrossDissolve, sq_core_time::Time::seconds(2)));
    // The session's own change note (a transition's "Use as Default").
    r.session_event(&SessionEvent::EffectDefaultsChange(d.clone()), &mut rig.cx());
    assert!(rig.session.effect_defaults().has_default_transition("crossDissolve"));
    assert!(
        r.shell.shell().preferences.effect_defaults.as_ref().is_some_and(|p| p.has_default_transition("crossDissolve"))
    );
    let file = sq_library::effect_defaults_file::EffectDefaultsFile::file_url_in(&dir);
    assert!(file.exists(), "the library file is written");
    // Restore Factory.
    event(
        &mut r,
        &mut rig,
        sq_draw_shell::ShellEvent::RestoreEffectDefault(EffectDefaultsEntry::Transition(TransitionKind::CrossDissolve)),
    );
    assert!(!rig.session.effect_defaults().has_default_transition("crossDissolve"), "the session forgot it");
    assert!(r.shell.shell().preferences.effect_defaults.as_ref().is_some_and(EffectDefaults::is_empty));
    let mut ids = sq_core_time::SequentialIds::default();
    let stored = sq_library::effect_defaults_file::EffectDefaultsFile::load(
        &file,
        sq_core_time::Timestamp::from_unix_seconds(1.0),
        &mut ids,
    )
    .expect("loads");
    assert!(stored.is_empty(), "the file forgot it");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn defaults_saved_earlier_reach_the_session_on_the_first_answer() {
    let dir = crate::test_rig::unique_dir("sq-app-hosts-effect-defaults-load");
    std::fs::create_dir_all(&dir).expect("dir");
    let mut d = EffectDefaults::default();
    d.set_default_transition(TransitionPreset::new(TransitionKind::CrossDissolve, sq_core_time::Time::seconds(2)));
    let file = sq_library::effect_defaults_file::EffectDefaultsFile::file_url_in(&dir);
    std::fs::create_dir_all(file.parent().expect("parent")).expect("dir");
    sq_library::effect_defaults_file::EffectDefaultsFile::save(&d, &file).expect("saved");
    let mut r = root().with_prefs(&dir);
    let mut rig = crate::test_rig::Rig::new(session());
    r.answer(&mut rig.cx());
    assert!(rig.session.effect_defaults().has_default_transition("crossDissolve"));
    let _ = std::fs::remove_dir_all(&dir);
}

struct NoSources;
impl crate::analysis_links::magic_flow::RunSources for NoSources {
    fn frames(
        &self,
        _: &std::path::Path,
        _: sq_core_time::Time,
        _: sq_core_time::Time,
    ) -> Result<Box<dyn crate::analysis_links::magic_job::TrackFrames>, String> {
        Err("no frames".to_string())
    }
    fn tracker(
        &self,
    ) -> Box<dyn FnOnce() -> Result<Box<dyn crate::analysis_links::magic_job::Tracker>, String> + Send> {
        Box::new(|| Err("no model".to_string()))
    }
}

#[test]
fn a_stabilizer_that_needs_analysis_is_requested_from_the_runner() {
    use crate::analysis_links::analysis::AnalysisLinks;
    use crate::analysis_links::magic_flow::{MagicFlow, MagicRunner};
    use crate::analysis_links::stabilization_store::StabilizationStore;
    use crate::analysis_links::stabilize_runner::{ClipStab, StabilizeRunner};
    let flow = MagicFlow::default();
    let magic = MagicRunner::new(
        std::sync::Arc::new(sq_analysis::frame_matte_store::FrameMatteStore::new(None)),
        Box::new(NoSources),
        Box::new(sq_core_time::SequentialIds::default()),
    );
    let stabilize = StabilizeRunner::new(
        StabilizationStore::default(),
        None,
        Box::new(|_| unreachable!("only the request is checked")),
        std::sync::Arc::new(|| {}),
    );
    let mut r = root().with_analysis(AnalysisLinks::new(flow, magic, stabilize));
    let mut rig = crate::test_rig::Rig::new(session());
    let clip = sq_core_time::Id::from_u128(5);
    let ask = SessionEvent::StabilizerNeedsAnalysis {
        timeline: sq_core_time::Id::from_u128(1),
        clips: std::collections::BTreeSet::from([clip]),
    };
    r.session_event(&ask, &mut rig.cx());
    let state = r.analysis.as_ref().and_then(|a| a.stabilizer_state(clip));
    assert_eq!(state, Some(ClipStab::Requested));
}
