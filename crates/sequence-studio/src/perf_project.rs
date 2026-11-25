//! `--perf-project <out.sqproj> --media <folder>`: the fixed "many layers" test project for the playback numbers
//! (docs/rust/PERF-NOTES.md, "Many layers (perf-layers)"). Reproducible: ids, times and values are fixed in code, the
//! pictures come from `scripts/perf-media.sh` (never committed). Writes the full project and one copy per heavy element
//! switched off (`-no-blur`, `-no-shadow`, `-no-motion-blur`, `-no-dissolve`, `-no-4k`) beside it, all over the same media.

use serde_json::json;
use sq_core_model::{
    AnimatedProperty, BlendMode, Clip, ClipEffect, ClipMask, ClipSpeed, ColorGraph, ColorQualifier, ColorStep,
    GeneratorRef, LUTRef, MaskShapeKind, MediaRef, Project, SequenceFormat, SpeedKeys, SpeedSegment, StepWindow,
    Timeline, Track, TrackKind, Transition,
};
use sq_core_time::{EaseHandle, Id, Interpolation, Keyframe, KeyframeTrack, Time, TimeRange, Vec2};
use sq_editor_session::ImportBackend;
use sq_text::text_generator::TextGenerator;
use sq_text::text_style::{RGBAColor, TextShadow, TextStyle};
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

/// A full Basic Correction (a Color effect), the same values as the P2 case.
fn grade(n: u128) -> ClipEffect {
    effect(
        n,
        ClipEffect::COLOR_KIND,
        &[
            (ClipEffect::COLOR_EXPOSURE_KEY, 0.3),
            (ClipEffect::COLOR_CONTRAST_KEY, 15.0),
            (ClipEffect::COLOR_HIGHLIGHTS_KEY, -20.0),
            (ClipEffect::COLOR_TEMPERATURE_KEY, 8.0),
            (ClipEffect::COLOR_SATURATION_KEY, 115.0),
        ],
    )
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
    cross_dissolve_of(700, 2 * FPS, out, incoming)
}

