//! The Export sheet body without a window: the geometry of its parts (rects) and each settings row writing the model.

use super::*;
use crate::shell_export_items::Row;
use sq_core_time::{Id, Time, TimeRange};
use sq_editor_session::SequenceItem;
use sq_export::core::audio_delivery::AudioDeliveryTarget;
use sq_export::core::encoder_support::{EncoderSupport, Missing, Probe, ProbeKind, ProbeState, caps_of};
use sq_export::core::preset::QualityStep;
use sq_export::core::settings::{CaptionMode, EncoderSpeed, VideoCodec, VideoProfile};
use std::sync::Arc;

fn model(in_out: bool) -> ExportDialogModel {
    let mut item = SequenceItem::new(Id::from_u128(1), "Main", Time::seconds(60));
    if in_out {
        item.in_out = Some(TimeRange::new(Time::seconds(10), Time::seconds(20)));
    }
    ExportDialogModel::new(
        vec![item],
        None,
        ExportDialogModel::system_free_space(),
        Arc::new(|_, _| Err(sq_export::core::error::ExportError::Other("test".into()))),
        Box::new(sq_core_time::SequentialIds::default()),
    )
}

/// A sheet over `model` in a card body of 1000 x 684 (the 740 card minus the 56 footer band), laid out with a 6 pt glyph.
fn sheet_for(m: ExportDialogModel) -> ShellExportSheet {
    let offered = crate::shell_export::ShellExport::presets(&VideoCodec::ALL, true);
    let sheet = ShellExportSheet::new(Rc::new(RefCell::new(m)), offered, VideoCodec::ALL.to_vec(), true, true, 1);
    {
        let mut i = sheet.0.borrow_mut();
        i.frame = CGRect::new(0.0, 0.0, 1000.0, 684.0);
        i.layout_all(&|s, _| s.chars().count() as f64 * 6.0);
    }
    sheet
}

fn at(sheet: &ShellExportSheet, title: &str) -> (usize, usize) {
    let s = sheet.sections();
    let (si, ri, _) = find_row(&s, title).unwrap_or_else(|| panic!("no row {title}"));
    (si, ri)
}

/// Delivers `v` to item `i` of the row `title`.
fn put(sheet: &ShellExportSheet, title: &str, i: usize, v: Val) {
    let (s, r) = at(sheet, title);
    sheet.deliver(Path { s, r, i }, v);
}

#[test]
fn the_card_parts_sit_where_the_mac_sheet_puts_them() {
    let sheet = sheet_for(model(false));
    let [column, preview, scrub, add, preset] = sheet.parts();
    assert_eq!((column.min_x(), column.min_y(), column.width, column.height), (360.0, 52.0, 640.0, 632.0));
    assert_eq!((preview.min_x(), preview.min_y(), preview.width, preview.height), (20.0, 72.0, 320.0, 250.0));
    // From the play button (24 + 8 after the 20 pad) to the 78 wide timecode column, 8 apart; the player row is 24 high.
    assert_eq!(
        (scrub.min_x(), scrub.min_y(), scrub.width, scrub.height),
        (52.0, 332.0, 360.0 - 20.0 - 78.0 - 8.0 - 52.0, 24.0)
    );
    // The header is 52 high; the preset popup (260) and the add button end 16 before the right edge.
    assert_eq!((add.min_x(), add.min_y(), add.width, add.height), (960.0, 15.0, 24.0, 22.0));
    assert_eq!((preset.min_x(), preset.width, preset.min_y()), (960.0 - 10.0 - 260.0, 260.0, 15.0));
}

#[test]
fn the_cards_stack_their_rows_by_height_and_the_opened_details_follow_the_fold_bar() {
    let sheet = sheet_for(model(false));
    {
        let mut i = sheet.0.borrow_mut();
        i.release(Target::Section(MORE_KEY));
        i.layout_all(&|s, _| s.chars().count() as f64 * 6.0);
    }
    let headers = sheet.header_frames();
    let keys: Vec<&str> = headers.iter().map(|h| h.0).collect();
    assert_eq!(keys, ["export.more", "export.video", "export.audio", "export.advanced"]);
    assert!(headers.iter().all(|h| h.1), "bar and headers are open");
    assert_eq!(headers[0].3.height, 32.0, "the fold bar is 32 tall");
    assert!(headers[1..].iter().all(|h| h.3.height == 21.0), "a group title is 13 and sits 8 above its card");
    let video_h: f64 = sheet.sections()[1].rows.iter().map(|r| r.height.unwrap_or(m::ROW_H)).sum();
    assert_eq!(headers[2].3.min_y(), headers[1].3.max_y() + video_h + 18.0, "header, rows, 18 section gap");
    assert_eq!(headers[1].3.min_y(), headers[0].3.max_y() + 18.0);
    let rows = sheet.row_frames();
    assert!(rows.iter().all(|r| r.2.min_x() == 384.0 && r.2.width == 592.0));
    assert!(rows.iter().filter(|r| r.0 == "Profile" || r.0 == "Encoder Speed").all(|r| r.2.height == 38.0));
    sheet.0.borrow_mut().release(Target::Section(MORE_KEY));
}

#[test]
fn controls_end_14_before_the_card_edge_and_popups_are_200_wide() {
    let sheet = sheet_for(model(false));
    let (s, r) = at(&sheet, "Format");
    let f = sheet.item_frames()[&Path { s, r, i: 0 }];
    assert_eq!((f.min_x(), f.max_x(), f.width, f.height), (976.0 - 14.0 - 200.0, 976.0 - 14.0, 200.0, 22.0));
    // A number field with a unit is 84 wide and the unit follows 8 later (fill items share the rest).
    let row = CGRect::new(0.0, 0.0, 539.0, 24.0);
    let sheet2 = sheet_for(model(false));
    let (s2, r2) = at(&sheet2, "Rate Control");
    let items = sheet2.sections()[s2].rows[r2].items.clone();
    let frames = Inner::layout_items(&items, row, None, &|t, _| t.chars().count() as f64 * 6.0);
    assert_eq!(frames.len(), items.len());
    assert!(frames[0].min_x() >= 150.0, "the label column keeps 150");
    assert_eq!(frames.last().map(|f| f.max_x()), Some(539.0 - 14.0), "the group ends at the right edge");
}

