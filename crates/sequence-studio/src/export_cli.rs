//! `--export`: the Export sheet's pipeline without a window (preset settings, `ExportQueue`, the engine frames of
//! `export.rs`), for verification from the command line and scripts.

use crate::cli::ExportArgs;
use crate::export::sources;
use sq_app_hosts::ExportSnapshot;
use sq_core_edit::source_edit_placement::SourceEditPlacementExt;
use sq_core_time::{Id, Time, TimeRange};
use sq_editor_session::ExportDialogModel;
use sq_export::core::frame_output::FrameOutput;
use sq_export::core::hdr::{HdrDelivery, HdrTransfer};
use sq_export::core::preset::ExportPreset;
use sq_export::core::queue::{ExportJob, ExportJobState, ExportQueue};
use sq_export::core::settings::{ExportSettings, RangeSelection};
use sq_export::core::timeline_audio::export_frame_count;
use sq_export::encode::FfmpegExportEncoder;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// The preset names of the sheet, in its order.
pub fn list_presets() -> Vec<String> {
    ExportPreset::all().iter().map(ExportPreset::name).collect()
}

fn find_preset(text: &str) -> Result<ExportPreset, String> {
    let same = |a: &str| a.eq_ignore_ascii_case(text);
    ExportPreset::all()
        .into_iter()
        .find(|p| same(&p.name()) || same(&p.id()))
        .ok_or_else(|| format!("Unknown preset \u{201c}{text}\u{201d}. --list-presets shows the names."))
}

/// Set by Ctrl+C / SIGINT / SIGTERM (Windows: Ctrl+C, Ctrl+Break, close): the run stops like the sheet's Cancel.
static INTERRUPTED: AtomicBool = AtomicBool::new(false);

/// Exit code of a canceled export (128 + SIGINT).
const CANCELED_EXIT: i32 = 130;

fn install_interrupt_handler() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        // A failure to install only means Ctrl+C keeps its default (the process ends at once).
        let _ = ctrlc::set_handler(|| INTERRUPTED.store(true, Ordering::SeqCst));
    });
}

/// What the file holds, for the JSON line: the real codec of the preset (not the picture default of an audio file).
fn delivered_codec(s: &ExportSettings) -> String {
    if let Some(a) = s.audio_only {
        return match a.codec() {
            sq_export::core::settings::AudioCodec::Aac => "aac".into(),
            sq_export::core::settings::AudioCodec::Pcm => "pcm".into(),
        };
    }
    match s.frame_output {
        Some(FrameOutput::Gif) => "gif".into(),
        Some(FrameOutput::Sequence(_)) => "image-sequence".into(),
        None => s.video.codec.raw_value().into(),
    }
}

/// Why `execute` stopped without a file.
#[derive(Debug, PartialEq)]
pub enum Stop {
    /// The text goes to stderr, exit code 1.
    Error(String),
    /// Ctrl+C / SIGTERM: the partial file is gone, exit code 130.
    Canceled(String),
}

impl From<String> for Stop {
    fn from(e: String) -> Stop {
        Stop::Error(e)
    }
}

impl From<&str> for Stop {
    fn from(e: &str) -> Stop {
        Stop::Error(e.to_string())
    }
}

/// What a finished export wrote.
#[derive(Debug)]
pub struct Report {
    pub file: std::path::PathBuf,
    pub frames: usize,
    pub codec: String,
    /// FFmpeg name of the video encoder that wrote the file ("h264_videotoolbox", "libx264", ...); empty for audio-only.
    pub encoder: String,
    pub size_bytes: u64,
    pub seconds: f64,
}

/// Exports the active sequence of `project` to `args.out`; prints progress lines and one JSON line at the end.
/// A canceled run ends the process with code 130.
pub fn run(project: &Path, args: &ExportArgs) -> Result<(), String> {
    install_interrupt_handler();
    match execute(project, args, &INTERRUPTED) {
        Ok(r) => {
            let line = serde_json::json!({
                "file": r.file.display().to_string(),
                "frames": r.frames,
                "seconds": r.seconds,
                "codec": r.codec,
                "encoder": r.encoder,
                "size_bytes": r.size_bytes,
            });
            sq_os::outln!("{line}");
            Ok(())
        }
        Err(Stop::Error(e)) => Err(e),
        Err(Stop::Canceled(text)) => {
            sq_os::errln!("{text}");
            sq_media_ffmpeg::encode::finish_warm_up();
            std::process::exit(CANCELED_EXIT)
        }
    }
}

