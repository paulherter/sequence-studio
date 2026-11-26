// Swift: LibraryDrawPanelTests.swift
//! Tests of the Library panel (the Mac-only audio preview test is not ported: the portable player is silent).

use crate::library::library_draw_panel::LibraryPicture;
use crate::library::library_draw_panel::{Cell, DragPhase, LibraryDrawPanel, LibraryPanelEvent, LibraryRequest};
use crate::library::library_panel_logic::{
    LibraryDragPayload, LibraryLabels, LibraryPresetCell, LibrarySidebarRow, LibraryTileGeometry,
};
use crate::library::library_panel_model::LibraryItem;
use crate::library::library_panel_model::UnavailablePreviewProvider;
use crate::library::library_panel_model::{LibraryPanelDeps, LibraryPanelModel, LibrarySection, LibraryViewMode};
use crate::library::text_templates::{TextTemplateEntry, TextTemplateTile, TextTemplates};
use crate::test_support::MemoryDefaults;
use sq_core_project::cache_disk_policy::CacheDiskPolicy;
use sq_core_time::{IdSource, SequentialIds, Timestamp};
use sq_draw::theme::DrawTheme;
use sq_draw::ui_cx::DrawCursor;
use sq_draw::{Canvas, InputKey, InputModifiers, UiCx};
use sq_library::folder_scanner::FolderScanner;
use sq_library::folder_watching::FakeFolderWatcher;
use sq_library::library_folder_store::MemorySettings;
use sq_library::library_index::LibraryIndex;
use sq_library::library_item_kind::LibraryItemKind;
use sq_library::preset_organizer::{PresetKey, PresetScope};
use sq_library::preset_store::{PresetItem, PresetKind, PresetStore};
use sq_library::preview_requests::{PreviewCache, PreviewCoordinator};
use sq_os::Platform;
use sq_uikit::appearance_palette::{AppearanceSettings, UiDefaults};
use sq_uikit::controls_grid::{CGPoint, CGSize};
use sq_uikit::sqmenu_model::SQMenuItem;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

struct Templates;

impl TextTemplates for Templates {
    fn entries(&self) -> Vec<TextTemplateEntry> {
        vec![TextTemplateEntry {
            id: "bold-title".into(),
            name: "Bold Title".into(),
            is_cta: false,
            graphic_preset_id: None,
        }]
    }
    fn tiles(&self, _presets: &[PresetItem]) -> Vec<TextTemplateTile> {
        Vec::new()
    }
}

struct Env {
    root: PathBuf,
    media: PathBuf,
    panel: LibraryDrawPanel,
    defaults: MemoryDefaults,
}

static NEXT: AtomicU64 = AtomicU64::new(0);

impl Env {
    fn new() -> Env {
        Env::with_files(&["b_clip.mp4", "a_song.wav", "c_still.png"])
    }

    fn with_files(files: &[&str]) -> Env {
        let root = std::env::temp_dir().join(format!(
            "libdraw-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::SeqCst)
        ));
        let media = root.join("media");
        std::fs::create_dir_all(&media).expect("media dir");
        for f in files {
            std::fs::write(media.join(f), b"x").expect("file");
        }
        let now = Timestamp::from_unix_seconds(0.0);
        let store = PresetStore::open(&root.join("support"), false, now).expect("store");
        let coordinator = PreviewCoordinator::new(PreviewCache::in_caches_directory(
            &root.join("caches"),
            PreviewCache::DEFAULT_BYTE_CAP,
            CacheDiskPolicy::unchecked(),
        ));
        let defaults = MemoryDefaults::default();
        let mut model = LibraryPanelModel::new(LibraryPanelDeps {
            index: LibraryIndex::new(FolderScanner::default(), Box::new(FakeFolderWatcher::new())),
            preset_store: store,
            coordinator,
            provider: Box::new(UnavailablePreviewProvider),
            favorites_url: root.join("favorites.json"),
            ids: Box::new(SequentialIds::default()),
            clock: Box::new(|| Timestamp::from_unix_seconds(0.0)),
            whoosh_defaults: Box::new(defaults.clone()),
        });
        model.set_templates(Box::new(Templates));
        model.start();
        let mut panel = LibraryDrawPanel::new(model, Box::new(defaults.clone()), Box::new(MemorySettings::default()));
        panel.size = CGSize::new(600.0, 400.0);
        Env { root, media, panel, defaults }
    }

    /// The panel-local center of the cell at `index`.
    fn center(&mut self, index: usize) -> CGPoint {
        self.panel.refresh();
        let pl = self.panel.placed().into_iter().find(|p| p.index == index).expect("placed");
        let r = self.panel.cell_rect(&pl);
        CGPoint::new(r.mid_x(), r.mid_y())
    }

    fn requests(&mut self) -> Vec<LibraryRequest> {
        self.panel
            .take_events()
            .into_iter()
            .filter_map(|e| if let LibraryPanelEvent::Request(r) = e { Some(r) } else { None })
            .collect()
    }

    fn drags(&mut self) -> Vec<(LibraryDragPayload, DragPhase)> {
        self.panel
            .take_events()
            .into_iter()
            .filter_map(|e| if let LibraryPanelEvent::Drag(d, ph, _) = e { Some((d, ph)) } else { None })
            .collect()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn find<'a>(prefix: &str, items: &'a [SQMenuItem]) -> Option<&'a SQMenuItem> {
    for m in items {
        if m.title.starts_with(prefix) {
            return Some(m);
        }
        if let Some(hit) = m.submenu.as_ref().and_then(|s| find(prefix, s)) {
            return Some(hit);
        }
    }
    None
}

fn run(item: Option<&SQMenuItem>) {
    if let Some(a) = item.and_then(|i| i.action.as_ref()) {
        a();
    }
}

fn no_picture(_: &LibraryItem, _: sq_uikit::controls_grid::CGRect) -> Option<LibraryPicture> {
    None
}