#[test]
fn fixed_fit_and_fill_items_share_a_row_like_the_mac_row() {
    use items::{Act, Item, Kind, ScrubSpec, Width};
    let it = |kind, width| Item { kind, width, enabled: true, act: Act::None, rebuild: false };
    let spec = ScrubSpec { value: 1.0, min: 0.0, max: 2.0, step: 1.0, decimals: 0, default: None };
    let row = CGRect::new(0.0, 100.0, 539.0, 24.0);
    let list = [
        it(Kind::Scrub(spec), Width::Fixed(84.0)),
        it(Kind::Unit("Mbit/s".into()), Width::Fit),
        it(Kind::Button("Change".into()), Width::Fit),
        it(Kind::Path("~".into()), Width::Fill),
    ];
    let f = Inner::layout_items(&list, row, None, &|t, _| t.chars().count() as f64 * 6.0);
    assert_eq!((f[0].min_x(), f[0].width), (150.0, 84.0));
    assert_eq!((f[1].min_x(), f[1].width), (150.0 + 84.0 + 8.0, 36.0));
    assert_eq!(f[2].width, 36.0 + 22.0, "a button is its title plus 11 pt each side");
    assert_eq!(f[3].max_x(), 539.0 - 14.0, "the fill item takes what is left, up to 200");
    assert!(f.iter().all(|r| r.height == 22.0 || r.height == 24.0));
    // No room left: a fill item keeps at least 20.
    let narrow = Inner::layout_items(&list[3..], CGRect::new(0.0, 0.0, 90.0, 24.0), None, &|_, _| 0.0);
    assert_eq!(narrow[0].width, 20.0);
}

#[test]
fn every_swift_row_title_is_in_the_sheet() {
    let sheet = sheet_for(model(false));
    let titles: Vec<String> = sheet.sections().iter().flat_map(|s| s.rows.iter().map(|r| r.title.clone())).collect();
    for want in [
        "Format",
        "Codec",
        "Profile",
        "Size",
        "Size Preset",
        "Frame Rate",
        "Rate Control",
        "Quality",
        "Bitrate",
        "Encoder Speed",
        "Color Space",
        "Audio",
        "Sample Rate",
        "Audio Check",
        "Captions",
        "Range",
        "Cover image",
        "Save to",
        "Keyframe Every",
        "B-Frames",
        "Alpha",
        "Bit Depth",
        "Channels",
        "Damaged Frames",
        "HDR to SDR",
    ] {
        assert!(titles.iter().any(|t| t == want), "{want} is missing: {titles:?}");
    }
}

#[test]
fn the_video_rows_write_the_model() {
    let sheet = sheet_for(model(false));
    let m = sheet.model();
    put(&sheet, "Rate Control", 0, Val::Index(1));
    assert_eq!(m.borrow().settings().video.constant_quality(), Some(0.6));
    put(&sheet, "Rate Control", 1, Val::Number(80.0));
    assert_eq!(m.borrow().settings().video.constant_quality(), Some(0.8));
    put(&sheet, "Rate Control", 0, Val::Index(0));
    assert_eq!(m.borrow().settings().video.constant_quality(), None);
    put(&sheet, "Frame Rate", 0, Val::Index(4));
    assert_eq!(m.borrow().fps(), 30.0);
    put(&sheet, "Encoder Speed", 0, Val::Index(2));
    assert_eq!(m.borrow().encoder_speed(), EncoderSpeed::Fast);
    put(&sheet, "Format", 0, Val::Index(1));
    assert_eq!(m.borrow().codec(), VideoCodec::Hevc);
    put(&sheet, "Profile", 0, Val::Index(2));
    assert_eq!(m.borrow().settings().video.profile, VideoProfile::Main10);
    put(&sheet, "Format", 0, Val::Index(0));
    assert_eq!(m.borrow().settings().video.profile, VideoProfile::Automatic, "H.264 has no Main 10");
    put(&sheet, "Bitrate", 1, Val::Number(12.0));
    assert_eq!(m.borrow().bitrate_mbps(), 12.0);
    put(&sheet, "Quality", 0, Val::Index(0));
    assert_eq!(m.borrow().settings().video.quality_step(), Some(sq_export::core::preset::QualityStep::Smaller));
    put(&sheet, "Quality", 0, Val::Index(2));
    assert_eq!(m.borrow().settings().video.quality_step(), Some(sq_export::core::preset::QualityStep::High));
    assert!(m.borrow().settings().video.quality_step().is_some(), "a quality step is applied");
    // Size: a preset size from the details, then the typed fields.
    put(&sheet, "Size Preset", 0, Val::Index(4));
    assert_eq!((m.borrow().width(), m.borrow().height()), (1280, 720));
    put(&sheet, "Size", 0, Val::Number(1001.0));
    put(&sheet, "Size", 2, Val::Number(555.0));
    assert_eq!((m.borrow().width(), m.borrow().height()), (1000, 554), "sizes stay even");
}

#[test]
fn size_swaps_and_the_shape_chips_set_it() {
    let sheet = sheet_for(model(false));
    let m = sheet.model();
    put(&sheet, "Size", 0, Val::Number(1920.0));
    put(&sheet, "Size", 2, Val::Number(1080.0));
    put(&sheet, "Size", 3, Val::Press);
    assert_eq!((m.borrow().width(), m.borrow().height()), (1080, 1920), "the swap trades width and height");
    let (s, r) = at(&sheet, "Size");
    let ratio = &sheet.sections()[s].rows[r].items[4];
    assert!(matches!(&ratio.kind, Kind::Text { text, .. } if text == "9:16"), "{ratio:?}");
    let chips = |sheet: &ShellExportSheet| match &sheet.sections()[s].rows[r + 1].items[0].kind {
        Kind::Segmented { labels, selected, chips: true, .. } => (labels.clone(), *selected),
        k => panic!("{k:?}"),
    };
    assert_eq!(chips(&sheet), (vec!["9:16".into(), "16:9".into(), "1:1".into(), "4:5".into()], 0));
    sheet.deliver(Path { s, r: r + 1, i: 0 }, Val::Index(3));
    assert_eq!((m.borrow().width(), m.borrow().height()), (1080, 1350));
    assert_eq!(chips(&sheet).1, 3);
    put(&sheet, "Size", 0, Val::Number(1000.0));
    assert_eq!(chips(&sheet).1, 4, "a size without a shape chip selects none");
    assert_eq!(items::aspect_text(1920, 1080), "16:9");
    assert_eq!(items::aspect_text(1001 & !1, 7), "1000:7".replace("1000:7", "142.86:1"));
}

