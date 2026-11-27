//! Tests of the Project panel model, columns and menus (Swift `ProjectPanelModelTests`, `ProjectImportTests`,
//! `ImportReportTests`, `ProjectPanelSmartBinTests`, `ProjectPanelGroupingTests` ...).

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use serde_json::json;
use sq_core_model::{
    BinItem, BinItemRef, Clip, LabelColor, MediaFingerprint, MediaInfo, MediaRef, MediaStatus, Project, SequenceFormat,
    SmartBin, SmartBinKind, SmartBinUsage, Timeline, Track, TrackKind,
};
use sq_core_project::media_grouping::MediaGrouping;
use sq_core_project::media_policy::ProjectFolderSyncExt as _;
use sq_core_time::{Id, Time, TimeRange};
use sq_runtime::UiRef;
use sq_runtime::UiRoot;
use sq_runtime::testing::Rt;

use super::*;
use crate::{EditorSession, SessionDeps};

fn id(n: u128) -> Id {
    Id::from_u128(n)
}

/// A 3840x2160 29.97 H.264 media item (Swift `ref`).
fn media(n: u128, name: &str, path: &str, width: i64, dur: Time) -> MediaRef {
    let mut m = MediaRef::new(id(n), name, path, MediaFingerprint::new(1));
    m.duration = Some(dur);
    m.info = Some(
        serde_json::from_value::<MediaInfo>(json!({
            "duration": {"value": dur.value(), "timescale": dur.timescale()},
            "video": {"width": width, "height": 2160, "codec": "avc1", "bitDepth": 10, "chroma": "4:2:2",
                      "nominalFrameDuration": {"value": 1001, "timescale": 30000}, "isVariableFrameRate": false}
        }))
        .expect("media info"),
    );
    m
}

fn clip(media: Id) -> Clip {
    Clip::new(id(900), "c", media, TrackKind::Video, TimeRange::new(Time::ZERO, Time::new(5, 1)), Time::ZERO)
}

fn sequence_using(media: Id) -> Timeline {
    let mut v = Track::new(id(800), TrackKind::Video);
    v.set_clips(vec![clip(media)]);
    Timeline::new(id(700), "T", SequenceFormat::new(Time::new(1, 30)), vec![v])
}

fn session(p: Project) -> EditorSession {
    EditorSession::new(p, SessionDeps::headless(std::env::temp_dir().join("sq-es07-autosave")))
}

fn model(p: &Project) -> ProjectPanelModel {
    ProjectPanelModel::new(p.clone(), ProjectPanelDeps::headless())
}

fn project_with(media: Vec<MediaRef>) -> Project {
    Project::new(id(1000), "P", media, vec![])
}

fn names(m: &ProjectPanelModel, bin: &sq_core_model::Bin) -> Vec<String> {
    m.children(bin).iter().map(|c| m.project().display_name(c.item_ref())).collect()
}

// MARK: formatting and cells

#[test]
fn format_strings() {
    let m = media(2, "a", "/x/a", 3840, Time::new(10, 1));
    assert_eq!(ProjectPanelModel::format_string(&m), "3840\u{D7}2160 29.97 H.264 4:2:2 10-bit");
    assert_eq!(ProjectPanelModel::format_label(&m), "3840\u{D7}2160");
    let mut none = m.clone();
    none.info = None;
    assert_eq!(ProjectPanelModel::format_string(&none), "");
    assert_eq!(ProjectPanelModel::format_label(&none), "");
    assert_eq!(ProjectPanelModel::aspect_label(1080, 1920), "9:16");
    assert_eq!(ProjectPanelModel::aspect_label(3840, 2160), "16:9");
    assert_eq!(ProjectPanelModel::aspect_label(0, 0), "");
    let audio: MediaInfo = serde_json::from_value(json!({
        "duration": {"value": 1, "timescale": 1}, "audio": {"sampleRate": 44100, "channels": 2, "codec": "mp3"}}))
    .expect("audio info");
    let mut a = MediaRef::new(id(3), "m", "/x/m.mp3", MediaFingerprint::new(1));
    a.info = Some(audio);
    assert_eq!(ProjectPanelModel::format_label(&a), "44.1 kHz");
    assert_eq!(ProjectPanelModel::format_string(&a), "44.1 kHz 2 ch mp3");
}

#[test]
fn cells_and_tooltips() {
    let m = media(2, "a", "/x/a", 3840, Time::new(10, 1));
    let mut vfr = media(3, "phone", "/x/phone", 3840, Time::new(10, 1));
    if let Some(v) = vfr.info.as_mut().and_then(|i| i.video.as_mut()) {
        v.is_variable_frame_rate = true;
    }
    let mut p = project_with(vec![m.clone(), vfr.clone()]);
    let t = Timeline::new(
        id(4),
        "Main",
        SequenceFormat { width: 1080, height: 1920, ..SequenceFormat::new(Time::new(1, 30)) },
        vec![],
    );
    p.timelines.push(t);
    let model = model(&p);
    assert_eq!(model.cell_text(Column::Format, BinItemRef::Media(m.id)), "3840\u{D7}2160");
    assert_eq!(model.cell_text(Column::Format, BinItemRef::Sequence(id(4))), "9:16");
    assert_eq!(
        model.cell_tooltip(Column::Format, BinItemRef::Media(m.id)).as_deref(),
        Some("3840\u{D7}2160 29.97 H.264 4:2:2 10-bit")
    );
    assert_eq!(model.cell_tooltip(Column::Duration, BinItemRef::Media(m.id)), None);
    let note = ProjectPanelModel::variable_frame_rate_note(&vfr).expect("note");
    assert!(note.starts_with("Variable frame rate") && note.contains("Conform"));
    assert_eq!(ProjectPanelModel::variable_frame_rate_note(&m), None);
    assert_eq!(model.cell_tooltip(Column::FrameRate, BinItemRef::Media(vfr.id)), Some(note.clone()));
    assert!(model.cell_tooltip(Column::Format, BinItemRef::Media(vfr.id)).is_some_and(|t| t.ends_with(&note)));
    assert_eq!(model.cell_text(Column::FrameRate, BinItemRef::Media(vfr.id)), "29.97 fps VFR");
    assert_eq!(model.cell_text(Column::Resolution, BinItemRef::Media(m.id)), "3840\u{D7}2160");
    assert_eq!(model.cell_text(Column::Codec, BinItemRef::Media(m.id)), "H.264");
}