#[test]
fn sidebar_rows_follow_the_mode() {
    let media = LibrarySidebarRow::rows(&[], &["Pack A".to_string()], false);
    assert!(media[0].section == Some(LibrarySection::All) && media[0].is_group);
    assert_eq!(media[1].section, Some(LibrarySection::Favorites));
    assert!(
        !media.iter().any(|r| matches!(r.section, Some(LibrarySection::Presets(_)) | Some(LibrarySection::Pack(_))))
    );
    let presets = LibrarySidebarRow::rows(&[], &["Pack A".to_string()], true);
    assert_eq!(presets[0].section, Some(LibrarySection::Presets(None)));
    assert!(
        !presets.iter().any(|r| r.section == Some(LibrarySection::Presets(Some(PresetKind::Easing)))),
        "kinds are chips"
    );
    assert_eq!(presets.last().and_then(|r| r.section.clone()), Some(LibrarySection::Pack("Pack A".into())));
    assert!(!LibrarySidebarRow::rows(&[], &[], true).iter().any(|r| r.title == "Packs"));
}

#[test]
fn empty_texts_and_tile_layout() {
    assert_eq!(LibraryLabels::empty_text(false, false, false, false, "").0, "No Media Yet");
    assert_eq!(LibraryLabels::empty_text(true, false, false, true, "").0, "Folder is offline");
    assert_eq!(LibraryLabels::empty_text(false, false, false, true, " x ").0, "No results");
    assert_eq!(LibraryTileGeometry::thumb_width(0.4), 96.0);
    let (columns, tile) = LibraryTileGeometry::layout(400.0, 0.4);
    assert_eq!(columns, 3);
    assert_eq!(tile.width, 128.0);
    assert!((tile.height - 98.0).abs() < 0.001, "{}", tile.height);
}

#[test]
fn empty_panel_offers_add_folder() {
    let mut env = Env::new();
    assert!(env.panel.offers_add_folder()); // opens on Media (All)
    env.panel.model.set_selection(LibrarySection::Favorites);
    env.panel.refresh();
    assert!(!env.panel.offers_add_folder()); // Favorites says how to add favorites
    env.panel.model.set_selection(LibrarySection::All);
    env.panel.refresh();
    let b = env.panel.add_folder_button_rect();
    env.panel.mouse_down(CGPoint::new(b.mid_x(), b.mid_y()), InputModifiers::NONE, 0.0);
    assert_eq!(env.requests(), vec![LibraryRequest::ImportMedia]);
}

/// The empty state's text wraps above the "Add Folder..." button at every pane size, in English and German (measured with
/// the real font; no text box touches the button, and the button stays inside the pane).
#[test]
fn the_empty_state_text_never_runs_under_the_add_folder_button() {
    let fonts =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
    let atlas = sq_draw::GlyphAtlas::inter(&fonts).expect("bundled Inter loads");
    let theme = DrawTheme::new(&AppearanceSettings::default(), 1.0);
    let mut env = Env::new();
    env.panel.model.set_selection(LibrarySection::All);
    env.panel.refresh();
    assert!(env.panel.offers_add_folder());
    let mut checked = 0;
    for (w, h) in [(300.0, 260.0), (360.0, 420.0), (520.0, 300.0), (900.0, 500.0), (1600.0, 900.0)] {
        env.panel.size = CGSize::new(w, h);
        let mut c = Canvas::with_size(w as f32, h as f32, Some(&atlas), 1.0);
        c.start_probe();
        env.panel.draw(&mut c, &theme, &mut UiCx::new(), &no_picture);
        let overlaps = c.probe_overlaps();
        assert!(overlaps.is_empty(), "{w}x{h}: text under the button: {overlaps:?}");
        let b = env.panel.add_folder_button_rect();
        assert!(b.max_y() <= h + 0.5, "{w}x{h}: the button is cut off at {b:?}");
        checked += c.probe().len();
    }
    assert!(checked > 5, "the probe saw the lines and the button");
}

#[test]
fn list_selects_with_shift_and_drags_the_files() {
    let mut env = Env::new();
    env.panel.model.add_folder(env.media.clone(), None);
    env.panel.set_view_mode(LibraryViewMode::List);
    env.panel.refresh();
    assert_eq!(env.panel.content_count(), 3);
    let c0 = env.center(0);
    env.panel.mouse_down(c0, InputModifiers::NONE, 0.0);
    env.panel.mouse_up(c0);
    let c2 = env.center(2);
    env.panel.mouse_down(c2, InputModifiers::SHIFT, 0.0);
    assert_eq!(env.panel.selected_items().len(), 3);
    // Dragging out of the panel carries every selected file; release outside ends the drag.
    env.panel.mouse_dragged(CGPoint::new(300.0, 500.0));
    env.panel.mouse_up(CGPoint::new(300.0, 500.0));
    let drags = env.drags();
    let Some((LibraryDragPayload::Files(urls), _)) = drags.first() else { panic!("no files drag") };
    assert_eq!(urls.len(), 3);
    assert_eq!(drags.last().map(|d| d.1), Some(DragPhase::Ended));
}

#[test]
fn drop_back_on_the_panel_cancels() {
    let mut env = Env::new();
    env.panel.model.add_folder(env.media.clone(), None);
    env.panel.set_view_mode(LibraryViewMode::List);
    let c1 = env.center(1);
    env.panel.mouse_down(c1, InputModifiers::NONE, 0.0);
    env.panel.mouse_dragged(CGPoint::new(300.0, 300.0));
    env.panel.mouse_up(CGPoint::new(300.0, 300.0));
    assert_eq!(env.drags().last().map(|d| d.1), Some(DragPhase::Canceled));
}

#[test]
fn grid_has_sections_and_search_filters() {
    let mut env = Env::new();
    let sub = env.media.join("Sub");
    std::fs::create_dir_all(&sub).expect("sub");
    std::fs::write(sub.join("d_deep.wav"), b"x").expect("deep");
    let f = env.panel.model.add_folder(env.media.clone(), None);
    env.panel.model.rescan(f.id);
    env.panel.set_view_mode(LibraryViewMode::Grid);
    env.panel.refresh();
    assert!(env.panel.cells().iter().any(Cell::is_header));
    env.panel.set_search_text("song");
    env.panel.refresh();
    let names: Vec<String> = env
        .panel
        .cells()
        .iter()
        .filter_map(|c| if let Cell::Item(it) = c { Some(it.entry.name().to_string()) } else { None })
        .collect();
    assert_eq!(names, vec!["a_song.wav".to_string()]);
    env.panel.set_search_text("zzz");
    env.panel.refresh();
    assert!(env.panel.is_no_hits());
    assert_eq!(env.panel.empty_text().0, "No results");
}

