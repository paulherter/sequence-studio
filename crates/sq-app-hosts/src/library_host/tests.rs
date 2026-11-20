//! Tests of the Library host: event routing against a real session, then a panel run through the headless App.

use super::*;
use sq_app_shell::{App, AppDeps, Headless};
use sq_core_time::{Id, SequentialIds, Timestamp};
use sq_draw::InputModifiers;
use sq_editor_session::SessionDeps;
use sq_library::preset_store::{PresetItem, PresetKind};
use sq_runtime::FakeClock;
use std::sync::Arc;

fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    let project = EditorSession::make_untitled(&mut ids);
    let mut deps = SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-tests"));
    deps.ids = Box::new(ids);
    EditorSession::new(project, deps)
}

fn entry(id: &str, is_cta: bool, graphic: Option<&str>) -> TextTemplateEntry {
    TextTemplateEntry { id: id.into(), name: id.into(), is_cta, graphic_preset_id: graphic.map(str::to_string) }
}

fn preset(kind: PresetKind) -> PresetItem {
    PresetItem {
        id: Id::from_u128(1),
        kind,
        name: "Glow".into(),
        created_at: Timestamp::from_unix_seconds(0.0),
        payload: Vec::new(),
        payload_version: 1,
        pack: None,
    }
}

/// A caption style of the real catalog.
const TEXT_ID: &str = "title-2-tier";

fn request(id: &str) -> LibraryPanelEvent {
    LibraryPanelEvent::Request(LibraryRequest::ApplyTextTemplate(id.into()))
}

#[test]
fn the_cta_template_places_the_end_card_in_one_undo_step() {
    let mut s = session();
    let templates = [entry("cta", true, None)];
    let (deferred, status) = route_library(&mut s, &templates, ApplyMode::Absolute, vec![request("cta")], Vec::new());
    assert!(deferred.is_empty() && status.is_empty());
    assert!(s.undo_name().is_some(), "the end card is an undo step");
}

#[test]
fn a_plain_text_template_places_a_text_clip_in_one_undo_step() {
    let mut s = session();
    let templates = [entry(TEXT_ID, false, None)];
    let (deferred, status) = route_library(&mut s, &templates, ApplyMode::Absolute, vec![request(TEXT_ID)], Vec::new());
    assert!(deferred.is_empty() && status.is_empty());
    assert!(s.undo_name().is_some(), "the text clip is an undo step");
    let before = s.active_timeline().map(|t| t.tracks.iter().map(|t| t.clips().len()).sum::<usize>());
    assert_eq!(before, Some(1));
    s.undo();
    assert_eq!(s.active_timeline().map(|t| t.tracks.iter().map(|t| t.clips().len()).sum::<usize>()), Some(0));
}

#[test]
fn dialog_requests_and_menus_are_deferred_in_order() {
    let mut s = session();
    let panel = vec![
        LibraryPanelEvent::Request(LibraryRequest::AddFolder),
        LibraryPanelEvent::Request(LibraryRequest::ImportPack),
    ];
    let (deferred, _) = route_library(&mut s, &[], ApplyMode::Absolute, panel, Vec::new());
    assert!(matches!(
        deferred.as_slice(),
        [LibraryDeferred::Request(LibraryRequest::AddFolder), LibraryDeferred::Request(LibraryRequest::ImportPack)]
    ));
}

#[test]
fn a_refused_preset_reports_the_session_error() {
    let mut s = session();
    let model = vec![LibraryModelEvent::ApplyPreset(preset(PresetKind::Easing), None)];
    let (deferred, status) = route_library(&mut s, &[], ApplyMode::Relative, Vec::new(), model);
    assert!(deferred.is_empty());
    assert_eq!(status, vec!["\u{201c}Glow\u{201d} is not an effect preset.".to_string()]);
}

#[test]
fn folder_hooks_reach_the_app_root() {
    let mut s = session();
    let model = vec![LibraryModelEvent::FoldersChanged(Vec::new())];
    let (deferred, _) = route_library(&mut s, &[], ApplyMode::Absolute, Vec::new(), model);
    assert!(matches!(deferred.as_slice(), [LibraryDeferred::Model(LibraryModelEvent::FoldersChanged(_))]));
}