#[test]
fn duration_timecode() {
    let ntsc = Time::new(1001, 30000);
    let m = media(2, "a", "/x/a", 3840, ntsc * (30 * 3725));
    assert_eq!(ProjectPanelModel::duration_string(&m), "01:02:05:00");
    // 301 frames at 29.97 -> 00:00:10:01 (rounded fps 30)
    assert_eq!(ProjectPanelModel::duration_string(&media(2, "a", "/x/a", 3840, ntsc * 301)), "00:00:10:01");
}

// MARK: editing

#[test]
fn bin_operations() {
    let mut s = session(project_with(vec![]));
    let mut m = model(s.project());
    let a = m.new_bin(&mut s, "A").expect("a");
    let b = m.new_bin(&mut s, "B").expect("b");
    assert_eq!(s.undo_step_depth(), 2);
    assert!(m.rename(&mut s, BinItemRef::Bin(a), "Alpha"));
    assert!(!m.rename(&mut s, BinItemRef::Bin(a), "  "));
    assert_eq!(m.project().bin(a).map(|b| b.name.as_str()), Some("Alpha"));
    assert!(m.move_items(&mut s, &[BinItemRef::Bin(b)], a, None));
    assert!(!m.move_items(&mut s, &[BinItemRef::Bin(a)], b, None)); // cycle refused
    assert_eq!(m.project().bin(a).map(|b| b.children.len()), Some(1));
    assert!(m.delete(&mut s, &[BinItemRef::Bin(a)]).changed);
    let kids: Vec<_> = m.project().root_bin.children.iter().map(BinItem::item_ref).collect();
    assert_eq!(kids, vec![BinItemRef::Bin(b)]);
    let root = m.project().root_bin.id;
    assert!(!m.delete(&mut s, &[BinItemRef::Bin(root)]).changed);
    assert_eq!(s.project(), m.project());
}

#[test]
fn media_delete_and_blocking() {
    let (r1, r2) = (media(2, "a", "/x/a", 3840, Time::new(10, 1)), media(3, "b", "/x/b", 3840, Time::new(10, 1)));
    let mut p = project_with(vec![r1.clone(), r2.clone()]);
    p.timelines.push(sequence_using(r2.id));
    let mut s = session(p.clone());
    let mut m = model(&p);
    assert!(m.delete(&mut s, &[BinItemRef::Media(r1.id)]).changed);
    assert_eq!(m.project().media.iter().map(|x| x.id).collect::<Vec<_>>(), vec![r2.id]);
    let blocked = m.delete(&mut s, &[BinItemRef::Media(r2.id)]);
    assert!(!blocked.changed && blocked.blocked_items == 1);
    assert_eq!(blocked.message().as_deref(), Some("Not deleted: still used in \u{201C}T\u{201D}."));
    assert_eq!(ProjectPanelModel::delete_name(&[BinItemRef::Bin(id(5))]), "Delete Folder");
    assert_eq!(ProjectPanelModel::delete_name(&[BinItemRef::Media(r1.id)]), "Delete Items");
}

#[test]
fn clear_makes_used_media_offline_and_keeps_its_clips() {
    let (used, free) =
        (media(2, "u.mov", "/x/u.mov", 3840, Time::new(10, 1)), media(3, "f.mov", "/x/f.mov", 3840, Time::new(10, 1)));
    let mut p = project_with(vec![used.clone(), free.clone()]);
    p.timelines.push(sequence_using(used.id));
    let mut s = session(p.clone());
    let mut m = model(&p);
    assert_eq!(m.delete(&mut s, &[BinItemRef::Media(used.id)]).blocked_items, 1); // delete still refuses
    let r = m.clear(&mut s, &[BinItemRef::Media(used.id), BinItemRef::Media(free.id)]);
    assert!(r.changed && r.offlined == 1 && r.blocked_items == 0);
    assert_eq!(m.project().media.iter().map(|x| x.id).collect::<Vec<_>>(), vec![used.id]);
    assert_eq!(m.project().media[0].status(), MediaStatus::Missing);
    assert_eq!(m.project().timelines[0].tracks[0].clips().len(), 1);
    assert_eq!(r.message().as_deref(), Some("1 item is offline now: the clips stay, Relink attaches a file."));
}

#[test]
fn labels_find_and_poster() {
    let (a, b) =
        (media(2, "needle.mov", "/x/a", 3840, Time::new(10, 1)), media(3, "hay.mov", "/x/b", 3840, Time::new(10, 1)));
    let p = project_with(vec![a.clone(), b.clone()]);
    let mut s = session(p.clone());
    let mut m = model(&p);
    assert!(m.set_label(&mut s, Some(LabelColor::Rose), &[BinItemRef::Media(a.id)]));
    assert_eq!(m.label(BinItemRef::Media(a.id)), LabelColor::Rose);
    assert!(!m.set_label(&mut s, Some(LabelColor::Rose), &[BinItemRef::Media(a.id)])); // nothing changed
    assert_eq!(m.find(&FindCriteria::new("NEEDLE", FindField::Name, false)), vec![BinItemRef::Media(a.id)]);
    assert_eq!(
        m.find(&FindCriteria::new(LabelColor::Rose.display_name(), FindField::Label, false)),
        vec![BinItemRef::Media(a.id)]
    );
    assert!(m.find(&FindCriteria::default()).is_empty());
    assert_eq!(m.find(&FindCriteria::new("", FindField::Name, true)).len(), 2); // both paths do not exist
    assert!(m.set_poster(&mut s, Some(Time::new(-1, 1)), &[BinItemRef::Media(a.id), BinItemRef::Bin(id(77))]));
    assert_eq!(m.project().media(a.id).and_then(|x| x.poster_time), Some(Time::ZERO));
    assert!(m.set_poster(&mut s, None, &[BinItemRef::Media(a.id)]));
    assert_eq!(m.project().media(a.id).and_then(|x| x.poster_time), None);
}