#[test]
fn options_menu_switches_view_and_flips_sort() {
    let mut env = Env::new();
    run(find("as List", &env.panel.options_menu()));
    env.panel.pump();
    assert_eq!(env.panel.model.view_mode(), LibraryViewMode::List);
    let by_name = |p: &LibraryDrawPanel| p.options_menu().into_iter().find(|m| m.title == "Sort by Name");
    assert_eq!(by_name(&env.panel).map(|m| m.is_checked), Some(true));
    let before = env.panel.model.ascending();
    run(by_name(&env.panel).as_ref());
    env.panel.pump();
    assert_ne!(env.panel.model.ascending(), before);
    run(find("Add Folder", &env.panel.options_menu()));
    env.panel.pump();
    assert_eq!(env.requests(), vec![LibraryRequest::AddFolder]);
}

#[test]
fn presets_show_templates_and_double_click_places_one() {
    let mut env = Env::new();
    env.panel.model.set_selection(LibrarySection::Presets(Some(PresetKind::TextTemplate)));
    env.panel.set_view_mode(LibraryViewMode::List);
    env.panel.refresh();
    let i = env
        .panel
        .cells()
        .iter()
        .position(|c| matches!(c, Cell::Preset(LibraryPresetCell::Template(_))))
        .expect("template cell");
    let Cell::Preset(LibraryPresetCell::Template(t)) = env.panel.cells()[i].clone() else { panic!("template") };
    let c = env.center(i);
    env.panel.mouse_down(c, InputModifiers::NONE, 0.0);
    env.panel.mouse_up(c);
    env.panel.mouse_down(c, InputModifiers::NONE, 0.0);
    assert!(env.requests().contains(&LibraryRequest::ApplyTextTemplate(t.id.clone())));
    // A template drags as a text template payload.
    env.panel.mouse_up(c);
    env.panel.mouse_down(c, InputModifiers::NONE, 10.0);
    env.panel.mouse_dragged(CGPoint::new(c.x, 600.0));
    assert_eq!(env.drags().first().map(|d| d.0.clone()), Some(LibraryDragPayload::TextTemplate(t.id)));
}

#[test]
fn saved_preset_menu_offers_export_and_delete() {
    let mut env = Env::new();
    let id = SequentialIds::default().next_id();
    let item = PresetItem::new(id, PresetKind::Effect, "Warm", Timestamp::from_unix_seconds(0.0), Vec::new(), 1);
    env.panel.model.save_preset(item.clone()).expect("save");
    env.panel.model.set_selection(LibrarySection::Presets(Some(PresetKind::Effect)));
    env.panel.set_view_mode(LibraryViewMode::List);
    env.panel.refresh();
    let key = PresetKey::user(item.id);
    let i = env.panel.cells().iter().position(|c| c.key() == key).expect("preset cell");
    let c = env.center(i);
    env.panel.mouse_down(c, InputModifiers::SECONDARY, 0.0);
    let menu = env.panel.item_menu(Some(i));
    run(find("Delete", &menu));
    run(find("Export", &menu));
    env.panel.pump();
    let reqs = env.requests();
    assert!(reqs.iter().any(|r| matches!(r, LibraryRequest::DeletePreset(p) if p.id == item.id)));
    assert!(reqs.iter().any(|r| matches!(r, LibraryRequest::ExportPreset(p) if p.id == item.id)));
    // Effect presets drag as effect presets (applied to the clip under the drop).
    env.panel.mouse_up(c);
    env.panel.mouse_down(c, InputModifiers::NONE, 0.0);
    env.panel.mouse_dragged(CGPoint::new(10.0, 700.0));
    assert_eq!(env.drags().first().map(|d| d.0.clone()), Some(LibraryDragPayload::EffectPreset(item.id)));
}

#[test]
fn empty_area_of_the_files_shows_the_full_file_menu_like_the_mac() {
    let env = Env::new();
    let menu = env.panel.item_menu(None);
    let titles: Vec<&str> = menu.iter().map(|m| m.title.as_str()).collect();
    assert_eq!(
        titles,
        ["Toggle Favorite", "Whoosh at Selected Cuts", "Add to SFX Folder", Platform::current().reveal_title()]
    );
    let enabled: Vec<&str> = menu.iter().filter(|m| m.is_enabled).map(|m| m.title.as_str()).collect();
    assert_eq!(enabled, ["Toggle Favorite", Platform::current().reveal_title()]);
}

#[test]
fn draws_without_an_atlas() {
    let mut env = Env::new();
    env.panel.model.add_folder(env.media.clone(), None);
    let theme = DrawTheme::new(&AppearanceSettings::default(), 1.0);
    let mut ui = UiCx::new();
    for mode in [LibraryViewMode::Grid, LibraryViewMode::List] {
        env.panel.set_view_mode(mode);
        let mut c = Canvas::with_size(600.0, 400.0, None, 1.0);
        env.panel.draw(&mut c, &theme, &mut ui, &no_picture);
        assert!(c.list.quads().len() > 10);
    }
}

#[test]
fn chips_wrap_onto_more_rows_in_a_narrow_panel_and_the_list_starts_below_them() {
    let mut env = Env::new();
    env.panel.model.set_selection(LibrarySection::Presets(None));
    env.panel.refresh();
    let p = &mut env.panel;
    p.size = CGSize::new(900.0, 400.0);
    assert_eq!(p.chip_rows(), 1);
    let wide_top = p.list_rect().min_y();
    p.size = CGSize::new(p.sidebar_rect().width + 150.0, 400.0);
    let frames = p.chip_frames();
    assert!(p.chip_rows() > 1);
    assert_eq!(p.list_rect().min_y(), wide_top + LibraryDrawPanel::CHIP_ROW_HEIGHT * (p.chip_rows() - 1) as f64);
    // Every chip stays inside the panel (unless one chip alone is wider) and no two overlap.
    for f in &frames {
        if f.2.width < 150.0 - 2.0 * LibraryDrawPanel::PAD {
            assert!(f.2.max_x() <= p.size.width - LibraryDrawPanel::PAD);
        }
    }
    for (a, b) in frames.iter().zip(frames.iter().skip(1)) {
        assert!(!crate::geom::intersects(&a.2, &b.2));
    }
    assert!(frames.iter().all(|f| f.2.max_y() <= p.list_rect().min_y()));
}

