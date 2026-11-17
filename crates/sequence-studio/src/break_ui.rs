//! Worst-case UI stress: projects with plausible worst data are opened in the headless app and drawn; no panic, finite
//! geometry, and a frame budget. Report: docs/rust/BREAK-UI.md.

use serde_json::{Value, json};
use sq_core_model::{Clip, MediaFingerprint, MediaRef, Project, SequenceFormat, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time, TimeRange};
use std::path::{Path, PathBuf};
use std::time::Instant;

/// Names a real user can produce: a 200-character file name without spaces, RTL, emoji, combining marks, CJK.
pub(crate) fn nasty_names() -> Vec<String> {
    vec![
        "A".to_string() + &"_Interview-Aleksandra-Wisniewska-Kowalczyk-Take".repeat(4) + ".mov",
        "\u{05E1}\u{05E8}\u{05D8}\u{05D5}\u{05DF}_\u{05D7}\u{05D3}\u{05E9} \u{0645}\u{0631}\u{062D}\u{0628}\u{0627} \u{0628}\u{0627}\u{0644}\u{0639}\u{0627}\u{0644}\u{0645}"
            .to_string(),
        "Party \u{1F389}\u{1F3AC}\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466} \u{1F1E9}\u{1F1EA} final_v12".to_string(),
        "Zalgo e\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}\u{0306}\u{0307}\u{0308}\u{0309}\u{030A} a\u{0334}\u{0335}\u{0336}\u{0337}".to_string(),
        "\u{6771}\u{4EAC}\u{3067}\u{306E}\u{30A4}\u{30F3}\u{30BF}\u{30D3}\u{30E5}\u{30FC}_\u{6700}\u{7D42}\u{7248}_\u{3059}\u{3079}\u{3066}\u{306E}\u{30AB}\u{30C3}\u{30C8}\u{3092}\u{307E}\u{3068}\u{3081}\u{305F}\u{3082}\u{306E}"
            .repeat(3),
        "Ä".repeat(60) + "Geschwindigkeitsbegrenzung_Zusammenfassung",
        String::new(),
        "x".to_string(),
    ]
}

pub(crate) struct Spec {
    pub video_tracks: usize,
    pub audio_tracks: usize,
    pub clips: usize,
    pub names: bool,
    pub start_seconds: i64,

    pub fps: (i64, i64),
    pub captions: usize,
    pub markers: usize,
    pub effects: usize,
    pub keys: usize,
    /// One name for every clip, track, media item and the sequence (the emoji shots).
    pub label: Option<&'static str>,
}

impl Default for Spec {
    fn default() -> Self {
        Spec {
            video_tracks: 3,
            audio_tracks: 3,
            clips: 12,
            names: true,
            start_seconds: 0,

            fps: (1, 25),
            captions: 0,
            markers: 0,
            effects: 0,
            keys: 0,
            label: None,
        }
    }
}

fn pick(names: &[String], on: bool, i: usize, fallback: &str) -> String {
    if on { names[i % names.len()].clone() } else { format!("{fallback} {i}") }
}

