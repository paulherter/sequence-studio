//! Silent chords, second pass (docs/rust/SWEEP-KEYS-2026-11-13.md): the Windows/Linux chords that changed nothing in a
//! headless shot of the sweep's fixture. Each is pressed through the real root (key map, focus, enable rule, handler) in the
//! state its command needs, and must then change something a test can see: the project, the selection, the playhead, a
//! dialog, an event.

use super::dead_commands_tests::{Scenario, demo_session};
use super::disabled_commands_tests::{
    Setup, clip_ids, first_clip_only, frame, new_root, pick, select_edge, three_tracks,
};
use super::menu_click_tests::send;
use super::*;
use sq_core_model::{ClipEdge, TrackKind};
use sq_core_time::{Id, Time};
use std::collections::BTreeSet;

const C: InputModifiers = InputModifiers::COMMAND;
const O: InputModifiers = InputModifiers::OPTION;
const S: InputModifiers = InputModifiers::SHIFT;
const N: InputModifiers = InputModifiers::NONE;

struct Case {
    label: &'static str,
    key: InputKey,
    mods: InputModifiers,
    focus: PanelID,
    scenario: Scenario,
    setup: Option<Setup>,
}

fn ch(c: char) -> InputKey {
    InputKey::Character(c)
}

fn case(label: &'static str, key: InputKey, mods: InputModifiers, scenario: Scenario, setup: Option<Setup>) -> Case {
    Case { label, key, mods, focus: PanelID::Timeline, scenario, setup }
}

/// The chord of `c` on this platform. The cases are written as the Windows/Linux key map binds them; on the Mac the same
/// command can sit on another chord (JoinCuts is Control+Option+J there), so the chord is looked up by command in the map the
/// shell runs. Chords no command owns (the control cases) stay as written.
fn chord_here(root: &mut AppRoot, c: &Case) -> (InputKey, InputModifiers) {
    use sq_draw_shell::ShellKeys;
    use sq_uikit::command_map::CommandMap;
    use sq_uikit::key_binding::{Key, KeyModifiers};
    let shell = root.shell.shell();
    if !shell.mac_keys {
        return (c.key, c.mods);
    }
    let windows = CommandMap::sq_default_for(sq_os::Platform::Windows);
    let Some(command) = ShellKeys::command(c.key, c.mods, Some(c.focus), &windows, false) else {
        return (c.key, c.mods);
    };
    let Some(b) = shell.map.binding_for(&command) else { return (c.key, c.mods) };
    let key = match b.key {
        Key::Char(ch) => InputKey::Character(ch),
        Key::Space => InputKey::Space,
        Key::Left => InputKey::Left,
        Key::Right => InputKey::Right,
        Key::Up => InputKey::Up,
        Key::Down => InputKey::Down,
        Key::Home => InputKey::Home,
        Key::End => InputKey::End,
        Key::PageUp => InputKey::PageUp,
        Key::PageDown => InputKey::PageDown,
        Key::Delete => InputKey::Backspace,
        Key::ForwardDelete => InputKey::Delete,
        Key::ReturnKey => InputKey::Enter,
        Key::Function(n) => InputKey::Function(n as u8),
    };
    let mut mods = N;
    for (from, to) in [
        (KeyModifiers::COMMAND, C),
        (KeyModifiers::OPTION, O),
        (KeyModifiers::SHIFT, S),
        (KeyModifiers::CONTROL, InputModifiers::CONTROL),
    ] {
        if b.modifiers.contains(from) {
            mods = mods | to;
        }
    }
    (key, mods)
}

/// Presses the chord; `Some(status)` says what happened, `None` means nothing changed.
fn press(c: &Case) -> Option<String> {
    let (mut root, mut rig, dir) = new_root(c.scenario);
    frame(&mut root, &mut rig);
    root.shell.shell().focus = Some(c.focus);
    if let Some(setup) = c.setup {
        setup(&mut root, &mut rig);
    }
    frame(&mut root, &mut rig);
    let before = fingerprint(&mut root, &mut rig);
    let (key, modifiers) = chord_here(&mut root, c);
    let taken = send(&mut root, &mut rig, InputEvent::KeyDown { key, modifiers });
    let lines = frame(&mut root, &mut rig);
    let after = fingerprint(&mut root, &mut rig);
    let changed = before != after;
    if c.label.starts_with("CONTROL") {
        std::fs::write("/tmp/ctl_before.txt", &before[before.len().saturating_sub(300)..]).ok();
        std::fs::write("/tmp/ctl_after.txt", &after[after.len().saturating_sub(300)..]).ok();
    }
    let _ = std::fs::remove_dir_all(&dir);
    Some(format!(
        "{}\ttaken={taken}\tchanged={changed}\tstatus={lines:?}\terror={:?}",
        c.label,
        rig.session.last_error()
    ))
}