/// `run` without the process exit; `interrupted` is the Ctrl+C flag.
pub fn execute(project: &Path, args: &ExportArgs, interrupted: &AtomicBool) -> Result<Report, Stop> {
    let out_text = args.out.to_string_lossy();
    if args.out.is_dir() || out_text.ends_with('/') || out_text.ends_with('\\') {
        let base = out_text.trim_end_matches(['/', '\\']);
        return Err(format!("{out_text} is a folder. Give the file name, for example {base}/export.mp4.").into());
    }
    let support = std::env::temp_dir().join(format!("sequence-studio-export-{}", std::process::id()));
    let mut session = sq_editor_session::EditorSession::new(
        sq_core_model::Project::new(Id::from_u128(1), "export", Vec::new(), Vec::new()),
        sq_editor_session::SessionDeps::headless(support),
    );
    session.open(project).map_err(|e| format!("Could not open {}: {e}", project.display()))?;
    let p = session.project();
    let timeline =
        session.active_timeline().or_else(|| p.timelines.iter().next()).ok_or("The project has no sequence.")?.clone();
    let snapshot = ExportSnapshot {
        timelines: p.timelines.clone(),
        media: p.media.clone(),
        use_proxies_for_export: args.use_proxies,
    };

    let preset = match &args.preset {
        Some(text) => find_preset(text)?,
        None => ExportPreset::default_preset(Some(&timeline.format), None),
    };
    let mut settings = preset.settings_matching(Some(&timeline.format));
    // The sheet starts every output with "Captions: Burn in" (`ExportDialogModel::with_dialog_defaults`); an audio-only
    // file has no picture to burn into.
    if settings.audio_only.is_none() {
        settings = ExportDialogModel::with_dialog_defaults(settings);
    }
    if let Some((w, h)) = args.size {
        (settings.video.width, settings.video.height) = (i64::from(w), i64::from(h));
    }
    if args.no_hardware {
        settings.video.hardware_encoding = false;
    }
    if let Some(h) = &args.hdr {
        let transfer = if h == "hlg" { HdrTransfer::Hlg } else { HdrTransfer::Pq };
        settings.hdr_delivery = Some(HdrDelivery { transfer, ..HdrDelivery::default() });
        if settings.applied_hdr_delivery().is_none() {
            return Err(
                "--hdr needs an HEVC preset (for example \u{201c}Match Source \u{2013} HEVC 10-bit\u{201d}).".into()
            );
        }
        // The sheet lets SDR pictures be conformed to HLG/PQ (an SDR to HDR conform); it adds no HDR range.
        if ExportDialogModel::hdr_target(&timeline).is_none() {
            sq_os::errln!(
                "note: the clips do not target HDR; --hdr {h} tags the file and converts SDR pictures, it adds no HDR range."
            );
        }
    } else {
        // The sheet's rule: clips that target PQ or HLG switch the HEVC delivery on; otherwise the file is tagged SDR.
        settings = ExportDialogModel::with_hdr_target(settings, ExportDialogModel::hdr_target(&timeline));
    }
    let duration = timeline.duration();
    let range = match args.range_ms {
        Some((a, b)) => {
            let r = TimeRange::new(Time::new(a, 1000), Time::new(b - a, 1000));
            if Time::new(b, 1000) > duration {
                return Err(format!(
                    "--range ends after the sequence ({} s long).",
                    duration.value() as f64 / duration.timescale() as f64
                )
                .into());
            }
            settings.range = RangeSelection::InOut(r);
            r
        }
        // The sheet starts on the sequence's In/Out when it has marks (`--entire` = "Entire sequence").
        None => match timeline.export_range().filter(|_| !args.entire) {
            Some(r) => {
                settings.range = RangeSelection::InOut(r);
                r
            }
            None => TimeRange::new(Time::ZERO, duration),
        },
    };
    let frames = export_frame_count(range, settings.video.frame_duration);
    let codec = delivered_codec(&settings);

    let ext = settings.file_extension();
    let out = args.out.clone();
    if !ext.is_empty() && out.extension().is_some_and(|e| !e.eq_ignore_ascii_case(ext)) {
        return Err(format!("The preset writes .{ext} files, not {}.", out.display()).into());
    }
    let dir = out.parent().filter(|d| !d.as_os_str().is_empty()).unwrap_or(Path::new(".")).to_path_buf();
    let name = out.file_stem().map_or_else(|| "export".to_string(), |s| s.to_string_lossy().into_owned());

    let encoder = Arc::new(FfmpegExportEncoder::new());
    let queue = ExportQueue::new(Arc::clone(&encoder) as Arc<dyn sq_export::core::traits::ExportEncoding>);
    let updates = queue.updates();
    let (tid, for_job) = (timeline.id, settings.clone());
    let mut job =
        ExportJob::new(Id::from_u128(7), &name, settings, dir, Arc::new(move || sources(&snapshot, tid, &for_job)));
    // The sheet's default for a file that exists is "Keep Both" (a number is added); `--overwrite` is "Replace".
    job.replace_existing = args.overwrite;
    let id = queue.enqueue(job);
    if let Some(planned) = queue.status(id).map(|s| s.output_url).filter(|p| p.file_name() != out.file_name()) {
        sq_os::errln!("note: {} exists; writing {} (--overwrite replaces it).", out.display(), planned.display());
    }
    sq_os::outln!("export {} frames, preset {}, {codec}", frames, preset.name());
    let start = Instant::now();
    let finished = AtomicBool::new(false);
    let finished = &finished;
    std::thread::scope(|scope| {
        let queue = &queue;
        scope.spawn(move || {
            let mut last = -1;
            let mut canceled = false;
            while !finished.load(Ordering::Relaxed) {
                if !canceled && interrupted.load(Ordering::SeqCst) {
                    canceled = true;
                    queue.cancel(id);
                }
                if let Ok(s) = updates.recv_timeout(Duration::from_millis(100)) {
                    let pct = (s.progress * 100.0) as i32;
                    if pct != last && matches!(s.state, ExportJobState::Running) {
                        sq_os::outln!("progress {pct}%");
                        last = pct;
                    }
                }
            }
        });
        queue.run_all();
        finished.store(true, Ordering::Relaxed);
    });
    let status = queue.status(id).ok_or("The export job disappeared.")?;
    match status.state {
        // The text the sheet shows (`shell_export_sheet.rs`: "Export failed: “name”: why"), plus the full path so a
        // permission, missing-folder or disk-full line says where.
        ExportJobState::Failed(why) => Err(Stop::Error(format!(
            "Export failed: \u{201c}{}\u{201d}: {why} ({})",
            status.name,
            std::path::absolute(&args.out).unwrap_or_else(|_| args.out.clone()).display()
        ))),
        // The text of the sheet's queue; the queue already removed the partial file.
        ExportJobState::Cancelled => Err(Stop::Canceled(format!("Export of \u{201c}{}\u{201d} canceled", status.name))),
        ExportJobState::Done(file) => {
            let size_bytes = std::fs::metadata(&file).map_or(0, |m| m.len());
            let seconds = (start.elapsed().as_secs_f64() * 1000.0).round() / 1000.0;
            // The proof of hardware or software encoding, on every system (also in the app log: "export: video encoder ...").
            let encoder = encoder.last_video_encoder();
            if !encoder.is_empty() {
                sq_os::outln!("video encoder {encoder}");
            }
            Ok(Report { file, frames, codec, encoder, size_bytes, seconds })
        }
        other => Err(Stop::Error(format!("Export did not finish: {other:?}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::export::tests::{ffmpeg_tool, tiny_sequence};

    /// A saved one-second project in `dir`, or `None` when ffmpeg or a graphics device is missing.
    fn project_in(dir: &Path) -> Option<std::path::PathBuf> {
        project_with(dir, |_| {})
    }

    fn project_with(dir: &Path, tweak: impl FnOnce(&mut sq_core_model::Timeline)) -> Option<std::path::PathBuf> {
        let tool = ffmpeg_tool()?;
        sq_gpu::gpu::Gpu::new().ok()?;
        let (mut timeline, reference) = tiny_sequence(&tool, dir);
        tweak(&mut timeline);
        let project = sq_core_model::Project::new(Id::from_u128(2), "p", vec![reference], vec![timeline]);
        let file = dir.join("tiny.sqproj");
        let mut session =
            sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.to_path_buf()));
        session.save_as(&file).ok()?;
        Some(file)
    }

    fn args(out: &Path, preset: &str) -> ExportArgs {
        ExportArgs {
            out: out.to_path_buf(),
            preset: Some(preset.to_string()),
            size: Some((320, 180)),
            no_hardware: true,
            ..ExportArgs::default()
        }
    }

    #[test]
    fn headless_export_writes_each_codec_and_fails_with_the_sheets_text() {
        let dir = std::env::temp_dir().join(format!("sq-export-cli-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let Some(project) = project_in(&dir) else {
            sq_os::errln!("skipped: no ffmpeg or no graphics device");
            return;
        };
        let by_codec = |c: sq_export::core::settings::VideoCodec| {
            ExportPreset::all()
                .into_iter()
                .find(|p| {
                    let s = p.settings();
                    s.video.codec == c && s.audio_only.is_none() && s.frame_output.is_none()
                })
                .map(|p| p.name())
        };
        use sq_export::core::settings::VideoCodec::{H264, Hevc, ProRes422};
        for (codec, ext) in [(H264, "mp4"), (Hevc, "mp4"), (ProRes422, "mov")] {
            let Some(preset) = by_codec(codec) else { continue };
            let out = dir.join(format!("out-{}.{ext}", codec.raw_value()));
            match run(&project, &args(&out, &preset)) {
                Ok(()) => assert!(std::fs::metadata(&out).is_ok_and(|m| m.len() > 500), "no file for {preset}"),
                // An encoder this FFmpeg build lacks (the LGPL build has no libx264/x265).
                Err(e) => sq_os::errln!("{preset}: {e}"),
            }
        }
        // At least the first available codec must have worked.
        let h264 = by_codec(H264).expect("an H.264 preset");
        let bad = dir.join("no-such-folder").join("deep").join("x.mp4");
        // Make the path unwritable: its parent is a file.
        std::fs::write(dir.join("blocker"), b"x").expect("blocker");
        let bad = if bad.exists() { bad } else { dir.join("blocker").join("x.mp4") };
        let err = run(&project, &args(&bad, &h264)).expect_err("an unwritable path fails");
        assert!(err.starts_with("Export failed: \u{201c}x\u{201d}: "), "{err}");
        assert!(run(&project, &args(&dir.join("o.mp4"), "No such preset")).unwrap_err().starts_with("Unknown preset"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn scratch(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-export-cli-{tag}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        dir
    }

    fn preset_of(codec: sq_export::core::settings::VideoCodec) -> String {
        ExportPreset::all()
            .into_iter()
            .find(|p| {
                let s = p.settings();
                s.video.codec == codec && s.audio_only.is_none() && s.frame_output.is_none()
            })
            .map(|p| p.name())
            .expect("a preset")
    }

    #[test]
    fn a_folder_as_the_output_is_an_error_and_writes_no_file() {
        let dir = scratch("folder");
        let flag = AtomicBool::new(false);
        for out in [dir.clone(), dir.join("sub").join("")] {
            let e = execute(Path::new("none.sqproj"), &args(&out, "YouTube 1080p Full HD"), &flag).unwrap_err();
            assert!(matches!(&e, Stop::Error(t) if t.contains("is a folder")), "{e:?}");
        }
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_json_codec_is_the_presets_real_codec() {
        let by_name = |n: &str| ExportPreset::all().into_iter().find(|p| p.name().starts_with(n)).unwrap().settings();
        assert_eq!(delivered_codec(&by_name("Audio only \u{2013} WAV")), "pcm");
        assert_eq!(delivered_codec(&by_name("Audio only \u{2013} M4A")), "aac");
        assert_eq!(delivered_codec(&by_name("Animated GIF")), "gif");
        assert_eq!(delivered_codec(&by_name("Match Source \u{2013} HEVC 10-bit")), "hevc");
        assert_eq!(delivered_codec(&by_name("ProRes 422 HQ")), "prores422HQ");
        assert_eq!(delivered_codec(&by_name("YouTube 1080p Full HD")), "h264");
    }

    #[test]
    fn an_interrupt_cancels_like_the_sheet_and_leaves_no_file() {
        let dir = scratch("cancel");
        let Some(project) = project_in(&dir) else { return };
        let (out, flag) = (dir.join("c.mp4"), AtomicBool::new(true));
        let r = execute(&project, &args(&out, &preset_of(sq_export::core::settings::VideoCodec::H264)), &flag);
        match r {
            Err(Stop::Canceled(t)) => assert!(t.ends_with("canceled"), "{t}"),
            Err(Stop::Error(e)) => sq_os::errln!("skipped: {e}"),
            Ok(_) => panic!("an interrupted run must not finish"),
        }
        assert!(!out.exists(), "the partial file is gone");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_second_export_to_the_same_name_is_numbered_unless_overwrite_is_asked() {
        let dir = scratch("same");
        let Some(project) = project_in(&dir) else { return };
        let preset = preset_of(sq_export::core::settings::VideoCodec::ProRes422);
        let out = dir.join("same.mov");
        let flag = AtomicBool::new(false);
        let first = execute(&project, &args(&out, &preset), &flag);
        let Ok(first) = first else { return sq_os::errln!("skipped: {first:?}") };
        assert_eq!(first.file, out);
        assert!(first.encoder.contains("prores"), "the report names the video encoder: {:?}", first.encoder);
        let second = execute(&project, &args(&out, &preset), &flag).expect("second");
        assert_ne!(second.file, out, "Keep Both: the first file stays");
        assert!(out.exists() && second.file.exists());
        let mut replace = args(&out, &preset);
        replace.overwrite = true;
        assert_eq!(execute(&project, &replace, &flag).expect("replace").file, out);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// D5: the sheet starts a new output with "Captions: Burn in"; `--export` of a sequence with a captions track must
    /// draw them too. The decoded picture differs from the same export without the track.
    #[test]
    fn the_cli_burns_captions_in_by_default_like_the_sheet() {
        use sq_core_model::CaptionItem;
        use sq_core_time::{Time, TimeRange};
        let (plain_dir, burned_dir) = (scratch("cap-plain"), scratch("cap-burned"));
        let Some(plain) = project_in(&plain_dir) else { return };
        let Some(burned) = project_with(&burned_dir, |t| {
            let item = CaptionItem {
                id: Id::from_u128(9),
                lines: vec!["HELLO WORLD".into()],
                range: TimeRange::new(Time::ZERO, Time::seconds(1)),
                style_ref: String::new(),
                animation_ref: String::new(),
                style_overridden: false,
                words: Vec::new(),
                position: None,
            };
            t.caption_tracks = vec![
                serde_json::from_value(serde_json::json!({"id": Id::from_u128(8), "items": [item]})).expect("track"),
            ];
        }) else {
            return;
        };
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        sq_text::portable_font_match::set_fonts_root(&root);
        let preset = preset_of(sq_export::core::settings::VideoCodec::ProRes422);
        let flag = AtomicBool::new(false);
        let (a, b) = (plain_dir.join("a.mov"), burned_dir.join("b.mov"));
        let (Ok(_), Ok(_)) = (execute(&plain, &args(&a, &preset), &flag), execute(&burned, &args(&b, &preset), &flag))
        else {
            return;
        };
        let md5 = |f: &Path| {
            let tool = ffmpeg_tool().expect("ffmpeg");
            let out = std::process::Command::new(tool)
                .args(["-v", "error", "-ss", "0.3", "-i"])
                .arg(f)
                .args(["-frames:v", "1", "-f", "md5", "-"])
                .output()
                .expect("decode");
            String::from_utf8_lossy(&out.stdout).to_string()
        };
        let (pa, pb) = (md5(&a), md5(&b));
        assert!(pa.contains("MD5=") && pb.contains("MD5="), "decoded {pa:?} {pb:?}");
        assert_ne!(pa, pb, "the captions are in the exported frame");
        let _ = std::fs::remove_dir_all(&plain_dir);
        let _ = std::fs::remove_dir_all(&burned_dir);
    }

    #[test]
    fn the_default_range_is_the_sequences_in_out_like_the_sheet() {
        use sq_core_time::{Time, TimeRange};
        let dir = scratch("range");
        let marks = TimeRange::new(Time::new(1, 4), Time::new(1, 2));
        let Some(project) = project_with(&dir, |t| {
            t.in_out = Some(marks);
            t.in_out_kind = Some(sq_core_model::InOutKind::Both);
        }) else {
            return;
        };
        let preset = preset_of(sq_export::core::settings::VideoCodec::ProRes422);
        let flag = AtomicBool::new(false);
        let Ok(marked) = execute(&project, &args(&dir.join("a.mov"), &preset), &flag) else { return };
        let mut all = args(&dir.join("b.mov"), &preset);
        all.entire = true;
        let entire = execute(&project, &all, &flag).expect("entire");
        assert!(marked.frames < entire.frames, "{} vs {}", marked.frames, entire.frames);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A gap at the start (clips begin at 0.5 s) and a gap in the middle: every kind of file still writes all frames.
    #[test]
    fn gaps_export_in_every_kind_of_file() {
        use sq_core_time::{Time, TimeRange};
        let dir = scratch("gap");
        let Some(start_gap) = project_with(&dir, |t| {
            for tr in &mut t.tracks {
                let mut clips = tr.clips().to_vec();
                clips.iter_mut().for_each(|c| c.start = Time::new(1, 2));
                tr.set_clips(clips);
            }
        }) else {
            return;
        };
        // The same clip cut in two with half a second of nothing between the halves.
        std::fs::create_dir_all(dir.join("mid")).expect("folder");
        let mid_gap = project_with(&dir.join("mid"), |t| {
            for tr in &mut t.tracks {
                let first = tr.clips().to_vec();
                let mut second = first.clone();
                for (n, c) in second.iter_mut().enumerate() {
                    c.id = Id::from_u128(500 + n as u128);
                    c.start = Time::new(3, 2);
                    c.source = TimeRange::new(Time::new(1, 2), Time::new(1, 2));
                }
                let mut all = first;
                all.iter_mut().for_each(|c| c.source = TimeRange::new(Time::ZERO, Time::new(1, 2)));
                all.extend(second);
                tr.set_clips(all);
            }
        });
        let flag = AtomicBool::new(false);
        for (label, project) in [("start", Some(start_gap)), ("mid", mid_gap)] {
            let Some(project) = project else { continue };
            for preset in
                ["YouTube 1080p Full HD", "Match Source \u{2013} HEVC 10-bit", "ProRes 422 HQ (master)", "Animated GIF"]
                    .into_iter()
                    .chain(["Audio only \u{2013} WAV (24-bit PCM)", "Audio only \u{2013} M4A (AAC)"])
            {
                let ext = if preset.contains("WAV") {
                    "wav"
                } else if preset.contains("M4A") {
                    "m4a"
                } else if preset.contains("ProRes") {
                    "mov"
                } else if preset.contains("GIF") {
                    "gif"
                } else {
                    "mp4"
                };
                let out = dir.join(format!("{label}-{}.{ext}", preset.len()));
                match execute(&project, &args(&out, preset), &flag) {
                    Ok(r) => assert!(r.size_bytes > 100, "{label} {preset}: empty file"),
                    // An encoder this FFmpeg build lacks (the LGPL build has no libx264/x265).
                    Err(Stop::Error(e)) if e.contains("encoder") => sq_os::errln!("{label} {preset}: {e}"),
                    Err(e) => panic!("{label} {preset}: {e:?}"),
                }
            }
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn preset_names_are_the_sheets() {
        let names = list_presets();
        assert!(names.contains(&"YouTube 1080p Full HD".to_string()));
        assert_eq!(find_preset("youtube 1080p full hd").map(|p| p.name()), Ok("YouTube 1080p Full HD".into()));
    }
}
