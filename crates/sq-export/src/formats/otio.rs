// SPDX-License-Identifier: GPL-3.0-or-later
//! OpenTimelineIO (.otio JSON, schema Timeline.1 / Stack.1 / Track.1 / Clip.2 / Gap.1 / Transition.1 / Marker.2) of a
//! sequence: every video and audio track as a Track.1 with gaps between clips, external media references, constant speed
//! as `LinearTimeWarp.1` (negative scalar = reverse), a hold frame as `FreezeFrame.1`, touching dissolves as
//! `Transition.1`, markers on the Stack. Item lengths are the lengths on the track; `source_range.start_time` is media
//! time. Titles, generators, nested sequences and disabled clips are skipped and listed in the warnings.
//! The JSON text is laid out like Foundation's `JSONSerialization` (pretty printed, sorted keys, slashes unescaped).
//! Written from the public OTIO file-format description; no third-party code.

use super::{InterchangeExport, Warnings, file_url, media_by_id, usable, written_speed};
use sq_core_effects::transition::TransitionKindExt as _;
use sq_core_model::{
    Clip, MarkerColor, MediaRef, Project, Timeline, Track, TrackKind, TransitionAlignment, TransitionKind,
};
use sq_core_time::Time;
use std::collections::BTreeMap;

/// OTIO writer.
pub struct OtioWriter;

/// Which sequences of a project one export holds (the export dialog's choice).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum OtioScope {
    /// The active sequence (the first when none is active).
    ActiveSequence,
    /// Every sequence.
    AllSequences,
}

impl OtioScope {
    /// The sequences of `project` this choice exports.
    pub fn timelines(self, project: &Project) -> Vec<&Timeline> {
        match self {
            OtioScope::AllSequences => project.timelines.iter().collect(),
            OtioScope::ActiveSequence => project
                .timelines
                .iter()
                .find(|t| Some(t.id) == project.active_timeline)
                .or(project.timelines.first())
                .into_iter()
                .collect(),
        }
    }
}

