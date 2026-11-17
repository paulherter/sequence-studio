// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: PRDocument.swift. The Premiere project as the importer reads it (sequences, tracks, items, components).

use crate::prcontainer::{NodeExt, ObjectTable, PRTicks, all_named, decode_base64_lenient};
use sq_core_model::EffectColor;
use sq_core_project::media_path_resolver::MediaPathResolver;
use sq_core_time::{Time, Vec2};
use sq_prproj_reader::inflate::{MAX_PROJECT_SIZE, gzip_inflate};
use sq_prproj_reader::{ImportError, Node};

/// One keyframe as Premiere stores it: `time,value,interp,flag,inSlope,inInfluence,outSlope,outInfluence[,spatial...]`.
/// `ticks` is absolute source time of the clip (not clip-local).
#[derive(Debug, Clone, PartialEq)]
pub struct PRKey {
    pub ticks: i64,
    pub value: String,
    /// 0 linear, 4 hold, 5...8 bezier variants (docs/PRPROJ-IMPORT.md section 1).
    pub interpolation: i64,
    pub in_slope: f64,
    pub in_influence: f64,
    pub out_slope: f64,
    pub out_influence: f64,
}

/// A component parameter: static value plus keys. `blob` is the base64 `StartKeyframeValue` of arbitrary-data params (text).
#[derive(Debug, Clone, PartialEq)]
pub struct PRParamValue {
    pub id: Option<i64>,
    pub name: String,
    pub static_value: Option<String>,
    pub keys: Vec<PRKey>,
    pub blob: Option<String>,
}

fn swift_double(s: &str) -> Option<f64> {
    s.parse().ok()
}

impl PRParamValue {
    /// A parameter with a static value and keys, no id, name or blob.
    pub fn new(static_value: Option<String>, keys: Vec<PRKey>) -> PRParamValue {
        PRParamValue { id: None, name: String::new(), static_value, keys, blob: None }
    }

    /// Reads the `StartKeyframe` and `Keyframes` texts of a param.
    pub fn parse(start: Option<&str>, keys: Option<&str>) -> PRParamValue {
        // Second comma-separated field, without splitting the whole string.
        let mut s = start.and_then(|str| {
            let a = str.find(',')?;
            let from = a + 1;
            let to = str[from..].find(',').map_or(str.len(), |i| from + i);
            Some(str[from..to].to_string())
        });
        // Point params of Premiere-authored .mogrt files store x and y as separate fields ("ticks,x,y,0,0,0,0,0,0,5,4,...", 15
        // fields) where project files use "x:y". Join them so every reader sees one form; scalars have 8 fields.
        if let (Some(st), Some(x)) = (start, s.as_ref())
            && !x.contains(':')
            && st.bytes().filter(|&b| b == b',').count() >= 14
        {
            let f: Vec<&str> = st.splitn(4, ',').collect();
            if f.len() >= 3 {
                s = Some(format!("{}:{}", f[1], f[2]));
            }
        }
        let mut out = Vec::new();
        for k in keys.unwrap_or("").split(';').filter(|k| !k.is_empty()) {
            let mut f: Vec<String> = k.split(',').map(str::to_string).collect();
            let Some(t) = (if f.len() >= 2 { f[0].parse::<i64>().ok() } else { None }) else { continue };
            // A point key of a .mogrt: "ticks,x,y,interpolation,..." (one field more than a scalar key).
            if f.len() >= 15 && !f[1].contains(':') {
                f[1] = format!("{}:{}", f[1], f[2]);
                f.remove(2);
            }
            let d = |i: usize| f.get(i).and_then(|v| swift_double(v)).unwrap_or(0.0);
            out.push(PRKey {
                ticks: t,
                value: f[1].clone(),
                interpolation: if f.len() > 2 { f[2].parse().unwrap_or(0) } else { 0 },
                in_slope: d(4),
                in_influence: d(5),
                out_slope: d(6),
                out_influence: d(7),
            });
        }
        out.sort_by_key(|k| k.ticks);
        PRParamValue::new(s, out)
    }