#[test]
fn smart_bins_filter_and_round_trip() {
    let (used, free) = (
        media(2, "used.mov", "/x/used.mov", 3840, Time::new(10, 1)),
        media(3, "free.mov", "/x/free.mov", 3840, Time::new(10, 1)),
    );
    let mut p = project_with(vec![used.clone(), free.clone()]);
    p.timelines.push(sequence_using(used.id));
    let mut s = session(p.clone());
    let mut m = model(&p);
    let bin = SmartBin {
        id: id(50),
        name: "Unused".into(),
        text: String::new(),
        usage: SmartBinUsage::Unused,
        kind: SmartBinKind::Any,
        offline_only: false,
        label: None,
        tokens: None,
        searches_spoken: None,
    };
    assert_eq!(m.add_smart_bin(&mut s, bin.clone()), Some(id(50)));
    assert_eq!(m.add_smart_bin(&mut s, SmartBin { id: id(51), name: " ".into(), ..bin.clone() }), None);
    assert_eq!(m.smart_bin_media(id(50)), vec![free.id]);
    m.set_active_smart_bin(Some(id(50)));
    let root = m.project().root_bin.clone();
    assert_eq!(m.children(&root).iter().map(BinItem::item_ref).collect::<Vec<_>>(), vec![BinItemRef::Media(free.id)]);
    assert!(m.update_smart_bin(&mut s, SmartBin { name: "Renamed".into(), ..bin.clone() }));
    assert!(m.remove_smart_bin(&mut s, id(50)));
    assert_eq!(m.active_smart_bin(), None);
    assert!(m.project().smart_bins.is_none());
    m.set_media_filter(MediaFilter::Unused);
    let from_filter = m.current_filter_as_smart_bin(id(52), "From filter");
    assert_eq!(from_filter.usage, SmartBinUsage::Unused);
    assert!(!from_filter.offline_only);
}

/// Another panel edits the project after the Project panel last synced; the panel's next command must not write its
/// stale copy back over that edit, and Undo takes back only the command.
#[test]
fn a_command_after_an_edit_through_another_panel_keeps_both_edits() {
    let p = project_with(vec![]);
    let mut s = session(p.clone());
    let mut m = model(&p);
    s.set_project_notes("kept");
    assert_eq!(m.project().notes(), "", "the panel's copy is stale");
    let bin = SmartBin {
        id: id(50),
        name: "Unused".into(),
        text: String::new(),
        usage: SmartBinUsage::Unused,
        kind: SmartBinKind::Any,
        offline_only: false,
        label: None,
        tokens: None,
        searches_spoken: None,
    };
    assert_eq!(m.add_smart_bin(&mut s, bin), Some(id(50)));
    assert_eq!(s.project().notes(), "kept", "the other panel's edit survived");
    assert!(s.project().smart_bins.is_some(), "the command ran");
    assert_eq!(m.project().notes(), "kept", "the panel adopted the session's project");
    assert!(s.undo());
    assert!(s.project().smart_bins.is_none());
    assert_eq!(s.project().notes(), "kept", "one Undo takes back only the command");
    assert!(s.undo());
    assert_eq!(s.project().notes(), "");
}

#[test]
fn sort_search_and_filters_are_display_only() {
    let b = media(2, "b.mov", "/x/b", 1920, Time::new(10, 1));
    let a = media(3, "a.mov", "/x/a", 3840, Time::new(20, 1));
    let c = media(4, "c.mov", "/x/c", 1280, Time::new(5, 1));
    let p = project_with(vec![b, a, c]);
    let mut m = model(&p);
    let root = m.project().root_bin.clone();
    assert_eq!(names(&m, &root), ["b.mov", "a.mov", "c.mov"]);
    m.set_sort(Some(Column::Name), true);
    assert_eq!(names(&m, &root), ["a.mov", "b.mov", "c.mov"]);
    m.set_sort(Some(Column::Duration), false);
    assert_eq!(names(&m, &root), ["a.mov", "b.mov", "c.mov"]);
    m.set_sort(Some(Column::Duration), true);
    assert_eq!(names(&m, &root), ["c.mov", "b.mov", "a.mov"]);
    m.set_sort(None, true);
    assert_eq!(names(&m, &root), ["b.mov", "a.mov", "c.mov"]);
    m.set_search_text("A.M");
    assert_eq!(names(&m, &root), ["a.mov"]);
    assert_eq!(m.project().root_bin.children.len(), 3);
    assert!(m.is_filtering());
}

#[test]
fn unused_and_offline_filters() {
    let (used, free) = (
        media(2, "used.mov", "/x/used.mov", 3840, Time::new(10, 1)),
        media(3, "free.mov", "/x/free.mov", 3840, Time::new(10, 1)),
    );
    let mut p = project_with(vec![used.clone(), free.clone()]);
    p.timelines.push(sequence_using(used.id));
    let mut m = model(&p);
    let root = m.project().root_bin.clone();
    assert!(!m.is_filtering());
    assert!(m.children(&root).iter().any(|c| c.item_ref() == BinItemRef::Media(used.id)));
    m.set_media_filter(MediaFilter::Unused);
    assert_eq!(m.children(&root).iter().map(BinItem::item_ref).collect::<Vec<_>>(), vec![BinItemRef::Media(free.id)]);
    m.refresh_offline();
    m.set_media_filter(MediaFilter::Offline);
    assert_eq!(m.children(&root).len(), 2);
}

#[test]
fn search_keeps_bins_with_matches_and_grouping_makes_headers() {
    let (needle, hay) =
        (media(2, "needle.mov", "/x/n", 3840, Time::new(10, 1)), media(3, "hay.mov", "/x/h", 3840, Time::new(10, 1)));
    let mut p = project_with(vec![needle.clone(), hay]);
    let mut s = session(p.clone());
    let mut m = model(&p);
    let sub = m.new_bin(&mut s, "Sub").expect("sub");
    assert!(m.move_items(&mut s, &[BinItemRef::Media(needle.id)], sub, None));
    p = m.project().clone();
    m.set_search_text("needle");
    let root = p.root_bin.clone();
    assert_eq!(m.children(&root).iter().map(BinItem::item_ref).collect::<Vec<_>>(), vec![BinItemRef::Bin(sub)]);
    assert_eq!(m.children(m.project().bin(sub).expect("sub")).len(), 1);
    m.set_search_text("");
    m.set_grouping(MediaGrouping::Kind);
    let headers = m.children(&root);
    assert!(!headers.is_empty());
    let first = headers[0].item_ref();
    let BinItemRef::Bin(g) = first else { panic!("group header expected") };
    assert!(m.is_group_header(g));
    assert!(m.display_bin(g).is_some());
    assert!(!m.display_name(first).is_empty());
    assert!(m.is_filtering());
}