/// A JSON value; objects keep their keys sorted.
enum Json {
    Null,
    Bool(bool),
    Num(f64),
    Str(String),
    Arr(Vec<Json>),
    Obj(BTreeMap<&'static str, Json>),
}

fn obj<const N: usize>(pairs: [(&'static str, Json); N]) -> Json {
    Json::Obj(pairs.into_iter().collect())
}

fn s(v: &str) -> Json {
    Json::Str(v.to_string())
}

fn empty() -> Json {
    Json::Obj(BTreeMap::new())
}

impl Json {
    /// Pretty-printed like `JSONSerialization` (`"key" : value`, two-space indent); `None` for a number JSON cannot hold.
    fn write(&self, indent: usize, out: &mut String) -> Option<()> {
        let pad = "  ".repeat(indent);
        match self {
            Json::Null => out.push_str("null"),
            Json::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Json::Num(v) => {
                if !v.is_finite() {
                    return None;
                }
                out.push_str(&number(*v));
            }
            Json::Str(t) => string(t, out),
            Json::Arr(items) if items.is_empty() => out.push_str(&format!("[\n\n{pad}]")),
            Json::Arr(items) => {
                out.push_str("[\n");
                for (i, it) in items.iter().enumerate() {
                    out.push_str(&pad);
                    out.push_str("  ");
                    it.write(indent + 1, out)?;
                    out.push_str(if i + 1 < items.len() { ",\n" } else { "\n" });
                }
                out.push_str(&pad);
                out.push(']');
            }
            Json::Obj(map) if map.is_empty() => out.push_str(&format!("{{\n\n{pad}}}")),
            Json::Obj(map) => {
                out.push_str("{\n");
                // Foundation sorts keys ignoring case ("name" before "OTIO_SCHEMA").
                let mut entries: Vec<(&&str, &Json)> = map.iter().collect();
                entries.sort_by_key(|(k, _)| k.to_lowercase());
                for (i, (k, v)) in entries.into_iter().enumerate() {
                    out.push_str(&pad);
                    out.push_str("  ");
                    string(k, out);
                    out.push_str(" : ");
                    v.write(indent + 1, out)?;
                    out.push_str(if i + 1 < map.len() { ",\n" } else { "\n" });
                }
                out.push_str(&pad);
                out.push('}');
            }
        }
        Some(())
    }
}

/// A finite double the way Foundation prints it: C `%.17g`.
fn number(v: f64) -> String {
    if v == 0.0 {
        return if v.is_sign_negative() { "-0".to_string() } else { "0".to_string() };
    }
    let sci = format!("{v:.16e}");
    let (mantissa, exp) = sci.split_once('e').unwrap_or((&sci, "0"));
    let exp: i32 = exp.parse().unwrap_or(0);
    let trim = |s: &str| -> String {
        if s.contains('.') { s.trim_end_matches('0').trim_end_matches('.').to_string() } else { s.to_string() }
    };
    if !(-4..17).contains(&exp) {
        let sign = if exp < 0 { '-' } else { '+' };
        return format!("{}e{sign}{:02}", trim(mantissa), exp.abs());
    }
    trim(&format!("{v:.prec$}", prec = (16 - exp).max(0) as usize))
}

fn string(t: &str, out: &mut String) {
    out.push('"');
    for c in t.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{8}' => out.push_str("\\b"),
            '\u{c}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04X}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
}

fn marker_color(c: MarkerColor) -> &'static str {
    match c {
        MarkerColor::Green => "GREEN",
        MarkerColor::Red => "RED",
        MarkerColor::Purple => "PURPLE",
        MarkerColor::Orange => "ORANGE",
        MarkerColor::Yellow => "YELLOW",
        MarkerColor::White => "WHITE",
        MarkerColor::Blue => "BLUE",
        MarkerColor::Cyan => "CYAN",
    }
}

struct Render<'a> {
    fd: Time,
    rate: f64,
    by_id: std::collections::HashMap<sq_core_time::Id, &'a MediaRef>,
    w: &'a mut Warnings,
}

impl Render<'_> {
    fn rt(&self, t: Time) -> Json {
        let frames =
            t.value() as f64 * self.fd.timescale() as f64 / (t.timescale() as f64 * self.fd.value().max(1) as f64);
        obj([("OTIO_SCHEMA", s("RationalTime.1")), ("rate", Json::Num(self.rate)), ("value", Json::Num(frames))])
    }

    fn range(&self, start: Time, duration: Time) -> Json {
        obj([("OTIO_SCHEMA", s("TimeRange.1")), ("start_time", self.rt(start)), ("duration", self.rt(duration))])
    }

    fn marker(&self, m: &sq_core_model::Marker) -> Json {
        obj([
            ("OTIO_SCHEMA", s("Marker.2")),
            ("name", s(&m.name)),
            ("color", s(marker_color(m.color))),
            ("marked_range", self.range(m.time, m.duration.max(Time::ZERO))),
            ("comment", s(&m.comment)),
            ("metadata", empty()),
        ])
    }