#[test]
fn search_row_spans_the_panel_with_switch_and_slider_at_the_right() {
    let mut env = Env::new();
    let p = &mut env.panel;
    p.size = CGSize::new(341.0, 500.0);
    p.model.set_view_mode(LibraryViewMode::Grid);
    assert_eq!(p.search_field_rect().min_x(), LibraryDrawPanel::PAD - 2.0); // measured against the AppKit crop
    let slider = p.slider_rect().expect("slider");
    assert_eq!(slider.max_x(), p.size.width - LibraryDrawPanel::PAD);
    assert_eq!(p.view_button_rect().max_x() + LibraryDrawPanel::PAD + 5.0, slider.min_x());
    assert_eq!(p.search_field_rect().max_x() + 11.0, p.view_button_rect().min_x());
    assert_eq!(p.sidebar_rect().min_y(), LibraryDrawPanel::SEARCH_ROW_HEIGHT);
    p.model.set_view_mode(LibraryViewMode::List);
    assert!(p.slider_rect().is_none());
    assert_eq!(p.view_button_rect().max_x(), p.size.width - LibraryDrawPanel::PAD);
}

#[test]
fn list_mode_reserves_a_column_header_row_above_the_items() {
    let mut env = Env::new();
    env.panel.model.add_folder(env.media.clone(), None);
    env.panel.model.set_view_mode(LibraryViewMode::Grid);
    env.panel.refresh();
    let grid_top = env.panel.list_rect().min_y();
    env.panel.model.set_view_mode(LibraryViewMode::List);
    env.panel.refresh();
    assert_eq!(env.panel.list_rect().min_y(), grid_top + LibraryDrawPanel::ROW_HEIGHT);
}

#[test]
fn library_search_keeps_undo_and_paste() {
    let mut env = Env::new();
    let mut ui = UiCx::new();
    env.panel.focus_search();
    for ch in "ab".chars() {
        assert!(env.panel.key(InputKey::Character(ch), InputModifiers::NONE, &mut ui));
    }
    assert_eq!(env.panel.search_text(), "ab");
    assert!(env.panel.key(InputKey::Character('z'), InputModifiers::COMMAND, &mut ui));
    assert_eq!(env.panel.search_text(), "");
    ui.clipboard.write("song");
    assert!(env.panel.key(InputKey::Character('v'), InputModifiers::COMMAND, &mut ui));
    assert_eq!(env.panel.search_text(), "song");
    assert!(env.panel.key(InputKey::Character('c'), InputModifiers::COMMAND, &mut ui));
}

#[test]
fn drag_from_empty_space_selects_the_tiles_the_band_crosses() {
    let mut env = Env::new();
    let f = env.panel.model.add_folder(env.media.clone(), None);
    env.panel.model.rescan(f.id);
    env.panel.set_view_mode(LibraryViewMode::Grid);
    env.panel.refresh();
    let tiles: Vec<_> = env.panel.placed().into_iter().filter(|p| !env.panel.cells()[p.index].is_header()).collect();
    assert!(tiles.len() >= 2);
    let first = env.panel.cell_rect(&tiles[0]);
    // Start in the list's empty bottom right corner, drag over the first and last tile.
    let empty = CGPoint::new(env.panel.size.width - 2.0, env.panel.size.height - 2.0);
    assert_eq!(env.panel.cell_index(empty), None);
    env.panel.mouse_down(empty, InputModifiers::NONE, 0.0);
    let target = CGPoint::new(first.min_x() + 1.0, first.min_y() + 1.0);
    env.panel.mouse_dragged(target);
    let want: std::collections::BTreeSet<String> = tiles.iter().map(|p| env.panel.cells()[p.index].key()).collect();
    assert_eq!(env.panel.selected(), &want);
    env.panel.mouse_up(target);
    assert!(!env.panel.is_pressed() && !env.panel.selected().is_empty());
    // A plain press on empty space starts over; Cmd keeps the earlier selection.
    let kept = env.panel.selected().clone();
    env.panel.mouse_down(empty, InputModifiers::COMMAND, 0.0);
    env.panel.mouse_dragged(CGPoint::new(empty.x - 1.0, empty.y - 1.0));
    assert_eq!(env.panel.selected(), &kept);
    env.panel.mouse_up(empty);
    env.panel.mouse_down(empty, InputModifiers::NONE, 0.0);
    assert!(env.panel.selected().is_empty());
}

#[test]
fn the_list_has_no_band() {
    let mut env = Env::new();
    env.panel.set_view_mode(LibraryViewMode::List);
    env.panel.refresh();
    let p = CGPoint::new(env.panel.size.width - 2.0, env.panel.size.height - 2.0);
    env.panel.mouse_down(p, InputModifiers::NONE, 0.0);
    assert!(!env.panel.is_pressed());
}

#[test]
fn dragging_the_sidebar_edge_resizes_and_stores_it() {
    let mut env = Env::new();
    env.panel.refresh();
    let edge = CGPoint::new(env.panel.sidebar_w(), 200.0);
    assert_eq!(env.panel.cursor(edge), Some(DrawCursor::ResizeLeftRight));
    env.panel.mouse_down(edge, InputModifiers::NONE, 0.0);
    env.panel.mouse_dragged(CGPoint::new(edge.x + 40.0, 200.0));
    env.panel.mouse_up(CGPoint::new(edge.x + 40.0, 200.0));
    assert!(env.panel.sidebar_w() == 163.0 && env.panel.sidebar_rect().width == 163.0);
    assert_eq!(env.defaults.string(LibraryDrawPanel::SIDEBAR_WIDTH_KEY).as_deref(), Some("163"));
    env.panel.mouse_down(CGPoint::new(163.0, 200.0), InputModifiers::NONE, 0.0);
    env.panel.mouse_dragged(CGPoint::new(5.0, 200.0));
    env.panel.mouse_up(CGPoint::new(5.0, 200.0));
    assert_eq!(env.panel.sidebar_w(), 96.0);
}

