//! Tests of the export dialog model, preflight report and quick export (Swift: ExportDialogFormatsTests,
//! ExportEncoderSpeedModelTests, QuickExportTests, ExportPreflightReportTests; the model tests below add the
//! range, bitrate, output-list and cut-down rules those suites cover through the sheet).

use std::path::{Path, PathBuf};
use std::sync::Arc;

use sq_core_model::{
    Clip, DeliveryPlatform, DeliveryTarget, MediaFingerprint, MediaRef, Project, Timeline, Track, TrackKind,
};
use sq_core_model::{Marker, MarkerColor, SequenceFormat};
use sq_core_time::{Id, SequentialIds, Time, TimeRange};
use sq_export::core::error::ExportError;
use sq_export::core::preset::{ExportPreferences, ExportPreset, QualityStep, SocialPlatform};
use sq_export::core::settings::{BitrateKind, EncoderSpeed, LoudnessNormalization, RangeSelection, VideoCodec};

use super::*;

fn provider() -> SourceProvider {
    Arc::new(|_, _| Err(ExportError::Cancelled))
}

fn model_of(items: Vec<SequenceItem>, initial: Option<ExportPreset>) -> ExportDialogModel {
    ExportDialogModel::new(items, initial, Arc::new(|_: &Path| None), provider(), Box::new(SequentialIds::default()))
}

fn item(n: u128, name: &str) -> SequenceItem {
    SequenceItem::new(Id::from_u128(1000 + n), name, Time::seconds(10))
}

fn make_model(n: u128) -> ExportDialogModel {
    model_of((1..=n).map(|i| item(i, &format!("Seq {i}"))).collect(), Some(ExportPreset::DEFAULT))
}

fn tiktok_h264() -> ExportPreset {
    ExportPreset::social_preset(SocialPlatform::Tiktok, VideoCodec::H264)
}

#[test]
fn every_sequence_starts_with_one_format() {
    let m = make_model(3);
    for s in m.sequences() {
        assert_eq!(m.formats(s.id).len(), 1);
    }
    assert_eq!(m.selected_format_id(), m.formats(m.selected_id())[0].id);
}

#[test]
fn add_format_appends_and_selects_it() {
    let mut m = make_model(3);
    let first = m.formats(m.selected_id())[0].clone();
    m.add_format(Some(&ExportPreset::PRORES.id()));
    let fs = m.formats(m.selected_id()).to_vec();
    assert_eq!(fs.len(), 2);
    assert_eq!(m.selected_format_id(), fs[1].id);
    assert_eq!(m.preset_id(), ExportPreset::PRORES.id());
    assert_eq!(m.codec(), VideoCodec::ProRes422HQ);
    assert_eq!(fs[0], first);
    assert_eq!(fs[0].settings, ExportDialogModel::with_dialog_defaults(ExportPreset::DEFAULT.settings()));
}

#[test]
fn add_format_without_preset_picks_an_unused_one() {
    let mut m = make_model(3);
    m.add_format(None);
    let ids: std::collections::BTreeSet<_> = m.formats(m.selected_id()).iter().map(|f| f.preset_id.clone()).collect();
    assert_eq!(ids.len(), 2);
}

#[test]
fn edits_only_touch_the_selected_format() {
    let mut m = make_model(3);
    m.add_format(Some(&ExportPreset::YOUTUBE_1080.id()));
    m.set_codec(VideoCodec::Hevc);
    let fs = m.formats(m.selected_id()).to_vec();
    assert_eq!(fs[0].settings.video.codec, VideoCodec::H264);
    assert_eq!(fs[1].settings.video.codec, VideoCodec::Hevc);
    assert_eq!(fs[1].preset_id, ExportDialogModel::CUSTOM_PRESET_ID);
    m.select_format(fs[0].id);
    assert_eq!(m.codec(), VideoCodec::H264);
    assert_eq!(m.preset_id(), ExportPreset::DEFAULT.id());
}

#[test]
fn formats_are_per_sequence() {
    let mut m = make_model(3);
    m.add_format(Some(&ExportPreset::PRORES.id()));
    let second = m.sequences()[1].id;
    m.set_selected_id(second);
    m.set_selected_format_id(m.formats(second)[0].id);
    assert_eq!(m.formats(second).len(), 1);
    assert_eq!(m.preset_id(), ExportPreset::DEFAULT.id());
}

#[test]
fn remove_keeps_at_least_one_format() {
    let mut m = make_model(3);
    let only = m.formats(m.selected_id())[0].id;
    m.remove_format(only);
    assert_eq!(m.formats(m.selected_id()).len(), 1);
    m.add_format(None);
    let added = m.selected_format_id();
    m.remove_format(added);
    assert_eq!(m.formats(m.selected_id()).len(), 1);
    assert_eq!(m.selected_format_id(), only);
}

#[test]
fn duplicate_copies_settings() {
    let mut m = make_model(3);
    m.set_codec(VideoCodec::Hevc);
    m.duplicate_format(m.selected_format_id());
    let fs = m.formats(m.selected_id()).to_vec();
    assert_eq!(fs.len(), 2);
    assert_eq!(fs[1].settings, fs[0].settings);
    assert_ne!(fs[1].id, fs[0].id);
    assert_eq!(m.selected_format_id(), fs[1].id);
}