#[test]
fn offline_flag_follows_the_disk() {
    let here = file!();
    let ok =
        MediaRef::new(id(2), "ok", &std::env::current_exe().expect("exe").to_string_lossy(), MediaFingerprint::new(-1));
    let gone = media(3, "gone", "/nonexistent/gone", 3840, Time::new(10, 1));
    assert!(!here.is_empty());
    let m = model(&project_with(vec![ok.clone(), gone.clone()]));
    assert!(m.is_offline(gone.id));
    assert!(!m.is_offline(ok.id)); // size mismatch: changed, not offline
    assert_eq!(m.health().missing, 1);
}

#[test]
fn pasteboard_ids_round_trip() {
    let refs = [BinItemRef::Media(id(1)), BinItemRef::Bin(id(2)), BinItemRef::Sequence(id(3))];
    assert_eq!(ProjectPanelModel::decode_items(&ProjectPanelModel::encode_items(&refs)), refs.to_vec());
    assert!(ProjectPanelModel::decode_items("garbage").is_empty());
}

#[test]
fn failure_lines() {
    let names: Vec<String> = ["a", "b", "c", "d", "e"].iter().map(|s| s.to_string()).collect();
    assert_eq!(ProjectPanelModel::failure_text(&names), "Could not read: a, b, c and 2 more.");
    let one = [FileReason { file: "x.mov".into(), reason: "empty".into() }];
    assert_eq!(ProjectPanelModel::failure_status(&one, &["x.mov".to_string()]), "x.mov: empty");
    assert_eq!(ProjectPanelModel::canceled_text(1, 10), "Import canceled: 1 of 10 files imported.");
    assert_eq!(ProjectPanelModel::canceled_text(1, 1), "Import canceled: 1 of 1 file imported.");
}

// MARK: columns, drops, menus

#[test]
fn column_layout_keeps_name_first_and_survives_unknown_columns() {
    let mut l = ProjectColumnLayout::defaults();
    assert_eq!(l.visible(), [Column::Name, Column::Duration]);
    l.toggle(Column::Name);
    l.toggle(Column::Codec);
    assert_eq!(l.visible(), [Column::Name, Column::Duration, Column::Codec]);
    l.move_column(Column::Codec, 0);
    assert_eq!(l.visible(), [Column::Name, Column::Codec, Column::Duration]);
    l.set_width(120.0, Column::Codec);
    assert_eq!((l.width(Column::Codec), l.width(Column::Audio), l.user_width(Column::Audio)), (120.0, 100.0, None));
    let json = br#"{"visible":["duration","fromTheFuture","name","duration"],"widths":{"codec":77}}"#;
    let read = ProjectColumnLayout::from_json(json).expect("layout");
    assert_eq!(read.visible(), [Column::Name, Column::Duration]);
    assert_eq!(read.width(Column::Codec), 77.0);
    let mut store = sq_library::library_folder_store::MemorySettings::default();
    l.save(&mut store);
    assert_eq!(ProjectColumnLayout::load(&store), l);
    assert_eq!(
        ProjectColumnLayout::load(&sq_library::library_folder_store::MemorySettings::default()),
        ProjectColumnLayout::defaults()
    );
}

#[test]
fn drops_prefer_internal_items_and_skip_known_files() {
    let known: std::collections::BTreeSet<String> = ["/x/a.mov".to_string()].into();
    let files = [PathBuf::from("/x/a.mov"), PathBuf::from("/x/b.mov")];
    let item = BinItemRef::Media(id(1));
    assert_eq!(ProjectDrop::classify(&[item], &files, &known), ProjectDrop::Move(vec![item]));
    assert_eq!(ProjectDrop::classify(&[], &files, &known), ProjectDrop::ImportFiles(vec![PathBuf::from("/x/b.mov")]));
    assert_eq!(ProjectDrop::classify(&[], &files[..1], &known), ProjectDrop::None);
}

#[test]
fn icons_follow_kind_and_offline() {
    assert_eq!(
        ProjectItemIcon::icon(ProjectItemKind::VideoAudio, false),
        ProjectItemIcon { symbol: "film", badge: Some("volume") }
    );
    assert_eq!(ProjectItemIcon::icon(ProjectItemKind::Bin, true).symbol, "unknown");
    let gone = media(3, "gone", "/nonexistent/gone", 3840, Time::new(10, 1));
    let m = model(&project_with(vec![gone.clone()]));
    assert_eq!(m.icon_of(BinItemRef::Media(gone.id)).symbol, "unknown");
    assert_eq!(m.item_kind(BinItemRef::Media(gone.id)), ProjectItemKind::Video);
}

#[test]
fn menus_follow_the_selection() {
    let picked: Rc<RefCell<Vec<ProjectMenuAction>>> = Rc::default();
    let log = Rc::clone(&picked);
    let run: MenuRun = Rc::new(move |a| log.borrow_mut().push(a));
    let none = |_: &sq_uikit::editor_command::EditorCommand| String::new();
    let empty = ProjectPanelMenus::items(&ProjectMenuContext::new(), &none, Rc::clone(&run));
    let titles: Vec<_> = empty.iter().filter(|r| !r.title.is_empty()).map(|r| r.title.as_str()).collect();
    assert_eq!(titles, ["New Folder", "New Sequence…", "New Color Matte…", "New Adjustment Layer", "Import…", "Find…"]);
    let c = ProjectMenuContext {
        media: vec![id(1)],
        target_count: 1,
        all_media_online: true,
        has_non_bin_target: true,
        any_media_used: true,
        ..ProjectMenuContext::new()
    };
    let rows = ProjectPanelMenus::items(&c, &none, Rc::clone(&run));
    let titles: Vec<_> = rows.iter().map(|r| r.title.as_str()).collect();
    assert!(titles.contains(&"Open in Source") && titles.contains(&"Clear Used Media") && titles.contains(&"Delete"));
    assert_eq!(titles.last(), Some(&"Delete"));
    let delete = rows.last().expect("row");
    if let Some(action) = &delete.action {
        action();
    }
    assert_eq!(*picked.borrow(), vec![ProjectMenuAction::Delete]);
    let labels = ProjectPanelMenus::label_items(
        &ProjectMenuContext { shared_label: Some(LabelColor::Rose), ..c.clone() },
        Rc::clone(&run),
    );
    assert_eq!(labels.len(), 2 + LabelColor::ALL.len());
    assert!(labels.iter().any(|r| r.is_checked && r.title == LabelColor::Rose.display_name()));
    let header = ProjectPanelMenus::header_items(&|col| col == Column::Duration, run);
    assert_eq!(header.len(), Column::ALL.len() - 1 + 2);
    assert!(header.iter().any(|r| r.is_checked && r.title == "Duration"));
}