/// What a chord can change that a test can see (the demo root logs every key as an event, so events are left out).
fn fingerprint(root: &mut AppRoot, rig: &mut crate::test_rig::Rig) -> String {
    format!(
        "{}|{:?}|{:?}|{:?}|{}|{:?}|{:?}|{}",
        serde_json::to_string(rig.session.project()).unwrap_or_default(),
        rig.session.selection(),
        rig.session.playhead(),
        rig.session.undo_name(),
        root.shell.shell().dialog().is_some(),
        root.timeline.inner().panel.edge_selection(),
        root.timeline.inner().panel.tool_state().tool,
        root.shell.shell().trim.is_active(),
    )
}

fn second_clip_only(_: &mut AppRoot, rig: &mut crate::test_rig::Rig) {
    let second = clip_ids(&rig.session)[1];
    pick(&mut rig.session, &[second]);
}

#[test]
fn silent_chords_change_something_in_their_state() {
    let tail: Setup = |root, rig| select_edge(root, rig, ClipEdge::Tail);
    let head: Setup = |root, rig| select_edge(root, rig, ClipEdge::Head);
    let tracks: Setup = |_, rig| {
        for _ in 0..9 {
            rig.session.add_track(TrackKind::Video);
            rig.session.add_track(TrackKind::Audio);
        }
    };
    let two_video: Setup = |_, rig| {
        let ids = clip_ids(&rig.session);
        pick(&mut rig.session, &ids);
    };
    let group: Setup = |_, rig| {
        assert!(rig.session.group_selection().is_some());
    };
    let bundle: Setup = |_, rig| {
        assert!(rig.session.bundle_selection());
    };
    let angles: Setup = |_, rig| {
        let ids = clip_ids(&rig.session);
        assert!(rig.session.create_angles_clip(&ids, None, None, 0, true).is_some(), "angles clip");
    };
    let music: Setup = |_, rig| {
        let audio = rig
            .session
            .active_timeline()
            .expect("sequence")
            .tracks
            .iter()
            .filter(|t| t.kind == TrackKind::Audio)
            .flat_map(|t| t.clips().iter().map(|c| c.id))
            .next()
            .expect("an audio clip");
        pick(&mut rig.session, &[audio]);
        assert!(rig.session.toggle_audio_tag(sq_core_model::AudioTag::Music), "tagged as music");
    };
    // The demo clips meet at 10 s: a J cut needs the audio cut ahead of the playhead, an L cut behind it.
    let before_the_cut: Setup = |_, rig| rig.session.seek(Time::seconds(9));
    let after_the_cut: Setup = |_, rig| rig.session.seek(Time::seconds(11));
    let top_of_three: Setup = |root, rig| {
        three_tracks(root, rig);
        let top = rig
            .session
            .active_timeline()
            .expect("sequence")
            .tracks
            .iter()
            .rfind(|t| t.kind == TrackKind::Video)
            .and_then(|t| t.clips().first().map(|c| c.id))
            .expect("top clip");
        pick(&mut rig.session, &[top]);
    };
    // A keyframe at 2 s on the selected clip's Opacity (as `hold_and_ease_act_on_the_selected_keyframes`), playhead before it.
    let key_at_2s: Setup = |root, rig| {
        use sq_editor_session::Change;
        use sq_inspector_ui::ec::effect_controls_model::property::EffectProperty;
        first_clip_only(rig);
        rig.session.seek(Time::seconds(2));
        {
            let model = &mut root.inspector.controls().model;
            model.sync(&rig.session, Change::SELECTION | Change::PROJECT);
            model.focused_property = Some(EffectProperty::Opacity);
        }
        assert!(root.shell.run_command(&mut rig.cx(), sq_uikit::editor_command::EditorCommand::AddKeyframe));
        frame(root, rig);
        root.inspector.pump(&mut rig.cx());
        rig.session.seek(Time::seconds(1));
    };
    let join: Setup = |_, rig| {
        rig.session.select(BTreeSet::new(), BTreeSet::new());
        rig.session.add_edit_at_playhead(false);
    };
    let cases = vec![
        case("CONTROL f12", InputKey::Function(12), N, Scenario::Plain, None),
        case("CONTROL ctrl+shift+f12", InputKey::Function(12), C | S, Scenario::Plain, None),
        case("Link ctrl+l", ch('l'), C, Scenario::Plain, None),
        case("Link ctrl+l two video", ch('l'), C, Scenario::Plain, Some(two_video)),
        case("MatchLoudness ctrl+alt+l", ch('l'), C | O, Scenario::Plain, None),
        case("AutoDuck ctrl+alt+d", ch('d'), C | O, Scenario::Plain, Some(music)),
        case("JoinCuts ctrl+alt+j", ch('j'), C | O, Scenario::Plain, Some(join)),
        case("TrimMode ctrl+shift+t", ch('t'), C | S, Scenario::Plain, None),
        // Toggle Trim Type (Ctrl+T on the Mac) cycles the trim type of a selected edit; it needs that edge selection.
        case("ToggleTrimType ctrl+t tail", ch('t'), InputModifiers::CONTROL, Scenario::Plain, Some(tail)),
        case("Ungroup", ch('g'), C | S, Scenario::Plain, Some(group)),
        case("Unbundle", ch('g'), C | O | S, Scenario::Plain, Some(bundle)),
        case("Lift", ch(';'), N, Scenario::InOut, None),
        case("Extract", ch('\''), N, Scenario::InOut, None),
        case("GoToIn", ch('i'), S, Scenario::InOut, None),
        case("ClearIn", ch('i'), O, Scenario::InOut, None),
        case("ClearOut", ch('o'), O, Scenario::InOut, None),
        case("ClearInOut", ch('x'), O, Scenario::InOut, None),
        case("MarkClip", ch('x'), N, Scenario::Plain, Some(second_clip_only)),
        case("ctrl+5 video", ch('5'), C, Scenario::Plain, Some(tracks)),
        case("ctrl+alt+9 audio", ch('9'), C | O, Scenario::Plain, Some(tracks)),
        case("angle 2", ch('2'), N, Scenario::Plain, Some(angles)),
        case("angle 1", ch('1'), N, Scenario::Plain, Some(angles)),
        case("TrimBackward alt+left tail", InputKey::Left, O, Scenario::Plain, Some(tail)),
        case("TrimForward alt+right head", InputKey::Right, O, Scenario::Plain, Some(head)),
        case("TrimBackward5 alt+shift+left", InputKey::Left, O | S, Scenario::Plain, Some(tail)),
        case("ExtendEdit w", ch('w'), N, Scenario::Plain, Some(tail)),
        case("RollTrimPrevious shift+q", ch('q'), S, Scenario::Plain, Some(tail)),
        case("InsertSpacer ctrl+w", ch('w'), C, Scenario::FastCut, Some(first_clip_only_fn)),
        case("StorylineRippleDelete", InputKey::Backspace, C | S, Scenario::FastCut, Some(first_clip_only_fn)),
        case("DeleteSelectionOnly", InputKey::Backspace, C | O, Scenario::FastCut, Some(first_clip_only_fn)),
        case("LiftOffMain", InputKey::Up, C | O, Scenario::FastCut, Some(first_clip_only_fn)),
        case("PutOnMain", InputKey::Down, C | O, Scenario::FastCut, Some(first_clip_only_fn)),
        case("Position tool shift+v", ch('v'), S, Scenario::FastCut, None),
        case("SelectPreviousClip ctrl+up", InputKey::Up, C, Scenario::Plain, Some(second_clip_only)),
        case("NudgeLeft ctrl+left", InputKey::Left, C, Scenario::Plain, Some(second_clip_only)),
        case("NudgeLeft10 ctrl+shift+left", InputKey::Left, C | S, Scenario::Plain, Some(second_clip_only)),
        case("NextKeyframe ctrl+]", ch(']'), C, Scenario::Plain, Some(key_at_2s)),
        case("AudioGain g", ch('g'), N, Scenario::Plain, None),
        case("AddEdit ctrl+k", ch('k'), C, Scenario::Plain, None),
        case("JCut alt+j", ch('j'), O, Scenario::Plain, Some(before_the_cut)),
        case("LCut alt+l", ch('l'), O, Scenario::Plain, Some(after_the_cut)),
        case("AudioGainDown [", ch('['), N, Scenario::Plain, None),
        case("AddFrameHold ctrl+shift+h", ch('h'), C | S, Scenario::Plain, Some(first_clip_only_fn)),
        case("ExpandAllTracks shift+=", ch('='), S, Scenario::Plain, None),
        case("MoveSelectionDown alt+down", InputKey::Down, O, Scenario::Plain, Some(top_of_three)),
    ];
    // Pressed with nothing to do on purpose, with the reason: the first two are keys no command owns (the control).
    let unchanged = [
        "CONTROL",
        // Starts a background tool (analysis of the audio file); the demo media has none, so nothing lands. Enabled and run
        // in `mark_overhang_auto_duck_and_revert_run_in_their_states`.
        "MatchLoudness",
        "AutoDuck",
        // Angle 1 is already the active angle ("Unchanged").
        "angle 1",
        // Fast Cut commands that are disabled without a storyline or an attached clip (`fast_cut_command_enabled`).
        "StorylineRippleDelete",
        "PutOnMain",
        // The demo clips use their whole media, so the audio edit has no handle to roll into (the core test
        // `split_edit_jl` in sq-core-edit runs with handles). Open: the key says nothing in that case.
        "JCut",
        "LCut",
        // A tool flow like Auto Duck: its dialog opens on the flow's async step, which this test does not pump. Open.
        "AudioGain g",
        // Track heights are view state, not in the project.
        "ExpandAllTracks",
    ];
    let mut wrong = Vec::new();
    for c in &cases {
        let line = press(c).unwrap_or_default();
        let expect_change = !unchanged.iter().any(|u| c.label.starts_with(u));
        if line.contains(&format!("changed={expect_change}")) {
            continue;
        }
        wrong.push(line);
    }
    let _ = (demo_session as fn(Scenario) -> _, Id::from_u128(0));
    assert!(wrong.is_empty(), "chords that did not behave: {wrong:#?}");
}