#[test]
fn jobs_per_checked_sequence_and_enabled_format() {
    let mut m = make_model(3);
    m.add_format(Some(&ExportPreset::PRORES.id()));
    let second = m.sequences()[1].id;
    m.set_checked(second, true);
    assert_eq!(m.job_count(), 3);
    let jobs = m.build_jobs(Path::new("/tmp/out"));
    assert_eq!(jobs.len(), 3);
    assert!(jobs[0].name.starts_with("Seq 1 ") && jobs[1].name.starts_with("Seq 1 "));
    assert_ne!(jobs[0].name, jobs[1].name);
    assert_eq!(jobs[2].name, "Seq 2");
    assert_eq!(jobs[0].settings.video.codec, VideoCodec::H264);
    assert_eq!(jobs[1].settings.video.codec, VideoCodec::ProRes422HQ);
    let ids: std::collections::BTreeSet<_> = jobs.iter().map(|j| j.id).collect();
    assert_eq!(ids.len(), 3);
}

#[test]
fn disabled_format_is_skipped_and_names_stay_plain() {
    let mut m = make_model(3);
    m.add_format(Some(&ExportPreset::PRORES.id()));
    m.set_format_enabled(m.selected_format_id(), false);
    assert_eq!(m.job_count(), 1);
    assert_eq!(m.build_jobs(Path::new("/tmp"))[0].name, "Seq 1");
}

#[test]
fn size_estimate_sums_all_enabled_formats() {
    let mut m = make_model(3);
    let one = m.estimated_bytes();
    m.add_format(Some(&tiktok_h264().id()));
    assert_eq!(m.estimated_bytes(), one * 2);
    m.set_format_enabled(m.selected_format_id(), false);
    assert_eq!(m.estimated_bytes(), one);
}

#[test]
fn nothing_enabled_cannot_export_and_validation_covers_other_formats() {
    let mut m = make_model(3);
    m.set_format_enabled(m.selected_format_id(), false);
    assert_eq!(m.job_count(), 0);
    assert!(!m.can_export() && !m.validation_messages().is_empty());
    let mut m = make_model(3);
    m.add_format(None);
    m.set_width(1081);
    m.select_format(m.formats(m.selected_id())[0].id);
    assert!(!m.can_export());
}

#[test]
fn footer_label_counts_files() {
    let mut m = make_model(3);
    assert_eq!(m.export_button_title(), "Export");
    m.add_format(None);
    assert_eq!(m.export_button_title(), "Export 2 files");
}

#[test]
fn max_bitrate_toggle_keeps_average() {
    let mut m = make_model(3);
    m.set_has_max_bitrate(false);
    assert_eq!(m.settings().video.bitrate.max_bits_per_second(), None);
    m.set_has_max_bitrate(true);
    assert!(m.settings().video.bitrate.max_bits_per_second().is_some());
    m.set_max_bitrate_mbps(30.0);
    assert_eq!(m.settings().video.bitrate.max_bits_per_second(), Some(30_000_000));
    assert_eq!(m.settings().video.bitrate.average_bits_per_second(), 12_000_000);
    m.set_has_max_bitrate(false);
    assert_eq!(m.settings().video.bitrate.max_bits_per_second(), None);
}

#[test]
fn max_bitrate_follows_target_until_edited_by_hand() {
    let mut m = make_model(1);
    m.set_has_max_bitrate(true);
    m.set_bitrate_mbps(10.0);
    assert_eq!(m.max_bitrate_mbps(), 15.0);
    m.set_max_bitrate_mbps(20.0);
    m.set_bitrate_mbps(8.0);
    assert_eq!(m.max_bitrate_mbps(), 20.0); // stays: edited by hand
    m.set_bitrate_mbps(25.0);
    assert_eq!(m.max_bitrate_mbps(), 25.0); // raised to the target
    m.set_bitrate_kind(BitrateKind::Cbr);
    m.set_bitrate_mbps(10.0);
    assert_eq!(m.max_bitrate_mbps(), 15.0); // the hand-edit state reset with CBR
}

#[test]
fn advanced_edit_marks_custom_but_audio_edit_does_not() {
    let mut m = make_model(3);
    m.edit(|s| s.audio.sample_rate = 44_100);
    assert_eq!(m.preset_id(), ExportPreset::DEFAULT.id());
    assert_eq!(m.settings().audio.sample_rate, 44_100);
    m.edit(|s| s.video.keyframe_interval = 120);
    assert_eq!(m.preset_id(), ExportDialogModel::CUSTOM_PRESET_ID);
    assert_eq!(m.settings().video.keyframe_interval, 120);
}

#[test]
fn fps_reports_the_picker_tag_and_writes_ntsc_rates() {
    let mut m = make_model(1);
    m.set_fps(29.97);
    assert_eq!(m.settings().video.frame_duration, Time::new(1001, 30000));
    assert_eq!(m.fps(), 29.97);
    assert_eq!(m.summary_text(), "1080×1920 · 29.97 fps · H.264 · 12 Mbit/s");
    m.set_fps(25.0);
    assert_eq!(m.settings().video.frame_duration, Time::new(1, 25));
    assert_eq!(ExportDialogModel::frame_rate_text(Time::new(1001, 24000)), "23.976");
    assert_eq!(ExportDialogModel::frame_rate_text(Time::new(1, 50)), "50");
    assert_eq!(ExportDialogModel::frame_rate_text(Time::new(1, 7)), "7");
}