#[test]
fn the_viewer_height_drags_like_the_mac_bar_and_keeps_its_key() {
    let mut env = Env::new();
    env.panel.size = CGSize::new(600.0, 700.0);
    env.panel.model.add_folder(env.media.clone(), None);
    env.panel.set_view_mode(LibraryViewMode::List);
    env.panel.refresh();
    let i = env
        .panel
        .cells()
        .iter()
        .position(
            |c| matches!(c, Cell::Item(it) if it.entry.kind == sq_library::library_item_kind::LibraryItemKind::Image),
        )
        .expect("image cell");
    let c = env.center(i);
    env.panel.mouse_down(c, InputModifiers::NONE, 0.0);
    assert_eq!(env.panel.preview_mode(), Some(sq_library::library_preview_math::PreviewMode::Image));
    let before = env.panel.viewer_rect().expect("viewer").height;
    let b = env.panel.preview_bar_rect();
    let top = CGPoint::new(b.mid_x(), b.min_y() + 2.0);
    assert_eq!(env.panel.cursor(top), Some(DrawCursor::ResizeUpDown));
    env.panel.mouse_down(top, InputModifiers::NONE, 0.0);
    env.panel.mouse_dragged(CGPoint::new(top.x, top.y - 30.0));
    env.panel.mouse_up(CGPoint::new(top.x, top.y - 30.0));
    assert_eq!(env.panel.viewer_rect().expect("viewer").height, before + 30.0);
    assert_eq!(env.defaults.string("sq.library.previewHeight"), Some((before + 30.0).to_string()));
}

#[test]
fn the_list_rows_draw_the_pictures_too() {
    use sq_draw::draw_list::QuadKind;
    let mut env = Env::new();
    env.panel.model.add_folder(env.media.clone(), None);
    env.panel.set_view_mode(LibraryViewMode::List);
    let theme = DrawTheme::new(&AppearanceSettings::default(), 1.0);
    let mut ui = UiCx::new();
    let poster = |_: &LibraryItem, _: sq_uikit::controls_grid::CGRect| {
        Some(LibraryPicture { slot: 2, source: [0.0, 0.0, 1.0, 1.0], size: CGSize::new(160.0, 90.0) })
    };
    let mut c = Canvas::with_size(600.0, 400.0, None, 1.0);
    env.panel.draw(&mut c, &theme, &mut ui, &poster);
    let shown = c.list.quads().iter().filter(|q| q.kind == QuadKind::Image && q.slot == 2.0).count();
    assert_eq!(shown, 3);
}

#[test]
fn library_names_and_empty_texts_have_german_entries() {
    use sq_uikit::localization::SQL10n;
    let de = SQL10n::table("de");
    let mut keys = vec!["All".to_string(), "Search library".to_string(), "Built-in".to_string()];
    for k in std::iter::once(None).chain(PresetKind::ALL.iter().map(|k| Some(*k))) {
        keys.push(LibraryLabels::preset_title(k));
    }
    for (offline, presets, favorites, folders, q) in [
        (false, false, false, false, ""),
        (true, false, false, true, ""),
        (false, true, false, true, ""),
        (false, false, true, true, ""),
        (false, false, false, true, ""),
    ] {
        let (a, b) = LibraryLabels::empty_text(offline, presets, favorites, folders, q);
        keys.extend([a, b]);
    }
    let missing: Vec<&String> = keys.iter().filter(|k| !de.contains_key(*k)).collect();
    assert!(missing.is_empty(), "no German for {missing:?}");
}

#[test]
fn the_active_preset_chip_is_a_raised_stone_chip() {
    use crate::library::library_draw_panel::LibraryChip;
    sq_draw::motion::set_snap(true);
    let mut env = Env::new();
    env.panel.model.set_selection(LibrarySection::Presets(Some(PresetKind::Keystone)));
    let theme = DrawTheme::new(&AppearanceSettings::default(), 1.0);
    let mut c = Canvas::with_size(900.0, 400.0, None, 1.0);
    env.panel.draw(&mut c, &theme, &mut UiCx::new(), &no_picture);
    // "Motion" is on: its pill is the raised stone body (banded gradient of opaque quads), not one flat fill.
    let (_, _, f) =
        env.panel.chip_frames().into_iter().find(|c| c.0 == LibraryChip::Preset(PresetKind::Keystone)).expect("Motion");
    let r = f; // the kit chip is the whole 20 pt frame
    let bands = c
        .list
        .quads()
        .iter()
        .filter(|q| {
            q.stroke == 0.0
                && q.radius == sq_uikit::redesign_tokens::radius::CONTROL
                && q.color.a == 1.0
                && (q.rect.x, q.rect.y, q.rect.w, q.rect.h) == (r.x as f32, r.y as f32, r.width as f32, r.height as f32)
        })
        .count();
    assert!(bands >= 6, "banded raised body: {bands}");
}

#[test]
fn the_motion_entry_lists_built_in_motion_and_double_click_applies_it() {
    use crate::library::library_panel_model::LibraryModelEvent;
    let mut env = Env::new();
    assert_eq!(LibraryLabels::preset_title(Some(PresetKind::Keystone)), "Motion");
    env.panel.model.set_selection(LibrarySection::Presets(Some(PresetKind::Keystone)));
    env.panel.set_view_mode(LibraryViewMode::List);
    env.panel.refresh();
    let i = env
        .panel
        .cells()
        .iter()
        .position(|c| matches!(c, Cell::Preset(LibraryPresetCell::User(p)) if p.kind == PresetKind::Keystone))
        .expect("a built-in motion preset is listed");
    let Cell::Preset(LibraryPresetCell::User(p)) = env.panel.cells()[i].clone() else { panic!("preset") };
    let c = env.center(i);
    env.panel.mouse_down(c, InputModifiers::NONE, 0.0);
    env.panel.mouse_up(c);
    env.panel.mouse_down(c, InputModifiers::NONE, 0.0);
    let applied = env.panel.model.take_events();
    assert!(
        applied.iter().any(|e| matches!(e, LibraryModelEvent::ApplyPreset(a, _) if a.id == p.id)),
        "double-click applies the motion preset"
    );
}

#[test]
fn a_motion_preset_drags_like_an_effect_preset() {
    let mut env = Env::new();
    env.panel.model.set_selection(LibrarySection::Presets(Some(PresetKind::Keystone)));
    env.panel.set_view_mode(LibraryViewMode::List);
    env.panel.refresh();
    let i = env
        .panel
        .cells()
        .iter()
        .position(|c| matches!(c, Cell::Preset(LibraryPresetCell::User(p)) if p.kind == PresetKind::Keystone))
        .expect("a built-in motion preset is listed");
    let Cell::Preset(LibraryPresetCell::User(p)) = env.panel.cells()[i].clone() else { panic!("preset") };
    let c = env.center(i);
    env.panel.mouse_down(c, InputModifiers::NONE, 0.0);
    env.panel.mouse_dragged(CGPoint::new(10.0, 700.0));
    assert_eq!(env.drags().first().map(|d| d.0.clone()), Some(LibraryDragPayload::EffectPreset(p.id)));
}