#[test]
fn the_essentials_come_first_and_the_technical_rows_fold_under_more_settings() {
    let sheet = sheet_for(model(false));
    let s = sheet.sections();
    assert!(!s[0].detail && s[0].title.is_empty() && s[1..].iter().all(|x| x.detail));
    let titles: Vec<&str> = s[0].rows.iter().map(|r| r.title.as_str()).collect();
    assert_eq!(
        titles,
        ["Size", "", "Quality", "", "Format", "Frame Rate", "Audio", "Captions", "Range", "Save to", "Cover image"]
    );
    let keys: Vec<&str> = sheet.header_frames().iter().map(|h| h.0).collect();
    assert_eq!(keys, ["export.more"], "closed: only the fold bar");
    let rows = sheet.row_frames();
    assert!(!rows.iter().any(|r| r.0 == "Profile" || r.0 == "Keyframe Every"));
    // 20 below the column top the first row; the fold bar sits 22 below the card.
    assert_eq!(rows[0].2.min_y(), 52.0 + 20.0);
    let last = rows.last().expect("rows").2;
    let bar = sheet.header_frames()[0].3;
    assert_eq!((bar.min_y(), bar.height), (last.max_y() + 22.0, 32.0));
    {
        let mut i = sheet.0.borrow_mut();
        i.release(Target::Section("export.more"));
        i.layout_all(&|s, _| s.chars().count() as f64 * 6.0);
        let keys: Vec<&str> = i.header_frames.iter().map(|h| h.0).collect();
        assert_eq!(keys, ["export.more", "export.video", "export.audio", "export.advanced"]);
        assert!(i.row_frames.iter().any(|r| r.0 == "Profile"));
        i.release(Target::Section("export.more"));
    }
}

#[test]
fn the_result_block_and_the_note_sit_above_the_footer_of_the_left_column() {
    let sheet = sheet_for(model(false));
    let i = sheet.0.borrow();
    let b = &i.blocks;
    assert_eq!((b.result.width, b.result.height), (320.0, 18.0 + m::RESULT_H));
    assert!(i.list_frame.max_y() <= b.result.min_y(), "the list stops above the Result block");
    assert!(b.hint.max_y() <= i.frame.max_y());
    assert!(i.model.borrow().estimated_size_text().starts_with("up to "));
}

#[test]
fn the_audio_rows_write_the_model() {
    let sheet = sheet_for(model(false));
    let m = sheet.model();
    put(&sheet, "Sample Rate", 0, Val::Index(2));
    assert_eq!(m.borrow().settings().audio.sample_rate, 96_000);
    put(&sheet, "Bitrate", 0, Val::Index(3));
    let kbps = |m: &SharedModel| m.borrow().settings().audio.bitrate;
    let (si, _) = at(&sheet, "Sample Rate");
    let audio_bitrate = sheet.sections()[si].rows.iter().position(|r| r.title == "Bitrate").expect("AAC bitrate row");
    sheet.deliver(Path { s: si, r: audio_bitrate, i: 0 }, Val::Index(3));
    assert_eq!(kbps(&m), 320_000);
    put(&sheet, "Codec", 0, Val::Index(0));
    let (s, r) = at(&sheet, "Audio");
    // item 0 is the loudness popup, item 1 the switch
    sheet.deliver(Path { s, r, i: 1 }, Val::Bool(false));
    assert!(!m.borrow().settings().audio.enabled);
    sheet.deliver(Path { s, r, i: 1 }, Val::Bool(true));
    sheet.deliver(Path { s, r, i: 0 }, Val::Index(0));
    assert!(m.borrow().settings().audio.loudness.is_none(), "No loudness match turns the normalizing off");
    let hint = |sheet: &ShellExportSheet| {
        let (s, r) = at(sheet, "Audio");
        sheet.sections()[s].rows[r].hint.clone()
    };
    assert_eq!(hint(&sheet), "The loudness stays as it is in the sequence.");
    sheet.deliver(Path { s, r, i: 0 }, Val::Index(3));
    assert_eq!(
        m.borrow().settings().audio.loudness,
        Some(AudioDeliveryTarget::ALL[2].normalization()),
        "a delivery target sets its loudness"
    );
    assert_eq!(hint(&sheet), "Loudness is matched for the platform.");
    sheet.deliver(Path { s, r, i: 1 }, Val::Bool(false));
    assert_eq!(hint(&sheet), "Audio is off: the file exports without sound.");
    sheet.deliver(Path { s, r, i: 1 }, Val::Bool(true));
    // The Audio row's delivery target set a loudness, so the Normalize row (target scrub, unit, preset popup) shows now.
    assert!(m.borrow().normalize_loudness());
    put(&sheet, "Normalize", 0, Val::Number(-16.0));
    assert_eq!(m.borrow().settings().audio.loudness.map(|l| l.target_lufs), Some(-16.0));
    put(&sheet, "Normalize", 2, Val::Index(1));
    assert!(m.borrow().delivery_target_index().is_some(), "a delivery target sets the loudness");
    put(&sheet, "True Peak Max", 0, Val::Number(-2.0));
    assert_eq!(m.borrow().settings().audio.loudness.map(|l| l.true_peak_ceiling_db), Some(-2.0));
    put(&sheet, "Channels", 0, Val::Index(0));
    assert_eq!(m.borrow().settings().audio.channels, 1);
}