// MARK: import

struct FakeBackend {
    live: AtomicUsize,
    peak: AtomicUsize,
    fail: Vec<&'static str>,
    unsupported: Vec<&'static str>,
    /// File names imported without sound (codec "ac-3").
    silenced: Vec<&'static str>,
    /// Whether `file_identity` knows files: `copy-of-x` is another path to `x`.
    knows_identity: bool,
}

impl FakeBackend {
    fn new() -> Arc<FakeBackend> {
        Arc::new(FakeBackend {
            live: AtomicUsize::new(0),
            peak: AtomicUsize::new(0),
            fail: vec![],
            unsupported: vec![],
            silenced: vec![],
            knows_identity: false,
        })
    }
}

impl ImportBackend for FakeBackend {
    fn probe(&self, path: &Path) -> Result<MediaRef, ImportError> {
        let now = self.live.fetch_add(1, Ordering::SeqCst) + 1;
        self.peak.fetch_max(now, Ordering::SeqCst);
        self.live.fetch_sub(1, Ordering::SeqCst);
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if self.fail.contains(&name.as_str()) {
            return Err(ImportError::Failed("broken".into()));
        }
        if let Some(c) = self.unsupported.iter().find(|_| name == "hdr.mkv") {
            return Err(ImportError::UnsupportedCodec((*c).into()));
        }
        let n = u128::from_le_bytes({
            let mut b = [0u8; 16];
            for (i, byte) in name.bytes().take(16).enumerate() {
                b[i] = byte;
            }
            b
        });
        Ok(media(n.max(1), &name, &path.to_string_lossy(), 3840, Time::new(10, 1)))
    }

    fn failure_reason(&self, _path: &Path, error: &ImportError) -> Option<String> {
        matches!(error, ImportError::Failed(_)).then(|| "It is broken.".to_string())
    }

    fn file_identity(&self, path: &Path) -> Option<String> {
        let name = path.file_name()?.to_string_lossy().into_owned();
        self.knows_identity.then(|| name.trim_start_matches("copy-of-").to_string())
    }

    fn take_audio_dropped(&self, path: &Path) -> Option<String> {
        let name = path.file_name()?.to_string_lossy().into_owned();
        self.silenced.contains(&name.as_str()).then(|| "ac-3".to_string())
    }
}

struct App {
    panel: ProjectPanelModel,
    session: EditorSession,
}

impl ProjectPanelRoot for App {
    fn panel_parts(&mut self) -> (&mut ProjectPanelModel, &mut EditorSession) {
        (&mut self.panel, &mut self.session)
    }
}

fn rig(rt: &Rt, backend: Arc<dyn ImportBackend>, limit: usize) -> UiRoot<App> {
    let p = project_with(vec![]);
    let mut deps = ProjectPanelDeps::headless();
    deps.backend = backend;
    deps.pool = Arc::clone(&rt.pool);
    deps.probe_limit = limit;
    deps.mono = Arc::new(rt.clock.clone());
    UiRoot::new(App { panel: ProjectPanelModel::new(p.clone(), deps), session: session(p) })
}

fn import(rt: &Rt, root: &UiRoot<App>, files: &[&str]) {
    let h = UiRef::new(root.weak());
    let urls = files.iter().map(PathBuf::from).collect();
    let task = rt.ex.spawn_local(ProjectPanelModel::import_files(h, urls));
    rt.run_until_stalled();
    assert!(task.is_finished());
}

fn panel<R>(root: &UiRoot<App>, f: impl FnOnce(&mut ProjectPanelModel, &mut EditorSession) -> R) -> R {
    root.with(|a| f(&mut a.panel, &mut a.session)).expect("root")
}

#[test]
fn clean_import_is_one_undo_step_with_a_report() {
    let rt = Rt::manual();
    let root = rig(&rt, FakeBackend::new(), 4);
    import(&rt, &root, &["/x/a.mov", "/x/b.mov"]);
    panel(&root, |m, s| {
        assert_eq!(m.project().media.len(), 2);
        assert_eq!(s.undo_step_depth(), 1);
        let r = m.last_import_report().expect("report");
        assert!(r.is_clean() && r.imported == 2);
        assert_eq!(r.summary(), "Imported 2 files.");
        assert_eq!(m.pending_imports(), 0);
        assert_eq!(m.import_total(), 0);
        assert!(m.media_id_for_imported(Path::new("/x/a.mov")).is_some());
        let events = m.take_events();
        assert!(matches!(&events[..], [ProjectPanelEvent::Imported { files, .. }] if files.len() == 2));
    });
    // Already in the project: skipped, one report, no new undo step.
    import(&rt, &root, &["/x/a.mov"]);
    panel(&root, |m, s| {
        assert_eq!(s.undo_step_depth(), 1);
        let r = m.last_import_report().expect("report");
        assert_eq!(r.summary(), "Nothing imported: 1 already in the project.");
        assert_eq!(m.already_in_project(), ["a.mov"]);
        assert!(m.take_events().is_empty());
    });
}

/// The probe stores `C:/x/a.mov`; the file dialog and a drop on Windows give `C:\x\a.mov`. The second import is the same
/// file: reported as already in the project (the status line the Windows VM never showed), not probed again.
#[test]
fn a_windows_spelling_of_a_known_path_is_already_in_the_project() {
    let rt = Rt::manual();
    let root = rig(&rt, FakeBackend::new(), 4);
    import(&rt, &root, &["C:/x/a.mov"]);
    panel(&root, |m, _| {
        m.take_events();
    });
    import(&rt, &root, &["C:\\x\\a.mov"]);
    panel(&root, |m, s| {
        assert_eq!(m.already_in_project().len(), 1, "named as already in the project");
        assert_eq!(s.project().media.len(), 1, "and not added twice");
        assert!(m.take_events().is_empty());
    });
}