    /// Has keys.
    pub fn is_animated(&self) -> bool {
        !self.keys.is_empty()
    }

    /// A number, tolerating spaces and a trailing dot.
    pub fn double(s: Option<&str>) -> Option<f64> {
        let t = s?.trim_matches(is_swift_whitespace);
        if t.is_empty() {
            return None;
        }
        swift_double(t.strip_suffix('.').unwrap_or(t))
    }

    /// `x:y`.
    pub fn point(s: Option<&str>) -> Option<Vec2> {
        let parts: Vec<&str> = s?.split(':').filter(|p| !p.is_empty()).collect();
        if parts.len() != 2 {
            return None;
        }
        Some(Vec2::new(Self::double(Some(parts[0]))?, Self::double(Some(parts[1]))?))
    }

    /// `true` / `false`.
    pub fn bool(s: Option<&str>) -> Option<bool> {
        match s {
            Some("true") => Some(true),
            Some("false") => Some(false),
            _ => None,
        }
    }

    /// Packed 64-bit color, 16 bit per channel ARGB with the 8-bit value in the high byte
    /// (18374686479671623680 = 0xFF00_0000_0000_0000 = opaque black).
    pub fn color(s: Option<&str>) -> Option<EffectColor> {
        let v: u64 = s?.parse().ok()?;
        let ch = |shift: u64| ((v >> (shift + 8)) & 0xFF) as f64 / 255.0;
        Some(EffectColor { red: ch(32), green: ch(16), blue: ch(0), alpha: ch(48) })
    }
}

/// Foundation's `.whitespaces` set: tab and the Unicode space separators (no line breaks).
pub(crate) fn is_swift_whitespace(c: char) -> bool {
    c == '\t'
        || (c.is_whitespace() && !matches!(c, '\n' | '\r' | '\u{b}' | '\u{c}' | '\u{85}' | '\u{2028}' | '\u{2029}'))
}

/// A video or audio filter of an item.
#[derive(Debug, Clone)]
pub struct PRComponent {
    /// `MatchName` of a video filter (`AE.ADBE Motion`), `FilterMatchName` of an audio filter.
    pub match_name: String,
    pub display_name: String,
    pub params: Vec<PRParamValue>,
    pub is_audio: bool,
}

impl PRComponent {
    /// The param with this `ParameterID`.
    pub fn param(&self, id: i64) -> Option<&PRParamValue> {
        self.params.iter().find(|p| p.id == Some(id))
    }

    /// Audio filter params have no ParameterID: by position.
    pub fn param_at(&self, index: usize) -> Option<&PRParamValue> {
        self.params.get(index)
    }
}

/// A media item of the project.
#[derive(Debug, Clone, PartialEq)]
pub struct PRMedia {
    pub key: String,
    pub title: String,
    /// Absolute file path as stored (POSIX or Windows, often from another machine); `None` for graphics / generated media
    /// (Premiere stores a number there).
    pub path: Option<String>,
    /// Premiere's `RelativePath` (relative to the project file's folder), when stored.
    pub relative_path: Option<String>,
    /// Pixel aspect ratio Premiere read from the file (`VideoStream/OriginalPAR`, width / height of one pixel); 1 = square.
    /// `None` = the project does not say (no `OriginalPAR`): unknown, not square.
    pub pixel_aspect: Option<f64>,
    /// Color profile Premiere assigned to the file (`VideoStream/OriginalColorSpace` colorProfileName), e.g.
    /// "BT.709,8-bit,Display-Referred", "Sony S-Log3/S-Gamut3.Cine", "BT.709 RGB Full".
    pub color_profile: Option<String>,
}