#[test]
fn the_mode_switch_and_preset_chips_select_the_presets_section() {
    use crate::library::library_draw_panel::LibraryChip;
    let mut env = Env::new();
    env.panel.size = CGSize::new(900.0, 400.0);
    let (_, presets) = env.panel.mode_rects();
    assert!(!env.panel.model.is_showing_presets());
    env.panel.mouse_down(CGPoint::new(presets.mid_x(), presets.mid_y()), InputModifiers::NONE, 0.0);
    env.panel.mouse_up(CGPoint::new(presets.mid_x(), presets.mid_y()));
    assert!(env.panel.model.is_showing_presets(), "Presets switch");
    let (media, _) = env.panel.mode_rects(); // the switch moved up into the search row
    let titles: Vec<String> = env.panel.chip_frames().into_iter().map(|c| c.1).collect();
    assert_eq!(titles, ["Text", "Captions", "Effects", "Transitions", "Motion", "Audio", "LUTs"]);
    let (_, _, f) =
        env.panel.chip_frames().into_iter().find(|c| c.0 == LibraryChip::Preset(PresetKind::Keystone)).expect("Motion");
    env.panel.mouse_down(CGPoint::new(f.mid_x(), f.mid_y()), InputModifiers::NONE, 0.0);
    env.panel.mouse_up(CGPoint::new(f.mid_x(), f.mid_y()));
    assert_eq!(*env.panel.model.selection(), LibrarySection::Presets(Some(PresetKind::Keystone)));
    env.panel.mouse_down(CGPoint::new(f.mid_x(), f.mid_y()), InputModifiers::NONE, 0.0);
    env.panel.mouse_up(CGPoint::new(f.mid_x(), f.mid_y()));
    assert_eq!(*env.panel.model.selection(), LibrarySection::Presets(None), "the active chip clears");
    env.panel.mouse_down(CGPoint::new(media.mid_x(), media.mid_y()), InputModifiers::NONE, 0.0);
    env.panel.mouse_up(CGPoint::new(media.mid_x(), media.mid_y()));
    assert!(!env.panel.model.is_showing_presets(), "Media switch");
}

#[test]
fn a_pack_can_be_switched_off_in_the_menu_and_import_sits_in_the_head() {
    let mut env = Env::new();
    let id = SequentialIds::default().next_id();
    let mut item = PresetItem::new(id, PresetKind::Effect, "Glow", Timestamp::from_unix_seconds(0.0), Vec::new(), 1);
    item.pack = Some("Pack A".to_string());
    env.panel.model.save_preset(item).expect("save");
    env.panel.model.set_selection(LibrarySection::Presets(None));
    env.panel.refresh();
    let packed = |p: &LibraryDrawPanel| p.model.visible_presets().iter().filter(|x| x.pack.is_some()).count();
    assert_eq!(packed(&env.panel), 1);
    let menu = env.panel.options_menu();
    let packs = menu.iter().find(|m| m.title == "Packs").expect("Packs submenu");
    let row = &packs.submenu.as_ref().expect("rows")[0];
    assert!(row.is_checked, "a shown pack is checked");
    run(Some(row));
    env.panel.pump();
    assert_eq!(packed(&env.panel), 0, "a hidden pack stays out of the list");
    assert!(env.panel.model.presets().iter().any(|p| p.id == id), "nothing was deleted");
    assert!(env.panel.import_rect().is_none(), "no strip, no button");
    env.panel.set_import_rect(Some(sq_uikit::controls_grid::CGRect::new(
        200.0,
        -26.0,
        LibraryDrawPanel::IMPORT_WIDTH,
        20.0,
    )));
    let b = env.panel.import_rect().expect("Import in the tab strip in Presets mode");
    env.panel.mouse_down(CGPoint::new(b.mid_x(), b.mid_y()), InputModifiers::NONE, 0.0);
    env.panel.mouse_up(CGPoint::new(b.mid_x(), b.mid_y()));
    assert_eq!(env.requests(), vec![LibraryRequest::ImportPack]);
}

#[test]
fn the_audio_and_lut_chips_list_stacks_and_files_and_double_click_asks_the_host() {
    use crate::library::library_draw_panel::LibraryChip;
    use sq_library::lutlibrary::LUTEntry;
    let mut env = Env::new();
    env.panel.size = CGSize::new(900.0, 400.0);
    env.panel.model.set_selection(LibrarySection::Presets(None));
    let click = |env: &mut Env, chip: LibraryChip| {
        let (_, _, f) = env.panel.chip_frames().into_iter().find(|c| c.0 == chip).expect("chip");
        env.panel.mouse_down(CGPoint::new(f.mid_x(), f.mid_y()), InputModifiers::NONE, 0.0);
        env.panel.mouse_up(CGPoint::new(f.mid_x(), f.mid_y()));
    };
    click(&mut env, LibraryChip::AudioStacks);
    assert_eq!(*env.panel.model.selection(), LibrarySection::AudioStacks);
    env.panel.rebuild();
    let names: Vec<String> = env
        .panel
        .cells()
        .iter()
        .filter_map(|c| if let Cell::Preset(p) = c { Some(p.name().to_string()) } else { None })
        .collect();
    assert_eq!(names, ["Voice", "Rode NTG Indoor"]);
    let cell = LibraryPresetCell::AudioStack("audio.preset.voice".into(), "Voice".into());
    assert_eq!(cell.drag_payload(), Some(LibraryDragPayload::AudioStack("audio.preset.voice".into())));
    env.panel.activate(&cell);
    assert!(matches!(
        env.panel.take_events().as_slice(),
        [LibraryPanelEvent::Request(LibraryRequest::ApplyAudioStack(id))] if id == "audio.preset.voice"
    ));
    click(&mut env, LibraryChip::AudioStacks);
    assert_eq!(*env.panel.model.selection(), LibrarySection::Presets(None), "the active chip clears");

    env.panel.model.set_lut_entries(vec![LUTEntry {
        file_name: "Teal.cube".into(),
        path: "/luts/Teal.cube".into(),
        is_favourite: false,
    }]);
    click(&mut env, LibraryChip::Luts);
    env.panel.rebuild();
    let names: Vec<String> = env
        .panel
        .cells()
        .iter()
        .filter_map(|c| if let Cell::Preset(p) = c { Some(p.name().to_string()) } else { None })
        .collect();
    assert_eq!(names, ["Teal"]);
    env.panel.activate(&LibraryPresetCell::Lut("/luts/Teal.cube".into(), "Teal".into()));
    assert!(matches!(
        env.panel.take_events().as_slice(),
        [LibraryPanelEvent::Request(LibraryRequest::ApplyLut(p))] if p == "/luts/Teal.cube"
    ));
}

