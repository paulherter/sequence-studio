//! The Project panel's footer "Locate…" through the real app root and the window's own pointer translation: the press
//! opens the Reconnect Media dialog, its default button asks for the folder, and the pick relinks the missing clip
//! (Windows acceptance item 3).

use crate::input::Pointer;
use sq_app_shell::{AppDeps, Headless, ShellFilePicker, answered};
use sq_core_model::{Clip, MediaFingerprint, MediaRef, TrackKind};
use sq_core_time::{Id, SequentialIds, Time, TimeRange};
use sq_draw::{DrawTheme, InputModifiers, text_log};
use sq_runtime::{Clock, ModalAsk, SystemClock};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use winit::event::{ElementState, MouseButton};

/// Answers the folder chooser with `folder`, like a user picking it.
struct FolderPicker(PathBuf);

impl ShellFilePicker for FolderPicker {
    fn choose_project(&mut self) -> ModalAsk<Option<PathBuf>> {
        answered(None)
    }
    fn choose_save_location(&mut self, _: &str, _: &str) -> ModalAsk<Option<PathBuf>> {
        answered(None)
    }
    fn choose_media(&mut self) -> ModalAsk<Vec<PathBuf>> {
        answered(Vec::new())
    }
    fn choose_folder(&mut self, _: &str) -> ModalAsk<Option<PathBuf>> {
        answered(Some(self.0.clone()))
    }
}

fn media_path(h: &Headless, id: Id) -> Option<String> {
    h.with(|a| a.session().project().media(id).map(|m| m.path.clone())).flatten()
}

