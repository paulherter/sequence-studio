//! `--perf-project <out.sqproj> --media <folder>`: the fixed "many layers" test project for the playback numbers
//! (docs/rust/PERF-NOTES.md, "Many layers (perf-layers)"). Reproducible: ids, times and values are fixed in code, the
//! pictures come from `scripts/perf-media.sh` (never committed). Writes the full project and one copy per heavy element
//! switched off (`-no-blur`, `-no-shadow`, `-no-motion-blur`, `-no-dissolve`, `-no-4k`) beside it, all over the same media.

use serde_json::json;
use sq_core_model::{
    AnimatedProperty, Clip, ClipEffect, MediaRef, Project, SequenceFormat, Timeline, Track, TrackKind, Transition,
};
use sq_core_time::{EaseHandle, Id, Interpolation, Keyframe, KeyframeTrack, Time, TimeRange, Vec2};
use sq_editor_session::ImportBackend;
use sq_text::text_generator::TextGenerator;
use sq_text::text_style::TextStyle;
use sq_text::text_template::TextTemplate;
use std::path::{Path, PathBuf};

/// The media files of the project, in the order `project` takes them. `scripts/perf-media.sh` makes them.
pub const MEDIA: [&str; 7] =
    ["pl-4k-hevc.mp4", "pl-v2a.mp4", "pl-v2b.mp4", "pl-v3.mp4", "pl-v4.mp4", "pl-music.m4a", "pl-voice.m4a"];

/// Length of the sequence in seconds.
const SECONDS: i64 = 20;
/// Sequence frame rate.
const FPS: i64 = 30;

/// Heavy elements left out of a copy of the project.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Without {
    /// Both Blur effects.
    pub blur: bool,
    /// The Drop Shadow of the picture-in-picture layer.
    pub shadow: bool,
    /// The shutter of the flying layer.
    pub motion_blur: bool,
    /// The Cross Dissolve (a hard cut stays).
    pub dissolve: bool,
    /// The 4K HEVC background (its Blur goes with it).
    pub hevc: bool,
}