/// What an item plays.
#[derive(Debug, Clone)]
pub enum PRSource {
    Media(PRMedia),
    Sequence {
        id: String,
    },
    /// Media without a file: Essential Graphics, mattes, adjustment layers.
    Graphic {
        title: String,
    },
    /// Color matte (Farbfläche): a numberless media whose `ImporterPrefs` hold the 8-bit RGB color.
    ColorMatte {
        rgb: [u8; 3],
    },
    Unknown,
}

/// A clip on a track.
#[derive(Debug, Clone)]
pub struct PRItem {
    pub name: String,
    /// Timeline range and source range, ticks.
    pub start: i64,
    pub end: i64,
    pub in_point: i64,
    pub out_point: i64,
    pub speed: f64,
    pub source: PRSource,
    pub components: Vec<PRComponent>,
    pub is_adjustment_layer: bool,
    pub is_audio: bool,
    /// Right-click > Audio Gain: linear factor stored as `AudioClip/Gain` (1 = 0 dB). Separate from the Volume level.
    pub clip_gain: f64,
    /// Clip markers (`VideoClip`/`AudioClip` > `Clip/MarkerOwner`), times in media ticks like `in_point`. Premiere keeps
    /// them on the master clip and copies them to every instance, so most lie outside the used range.
    pub markers: Vec<PRMarker>,
}

impl PRItem {
    /// The components with this match name.
    pub fn components_named(&self, match_name: &str) -> Vec<&PRComponent> {
        self.components.iter().filter(|c| c.match_name == match_name).collect()
    }
}

/// A transition between two clips of a track.
#[derive(Debug, Clone)]
pub struct PRTransitionItem {
    pub start: i64,
    pub end: i64,
    pub match_name: String,
}

/// A video or audio track.
#[derive(Debug, Clone, Default)]
pub struct PRTrack {
    pub items: Vec<PRItem>,
    pub transitions: Vec<PRTransitionItem>,
    pub is_muted: bool,
}

/// A sequence or clip marker (`Markers/Marker/Second -> Marker/DVAMarker` JSON). Checked 2026-10-06 on all 251 markers in
/// the maintainer's 16 projects (all clip markers, no sequence markers): each has only mMarkerID, mStartTime {ticks: JSON number} and
/// mType "Comment". mDuration, mName, mComment and mColorIndex are absent when at their default; their names are not
/// confirmed by a real file, so a missing key falls back to the default (0 / "" / green).
#[derive(Debug, Clone, PartialEq)]
pub struct PRMarker {
    pub ticks: i64,
    pub duration_ticks: i64,
    pub name: String,
    pub comment: String,
    /// Premiere's marker color index (0 green, 1 red, 2 purple, 3 orange, 4 yellow, 5 white, 6 blue, 7 cyan).
    pub color_index: i64,
}

/// A sequence with its tracks.
#[derive(Debug, Clone)]
pub struct PRSequence {
    pub id: String,
    pub name: String,
    pub width: i64,
    pub height: i64,
    pub frame_duration: Time,
    pub video_tracks: Vec<PRTrack>,
    pub audio_tracks: Vec<PRTrack>,
    pub markers: Vec<PRMarker>,
}

/// All sequences of a project.
#[derive(Debug, Clone)]
pub struct PRDocument {
    pub sequences: Vec<PRSequence>,
}

/// .prproj (gzip XML) -> `PRDocument`. Tolerant: unknown nodes are skipped, never thrown on.
pub struct PRReader;

fn json_i64(v: &serde_json::Value) -> Option<i64> {
    // NSNumber.int64Value: floats truncate, booleans are 0 / 1.
    match v {
        serde_json::Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        serde_json::Value::Bool(b) => Some(i64::from(*b)),
        _ => None,
    }
}

impl PRReader {
    /// Reads a project from the bytes of a .prproj (gzip) or an uncompressed XML export.
    pub fn read(data: &[u8]) -> Result<PRDocument, ImportError> {
        let table = ObjectTable::new(&gzip_inflate(data, MAX_PROJECT_SIZE)?)?;
        Ok(PRDocument {
            sequences: all_named(&table, "Sequence").into_iter().filter_map(|s| Self::sequence(s, &table)).collect(),
        })
    }