fn run(scale: f32) {
    let root = std::env::temp_dir().join(format!("sq-locate-test-{}-{scale}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let (support, found) = (root.join("support"), root.join("found"));
    std::fs::create_dir_all(&support).expect("support");
    std::fs::create_dir_all(&found).expect("found");
    std::fs::write(found.join("tint.mp4"), [0u8]).expect("file");
    let id = Id::from_u128(0x71);
    let gone = root.join("moved").join("tint.mp4").to_string_lossy().into_owned();
    let (mut session, _) = crate::untitled_session(&support);
    session.perform("Setup", None, |p| {
        p.media.push(MediaRef::new(id, "tint", &gone, MediaFingerprint::new(1)));
        let mut ids = SequentialIds::default();
        let clip = Clip::new(
            Id::from_u128(0x72),
            "tint",
            id,
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::seconds(2)),
            Time::ZERO,
        );
        assert!(p.timelines[0].tracks[0].insert(clip, &mut ids).is_ok());
    });
    session.take_changes();
    let (w, hgt) = ((1440.0 * scale) as i64, (900.0 * scale) as i64);
    let clock = Arc::new(SystemClock::new());
    let mut deps = AppDeps::headless(Arc::clone(&clock) as Arc<dyn Clock>);
    deps.theme = DrawTheme { scale, ..DrawTheme::default() };
    let theme = deps.theme;
    let atlas = sq_draw::GlyphAtlas::ui(&crate::fonts_root()).expect("bundled Inter loads");
    atlas.set_point_scale(scale);
    deps.atlas = Some(atlas);
    let h = Headless::new(session, deps, w, hgt);
    crate::add_root(&h, clock, theme, &support, Default::default(), sq_editor_session::WorkspacePage::Edit);
    h.with(|a| a.services_mut().files = Box::new(FolderPicker(found.clone())));
    for _ in 0..5 {
        h.turn();
    }
    // A fresh profile starts with the Welcome tour on top; the user closes it first.
    let tour_open = || {
        h.with(|a| {
            use sq_draw_shell::ShellRoot;
            a.shell_parts().shell.dialog().is_some()
        })
        .unwrap_or(false)
    };
    for _ in 0..5 {
        if !tour_open() {
            break;
        }
        h.input(&sq_draw::InputEvent::KeyDown { key: sq_draw::InputKey::Escape, modifiers: InputModifiers::NONE });
        for _ in 0..3 {
            h.turn();
        }
    }
    assert!(!tour_open(), "the Welcome tour closes on Escape");
    // Where the footer draws its button (pixels), from the text the frame draws.
    text_log::start();
    h.with(|a| a.set_needs_redraw());
    h.turn();
    let runs = text_log::finish();
    let locate = runs.iter().find(|r| r.asked == "Locate…" && r.drawn.is_some()).unwrap_or_else(|| {
        panic!(
            "the footer draws Locate…: {} runs, {:?}",
            runs.len(),
            runs.iter().map(|r| r.asked.as_str()).collect::<Vec<_>>()
        )
    });
    let (x, y) = (f64::from(locate.rect.0 + locate.rect.2 / 2.0), f64::from(locate.rect.1 + locate.rect.3 / 2.0));

    let mut p = Pointer::default();
    let send = |e: &sq_draw::InputEvent| {
        h.input(e);
        h.turn();
    };
    send(&p.moved(x, y, InputModifiers::NONE));
    for e in p.button(ElementState::Pressed, MouseButton::Left, InputModifiers::NONE) {
        send(&e);
    }
    for e in p.button(ElementState::Released, MouseButton::Left, InputModifiers::NONE) {
        send(&e);
    }
    for _ in 0..3 {
        h.turn();
    }
    let dialog_open = h.with(|a| {
        use sq_draw_shell::ShellRoot;
        a.shell_parts().shell.dialog().is_some()
    });
    assert_eq!(dialog_open, Some(true), "the footer press opens Reconnect Media at scale {scale} (at {x},{y})");
    // Its default button (also "Locate…") asks for the folder; the pick relinks.
    text_log::start();
    h.with(|a| a.set_needs_redraw());
    h.turn();
    let runs = text_log::finish();
    let button = runs.iter().rfind(|r| r.asked == "Locate…" && r.drawn.is_some()).unwrap_or_else(|| {
        panic!("the dialog draws Locate…: {:?}", runs.iter().map(|r| r.asked.as_str()).collect::<Vec<_>>())
    });
    let (bx, by) = (f64::from(button.rect.0 + button.rect.2 / 2.0), f64::from(button.rect.1 + button.rect.3 / 2.0));
    send(&p.moved(bx, by, InputModifiers::NONE));
    for e in p.button(ElementState::Pressed, MouseButton::Left, InputModifiers::NONE) {
        send(&e);
    }
    for e in p.button(ElementState::Released, MouseButton::Left, InputModifiers::NONE) {
        send(&e);
    }
    for _ in 0..5 {
        h.turn();
    }
    let relinked = media_path(&h, id);
    assert!(
        relinked.as_deref().is_some_and(|p| Path::new(p).starts_with(&found)),
        "the clip's media points into the chosen folder at scale {scale}: {relinked:?}"
    );
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn the_footer_locate_button_opens_the_dialog_and_the_chosen_folder_relinks_the_clip() {
    for scale in [1.0_f32, 1.25, 2.0] {
        run(scale);
    }
}

#[test]
fn the_session_relinks_a_missing_file_found_in_a_folder() {
    let root = std::env::temp_dir().join(format!("sq-locate-session-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let (support, found) = (root.join("support"), root.join("found"));
    std::fs::create_dir_all(&support).expect("support");
    std::fs::create_dir_all(&found).expect("found");
    std::fs::write(found.join("tint.mp4"), [0u8]).expect("file");
    let id = Id::from_u128(0x71);
    let gone = root.join("moved").join("tint.mp4").to_string_lossy().into_owned();
    let (mut session, _) = crate::untitled_session(&support);
    session.perform("Setup", None, |p| p.media.push(MediaRef::new(id, "tint", &gone, MediaFingerprint::new(1))));
    let outcome = session.relink_missing(&found);
    assert_eq!(outcome.relinked, 1);
    let _ = std::fs::remove_dir_all(&root);
}