/// A centered Cross Dissolve of `frames` frames (at `FPS`) with the fixed id `n`.
fn cross_dissolve_of(n: u128, frames: i64, out: Id, incoming: Id) -> Result<Transition, String> {
    serde_json::from_value(json!({
        "id": id(n), "kind": "crossDissolve", "alignment": "center",
        "duration": {"value": frames, "timescale": FPS}, "customBefore": {"value": 0, "timescale": 1},
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

/// How the layers of a case sit in the picture.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Layout {
    /// Every layer full frame, each above the bottom one at `opacity`.
    Stack,
    /// Up to four layers scaled into a 2x2 grid, all opaque.
    Grid,
}

/// One bench case (`bench/cases/*.json`): which korpus set, how many layers, how they sit, what is on them.
/// Keys: `name` (informational), `set` (korpus set, files `<set>-NN.mp4|mov`), `layers` (1..=8), `layout` ("stack" or
/// "grid"), `opacity` (of the layers above the bottom, stack only, default 0.5), `seconds` (default 20), `blur` /
/// `shadow` / `title` (default false), `cut_every` (seconds; cuts the bottom layer into clips of that length over files
/// 1..=4 and takes the other layers from files 5 and up), `far_cuts` (the bottom layer is 3 equal clips of ONE file,
/// file 1, whose in-points lie far apart: 0 s, 14 s, 6 s; a cut to a far position of one long-GOP file), `audio` (the bottom layer's audio on one audio track).
#[derive(Clone, Debug, PartialEq)]
pub struct CaseSpec {
    /// `fx` key: the effect set of the case (see [`Fx`]); `None` = a plain case.
    pub fx: Option<Fx>,
    pub set: String,
    pub layers: usize,
    pub layout: Layout,
    pub opacity: f64,
    pub seconds: i64,
    pub blur: bool,
    pub shadow: bool,
    pub title: bool,
    /// Two titles with a blurred drop shadow (the second appears 4 s in, so its first draw falls into the run).
    pub title_shadow: bool,
    pub cut_every: Option<i64>,
    pub far_cuts: bool,
    pub audio: bool,
    /// Sequence size and frame rate (`width`, `height`, `fps`); `None` = 1920x1080 at 29.97.
    pub format: Option<(i64, i64, i64)>,
    /// Fit scale of the layers (`fit`); `None` = the set-name rule of `case_project`.
    pub fit: Option<f64>,
    /// Constant speed of every clip in percent (`speed`, 25 = quarter speed); 100 = normal.
    pub speed_percent: i64,
    /// `speed_ramp`: every clip ramps 100 % -> 25 % -> 100 % (a speed track).
    pub speed_ramp: bool,
    /// `grades`: this many extra stacked Basic Corrections on every layer.
    pub grades: usize,
    /// `graph_steps`: a Pro color graph with this many Steps (primaries, windows, qualifiers) on every layer.
    pub graph_steps: usize,
    /// `lut`: file name (in a media folder) of a .cube look LUT in the first Step of the graph.
    pub lut: Option<String>,
    /// `adjustment`: an adjustment layer over everything with a 6-Step graph and a Basic Correction.
    pub adjustment: bool,
    /// `masks`: a feathered ellipse mask on every layer.
    pub masks: bool,
    /// `stabilize`: a finished Stabilizer (a synthetic hand-held path, `workflow_synth`) on every layer.
    pub stabilize: bool,
    /// `subject_mask`: a subject (Magic) mask on every layer; its mattes are synthetic and written when a bench opens the
    /// project (`workflow_synth::ensure_mattes`).
    pub subject_mask: bool,
    /// `motion_blur`: the top layer swooshes with a 180 degree shutter.
    pub motion_blur: bool,
    /// `blend`: the layers above the bottom one cycle through blend modes.
    pub blend: bool,
    /// `nested`: all layers sit in an inner sequence that the outer sequence plays as one nested clip (graded).
    pub nested: bool,
}

/// The effect sets of the effect-heavy bench cases (`"fx"` in a case spec).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fx {
    /// Every video clip has a full Basic Correction (exposure, contrast, highlights, temperature, saturation).
    Grade,
    /// Gaussian Blur, Glow, Sharpen and Unsharp Mask on every video clip.
    BlurGlow,
    /// Every layer graded; layer 2 has a feathered ellipse mask, layer 3 the Screen blend mode.
    Stack,
    /// Bottom layer cut every `cut_every` s with a half-second Cross Dissolve at each cut, the third clip at 200 % speed.
    TitlesTrans,
}

impl CaseSpec {
    /// Reads the JSON text of a case; unknown keys are an error so a typo does not silently change a case.
    pub fn parse(text: &str) -> Result<CaseSpec, String> {
        let v: serde_json::Value = serde_json::from_str(text).map_err(|e| format!("case spec: {e}"))?;
        let o = v.as_object().ok_or("case spec: not an object")?;
        const KEYS: &[&str] = &[
            "fx",
            "name",
            "set",
            "layers",
            "layout",
            "opacity",
            "seconds",
            "blur",
            "shadow",
            "title",
            "title_shadow",
            "cut_every",
            "far_cuts",
            "audio",
            "width",
            "height",
            "fps",
            "fit",
            "speed",
            "speed_ramp",
            "grades",
            "graph_steps",
            "lut",
            "adjustment",
            "masks",
            "stabilize",
            "subject_mask",
            "motion_blur",
            "blend",
            "nested",
        ];
        if let Some(k) = o.keys().find(|k| !KEYS.contains(&k.as_str())) {
            return Err(format!("case spec: unknown key {k}"));
        }
        let flag = |k: &str| o.get(k).and_then(|x| x.as_bool()).unwrap_or(false);
        let layout = match o.get("layout").and_then(|x| x.as_str()).unwrap_or("stack") {
            "stack" => Layout::Stack,
            "grid" => Layout::Grid,
            other => return Err(format!("case spec: layout {other}")),
        };
        let layers = o.get("layers").and_then(|x| x.as_u64()).unwrap_or(1) as usize;
        if !(1..=8).contains(&layers) || (layout == Layout::Grid && layers > 4) {
            return Err(format!("case spec: {layers} layers"));
        }
        let seconds = o.get("seconds").and_then(|x| x.as_i64()).unwrap_or(20);
        if seconds < 1 {
            return Err("case spec: seconds".into());
        }
        let fx = match o.get("fx").and_then(|x| x.as_str()) {
            None => None,
            Some("grade") => Some(Fx::Grade),
            Some("blur-glow") => Some(Fx::BlurGlow),
            Some("stack") => Some(Fx::Stack),
            Some("titles-trans") => Some(Fx::TitlesTrans),
            Some(other) => return Err(format!("case spec: fx {other}")),
        };
        let int = |k: &str| o.get(k).and_then(|x| x.as_i64());
        let format = match (int("width"), int("height"), int("fps")) {
            (None, None, None) => None,
            (Some(w), Some(h), Some(f)) if w > 0 && h > 0 && (1..=240).contains(&f) => Some((w, h, f)),
            _ => return Err("case spec: width, height and fps go together".into()),
        };
        let speed_percent = int("speed").unwrap_or(100);
        if !(1..=800).contains(&speed_percent) {
            return Err("case spec: speed".into());
        }
        Ok(CaseSpec {
            format,
            fit: o.get("fit").and_then(|x| x.as_f64()),
            speed_percent,
            speed_ramp: flag("speed_ramp"),
            grades: int("grades").unwrap_or(0).clamp(0, 12) as usize,
            graph_steps: int("graph_steps").unwrap_or(0).clamp(0, 24) as usize,
            lut: o.get("lut").and_then(|x| x.as_str()).map(str::to_string),
            adjustment: flag("adjustment"),
            masks: flag("masks"),
            stabilize: flag("stabilize"),
            subject_mask: flag("subject_mask"),
            motion_blur: flag("motion_blur"),
            blend: flag("blend"),
            nested: flag("nested"),
            fx,
            set: o.get("set").and_then(|x| x.as_str()).ok_or("case spec: set is missing")?.to_string(),
            layers,
            layout,
            opacity: o.get("opacity").and_then(|x| x.as_f64()).unwrap_or(0.5),
            seconds,
            blur: flag("blur"),
            shadow: flag("shadow"),
            title: flag("title"),
            title_shadow: flag("title_shadow"),
            cut_every: o.get("cut_every").and_then(|x| x.as_i64()).filter(|n| *n >= 1),
            far_cuts: flag("far_cuts"),
            audio: flag("audio"),
        })
    }

    /// The 1-based korpus file number of video layer `layer` (0 = bottom) and, for a cut bottom layer, of cut `cut`.
    pub fn file_number(&self, layer: usize, cut: usize) -> usize {
        match (self.cut_every, layer) {
            _ if self.far_cuts && layer == 0 => 1,
            (Some(_), 0) => cut % 4 + 1,
            (Some(_), l) => 4 + l,
            (None, l) => l + 1,
        }
    }

    /// Lengths in seconds of the clips of video layer `layer`.
    fn lengths(&self, layer: usize) -> Vec<i64> {
        if self.far_cuts && layer == 0 {
            return vec![self.seconds / 3; 3];
        }
        match (self.cut_every, layer) {
            (Some(c), 0) => (0..self.seconds).step_by(c as usize).map(|at| c.min(self.seconds - at)).collect(),
            _ => vec![self.seconds],
        }
    }

    /// Seconds into its file where clip `cut` of video layer `layer` starts.
    fn source_start(&self, layer: usize, cut: usize) -> i64 {
        if self.far_cuts && layer == 0 {
            [0, 14, 6][cut % 3]
        } else if self.fx == Some(Fx::TitlesTrans) && layer == 0 && cut > 0 {
            1 // one second of handle before the cut, so the dissolve has frames on both sides
        } else {
            0
        }
    }

    /// Numbers of the files the case needs, ascending and without repeats.
    pub fn files_needed(&self) -> Vec<usize> {
        let mut n = Vec::new();
        for layer in 0..self.layers {
            n.extend((0..self.lengths(layer).len()).map(|cut| self.file_number(layer, cut)));
        }
        n.sort_unstable();
        n.dedup();
        n
    }
}

/// The path of a case's look LUT: the first media folder that holds it, else the plain name.
fn lut_path(folders: &[PathBuf], name: &str) -> String {
    let found = folders.iter().map(|f| f.join(name)).find(|p| p.is_file());
    found.map_or_else(|| name.to_string(), |p| p.to_string_lossy().into_owned())
}

/// A Basic-Correction-like Pro color graph of `steps` Steps: primaries on every Step, an ellipse window on every 3rd,
/// a color qualifier on every 4th, `lut` (a .cube path) in the first.
fn graph_effect(n: u128, steps: usize, lut: Option<String>) -> ClipEffect {
    let mut list = Vec::new();
    for i in 0..steps {
        let mut st = ColorStep::new(id(n + 1 + i as u128), &format!("Step {}", i + 1));
        let f = (i % 5) as f32 * 0.02;
        st.primaries.lift = [0.01 + f, 0.0, -0.01].into();
        st.primaries.gain = [1.05, 1.0 + f, 0.95].into();
        st.primaries.contrast = 1.05;
        st.primaries.saturation = 1.1;
        if i % 3 == 2 {
            st.window = Some(StepWindow::default());
        }
        if i % 4 == 3 {
            st.qualifier = Some(ColorQualifier::default());
        }
        if i == 0 {
            st.lut = lut.clone().map(|path| LUTRef::File { path });
        }
        list.push(st);
    }
    let mut graph = ColorGraph::new(list, None, None, id(n + 900));
    graph.is_active = true;
    // shortcut: kind string of sq_core_color::clip_grade::COLOR_GRAPH_KIND ("colorGraph", a stored name), not imported to
    // keep this module free of that crate; the renderer only reads a graph from an effect of that kind.
    let mut e = ClipEffect::new(id(n), "colorGraph");
    e.color_graph = Some(graph);
    e
}

/// The project of a case over `media` (`(file number, probed media)` pairs).
/// shortcut: the fit scale is 0.5 for 4K sets and 1.0 for 1080p sets, read from the set name; upgrade to the probed
/// frame size when a set of another size is added.
pub fn case_project(spec: &CaseSpec, media: &[(usize, MediaRef)], lut_folder: &[PathBuf]) -> Result<Project, String> {
    let find =
        |n: usize| media.iter().find(|(k, _)| *k == n).map(|(_, m)| m).ok_or(format!("file {n} of {}", spec.set));
    let fit = spec.fit.unwrap_or(if spec.set.starts_with("1080p") { 1.0 } else { 0.5 });
    let video = TrackKind::Video;
    let grid = [(-480.0, -270.0), (480.0, -270.0), (-480.0, 270.0), (480.0, 270.0)];
    let lut_folder = lut_folder.to_vec();
    let mut next = 100_u128;
    let mut tracks = Vec::new();
    #[allow(clippy::needless_range_loop)] // `layer` also numbers the track and picks files, not only the grid slot
    for layer in 0..spec.layers {
        let mut clips = Vec::new();
        let mut at = 0;
        for (cut, len) in spec.lengths(layer).into_iter().enumerate() {
            let m = find(spec.file_number(layer, cut))?;
            // The korpus files are cut at 599 frames (19.987 s), a tenth of a second short of the nominal length is fine.
            let from = spec.source_start(layer, cut);
            if m.duration.is_some_and(|d| d + Time::new(1, 10) < secs(from + len)) {
                return Err(format!("{} is shorter than {len} s", m.path));
            }
            next += 1;
            let sped = spec.fx == Some(Fx::TitlesTrans) && layer == 0 && cut == 2;
            let slow = spec.speed_percent != 100;
            // A slowed clip reads len * percent / 100 s of its file (at least one frame).
            let source_len = if sped {
                len * 2
            } else if slow {
                (len * spec.speed_percent / 100).max(1)
            } else {
                len
            };
            let mut c = clip(next, &format!("L{} cut {cut}", layer + 1), m, video, secs(from), source_len, secs(at));
            if sped {
                c.speed = ClipSpeed::new(2, 1);
            } else if slow {
                c.speed = ClipSpeed::new(spec.speed_percent, 100);
            }
            if spec.speed_ramp {
                // 100 % -> 25 % over the first half, 25 % -> 100 % over the second; the source range is generous.
                let half = Time::new(len, 2);
                let (full, quarter) = (ClipSpeed::new(1, 1), ClipSpeed::new(1, 4));
                let segments = vec![
                    SpeedSegment::new(half, full, Some(quarter), false, None),
                    SpeedSegment::new(half, quarter, Some(full), false, None),
                ];
                c.set_speed_keys(Some(SpeedKeys::new(segments, secs(from))));
            }
            let (scale, position, opacity) = match spec.layout {
                Layout::Stack => (fit, (0.0, 0.0), if layer == 0 { 1.0 } else { spec.opacity }),
                Layout::Grid => (fit * 0.5, grid[layer], 1.0),
            };
            c.animation.scale.value = Vec2::new(scale, scale);
            c.animation.position.value = Vec2::new(position.0, position.1);
            c.animation.opacity.value = opacity;
            if spec.blur {
                next += 1;
                c.effects.push(blur(next, 12.0));
            }
            match spec.fx {
                Some(Fx::Grade) => c.effects.push(grade(next + 10_000)),
                Some(Fx::BlurGlow) => {
                    let n = next + 10_000;
                    c.effects.push(blur(n, 8.0));
                    c.effects.push(effect(n + 1, ClipEffect::GLOW_KIND, &[]));
                    c.effects.push(effect(n + 2, ClipEffect::SHARPEN_KIND, &[]));
                    c.effects.push(effect(n + 3, ClipEffect::UNSHARP_MASK_KIND, &[]));
                }
                Some(Fx::Stack) => {
                    c.effects.push(grade(next + 10_000));
                    if layer == 1 {
                        c.mask_store = Some(vec![ClipMask::make(id(next + 11_000), MaskShapeKind::Ellipse, "Mask")]);
                    }
                    if layer == 2 {
                        c.blend_mode = BlendMode::Screen;
                    }
                }
                Some(Fx::TitlesTrans) | None => {}
            }
            if spec.shadow {
                next += 1;
                c.effects.push(effect(next, ClipEffect::DROP_SHADOW_KIND, &[(ClipEffect::SHADOW_OPACITY_KEY, 75.0)]));
            }
            for g in 0..spec.grades {
                c.effects.push(grade(next + 20_000 + 1000 * g as u128));
            }
            if spec.graph_steps > 0 || spec.lut.is_some() {
                let lut = spec.lut.as_ref().map(|n| lut_path(&lut_folder, n));
                c.effects.push(graph_effect(next + 40_000, spec.graph_steps.max(1), lut));
            }
            if spec.masks {
                c.mask_store = Some(vec![ClipMask::make(id(next + 50_000), MaskShapeKind::Ellipse, "Mask")]);
            }
            if spec.stabilize {
                let picture = if spec.set.starts_with("1080p") { (1920, 1080) } else { (3840, 2160) };
                let fd = Time::new(1, FPS);
                c.effects.extend(crate::workflow_synth::stabilizer_for(&c, picture, fd, id(next + 60_000)));
            }
            if spec.subject_mask {
                let point = sq_core_model::MagicPoint {
                    position: Vec2::new(0.5, 0.5),
                    subtract: false,
                    source_time: c.source.start,
                };
                c.mask_store = Some(vec![ClipMask::make_magic(id(next + 70_000), "Subject", vec![point])]);
            }
            if spec.blend && layer > 0 {
                const MODES: [BlendMode; 6] = [
                    BlendMode::Screen,
                    BlendMode::Multiply,
                    BlendMode::Overlay,
                    BlendMode::SoftLight,
                    BlendMode::Add,
                    BlendMode::Lighten,
                ];
                c.blend_mode = MODES[(layer - 1) % MODES.len()];
            }
            if spec.motion_blur && layer + 1 == spec.layers {
                c.animation.position = swoosh();
                c.animation.shutter_angle.value = 180.0;
            }
            clips.push(c);
            at += len;
        }
        let mut t = track(900 + layer as u128, video, &format!("V{}", layer + 1), clips);
        if spec.fx == Some(Fx::TitlesTrans) && layer == 0 {
            let ids: Vec<Id> = t.clips().iter().map(|c| c.id).collect();
            for (n, pair) in ids.windows(2).enumerate() {
                t.transitions.push(cross_dissolve_of(700 + n as u128, FPS / 2, pair[0], pair[1])?);
            }
        }
        tracks.push(t);
    }
    if spec.title {
        let template = TextTemplate::new("Title", "BENCH", TextStyle { size: 110.0, ..TextStyle::default() });
        let range = TimeRange::new(Time::ZERO, secs(spec.seconds));
        let mut title = Clip::new(id(15), "Title", id(115), video, range, Time::ZERO);
        title.generator = Some(TextGenerator::make_ref(&template, None).map_err(|e| format!("title: {e}"))?);
        title.animation.position.value = Vec2::new(0.0, 380.0);
        tracks.push(track(950, video, "Title", vec![title]));
    }
    if spec.title_shadow {
        let shadow = TextShadow::new(RGBAColor::BLACK, 4.0, 6.0, 14.0);
        let style = TextStyle { size: 110.0, shadow: Some(shadow), ..TextStyle::default() };
        for (n, (word, y, from)) in [("SHADOW ONE", 380.0, 0), ("SHADOW TWO", -380.0, 4)].into_iter().enumerate() {
            let template = TextTemplate::new("Title", word, style.clone());
            let range = TimeRange::new(secs(from), secs(spec.seconds - from));
            let mut title = Clip::new(id(16 + n as u128), "Title", id(116 + n as u128), video, range, Time::ZERO);
            title.generator = Some(TextGenerator::make_ref(&template, None).map_err(|e| format!("title: {e}"))?);
            title.animation.position.value = Vec2::new(0.0, y);
            tracks.push(track(951 + n as u128, video, "Title", vec![title]));
        }
    }
    if spec.audio {
        let m = find(spec.file_number(0, 0))?;
        let sound = clip(next + 1, "Audio", m, TrackKind::Audio, Time::ZERO, spec.seconds, Time::ZERO);
        tracks.push(track(960, TrackKind::Audio, "A1", vec![sound]));
    }
    if spec.adjustment {
        // shortcut: the generator kind string is sq_core_effects::adjustment_clip::ADJUSTMENT_KIND, not imported to
        // keep this module free of that crate; upgrade if the kind ever gets a payload.
        let range = TimeRange::new(Time::ZERO, secs(spec.seconds));
        let mut adj = Clip::new(id(17), "Adjustment", id(117), video, range, Time::ZERO);
        adj.generator = Some(GeneratorRef { kind: "adjustment".into(), payload: Vec::new(), payload_version: 1 });
        adj.effects.push(graph_effect(60_000, 6, None));
        adj.effects.push(grade(61_000));
        tracks.push(track(970, video, "Adjustment", vec![adj]));
    }
    let used: Vec<MediaRef> = media.iter().map(|(_, m)| m.clone()).collect();
    let mut format = SequenceFormat::new(Time::new(1001, 30000));
    if let Some((w, h, f)) = spec.format {
        (format.width, format.height, format.frame_duration) = (w, h, Time::new(1, f));
    }
    if spec.nested {
        // The layers move into an inner sequence (id 3); the outer one plays it as one graded clip on one track.
        let inner = Timeline::new(id(3), "bench-inner", format.clone(), tracks);
        let range = TimeRange::new(Time::ZERO, secs(spec.seconds));
        let mut outer = Clip::new(id(18), "Nested", id(3), video, range, Time::ZERO);
        outer.sequence = Some(id(3));
        outer.media_duration = Some(secs(spec.seconds));
        outer.effects.push(grade(62_000));
        let outer = Timeline::new(id(2), "bench-case", format, vec![track(980, video, "V1", vec![outer])]);
        return Ok(Project::new(id(1), "bench-case", used, vec![outer, inner]));
    }
    let timeline = Timeline::new(id(2), "bench-case", format, tracks);
    Ok(Project::new(id(1), "bench-case", used, vec![timeline]))
}

/// Reads the case at `spec_path`, probes the korpus files it needs in `folder` and writes the project to `out`.
pub fn write_case(out: &Path, folder: &Path, spec_path: &Path) -> Result<Vec<PathBuf>, String> {
    let text = std::fs::read_to_string(spec_path).map_err(|e| format!("{}: {e}", spec_path.display()))?;
    let spec = CaseSpec::parse(&text)?;
    // `folder` may name several media folders separated by `:` (the korpus, then generated media).
    let folders = folder
        .to_string_lossy()
        .split(':')
        .map(|f| sq_os::paths::canonical(Path::new(f)).map_err(|e| format!("{f}: {e}")))
        .collect::<Result<Vec<_>, _>>()?;
    let probe = crate::probe::FfmpegProbe::default();
    let mut media = Vec::new();
    for n in spec.files_needed() {
        let found = folders
            .iter()
            .flat_map(|folder| {
                let set = &spec.set;
                ["mp4", "mov"].iter().map(move |ext| folder.join(format!("{set}-{n:02}.{ext}")))
            })
            .find(|p| p.is_file());
        let path = found.ok_or(format!(
            "{}-{n:02} is missing: run scripts/perf-media.sh --korpus public {}",
            spec.set,
            folder.display()
        ))?;
        let mut m = probe.probe(&path).map_err(|e| format!("{}: {e:?}", path.display()))?;
        m.id = id(200 + n as u128);
        media.push((n, m));
    }
    sq_core_project::project_file::project_file()
        .write(&case_project(&spec, &media, &folders)?, out)
        .map_err(|e| format!("{}: {e:?}", out.display()))?;
    Ok(vec![out.to_path_buf()])
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

    fn case_media(spec: &CaseSpec) -> Vec<(usize, MediaRef)> {
        spec.files_needed()
            .into_iter()
            .map(|n| {
                let path = format!("/m/{}-{n:02}.mp4", spec.set);
                let mut m = MediaRef::new(id(200 + n as u128), "f", &path, MediaFingerprint::new(1));
                m.duration = Some(secs(20));
                (n, m)
            })
            .collect()
    }

    #[test]
    fn a_stack_case_has_distinct_files_and_half_opacity_above_the_bottom() {
        let spec = CaseSpec::parse(r#"{"set":"cam-422","layers":4,"layout":"stack"}"#).expect("spec");
        assert_eq!(spec.files_needed(), vec![1, 2, 3, 4]);
        let p = case_project(&spec, &case_media(&spec), &[]).expect("project");
        let t = &p.timelines[0];
        let opacity: Vec<f64> = t.tracks.iter().map(|t| t.clips()[0].animation.opacity.value).collect();
        assert_eq!(opacity, vec![1.0, 0.5, 0.5, 0.5]);
        let media: std::collections::BTreeSet<_> = t.tracks.iter().map(|t| t.clips()[0].media).collect();
        assert_eq!(media.len(), 4, "no two layers share a file");
    }

    #[test]
    fn a_cut_case_cuts_the_bottom_layer_and_takes_b_roll_from_file_five() {
        let text = r#"{"set":"cam-422","layers":2,"cut_every":3,"seconds":10,"title":true,"audio":true}"#;
        let spec = CaseSpec::parse(text).expect("spec");
        assert_eq!(spec.files_needed(), vec![1, 2, 3, 4, 5]);
        let p = case_project(&spec, &case_media(&spec), &[]).expect("project");
        let t = &p.timelines[0];
        assert_eq!(t.tracks[0].clips().len(), 4, "3 + 3 + 3 + 1 s");
        assert_eq!(t.tracks.len(), 4, "two video layers, title, audio");
    }

    #[test]
    fn a_far_cut_case_is_three_clips_of_one_file_with_far_in_points() {
        let spec = CaseSpec::parse(r#"{"set":"cam-422","layers":1,"far_cuts":true,"seconds":12}"#).expect("spec");
        assert_eq!(spec.files_needed(), vec![1]);
        let p = case_project(&spec, &case_media(&spec), &[]).expect("project");
        let clips = p.timelines[0].tracks[0].clips();
        let starts: Vec<Time> = clips.iter().map(|c| c.source.start).collect();
        assert_eq!(starts, vec![secs(0), secs(14), secs(6)]);
        assert!(clips.iter().all(|c| c.source.duration == secs(4)));
    }

    #[test]
    fn a_misspelled_key_or_a_bad_layer_count_is_refused() {
        assert!(CaseSpec::parse(r#"{"set":"x","layer":2}"#).is_err());
        assert!(CaseSpec::parse(r#"{"set":"x","layers":9}"#).is_err());
        assert!(CaseSpec::parse(r#"{"set":"x","layers":5,"layout":"grid"}"#).is_err());
        assert!(CaseSpec::parse(r#"{"layers":2}"#).is_err());
    }

    #[test]
    fn the_stabilizer_and_subject_mask_cases_carry_a_planned_stabilizer_and_a_magic_mask() {
        use sq_core_masks::masks::ClipMasksExt;
        for name in ["mx-fx-stabilize", "mx-fx-stabilize-1080p", "mx-fx-subjectmask", "mx-fx-subjectmask-1080p"] {
            let text = std::fs::read_to_string(format!("{}/../../bench/cases/{name}.json", env!("CARGO_MANIFEST_DIR")))
                .expect("spec file");
            let spec = CaseSpec::parse(&text).expect("spec");
            let p = case_project(&spec, &case_media(&spec), &[]).expect("project");
            let clip = &p.timelines[0].tracks[0].clips()[0];
            if name.contains("stabilize") {
                let e = clip.effects.iter().find(|e| e.kind == ClipEffect::STABILIZE_KIND).expect("a Stabilizer");
                assert!(e.parameters.values().any(|v| v.is_animated()), "{name}: the planned correction has keys");
                assert!(clip.masks().is_empty());
            } else {
                assert_eq!(clip.masks().len(), 1, "{name}");
                assert_eq!(clip.masks()[0].source(), sq_core_model::MaskSource::Magic);
            }
        }
    }

    #[test]
    fn the_fx_cases_build_with_their_effects() {
        let load = |name: &str| {
            let text = std::fs::read_to_string(format!("{}/../../bench/cases/{name}.json", env!("CARGO_MANIFEST_DIR")))
                .expect("spec file");
            let spec = CaseSpec::parse(&text).expect("spec");
            let p = case_project(&spec, &case_media(&spec), &[]).expect("project");
            (spec, p)
        };
        let kinds = |c: &Clip| c.effects.iter().map(|e| e.kind.clone()).collect::<Vec<_>>();
        let (_, p) = load("fx-grade-4k");
        assert_eq!(kinds(&p.timelines[0].tracks[0].clips()[0]), vec![ClipEffect::COLOR_KIND]);
        let (_, p) = load("fx-blur-glow");
        assert_eq!(kinds(&p.timelines[0].tracks[0].clips()[0]).len(), 4);
        let (_, p) = load("fx-stack-3");
        let t = &p.timelines[0];
        assert_eq!(t.tracks.len(), 3);
        assert!(t.tracks.iter().all(|t| kinds(&t.clips()[0]) == vec![ClipEffect::COLOR_KIND]));
        assert!(t.tracks[1].clips()[0].mask_store.is_some() && t.tracks[0].clips()[0].mask_store.is_none());
        assert_eq!(t.tracks[2].clips()[0].blend_mode, BlendMode::Screen);
        let (_, p) = load("fx-titles-trans");
        let t = &p.timelines[0];
        let base = &t.tracks[0];
        assert_eq!(base.clips().len(), 6);
        assert_eq!(base.transitions.len(), 5, "a dissolve at every cut");
        assert_eq!(base.clips()[2].speed, ClipSpeed::new(2, 1));
        assert_eq!(base.clips()[2].duration(), secs(2), "200 % over a 4 s source is 2 s");
        assert_eq!(base.clips()[5].timeline().end(), secs(12));
        assert!(base.clips()[1].source.start >= secs(1), "handle before the cut");
        assert_eq!(t.tracks.len(), 3, "base plus two shadow titles");
    }

    #[test]
    fn an_unknown_fx_is_refused() {
        assert!(CaseSpec::parse(r#"{"set":"cam-422","fx":"nope"}"#).is_err());
    }

    #[test]
    fn matrix_keys_set_format_speed_graph_adjustment_and_nesting() {
        let text = r#"{"set":"4k-h264","layers":3,"width":3840,"height":2160,"fps":60,"fit":1.0,"speed":25,
            "graph_steps":6,"grades":2,"masks":true,"blend":true,"motion_blur":true,"adjustment":true,"seconds":8}"#;
        let spec = CaseSpec::parse(text).expect("spec");
        let p = case_project(&spec, &case_media(&spec), &[]).expect("project");
        let t = &p.timelines[0];
        assert_eq!((t.format.width, t.format.height, t.format.frame_duration), (3840, 2160, Time::new(1, 60)));
        let c = &t.tracks[0].clips()[0];
        assert_eq!(c.speed, ClipSpeed::new(25, 100));
        assert_eq!(c.source.duration, secs(2), "a quarter-speed clip of 8 s reads 2 s");
        assert_eq!(c.effects.len(), 3, "two grades and the graph");
        assert!(c.effects.iter().any(|e| e.kind == "colorGraph" && e.color_graph.is_some()));
        assert_eq!(t.tracks[1].clips()[0].blend_mode, BlendMode::Screen);
        assert_eq!(t.tracks.last().map(|t| t.clips()[0].is_generator()), Some(true), "the adjustment layer is on top");
        let nested = CaseSpec::parse(r#"{"set":"cam-422","layers":2,"nested":true,"speed_ramp":true}"#).expect("spec");
        let n = case_project(&nested, &case_media(&nested), &[]).expect("project");
        assert_eq!(n.timelines.len(), 2);
        assert!(n.timelines[0].tracks[0].clips()[0].is_nested());
        assert!(n.timelines[1].tracks[0].clips()[0].speed_keys.is_some());
        assert!(CaseSpec::parse(r#"{"set":"x","width":1920}"#).is_err(), "size and rate go together");
    }
}