    pub(crate) fn sequence(s: &Node, t: &ObjectTable) -> Option<PRSequence> {
        let id = s.object_id()?;
        let mut seq = PRSequence {
            id: id.to_string(),
            name: s.text_at("Name").unwrap_or("Sequence").to_string(),
            width: 1920,
            height: 1080,
            frame_duration: Time::new(1, 30),
            video_tracks: Vec::new(),
            audio_tracks: Vec::new(),
            markers: Vec::new(),
        };
        for g in s.children_at("TrackGroups/TrackGroup") {
            let Some(group) = t.deref(g.child("Second")) else { continue };
            let tracks: Vec<PRTrack> = group
                .children_at("TrackGroup/Tracks/Track")
                .into_iter()
                .filter_map(|n| t.deref(Some(n)))
                .map(|n| Self::track(n, t))
                .collect();
            match group.name.as_str() {
                "VideoTrackGroup" => {
                    if let Some(f) = group.int_at("TrackGroup/FrameRate").filter(|&f| f > 0) {
                        seq.frame_duration = PRTicks::frame_duration(f);
                    }
                    if let Some(r) = group
                        .text_at("FrameRect")
                        .map(|x| x.split(',').filter_map(|p| p.parse::<i64>().ok()).collect::<Vec<_>>())
                        && r.len() == 4
                        && let (Some(w), Some(h)) = (r[2].checked_sub(r[0]), r[3].checked_sub(r[1]))
                        && (1..=65_536).contains(&w)
                        && (1..=65_536).contains(&h)
                    {
                        seq.width = w;
                        seq.height = h;
                    }
                    seq.video_tracks = tracks;
                }
                "AudioTrackGroup" => seq.audio_tracks = tracks,
                _ => {}
            }
        }
        seq.markers = Self::markers(s.child("MarkerOwner/Markers"), t);
        Some(seq)
    }

    pub(crate) fn markers(owner: Option<&Node>, t: &ObjectTable) -> Vec<PRMarker> {
        let Some(list) = t.deref(owner) else { return Vec::new() };
        let mut out: Vec<PRMarker> = list
            .children_at("Markers/Marker")
            .into_iter()
            .filter_map(|m| {
                let json = t.deref(m.child("Second"))?.text_at("DVAMarker")?;
                let root: serde_json::Value = serde_json::from_str(json).ok()?;
                let d = root.as_object()?.get("DVAMarker")?.as_object()?;
                let ticks = |key: &str| -> i64 {
                    let Some(o) = d.get(key).and_then(|v| v.as_object()) else { return 0 };
                    match o.get("ticks") {
                        Some(n @ (serde_json::Value::Number(_) | serde_json::Value::Bool(_))) => {
                            json_i64(n).unwrap_or(0)
                        }
                        Some(serde_json::Value::String(s)) => s.parse().unwrap_or(0),
                        _ => 0,
                    }
                };
                let text = |key: &str| d.get(key).and_then(|v| v.as_str()).unwrap_or("").to_string();
                Some(PRMarker {
                    ticks: ticks("mStartTime"),
                    duration_ticks: ticks("mDuration"),
                    name: text("mName"),
                    comment: text("mComment"),
                    color_index: d.get("mColorIndex").and_then(json_i64).unwrap_or(0),
                })
            })
            .collect();
        out.sort_by_key(|m| m.ticks);
        out
    }