#[test]
fn report_lists_failed_and_unsupported_files() {
    let rt = Rt::manual();
    let mut backend = FakeBackend::new();
    if let Some(b) = Arc::get_mut(&mut backend) {
        b.fail = vec!["broken.mov"];
        b.unsupported = vec!["av01"];
    }
    let root = rig(&rt, backend, 4);
    import(&rt, &root, &["/x/ok.mov", "/x/broken.mov", "/x/hdr.mkv"]);
    panel(&root, |m, _| {
        let r = m.last_import_report().expect("report");
        assert_eq!(r.imported, 1);
        assert_eq!(r.failed, vec![ImportReportEntry::new("broken.mov", "It is broken.")]);
        assert_eq!(r.unsupported, vec![ImportReportEntry::new("hdr.mkv", "av01")]);
        assert_eq!(m.import_failures(), ["broken.mov"]);
        assert_eq!(
            ProjectPanelModel::failure_status(m.import_failure_reasons(), m.import_failures()),
            "broken.mov: It is broken."
        );
        let machine = if sq_os::Platform::current() == sq_os::Platform::Mac { "Mac" } else { "computer" };
        assert!(r.summary().contains(&format!("1 uses a codec this {machine} cannot decode")));
        assert!(m.take_events().iter().any(|e| matches!(e, ProjectPanelEvent::Unsupported(u) if u.len() == 1)));
    });
}

#[test]
fn another_path_to_a_file_in_the_project_or_earlier_in_the_batch_is_imported_once() {
    let rt = Rt::manual();
    let mut backend = FakeBackend::new();
    if let Some(b) = Arc::get_mut(&mut backend) {
        b.knows_identity = true;
    }
    let root = rig(&rt, backend, 4);
    import(&rt, &root, &["/x/a.mov", "/y/copy-of-a.mov", "/x/b.mov"]);
    panel(&root, |m, _| {
        assert_eq!(m.project().media.len(), 2, "a.mov once, b.mov once");
        let r = m.last_import_report().expect("report");
        assert_eq!((r.imported, r.duplicates.clone()), (2, vec!["copy-of-a.mov".to_string()]));
    });
    import(&rt, &root, &["/z/copy-of-b.mov"]);
    panel(&root, |m, _| {
        assert_eq!(m.project().media.len(), 2, "b.mov is in the project under another path");
        assert_eq!(m.last_import_report().map(|r| r.duplicates.clone()), Some(vec!["copy-of-b.mov".to_string()]));
    });
}

/// A backend that records every `file_identity` call (on a slow or disconnected NAS each one blocks for seconds).
struct CountingIdentity {
    calls: std::sync::Mutex<Vec<String>>,
}

impl CountingIdentity {
    fn count(&self, path: &str) -> usize {
        self.calls.lock().map(|c| c.iter().filter(|p| p.as_str() == path).count()).unwrap_or(0)
    }
    fn total(&self) -> usize {
        self.calls.lock().map(|c| c.len()).unwrap_or(0)
    }
}

impl ImportBackend for CountingIdentity {
    fn probe(&self, path: &Path) -> Result<MediaRef, ImportError> {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let n = u128::from(name.bytes().fold(7u64, |a, b| a.wrapping_mul(31).wrapping_add(u64::from(b))));
        Ok(media(n.max(1), &name, &path.to_string_lossy(), 3840, Time::new(10, 1)))
    }

    fn file_identity(&self, path: &Path) -> Option<String> {
        if let Ok(mut calls) = self.calls.lock() {
            calls.push(path.to_string_lossy().into_owned());
        }
        path.file_name().map(|n| n.to_string_lossy().trim_start_matches("copy-of-").to_string())
    }
}

/// The disk is read on a worker, never on the UI thread (a stat of a disconnected NAS froze the app at the next import),
/// and a project file is read once, not at every import.
#[test]
fn an_import_reads_file_identities_on_the_worker_once_per_file() {
    let rt = Rt::manual();
    let backend = Arc::new(CountingIdentity { calls: std::sync::Mutex::new(Vec::new()) });
    let root = rig(&rt, Arc::clone(&backend) as Arc<dyn ImportBackend>, 4);
    import(&rt, &root, &["/x/a.mov", "/x/b.mov"]);
    assert_eq!(backend.total(), 2, "the two new files, nothing else in the project yet");

    let h = UiRef::new(root.weak());
    let task = rt.ex.spawn_local(ProjectPanelModel::import_files(
        h,
        vec![PathBuf::from("/y/copy-of-a.mov"), PathBuf::from("/y/c.mov")],
    ));
    rt.ex.poll_frame();
    assert_eq!(backend.total(), 2, "the UI step touched no file: the worker job has not run yet");
    assert!(!task.is_finished());
    rt.run_until_stalled();
    assert!(task.is_finished());
    panel(&root, |m, _| {
        assert_eq!(m.project().media.len(), 3, "a, b, c: copy-of-a is a.mov under another path");
        assert_eq!(m.last_import_report().map(|r| r.duplicates.clone()), Some(vec!["copy-of-a.mov".to_string()]));
    });
    import(&rt, &root, &["/y/d.mov"]);
    // Each file: once as a new file, once as project media the first import after it joined; never again.
    assert_eq!([backend.count("/x/a.mov"), backend.count("/x/b.mov"), backend.count("/y/c.mov")], [2, 2, 2]);
    assert_eq!([backend.count("/y/d.mov"), backend.count("/y/copy-of-a.mov")], [1, 1]);
    import(&rt, &root, &["/y/e.mov"]);
    assert_eq!([backend.count("/x/a.mov"), backend.count("/x/b.mov"), backend.count("/y/c.mov")], [2, 2, 2]);
}

#[test]
fn a_file_imported_without_sound_is_named_in_the_report() {
    let rt = Rt::manual();
    let mut backend = FakeBackend::new();
    if let Some(b) = Arc::get_mut(&mut backend) {
        b.silenced = vec!["talk.mkv"];
    }
    let root = rig(&rt, backend, 4);
    import(&rt, &root, &["/x/talk.mkv", "/x/ok.mov"]);
    panel(&root, |m, _| {
        let r = m.last_import_report().expect("report");
        assert_eq!(r.imported, 2);
        assert_eq!(r.audio_dropped, vec![ImportReportEntry::new("talk.mkv", "ac-3")]);
        assert!(r.summary().contains("1 imported without sound"));
    });
}

#[test]
fn import_probes_are_bounded_and_keep_the_input_order() {
    let rt = Rt::manual();
    let backend = FakeBackend::new();
    let root = rig(&rt, Arc::clone(&backend) as Arc<dyn ImportBackend>, 3);
    let files: Vec<String> = (0..30).map(|i| format!("/x/clip{i}.mov")).collect();
    let refs: Vec<&str> = files.iter().map(String::as_str).collect();
    import(&rt, &root, &refs);
    panel(&root, |m, _| {
        assert_eq!(m.project().media.iter().map(|x| x.path.clone()).collect::<Vec<_>>(), files);
        assert_eq!(m.pending_imports(), 0);
    });
}

