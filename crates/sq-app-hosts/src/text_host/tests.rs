//! Tests of the Text host: the panel draws, a press in the tab bar switches tabs, and a press outside is not taken.

use super::*;
use crate::test_rig::Rig;
use sq_core_time::SequentialIds;
use sq_editor_session::SessionDeps;
use sq_inspector_ui::text::panel_draw::Tab;

fn rig() -> Rig {
    let mut ids = SequentialIds::default();
    let project = sq_editor_session::EditorSession::make_untitled(&mut ids);
    Rig::new(sq_editor_session::EditorSession::new(
        project,
        SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-text-tests")),
    ))
}

fn frame() -> CGRect {
    CGRect { x: 40.0, y: 20.0, width: 320.0, height: 480.0 }
}

#[test]
fn the_panel_draws_in_its_frame_and_starts_on_the_list_tab() {
    let mut host = TextHost::new();
    let mut rig = rig();
    host.layout(frame(), &mut rig.cx());
    let mut c = Canvas::with_size(400.0, 520.0, None, 1.0);
    host.draw(&mut c, &DrawTheme::default(), &mut rig.cx());
    assert_eq!(host.panel().tab(), Tab::Captions);
}

#[test]
fn a_press_in_the_tab_bar_switches_the_tab() {
    let mut host = TextHost::new();
    let mut rig = rig();
    host.layout(frame(), &mut rig.cx());
    let target = *host.panel().tabs().last().expect("tabs");
    let f = host.panel().frame(target);
    let (x, y) = ((frame().x + f.mid_x()) as f32, (frame().y + f.mid_y()) as f32);
    assert!(host.handle(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::default() }, &mut rig.cx()));
    assert!(host.handle(&InputEvent::MouseUp { x, y }, &mut rig.cx()));
    assert_eq!(host.panel().tab(), target);
}

#[test]
fn a_press_outside_the_frame_is_not_taken() {
    let mut host = TextHost::new();
    let mut rig = rig();
    host.layout(frame(), &mut rig.cx());
    assert!(
        !host.handle(&InputEvent::MouseDown { x: 5.0, y: 5.0, modifiers: InputModifiers::default() }, &mut rig.cx())
    );
}

#[test]
fn a_swatch_request_opens_the_picker_and_a_press_outside_closes_it() {
    let mut host = TextHost::new();
    let mut rig = rig();
    host.layout(frame(), &mut rig.cx());
    host.set_window(CGRect { x: 0.0, y: 0.0, width: 800.0, height: 600.0 });
    let red = EffectColor { red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0 };
    host.picks.borrow_mut().push((red, CGRect { x: 10.0, y: 100.0, width: 20.0, height: 12.0 }));
    host.flush(&mut rig.cx());
    assert!(host.has_popover());
    let outside = InputEvent::MouseDown { x: 790.0, y: 590.0, modifiers: InputModifiers::default() };
    assert!(!host.handle_popover(&outside, &mut rig.cx()), "a press elsewhere closes it and goes on to the panel");
    assert!(!host.has_popover());
}

use sq_translate::{Progress, TranslateError};
use std::time::{Duration, Instant};

fn session_with_captions(rig: &mut Rig, lines: &[&str]) {
    use sq_core_model::CaptionItem;
    use sq_core_time::{IdSource, Time, TimeRange};
    let mut ids = SequentialIds::default();
    let items: Vec<CaptionItem> = lines
        .iter()
        .enumerate()
        .map(|(i, l)| CaptionItem {
            id: ids.next_id(),
            lines: vec![(*l).to_string()],
            range: TimeRange::new(Time::seconds(i as i64), Time::seconds(1)),
            style_ref: String::new(),
            animation_ref: String::new(),
            style_overridden: false,
            words: Vec::new(),
            position: None,
        })
        .collect();
    assert!(rig.session.add_caption_track().is_some());
    assert!(rig.session.add_captions(items));
}

fn caption_tracks(rig: &Rig) -> &[sq_core_model::CaptionTrack] {
    &rig.session.active_timeline().expect("timeline").caption_tracks
}

fn wait_for_translation(host: &mut TextHost, rig: &mut Rig) {
    let end = Instant::now() + Duration::from_secs(5);
    while host.is_translating() && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(10));
        host.layout(frame(), &mut rig.cx());
    }
}

