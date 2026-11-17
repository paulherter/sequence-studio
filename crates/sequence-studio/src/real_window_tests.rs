//! Tests through the real app root (the same root `main.rs` builds) and the window's own event conversion: Stop All on a
//! running export (popover button, the "Stop the export?" question, the queue's cancel) and the Windows mouse wheel in
//! Settings.

use sq_core_model::{Project, SequenceFormat, Timeline};
use sq_core_time::{Id, Time};
use sq_draw::{InputEvent, InputModifiers};
use sq_draw_shell::ShellRoot;
use sq_export::core::error::{CancelToken, ExportError};
use sq_export::core::loudness::LoudnessReport;
use sq_export::core::queue::{ExportJob, ExportJobState, ExportQueue, ExportSources};
use sq_export::core::settings::ExportSettings;
use sq_export::core::traits::{AudioSource, ExportEncoding, ExportFrame, FrameSource};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// Holds the export (30 % done) until the token is cancelled, like a slow encode.
struct Slow;

impl ExportEncoding for Slow {
    fn export(
        &self,
        _: &mut dyn FrameSource,
        _: Option<&mut dyn AudioSource>,
        _: &ExportSettings,
        _: &Path,
        cancel: &CancelToken,
        progress: &mut dyn FnMut(f64),
    ) -> Result<Option<LoudnessReport>, ExportError> {
        progress(0.3);
        while !cancel.is_cancelled() {
            std::thread::sleep(Duration::from_millis(2));
        }
        Err(ExportError::Cancelled)
    }
}

struct OneFrame;

impl FrameSource for OneFrame {
    fn frame_count(&self) -> usize {
        1
    }
    fn frame_duration(&self) -> Time {
        Time::new(1, 30)
    }
    fn frame(&mut self, _: usize) -> Result<ExportFrame, ExportError> {
        Err(ExportError::EmptySource)
    }
}

fn click(app: &sq_app_shell::Headless, x: f64, y: f64) {
    let (x, y) = (x as f32, y as f32);
    app.input(&InputEvent::MouseMoved { x, y });
    app.input(&InputEvent::MouseDown { x, y, modifiers: InputModifiers::default() });
    app.input(&InputEvent::MouseUp { x, y });
    app.turn();
}

fn state(queue: &ExportQueue, id: Id) -> ExportJobState {
    queue.status(id).expect("the job").state
}

#[test]
fn stop_all_on_a_running_export_cancels_it_after_the_question() {
    let dir = std::env::temp_dir().join(format!("sq-stop-all-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("temp folder");
    let timeline = Timeline::new(Id::from_u128(3), "Main", SequenceFormat::new(Time::new(1, 25)), Vec::new());
    let project = Project::new(Id::from_u128(2), "p", Vec::new(), vec![timeline]);
    let file = dir.join("p.sqproj");
    let mut session =
        sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.clone()));
    session.save_as(&file).expect("save the test project");
    let (app, _picture) =
        crate::headless::build_in(&dir.join("support"), 1280, 800, 1.0, Some(&file), Path::new("/nonexistent"));
    app.turn();

    // The app's shell exports through a queue whose encoder never finishes by itself.
    let queue = Arc::new(ExportQueue::new(Arc::new(Slow)));
    app.with(|a| a.shell_parts().shell.export.queue = Some(Arc::clone(&queue)));
    let mut settings = ExportSettings::default();
    settings.audio.enabled = false;
    let id = queue.enqueue(ExportJob::new(
        Id::from_u128(9),
        "Cut",
        settings,
        dir.clone(),
        Arc::new(|| Ok(ExportSources::new(Box::new(OneFrame), None))),
    ));
    let runner = {
        let q = Arc::clone(&queue);
        std::thread::spawn(move || q.run_all())
    };
    let end = Instant::now() + Duration::from_secs(10);
    while state(&queue, id) != ExportJobState::Running && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(state(&queue, id), ExportJobState::Running);

    // The ring's popover, then its Stop All button (footer, right edge).
    app.with(|a| {
        a.shell_parts().shell.show_export_queue(
            sq_uikit::controls_grid::CGPoint::new(1250.0, 780.0),
            sq_uikit::controls_grid::CGRect::default(),
        )
    });
    app.turn();
    let frame = app.with(|a| a.shell_parts().shell.export_queue_popover_frame()).flatten().expect("the popover is up");
    click(&app, frame.max_x() - 12.0 - 36.0, frame.max_y() - 21.0);

    // The question comes up; Stop Export is its second button.
    let button = app
        .with(|a| a.shell_parts().shell.dialog().and_then(|d| d.button_frames().get(&1).copied()))
        .flatten()
        .expect("Stop All asks \"Stop the export?\"");
    click(&app, button.mid_x(), button.mid_y());

    let end = Instant::now() + Duration::from_secs(10);
    while !matches!(state(&queue, id), ExportJobState::Cancelled) && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(5));
        app.turn();
    }
    let last = state(&queue, id);
    // The popover's row follows: it no longer says Running (it refreshes every 250 ms).
    let end = Instant::now() + Duration::from_secs(3);
    let mut row = None;
    while Instant::now() < end {
        std::thread::sleep(Duration::from_millis(20));
        // In the app the export follower ends with an event that redraws; this test has no follower.
        app.with(sq_app_shell::App::set_needs_redraw);
        app.turn();
        row = app.with(|a| a.shell_parts().shell.export_queue_popover_jobs().first().map(|j| j.1.clone())).flatten();
        if row.as_ref().is_some_and(|s| *s != ExportJobState::Running) {
            break;
        }
    }
    assert!(
        row.is_some_and(|s| s != ExportJobState::Running && s != ExportJobState::Cancelling),
        "the row stays in Exporting"
    );
    let status = app.with(|a| a.status_text().to_string()).unwrap_or_default();
    assert_eq!(status, "Export of “Cut” canceled", "the status bar must not keep \"Exporting 48%\"");
    let _ = runner.join();
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(last, ExportJobState::Cancelled, "the running export was not stopped");
}