#[test]
fn the_caption_range_cover_and_output_rows_write_the_model() {
    let sheet = sheet_for(model(true));
    let m = sheet.model();
    put(&sheet, "Captions", 0, Val::Index(2));
    assert_eq!(m.borrow().captions(), CaptionMode::SidecarSrt);
    put(&sheet, "Captions", 0, Val::Index(3));
    assert_eq!(m.borrow().captions(), CaptionMode::SidecarVtt);
    assert_eq!(m.borrow().range_mode(), 1, "an In/Out sequence starts on In to Out");
    put(&sheet, "Range", 0, Val::Index(3));
    assert_eq!(m.borrow().range_mode(), 2, "the fourth segment is Custom");
    put(&sheet, "Start", 0, Val::Number(5.0));
    put(&sheet, "End", 0, Val::Number(8.0));
    let r = m.borrow().range_seconds();
    assert_eq!((r.start, r.end), (5.0, 8.0));
    put(&sheet, "Range", 0, Val::Index(0));
    assert_eq!(m.borrow().range_mode(), 0);
    put(&sheet, "Cover image", 0, Val::Bool(true));
    assert!(m.borrow().cover_image().is_some());
    put(&sheet, "Cover image", 0, Val::Index(1));
    assert_eq!(m.borrow().cover_image(), Some(sq_export::core::settings::CoverImageFormat::Jpg));
    put(&sheet, "Save to", 0, Val::Text("Cut".into()));
    assert_eq!(m.borrow().file_name(), "Cut");
}

#[test]
fn the_advanced_rows_write_the_model() {
    let sheet = sheet_for(model(false));
    let m = sheet.model();
    put(&sheet, "Keyframe Every", 0, Val::Number(48.0));
    assert_eq!(m.borrow().settings().video.keyframe_interval, 48);
    put(&sheet, "B-Frames", 0, Val::Bool(false));
    assert!(!m.borrow().settings().video.allows_frame_reordering);
    put(&sheet, "Damaged Frames", 0, Val::Bool(true));
    assert!(m.borrow().continue_on_damaged_frames());
    put(&sheet, "HDR to SDR", 0, Val::Bool(true));
    assert!(m.borrow().settings().hdr_to_sdr.is_some());
    put(&sheet, "HDR Exposure", 0, Val::Number(1.5));
    assert_eq!(m.borrow().settings().hdr_to_sdr.map(|h| h.exposure_stops), Some(1.5));
    put(&sheet, "HDR Gamut", 0, Val::Bool(false));
    assert_eq!(m.borrow().settings().hdr_to_sdr.map(|h| h.compresses_gamut), Some(false));
    // The HEVC color space rows: HLG, a peak brightness, back to Rec. 709.
    put(&sheet, "Format", 0, Val::Index(1));
    put(&sheet, "Color Space", 0, Val::Index(2));
    assert_eq!(m.borrow().settings().hdr_delivery.map(|h| h.transfer), Some(sq_export::core::hdr::HdrTransfer::Pq));
    put(&sheet, "Peak Brightness", 0, Val::Number(4000.0));
    assert_eq!(m.borrow().settings().hdr_delivery.map(|h| h.peak_nits), Some(4000.0));
    put(&sheet, "Color Space", 0, Val::Index(0));
    assert!(m.borrow().settings().hdr_delivery.is_none());
    // Alpha needs ProRes 4444.
    put(&sheet, "Format", 0, Val::Index(6));
    put(&sheet, "Alpha", 0, Val::Bool(true));
    assert!(m.borrow().settings().video.preserves_alpha);
}

#[test]
fn the_flow_only_buttons_leave_as_events_and_the_header_buttons_edit_the_model() {
    let sheet = sheet_for(model(false));
    put(&sheet, "Audio Check", 0, Val::Press);
    put(&sheet, "Save to", 2, Val::Press);
    let events: Vec<String> = sheet.0.borrow_mut().changes.drain(..).map(|c| c.0).collect();
    assert!(events.contains(&"audio_check".to_string()) && events.contains(&"folder".to_string()), "{events:?}");
    let mut i = sheet.0.borrow_mut();
    assert_eq!(i.model.borrow().job_count(), 1);
    i.release(Target::Add);
    assert_eq!(i.model.borrow().job_count(), 2, "the add button adds a format");
    let id = i.model.borrow().output_rows()[0].id;
    i.release(Target::OutputCheck(id));
    assert_eq!(i.model.borrow().job_count(), 1, "a list check unticks its output");
    i.release(Target::Section(MORE_KEY));
    i.release(Target::Section("export.advanced"));
    i.layout_all(&|s, _| s.chars().count() as f64 * 6.0);
    assert!(!i.row_frames.iter().any(|r| r.0 == "Keyframe Every"), "a clicked header closes its section");
    i.release(Target::Section("export.advanced"));
    i.layout_all(&|s, _| s.chars().count() as f64 * 6.0);
    assert!(i.row_frames.iter().any(|r| r.0 == "Keyframe Every"), "and opens it again");
    i.release(Target::Section(MORE_KEY));
}

#[test]
fn a_long_note_wraps_into_lines_that_fit_and_loses_no_word() {
    let note = "Hardware encoder; it falls back to software when the Mac has none for this size.\nSecond note.";
    // 7 points per character stands in for the real text width.
    let measure = |t: &str| t.chars().count() as f64 * 7.0;
    let lines = super::wrap_lines(note, 330.0, &measure);
    assert!(lines.len() >= 3, "{lines:?}");
    assert!(lines.iter().all(|l| measure(l) <= 330.0), "{lines:?}");
    assert_eq!(lines.join(" "), note.replace('\n', " "));
    assert_eq!(super::wrap_lines("", 330.0, &measure), Vec::<String>::new());
}