#[test]
fn a_translation_job_reports_progress_and_adds_one_caption_track_as_one_undo_step() {
    let mut host = TextHost::new();
    let mut rig = rig();
    session_with_captions(&mut rig, &["This is the first line of the day.", "And we are happy with the second."]);
    let before = caption_tracks(&rig).len();
    host.layout(frame(), &mut rig.cx());
    host.start_translation(&mut rig.cx(), "de", |texts, from| {
        assert_eq!(from, "en");
        Box::new(move |progress, _cancel| {
            progress(Progress::Translating(1, texts.len()));
            Ok(texts.iter().map(|t| format!("DE {t}")).collect())
        })
    });
    assert!(host.is_translating());
    wait_for_translation(&mut host, &mut rig);
    assert!(!host.is_translating());
    let tracks = caption_tracks(&rig);
    assert_eq!(tracks.len(), before + 1);
    let made = tracks.last().unwrap();
    assert!(made.name.ends_with("(de)"), "{}", made.name);
    assert_eq!(made.items()[0].lines.join(" "), "DE This is the first line of the day.");
    assert!(rig.events.iter().any(|e| matches!(e, AppEvent::Status(s) if s.contains("Translating captions: 1 of 2"))));
}

#[test]
fn a_canceled_translation_adds_nothing_and_says_so() {
    let mut host = TextHost::new();
    let mut rig = rig();
    session_with_captions(&mut rig, &["This is the first line of the day."]);
    let before = caption_tracks(&rig).len();
    host.layout(frame(), &mut rig.cx());
    host.start_translation(&mut rig.cx(), "fr", |_t, _f| {
        Box::new(|_p, cancel| {
            while !cancel.is_canceled() {
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(TranslateError::Canceled)
        })
    });
    host.cancel_translation();
    wait_for_translation(&mut host, &mut rig);
    assert_eq!(caption_tracks(&rig).len(), before);
    assert_eq!(rig.session.last_error(), Some("Translation canceled."));
}

#[test]
fn a_caption_track_in_the_target_language_is_refused() {
    let mut host = TextHost::new();
    let mut rig = rig();
    session_with_captions(&mut rig, &["This is the first line of the day."]);
    host.start_translation(&mut rig.cx(), "en", |_t, _f| Box::new(|_p, _c| Ok(Vec::new())));
    assert!(!host.is_translating());
    assert_eq!(rig.session.last_error(), Some("The captions are already in that language."));
}

#[test]
fn editing_a_caption_opens_typing_on_its_row_in_the_captions_tab() {
    let mut host = TextHost::new();
    let mut rig = rig();
    host.layout(frame(), &mut rig.cx());
    assert!(!host.edit_caption(&mut rig.session, sq_core_time::Id::from_u128(5)), "no such caption");
    let id = rig.session.add_caption_at_playhead().expect("a caption");
    host.panel().select(&rig.session, Tab::Style);
    assert!(host.edit_caption(&mut rig.session, id));
    assert_eq!(host.panel().tab(), Tab::Captions);
    assert!(host.panel().captions.is_editing_caption());
}

/// Answers the subtitle choosers with fixed paths.
struct SubtitleFiles {
    open: Option<std::path::PathBuf>,
    save: Option<std::path::PathBuf>,
}

impl sq_app_shell::PanelFileChooser for SubtitleFiles {
    fn choose_subtitles(&mut self) -> Option<std::path::PathBuf> {
        self.open.clone()
    }
    fn choose_srt_location(&mut self, _suggested_name: &str) -> Option<std::path::PathBuf> {
        self.save.clone()
    }
    fn choose_frame_location(&mut self, _n: &str, _f: &[(&str, &str)]) -> Option<std::path::PathBuf> {
        None
    }
    fn choose_csv_location(&mut self, _n: &str) -> Option<std::path::PathBuf> {
        None
    }
    fn choose_luts(&mut self, _multiple: bool) -> Vec<std::path::PathBuf> {
        Vec::new()
    }
}

#[test]
fn the_captions_menu_imports_and_exports_a_subtitle_file() {
    let mut host = TextHost::new();
    let mut rig = rig();
    let dir = crate::test_rig::unique_dir("sq-app-hosts-srt");
    std::fs::create_dir_all(&dir).expect("dir");
    let (input, output) = (dir.join("in.srt"), dir.join("out.srt"));
    std::fs::write(
        &input,
        "1\n00:00:01,000 --> 00:00:02,000\nHello there\n\n2\n00:00:03,000 --> 00:00:04,000\nSecond\n",
    )
    .expect("write");
    rig.services.panel_files = Box::new(SubtitleFiles { open: Some(input), save: Some(output.clone()) });
    host.layout(frame(), &mut rig.cx());
    // The menu rows are enabled only while the host listens for them.
    assert!(host.panel().captions.on_import_srt.is_some() && host.panel().captions.on_export_srt.is_some());
    host.srt_asked.borrow_mut().push(SrtAsk::Import);
    host.flush(&mut rig.cx());
    let items: usize = caption_tracks(&rig).iter().map(|t| t.items().len()).sum();
    assert_eq!(items, 2, "the file's two cues became captions");
    host.srt_asked.borrow_mut().push(SrtAsk::Export);
    host.flush(&mut rig.cx());
    let written = std::fs::read_to_string(&output).expect("exported");
    assert!(written.contains("Hello there") && written.contains("00:00:03,000 --> 00:00:04,000"), "{written}");
    std::fs::remove_dir_all(&dir).ok();
}