pub(super) fn panel(root: &std::path::Path) -> LibraryDrawPanel {
    crate::standard::library_panel(root).expect("panel")
}

#[test]
fn the_host_draws_and_takes_clicks_inside_its_frame_through_the_app() {
    let root = crate::test_rig::test_dir("sq-app-hosts-lib");
    std::fs::create_dir_all(&root).expect("root");
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 800, 600);
    h.with(|a: &mut App| {
        let id = a.add_host(Box::new(LibraryHost::new(panel(&root), Box::new(|| ApplyMode::Absolute))));
        a.set_host_frame(id, Some(CGRect::new(0.0, 0.0, 400.0, 300.0)));
    });
    let (_, list) = h.turn();
    assert!(list.is_some_and(|l| !l.quads().is_empty()), "the panel draws");
    assert!(!h.input(&InputEvent::MouseDown { x: 700.0, y: 500.0, modifiers: InputModifiers::NONE }), "outside");
    assert!(h.input(&InputEvent::MouseDown { x: 200.0, y: 150.0, modifiers: InputModifiers::NONE }), "inside");
}

#[test]
fn a_saved_transition_preset_shows_its_still_in_the_preset_grid() {
    use crate::preset_stills::tests::{colors, picture_pixels};
    use sq_core_effects::transition::TransitionPresetExt;
    use sq_core_model::effect_defaults::TransitionPreset;
    use sq_draw_library::library::library_panel_model::LibrarySection;
    let root = crate::test_rig::test_dir("sq-app-hosts-lib-still");
    std::fs::create_dir_all(&root).expect("root");
    let mut host = LibraryHost::new(panel(&root), Box::new(|| ApplyMode::Absolute));
    host.share_atlas(crate::SharedAtlas::default());
    let payload = TransitionPreset::new(sq_core_model::TransitionKind::CrossDissolve, sq_core_time::Time::seconds(1))
        .payload()
        .expect("payload");
    let item = PresetItem::new(
        Id::from_u128(5),
        PresetKind::Transition,
        "Dissolve",
        Timestamp::from_unix_seconds(0.0),
        payload,
        1,
    );
    let model = &mut host.panel_host().panel.model;
    model.save_preset(item).expect("saved");
    model.set_selection(LibrarySection::Presets(Some(PresetKind::Transition)));
    let mut rig = crate::test_rig::Rig::new(session());
    host.sync(&rig.session);
    host.layout(CGRect::new(0.0, 0.0, 600.0, 400.0), &mut rig.cx());
    let mut c = sq_draw::Canvas::with_size(600.0, 400.0, None, 1.0);
    host.draw(&mut c, &sq_draw::DrawTheme::default(), &mut rig.cx());
    let pixels = picture_pixels(&c.list, 600, 400, host.take_image_uploads()).expect("the tile draws its still");
    assert!(colors(&pixels) > 50, "the tile shows picture pixels");
}

fn draw_shot(host: &mut LibraryHost, rig: &mut crate::test_rig::Rig) -> Vec<u8> {
    use crate::preset_stills::tests::picture_pixels;
    host.sync(&rig.session);
    host.layout(CGRect::new(0.0, 0.0, 600.0, 400.0), &mut rig.cx());
    let mut c = sq_draw::Canvas::with_size(600.0, 400.0, None, 1.0);
    host.draw(&mut c, &sq_draw::DrawTheme::default(), &mut rig.cx());
    picture_pixels(&c.list, 600, 400, host.take_image_uploads()).unwrap_or_default()
}