#[test]
fn the_result_target_uses_the_platforms_separators_throughout() {
    use std::path::{MAIN_SEPARATOR as S, Path};
    let home = Path::new("home");
    let dir = Path::new("home").join("sq-test").join("Exports");
    let want = format!("~{S}sq-test{S}Exports{S}Sequence 01.mp4");
    assert_eq!(Inner::result_target(&dir, "Sequence 01.mp4", home), want);
    assert!(!want.contains(if S == '/' { '\\' } else { '/' }), "one kind of separator: {want}");
    let outside = Path::new("elsewhere").join("Exports");
    assert_eq!(Inner::result_target(&outside, "a.mp4", home), format!("elsewhere{S}Exports{S}a.mp4"));
    assert_eq!(Inner::result_target(Path::new(""), "a.mp4", home), "a.mp4");
}

#[test]
fn a_long_result_target_keeps_the_word_the_start_and_the_file_name() {
    let root =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
    let atlas = sq_draw::GlyphAtlas::inter(&root).expect("bundled Inter loads");
    let c = Canvas::with_size(600.0, 200.0, Some(&atlas), 1.0);
    let width_of = |s: &str| c.size_of(s, m::BODY, 0).width;
    let target = "~/Movies/Client Work/Spring Campaign/Final Versions/Sequence 01.mp4";
    // Just wide enough for the start and the file name: the case that used to collapse to "to…".
    let narrow = width_of("to ~/\u{2026}/Sequence 01.mp4") + 1.0;
    assert_eq!(Inner::result_target_line(&c, target, narrow), "to ~/\u{2026}/Sequence 01.mp4");
    // A long path without a space has no word boundary to cut at.
    let spaceless = "/private/var/folders/zz/abcdefghijklmnop/T/exports/Sequence-01.mp4";
    let line = Inner::result_target_line(&c, spaceless, 190.0);
    assert!(line.starts_with("to /private/") && line.ends_with("/Sequence-01.mp4"), "{line}");
    assert!(width_of(&line) <= 190.0, "{line}");
    assert_eq!(Inner::result_target_line(&c, "~/Movies/a.mp4", 400.0), "to ~/Movies/a.mp4");
}

#[test]
fn the_result_target_shows_the_home_folder_as_a_tilde_on_every_system() {
    use std::path::Path;
    let dir = Path::new("/Users/anna/Movies");
    let line = Inner::result_target(dir, "Sequence 01.mp4", Path::new("/Users/anna"));
    assert_eq!(line, if cfg!(windows) { "\\Users\\paul\\Movies\\Sequence 01.mp4" } else { "~/Movies/Sequence 01.mp4" });
}

#[test]
fn the_range_segments_run_entire_in_out_selected_custom() {
    use crate::shell_export_items::{RANGE_SEGMENTS, range_mode_of_segment, range_segment};
    assert_eq!(RANGE_SEGMENTS, ["Entire", "In to Out", "Selected", "Custom"]);
    // Model modes: 0 Entire, 1 In to Out, 2 Custom, 3 Selected.
    assert_eq!(range_segment(2), 3, "Custom shows last");
    assert_eq!(range_segment(3), 2, "Selected shows third");
    for mode in 0..4 {
        assert_eq!(range_mode_of_segment(range_segment(mode)), mode);
    }
}

#[test]
fn a_closed_more_settings_bar_stays_visible_when_the_rows_overflow_the_column() {
    let sheet = sheet_for(model(false));
    {
        let mut i = sheet.0.borrow_mut();
        i.frame = CGRect::new(0.0, 0.0, 1000.0, 400.0);
        i.layout_all(&|s, _| s.chars().count() as f64 * 6.0);
        let col = i.column_frame();
        let bar = i.header_frames.iter().find(|h| h.0 == MORE_KEY).expect("the fold bar").3;
        assert!(bar.max_y() <= col.max_y() - 16.0 + 0.1 && bar.min_y() >= col.min_y(), "the bar sits in the column");
        // Scrolled to the end, the last row still ends above the bar.
        i.scroll = 1000.0;
        i.layout_all(&|s, _| s.chars().count() as f64 * 6.0);
        let last = i.row_frames.last().expect("rows").2;
        let bar = i.header_frames.iter().find(|h| h.0 == MORE_KEY).expect("bar").3;
        assert!(last.max_y() <= bar.min_y(), "no row under the pinned bar");
    }
}

/// Every settings control stays inside the sheet, at the smallest window (640x400) and a large one (1440x900); the sheet
/// card is the window width and the window height minus the 56 footer band.
#[test]
fn every_export_control_is_inside_the_sheet_at_640_by_400_and_1440_by_900() {
    for (w, h) in [(640.0, 344.0), (1440.0, 844.0)] {
        let sheet = sheet_for(model(false));
        {
            let mut i = sheet.0.borrow_mut();
            i.release(Target::Section(MORE_KEY));
            i.frame = CGRect::new(0.0, 0.0, w, h);
            i.layout_all(&|s, _| s.chars().count() as f64 * 6.0);
        }
        let i = sheet.0.borrow();
        let col = i.column_frame();
        assert!(i.item_frames.len() > 10, "{} items", i.item_frames.len());
        for (p, f) in &i.item_frames {
            assert!(
                f.min_x() >= col.min_x() && f.max_x() <= col.max_x(),
                "{w}x{h}: item {p:?} ({t}) {f:?} leaves the settings column {col:?}",
                t = i.sections[p.s].rows[p.r].title
            );
        }
        for (name, f) in [
            ("preview", i.preview_frame()),
            ("scrub", i.scrub_frame()),
            ("add", i.add_frame()),
            ("preset", i.preset_frame()),
        ] {
            assert!(f.width > 0.0 && f.min_x() >= 0.0 && f.max_x() <= w, "{w}x{h}: {name} {f:?} leaves the sheet");
        }
        for (_, _, r) in &i.row_frames {
            assert!(r.max_x() <= w, "{w}x{h}: row {r:?}");
        }
    }
}