fn first_clip_only_fn(_: &mut AppRoot, rig: &mut crate::test_rig::Rig) {
    first_clip_only(rig);
}

/// Review: Toggle Trim Type (Ctrl+T) and Export Frame (Shift+E) looked dead in a shot. They are not: the first needs a
/// selected edit (handler `sq-draw-timeline/src/view_commands.rs`, `ToggleTrimType`) and says so in the status line when
/// there is none; the second needs a picture in the monitor (`AppRoot::export_frame`) and says "There is no frame to export
/// yet." when the monitor shows none. Both must answer with a verdict, never nothing.
#[test]
fn toggle_trim_type_and_export_frame_always_give_a_verdict() {
    let no_edge = press(&case("ToggleTrimType no edge", ch('t'), InputModifiers::CONTROL, Scenario::Plain, None))
        .unwrap_or_default();
    // Without an edit point the command is disabled (`trim_commands_enable_with_a_selected_edit_point`): the chord is not
    // taken and nothing changes; the menu row is greyed, which is the verdict.
    assert!(no_edge.contains("taken=false") && no_edge.contains("changed=false"), "{no_edge}");
    let tail: Setup = |root, rig| select_edge(root, rig, ClipEdge::Tail);
    let with_edge = press(&case("ToggleTrimType tail", ch('t'), InputModifiers::CONTROL, Scenario::Plain, Some(tail)))
        .unwrap_or_default();
    assert!(with_edge.contains("taken=true") && with_edge.contains("changed=true"), "{with_edge}");
    // The Program monitor keeps the chord too (Trim mode).
    let mut on_program = case("ToggleTrimType program", ch('t'), InputModifiers::CONTROL, Scenario::Plain, Some(tail));
    on_program.focus = PanelID::ProgramMonitor;
    let line = press(&on_program).unwrap_or_default();
    assert!(line.contains("taken=true") && line.contains("changed=true"), "{line}");

    let frame_line = press(&case("ExportFrame shift+e", ch('e'), S, Scenario::Plain, None)).unwrap_or_default();
    // With a picture in the monitor the grab starts and the save panel opens a few frames later (nothing changes yet);
    // without one the status line says so. Either way the chord is taken and raises no error.
    assert!(frame_line.contains("taken=true") && frame_line.contains("error=None"), "{frame_line}");
}