/// Windows bug: the Settings wheel did nothing in the real window. winit reports a notch as `LineDelta`; it goes through
/// `Pointer::win_wheel` and the app's gesture slot exactly as `main.rs` does.
#[test]
fn a_line_delta_wheel_scrolls_a_long_settings_page_through_the_real_root() {
    use winit::event::MouseScrollDelta;
    let dir = std::env::temp_dir().join(format!("sq-wheel-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("temp folder");
    let timeline = Timeline::new(Id::from_u128(3), "Main", SequenceFormat::new(Time::new(1, 25)), Vec::new());
    let project = Project::new(Id::from_u128(2), "p", Vec::new(), vec![timeline]);
    let file = dir.join("p.sqproj");
    let mut session =
        sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.clone()));
    session.save_as(&file).expect("save the test project");
    let (mut app, _picture) =
        crate::headless::build_in(&dir.join("support"), 1100, 420, 1.0, Some(&file), Path::new("/nonexistent"));
    app.resize(1100, 420);
    app.turn();
    app.with(|a| {
        a.emit_flow(sq_draw_shell::ShellFlow::ShowPreferencesAt(sq_draw_shell::PreferencesPage::Editing, false))
    });
    app.turn();
    app.turn();
    let scroll = |app: &sq_app_shell::Headless| {
        app.with(|a| a.shell_parts().shell.dialog().map(|d| (d.form_scroll(), d.form_scrolls()))).flatten()
    };
    assert_eq!(scroll(&app).map(|s| s.1), Some(true), "the Editing page is taller than the window");

    let mut pointer = crate::input::Pointer::default();
    let send = |(e, g): (InputEvent, sq_draw::scroll::ScrollGesture)| {
        app.with(|a| a.handle_with_gesture(&e, g));
        app.turn();
    };
    // One notch down (winit: negative y), at the 1.0 and the 1.5 display scale, a few notches apart.
    let mut now = 1.0;
    let mut last = 0.0;
    // Over the card, over the window's edge outside it, and over the bottom strip: the dialog is modal, the wheel is its own.
    for (i, (scale, at)) in
        [(1.0_f32, (550.0, 200.0)), (1.5, (20.0, 150.0)), (1.0, (1080.0, 410.0)), (1.0, (550.0, 5.0))]
            .into_iter()
            .enumerate()
    {
        pointer.moved(at.0, at.1, InputModifiers::default());
        now += 1.0;
        send(pointer.win_wheel(MouseScrollDelta::LineDelta(0.0, -1.0), InputModifiers::default(), scale, now));
        let now_at = scroll(&app).map_or(0.0, |s| s.0);
        assert!(now_at > last, "notch {i} at scale {scale} over {at:?}: the page stays at {last}");
        last = now_at;
    }
    // A high-resolution wheel sends fractions of a notch (a quarter each): they scroll too, as a precise gesture.
    for k in 0..4 {
        let quarter = MouseScrollDelta::LineDelta(0.0, -0.25);
        send(pointer.win_wheel(quarter, InputModifiers::default(), 1.0, 10.0 + f64::from(k) * 0.01));
    }
    assert!(scroll(&app).map_or(0.0, |s| s.0) > last, "fractional notches did not scroll");
    let _ = std::fs::remove_dir_all(&dir);
}