/// At the narrowest width the panel may be laid out at, no control is cut by the panel edge or overlaps its neighbor, in
/// both modes (the audit saw "Preset" cut mid-letter and "Sea..." at 200 pt next to a 96 pt sidebar).
#[test]
fn every_control_fits_at_the_minimum_panel_width() {
    let width = sq_uikit::panel_id::PanelID::Library.min_size().0;
    for presets in [false, true] {
        let mut env = Env::new();
        env.panel.size = CGSize::new(width, 600.0);
        if presets {
            env.panel.model.set_selection(LibrarySection::Presets(None));
        }
        env.panel.refresh();
        let (media, preset) = env.panel.mode_rects();
        let search = env.panel.search_field_rect();
        let view = env.panel.view_button_rect();
        for (name, r) in [("media", media), ("presets", preset), ("search", search), ("view", view)] {
            assert!(r.min_x() >= 0.0 && r.max_x() <= width, "{name} cut at {width} (presets: {presets}): {r:?}");
        }
        assert!(search.width >= 60.0, "search field only {} wide", search.width);
        if presets {
            let star = env.panel.star_rect();
            assert!(star.min_x() >= preset.max_x() && search.min_x() >= star.max_x(), "star between switch and search");
            assert!(search.max_x() <= width, "search cut");
        } else {
            assert!(search.max_x() <= view.min_x(), "search overlaps the view switch");
        }
        for (_, title, f) in env.panel.chip_frames() {
            assert!(f.max_x() <= width, "chip {title} cut at {width}");
        }
    }
}

#[test]
fn presets_mode_follows_the_kit_layout() {
    let mut env = Env::new();
    env.panel.size = CGSize::new(342.0, 520.0);
    env.panel.model.set_selection(LibrarySection::Presets(None));
    env.panel.refresh();
    let p = &mut env.panel;
    assert_eq!(p.sidebar_rect().width, 0.0, "no folder sidebar in Presets mode");
    let (media, presets) = p.mode_rects();
    assert_eq!(media.mid_y(), p.star_rect().mid_y(), "switch, star and search share one row");
    assert_eq!(p.search_field_rect().mid_y(), media.mid_y());
    assert!(p.slider_rect().is_none(), "no tile slider in Presets mode");
    assert!(presets.max_x() < p.star_rect().min_x());
    // Two flat columns whatever the slider says.
    let cols: std::collections::BTreeSet<i64> = p.placed().iter().map(|pl| pl.frame.x as i64).collect();
    assert!(cols.len() <= 2, "at most two tile columns: {cols:?}");
    // The star filters to favorites and back.
    let star = p.star_rect();
    let click = CGPoint::new(star.mid_x(), star.mid_y());
    p.mouse_down(click, InputModifiers::NONE, 0.0);
    assert_eq!(p.model.preset_scope(), PresetScope::Favorites);
    p.mouse_down(click, InputModifiers::NONE, 1.0);
    assert_eq!(p.model.preset_scope(), PresetScope::All);
    // Back to Media from the switch in the same row.
    p.mouse_down(CGPoint::new(media.mid_x(), media.mid_y()), InputModifiers::NONE, 2.0);
    assert!(!p.model.is_showing_presets());
    assert!(p.sidebar_rect().width > 0.0 || p.size.width < 300.0);
}

/// Bug 39: the Library list springs back from a rubber-band pull by frames alone, and a reopened panel starts in bounds.
#[test]
fn a_library_overscroll_springs_back_by_frames_alone() {
    use sq_draw::scroll::{ScrollGesture, ScrollPhase};
    let names: Vec<String> = (0..60).map(|i| format!("clip_{i:02}.mp4")).collect();
    let files: Vec<&str> = names.iter().map(String::as_str).collect();
    let mut env = Env::with_files(&files);
    env.panel.model.add_folder(env.media.clone(), None);
    env.panel.set_view_mode(LibraryViewMode::List);
    env.panel.size = CGSize::new(600.0, 200.0);
    env.panel.refresh();
    assert_eq!(env.panel.content_count(), 60);
    env.panel.sync_scroll_range();
    let max = env.panel.scroll_body.max_offset;
    assert!(max > 0.0, "sixty clips are taller than 200 pt");
    let lr = env.panel.list_rect();
    let at = CGPoint::new(lr.mid_x(), lr.mid_y());
    let pad = |phase| Some(ScrollGesture { precise: true, phase, ..Default::default() });
    env.panel.now = 1.0;
    env.panel.scroll_at(at, pad(ScrollPhase::Began), 0.0);
    env.panel.now = 1.01;
    env.panel.scroll_at(at, pad(ScrollPhase::Changed), 300.0);
    sq_draw::motion::begin_frame(1.02);
    assert!(env.panel.scroll() < 0.0, "pulled past the top");
    env.panel.now = 1.5;
    env.panel.scroll_at(at, pad(ScrollPhase::Ended), 0.0);
    let mut t = 1.5;
    while t < 3.0 {
        t += 1.0 / 60.0;
        sq_draw::motion::begin_frame(t);
        env.panel.scroll();
    }
    assert_eq!(env.panel.scroll(), 0.0);
    // Pulled again and the panel closed: the first frame after reopening shows the edge.
    env.panel.now = 10.0;
    env.panel.scroll_at(at, pad(ScrollPhase::Began), 0.0);
    env.panel.now = 10.01;
    env.panel.scroll_at(at, pad(ScrollPhase::Changed), 300.0);
    sq_draw::motion::begin_frame(60.0);
    assert_eq!(env.panel.scroll(), 0.0);
}