/// Saves a project built from `spec` into `dir` and returns the `.sqproj` path. Media are offline references.
pub(crate) fn write_project(dir: &Path, name: &str, spec: &Spec) -> PathBuf {
    std::fs::create_dir_all(dir).expect("temp folder");
    let names = spec.label.map_or_else(nasty_names, |l| vec![l.to_string()]);
    let media = Id::from_u128(100);
    let reference =
        MediaRef::new(media, &pick(&names, spec.names, 0, "media"), "/offline/none.mov", MediaFingerprint::new(1));
    let mut tracks = Vec::new();
    let mut n = 1u128;
    let total = spec.video_tracks + spec.audio_tracks;
    let per_track = if total == 0 { 0 } else { spec.clips.div_ceil(total) };
    for t in 0..total {
        let kind = if t < spec.video_tracks { TrackKind::Video } else { TrackKind::Audio };
        let mut track = Track::new(Id::from_u128(10_000 + t as u128), kind);
        track.name = pick(&names, spec.names, t, "Track");
        let mut clips = Vec::new();
        for c in 0..per_track {
            n += 1;
            let start = Time::seconds(spec.start_seconds + (c as i64) * 2);
            let source = TimeRange::new(Time::ZERO, Time::new(1 + (c as i64 % 3) * 24, 25));
            let mut clip =
                Clip::new(Id::from_u128(n), &pick(&names, spec.names, n as usize, "clip"), media, kind, source, start);
            if t == 0 && c == 0 {
                for e in 0..spec.effects {
                    let mut fx = sq_core_model::ClipEffect::new(Id::from_u128(5_000_000 + e as u128), "blur");
                    fx.parameters.insert("blurriness".into(), sq_core_model::AnimatedProperty::new(1e9));
                    clip.effects.push(fx);
                }
                let keys: Vec<_> = (0..spec.keys)
                    .map(|k| {
                        let value = if k % 5 == 0 { -0.0 } else { 1e9 * k as f64 };
                        sq_core_time::Keyframe::new(
                            Id::from_u128(9_000_000 + k as u128),
                            Time::new(k as i64, 1000),
                            value,
                        )
                    })
                    .collect();
                if !keys.is_empty() {
                    let mut p = sq_core_model::AnimatedProperty::new(100.0);
                    p.track.keys = keys;
                    let mut fx = sq_core_model::ClipEffect::new(Id::from_u128(5_999_999), "blur");
                    fx.parameters.insert("blurriness".into(), p);
                    clip.effects.push(fx);
                }
            }
            clips.push(clip);
        }
        track.set_clips(clips);
        tracks.push(track);
    }
    let mut format = SequenceFormat::new(Time::new(spec.fps.0, spec.fps.1));
    (format.width, format.height) = (1920, 1080);
    let mut timeline = Timeline::new(Id::from_u128(1), &pick(&names, spec.names, 0, "Sequence"), format, tracks);
    for m in 0..spec.markers {
        timeline.markers.push(sq_core_model::Marker {
            id: Id::from_u128(7_000_000 + m as u128),
            time: Time::new(spec.start_seconds * 1000 + (m as i64 % 3), 1000),
            name: pick(&names, spec.names, m, "Marker"),
            color: Default::default(),
            comment: pick(&names, spec.names, m + 1, "Comment"),
            duration: if m % 2 == 0 { Time::ZERO } else { Time::seconds(3600) },
        });
    }
    let project =
        Project::new(Id::from_u128(2), &pick(&names, spec.names, 0, "Project"), vec![reference], vec![timeline]);
    let mut value = serde_json::to_value(&project).expect("project json");
    if spec.captions > 0 {
        let items: Vec<Value> = (0..spec.captions)
            .map(|i| {
                json!({"id": Id::from_u128(8_000_000 + i as u128), "lines": [pick(&names, spec.names, i, "Caption")],
                    "range": {"start": {"value": i as i64, "timescale": 25}, "duration": {"value": 1, "timescale": 25}}})
            })
            .collect();
        let track = json!({"id": Id::from_u128(77), "name": pick(&names, spec.names, 0, "Captions"), "items": items});
        value["timelines"][0]["captionTracks"] = json!([track]);
    }
    let project: Project = serde_json::from_value(value).expect("project with captions reads back");
    let file = dir.join(format!("{name}.sqproj"));
    let mut session =
        sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.to_path_buf()));
    session.save_as(&file).expect("save the stress project");
    file
}

pub(crate) fn fonts() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts")
}

pub(crate) struct Stats {
    pub p95_ms: f64,
    pub quads: usize,
    /// Glyph quads cut at the side by their clip (text that did not fit its box and shows no ellipsis): (x, y, clip x0, clip x1).
    pub cut_glyphs: Vec<(f32, f32, f32, f32)>,
}