    fn clip(&mut self, c: &Clip) -> Json {
        let m = self.by_id.get(&c.media).copied();
        if m.is_none() {
            self.w.warn("Media of a clip is missing from the project; written as a missing reference");
        }
        let reference = match m.filter(|m| !m.path.is_empty()) {
            Some(m) => obj([
                ("OTIO_SCHEMA", s("ExternalReference.1")),
                ("name", s(&m.name)),
                ("target_url", s(&file_url(&m.path))),
                ("metadata", empty()),
                (
                    "available_range",
                    match m.duration.or(m.info.as_ref().map(|i| i.duration)) {
                        Some(d) => self.range(Time::ZERO, d),
                        None => Json::Null,
                    },
                ),
            ]),
            None => obj([
                ("OTIO_SCHEMA", s("MissingReference.1")),
                ("name", s(m.map_or(c.name.as_str(), |m| m.name.as_str()))),
                ("metadata", empty()),
                ("available_range", Json::Null),
            ]),
        };
        let mut effects = Vec::new();
        let mut start = c.source.start;
        if let Some(h) = c.hold_frame {
            start = h;
            effects.push(obj([
                ("OTIO_SCHEMA", s("FreezeFrame.1")),
                ("name", s("Freeze Frame")),
                ("effect_name", s("FreezeFrame")),
                ("time_scalar", Json::Num(0.0)),
                ("metadata", empty()),
            ]));
        } else {
            let (speed, reversed) = written_speed(c, self.w);
            if !speed.is_normal() || reversed {
                // Reversed: start_time stays the lowest source frame, the negative scalar plays the range backward.
                let scalar = speed.num() as f64 / speed.den() as f64 * if reversed { -1.0 } else { 1.0 };
                effects.push(obj([
                    ("OTIO_SCHEMA", s("LinearTimeWarp.1")),
                    ("name", s("")),
                    ("effect_name", s("LinearTimeWarp")),
                    ("time_scalar", Json::Num(scalar)),
                    ("metadata", empty()),
                ]));
            }
        }
        // Clip markers sit in media time (what the reader expects), only those inside the played range.
        let mut own: Vec<&sq_core_model::Marker> = if c.hold_frame.is_some() {
            Vec::new()
        } else {
            c.markers.iter().flatten().filter(|m| m.time >= c.source.start && m.time < c.source.end()).collect()
        };
        own.sort_by_key(|m| m.time);
        obj([
            ("OTIO_SCHEMA", s("Clip.2")),
            ("name", s(&c.name)),
            ("source_range", self.range(start, c.duration())),
            ("media_reference", reference),
            ("effects", Json::Arr(effects)),
            ("markers", Json::Arr(own.into_iter().map(|m| self.marker(m)).collect())),
            ("metadata", empty()),
            ("enabled", Json::Bool(true)),
        ])
    }

    fn track(&mut self, t: &Track) -> Json {
        let mut clips: Vec<&Clip> = t.clips().iter().filter(|c| usable(c, self.w)).collect();
        clips.sort_by_key(|c| c.start);
        let mut children = Vec::new();
        let mut cursor = Time::ZERO;
        for (i, &c) in clips.iter().enumerate() {
            if c.start > cursor {
                children.push(obj([
                    ("OTIO_SCHEMA", s("Gap.1")),
                    ("name", s("")),
                    ("source_range", self.range(Time::ZERO, c.start - cursor)),
                    ("effects", Json::Arr(Vec::new())),
                    ("markers", Json::Arr(Vec::new())),
                    ("metadata", empty()),
                ]));
            }
            // A dissolve between this clip and the one before sits between the two items.
            let dissolve = (i > 0 && clips[i - 1].timeline().end() == c.start)
                .then(|| {
                    t.transitions.iter().find(|tr| tr.outgoing == Some(clips[i - 1].id) && tr.incoming == Some(c.id))
                })
                .flatten();
            if let Some(tr) = dissolve {
                let before = match tr.alignment {
                    TransitionAlignment::Center => tr.duration.halved().snapped(self.fd),
                    TransitionAlignment::StartAtCut => Time::ZERO,
                    TransitionAlignment::EndAtCut => tr.duration,
                    TransitionAlignment::Custom => tr.custom_before,
                };
                let before = before.max(Time::ZERO).min(tr.duration);
                let dissolve_like = matches!(tr.kind, TransitionKind::CrossDissolve | TransitionKind::QuickFade)
                    || tr.kind.track_kind() == TrackKind::Audio;
                if !matches!(
                    tr.kind,
                    TransitionKind::CrossDissolve
                        | TransitionKind::QuickFade
                        | TransitionKind::ConstantPower
                        | TransitionKind::ConstantGain
                ) {
                    self.w.warn(format!(
                        "Transition \"{}\" written as a custom transition named {}",
                        super::raw_name(&tr.kind),
                        tr.kind.name()
                    ));
                }
                children.push(obj([
                    ("OTIO_SCHEMA", s("Transition.1")),
                    ("name", s(tr.kind.name())),
                    ("transition_type", s(if dissolve_like { "SMPTE_Dissolve" } else { "Custom_Transition" })),
                    ("in_offset", self.rt(before)),
                    ("out_offset", self.rt(tr.duration - before)),
                    ("metadata", empty()),
                ]));
            }
            children.push(self.clip(c));
            cursor = c.timeline().end();
        }
        if t.transitions.iter().any(|tr| tr.outgoing.is_none() || tr.incoming.is_none()) {
            self.w.warn("Fade at a clip edge is not exported");
        }
        obj([
            ("OTIO_SCHEMA", s("Track.1")),
            ("name", s(&t.name)),
            ("kind", s(if t.kind == TrackKind::Video { "Video" } else { "Audio" })),
            ("children", Json::Arr(children)),
            ("source_range", Json::Null),
            ("effects", Json::Arr(Vec::new())),
            ("markers", Json::Arr(Vec::new())),
            ("metadata", empty()),
            ("enabled", Json::Bool(true)),
        ])
    }
}