#[test]
fn encoder_speed_applies_to_every_format_and_survives_presets() {
    let mut m = make_model(2);
    assert_eq!(m.encoder_speed(), EncoderSpeed::Quality);
    m.add_format(Some(&ExportPreset::PRORES.id()));
    let before = m.preset_id().to_string();
    m.set_encoder_speed(EncoderSpeed::Balanced);
    assert_eq!(m.preset_id(), before);
    for s in m.sequences() {
        for f in m.formats(s.id) {
            assert_eq!(f.settings.encoder_speed(), EncoderSpeed::Balanced);
        }
    }
    m.set_preset_id(&ExportPreset::DEFAULT.id());
    assert_eq!(m.settings().encoder_speed(), EncoderSpeed::Balanced);
    m.add_format(None);
    assert_eq!(m.settings().encoder_speed(), EncoderSpeed::Balanced);
}

#[test]
fn speed_hint_only_on_small_macs_at_quality() {
    let gib: u64 = 1 << 30;
    assert!(ExportDialogModel::encoder_speed_hint(EncoderSpeed::Quality, 8 * gib).is_some());
    assert!(ExportDialogModel::encoder_speed_hint(EncoderSpeed::Balanced, 8 * gib).is_none());
    assert!(ExportDialogModel::encoder_speed_hint(EncoderSpeed::Quality, 32 * gib).is_none());
}

#[test]
fn loudness_follows_the_delivery_target_then_the_preset() {
    let mut it = item(1, "A");
    it.delivery_target =
        Some(DeliveryTarget { platform: DeliveryPlatform::Tiktok, target_lufs: -16.0, true_peak_db: -2.0 });
    let mut m = model_of(vec![it], None);
    assert_eq!(m.settings().audio.loudness, Some(LoudnessNormalization::new(-16.0, -2.0)));
    assert!(m.normalize_loudness());
    assert_eq!(m.loudness_label(), "Normalize loudness to -16 LUFS, max -2 dBTP");
    let mut plain = make_model(1);
    assert!(!plain.normalize_loudness());
    plain.set_normalize_loudness(true);
    assert_eq!(plain.settings().audio.loudness, Some(LoudnessNormalization::new(-14.0, -1.0)));
    m.set_normalize_loudness(false);
    assert!(!m.normalize_loudness());
}

#[test]
fn range_modes_switch_between_entire_in_out_custom_and_selection() {
    let mut it = item(1, "R");
    it.in_out = Some(TimeRange::new(Time::seconds(2), Time::seconds(4)));
    it.selected_clips = vec![
        SelectedClipRange::new("b", TimeRange::new(Time::seconds(5), Time::seconds(2))),
        SelectedClipRange::new("a", TimeRange::new(Time::seconds(1), Time::seconds(2))),
    ];
    let mut m = model_of(vec![it], Some(ExportPreset::DEFAULT));
    assert_eq!(m.range_mode(), 1); // In/Out starts on
    assert_eq!(m.sequences()[0].selected_clips[0].name, "a"); // sorted by start
    m.set_range_mode(0);
    assert_eq!((m.range_mode(), m.settings().range), (0, RangeSelection::EntireSequence));
    assert_eq!(m.range_seconds(), RangeSeconds { start: 0.0, end: 10.0 });
    m.set_range_mode(3);
    assert_eq!(m.range_mode(), 3);
    assert_eq!(m.range_seconds(), RangeSeconds { start: 1.0, end: 7.0 });
    m.set_one_file_per_clip(true);
    assert_eq!(m.job_count(), 2);
    let names: Vec<_> = m.build_jobs(Path::new("/o")).into_iter().map(|j| j.name).collect();
    assert_eq!(names, ["R - 1 a", "R - 2 b"]);
    m.set_range_mode(2);
    assert_eq!(m.range_mode(), 2);
    assert_eq!(m.job_count(), 1);
}

#[test]
fn a_zero_or_one_frame_in_out_never_becomes_the_default_range() {
    for len in [Time::ZERO, Time::new(1, 30)] {
        let mut it = item(1, "R");
        it.in_out = Some(TimeRange::new(Time::seconds(3), len));
        let mut m = model_of(vec![it], Some(ExportPreset::DEFAULT));
        assert_eq!(m.settings().range, RangeSelection::EntireSequence, "new sheet, length {len:?}");
        assert!(m.can_use_in_out(), "the user can still pick In to Out");
        let prefs = ExportPreferences::new(&ExportPreset::DEFAULT.id(), m.settings(), false);
        m.apply_preferences(&prefs);
        assert_eq!(m.settings().range, RangeSelection::EntireSequence, "remembered choices, length {len:?}");
        assert_eq!(m.range_seconds(), RangeSeconds { start: 0.0, end: 10.0 });
    }
    let mut real = item(1, "R");
    real.in_out = Some(TimeRange::new(Time::seconds(3), Time::new(2, 30)));
    let m = model_of(vec![real], Some(ExportPreset::DEFAULT));
    assert_eq!(m.range_mode(), 1, "two frames are a real range");
}

