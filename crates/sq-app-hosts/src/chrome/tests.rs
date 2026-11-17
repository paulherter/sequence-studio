use super::status_bar::{StatusBarContent, StatusPart, layout, part_at};
use super::title_row::{EXPORT_ICON, Mouse, PAGES, SMALL_FONT, TitleAction, TitleRow, WORKSPACE_ICON};
use sq_draw::TextMeasure;
use sq_editor_session::{MonitorQuality, SaveStatus};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::sqicon::SQIcon;
use std::time::{Duration, SystemTime};

/// 6 pt per character, so the layout is exact without fonts.
fn width(s: &str) -> f64 {
    s.chars().count() as f64 * 6.0
}

fn content() -> StatusBarContent {
    StatusBarContent {
        format: StatusBarContent::format_text(1920, 1080, 25.0, false),
        save: Some(SaveStatus::make(false, true, None, None, 0)),
        message: "Imported 2 files".into(),
        playback: StatusBarContent::playback_text(MonitorQuality::Half),
        ..StatusBarContent::default()
    }
}

#[test]
fn the_status_texts_are_the_swift_ones() {
    assert_eq!(StatusBarContent::format_text(1920, 1080, 25.0, false), "1920 × 1080 · 25 fps");
    assert_eq!(StatusBarContent::format_text(3840, 2160, 29.97, true), "3840 × 2160 · 29.97 fps VFR");
    assert_eq!(StatusBarContent::playback_text(MonitorQuality::Full), "Playback: Full · GPU");
}

#[test]
fn a_wide_bar_shows_everything_and_the_message_takes_the_gap() {
    let bar = CGRect::new(0.0, 772.0, 1400.0, 28.0);
    let f = layout(&content(), bar, &width, &width);
    assert!(f.format.is_some() && f.dot.is_some() && f.save.is_some());
    assert!(f.version.is_some() && f.playback.is_some());
    let (m, v) = (f.message.expect("message"), f.version.expect("version"));
    assert!(m.max_x() <= v.min_x(), "the message stops before the version");
}

#[test]
fn a_narrow_bar_drops_the_version_first_then_the_playback() {
    let at = |w: f64| layout(&content(), CGRect::new(0.0, 0.0, w, 28.0), &width, &width);
    let mid = at(700.0);
    assert!(mid.version.is_none() && mid.playback.is_some());
    let narrow = at(300.0);
    assert!(narrow.version.is_none() && narrow.playback.is_none());
}

#[test]
fn the_ring_and_the_relink_chip_are_clickable() {
    let mut s = content();
    s.export_progress = Some(0.4);
    s.relink_offer = "Found 4 offline files · Reconnect".into();
    let bar = CGRect::new(0.0, 772.0, 1400.0, 28.0);
    let f = layout(&s, bar, &width, &width);
    let (ring, chip) = (f.ring.expect("ring"), f.relink.expect("chip"));
    let center = |r: CGRect| CGPoint::new(r.mid_x(), r.mid_y());
    assert_eq!(part_at(center(ring), &s, bar, &width, &width), Some(StatusPart::Ring));
    assert_eq!(part_at(center(chip), &s, bar, &width, &width), Some(StatusPart::Relink));
    assert_eq!(part_at(CGPoint::new(2.0, 780.0), &s, bar, &width, &width), None);
}

#[test]
fn edit_times_read_like_the_mac_row() {
    let now = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
    let ago = |s: u64| TitleRow::edited_text(Some(now - Duration::from_secs(s)), false, now);
    assert_eq!(ago(5), "Edited just now");
    assert_eq!(ago(150), "Edited 2 min ago");
    assert_eq!(ago(3 * 3600), "Edited 3 h ago");
    assert_eq!(ago(4 * 86_400), "Edited 4 d ago");
    assert_eq!(TitleRow::edited_text(None, false, now), "");
    // After a save the row says "Saved", the word of the status bar.
    assert_eq!(TitleRow::edited_text(Some(now - Duration::from_secs(5)), true, now), "Saved just now");
    assert_eq!(TitleRow::edited_text(Some(now - Duration::from_secs(150)), true, now), "Saved 2 min ago");
}

#[test]
fn export_and_the_workspace_popup_answer_clicks() {
    let mut row = TitleRow::default();
    row.project_name = "Holiday".into();
    row.workspace_name = "Editing".into();
    let m = TextMeasure::new(None, 1.0);
    row.layout(78.0, (1200.0, 1188.0), 0.0, 44.0, &m, SystemTime::UNIX_EPOCH);
    let export = CGPoint::new(1180.0, 22.0);
    assert_eq!(row.mouse(Mouse::Down, export), (true, None));
    assert_eq!(row.mouse(Mouse::Up, export), (true, Some(TitleAction::Export)));
    let (taken, action) = row.mouse(Mouse::Down, CGPoint::new(1040.0, 22.0));
    assert!(taken && matches!(action, Some(TitleAction::Workspaces(_))));
    assert_eq!(row.mouse(Mouse::Down, CGPoint::new(500.0, 22.0)), (false, None));
}