fn timeline_json(timeline: &Timeline, media: &[MediaRef], w: &mut Warnings) -> Json {
    let fd = timeline.format.frame_duration;
    let rate = fd.timescale() as f64 / fd.value().max(1) as f64;
    let mut r = Render { fd, rate, by_id: media_by_id(media), w };
    let tracks: Vec<Json> = timeline.tracks.iter().map(|t| r.track(t)).collect();
    if !timeline.tracks.iter().any(|t| t.clips().iter().any(|c| usable(c, r.w))) {
        r.w.warn("The sequence has no clips OpenTimelineIO can carry");
    }
    let mut markers: Vec<&sq_core_model::Marker> = timeline.markers.iter().collect();
    markers.sort_by_key(|m| m.time);
    let stack = obj([
        ("OTIO_SCHEMA", s("Stack.1")),
        ("name", s("tracks")),
        ("children", Json::Arr(tracks)),
        ("source_range", Json::Null),
        ("effects", Json::Arr(Vec::new())),
        ("markers", Json::Arr(markers.into_iter().map(|m| r.marker(m)).collect())),
        ("metadata", empty()),
        ("enabled", Json::Bool(true)),
    ]);
    obj([
        ("OTIO_SCHEMA", s("Timeline.1")),
        ("name", s(&timeline.name)),
        ("tracks", stack),
        ("global_start_time", r.rt(timeline.timecode_start())),
        ("metadata", empty()),
    ])
}

impl OtioWriter {
    /// One sequence.
    pub fn render(timeline: &Timeline, media: &[MediaRef]) -> InterchangeExport {
        Self::render_all(&[timeline], media)
    }

    /// Several sequences: one Timeline.1 as is for a single one, else a SerializableCollection.1 holding every Timeline.1
    /// (a reader takes each timeline of a collection as one sequence).
    pub fn render_all(timelines: &[&Timeline], media: &[MediaRef]) -> InterchangeExport {
        let mut w = Warnings::default();
        let mut roots: Vec<Json> = timelines.iter().map(|t| timeline_json(t, media, &mut w)).collect();
        let root = if roots.len() == 1 {
            roots.remove(0)
        } else {
            obj([
                ("OTIO_SCHEMA", s("SerializableCollection.1")),
                ("name", s("Sequences")),
                ("children", Json::Arr(roots)),
                ("metadata", empty()),
            ])
        };
        let mut text = String::new();
        if root.write(0, &mut text).is_none() {
            let failure = Some("a time or name in the sequence cannot be written as JSON".to_string());
            return InterchangeExport { text: String::new(), warnings: w.0, failure };
        }
        text.push('\n');
        InterchangeExport::new(text, w.0)
    }
}