#[test]
fn import_goes_to_the_current_bin() {
    let rt = Rt::manual();
    let root = rig(&rt, FakeBackend::new(), 4);
    let bin = panel(&root, |m, s| {
        let bin = m.new_bin(s, "Folder").expect("bin");
        m.set_current_bin(bin);
        bin
    });
    import(&rt, &root, &["/x/a.mov", "/x/b.mov"]);
    panel(&root, |m, s| {
        assert_eq!(s.undo_step_depth(), 2); // the new bin and the import
        assert_eq!(m.project().bin(bin).map(|b| b.media_ids().len()), Some(2));
        assert_eq!(m.project().root_bin.children.len(), 1);
    });
}

#[test]
fn canceled_import_keeps_finished_files_and_skips_the_rest() {
    let rt = Rt::manual();
    let root = rig(&rt, FakeBackend::new(), 1);
    let files: Vec<String> = (0..10).map(|i| format!("/x/clip{i}.mov")).collect();
    let h = UiRef::new(root.weak());
    let task = rt.ex.spawn_local(ProjectPanelModel::import_files(h, files.iter().map(PathBuf::from).collect()));
    // The file identities are read on a worker first; then the first probe is queued. Cancel before it ran.
    rt.ex.poll_frame();
    assert!(rt.pool.step());
    rt.ex.poll_frame();
    panel(&root, |m, _| {
        assert_eq!((m.pending_imports(), m.import_total()), (10, 10));
        m.cancel_import();
    });
    rt.run_until_stalled();
    assert!(task.is_finished());
    panel(&root, |m, _| {
        assert_eq!(m.project().media.len(), 1); // the probe that was already queued lands, the rest is skipped
        assert_eq!(m.import_canceled(), Some((1, 10)));
        assert!(m.last_import_report().is_some_and(|r| r.canceled));
        assert_eq!((m.pending_imports(), m.import_total()), (0, 0));
    });
    import(&rt, &root, &["/x/other.mov"]); // a later import is not canceled
    panel(&root, |m, _| assert!(m.project().media.len() == 2 && m.import_canceled().is_none()));
}

#[test]
fn coalescing_import_fills_the_bin_while_probing_as_one_step() {
    let rt = Rt::manual();
    let root = rig(&rt, FakeBackend::new(), 8);
    panel(&root, |m, _| {
        m.set_coalescing_imports(true);
        m.set_import_commit_interval(Duration::ZERO);
    });
    import(&rt, &root, &["/x/c0.mov", "/x/c1.mov", "/x/c2.mov", "/x/c3.mov"]);
    panel(&root, |m, s| {
        assert_eq!(m.project().media.len(), 4);
        assert_eq!(s.undo_step_depth(), 1); // every landing merged under one key
    });
}

#[test]
fn overlapping_imports_of_one_file_add_it_once() {
    let rt = Rt::manual();
    let root = rig(&rt, FakeBackend::new(), 4);
    let (h1, h2) = (UiRef::new(root.weak()), UiRef::new(root.weak()));
    let one = rt.ex.spawn_local(ProjectPanelModel::import_files(h1, vec![PathBuf::from("/x/a.mov")]));
    let two = rt.ex.spawn_local(ProjectPanelModel::import_files(h2, vec![PathBuf::from("/x/a.mov")]));
    rt.run_until_stalled();
    assert!(one.is_finished() && two.is_finished());
    panel(&root, |m, _| assert_eq!(m.project().media.len(), 1));
}

// MARK: folder sync

fn synced(rt: &Rt, root: &UiRoot<App>, adds: Vec<FolderSyncAdd>, valid: bool) -> i64 {
    let h = UiRef::new(root.weak());
    let task = rt.ex.spawn_local(ProjectPanelModel::import_synced(h, adds, move |_: &mut App| valid));
    rt.run_until_stalled();
    assert!(task.is_finished());
    task.try_take().and_then(Result::ok).expect("finished")
}

fn add(path: &str, bin: &[&str]) -> FolderSyncAdd {
    FolderSyncAdd { path: path.to_string(), bin: bin.iter().map(|b| (*b).to_string()).collect() }
}

#[test]
fn folder_sync_files_land_in_mirrored_bins_without_an_undo_step() {
    let rt = Rt::manual();
    let root = rig(&rt, FakeBackend::new(), 4);
    let n = synced(&rt, &root, vec![add("/p/Film/Day 1/a.mov", &["Day 1"]), add("/p/Film/b.wav", &[])], true);
    assert_eq!(n, 2);
    panel(&root, |m, s| {
        let mut paths: Vec<String> = m.project().media.iter().map(|x| x.path.clone()).collect();
        paths.sort();
        assert_eq!(paths, vec!["/p/Film/Day 1/a.mov", "/p/Film/b.wav"]);
        assert_eq!(s.undo_step_depth(), 0);
        assert_eq!(s.project().media.len(), 2);
        let mut copy = m.project().clone();
        let none = std::collections::BTreeMap::new();
        assert!(copy.bin_id(&["Day 1".to_string()], false, &none, &mut *s.ids).is_some());
    });
    assert_eq!(synced(&rt, &root, vec![add("/p/Film/b.wav", &[])], true), 0);
}

#[test]
fn a_sync_result_is_dropped_when_the_project_changed_during_the_probes() {
    let rt = Rt::manual();
    let root = rig(&rt, FakeBackend::new(), 4);
    assert_eq!(synced(&rt, &root, vec![add("/p/Film/a.mov", &[])], false), 0);
    panel(&root, |m, _| {
        assert!(m.project().media.is_empty());
        assert_eq!(m.remembered_failure_count(), 0);
    });
}

