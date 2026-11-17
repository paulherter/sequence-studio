// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: OTIOReader.swift. OpenTimelineIO JSON (.otio) -> `IXSequence`: the first timeline (`read_all`: every timeline of
//! a collection), its Video and Audio tracks (clips with `source_range`, gaps, transitions with in / out offsets,
//! `LinearTimeWarp` / `FreezeFrame` effects, external media references), and stack / clip markers. The length of an item on
//! a track is its `source_range.duration`; `start_time` is media time. Nested stacks, image sequences and generators are
//! dropped. Written from the public OTIO file-format description; no third-party code.

use crate::interchange_model::{IXClip, IXMarker, IXSequence, IXTrack, IXTransition, InterchangeError};
use crate::interchange_xml::{last_path_component, path_from_url};
use crate::primport_report::Status;
use serde_json::{Map, Value};
use sq_core_model::{ClipSpeed, MarkerColor, TrackKind, TransitionAlignment, TransitionKind};
use sq_core_time::{Time, TimeRange};

type Json = Map<String, Value>;

/// `d[key]` as a string.
fn string<'a>(d: &'a Json, key: &str) -> Option<&'a str> {
    d.get(key).and_then(Value::as_str)
}

/// `d[key]` as an array of objects; empty when it is missing or holds anything else.
fn objects<'a>(d: &'a Json, key: &str) -> Vec<&'a Json> {
    let Some(Value::Array(a)) = d.get(key) else { return Vec::new() };
    a.iter().map(Value::as_object).collect::<Option<Vec<_>>>().unwrap_or_default()
}

fn saturating_i64(d: f64) -> i64 {
    d as i64
}

/// Reads OpenTimelineIO.
pub struct OTIOReader;

impl OTIOReader {
    /// The first timeline.
    pub fn read(data: &[u8], name: &str) -> Result<IXSequence, InterchangeError> {
        Self::read_all(data, name)?
            .into_iter()
            .next()
            .ok_or_else(|| InterchangeError::Unsupported("no OpenTimelineIO timeline".into()))
    }

    /// Every timeline of the file, in document order: a lone Timeline, or each Timeline (and each bare Stack) found in
    /// the children of a Collection / SerializableCollection, nested collections included.
    pub fn read_all(data: &[u8], name: &str) -> Result<Vec<IXSequence>, InterchangeError> {
        let Some(Value::Object(root)) = serde_json::from_slice::<Value>(data).ok() else {
            return Err(InterchangeError::Malformed("not valid JSON".into()));
        };
        let mut found: Vec<Json> = Vec::new();
        Self::collect_timelines(&root, &mut found);
        if found.is_empty() {
            return Err(InterchangeError::Unsupported("no OpenTimelineIO timeline".into()));
        }
        found.iter().map(|t| Self::sequence(t, name)).collect()
    }

    fn collect_timelines(d: &Json, found: &mut Vec<Json>) {
        let schema = string(d, "OTIO_SCHEMA").unwrap_or("");
        if schema.starts_with("Timeline") {
            found.push(d.clone());
            return;
        }
        if schema.starts_with("Stack") && Self::is_bare_stack(d) {
            // A stack held by a collection plays as its own sequence.
            let mut t = Json::new();
            if let Some(n) = d.get("name") {
                t.insert("name".into(), n.clone());
            }
            t.insert("tracks".into(), Value::Object(d.clone()));
            found.push(t);
            return;
        }
        for c in objects(d, "children") {
            Self::collect_timelines(c, found);
        }
    }

    /// A stack whose children are tracks (not a stack nested in a track).
    fn is_bare_stack(d: &Json) -> bool {
        objects(d, "children").iter().any(|c| string(c, "OTIO_SCHEMA").is_some_and(|s| s.starts_with("Track")))
    }