#[test]
fn a_built_in_graphic_shows_its_still_in_the_preset_grid() {
    use crate::preset_stills::tests::colors;
    use sq_draw_library::library::library_panel_model::LibrarySection;
    use sq_draw_library::library::text_templates::{TextTemplateTile, TextTemplates};
    struct Graphics(String);
    impl TextTemplates for Graphics {
        fn entries(&self) -> Vec<TextTemplateEntry> {
            vec![entry("graphic", false, Some(&self.0))]
        }
        fn tiles(&self, _: &[PresetItem]) -> Vec<TextTemplateTile> {
            Vec::new()
        }
    }
    let root = crate::test_rig::test_dir("sq-app-hosts-lib-graphic");
    std::fs::create_dir_all(&root).expect("root");
    let mut host = LibraryHost::new(panel(&root), Box::new(|| ApplyMode::Absolute));
    host.share_atlas(crate::SharedAtlas::default());
    let id = sq_editor_session::GraphicPresetCatalog::all().remove(0).id;
    let model = &mut host.panel_host().panel.model;
    model.set_templates(Box::new(Graphics(id)));
    model.set_selection(LibrarySection::Presets(None));
    let mut rig = crate::test_rig::Rig::new(session());
    let pixels = draw_shot(&mut host, &mut rig);
    assert!(colors(&pixels) > 50, "the graphic's tile shows picture pixels");
}

#[test]
fn a_video_file_shows_its_poster_frame_in_the_grid() {
    use crate::preset_stills::tests::colors;
    use sq_draw_library::library::library_panel_model::LibrarySection;
    use sq_editor_session::{Thumbnail, ThumbnailJob, ThumbnailSource};
    use sq_runtime::WorkerPool;
    struct Gradient;
    impl ThumbnailSource for Gradient {
        fn run(&self, _: &ThumbnailJob) -> Vec<Option<Thumbnail>> {
            let rgba: Vec<u8> = (0..64 * 36).flat_map(|i| [(i % 64 * 4) as u8, (i / 64 * 7) as u8, 90, 255]).collect();
            vec![Some(Thumbnail { width: 64, height: 36, rgba: Arc::new(rgba) })]
        }
    }
    let root = crate::test_rig::test_dir("sq-app-hosts-lib-poster");
    let media = root.join("media");
    std::fs::create_dir_all(&media).expect("media");
    std::fs::write(media.join("clip.mp4"), b"x").expect("file");
    let mut host = LibraryHost::new(panel(&root), Box::new(|| ApplyMode::Absolute));
    let atlas = crate::SharedAtlas::default();
    let pool = Arc::new(WorkerPool::manual());
    host.set_posters(crate::PosterPump::new(Arc::new(Gradient), Arc::clone(&pool), atlas));
    let model = &mut host.panel_host().panel.model;
    let folder = model.add_folder(media, None);
    model.set_selection(LibrarySection::Folder(folder.id));
    let mut rig = crate::test_rig::Rig::new(session());
    let _ = draw_shot(&mut host, &mut rig);
    while pool.step() {}
    let pixels = draw_shot(&mut host, &mut rig);
    assert!(colors(&pixels) > 50, "the tile shows the poster, not the kind icon");
}

#[test]
fn a_preset_is_a_list_item_and_a_click_selects_it() {
    use sq_core_effects::transition::TransitionPresetExt;
    use sq_core_model::effect_defaults::TransitionPreset;
    use sq_draw_library::library::library_panel_model::LibrarySection;
    let root = crate::test_rig::test_dir("sq-app-hosts-lib-a11y");
    std::fs::create_dir_all(&root).expect("root");
    let mut host = LibraryHost::new(panel(&root), Box::new(|| ApplyMode::Absolute));
    let payload = TransitionPreset::new(sq_core_model::TransitionKind::CrossDissolve, sq_core_time::Time::seconds(1))
        .payload()
        .expect("payload");
    let item = PresetItem::new(
        Id::from_u128(5),
        PresetKind::Transition,
        "Dissolve",
        Timestamp::from_unix_seconds(0.0),
        payload,
        1,
    );
    let model = &mut host.panel_host().panel.model;
    model.save_preset(item).expect("saved");
    model.set_selection(LibrarySection::Presets(Some(PresetKind::Transition)));
    let mut rig = crate::test_rig::Rig::new(session());
    host.sync(&rig.session);
    host.layout(CGRect::new(0.0, 0.0, 600.0, 400.0), &mut rig.cx());
    let mut c = sq_draw::Canvas::with_size(600.0, 400.0, None, 1.0);
    host.draw(&mut c, &sq_draw::DrawTheme::default(), &mut rig.cx());
    let find = |host: &LibraryHost| {
        let mut a = sq_draw::A11y::new(true);
        host.a11y(&mut a);
        a.nodes().iter().find(|(_, n)| n.label() == Some("Dissolve")).map(|(id, n)| (*id, n.is_selected()))
    };
    let (id, selected) = find(&host).expect("the preset is a node");
    assert_eq!(selected, Some(false));
    assert!(host.a11y_action(id, sq_app_shell::A11yAction::Click, &mut rig.cx()));
    assert_eq!(find(&host).map(|n| n.1), Some(Some(true)));
}

