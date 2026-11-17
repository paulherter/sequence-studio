//! Dead-command audit: every menu, key and catalog command goes through the real root's shell with a sensible
//! precondition (sequence open, two clips selected, media present). A command the shell reports as not run is either
//! disabled for a documented reason (`UNAVAILABLE`) or dead, and a dead one fails this test (docs/rust/DEAD-COMMANDS.md).

use super::*;
use sq_core_model::{MediaFingerprint, MediaRef, Project};
use sq_core_time::{Id, SequentialIds, Time};
use sq_editor_session::{PlaceOptions, SessionDeps};
use sq_runtime::FakeClock;
use sq_uikit::command_catalog::CommandCatalog;
use sq_uikit::command_map::CommandMap;
use sq_uikit::panel_id::PanelID;
use std::collections::BTreeSet;
use std::sync::Arc;

/// Case names the shell may report as not run with the demo project, with the reason.
const UNAVAILABLE: [(&str, &str); 2] = [
    ("export", "needs the app's export queue (`enable_export`, sequence-studio main.rs); the test root has none"),
    ("quickExport", "needs the app's export queue (`enable_export`, sequence-studio main.rs); the test root has none"),
];

/// Commands that are enabled but run nowhere yet: one row each in docs/rust/DEAD-COMMANDS.md. Wire one, delete it here.
const KNOWN_DEAD: [&str; 0] = [];

/// Commands the three demo scenarios never enable. Each has its state in `disabled_commands_tests.rs` (the Swift enabling
/// rule, enabled and run). A different count means a command was newly disabled everywhere (a lost fact) or the demo grew:
/// update the number together with the state tests.
const DISABLED_IN_DEMO: usize = 81;

/// What the demo project looks like: a plain sequence, one with In and Out set, or a Fast Cut (magnetic) one.
#[derive(Clone, Copy, PartialEq, Debug)]
pub(super) enum Scenario {
    Plain,
    InOut,
    FastCut,
}

pub(super) fn demo_session(scenario: Scenario) -> EditorSession {
    let media: Vec<MediaRef> = (1..=2u128)
        .map(|n| {
            let mut m = MediaRef::new(
                Id::from_u128(900 + n),
                &format!("clip{n}"),
                &format!("/tmp/sq-demo-{n}.mp4"),
                MediaFingerprint::new(n as i64),
            );
            m.duration = Some(Time::seconds(10));
            m.info = serde_json::from_value(serde_json::json!({
                "duration": {"value": 10, "timescale": 1},
                "video": {"width": 1920, "height": 1080, "codec": "avc1", "bitDepth": 8, "chroma": "4:2:0",
                          "nominalFrameDuration": {"value": 1001, "timescale": 30000}, "isVariableFrameRate": false, "rotation": 0},
                "audio": {"sampleRate": 48000, "channels": 2, "codec": "lpcm"}
            }))
            .ok();
            m
        })
        .collect();
    let project = Project::new(Id::from_u128(2), "demo", media, Vec::new());
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-dead-commands"));
    deps.ids = Box::new(SequentialIds::default());
    let mut s = EditorSession::new(project, deps);
    assert!(s.place_media(&[Id::from_u128(901), Id::from_u128(902)], &PlaceOptions::default()), "demo clips placed");
    if scenario == Scenario::FastCut {
        assert!(s.set_timeline_edit_mode(sq_core_model::TimelineEditMode::Magnetic), "fast cut");
    }
    let clips: BTreeSet<Id> =
        s.active_timeline().expect("sequence").tracks.iter().flat_map(|t| t.clips()).map(|c| c.id).collect();
    assert!(!clips.is_empty());
    s.select(clips, BTreeSet::new());
    s.seek(Time::seconds(3));
    if scenario == Scenario::InOut {
        s.mark_in();
        s.seek(Time::seconds(6));
        s.mark_out();
    }
    s
}