    fn sequence(timeline: &Json, name: &str) -> Result<IXSequence, InterchangeError> {
        let Some(Value::Object(stack)) = timeline.get("tracks") else {
            return Err(InterchangeError::Malformed("no tracks".into()));
        };
        let track_list = objects(stack, "children");

        // The sequence rate: the first rate any item carries.
        fn scan(v: &Value, rate: &mut Option<f64>) {
            if rate.is_some() {
                return;
            }
            match v {
                Value::Object(d) => {
                    if string(d, "OTIO_SCHEMA").is_some_and(|s| s.starts_with("RationalTime"))
                        && let Some(r) = d.get("rate").and_then(Value::as_f64).filter(|&r| r > 0.0)
                    {
                        *rate = Some(r);
                        return;
                    }
                    let mut keys: Vec<&String> = d.keys().collect();
                    keys.sort();
                    for k in keys {
                        scan(&d[k], rate);
                    }
                }
                Value::Array(a) => a.iter().for_each(|x| scan(x, rate)),
                _ => {}
            }
        }
        let mut rate = None;
        if let Some(c) = stack.get("children") {
            scan(c, &mut rate);
        }
        if rate.is_none()
            && let Some(g) = timeline.get("global_start_time")
        {
            scan(g, &mut rate);
        }
        let fd = rate.map_or(Time::new(1, 25), Self::frame_duration);
        let mut seq =
            IXSequence::new(string(timeline, "name").filter(|s| !s.is_empty()).unwrap_or(name), fd, 1920, 1080);

        for t in track_list {
            let schema = string(t, "OTIO_SCHEMA").unwrap_or("");
            if !schema.starts_with("Track") {
                seq.report.note("Nested sequence", Status::Dropped, "a stack inside the tracks is not read");
                continue;
            }
            let kind = if string(t, "kind").map(str::to_lowercase).as_deref() == Some("audio") {
                TrackKind::Audio
            } else {
                TrackKind::Video
            };
            let track = Self::track(t, kind, &mut seq);
            seq.tracks.push(track);
        }
        for m in objects(stack, "markers") {
            let Some(r) = Self::time_range(m.get("marked_range")) else { continue };
            seq.markers.push(IXMarker {
                time: r.start,
                name: string(m, "name").unwrap_or("").to_string(),
                comment: string(m, "comment").unwrap_or("").to_string(),
                duration: r.duration,
                color: Self::marker_color(string(m, "color")),
            });
        }
        Ok(seq)
    }

    /// Frame duration of a rate: NTSC family exact, whole rates, else a rounded thousandth.
    pub(crate) fn frame_duration(rate: f64) -> Time {
        for base in [24i64, 30, 48, 60, 120] {
            if (rate - (base * 1000) as f64 / 1001.0).abs() < 0.01 {
                return Time::new(1001, base * 1000);
            }
        }
        if (rate - rate.round()).abs() < 0.001 {
            return Time::new(1, saturating_i64(rate.round()).max(1));
        }
        Time::new(1000, saturating_i64((rate * 1000.0).round()).max(1))
    }

    /// RationalTime { value, rate } -> exact `Time`.
    pub(crate) fn rational_time(any: Option<&Value>) -> Option<Time> {
        let d = any?.as_object()?;
        let (v, r) = (Self::number(d.get("value"))?, Self::number(d.get("rate"))?);
        if r <= 0.0 || !v.is_finite() {
            return None;
        }
        let fd = Self::frame_duration(r); // seconds per unit
        let whole = v.round();
        if (v - whole).abs() < 1e-6 {
            return Some(fd * saturating_i64(whole));
        }
        // A fractional value: thousandths of a unit.
        Some(Time::scaled_int(fd * saturating_i64((v * 1000.0).round()), 1, 1000))
    }

    fn time_range(any: Option<&Value>) -> Option<TimeRange> {
        let d = any?.as_object()?;
        Some(TimeRange::new(Self::rational_time(d.get("start_time"))?, Self::rational_time(d.get("duration"))?))
    }

    /// An NSNumber read: JSON numbers and booleans.
    fn number(any: Option<&Value>) -> Option<f64> {
        match any? {
            Value::Number(n) => n.as_f64(),
            Value::Bool(b) => Some(f64::from(u8::from(*b))),
            _ => None,
        }
    }