#[test]
fn export_keeps_the_room_the_caller_leaves_for_the_window_buttons() {
    let mut row = TitleRow::default();
    row.project_name = "Holiday".into();
    row.workspace_name = "Editing".into();
    let m = TextMeasure::new(None, 1.0);
    // Windows: the three 46 pt buttons and 8 pt of air keep Export 146 pt from the right edge.
    row.layout(250.0, (1440.0, 1440.0 - 146.0), 0.0, 40.0, &m, SystemTime::UNIX_EPOCH);
    let export = row.controls().into_iter().find(|r| r.width < 120.0 && r.min_x() > 1200.0).expect("export");
    assert_eq!(export.max_x(), 1440.0 - 146.0);
}

#[test]
fn the_page_switch_sits_in_the_middle_and_a_press_picks_a_page() {
    use sq_editor_session::WorkspacePage;
    let mut row = TitleRow::default();
    row.project_name = "Holiday".into();
    row.workspace_name = "Editing".into();
    let m = TextMeasure::new(None, 1.0);
    row.layout(78.0, (1200.0, 1188.0), 0.0, 44.0, &m, SystemTime::UNIX_EPOCH);
    let edit = CGPoint::new(600.0 - 36.0, 22.0);
    let color = CGPoint::new(600.0 + 36.0, 22.0);
    assert_eq!(row.mouse(Mouse::Down, color), (true, Some(TitleAction::Page(WorkspacePage::Color))));
    assert_eq!(row.mouse(Mouse::Down, edit), (true, Some(TitleAction::Page(WorkspacePage::Edit))));
}

#[test]
fn a_narrow_bar_drops_the_page_switch() {
    let mut row = TitleRow::default();
    row.project_name = "Holiday".into();
    let m = TextMeasure::new(None, 1.0);
    row.layout(78.0, (360.0, 348.0), 0.0, 44.0, &m, SystemTime::UNIX_EPOCH);
    assert_eq!(row.mouse(Mouse::Down, CGPoint::new(180.0, 22.0)), (false, None));
}

#[test]
fn the_title_row_carries_the_frames_icons() {
    use sq_editor_session::WorkspacePage;
    // Shell/PageSwitch: film strip on Edit, half circle on Color; Button/Primary: upload; Button/RaisedMenu: layout.
    assert_eq!(PAGES[0], (WorkspacePage::Edit, SQIcon::Film, "Edit"));
    assert_eq!(PAGES[1], (WorkspacePage::Color, SQIcon::Contrast, "Color"));
    assert_eq!(EXPORT_ICON, SQIcon::Upload);
    assert_eq!(WORKSPACE_ICON, SQIcon::Layout);
}

#[test]
fn export_and_the_popup_make_room_for_their_icons() {
    let mut row = TitleRow::default();
    row.project_name = "Holiday".into();
    row.workspace_name = "Editing".into();
    let m = TextMeasure::new(None, 1.0);
    row.layout(78.0, (1200.0, 1188.0), 0.0, 44.0, &m, SystemTime::UNIX_EPOCH);
    let c = row.controls();
    let export = c[0];
    let popup = c[1];
    // 11 + icon 14 + 6 + label + 14, and 8 + 14 + 6 + label + 6 + 9 + 9.
    assert_eq!(export.width, (m.width("Export", SMALL_FONT, m.semibold())).ceil() + 45.0);
    assert_eq!(popup.width, m.width("Editing", SMALL_FONT, 0).ceil() + 52.0);
    assert_eq!(export.min_x() - popup.max_x(), 8.0);
}

#[test]
fn a_menu_bar_with_the_app_icon_leaves_no_name_or_edit_time_in_the_bar() {
    let mut row = TitleRow::default();
    row.project_name = "Holiday".into();
    row.workspace_name = "Editing".into();
    row.icon_in_menu_bar = true;
    row.edited = Some(SystemTime::UNIX_EPOCH);
    let m = TextMeasure::new(None, 1.0);
    row.layout(78.0, (1200.0, 1188.0), 0.0, 44.0, &m, SystemTime::UNIX_EPOCH);
    assert!(row.icon.is_none(), "one app icon in the bar, as in the kit's Windows frame");
    assert!(row.name.is_none(), "the kit's Windows bar has no project name");
    assert!(row.edited_slot.is_none(), "and no edit time");
}

#[test]
fn the_app_icon_sits_left_of_the_project_name_and_goes_first_when_narrow() {
    let mut row = TitleRow::default();
    row.project_name = "Holiday".into();
    row.workspace_name = "Editing".into();
    let m = TextMeasure::new(None, 1.0);
    row.layout(78.0, (1200.0, 1188.0), 0.0, 44.0, &m, SystemTime::UNIX_EPOCH);
    let icon = row.icon.expect("icon at a wide bar");
    let name = row.name.expect("name");
    assert!(icon.max_x() <= name.min_x());
    row.layout(78.0, (330.0, 318.0), 0.0, 44.0, &m, SystemTime::UNIX_EPOCH);
    assert!(row.icon.is_none(), "a narrow bar keeps the name, not the icon");
}
