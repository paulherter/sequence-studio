//! Tests of the timeline host: hooks become queues; the panel draws through the headless App.

use super::*;
use sq_app_shell::{AppDeps, Headless};
use sq_core_time::{Id, SequentialIds};
use sq_editor_session::SessionDeps;
use sq_runtime::{Clock as _, FakeClock};
use std::sync::Arc;

fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests"));
    deps.ids = Box::new(ids);
    EditorSession::new(project, deps)
}

#[test]
fn editor_requests_and_commands_are_queued_for_the_root() {
    let mut host = TimelinePanelHost::new(DrawTheme::default());
    let tl = host.inner();
    assert_eq!(tl.host.request(&TimelineEditorRequest::Marker(Id::from_u128(5))), None);
    tl.host.run(EditorCommand::ShuttleStop);
    assert_eq!(
        host.take_events(),
        vec![
            TimelineHostEvent::Open(TimelineEditorRequest::Marker(Id::from_u128(5))),
            TimelineHostEvent::Command(EditorCommand::ShuttleStop),
        ]
    );
    assert!(host.take_events().is_empty());
}

#[test]
fn status_lines_reach_the_app_status_bar() {
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 800, 600);
    h.with(|a| {
        a.add_host(Box::new(TimelinePanelHost::new(DrawTheme::default())));
    });
    let (_, list) = h.turn();
    assert!(list.is_some(), "the timeline draws");
    assert!(h.with(|a| a.status_text().is_empty()).unwrap_or(false));
}

#[test]
fn the_duration_request_goes_to_the_prompt_and_other_editors_are_queued() {
    let mut host = TimelinePanelHost::new(DrawTheme::default());
    let tl = host.inner();
    assert!(tl.host.prompt.is_some(), "prompts are answered by dialogs");
    let open = tl.host.open.as_mut().expect("open hook");
    assert!(!open(&TimelineEditorRequest::EditTransitionDuration(Id::from_u128(3))));
    assert!(host.take_events().is_empty());
    let mut s = session();
    // Requests the editor dialogs answer are not queued any more.
    assert!(host.editor_dialog(&mut s, &TimelineEditorRequest::SequenceVolume).is_some());
    assert!(host.editor_dialog(&mut s, &TimelineEditorRequest::NewColorMatte).is_some());
    // A request no dialog answers still goes to the root queue.
    let tl = host.inner();
    let open = tl.host.open.as_mut().expect("open hook");
    assert!(open(&TimelineEditorRequest::GraphicLayers(Id::from_u128(4))));
    assert_eq!(
        host.take_events(),
        vec![TimelineHostEvent::Open(TimelineEditorRequest::GraphicLayers(Id::from_u128(4)))]
    );
}

#[test]
fn a_prompt_becomes_a_dialog_for_the_root() {
    let mut host = TimelinePanelHost::new(DrawTheme::default());
    let tl = host.inner();
    tl.host.ask(sq_draw_timeline::host::TimelinePrompt::new("Rename Track", "V1"), "", Box::new(|_| {}));
    assert_eq!(host.take_dialogs().len(), 1);
    assert!(host.take_dialogs().is_empty());
}

#[test]
fn the_duck_curve_reads_the_live_ducking_the_root_sets() {
    use sq_core_audio::live_ducking::LiveDucking;
    let mut host = TimelinePanelHost::new(DrawTheme::default());
    let read = |h: &mut TimelinePanelHost| (h.inner().panel.duck_curve.as_ref().expect("source").ducking)();
    assert_eq!(read(&mut host), None);
    let setting = LiveDucking::new(12.0, sq_core_time::Time::new(1, 2));
    host.set_live_ducking(Some(setting.clone()));
    assert_eq!(read(&mut host), Some(setting));
    host.set_live_ducking(None);
    assert_eq!(read(&mut host), None);
}

/// Real-window bug: after an animated zoom the screen stayed on a mid-animation frame until the next input.
#[test]
fn a_zoom_animation_keeps_frames_coming_until_it_lands_without_input() {
    let clock = FakeClock::new();
    let h = Headless::new(session(), AppDeps::headless(Arc::new(clock.clone())), 800, 600);
    let read = clock.clone();
    h.with(|a| {
        let mut host = TimelinePanelHost::new(DrawTheme::default());
        host.inner().panel.clock = Box::new(move || read.now().as_secs_f64());
        a.add_host(Box::new(host));
        a.session_mut().mark_in();
        a.session_mut().seek(sq_core_time::Time::new(10, 1));
        a.session_mut().mark_out();
    });
    h.turn();
    h.turn();
    assert_eq!(h.with(|a| a.needs_redraw()), Some(false), "idle before the zoom");
    h.input(&sq_draw::InputEvent::KeyDown {
        key: sq_draw::InputKey::Character('\\'),
        modifiers: sq_draw::InputModifiers::NONE,
    });
    let mut frames = 0;
    while h.with(|a| a.needs_redraw()) == Some(true) && frames < 100 {
        clock.advance(std::time::Duration::from_millis(16));
        assert!(h.turn().1.is_some(), "a frame is drawn for every wake, with no input");
        frames += 1;
    }
    assert!(frames > 3 && frames < 100, "the glide ran and then ended: {frames}");
    assert_eq!(h.with(|a| a.needs_redraw()), Some(false), "settled: the loop sleeps again");
}

#[test]
fn the_duck_curve_gets_the_dialogue_pauses_from_the_timeline_waveforms() {
    use sq_core_model::{Clip, TrackKind};
    use sq_core_time::{Time, TimeRange};
    use sq_media::waveform_data::WaveformData;
    // 20 s of 10 ms buckets at level 0.5, silent from 5 s for 3 s (the playback provider's own fixture).
    let mut l0 = Vec::new();
    for i in 0..2000 {
        l0.extend(if (500..800).contains(&i) { [0.0, 0.0] } else { [-0.5, 0.5] });
    }
    let data = Arc::new(WaveformData {
        sample_rate: 1000,
        channel_count: 1,
        total_frames: 20_000,
        base_bucket_size: 10,
        levels: vec![l0],
    });
    let media = Id::from_u128(1);
    let mut host = TimelinePanelHost::new(DrawTheme::default());
    host.attach_waveforms(Rc::new(move |id| (id == media).then(|| Arc::clone(&data))));
    let provider = host.inner().panel.duck_curve.as_ref().and_then(|c| c.silences.clone()).expect("provider");
    let len = TimeRange::new(Time::ZERO, Time::new(20, 1));
    let clip = Clip::new(Id::from_u128(50), "d", media, TrackKind::Audio, len, Time::ZERO);
    let mut found = None;
    for _ in 0..200 {
        found = provider.silences(&clip, 0.0);
        if found.is_some() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert_eq!(found, Some(vec![TimeRange::new(Time::new(5, 1), Time::new(3, 1))]));
    let other = Clip::new(Id::from_u128(51), "x", Id::from_u128(2), TrackKind::Audio, len, Time::ZERO);
    assert_eq!(provider.silences(&other, 0.0), None, "no waveform for that media");
}