#[test]
fn no_audited_command_is_dead_with_the_demo_project() {
    let map = CommandMap::premiere_default();
    let commands = CommandCatalog::audited(&map);
    let mut dead: Vec<String> = Vec::new();
    let mut disabled_everywhere: Vec<String> = Vec::new();
    let mut not_available: Vec<String> = Vec::new();
    let mut unwired = 0;
    for c in &commands {
        if !sq_editor_session::CommandRouting::is_supported(c) {
            unwired += 1;
            continue;
        }
        let name = sq_draw_shell::SharedCommandCoverage::name(c);
        let mut ran_somewhere = false;
        let mut enabled_somewhere = false;
        for scenario in [Scenario::Plain, Scenario::InOut, Scenario::FastCut] {
            let dir = crate::test_rig::unique_dir("sq-dead-root");
            std::fs::create_dir_all(&dir).expect("dir");
            let mut root = crate::standard_root_with_source(
                &dir,
                Arc::new(FakeClock::new()),
                DrawTheme::default(),
                crate::MonitorPicture::default(),
                Box::new(sq_editor_session::StubProgramEngine::new()),
                crate::MonitorPicture::default(),
            )
            .expect("root");
            let mut rig = crate::test_rig::Rig::new(demo_session(scenario));
            root.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &mut rig.cx());
            root.shell.shell().focus = Some(PanelID::Timeline);
            let enabled = root.shell.command_enabled(&rig.session, *c);
            let ran = enabled && root.shell.run_command(&mut rig.cx(), *c);
            let _ = std::fs::remove_dir_all(&dir);
            if ran && super::not_available_tests::said_not_available(&rig) {
                not_available.push(format!("{c:?} ({scenario:?})"));
            }
            enabled_somewhere |= enabled;
            ran_somewhere |= ran;
            if ran {
                break;
            }
        }
        if !enabled_somewhere {
            disabled_everywhere.push(format!("{c:?}"));
        } else if !ran_somewhere && !UNAVAILABLE.iter().any(|(n, _)| *n == name) {
            dead.push(format!("{c:?}"));
        }
    }
    eprintln!(
        "commands: {}, unwired: {unwired}, disabled in every scenario: {}, dead: {}\ndisabled: {disabled_everywhere:?}",
        commands.len(),
        disabled_everywhere.len(),
        dead.len()
    );
    assert_eq!(
        disabled_everywhere.len(),
        DISABLED_IN_DEMO,
        "commands disabled in every demo scenario changed: {disabled_everywhere:?} (give each a state in disabled_commands_tests.rs)"
    );
    assert!(
        not_available.is_empty(),
        "these commands ended in the platform's not-available text (wire them, or allow-list a deliberate limit with its reason in not_available_tests.rs): {not_available:?}"
    );
    dead.sort();
    let mut known: Vec<String> = KNOWN_DEAD.iter().map(|s| s.to_string()).collect();
    known.sort();
    assert_eq!(
        dead, known,
        "enabled but not run: wire the new ones, or add a row to docs/rust/DEAD-COMMANDS.md and KNOWN_DEAD"
    );
}

#[test]
fn the_view_menu_switches_toggle_the_program_monitor() {
    use sq_uikit::editor_command::EditorCommand as C;
    let dir = crate::test_rig::unique_dir("sq-dead-view");
    std::fs::create_dir_all(&dir).expect("dir");
    let mut root = crate::standard_root(&dir, Arc::new(FakeClock::new()), DrawTheme::default()).expect("root");
    let mut rig = crate::test_rig::Rig::new(demo_session(Scenario::Plain));
    let (safe, hidden) = (root.monitor.panel.model.safe_margins(), root.monitor.panel.model.overlays_hidden());
    assert!(root.shell.run_command(&mut rig.cx(), C::ToggleSafeAreas));
    assert!(root.shell.run_command(&mut rig.cx(), C::ToggleOverlays));
    let mut lines = Vec::new();
    root.answer_timeline(&mut rig.cx(), &mut lines);
    assert_eq!(root.monitor.panel.model.safe_margins(), !safe);
    assert_eq!(root.monitor.panel.model.overlays_hidden(), !hidden);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A disabled command asked for by a panel (context menu row, header button) does nothing and says nothing; the old
/// "This command is not available here yet" line is gone.
#[test]
fn a_disabled_panel_command_is_silent() {
    let map = CommandMap::premiere_default();
    let dir = crate::test_rig::unique_dir("sq-dead-silent");
    std::fs::create_dir_all(&dir).expect("dir");
    let mut root = crate::standard_root(&dir, Arc::new(FakeClock::new()), DrawTheme::default()).expect("root");
    let mut rig = crate::test_rig::Rig::new(demo_session(Scenario::Plain));
    let off = CommandCatalog::audited(&map)
        .into_iter()
        .find(|c| sq_editor_session::CommandRouting::is_supported(c) && !root.shell.command_enabled(&rig.session, *c))
        .expect("a disabled command");
    assert_eq!(root.run_panel_command(&mut rig.cx(), off), PanelCommand::Disabled);
    let mut lines = Vec::new();
    root.answer_timeline(&mut rig.cx(), &mut lines);
    assert!(lines.iter().all(|l| !l.contains("not available")), "{lines:?}");
    let _ = std::fs::remove_dir_all(&dir);
}