#[test]
fn unreadable_sync_files_are_remembered_by_size_and_date() {
    let rt = Rt::manual();
    let backend = Arc::new(FakeBackend {
        live: AtomicUsize::new(0),
        peak: AtomicUsize::new(0),
        fail: vec!["broken.mov"],
        unsupported: vec![],
        silenced: vec![],
        knows_identity: false,
    });
    let root = rig(&rt, backend, 4);
    let dir = std::env::temp_dir().join(format!("sq-es07-sync-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap_or_default();
    let file = dir.join("broken.mov");
    std::fs::write(&file, [1u8, 2, 3]).unwrap_or_default();
    let path = file.to_string_lossy().into_owned();
    assert_eq!(synced(&rt, &root, vec![add(&path, &[])], true), 0);
    assert_eq!(synced(&rt, &root, vec![add(&path, &[])], true), 0);
    panel(&root, |m, _| assert_eq!(m.remembered_failure_count(), 1));
    let _ = std::fs::remove_dir_all(&dir);
}

// MARK: project folder watcher

fn watched_rig(rt: &Rt, folder: &Path, watch: bool) -> UiRoot<App> {
    let mut p = project_with(vec![]);
    p.media_policy = Some(sq_core_model::MediaPolicy { watch_folder: Some(watch), ..Default::default() });
    let mut deps = ProjectPanelDeps::headless();
    deps.backend = FakeBackend::new();
    deps.pool = Arc::clone(&rt.pool);
    deps.mono = Arc::new(rt.clock.clone());
    let mut s = session(p.clone());
    std::fs::create_dir_all(folder).unwrap_or_default();
    s.save_as(&folder.join("Film.sqproj")).expect("save");
    UiRoot::new(App { panel: ProjectPanelModel::new(p, deps), session: s })
}

/// A fresh project folder `<tmp>/sq-es07-watch-<pid>-<name>/Film`.
fn watch_folder(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("sq-es07-watch-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir.join("Film")
}

/// Writes `bytes` bytes and dates the file `age` seconds ago.
fn media_file(path: &Path, bytes: usize, age: u64) {
    std::fs::create_dir_all(path.parent().unwrap_or(Path::new("/"))).unwrap_or_default();
    std::fs::write(path, vec![7u8; bytes]).unwrap_or_default();
    let file = std::fs::File::options().write(true).open(path).expect("open");
    file.set_modified(std::time::SystemTime::now() - Duration::from_secs(age)).expect("date");
}

fn tick(rt: &Rt, root: &UiRoot<App>, mut watch: FolderWatch) -> (FolderWatch, i64) {
    let h = UiRef::new(root.weak());
    let task = rt.ex.spawn_local(async move {
        let added = watch.sync(&h, std::time::SystemTime::now()).await;
        (watch, added)
    });
    rt.run_until_stalled();
    task.try_take().and_then(Result::ok).expect("finished")
}

fn quick() -> FolderWatch {
    FolderWatch::with_recheck(Duration::from_millis(5))
}

fn media_paths(root: &UiRoot<App>) -> Vec<String> {
    let mut paths = panel(root, |_, s| s.project().media.iter().map(|m| m.path.clone()).collect::<Vec<_>>());
    paths.sort();
    paths
}

#[test]
fn watcher_files_a_new_media_file_in_one_tick_and_skips_exports_and_hidden_items() {
    let (rt, folder) = (Rt::manual(), watch_folder("new"));
    let root = watched_rig(&rt, &folder, true);
    media_file(&folder.join("Day 1/a.mov"), 10, 60);
    media_file(&folder.join("b.wav"), 10, 60);
    media_file(&folder.join("Exports/out.mov"), 10, 60);
    media_file(&folder.join(".hidden/h.mov"), 10, 60);
    media_file(&folder.join("Day 1/.partial.mov"), 10, 60);
    media_file(&folder.join("notes.txt"), 10, 60);
    let (_, added) = tick(&rt, &root, quick());
    assert_eq!(added, 2);
    let want = [folder.join("Day 1/a.mov"), folder.join("b.wav")].map(|p| p.to_string_lossy().into_owned());
    assert_eq!(media_paths(&root), want);
    panel(&root, |_, s| assert_eq!(s.undo_step_depth(), 0));
    let _ = std::fs::remove_dir_all(folder.parent().unwrap_or(&folder));
}

#[test]
fn watcher_waits_for_a_file_that_is_still_being_written() {
    let (rt, folder) = (Rt::manual(), watch_folder("half"));
    let root = watched_rig(&rt, &folder, true);
    let file = folder.join("copy.mov");
    media_file(&file, 10, 0); // written just now
    let (watch, added) = tick(&rt, &root, quick());
    assert_eq!(added, 0, "a file written in the last two seconds waits");
    media_file(&file, 20, 60); // the copy went on (bigger) and then stopped
    let (watch, added) = tick(&rt, &root, watch);
    assert_eq!(added, 0, "a file that changed since the last scan waits one more tick");
    let (_, added) = tick(&rt, &root, watch);
    assert_eq!(added, 1);
    assert_eq!(media_paths(&root), vec![file.to_string_lossy().into_owned()]);
    let _ = std::fs::remove_dir_all(folder.parent().unwrap_or(&folder));
}

#[test]
fn watcher_turns_a_deleted_file_offline() {
    let (rt, folder) = (Rt::manual(), watch_folder("gone"));
    let root = watched_rig(&rt, &folder, true);
    let file = folder.join("a.mov");
    media_file(&file, 10, 60);
    let (watch, added) = tick(&rt, &root, quick());
    assert_eq!(added, 1);
    let id = panel(&root, |m, _| m.project().media[0].id);
    panel(&root, |m, _| assert!(!m.is_offline(id)));
    std::fs::remove_file(&file).unwrap_or_default();
    tick(&rt, &root, watch);
    panel(&root, |m, _| assert!(m.is_offline(id), "the vanished file is offline after one tick"));
    let _ = std::fs::remove_dir_all(folder.parent().unwrap_or(&folder));
}

#[test]
fn watcher_stays_idle_while_the_project_setting_is_off() {
    let (rt, folder) = (Rt::manual(), watch_folder("off"));
    let root = watched_rig(&rt, &folder, false);
    media_file(&folder.join("a.mov"), 10, 60);
    assert_eq!(tick(&rt, &root, quick()).1, 0);
    assert!(media_paths(&root).is_empty());
    let _ = std::fs::remove_dir_all(folder.parent().unwrap_or(&folder));
}

#[test]
fn the_watch_task_ticks_on_the_executor_clock_and_ends_with_the_root() {
    let (rt, folder) = (Rt::manual(), watch_folder("run"));
    let root = watched_rig(&rt, &folder, true);
    media_file(&folder.join("a.mov"), 10, 60);
    let task = rt.ex.spawn_local(FolderWatch::run(UiRef::new(root.weak())));
    rt.run_until_stalled();
    assert!(media_paths(&root).is_empty(), "nothing happens before the first tick");
    rt.advance(TICK);
    assert_eq!(media_paths(&root).len(), 1);
    drop(root);
    rt.advance(TICK);
    assert!(task.is_finished());
    let _ = std::fs::remove_dir_all(folder.parent().unwrap_or(&folder));
}
