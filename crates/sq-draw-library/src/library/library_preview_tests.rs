//! The Library preview bar: every transport button does what its key does, for music and for video, and the viewer
//! draws the host's live picture instead of the poster.

use super::{Env, LibraryPicture};
use crate::library::library_draw_panel::Cell;
use crate::library::library_panel_model::LibraryViewMode;
use sq_draw::draw_list::QuadKind;
use sq_draw::theme::DrawTheme;
use sq_draw::{Canvas, InputModifiers, UiCx};
use sq_library::library_item_kind::LibraryItemKind;
use sq_library::library_preview_player_portable::{PreviewSound, SoundState};
use sq_uikit::appearance_palette::AppearanceSettings;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use std::cell::RefCell;
use std::path::Path;
use std::rc::Rc;

/// A sound of 30 seconds whose playhead moves only when the player seeks.
struct Stub(Rc<RefCell<SoundState>>);

impl PreviewSound for Stub {
    fn load(&mut self, _: &Path) {
        *self.0.borrow_mut() = SoundState { duration: 30.0, ..SoundState::default() };
    }
    fn play(&mut self) {
        self.0.borrow_mut().playing = true;
    }
    fn pause(&mut self) {
        self.0.borrow_mut().playing = false;
    }
    fn seek(&mut self, seconds: f64) {
        self.0.borrow_mut().position = seconds;
    }
    fn set_gain(&mut self, _: f32) {}
    fn unload(&mut self) {}
    fn poll(&mut self) -> SoundState {
        self.0.borrow().clone()
    }
}

/// A panel previewing the one file of `kind` in its folder, the stub sound playing it from 12 s.
fn previewing(kind: LibraryItemKind) -> Env {
    let mut env = Env::new();
    env.panel.size = CGSize::new(600.0, 700.0);
    env.panel.model.preview.set_sound(Box::new(Stub(Rc::default())));
    env.panel.model.add_folder(env.media.clone(), None);
    env.panel.set_view_mode(LibraryViewMode::List);
    env.panel.refresh();
    let i = env
        .panel
        .cells()
        .iter()
        .position(|c| matches!(c, Cell::Item(it) if it.entry.kind == kind))
        .expect("a cell of that kind");
    let at = env.center(i);
    env.panel.mouse_down(at, InputModifiers::NONE, 0.0);
    env.panel.mouse_up(at);
    env.panel.model.preview.tick();
    env.panel.model.preview.seek(12.0);
    env.panel.model.preview.tick();
    assert!(env.panel.model.preview.is_playing(), "selecting plays");
    env
}

fn click(env: &mut Env, at: CGRect) {
    let p = CGPoint::new(at.mid_x(), at.mid_y());
    env.panel.mouse_down(p, InputModifiers::NONE, 0.0);
    env.panel.mouse_up(p);
    env.panel.model.preview.tick();
}

const KINDS: [LibraryItemKind; 2] = [LibraryItemKind::Audio, LibraryItemKind::Video];

#[test]
fn the_play_button_pauses_and_plays_like_space() {
    for kind in KINDS {
        let (mut by_click, mut by_key) = (previewing(kind), previewing(kind));
        for step in 0..2 {
            let r = by_click.panel.play_button_rect();
            click(&mut by_click, r);
            assert!(by_key.panel.handle_play_pause());
            by_key.panel.model.preview.tick();
            let playing = by_click.panel.model.preview.is_playing();
            assert_eq!(playing, by_key.panel.model.preview.is_playing(), "{kind:?} step {step}");
            assert_eq!(playing, step == 1, "{kind:?}: the first press pauses, the second plays");
        }
    }
}

#[test]
fn the_skip_buttons_move_five_seconds() {
    for kind in KINDS {
        let mut env = previewing(kind);
        let back = env.panel.back_button_rect();
        click(&mut env, back);
        assert_eq!(env.panel.model.preview.seconds(), 7.0, "{kind:?} back");
        let forward = env.panel.forward_button_rect();
        click(&mut env, forward);
        click(&mut env, forward);
        assert_eq!(env.panel.model.preview.seconds(), 17.0, "{kind:?} forward");
    }
}

#[test]
fn a_press_on_the_scrub_bar_jumps_there() {
    for kind in KINDS {
        let mut env = previewing(kind);
        let track = env.panel.scrub_track_rect();
        click(&mut env, track);
        assert!((env.panel.model.preview.seconds() - 15.0).abs() < 0.5, "{kind:?} halfway of 30 s");
    }
}

#[test]
fn the_buttons_work_while_the_sound_reports_a_problem_it_survived() {
    // The sound can note a read error and still play (it retries): the bar must not lock then.
    for kind in KINDS {
        let mut env = previewing(kind);
        let state = Rc::new(RefCell::new(SoundState {
            duration: 30.0,
            position: 12.0,
            playing: true,
            error: Some("read failed".into()),
        }));
        env.panel.model.preview.set_sound(Box::new(Stub(Rc::clone(&state))));
        env.panel.model.preview.tick();
        let back = env.panel.back_button_rect();
        click(&mut env, back);
        assert_eq!(env.panel.model.preview.seconds(), 7.0, "{kind:?}");
    }
}

#[test]
fn the_viewer_draws_the_hosts_live_picture_instead_of_the_poster() {
    let mut env = previewing(LibraryItemKind::Video);
    let theme = DrawTheme::new(&AppearanceSettings::default(), 1.0);
    let mut ui = UiCx::new();
    let poster = |_: &crate::library::library_panel_model::LibraryItem, _: CGRect| {
        Some(LibraryPicture { slot: 2, source: [0.0, 0.0, 1.0, 1.0], size: CGSize::new(160.0, 90.0) })
    };
    let mut viewer_quads = |env: &mut Env, slot: f32| {
        let mut c = Canvas::with_size(600.0, 700.0, None, 1.0);
        env.panel.draw(&mut c, &theme, &mut ui, &poster);
        let v = env.panel.viewer_rect().expect("a video has a viewer");
        let hit = |q: &&sq_draw::draw_list::DrawQuad| {
            q.kind == QuadKind::Image && q.slot == slot && f64::from(q.rect.h) > 0.5 * v.height
        };
        c.list.quads().iter().filter(hit).map(|q| q.uv).collect::<Vec<_>>()
    };
    assert_eq!(viewer_quads(&mut env, 2.0).len(), 1, "the poster before the first frame");
    env.panel.preview_frame =
        Some(LibraryPicture { slot: 0, source: [0.25, 0.5, 0.5, 0.75], size: CGSize::new(320.0, 180.0) });
    assert_eq!(viewer_quads(&mut env, 0.0), [[0.25, 0.5, 0.5, 0.75]], "the frame, from its part of the atlas");
    assert!(viewer_quads(&mut env, 2.0).is_empty(), "no poster under a live frame");
}

#[test]
fn a_panel_that_leaves_the_screen_pauses_its_preview_once() {
    let mut env = previewing(LibraryItemKind::Audio);
    env.panel.pause_preview();
    assert!(!env.panel.model.preview.is_playing());
    let seen = env.panel.model.preview.version();
    env.panel.pause_preview();
    assert_eq!(env.panel.model.preview.version(), seen, "an idle preview is left alone, no change every frame");
}