    pub(crate) fn track(n: &Node, t: &ObjectTable) -> PRTrack {
        let mut items: Vec<PRItem> = n
            .children_at("ClipTrack/ClipItems/TrackItems/TrackItem")
            .into_iter()
            .filter_map(|x| t.deref(Some(x)))
            .filter_map(|x| Self::item(x, t))
            .collect();
        let transitions = n
            .children_at("ClipTrack/TransitionItems/TrackItems/TrackItem")
            .into_iter()
            .filter_map(|x| t.deref(Some(x)))
            .filter_map(|tr| {
                let ti = tr.descendant("TrackItem")?;
                let end = ti.int_at("End")?;
                Some(PRTransitionItem {
                    start: ti.int_at("Start").unwrap_or(0),
                    end,
                    match_name: tr.descendant("MatchName").map(|m| m.text.clone()).unwrap_or_default(),
                })
            })
            .collect();
        items.sort_by_key(|i| i.start);
        PRTrack { items, transitions, is_muted: n.text_at("ClipTrack/Track/IsMuted") == Some("true") }
    }

    /// A file path as Premiere stores it: POSIX ("/Volumes/…"), a Windows drive ("D:\\…", "D:/…") or UNC ("\\\\nas\\…").
    /// Graphics and generated media store a number there instead.
    pub(crate) fn is_file_path(p: &str) -> bool {
        if p.starts_with('/') || p.starts_with("\\\\") {
            return true;
        }
        let c: Vec<char> = p.chars().take(3).collect();
        c.len() == 3 && c[0].is_ascii_alphabetic() && c[1] == ':' && (c[2] == '\\' || c[2] == '/')
    }

    pub(crate) fn item(n: &Node, t: &ObjectTable) -> Option<PRItem> {
        let end = n.int_at("ClipTrackItem/TrackItem/End")?;
        let start = n.int_at("ClipTrackItem/TrackItem/Start").unwrap_or(0);
        let sub = t.deref(n.child("ClipTrackItem/SubClip"));
        let clip = t.deref(sub.and_then(|s| s.child("Clip")));
        let mut source = PRSource::Unknown;
        if let Some(src) = t.deref(clip.and_then(|c| c.child("Clip/Source"))) {
            if let Some(seq) = src.child("SequenceSource/Sequence").and_then(|n| n.reference()) {
                source = PRSource::Sequence { id: seq.to_string() };
            } else if let Some(m) = t.deref(src.child("MediaSource/Media")) {
                // First non-empty of ActualMediaFilePath / FilePath (an empty element must not hide the other).
                let path = [m.text_at("ActualMediaFilePath"), m.text_at("FilePath")]
                    .into_iter()
                    .flatten()
                    .find(|s| !s.is_empty())
                    .unwrap_or("");
                let title = m.text_at("Title").map_or_else(|| MediaPathResolver::file_name_of(path), str::to_string);
                let mut media = PRMedia {
                    key: m.object_id().unwrap_or(path).to_string(),
                    title: title.clone(),
                    path: Some(path.to_string()),
                    relative_path: m.text_at("RelativePath").filter(|s| !s.is_empty()).map(str::to_string),
                    pixel_aspect: None,
                    color_profile: None,
                };
                let stream = t.deref(m.child("VideoStream"));
                if let Some(par) = stream
                    .and_then(|s| s.text_at("OriginalPAR"))
                    .map(|x| x.split(',').filter_map(swift_double).collect::<Vec<_>>())
                    && par.len() == 2
                    && par[0] > 0.0
                    && par[1] > 0.0
                {
                    media.pixel_aspect = Some(par[0] / par[1]);
                }
                media.color_profile =
                    stream.and_then(|s| s.text_at("OriginalColorSpace")).and_then(Self::color_profile_name);
                if Self::is_file_path(path) {
                    source = PRSource::Media(media);
                } else if let Some(rgb) = Self::matte_color(m, t) {
                    source = PRSource::ColorMatte { rgb };
                } else {
                    source = PRSource::Graphic { title };
                }
            }
        }
        let comps: Vec<PRComponent> = t
            .deref(n.child("ClipTrackItem/ComponentOwner/Components"))
            .map(|c| {
                c.children_at("ComponentChain/Components/Component")
                    .into_iter()
                    .filter_map(|x| t.deref(Some(x)))
                    .filter_map(|x| Self::component(x, t))
                    .collect()
            })
            .unwrap_or_default();
        let is_audio = n.name.starts_with("Audio");
        let gain =
            if is_audio { PRParamValue::double(clip.and_then(|c| c.text_at("Gain"))).unwrap_or(1.0) } else { 1.0 };
        let adjustment = clip.and_then(|c| c.text_at("AdjustmentLayer")) == Some("true")
            || clip.and_then(|c| c.text_at("Clip/AdjustmentLayer")) == Some("true");
        Some(PRItem {
            name: sub.and_then(|s| s.text_at("Name")).unwrap_or("").to_string(),
            start,
            end,
            in_point: clip.and_then(|c| c.int_at("Clip/InPoint")).unwrap_or(0),
            out_point: clip.and_then(|c| c.int_at("Clip/OutPoint")).unwrap_or(0),
            speed: PRParamValue::double(clip.and_then(|c| c.text_at("Clip/PlaybackSpeed"))).unwrap_or(1.0),
            source,
            components: comps,
            is_adjustment_layer: adjustment,
            is_audio,
            clip_gain: if gain > 0.0 { gain } else { 1.0 },
            markers: Self::markers(clip.and_then(|c| c.child("Clip/MarkerOwner/Markers")), t),
        })
    }