    fn marker_color(s: Option<&str>) -> Option<MarkerColor> {
        match s.map(str::to_uppercase).as_deref() {
            Some("RED") => Some(MarkerColor::Red),
            Some("GREEN") => Some(MarkerColor::Green),
            Some("BLUE") => Some(MarkerColor::Blue),
            Some("CYAN") => Some(MarkerColor::Cyan),
            Some("PURPLE" | "MAGENTA" | "PINK") => Some(MarkerColor::Purple),
            Some("ORANGE") => Some(MarkerColor::Orange),
            Some("YELLOW") => Some(MarkerColor::Yellow),
            Some("WHITE") => Some(MarkerColor::White),
            _ => None,
        }
    }

    fn track(t: &Json, kind: TrackKind, seq: &mut IXSequence) -> IXTrack {
        struct Pending {
            offsets: (Time, Time),
            kind: String,
            name: String,
            outgoing: Option<usize>,
        }
        fn resolve(
            pending: &mut Vec<Pending>,
            incoming: Option<usize>,
            kind: TrackKind,
            track: &mut IXTrack,
            seq: &mut IXSequence,
        ) {
            for p in pending.drain(..) {
                let total = p.offsets.0 + p.offsets.1;
                if total <= Time::ZERO || (p.outgoing.is_none() && incoming.is_none()) {
                    continue;
                }
                let mut alignment = TransitionAlignment::Center;
                if p.offsets.0 == Time::ZERO {
                    alignment = TransitionAlignment::StartAtCut;
                } else if p.offsets.1 == Time::ZERO {
                    alignment = TransitionAlignment::EndAtCut;
                } else if p.offsets.0 != p.offsets.1 {
                    alignment = TransitionAlignment::Custom;
                }
                let mut k = TransitionKind::CrossDissolve;
                if kind == TrackKind::Audio {
                    k = TransitionKind::ConstantPower;
                } else if p.kind != "SMPTE_Dissolve" && !p.kind.is_empty() {
                    let shown = if p.name.is_empty() { &p.kind } else { &p.name };
                    seq.report.note(&format!("Transition {shown}"), Status::Approximated, "played as Cross Dissolve");
                }
                track.transitions.push(IXTransition {
                    kind: k,
                    duration: total,
                    alignment,
                    outgoing: p.outgoing,
                    incoming,
                });
            }
        }
        let mut track = IXTrack::new(kind);
        let mut cursor = Time::ZERO;
        let mut pending: Vec<Pending> = Vec::new();
        let mut last_was_clip = false;
        for item in objects(t, "children") {
            let schema = string(item, "OTIO_SCHEMA").unwrap_or("");
            let range = Self::time_range(item.get("source_range"));
            if schema.starts_with("Gap") {
                cursor += range.map_or(Time::ZERO, |r| r.duration);
                last_was_clip = false;
            } else if schema.starts_with("Transition") {
                let i = Self::rational_time(item.get("in_offset")).unwrap_or(Time::ZERO);
                let o = Self::rational_time(item.get("out_offset")).unwrap_or(Time::ZERO);
                pending.push(Pending {
                    offsets: (i, o),
                    kind: string(item, "transition_type").unwrap_or("").to_string(),
                    name: string(item, "name").unwrap_or("").to_string(),
                    outgoing: if last_was_clip { track.clips.len().checked_sub(1) } else { None },
                });
            } else if schema.starts_with("Clip") {
                let media_ref = item.get("media_reference").and_then(Value::as_object);
                let ref_schema = media_ref.and_then(|r| string(r, "OTIO_SCHEMA")).unwrap_or("");
                let available = Self::time_range(media_ref.and_then(|r| r.get("available_range")));
                let Some(r) = range.or(available).filter(|r| r.duration > Time::ZERO) else {
                    seq.report.note("Clip without range", Status::Dropped, "");
                    resolve(&mut pending, None, kind, &mut track, seq);
                    last_was_clip = false;
                    continue;
                };
                if item.get("enabled").and_then(Value::as_bool) == Some(false) {
                    seq.report.note("Disabled clip", Status::Dropped, "");
                    cursor += r.duration;
                    resolve(&mut pending, None, kind, &mut track, seq);
                    last_was_clip = false;
                    continue;
                }
                if ref_schema.starts_with("GeneratorReference") || ref_schema.starts_with("ImageSequenceReference") {
                    seq.report.note(
                        if ref_schema.starts_with("Generator") { "Generator" } else { "Image sequence" },
                        Status::Dropped,
                        "not read from OpenTimelineIO",
                    );
                    cursor += r.duration;
                    resolve(&mut pending, None, kind, &mut track, seq);
                    last_was_clip = false;
                    continue;
                }
                let clip_name = string(item, "name").unwrap_or("");
                let mut key = if clip_name.is_empty() { "Media".to_string() } else { clip_name.to_string() };
                let mut media_name = key.clone();
                if let Some(url) = media_ref.and_then(|r| string(r, "target_url")).filter(|u| !u.is_empty()) {
                    key = path_from_url(url);
                    media_name = last_path_component(&key);
                } else if let Some(n) = media_ref.and_then(|r| string(r, "name")).filter(|n| !n.is_empty()) {
                    key = n.to_string();
                    media_name = n.to_string();
                }
                let mut speed = ClipSpeed::NORMAL;
                let mut reversed = false;
                let mut hold: Option<Time> = None;
                for e in objects(item, "effects") {
                    let es = string(e, "OTIO_SCHEMA").unwrap_or("");
                    if !(es.starts_with("LinearTimeWarp") || es.starts_with("FreezeFrame")) {
                        seq.report.note("Effect", Status::Dropped, string(e, "name").unwrap_or(es));
                        continue;
                    }
                    let s = if es.starts_with("FreezeFrame") {
                        0.0
                    } else {
                        Self::number(e.get("time_scalar")).unwrap_or(1.0)
                    };
                    if s == 0.0 {
                        hold = Some(r.start);
                    } else if s != 1.0 {
                        speed = ClipSpeed::new(saturating_i64((s.abs() * 10_000.0).round()), 10_000);
                        reversed = s < 0.0;
                    }
                }
                if hold.is_some() {
                    seq.report.note("Speed", Status::Mapped, "hold frame");
                } else if !speed.is_normal() || reversed {
                    seq.report.note("Speed", Status::Mapped, "");
                }
                let mut clip = IXClip::new(clip_name, &key, Some(&media_name), cursor, r.duration, r.start);
                clip.speed = speed;
                clip.reversed = reversed;
                clip.media_duration = available.map(|a| a.duration);
                clip.hold_frame = hold;
                resolve(&mut pending, Some(track.clips.len()), kind, &mut track, seq);
                track.clips.push(clip);
                // Clip markers sit in media time; show them where the clip plays that frame.
                for m in objects(item, "markers") {
                    let Some(mr) = Self::time_range(m.get("marked_range")).filter(|mr| mr.start >= r.start) else {
                        continue;
                    };
                    let local = speed.unscale(mr.start - r.start);
                    if local >= r.duration {
                        continue;
                    }
                    seq.markers.push(IXMarker {
                        time: cursor + local,
                        name: string(m, "name").unwrap_or("").to_string(),
                        comment: string(m, "comment").unwrap_or("").to_string(),
                        duration: Time::ZERO,
                        color: Self::marker_color(string(m, "color")),
                    });
                }
                cursor += r.duration;
                last_was_clip = true;
            } else {
                seq.report.note("Nested sequence", Status::Dropped, "a nested item is not read from OpenTimelineIO");
                cursor += range.map_or(Time::ZERO, |r| r.duration);
                resolve(&mut pending, None, kind, &mut track, seq);
                last_was_clip = false;
            }
        }
        resolve(&mut pending, None, kind, &mut track, seq);
        track
    }
}