/// At 640 x 400 the "Size" hint is wrapped whole (never cut with an ellipsis) and the row grows for it; in a big window the
/// hint stays beside the title and the row keeps its height.
#[test]
fn a_row_hint_is_never_cut_and_the_row_grows_at_640_by_400() {
    let text = "Type a size or pick a shape. The picture is scaled to fit.";
    let measure = |s: &str| s.chars().count() as f64 * 6.0;
    for (w, h, stacked) in [(640.0, 344.0, true), (1440.0, 844.0, false)] {
        let sheet = sheet_for(model(false));
        let mut i = sheet.0.borrow_mut();
        i.frame = CGRect::new(0.0, 0.0, w, h);
        i.layout_all(&|s, _| s.chars().count() as f64 * 6.0);
        let k = i.row_frames.iter().position(|r| r.0 == "Size").expect("Size row");
        let note = &i.row_notes[k];
        assert_eq!(note.hint_lines.join(" "), text, "{w}: hint cut: {:?}", note.hint_lines);
        assert!(note.hint_lines.iter().all(|l| measure(l) <= note.hint_w), "{w}: a line is wider than {}", note.hint_w);
        let row = i.row_frames[k].2;
        assert_eq!(note.hint_w > note.label_w, stacked, "{w}: stacked {note:?}");
        let last = row.min_y() + note.hint_top + note.hint_lines.len() as f64 * m::HINT_LINE_H;
        if stacked {
            assert!(last <= row.max_y() + 0.5, "{w}: hint ends {last} below the row {row:?}");
        } else {
            assert!((row.height - 39.0).abs() < 0.5, "{w}: row {row:?}");
        }
    }
}

/// At 640 x 400 the output row shows the whole title ("What to export" list); in a big window the title and the size sit
/// beside each other as before.
#[test]
fn an_output_row_shows_its_whole_title_at_640_by_400() {
    let (title_w, size_w) = (11.0 * 6.5, 11.0 * 6.5);
    for (w, h, stacked) in [(640.0, 344.0, true), (1440.0, 844.0, false)] {
        let sheet = sheet_for(model(false));
        let mut i = sheet.0.borrow_mut();
        i.frame = CGRect::new(0.0, 0.0, w, h);
        i.layout_all(&|s, _| s.chars().count() as f64 * 6.0);
        let lf = i.list_frame;
        let row = CGRect::new(lf.min_x(), lf.min_y() + 4.0, lf.width, 32.0);
        let r = output_row_rects(row, title_w, size_w);
        assert!(r.title.width >= title_w, "{w}: title box {:?} cuts a {title_w} title", r.title);
        assert_eq!(r.stacked, stacked, "{w}: {:?} {:?}", r.title, r.size);
        assert!(r.title.max_x() <= row.max_x() && r.size.max_x() <= row.max_x(), "{w}");
        if stacked {
            assert!(r.title.max_y() <= r.size.min_y() + 0.5 && r.size.max_y() <= row.max_y(), "{w}");
        } else {
            assert!(r.title.max_x() <= r.size.min_x(), "{w}");
        }
    }
}

/// At 640 x 400 a 200-character sequence name stays in its column, which ends before the "Preset" label.
#[test]
fn a_long_sequence_name_stays_left_of_the_preset_label_at_640_by_400() {
    for (w, h) in [(640.0, 344.0), (1440.0, 844.0)] {
        let sheet = sheet_for(model(false));
        let mut i = sheet.0.borrow_mut();
        i.frame = CGRect::new(0.0, 0.0, w, h);
        i.layout_all(&|s, _| s.chars().count() as f64 * 6.0);
        let col = i.seq_name_frame();
        let label_left = i.preset_frame().min_x() - 8.0 - 44.0;
        assert!(col.width > 0.0 && col.width <= 260.0 && col.max_x() <= label_left, "{w}: {col:?} vs {label_left}");
        let name = "Aleksandra_Wisniewska-Kowalczyk_Interview_Take_".repeat(5);
        let shown = sq_draw::glyph_atlas::fit_with_ellipsis(&name, |s| s.chars().count() as f64 * 6.0 <= col.width)
            .unwrap_or_default();
        assert!(shown.ends_with('\u{2026}') && shown.chars().count() as f64 * 6.0 <= col.width, "{shown}");
    }
}

/// The closed "More settings" bar at 640 x 400 shows a summary that fits, not a sentence cut mid-way.
#[test]
fn the_more_settings_summary_is_whole_at_640_by_400() {
    let measure = |s: &str| s.chars().count() as f64 * 5.5;
    let sheet = sheet_for(model(false));
    let mut i = sheet.0.borrow_mut();
    i.frame = CGRect::new(0.0, 0.0, 640.0, 344.0);
    i.layout_all(&|s, _| s.chars().count() as f64 * 6.0);
    let bar = i.header_frames.iter().find(|h| h.0 == MORE_KEY).expect("bar").3;
    let room = bar.width - 30.0 - 85.0 - 12.0 - m::TRAILING;
    let narrow = more_summary(12, room, &measure);
    assert!(measure(&narrow) <= room && narrow.contains("12"), "{narrow:?} in {room}");
    assert!(!narrow.ends_with('\u{2026}'));
    assert!(more_summary(12, 900.0, &measure).starts_with("Video and audio details"), "wide keeps the sentence");
}

fn rows_with(m: &ExportDialogModel, support: Option<EncoderSupport>) -> Vec<Section> {
    Rows {
        model: m,
        codecs: &VideoCodec::ALL,
        custom_size: false,
        home: None,
        can_copy: false,
        can_choose_folder: false,
        support,
    }
    .sections()
}

fn row_of<'a>(sections: &'a [Section], title: &str) -> &'a Row {
    let (s, r, _) = find_row(sections, title).unwrap_or_else(|| panic!("no row {title}"));
    &sections[s].rows[r]
}

#[test]
fn an_encoder_without_b_frames_shows_the_option_off_and_not_available() {
    let m = model(false);
    let lacking =
        |missing: Vec<Missing>| Some(EncoderSupport { label: "OpenH264 (software)".into(), hardware: false, missing });
    let free = rows_with(&m, lacking(Vec::new()));
    let row = row_of(&free, "B-Frames");
    assert!(row.items[0].enabled && row.hint.is_empty());
    assert!(matches!(row.items[0].kind, Kind::Check { on: true, .. }), "the preset allows B-frames");
    let lost = rows_with(&m, lacking(vec![Missing::BFrames]));
    let row = row_of(&lost, "B-Frames");
    assert!(!row.items[0].enabled, "the box cannot be switched on");
    assert!(matches!(row.items[0].kind, Kind::Check { on: false, .. }), "and does not claim to be on");
    assert_eq!(row.hint, "Not available on this computer.");
    // Before the probe answered nothing is restricted.
    assert!(row_of(&rows_with(&m, None), "B-Frames").items[0].enabled);
}