#[test]
fn a_display_scale_change_reaches_the_library_hit_test_before_the_next_draw() {
    let root = crate::test_rig::test_dir("sq-app-hosts-lib-scale");
    std::fs::create_dir_all(&root).expect("root");
    let h = Headless::new(session(), AppDeps::headless(Arc::new(FakeClock::new())), 800, 600);
    h.with(|a: &mut App| {
        let id = a.add_host(Box::new(LibraryHost::new(panel(&root), Box::new(|| ApplyMode::Absolute))));
        a.set_host_frame(id, Some(CGRect::new(0.0, 0.0, 400.0, 300.0)));
    });
    h.turn();
    for scale in [2.0_f32, 1.5, 1.0] {
        // The window moved to a display of another scale: the theme changes, the next frame has not run yet.
        h.with(|a: &mut App| a.set_theme(sq_draw::DrawTheme { scale, ..*a.theme() }));
        let at = |p: f32| InputEvent::MouseDown { x: p * scale, y: p * scale * 0.75, modifiers: InputModifiers::NONE };
        assert!(h.input(&at(390.0)), "the point (390, 292) is inside the panel at scale {scale}");
        assert!(!h.input(&at(410.0)), "the point (410, 307) is outside the panel at scale {scale}");
    }
}

/// The panel reports panel-local points; the root needs window points to find the timeline under a drag (the real
/// window showed no ghost and no drop for a Library tile).
#[test]
fn a_tile_drag_reports_window_points_not_panel_local_ones() {
    use sq_draw_library::library::library_panel_model::LibrarySection;
    let root = crate::test_rig::test_dir("sq-app-hosts-lib-drag");
    std::fs::create_dir_all(&root).expect("root");
    let mut host = LibraryHost::new(panel(&root), Box::new(|| ApplyMode::Absolute));
    let item = preset(PresetKind::Effect);
    let model = &mut host.panel_host().panel.model;
    model.save_preset(item).expect("saved");
    model.set_selection(LibrarySection::Presets(Some(PresetKind::Effect)));
    let mut rig = crate::test_rig::Rig::new(session());
    host.sync(&rig.session);
    let (ox, oy) = (300.0_f32, 200.0_f32);
    host.layout(CGRect::new(f64::from(ox), f64::from(oy), 600.0, 400.0), &mut rig.cx());
    let mut c = sq_draw::Canvas::with_size(1000.0, 700.0, None, 1.0);
    host.draw(&mut c, &sq_draw::DrawTheme::default(), &mut rig.cx());
    let mut seen = None;
    'scan: for sy in (60..380).step_by(10) {
        for sx in (180..560).step_by(10) {
            let (px, py) = (ox + sx as f32, oy + sy as f32);
            host.handle(&InputEvent::MouseDown { x: px, y: py, modifiers: InputModifiers::NONE }, &mut rig.cx());
            host.handle(&InputEvent::dragged(px + 60.0, py - 100.0), &mut rig.cx());
            let drags: Vec<_> = host
                .take_deferred()
                .into_iter()
                .filter_map(|d| match d {
                    LibraryDeferred::Panel(LibraryPanelEvent::Drag(_, _, at)) => Some(at),
                    _ => None,
                })
                .collect();
            host.handle(&InputEvent::MouseUp { x: px + 60.0, y: py - 100.0 }, &mut rig.cx());
            host.take_deferred();
            if let Some(at) = drags.first() {
                seen = Some((*at, (px + 60.0, py - 100.0)));
                break 'scan;
            }
        }
    }
    let (at, want) = seen.expect("a drag started on the preset tile");
    assert_eq!((at.x as f32, at.y as f32), want, "the drag point is a window point");
}