    /// Color mattes store `ImporterPrefs` = R, G, B, 0, 1, 0, 0, 0 (checked on 23 mattes of a real project); graphics have none.
    pub(crate) fn matte_color(media: &Node, t: &ObjectTable) -> Option<[u8; 3]> {
        let prefs = media.child("ImporterPrefs")?;
        let b64 = if prefs.text.is_empty() {
            prefs.attributes.get("BinaryHash").and_then(|h| t.binaries.get(h)).cloned().unwrap_or_default()
        } else {
            prefs.text.clone()
        };
        let d = decode_base64_lenient(&b64)?;
        if d.len() == 8 && d[4] == 1 { Some([d[0], d[1], d[2]]) } else { None }
    }

    /// `{"baseColorProfile":{"colorProfileName":"BT.709 RGB Full"},...}` -> "BT.709 RGB Full".
    pub(crate) fn color_profile_name(json: &str) -> Option<String> {
        let obj: serde_json::Value = serde_json::from_str(json).ok()?;
        obj.as_object()?.get("baseColorProfile")?.as_object()?.get("colorProfileName")?.as_str().map(str::to_string)
    }

    pub(crate) fn component(c: &Node, t: &ObjectTable) -> Option<PRComponent> {
        let is_audio = c.name == "AudioFilterComponent";
        let base = if is_audio { c.child("AudioComponent/Component") } else { c.child("Component") };
        let match_name =
            (if is_audio { c.text_at("FilterMatchName") } else { c.text_at("MatchName") }).unwrap_or("").to_string();
        let params = base
            .map(|b| b.children_at("Params/Param"))
            .unwrap_or_default()
            .into_iter()
            .filter_map(|x| t.deref(Some(x)))
            .map(|p| {
                let mut v = PRParamValue::parse(p.text_at("StartKeyframe"), p.text_at("Keyframes"));
                v.id = p.text_at("ParameterID").and_then(|s| s.parse().ok());
                v.name = p.text_at("Name").unwrap_or("").to_string();
                if let Some(b) = p.child("StartKeyframeValue") {
                    v.blob = if b.text.is_empty() {
                        b.attributes.get("BinaryHash").and_then(|h| t.binaries.get(h)).cloned()
                    } else {
                        Some(b.text.clone())
                    };
                }
                v
            })
            .collect();
        Some(PRComponent {
            display_name: base
                .and_then(|b| b.text_at("DisplayName"))
                .map_or_else(|| match_name.clone(), str::to_string),
            match_name,
            params,
            is_audio,
        })
    }
}