#[test]
fn main_10_and_constant_bitrate_say_when_the_encoder_cannot_do_them() {
    let mut m = model(false);
    m.edit(|s| {
        s.video.codec = VideoCodec::Hevc;
        s.video.profile = VideoProfile::Main10;
        s.video.set_bitrate_kind(sq_export::core::settings::BitrateKind::Cbr);
    });
    let lost = EncoderSupport {
        label: "Kvazaar (software)".into(),
        hardware: false,
        missing: vec![Missing::TenBit, Missing::ConstantBitrate],
    };
    let sections = rows_with(&m, Some(lost));
    let profile = row_of(&sections, "Profile");
    assert!(profile.hint.contains("will not run"), "the choice is refused, never turned into 8-bit: {}", profile.hint);
    assert!(
        matches!(&profile.items[0].kind, Kind::Popup { disabled, titles, .. } if disabled == &[2] && titles[2] == "Main 10"),
        "{:?}",
        profile.items[0].kind
    );
    assert!(row_of(&sections, "Bitrate").hint.contains("Constant bitrate is not available"));
    let depth = row_of(&sections, "Bit Depth");
    assert!(matches!(&depth.items[0].kind, Kind::Text { text, .. } if text == "10-bit"), "{:?}", depth.items[0].kind);
    let fine =
        rows_with(&m, Some(EncoderSupport { label: "VA-API (hardware)".into(), hardware: true, missing: Vec::new() }));
    assert!(row_of(&fine, "Profile").hint.is_empty() && row_of(&fine, "Bitrate").hint.is_empty());
    assert!(matches!(&row_of(&fine, "Profile").items[0].kind, Kind::Popup { disabled, .. } if disabled.is_empty()));
    assert!(matches!(&row_of(&fine, "Bit Depth").items[0].kind, Kind::Text { text, .. } if text == "10-bit"));
}

/// The Windows VM: the probe of 10-bit HEVC with hardware off found no encoder, hardware on found one.
fn vm_probe(kind: ProbeKind) -> ProbeState {
    if kind.hevc && kind.ten_bit && !kind.hardware {
        ProbeState::NoEncoder
    } else {
        ProbeState::Found(Probe { name: "hevc_mf".into(), caps: caps_of("hevc_mf") })
    }
}

#[test]
fn main_10_without_hardware_and_without_a_10_bit_encoder_is_not_available_and_the_export_refuses() {
    let mut m = model(false);
    m.set_probe_state(vm_probe);
    m.edit(|s| {
        s.video.codec = VideoCodec::Hevc;
        s.video.profile = VideoProfile::Main10;
        s.video.hardware_encoding = false;
    });
    let sections = rows_with(&m, m.encoder_support());
    let profile = row_of(&sections, "Profile");
    assert!(
        profile.hint.contains("Main 10 is not available") && profile.hint.contains("will not run"),
        "{}",
        profile.hint
    );
    assert!(
        matches!(&profile.items[0].kind, Kind::Popup { disabled, titles, .. } if disabled == &[2] && titles[2] == "Main 10"),
        "{:?}",
        profile.items[0].kind
    );
    assert!(!m.can_export(), "the Export button is off");
    let message = m.validation_messages().join(" ");
    assert!(message.contains("no 10-bit HEVC") && message.contains("Turn on hardware encoding"), "{message}");
    // Hardware encoding on: the same Main 10 is available and the export runs.
    m.edit(|s| s.video.hardware_encoding = true);
    let sections = rows_with(&m, m.encoder_support());
    let profile = row_of(&sections, "Profile");
    assert!(profile.hint.is_empty());
    assert!(matches!(&profile.items[0].kind, Kind::Popup { disabled, .. } if disabled.is_empty()));
    assert!(m.validation_messages().iter().all(|v| !v.contains("encoder")), "{:?}", m.validation_messages());
}

#[test]
fn an_h264_profile_the_encoder_cannot_set_says_so_on_the_profile_row() {
    let mut m = model(false);
    m.edit(|s| {
        s.video.codec = VideoCodec::H264;
        s.video.profile = VideoProfile::High;
    });
    let lost =
        EncoderSupport { label: "MPEG-4 Part 2 (software)".into(), hardware: false, missing: vec![Missing::Profile] };
    assert!(row_of(&rows_with(&m, Some(lost)), "Profile").hint.contains("not available on this computer"));
    let fine = EncoderSupport { label: "x264 (software)".into(), hardware: false, missing: Vec::new() };
    assert!(row_of(&rows_with(&m, Some(fine)), "Profile").hint.is_empty());
}

#[test]
fn a_format_without_any_encoder_is_shown_not_available_and_greyed_out() {
    let mut m = model(false);
    m.edit(|s| s.video.codec = VideoCodec::Hevc);
    let none = EncoderSupport::none(m.settings());
    let sections = rows_with(&m, Some(none));
    let format = row_of(&sections, "Format");
    assert_eq!(format.hint, "Not available on this computer.");
    assert!(matches!(&format.items[0].kind, Kind::Popup { disabled, selected, .. } if disabled == &[*selected]));
    // With an encoder, or before the probe answered, nothing is greyed out.
    for support in [None, Some(EncoderSupport { label: "Kvazaar (software)".into(), hardware: false, missing: vec![] })]
    {
        let format = row_of(&rows_with(&m, support), "Format").clone();
        assert!(format.hint.is_empty());
        assert!(matches!(&format.items[0].kind, Kind::Popup { disabled, .. } if disabled.is_empty()));
    }
}