/// A picture whose red channel is the frame number at 10 frames a second, 64 x 36 pixels.
struct Numbered;

impl crate::preview_video::PictureSource for Numbered {
    fn picture_at(&mut self, seconds: f64) -> Option<crate::preview_video::PreviewPicture> {
        let frame = (seconds * 10.0).round() as u8;
        let rgba = (0..64 * 36).flat_map(|_| [frame.saturating_mul(8), 40, 90, 255]).collect();
        Some(crate::preview_video::PreviewPicture { width: 64, height: 36, rgba })
    }
}

/// A sound whose playhead the test moves.
struct Playhead(Rc<RefCell<sq_library::library_preview_player_portable::SoundState>>);

impl sq_library::library_preview_player_portable::PreviewSound for Playhead {
    fn load(&mut self, _: &std::path::Path) {
        self.0.borrow_mut().duration = 10.0;
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
    fn poll(&mut self) -> sq_library::library_preview_player_portable::SoundState {
        self.0.borrow().clone()
    }
}

/// One frame of the host over a persistent atlas (the window keeps its slots between frames): the picture the viewer
/// shows at its middle, as a red value.
fn viewer_red(host: &mut LibraryHost, rig: &mut crate::test_rig::Rig, atlas: &mut sq_draw::RgbaImage) -> u8 {
    use sq_app_shell::{ATLAS_SIZE, ATLAS_SLOT, ImageUpload};
    host.sync(&rig.session);
    host.layout(CGRect::new(0.0, 0.0, 600.0, 400.0), &mut rig.cx());
    let mut c = sq_draw::Canvas::with_size(600.0, 400.0, None, 1.0);
    host.draw(&mut c, &sq_draw::DrawTheme::default(), &mut rig.cx());
    for ImageUpload { at, image, .. } in host.take_image_uploads() {
        let Some((x, y)) = at else { continue };
        for row in 0..image.height {
            let (from, to) = (row * image.width * 4, ((y + row) * ATLAS_SIZE + x) * 4);
            atlas.pixels[to..to + image.width * 4].copy_from_slice(&image.pixels[from..from + image.width * 4]);
        }
    }
    let mut images = vec![None; sq_draw::DrawList::IMAGE_SLOTS];
    images[ATLAS_SLOT] = Some(atlas.clone());
    let clear = sq_draw::Color { r: 0.0, g: 0.0, b: 0.0, a: 1.0 };
    let sources = sq_draw::Sources { atlas: None, video: None, images: &images };
    let shot = sq_draw::SoftwareRenderer::render(&c.list, 600, 400, clear, &sources);
    let v = host.panel_host().panel.viewer_rect().expect("a video has a viewer");
    shot.pixels[(v.mid_y() as usize * 600 + v.mid_x() as usize) * 4]
}

#[test]
fn a_playing_video_preview_shows_a_new_picture_as_the_sound_moves_on() {
    playing_preview_moves(false);
}

/// With a full library the posters had used up the shared atlas, the viewer found no cell and kept its still.
#[test]
fn a_playing_video_preview_moves_although_posters_filled_the_atlas() {
    playing_preview_moves(true);
}

fn playing_preview_moves(fill_atlas: bool) {
    use sq_app_shell::ATLAS_SIZE;
    use sq_draw_library::library::library_panel_model::LibrarySection;
    let root = crate::test_rig::test_dir("sq-app-hosts-lib-live");
    let media = root.join("media");
    std::fs::create_dir_all(&media).expect("media");
    std::fs::write(media.join("clip.mp4"), b"x").expect("file");
    let mut host = LibraryHost::new(panel(&root), Box::new(|| ApplyMode::Absolute));
    let shared = crate::SharedAtlas::default();
    host.share_atlas(crate::SharedAtlas::clone(&shared));
    if fill_atlas {
        while shared.borrow_mut().place(100, 60).is_some() {}
    }
    host.set_preview_pictures(Arc::new(|_| Some(Box::new(Numbered) as Box<dyn crate::preview_video::PictureSource>)));
    let sound = Rc::default();
    let model = &mut host.panel_host().panel.model;
    model.preview.set_sound(Box::new(Playhead(Rc::clone(&sound))));
    let folder = model.add_folder(media, None);
    model.set_selection(LibrarySection::Folder(folder.id));
    let mut rig = crate::test_rig::Rig::new(session());
    host.panel_host().panel.refresh();
    let item = host.panel_host().panel.model.items().into_iter().next().expect("the clip");
    host.panel_host().panel.model.select_item_for_preview(Some(&item));
    let mut atlas =
        sq_draw::RgbaImage { width: ATLAS_SIZE, height: ATLAS_SIZE, pixels: vec![0; ATLAS_SIZE * ATLAS_SIZE * 4] };
    // The decode runs on a worker: draw until the viewer shows the frame of the sound's position.
    let mut shows = |seconds: f64, want: u8| {
        sound.borrow_mut().position = seconds;
        let mut red = 0;
        for _ in 0..600 {
            red = viewer_red(&mut host, &mut rig, &mut atlas);
            if red == want {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        red
    };
    assert_eq!(shows(1.0, 80), 80, "the frame at 1 s");
    assert_eq!(shows(2.5, 200), 200, "the frame at 2.5 s replaced it");
}

/// A Library host whose folder holds one video, a sound that only records, and a session with a clip that plays.
fn host_with_a_video_and_a_playing_sequence(
    tag: &str,
) -> (LibraryHost, crate::test_rig::Rig, Rc<RefCell<sq_library::library_preview_player_portable::SoundState>>) {
    use sq_draw_library::library::library_panel_model::LibrarySection;
    let root = crate::test_rig::test_dir(tag);
    let media = root.join("media");
    std::fs::create_dir_all(&media).expect("media");
    std::fs::write(media.join("clip.mp4"), b"x").expect("file");
    let mut host = LibraryHost::new(panel(&root), Box::new(|| ApplyMode::Absolute));
    host.set_preview_pictures(Arc::new(|_| Some(Box::new(Numbered) as Box<dyn crate::preview_video::PictureSource>)));
    let sound = Rc::default();
    let model = &mut host.panel_host().panel.model;
    model.preview.set_sound(Box::new(Playhead(Rc::clone(&sound))));
    let folder = model.add_folder(media, None);
    model.set_selection(LibrarySection::Folder(folder.id));
    host.panel_host().panel.refresh();
    let mut rig = crate::test_rig::Rig::new(session());
    rig.session.add_graphic_preset("sticker-circle", None, None);
    rig.session.play_pause();
    assert!(rig.session.is_playing(), "the sequence plays");
    (host, rig, sound)
}

#[test]
fn starting_a_library_preview_pauses_the_program_monitor() {
    let (mut host, mut rig, sound) = host_with_a_video_and_a_playing_sequence("sq-app-hosts-lib-will-play");
    let item = host.panel_host().panel.model.items().into_iter().next().expect("the clip");
    host.panel_host().panel.model.select_item_for_preview(Some(&item));
    assert!(sound.borrow().playing, "the preview plays");
    host.handle(&InputEvent::MouseMoved { x: 1.0, y: 1.0 }, &mut rig.cx());
    assert!(!rig.session.is_playing(), "the Program monitor gave way to the preview");
}

#[test]
fn the_program_keeps_playing_while_no_library_preview_starts() {
    let (mut host, mut rig, sound) = host_with_a_video_and_a_playing_sequence("sq-app-hosts-lib-no-play");
    host.handle(&InputEvent::MouseMoved { x: 1.0, y: 1.0 }, &mut rig.cx());
    assert!(!sound.borrow().playing);
    assert!(rig.session.is_playing(), "nothing started in the Library, the sequence plays on");
}