#[test]
fn custom_range_snaps_to_frames_and_stays_inside() {
    let mut m = make_model(1);
    m.set_range_mode(2);
    m.set_custom_range(Some(1.01), None);
    let RangeSelection::InOut(r) = m.settings().range else { panic!("range") };
    assert_eq!(r.start, Time::new(30, 30));
    assert_eq!(r.end(), Time::seconds(10));
    m.set_custom_range(None, Some(0.5));
    let RangeSelection::InOut(r) = m.settings().range else { panic!("range") };
    assert_eq!((r.start, r.end()), (Time::new(14, 30), Time::new(15, 30))); // one frame at least, start follows the end
    m.set_custom_range(Some(99.0), None);
    let RangeSelection::InOut(r) = m.settings().range else { panic!("range") };
    assert!(r.end() <= Time::seconds(10) && r.duration > Time::ZERO);
}

#[test]
fn output_list_ticks_sequences_and_summarizes() {
    let mut m = make_model(2);
    let (a, b) = (m.sequences()[0].id, m.sequences()[1].id);
    let b_fmt = m.formats(b)[0].id;
    assert_eq!(m.output_rows().len(), 2);
    assert!(m.output_rows()[0].is_checked && !m.output_rows()[1].is_checked);
    assert_eq!(m.output_rows()[0].title, "Seq 1 · Vertical 9:16");
    assert_eq!(m.output_rows()[0].size_text, "1080 × 1920");
    m.set_output_checked(b_fmt, true);
    assert!(m.is_checked(b));
    assert_eq!(m.job_count(), 2);
    assert!(m.output_summary_text().starts_with("2 files · about "));
    assert!(m.output_summary_text().ends_with("00:00:10:00 each"));
    m.set_output_checked(b_fmt, false);
    assert!(!m.is_checked(b) && m.is_checked(a));
    m.select_output(b_fmt);
    assert_eq!((m.selected_id(), m.selected_format_id()), (b, b_fmt));
    assert_eq!(ExportDialogModel::aspect_name(1000, 1250), "Portrait 4:5");
    assert_eq!(ExportDialogModel::aspect_name(1000, 777), "1000 × 777");
}

#[test]
fn file_names_are_cleaned_and_fall_back_to_the_sequence_name() {
    let mut m = make_model(1);
    assert_eq!(m.file_name(), "Seq 1");
    m.set_file_name("a/b: c.");
    assert_eq!(m.file_name(), "ab c");
    m.set_file_name("???");
    assert_eq!(m.file_name(), "Seq 1");
    assert_eq!(m.file_extension(), "mp4");
}

#[test]
fn disk_space_and_x_limits_block_the_export() {
    let m = ExportDialogModel::new(
        vec![item(1, "A")],
        Some(ExportPreset::DEFAULT),
        Arc::new(|_: &Path| Some(1000)),
        provider(),
        Box::new(SequentialIds::default()),
    );
    let msg = m.disk_space_message().unwrap_or_default();
    assert!(msg.starts_with("Not enough free disk space: the export needs about "));
    assert!(!m.can_export());
    let mut long = item(2, "Long");
    long.duration = Time::seconds(200);
    let m = model_of(vec![long], Some(ExportPreset::X_POST));
    assert_eq!(m.platform_limit_messages().len(), 1);
    assert!(m.platform_limit_messages()[0].contains("allows at most 140 seconds; this export is 200 seconds."));
}

#[test]
fn hdr_clips_start_on_hevc_10_bit_with_the_transfer_set() {
    let mut it = item(1, "H");
    it.hdr_target = Some(sq_export::core::hdr::HdrTransfer::Hlg);
    let m = model_of(vec![it], None);
    assert_eq!(m.preset_id(), ExportPreset::HEVC_10.id());
    assert_eq!(m.settings().hdr_delivery.map(|d| d.transfer), Some(sq_export::core::hdr::HdrTransfer::Hlg));
}

#[test]
fn preferences_round_trip_through_apply() {
    let mut m = make_model(1);
    m.set_captions(sq_export::core::settings::CaptionMode::SidecarSrt);
    m.set_normalize_loudness(true);
    let p = m.preferences();
    let mut fresh = make_model(1);
    fresh.apply_preferences(&p);
    assert_eq!(fresh.captions(), sq_export::core::settings::CaptionMode::SidecarSrt);
    assert!(fresh.normalize_loudness());
    assert!(!fresh.export_all_formats()); // no variants
}

#[test]
fn cut_down_jobs_use_suffixes_per_checked_range() {
    let mut it = item(1, "Reel");
    let mk = |t: i64, d: i64, name: &str| Marker {
        id: Id::from_u128(t as u128),
        time: Time::seconds(t),
        name: name.to_string(),
        color: MarkerColor::Cyan,
        comment: String::new(),
        duration: Time::seconds(d),
    };
    it.markers = vec![mk(0, 6, "cut-down 6"), mk(20, 6, "cut-down 6")];
    let mut m = model_of(vec![it], Some(ExportPreset::DEFAULT));
    let plans = m.cut_down_plans();
    assert!(!plans.is_empty());
    assert_eq!(m.checked_cut_down_count(), plans.iter().map(|p| p.ranges.len()).sum::<usize>());
    let key = CutDownKey::new(plans[0].target_seconds, 0);
    m.set_cut_down_checked(key, false);
    assert!(!m.is_cut_down_checked(key));
    let jobs = m.build_cut_down_jobs(Path::new("/o"));
    assert_eq!(jobs.len(), m.checked_cut_down_count());
    assert!(jobs.iter().all(|j| j.name.starts_with("Reel_") && matches!(j.settings.range, RangeSelection::InOut(_))));
    m.on_export_cut_downs();
    assert_eq!(m.take_events(), vec![ExportDialogEvent::ExportCutDowns]);
}