#[test]
fn the_media_mode_has_no_filter_chips_and_its_list_starts_under_the_switch() {
    let mut env = Env::new();
    env.panel.model.add_folder(env.media.clone(), None);
    env.panel.refresh();
    let p = &env.panel;
    assert!(!p.model.is_showing_presets());
    assert!(p.chip_frames().is_empty(), "no kind chips in the Media mode");
    assert_eq!(p.list_rect().min_y(), LibraryDrawPanel::SEARCH_ROW_HEIGHT + LibraryDrawPanel::MODE_ROW_HEIGHT);
    // The first row of tiles keeps the panel padding under the switch row.
    let first = p.placed().first().map(|pl| pl.frame.min_y());
    assert_eq!(first, Some(LibraryDrawPanel::PAD));
    // The search field filters by name only: "b" keeps b_clip.mp4 (and the file that has a b in its name).
    let all = env.panel.model.items().len();
    env.panel.model.set_query("clip");
    assert!(env.panel.model.items().len() < all);
}

/// Every Image quad the panel draws keeps the aspect of its picture and stays inside the rect it was given (bug: the
/// grid tile, the list thumbnail and the viewer drew the whole poster stretched into their own shape).
#[test]
fn pictures_keep_their_aspect_in_tiles_rows_and_the_viewer_at_every_viewer_height() {
    use sq_draw::draw_list::QuadKind;
    let theme = DrawTheme::new(&AppearanceSettings::default(), 1.0);
    for (pw, ph) in [(1920.0, 1080.0), (1080.0, 1920.0), (1000.0, 1000.0), (1440.0, 1080.0)] {
        for viewer in [150.0, 260.0, 330.0] {
            for mode in [LibraryViewMode::Grid, LibraryViewMode::List] {
                let mut env = Env::new();
                env.panel.size = CGSize::new(600.0, 800.0);
                env.panel.model.add_folder(env.media.clone(), None);
                env.panel.set_view_mode(mode);
                env.defaults.clone().set_string(LibraryDrawPanel::VIEWER_HEIGHT_KEY, &viewer.to_string());
                env.panel.refresh();
                let i = env
                    .panel
                    .cells()
                    .iter()
                    .position(|c| matches!(c, Cell::Item(it) if it.entry.kind == LibraryItemKind::Image))
                    .expect("image cell");
                let c = env.center(i);
                env.panel.mouse_down(c, InputModifiers::NONE, 0.0);
                assert_eq!(env.panel.viewer_rect().map(|v| v.height), Some(viewer));
                let poster = |_: &LibraryItem, _: sq_uikit::controls_grid::CGRect| {
                    Some(LibraryPicture { slot: 2, source: [0.25, 0.5, 0.5, 0.75], size: CGSize::new(pw, ph) })
                };
                let mut canvas = Canvas::with_size(600.0, 800.0, None, 1.0);
                env.panel.draw(&mut canvas, &theme, &mut UiCx::new(), &poster);
                let viewer_rect = env.panel.viewer_rect().expect("viewer");
                let images: Vec<_> =
                    canvas.list.quads().iter().filter(|q| q.kind == QuadKind::Image && q.slot == 2.0).collect();
                assert!(images.len() >= 4, "three cells and the viewer: {}", images.len());
                for q in images {
                    let aspect = f64::from(q.rect.w) / f64::from(q.rect.h);
                    assert!(
                        (aspect - pw / ph).abs() < 0.02 * pw / ph,
                        "{pw}x{ph} at viewer {viewer} ({mode:?}): drawn {}x{} is stretched",
                        q.rect.w,
                        q.rect.h
                    );
                }
                // The viewer's picture is as large as the viewer allows, centered in it.
                let big = canvas
                    .list
                    .quads()
                    .iter()
                    .filter(|q| q.kind == QuadKind::Image && f64::from(q.rect.h) > 60.0)
                    .max_by(|a, b| a.rect.h.total_cmp(&b.rect.h))
                    .expect("the viewer picture");
                assert!(
                    (f64::from(big.rect.x) + f64::from(big.rect.w) / 2.0 - viewer_rect.mid_x()).abs() < 1.0
                        && (f64::from(big.rect.y) + f64::from(big.rect.h) / 2.0 - viewer_rect.mid_y()).abs() < 1.0,
                    "centered in the viewer"
                );
            }
        }
    }
}

#[path = "library_preview_tests.rs"]
mod preview;

#[test]
fn r8_sidebar_tree_is_112_wide_with_its_split_at_122() {
    let mut env = Env::new();
    let p = &mut env.panel;
    p.size = CGSize::new(500.0, 400.0);
    p.model.set_selection(LibrarySection::All);
    p.refresh();
    assert_eq!(p.sidebar_w(), 123.0);
    let row = p.sidebar_row_rect(0);
    assert_eq!((row.min_x(), row.width), (6.0, 112.0));
    assert_eq!(p.content_x() - 1.0, 122.0);
}

#[test]
fn r8_media_row_has_24_high_segments_and_import_at_the_right() {
    let mut env = Env::new();
    env.panel.size = CGSize::new(500.0, 400.0);
    env.panel.model.set_selection(LibrarySection::All);
    env.panel.refresh();
    let (media, presets) = env.panel.mode_rects();
    assert_eq!((media.height, presets.height), (24.0, 24.0));
    let b = env.panel.import_rect().expect("Import… in Media mode");
    assert_eq!(b.max_x(), 500.0 - 12.0);
    assert!(b.min_x() > presets.max_x());
    env.panel.mouse_down(CGPoint::new(b.mid_x(), b.mid_y()), InputModifiers::NONE, 0.0);
    assert_eq!(env.requests(), vec![LibraryRequest::ImportMedia]);
}

#[test]
fn media_list_keeps_kind_size_created_columns_at_the_default_width() {
    let env = Env::new();
    assert_eq!(env.panel.list_col_widths().len(), 3);
    assert!(env.panel.shows_list_columns(env.panel.list_rect().width));
    assert!(!env.panel.shows_list_columns(299.0));
}

#[test]
fn switching_to_presets_opens_all_presets_whatever_chip_lies_under_the_click() {
    // The Presets chips take the place of the Media mode row, so the switch click must not reach them.
    for width in [420.0, 640.0, 900.0] {
        for dx in [4.0_f64, 16.0, 28.0, 40.0, 52.0] {
            let mut env = Env::new();
            env.panel.size = CGSize::new(width, 400.0);
            let (_, presets) = env.panel.mode_rects();
            let at = CGPoint::new(presets.min_x() + dx.min(presets.width - 2.0), presets.mid_y());
            env.panel.mouse_down(at, InputModifiers::NONE, 0.0);
            env.panel.mouse_up(at);
            assert!(env.panel.model.is_showing_presets());
            assert_eq!(*env.panel.model.selection(), LibrarySection::Presets(None), "width {width} dx {dx}");
        }
    }
}