impl Without {
    /// The full project and the five copies, each with its file name suffix.
    pub const VARIANTS: [(&'static str, Without); 6] = [
        ("", Without { blur: false, shadow: false, motion_blur: false, dissolve: false, hevc: false }),
        ("-no-blur", Without { blur: true, shadow: false, motion_blur: false, dissolve: false, hevc: false }),
        ("-no-shadow", Without { blur: false, shadow: true, motion_blur: false, dissolve: false, hevc: false }),
        ("-no-motion-blur", Without { blur: false, shadow: false, motion_blur: true, dissolve: false, hevc: false }),
        ("-no-dissolve", Without { blur: false, shadow: false, motion_blur: false, dissolve: true, hevc: false }),
        ("-no-4k", Without { blur: false, shadow: false, motion_blur: false, dissolve: false, hevc: true }),
    ];
}

fn id(n: u128) -> Id {
    Id::from_u128(n)
}

fn frames(n: i64) -> Time {
    Time::new(n, FPS)
}

fn secs(n: i64) -> Time {
    Time::seconds(n)
}

/// A video clip of `media` (`seconds` from `from`) at `start`, with the media's length recorded for the handles.
fn clip(n: u128, name: &str, media: &MediaRef, kind: TrackKind, from: Time, seconds: i64, start: Time) -> Clip {
    let mut c = Clip::new(id(n), name, media.id, kind, TimeRange::new(from, secs(seconds)), start);
    c.media_duration = media.duration;
    c
}

fn effect(n: u128, kind: &str, set: &[(&str, f64)]) -> ClipEffect {
    let mut e = ClipEffect::new(id(n), kind);
    e.parameters = ClipEffect::default_parameters(kind);
    e.colors = ClipEffect::default_colors(kind);
    e.points = ClipEffect::default_points(kind);
    for (key, value) in set {
        e.parameters.insert((*key).to_string(), AnimatedProperty::new(*value));
    }
    e
}

fn blur(n: u128, amount: f64) -> ClipEffect {
    effect(n, ClipEffect::GAUSSIAN_BLUR_KIND, &[(ClipEffect::BLURRINESS_KEY, amount)])
}

fn track(n: u128, kind: TrackKind, name: &str, clips: Vec<Clip>) -> Track {
    let mut t = Track::new(id(n), kind);
    t.name = name.to_string();
    t.set_clips(clips);
    t
}

/// The flying layer's position: a swoosh every 1.5 s between the two sides, eased, never at rest.
fn swoosh() -> AnimatedProperty<Vec2> {
    let ease = EaseHandle { dx: 0.42, dy: 0.0 };
    let keys = (0..=13_i64)
        .map(|i| {
            let side = if i % 2 == 0 { -1.0 } else { 1.0 };
            let mut k = Keyframe::new(id(3000 + i as u128), Time::new(3 * i, 2), Vec2::new(side * 620.0, side * 220.0));
            k.interpolation = Interpolation::Bezier;
            (k.in_handle, k.out_handle) = (ease, ease);
            k
        })
        .collect();
    AnimatedProperty { value: Vec2::new(-620.0, -220.0), track: KeyframeTrack::with_keys(keys) }
}

fn cross_dissolve(out: Id, incoming: Id) -> Result<Transition, String> {
    serde_json::from_value(json!({
        "id": id(700), "kind": "crossDissolve", "alignment": "center",
        "duration": {"value": 2 * FPS, "timescale": FPS}, "customBefore": {"value": 0, "timescale": 1},
        "outgoing": out, "incoming": incoming,
    }))
    .map_err(|e| format!("cross dissolve: {e}"))
}

/// The project over `media` (in `MEDIA` order, each with its probed length) without the elements in `without`.
/// Five video layers, bottom to top: a 4K HEVC background under Blur; a 1080p clip pair with a 2 s Cross Dissolve at 70 %
/// opacity under Blur; a scaled-down picture-in-picture with a Drop Shadow; a layer flying in from side to side with
/// position keyframes and Motion Blur (shutter 180 degrees); a title. Music and voice on two audio tracks.
pub fn project(media: &[MediaRef; 7], without: Without) -> Result<Project, String> {
    let [hevc, v2a, v2b, v3, v4, music, voice] = media;
    let video = TrackKind::Video;

    let mut background = clip(10, "4K HEVC background", hevc, video, Time::ZERO, SECONDS, Time::ZERO);
    background.animation.scale.value = Vec2::new(0.5, 0.5);
    if !without.blur {
        background.effects.push(blur(500, 40.0));
    }

    // The second half starts one second into its file so the dissolve (9 s to 11 s) has frames on both sides.
    let mut first = clip(11, "Layer A", v2a, video, Time::ZERO, 10, Time::ZERO);
    let mut second = clip(12, "Layer B", v2b, video, secs(1), 10, secs(10));
    for (c, n) in [(&mut first, 501), (&mut second, 502)] {
        c.animation.opacity.value = 0.7;
        if !without.blur {
            c.effects.push(blur(n, 12.0));
        }
    }
    let mut middle = track(901, video, "V2", vec![first.clone(), second.clone()]);
    if !without.dissolve {
        middle.transitions.push(cross_dissolve(first.id, second.id)?);
    }

    let mut inset = clip(13, "Picture in picture", v3, video, Time::ZERO, SECONDS, Time::ZERO);
    inset.animation.scale.value = Vec2::new(0.35, 0.35);
    inset.animation.position.value = Vec2::new(-560.0, 280.0);
    if !without.shadow {
        let shadow = [
            (ClipEffect::SHADOW_OPACITY_KEY, 75.0),
            (ClipEffect::SHADOW_DIRECTION_KEY, 135.0),
            (ClipEffect::SHADOW_DISTANCE_KEY, 24.0),
            (ClipEffect::SHADOW_SOFTNESS_KEY, 40.0),
        ];
        inset.effects.push(effect(503, ClipEffect::DROP_SHADOW_KIND, &shadow));
    }

    let mut flyer = clip(14, "Flying layer", v4, video, Time::ZERO, SECONDS, Time::ZERO);
    flyer.animation.scale.value = Vec2::new(0.45, 0.45);
    flyer.animation.position = swoosh();
    if !without.motion_blur {
        flyer.animation.shutter_angle.value = 180.0;
    }

    let template = TextTemplate::new("Title", "PERF LAYERS 1080p30", TextStyle { size: 110.0, ..TextStyle::default() });
    let mut title = Clip::new(id(15), "Title", id(115), video, TimeRange::new(Time::ZERO, secs(SECONDS)), Time::ZERO);
    title.generator = Some(TextGenerator::make_ref(&template, None).map_err(|e| format!("title: {e}"))?);
    title.animation.position.value = Vec2::new(0.0, 380.0);

    let sound = |n: u128, name: &str, m: &MediaRef| clip(n, name, m, TrackKind::Audio, Time::ZERO, SECONDS, Time::ZERO);
    let tracks = vec![
        track(900, video, "V1", if without.hevc { Vec::new() } else { vec![background] }),
        middle,
        track(902, video, "V3", vec![inset]),
        track(903, video, "V4", vec![flyer]),
        track(904, video, "V5", vec![title]),
        track(910, TrackKind::Audio, "A1 music", vec![sound(20, "Music", music)]),
        track(911, TrackKind::Audio, "A2 voice", vec![sound(21, "Voice", voice)]),
    ];
    let timeline = Timeline::new(id(2), "perf-layers", SequenceFormat::new(frames(1)), tracks);
    Ok(Project::new(id(1), "perf-layers", media.to_vec(), vec![timeline]))
}

/// Probes the files of `MEDIA` in `folder` (fixed ids 101...107, the folder's absolute paths).
pub fn probe_media(folder: &Path) -> Result<[MediaRef; 7], String> {
    let folder = sq_os::paths::canonical(folder).map_err(|e| format!("{}: {e}", folder.display()))?;
    let probe = crate::probe::FfmpegProbe::default();
    let mut refs = Vec::new();
    for (n, name) in MEDIA.iter().enumerate() {
        let path = folder.join(name);
        if !path.is_file() {
            return Err(format!("{} is missing: run scripts/perf-media.sh {}", path.display(), folder.display()));
        }
        let mut m = probe.probe(&path).map_err(|e| format!("{}: {e:?}", path.display()))?;
        m.id = id(101 + n as u128);
        refs.push(m);
    }
    refs.try_into().map_err(|_| "media count".to_string())
}

/// Writes the project and its five copies; returns the paths written.
pub fn write_all(out: &Path, folder: &Path) -> Result<Vec<PathBuf>, String> {
    let media = probe_media(folder)?;
    let stem = out.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = out.extension().map(|e| e.to_string_lossy().into_owned()).unwrap_or_else(|| "sqproj".into());
    let mut written = Vec::new();
    for (suffix, without) in Without::VARIANTS {
        let path = out.with_file_name(format!("{stem}{suffix}.{ext}"));
        sq_core_project::project_file::project_file()
            .write(&project(&media, without)?, &path)
            .map_err(|e| format!("{}: {e:?}", path.display()))?;
        written.push(path);
    }
    Ok(written)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::MediaFingerprint;

    fn media() -> [MediaRef; 7] {
        let seconds = [22, 12, 12, 22, 22, 22, 22];
        std::array::from_fn(|n| {
            let path = format!("/m/{}", MEDIA[n]);
            let mut m = MediaRef::new(id(101 + n as u128), MEDIA[n], &path, MediaFingerprint::new(1));
            m.duration = Some(secs(seconds[n]));
            m
        })
    }

    fn effect_kinds(p: &Project) -> Vec<String> {
        p.timelines[0]
            .tracks
            .iter()
            .flat_map(|t| t.clips())
            .flat_map(|c| c.effects.iter().map(|e| e.kind.clone()))
            .collect()
    }

    #[test]
    fn the_full_project_has_every_heavy_element() {
        let p = project(&media(), Without::default()).expect("project");
        let t = &p.timelines[0];
        let video = t.tracks.iter().filter(|t| t.kind == TrackKind::Video).count();
        assert_eq!((video, t.tracks.len() - video), (5, 2), "five picture layers, music and voice");
        let kinds = effect_kinds(&p);
        assert_eq!(
            kinds.iter().filter(|k| *k == ClipEffect::GAUSSIAN_BLUR_KIND).count(),
            3,
            "background and both halves of V2"
        );
        assert_eq!(kinds.iter().filter(|k| *k == ClipEffect::DROP_SHADOW_KIND).count(), 1);
        assert_eq!(t.tracks[1].transitions.len(), 1, "the Cross Dissolve");
        let flyer = &t.tracks[3].clips()[0];
        assert!(flyer.animation.position.is_animated() && flyer.animation.shutter_angle.value == 180.0);
        assert!(t.tracks[4].clips()[0].generator.is_some(), "the title");
    }

    #[test]
    fn each_copy_loses_exactly_its_element() {
        let full = project(&media(), Without::default()).expect("project");
        let blur = |p: &Project| effect_kinds(p).iter().filter(|k| *k == ClipEffect::GAUSSIAN_BLUR_KIND).count();
        let shadow = |p: &Project| effect_kinds(p).iter().filter(|k| *k == ClipEffect::DROP_SHADOW_KIND).count();
        let dissolve = |p: &Project| p.timelines[0].tracks[1].transitions.len();
        let shutter = |p: &Project| p.timelines[0].tracks[3].clips()[0].animation.shutter_angle.value;
        for (suffix, without) in Without::VARIANTS {
            let p = project(&media(), without).expect("project");
            let (b, s, d, m) = (blur(&p), shadow(&p), dissolve(&p), shutter(&p));
            let background = p.timelines[0].tracks[0].clips().len();
            assert_eq!(background, if without.hevc { 0 } else { 1 }, "{suffix} 4K layer");
            let kept_blur = blur(&full) - usize::from(without.hevc);
            assert_eq!(b, if without.blur { 0 } else { kept_blur }, "{suffix} blur");
            assert_eq!(s, if without.shadow { 0 } else { 1 }, "{suffix} shadow");
            assert_eq!(d, if without.dissolve { 0 } else { 1 }, "{suffix} dissolve");
            assert_eq!(m, if without.motion_blur { 0.0 } else { 180.0 }, "{suffix} motion blur");
        }
    }

    #[test]
    fn the_dissolve_has_frames_on_both_sides_and_the_file_round_trips() {
        let p = project(&media(), Without::default()).expect("project");
        let dir = std::env::temp_dir().join(format!("sq-perf-project-{}", std::process::id()));
        let path = dir.join("perf-layers.sqproj");
        sq_core_project::project_file::project_file().write(&p, &path).expect("write");
        let back = sq_core_project::project_file::project_file().read(&path).expect("read");
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(back.timelines[0].tracks[1].transitions, p.timelines[0].tracks[1].transitions);
        assert_eq!(
            back.timelines[0].tracks[3].clips()[0].animation.position,
            p.timelines[0].tracks[3].clips()[0].animation.position
        );
        let b = &back.timelines[0].tracks[1].clips()[1];
        assert!(b.source.start >= secs(1), "one second of media before the cut for the dissolve");
    }
}