/// The Mbit/s line under the Quality segments.
fn quality_mbps_text(sheet: &ShellExportSheet) -> String {
    let s = sheet.sections();
    let (si, ri, _) = find_row(&s, "Quality").unwrap_or_else(|| panic!("no Quality row"));
    match &s[si].rows[ri + 1].items[0].kind {
        Kind::Text { text, .. } => text.clone(),
        other => panic!("the line under Quality is not text: {other:?}"),
    }
}

/// A 1080p30 sequence on a platform preset: each quality step shows its own bitrate with the decimal point (5.6, not 56),
/// and the step keeps its place in the three segments. On purpose unlike the Mac sheet, a step keeps
/// the chosen preset: only a value typed by hand turns it into "Custom".
#[test]
fn a_quality_step_sets_the_bitrate_with_its_decimal_point() {
    let mut m = model(false);
    m.set_preset_id("youtube1080");
    assert_eq!((m.width(), m.height(), m.fps()), (1920, 1080, 30.0));
    let sheet = sheet_for(m);
    assert_eq!(quality_mbps_text(&sheet), "12 Mbit/s", "the preset's own bitrate");
    for (index, step, mbps_text, bits) in [
        (0, QualityStep::Smaller, "5.6 Mbit/s", 5_598_720),
        (1, QualityStep::Standard, "11.2 Mbit/s", 11_197_440),
        (2, QualityStep::High, "21.8 Mbit/s", 21_772_800),
    ] {
        put(&sheet, "Quality", 0, Val::Index(index));
        let m = sheet.model();
        assert_eq!(m.borrow().settings().video.quality_step(), Some(step));
        assert_eq!(m.borrow().settings().video.bitrate.average_bits_per_second(), bits);
        assert_eq!(quality_mbps_text(&sheet), mbps_text);
        assert_eq!(m.borrow().shown_preset_id(), "youtube1080", "a quality step keeps the preset");
    }
}

/// Smaller, then Format HEVC and back to H.264: the lit step stays "Smaller" and the Mbit/s beside it is Smaller's rate for
/// that format (the sheet lit "Standard" next to the old 5.6 Mbit/s before; checker row Export).
#[test]
fn a_format_change_keeps_the_quality_step_and_gives_it_the_new_rate() {
    let mut m = model(false);
    m.set_preset_id("youtube1080");
    let sheet = sheet_for(m);
    let lit = || sheet.model().borrow().quality_step();
    put(&sheet, "Quality", 0, Val::Index(0));
    assert_eq!(quality_mbps_text(&sheet), "5.6 Mbit/s");
    put(&sheet, "Format", 0, Val::Index(1));
    assert_eq!(sheet.model().borrow().codec(), VideoCodec::Hevc);
    assert_eq!((lit(), quality_mbps_text(&sheet)), (Some(QualityStep::Smaller), "3.4 Mbit/s".to_string()));
    put(&sheet, "Format", 0, Val::Index(0));
    assert_eq!(sheet.model().borrow().codec(), VideoCodec::H264);
    assert_eq!((lit(), quality_mbps_text(&sheet)), (Some(QualityStep::Smaller), "5.6 Mbit/s".to_string()));
}

/// After a quality step the preset still stands; the next hand-typed bitrate is what makes it "Custom".
#[test]
fn a_typed_bitrate_after_a_quality_step_turns_the_preset_into_custom() {
    let mut m = model(false);
    m.set_preset_id("youtube1080");
    let sheet = sheet_for(m);
    put(&sheet, "Quality", 0, Val::Index(0));
    assert_eq!(sheet.model().borrow().shown_preset_id(), "youtube1080");
    put(&sheet, "Bitrate", 1, Val::Number(9.0));
    let m = sheet.model();
    assert_eq!(m.borrow().bitrate_mbps(), 9.0);
    assert_eq!(m.borrow().shown_preset_id(), ExportDialogModel::CUSTOM_PRESET_ID);
}

/// The text of the "In / Out" row, `None` when the sheet has no such row.
fn in_out_text(m: &ExportDialogModel) -> Option<String> {
    let sections = rows_with(m, None);
    find_row(&sections, "In / Out")?;
    match &row_of(&sections, "In / Out").items[0].kind {
        items::Kind::Text { text, .. } => Some(text.clone()),
        _ => None,
    }
}

#[test]
fn the_in_out_row_shows_the_range_the_export_covers_for_the_picked_mode() {
    // A stray one-frame Out at 0 (the sequence is 60 s): Entire must read the whole sequence, never the stray mark.
    let mut item = SequenceItem::new(Id::from_u128(1), "Main", Time::seconds(60));
    item.in_out = Some(TimeRange::new(Time::ZERO, Time::new(1, 30)));
    let mut m = ExportDialogModel::new(
        vec![item],
        None,
        ExportDialogModel::system_free_space(),
        Arc::new(|_, _| Err(sq_export::core::error::ExportError::Other("test".into()))),
        Box::new(sq_core_time::SequentialIds::default()),
    );
    assert_eq!(m.range_mode(), 0, "a one-frame mark starts on Entire");
    let fd = m.settings().video.frame_duration;
    let tc = |t| sq_export::core::error::ExportDecodeError::timecode(t, fd);
    assert_eq!(in_out_text(&m), Some(format!("{} \u{2013} {}", tc(Time::ZERO), tc(Time::seconds(60)))));
    m.set_range_mode(1);
    assert_eq!(in_out_text(&m), Some(format!("{} \u{2013} {}", tc(Time::ZERO), tc(Time::new(1, 30)))));
    m.set_range_mode(0);
    assert_eq!(in_out_text(&m), Some(format!("{} \u{2013} {}", tc(Time::ZERO), tc(Time::seconds(60)))));
    // Without marks the row stays away.
    assert_eq!(in_out_text(&model(false)), None);
    // A real In/Out shows its marks in In to Out and the full length in Entire.
    let mut m = model(true);
    assert_eq!(m.range_mode(), 1);
    assert_eq!(in_out_text(&m), Some(format!("{} \u{2013} {}", tc(Time::seconds(10)), tc(Time::seconds(30)))));
    m.set_range_mode(0);
    assert_eq!(in_out_text(&m), Some(format!("{} \u{2013} {}", tc(Time::ZERO), tc(Time::seconds(60)))));
}