#[test]
fn version_goes_up_with_changes() {
    let mut m = make_model(1);
    let v = m.version();
    m.set_codec(VideoCodec::Hevc);
    assert!(m.version() > v);
}

// MARK: Quick export

fn temp_dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("sq-quick-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    let _ = std::fs::create_dir_all(&d);
    d
}

#[test]
fn saved_project_exports_into_its_exports_folder_without_creating_it() {
    let root = temp_dir("a");
    let dir = QuickExport::directory(Some(&root.join("Film.sqproj")), Some("/nonexistent"), Some(&root.join("Movies")));
    assert_eq!(dir.file_name().and_then(|n| n.to_str()), Some("Exports"));
    assert!(!dir.exists(), "choosing the folder (sheet open, then Cancel) must not create it");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn unsaved_project_uses_last_folder_then_movies_then_temp() {
    let root = temp_dir("b");
    let movies = root.join("Movies");
    let last = root.to_string_lossy().into_owned();
    assert_eq!(QuickExport::directory(None, Some(&last), Some(&movies)), root);
    let gone = root.join("gone").to_string_lossy().into_owned();
    assert_eq!(QuickExport::directory(None, Some(&gone), Some(&movies)), movies);
    assert_eq!(QuickExport::directory(None, None, Some(&movies)), movies);
    assert_eq!(QuickExport::directory(None, None, None), std::env::temp_dir());
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn target_sequence_keeps_its_platform_preset_and_others_use_the_last_one() {
    let mut it = item(1, "S");
    it.format = Some(SequenceFormat::new(Time::new(1, 30)));
    it.delivery_target =
        Some(DeliveryTarget { platform: DeliveryPlatform::Tiktok, target_lufs: -14.0, true_peak_db: -1.0 });
    let mut m = model_of(vec![it], None);
    let own = m.preset_id().to_string();
    QuickExport::apply_preset(&mut m, Some(&ExportPreset::PRORES.id()));
    assert_eq!(m.preset_id(), own);
    assert_eq!(m.preset_id(), tiktok_h264().id());
    assert!(m.normalize_loudness());

    let mut plain = model_of(vec![item(2, "S")], None);
    let before = plain.preset_id().to_string();
    QuickExport::apply_preset(&mut plain, Some("no-such-preset"));
    assert_eq!(plain.preset_id(), before);
    QuickExport::apply_preset(&mut plain, None);
    assert_eq!(plain.preset_id(), before);
    QuickExport::apply_preset(&mut plain, Some(&ExportPreset::PRORES.id()));
    assert_eq!(plain.preset_id(), ExportPreset::PRORES.id());
}

#[test]
fn range_notice_only_for_in_out() {
    let mut it = item(1, "N");
    it.in_out = Some(TimeRange::new(Time::seconds(1), Time::seconds(72)));
    let mut m = model_of(vec![it], Some(ExportPreset::DEFAULT));
    assert_eq!(QuickExport::range_notice(&m).as_deref(), Some("Exporting In to Out, 1:12"));
    m.set_use_in_out(false);
    assert_eq!(QuickExport::range_notice(&m), None);
}

// MARK: Preflight report

fn project_with(tl: Timeline, media: Vec<MediaRef>) -> Project {
    Project::new(Id::from_u128(1), "P", media, vec![tl])
}

fn preflight_model(p: &Project) -> ExportDialogModel {
    let items = p.timelines.iter().map(|t| SequenceItem::new(t.id, &t.name, t.duration())).collect();
    model_of(items, None)
}

#[test]
fn offline_media_is_named_with_the_mac_title() {
    let gone = MediaRef::new(Id::from_u128(7), "gone.mov", "/nonexistent/gone.mov", MediaFingerprint::new(1));
    let clip = Clip::new(
        Id::from_u128(8),
        "c",
        gone.id,
        TrackKind::Video,
        TimeRange::new(Time::ZERO, Time::seconds(2)),
        Time::ZERO,
    );
    let mut track = Track::new(Id::from_u128(9), TrackKind::Video);
    track.set_clips(vec![clip]);
    let tl = Timeline::new(Id::from_u128(2), "Main", SequenceFormat::new(Time::new(1, 25)), vec![track]);
    let project = project_with(tl, vec![gone]);
    let r = ExportPreflightReport::build(&preflight_model(&project), &project, &std::env::temp_dir(), None);
    assert_eq!(r.title, "Media is offline");
    assert!(r.lines[0].contains("• gone.mov"));
}

#[test]
fn the_disk_space_note_follows_the_design_text() {
    use sq_export::core::preflight::{ExportPreflight, SpaceVerdict};
    // Fake free space: 3.1 GB free for a 2.4 GB export is room enough, 2.6 GB is tight, 1 GB is not enough.
    let (est, tight) = (2_400_000_000, 2_800_000_000);
    assert_eq!(ExportPreflight::space_verdict(Some(3_100_000_000), est), SpaceVerdict::Ok);
    assert_eq!(ExportPreflightReport::space_note(SpaceVerdict::Ok, Some(3_100_000_000), est), None);
    assert_eq!(ExportPreflight::space_verdict(Some(tight), est), SpaceVerdict::Tight);
    assert_eq!(
        ExportPreflightReport::space_note(SpaceVerdict::Tight, Some(3_100_000_000), est).as_deref(),
        Some("The output disk has 3.1 GB free and the export needs about 2.4 GB: little room is left over.")
    );
    assert_eq!(ExportPreflight::space_verdict(Some(1_000_000_000), est), SpaceVerdict::Insufficient);
    let note = ExportPreflightReport::space_note(SpaceVerdict::Insufficient, Some(1_000_000_000), est).unwrap();
    assert!(note.starts_with("The output disk has 1.0 GB free and the export needs about 2.4 GB."));
    assert_eq!(ExportPreflightReport::space_note(SpaceVerdict::Tight, None, est), None);
}

#[test]
fn untracked_magic_frames_come_from_the_host_counter() {
    let tl = Timeline::new(
        Id::from_u128(2),
        "Main",
        SequenceFormat::new(Time::new(1, 25)),
        vec![Track::new(Id::from_u128(9), TrackKind::Video)],
    );
    let project = project_with(tl, Vec::new());
    let model = preflight_model(&project);
    let three = |_: &Timeline, _: &std::collections::BTreeMap<Id, Timeline>| 3;
    let r = ExportPreflightReport::build(&model, &project, &std::env::temp_dir(), Some(&three));
    assert_eq!(r.title, "Magic mask not tracked");
    assert_eq!(
        r.lines,
        [
            "Magic mask not tracked on 3 frames: those frames export without the mask. Select the clip, then Track Forward / Backward in its mask row."
        ]
    );
    assert!(ExportPreflightReport::build(&model, &project, &std::env::temp_dir(), None).is_empty());
}

#[test]
fn existing_files_question_names_up_to_three() {
    assert_eq!(ExportPreflightReport::existing_files_question(&[]), None);
    let one = ExportPreflightReport::existing_files_question(&[PathBuf::from("/x/A.mp4")]);
    assert_eq!(one.map(|q| q.0).as_deref(), Some("“A.mp4” already exists in this folder"));
    let five: Vec<PathBuf> = (1..=5).map(|i| PathBuf::from(format!("/x/{i}.mp4"))).collect();
    assert_eq!(
        ExportPreflightReport::existing_files_question(&five).map(|q| q.0).as_deref(),
        Some("“1.mp4”, “2.mp4”, “3.mp4” and 2 more already exist in this folder")
    );
}

#[test]
fn encoder_speed_hint_names_the_machine_per_platform() {
    use sq_os::Platform;
    let gib = 1u64 << 30;
    let on = |p| ExportDialogModel::encoder_speed_hint_on(p, EncoderSpeed::Quality, 8 * gib).expect("hint");
    assert!(on(Platform::Mac).ends_with("exports faster on this Mac"));
    assert!(on(Platform::Windows).ends_with("exports faster on this computer"));
    assert!(on(Platform::Linux).ends_with("exports faster on this computer"));
}

/// A Custom 8K size remembered from an earlier run: only a sequence of the same aspect takes it back. (Windows run: a
/// 1080 x 1920 sequence opened at 7680 x 4320 "Custom" with the software-encoder note.)
fn custom_8k() -> ExportPreferences {
    let mut s = ExportPreset::DEFAULT.settings();
    s.video.width = 7680;
    s.video.height = 4320;
    ExportPreferences::new(ExportPreferences::CUSTOM_PRESET_ID, &s, false)
}

fn sized(w: i64, h: i64) -> SequenceItem {
    let mut it = item(1, "Seq");
    let mut f = sq_core_model::SequenceFormat::new(Time::new(1, 30));
    f.width = w;
    f.height = h;
    it.format = Some(f);
    it
}

#[test]
fn a_remembered_8k_custom_does_not_reach_a_portrait_sequence() {
    let mut m = model_of(vec![sized(1080, 1920)], Some(ExportPreset::DEFAULT));
    m.apply_preferences(&custom_8k());
    assert_ne!(m.preset_id(), ExportPreferences::CUSTOM_PRESET_ID);
    let v = &m.settings().video;
    assert!((v.width, v.height) != (7680, 4320), "got {}x{}", v.width, v.height);
}

#[test]
fn a_remembered_custom_size_returns_on_a_sequence_of_the_same_aspect() {
    let mut m = model_of(vec![sized(1920, 1080)], Some(ExportPreset::DEFAULT));
    m.apply_preferences(&custom_8k());
    assert_eq!(m.preset_id(), ExportPreferences::CUSTOM_PRESET_ID);
    assert_eq!((m.settings().video.width, m.settings().video.height), (7680, 4320));
}

/// A vertical sequence with a YouTube delivery target opens the sheet at its own size, with and without remembered
/// choices (it opened at 1920 x 1080 with the picture letterboxed).
#[test]
fn a_vertical_sequence_with_a_youtube_target_opens_at_its_own_size() {
    let mut it = sized(1080, 1920);
    it.delivery_target =
        Some(DeliveryTarget { platform: DeliveryPlatform::Youtube, target_lufs: -14.0, true_peak_db: -1.0 });
    let mut m = model_of(vec![it], Some(ExportPreset::DEFAULT));
    assert_eq!((m.settings().video.width, m.settings().video.height), (1080, 1920));
    m.apply_preferences(&custom_8k());
    assert_eq!((m.settings().video.width, m.settings().video.height), (1080, 1920));
}

/// PRUEF-LIN-3: the preset label never names a size the file will not have (YouTube 1080p kept 1080 x 1920).
#[test]
fn the_shown_preset_is_custom_when_the_size_is_not_the_presets() {
    let mut it = sized(1080, 1920);
    it.delivery_target =
        Some(DeliveryTarget { platform: DeliveryPlatform::Youtube, target_lufs: -14.0, true_peak_db: -1.0 });
    let m = model_of(vec![it], Some(ExportPreset::YOUTUBE_1080));
    assert_eq!(m.preset_id(), ExportPreset::YOUTUBE_1080.id(), "the stored preset is what was asked for");
    assert_eq!((m.settings().video.width, m.settings().video.height), (1080, 1920));
    assert_eq!(m.shown_preset_id(), ExportDialogModel::CUSTOM_PRESET_ID);
    // A landscape sequence keeps the name; a Match Source preset follows any sequence size.
    let m = model_of(vec![sized(1920, 1080)], Some(ExportPreset::YOUTUBE_1080));
    assert_eq!(m.shown_preset_id(), ExportPreset::YOUTUBE_1080.id());
    let m = model_of(vec![sized(1080, 1920)], Some(ExportPreset::MATCH_SOURCE));
    assert_eq!(m.shown_preset_id(), ExportPreset::MATCH_SOURCE.id());
}

/// A quality step keeps the chosen preset (on purpose; the Mac sheet turns it into Custom) and returns with it when
/// the sheet opens again.
#[test]
fn a_quality_step_keeps_the_preset_and_comes_back_when_the_sheet_reopens() {
    let mut m = model_of(vec![sized(1920, 1080)], Some(ExportPreset::YOUTUBE_1080));
    let own = m.settings().video.bitrate;
    assert_eq!(m.preferences().quality_step, None, "the preset's own bitrate is not a remembered step");
    m.set_quality_step(QualityStep::Smaller);
    assert_eq!(m.shown_preset_id(), ExportPreset::YOUTUBE_1080.id());
    assert_eq!(m.settings().video.quality_step(), Some(QualityStep::Smaller));
    let stored = ExportPreferences::decode(m.preferences().encoded().as_deref()).expect("stored preferences");
    assert_eq!(stored.quality_step, Some(QualityStep::Smaller));
    let mut again = model_of(vec![sized(1920, 1080)], Some(ExportPreset::DEFAULT));
    again.apply_preferences(&stored);
    assert_eq!(again.shown_preset_id(), ExportPreset::YOUTUBE_1080.id());
    assert_eq!(again.settings().video.bitrate, m.settings().video.bitrate);
    assert_ne!(again.settings().video.bitrate, own);
    // A sequence on its own platform preset keeps that preset's bitrate: the step belongs to the remembered preset.
    let mut it = sized(1080, 1920);
    it.delivery_target =
        Some(DeliveryTarget { platform: DeliveryPlatform::Tiktok, target_lufs: -14.0, true_peak_db: -1.0 });
    let mut other = model_of(vec![it], Some(ExportPreset::DEFAULT));
    let own = other.settings().video.bitrate;
    other.apply_preferences(&stored);
    assert_eq!(other.settings().video.bitrate, own);
}

/// A bitrate typed after a step is a hand edit: "Custom" with the whole video part remembered, and no step left over.
#[test]
fn a_typed_bitrate_after_a_quality_step_makes_the_preset_custom() {
    let mut m = model_of(vec![sized(1920, 1080)], Some(ExportPreset::YOUTUBE_1080));
    m.set_quality_step(QualityStep::High);
    m.set_bitrate_mbps(9.0);
    assert_eq!(m.shown_preset_id(), ExportDialogModel::CUSTOM_PRESET_ID);
    let p = m.preferences();
    assert_eq!(p.quality_step, None);
    assert!(p.custom_video.is_some());
}

/// "Best" advertised ~31 MB and the file had 17.4 MB: an average-bitrate (VBR) target is a ceiling, so the text says "up to".
#[test]
fn a_vbr_size_estimate_is_a_ceiling_and_cbr_keeps_its_tilde() {
    let mut m = make_model(3);
    let bytes = m.estimated_bytes();
    assert!(m.estimated_size_is_upper_bound(), "the default H.264 preset is VBR");
    assert_eq!(m.estimated_size_text(), format!("up to {}", sq_uikit::sqbyte_size::SQByteSize::string(bytes)));
    // The math itself: (video + audio bit rate) x duration / 8.
    let s = m.settings().clone();
    assert_eq!(
        s.estimated_file_size(Time::new(10, 1)),
        (s.estimated_video_bits_per_second() + s.estimated_audio_bits_per_second()) * 10 / 8
    );
    m.set_bitrate_kind(BitrateKind::Cbr);
    assert!(!m.estimated_size_is_upper_bound());
    assert!(m.estimated_size_text().starts_with("~ "));
}

/// Sequence shapes and delivery targets the sheet opens over: 9:16, 1:1, 4:3, 4:5 and 16:9, each with no target and with
/// every platform.
fn opening_cases() -> Vec<(i64, i64, Option<DeliveryPlatform>)> {
    let platforms = [
        None,
        Some(DeliveryPlatform::Tiktok),
        Some(DeliveryPlatform::Reels),
        Some(DeliveryPlatform::Shorts),
        Some(DeliveryPlatform::Youtube),
        Some(DeliveryPlatform::SocialFeed),
    ];
    let shapes = [(1080, 1920), (1080, 1080), (1440, 1080), (1080, 1350), (1920, 1080), (3840, 2160)];
    shapes.iter().flat_map(|&(w, h)| platforms.iter().map(move |&p| (w, h, p))).collect()
}

fn targeted(w: i64, h: i64, platform: Option<DeliveryPlatform>) -> SequenceItem {
    let mut it = sized(w, h);
    it.delivery_target = platform.map(|platform| DeliveryTarget { platform, target_lufs: -14.0, true_peak_db: -1.0 });
    it
}

/// The sheet opens at the sequence's own shape whatever preset the platform, the last export or the remembered choices name
/// (a remembered YouTube 1080p on a 9:16 sequence opened at 1920 x 1080, letterboxed), and a Quality step is always lit.
#[test]
fn the_sheet_opens_at_the_sequence_shape_with_a_quality_step_lit() {
    let video_presets: Vec<ExportPreset> = ExportPreset::all()
        .into_iter()
        .filter(|p| {
            let s = p.settings();
            s.audio_only.is_none() && s.frame_output.is_none()
        })
        .collect();
    assert!(video_presets.len() > 10);
    let mut checked = 0;
    for (w, h, platform) in opening_cases() {
        let new = || model_of(vec![targeted(w, h, platform)], None);
        let mut opened: Vec<(String, ExportDialogModel)> = vec![("no memory".into(), new())];
        for p in &video_presets {
            let mut last = new();
            QuickExport::apply_preset(&mut last, Some(&p.id()));
            opened.push((format!("last preset {}", p.id()), last));
            let mut remembered = new();
            remembered.apply_preferences(&ExportPreferences::new(&p.id(), &p.settings(), false));
            opened.push((format!("remembered {}", p.id()), remembered));
        }
        for (how, m) in opened {
            let v = &m.settings().video;
            let (a, b) = (i128::from(v.width) * i128::from(h), i128::from(v.height) * i128::from(w));
            assert!(
                (a - b).abs() * 100 <= a.max(b),
                "{how} on {w}x{h} with {platform:?} opens at {}x{}",
                v.width,
                v.height
            );
            if matches!(v.codec, VideoCodec::H264 | VideoCodec::Hevc) {
                assert!(
                    v.quality_step().or_else(|| v.nearest_quality_step()).is_some(),
                    "{how} on {w}x{h} with {platform:?}: no Quality step is lit"
                );
            }
            checked += 1;
        }
    }
    assert!(checked > 1000, "{checked}");
}

/// The quality step is state, the rate is derived from it: a new format keeps "Smaller" and gets Smaller's rate for that
/// codec (the sheet showed "Standard" beside the old 5.6 Mbit/s before).
#[test]
fn a_quality_step_survives_a_format_change_with_the_rate_of_the_new_format() {
    let mut m = model_of(vec![sized(1920, 1080)], Some(ExportPreset::YOUTUBE_1080));
    m.set_quality_step(QualityStep::Smaller);
    let h264 = m.bitrate_mbps();
    m.set_codec(VideoCodec::Hevc);
    assert_eq!(m.quality_step(), Some(QualityStep::Smaller), "HEVC keeps the picked step");
    let hevc = m.bitrate_mbps();
    assert!((hevc / h264 - 0.055 / 0.09).abs() < 0.01, "Smaller on HEVC is 0.055 bpp: {hevc} vs {h264}");
    assert_eq!(m.settings().video.quality_step(), Some(QualityStep::Smaller), "the rate sits on the step");
    // ProRes has no rate of its own; coming back to H.264 gives Smaller its H.264 rate again.
    m.set_codec(VideoCodec::ProRes422);
    assert_eq!(m.quality_step(), Some(QualityStep::Smaller));
    m.set_codec(VideoCodec::H264);
    assert_eq!(m.quality_step(), Some(QualityStep::Smaller));
    assert!((m.bitrate_mbps() - h264).abs() < 1e-9, "{} vs {h264}", m.bitrate_mbps());
    // A new size recomputes the rate for the step; a typed rate drops the step.
    m.set_width(1280);
    m.set_height(720);
    assert_eq!(m.settings().video.quality_step(), Some(QualityStep::Smaller));
    assert!(m.bitrate_mbps() < h264);
    m.set_bitrate_mbps(9.0);
    assert_ne!(m.selected_format().quality_step, Some(QualityStep::Smaller), "a typed rate is no step");
    m.set_codec(VideoCodec::Hevc);
    assert_eq!(m.bitrate_mbps(), 9.0, "a typed rate stays through a format change");
    // A preset the user picks gives its own rate back and forgets the step.
    m.set_quality_step(QualityStep::High);
    m.set_preset_id(&ExportPreset::YOUTUBE_1080.id());
    assert_eq!(m.selected_format().quality_step, None);
}