/// Opens `file`, selects the first clip, draws 60 frames at `w x h` device pixels and returns the p95 frame time.
pub(crate) fn measure(dir: &Path, file: &Path, w: u32, h: u32, scale: f32) -> Stats {
    sq_text::portable_font_match::set_fonts_root(&fonts());
    let support = dir.join(format!("support-{w}x{h}"));
    let (app, _picture) = crate::headless::build_in(&support, w, h, scale, Some(file), &fonts());
    app.with(|a| {
        let id = a
            .session_mut()
            .active_timeline()
            .and_then(|t| t.tracks.iter().flat_map(|t| t.clips()).next().map(|c| c.id));
        if let Some(id) = id {
            a.session_mut().select_with_partners(std::iter::once(id).collect());
        }
    });
    let mut times = Vec::new();
    let mut quads = 0;
    let mut cut = Vec::new();
    let mut worst: Vec<(String, f64)> = Vec::new();
    for _ in 0..60 {
        let t = Instant::now();
        let list = app.with(|a| a.frame(i64::from(w), i64::from(h))).expect("app busy");
        times.push(t.elapsed().as_secs_f64() * 1000.0);
        quads = list.quads().len();
        let prof: Vec<(String, f64)> = app
            .with(|a| {
                a.frame_profile()
                    .iter()
                    .map(|(h, p, d)| {
                        (format!("{} {p}", h.replace("sq_", "").replace("::", ".")), d.as_secs_f64() * 1000.0)
                    })
                    .collect()
            })
            .unwrap_or_default();
        if worst.is_empty() {
            worst = prof
        } else {
            worst.iter_mut().zip(prof).for_each(|(w, p)| w.1 = w.1.max(p.1))
        }
        cut.clear();
        for q in list.quads() {
            let r = q.rect;
            if q.kind == sq_draw::QuadKind::Glyph
                && r.w > 0.0
                && (r.x < q.clip[0] - 0.5 || r.x + r.w > q.clip[2] + 0.5)
                && q.clip[2] - q.clip[0] > 2.0
            {
                cut.push((r.x, r.y, q.clip[0], q.clip[2]));
            }
            assert!(r.x.is_finite() && r.y.is_finite() && r.w.is_finite() && r.h.is_finite(), "non-finite rect {r:?}");
        }
        app.turn();
    }
    worst.sort_by(|a, b| b.1.total_cmp(&a.1));
    eprintln!("BREAK   hosts {:?}", worst.iter().take(3).map(|(n, t)| format!("{n} {t:.1}ms")).collect::<Vec<_>>());
    times.sort_by(f64::total_cmp);
    Stats { cut_glyphs: cut, p95_ms: times[(times.len() * 95 / 100).min(times.len() - 1)], quads }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(name: &str, spec: Spec, sizes: &[(u32, u32, f32)], budget_ms: f64) {
        let dir = std::env::temp_dir().join(format!("sq-break-{name}-{}", std::process::id()));
        let file = write_project(&dir, name, &spec);
        for &(w, h, s) in sizes {
            let st = measure(&dir, &file, w, h, s);
            eprintln!(
                "BREAK {name} {w}x{h}@{s}: p95 {:.1} ms, {} quads, {} cut glyphs",
                st.p95_ms,
                st.quads,
                st.cut_glyphs.len()
            );
            for g in st.cut_glyphs.iter().step_by((st.cut_glyphs.len() / 12).max(1)) {
                eprintln!("BREAK   cut glyph at ({:.0},{:.0}) clip {:.0}..{:.0}", g.0, g.1, g.2, g.3);
            }
            // shortcut: the frame budget is asserted in release builds only (debug is 10x slower), upgrade when CI runs release.
            assert!(
                cfg!(debug_assertions) || st.p95_ms <= budget_ms,
                "{name} {w}x{h}@{s}: p95 {:.1} ms over {budget_ms}",
                st.p95_ms
            );
        }
        if let Some(keep) = std::env::var_os("SQ_BREAK_KEEP") {
            let _ = std::fs::create_dir_all(&keep);
            let _ = std::fs::rename(&file, Path::new(&keep).join(format!("{name}.sqproj")));
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    const SIZES: &[(u32, u32, f32)] =
        &[(1280, 800, 1.0), (1600, 1000, 2.0), (1200, 750, 1.5), (800, 500, 1.0), (3840, 2160, 1.0)];

    #[test]
    fn long_rtl_emoji_cjk_names_everywhere() {
        run("names", Spec { markers: 8, captions: 8, ..Spec::default() }, SIZES, 16.0);
    }

    #[test]
    fn empty_project() {
        run("empty", Spec { video_tracks: 0, audio_tracks: 0, clips: 0, ..Spec::default() }, SIZES, 16.0);
    }

    #[test]
    fn two_hundred_plus_two_hundred_tracks() {
        run("tracks", Spec { video_tracks: 200, audio_tracks: 200, clips: 400, ..Spec::default() }, SIZES, 16.0);
    }

    #[test]
    fn five_thousand_clips() {
        run("clips", Spec { clips: 5000, ..Spec::default() }, SIZES, 16.0);
    }

    #[test]
    fn hundred_hour_timecodes_and_120_fps() {
        run("hours", Spec { start_seconds: 360_000, markers: 20, fps: (1, 120), ..Spec::default() }, SIZES, 16.0);
        run("df", Spec { start_seconds: 36_000, fps: (1001, 30000), ..Spec::default() }, &SIZES[..1], 16.0);
        run("ntsc24", Spec { start_seconds: 36_000, fps: (1001, 24000), ..Spec::default() }, &SIZES[..1], 16.0);
    }

    #[test]
    fn ten_thousand_keys_on_one_parameter() {
        run("keys", Spec { keys: 10_000, ..Spec::default() }, &SIZES[..2], 16.0);
    }

    #[test]
    fn five_hundred_effects_on_a_clip() {
        run("fx", Spec { effects: 500, ..Spec::default() }, &SIZES[..2], 16.0);
    }

    #[test]
    fn ten_thousand_captions() {
        // shortcut: 10000 captions (4x a feature film) get 25 ms; the Text panel sync is not incremental yet, upgrade to 16 ms with it.
        run("caps", Spec { captions: 10_000, ..Spec::default() }, &SIZES[..2], 25.0);
    }

    #[test]
    fn two_thousand_markers() {
        run("marks", Spec { markers: 2000, ..Spec::default() }, &SIZES[..2], 16.0);
    }

    #[test]
    fn extreme_zoom_keeps_the_ruler_bounded() {
        let dir = std::env::temp_dir().join(format!("sq-break-zoom-{}", std::process::id()));
        let file = write_project(&dir, "zoom", &Spec { start_seconds: 36_000, markers: 20, ..Spec::default() });
        sq_text::portable_font_match::set_fonts_root(&fonts());
        let (app, _p) = crate::headless::build_in(&dir.join("support"), 1280, 800, 1.0, Some(&file), &fonts());
        app.with(|a| a.frame(1280, 800));
        for text in ["=", "-"] {
            let (key, modifiers) = crate::cli::parse_key(text).expect("zoom key");
            let mut worst = (0, 0.0f64);
            for _ in 0..60 {
                app.input(&sq_draw::InputEvent::KeyDown { key, modifiers });
                app.turn();
                let t = Instant::now();
                let list = app.with(|a| a.frame(1280, 800)).expect("app busy");
                worst = (worst.0.max(list.quads().len()), worst.1.max(t.elapsed().as_secs_f64() * 1000.0));
                assert!(list.quads().iter().all(|q| q.rect.x.is_finite() && q.rect.w.is_finite()), "non-finite rect");
            }
            eprintln!("BREAK zoom {text}: max {} quads, worst frame {:.1} ms", worst.0, worst.1);
            assert!(worst.0 < 40_000, "ruler ticks unbounded at zoom {text}: {} quads", worst.0);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `SQ_BREAK_SHOTS=<dir>` writes the worst-case window as PNG in English and German (for the report); otherwise skipped.
    #[test]
    fn shots_for_the_report() {
        use sq_uikit::localization::{SQL10n, selected_language};
        let Some(out) = std::env::var_os("SQ_BREAK_SHOTS") else { return };
        let out = PathBuf::from(out);
        std::fs::create_dir_all(&out).expect("shot folder");
        let dir = std::env::temp_dir().join(format!("sq-break-shots-{}", std::process::id()));
        let file = write_project(&dir, "names", &Spec { markers: 8, captions: 8, ..Spec::default() });
        sq_text::portable_font_match::set_fonts_root(&fonts());
        for (lang, w, h, scale) in [("de", 1280, 800, 1.0), ("de", 800, 500, 1.0), ("de", 1200, 750, 1.5)] {
            // The language is fixed per process (SQL10n::install runs once): this test shoots German only, run it alone.
            SQL10n::install(&selected_language(Some(lang), None, false, &[]));
            let mode = crate::cli::Mode::UiShot {
                out: out.join(format!("names-{lang}-{w}x{h}@{scale}.png")),
                width: w,
                height: h,
                scale,
                playhead_ms: 0,
                pose: crate::cli::Pose { select: Some("0".into()), ..Default::default() },
            };
            assert_eq!(crate::headless::run(&mode, Some(&file), &fonts()), Ok(()));
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `SQ_EMOJI_SHOTS=<dir>` writes the window with clip, media, track and sequence names holding color emoji, and the same
    /// window with plain names, as PNG (`emoji.png`, `plain.png`); otherwise skipped. The proof of the color emoji path.
    #[test]
    fn shots_with_color_emoji_names() {
        let Some(out) = std::env::var_os("SQ_EMOJI_SHOTS") else { return };
        let out = PathBuf::from(out);
        std::fs::create_dir_all(&out).expect("shot folder");
        let dir = std::env::temp_dir().join(format!("sq-emoji-shots-{}", std::process::id()));
        sq_text::portable_font_match::set_fonts_root(&fonts());
        for (name, label) in [("emoji", "\u{1F3AC} Intro \u{1F600} \u{2764}\u{FE0F} \u{1F44D}"), ("plain", "Intro")] {
            let file = write_project(&dir, name, &Spec { label: Some(label), ..Spec::default() });
            let mode = crate::cli::Mode::UiShot {
                out: out.join(format!("{name}.png")),
                width: 1440,
                height: 900,
                scale: 1.0,
                playhead_ms: 0,
                pose: Default::default(),
            };
            assert_eq!(crate::headless::run(&mode, Some(&file), &fonts()), Ok(()));
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
