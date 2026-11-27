//! The "see and understand" endpoints: capture, source frames, transcript, levels, scenes, Premiere import.
//! This file only parses and validates the wire form (strict keys, like the commit operations); the host does the work
//! and answers with files written under the app's cache folder plus their paths.

use crate::edit_operation::{check_strict_keys, optional, required};
use crate::time_limits::WireTime;
use serde_json::{Map, Value};
use sq_core_time::{Id, Time};

/// A refused or failed perceive call: the HTTP status and a short reason.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PerceiveError {
    /// HTTP status.
    pub status: u16,
    /// What went wrong.
    pub message: String,
}

impl PerceiveError {
    /// An error with `status`.
    pub fn new(status: u16, message: impl Into<String>) -> PerceiveError {
        PerceiveError { status, message: message.into() }
    }
}

/// One word of `addCaptions {words}`: its text and where it is spoken, in sequence time.
#[derive(Clone, Debug, PartialEq)]
pub struct CaptionWordSpec {
    /// The word.
    pub text: String,
    /// First instant.
    pub from: Time,
    /// End.
    pub to: Time,
}

/// Most words one `addCaptions` request may carry.
pub const MAX_CAPTION_WORDS: usize = 5000;

/// `contactSheet {from,to,count}`: one PNG grid of `count` frames between `from` and `to`, each with its timecode.
#[derive(Clone, Debug, PartialEq)]
pub struct ContactSheet {
    /// First frame time.
    pub from: Time,
    /// Last frame time.
    pub to: Time,
    /// How many tiles.
    pub count: u32,
}

/// What a source-frames or levels call points at.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Target {
    /// A media item of the project.
    Media(Id),
    /// A clip of the project.
    Clip(Id),
    /// A sequence of the project.
    Sequence(Id),
}

/// One request of the perceive family.
#[derive(Clone, Debug, PartialEq)]
pub enum PerceiveRequest {
    /// `POST /v1/capture`.
    Capture { sequence: Option<Id>, at: Vec<Time>, width: Option<u32>, contact_sheet: Option<ContactSheet> },
    /// `POST /v1/media/frames`: `at` or `count` evenly spaced frames over the media.
    MediaFrames { media: Id, at: Vec<Time>, count: Option<u32>, width: Option<u32> },
    /// `POST /v1/media/transcript` (media or clip).
    Transcript { target: Target },
    /// `POST /v1/media/levels`.
    Levels { target: Target, from: Option<Time>, to: Option<Time> },
    /// `POST /v1/media/scenes`.
    Scenes { media: Id },
    /// `POST /v1/importPremiere`.
    ImportPremiere { path: String, dry_run: bool },
    /// `POST /v1/addCaptions`: the app's own Create Captions on a clip's or a sequence's speech, one undo step.
    AddCaptions {
        target: Target,
        style: Option<String>,
        word_by_word: bool,
        position: CaptionSpot,
        look: CaptionLookSpec,
        /// The words to caption (sequence time) instead of a transcript of the speech.
        words: Option<Vec<CaptionWordSpec>>,
        /// The name of a look in the user's Look store (the Captions panel's saved looks).
        saved_look: Option<String>,
    },
    /// `GET /v1/captionStyles`.
    CaptionStyles,
    /// `GET /v1/fonts`: the families the font picker lists.
    Fonts,
}

/// Where added captions sit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CaptionSpot {
    /// Upper third.
    Top,
    /// Frame center.
    Center,
    /// Lower third (the usual subtitle place).
    Bottom,
}

/// Caption looks the API knows (the built-in styles of the Captions panel).
pub const CAPTION_STYLES: [&str; 4] = ["default", "outline", "pill", "paul"];

/// A part of the look that is switched off or set.
#[derive(Clone, Debug, PartialEq)]
pub enum Part<T> {
    /// Off (`false` on the wire).
    Off,
    /// On with these values.
    On(T),
}

/// The shadow of a caption: color black at `opacity`, `blur` and `offset` (down) in text points.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ShadowSpec {
    /// Blur radius.
    pub blur: f64,
    /// Opacity 0...1.
    pub opacity: f64,
    /// Offset down.
    pub offset: f64,
}

/// The box (pill) behind a caption.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BoxSpec {
    /// Fill color r, g, b, a.
    pub color: [f64; 4],
    /// Corner radius.
    pub radius: f64,
}

/// What `addCaptions` may change of the look at creation; unset keys keep the base style.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct CaptionLookSpec {
    /// 1...3 words per caption (1 = word by word).
    pub words_per_caption: Option<u8>,
    /// Text size.
    pub size: Option<f64>,
    /// Text color r, g, b, a.
    pub color: Option<[f64; 4]>,
    /// Shadow.
    pub shadow: Option<Part<ShadowSpec>>,
    /// Box behind the text.
    pub box_: Option<Part<BoxSpec>>,
    /// Vertical place of the caption, 0 (top) ... 1 (bottom) of the frame.
    pub position_y: Option<f64>,
    /// Font family or PostScript name.
    pub font: Option<String>,
    /// Weight 100...900.
    pub weight: Option<i64>,
}

/// `words: [{text, from, to}]` (sequence seconds, rational or bare), sorted by start.
fn parse_caption_words(v: &Value) -> Result<Vec<CaptionWordSpec>, String> {
    let list = v.as_array().filter(|a| !a.is_empty()).ok_or("words: a non-empty list of {text, from, to}")?;
    if list.len() > MAX_CAPTION_WORDS {
        return Err(format!("words: at most {MAX_CAPTION_WORDS} words"));
    }
    let mut out = Vec::with_capacity(list.len());
    for (i, w) in list.iter().enumerate() {
        let o = w.as_object().ok_or_else(|| format!("words[{i}]: an object {{text, from, to}}"))?;
        check_strict_keys(o, &["text", "from", "to"], &format!("words[{i}]"))?;
        let text: String = required(o, "text").map_err(|e| format!("words[{i}]: {e}"))?;
        let (from, to) = (
            required::<WireTime>(o, "from").map_err(|e| format!("words[{i}]: {e}"))?.time,
            required::<WireTime>(o, "to").map_err(|e| format!("words[{i}]: {e}"))?.time,
        );
        if text.trim().is_empty() {
            return Err(format!("words[{i}]: text must not be empty"));
        }
        if from < Time::ZERO || to <= from {
            return Err(format!("words[{i}]: needs 0 <= from < to"));
        }
        out.push(CaptionWordSpec { text, from, to });
    }
    out.sort_by_key(|w| w.from);
    Ok(out)
}

impl CaptionLookSpec {
    /// True when no key asks for a changed look.
    pub fn is_empty(&self) -> bool {
        *self == CaptionLookSpec::default()
    }

    /// The named style "paul": white Inter Bold, 2 words, y 0.7068, soft shadow, size 70 px at 1080 wide, pop 90 -> 105 -> 100 %, no box.
    pub fn paul() -> CaptionLookSpec {
        CaptionLookSpec {
            words_per_caption: Some(2),
            size: None,
            color: Some([1.0, 1.0, 1.0, 1.0]),
            shadow: Some(Part::On(ShadowSpec { blur: 8.0, opacity: 0.6, offset: 2.0 })),
            box_: Some(Part::Off),
            position_y: Some(0.7068),
            font: Some("Inter-Bold".into()),
            weight: Some(700),
        }
    }

    fn parse(m: &Map<String, Value>, base: CaptionLookSpec) -> Result<CaptionLookSpec, String> {
        use crate::clip_params::parse_rgba;
        let mut l = base;
        let num = |v: &Value, k: &str| v.as_f64().filter(|x| x.is_finite()).ok_or_else(|| format!("{k}: a number"));
        if let Some(v) = m.get("wordsPerCaption") {
            let n = v.as_u64().filter(|n| (1..=3).contains(n)).ok_or("wordsPerCaption: 1, 2 or 3")?;
            l.words_per_caption = Some(n as u8);
        }
        if let Some(v) = m.get("size") {
            let n = num(v, "size")?;
            if !(1.0..=1000.0).contains(&n) {
                return Err("size: 1...1000".into());
            }
            l.size = Some(n);
        }
        if let Some(v) = m.get("color") {
            l.color = Some(parse_rgba(v).map_err(|e| format!("color: {e}"))?);
        }
        if let Some(v) = m.get("shadow") {
            l.shadow = Some(match v {
                Value::Bool(false) => Part::Off,
                Value::Object(o) => {
                    check_strict_keys(o, &["blur", "opacity", "offset"], "shadow")?;
                    let get = |k: &str, d: f64| o.get(k).map_or(Ok(d), |x| num(x, k));
                    let (blur, opacity, offset) = (get("blur", 8.0)?, get("opacity", 0.6)?, get("offset", 2.0)?);
                    if blur < 0.0 || !(0.0..=1.0).contains(&opacity) {
                        return Err("shadow: blur >= 0, opacity 0...1".into());
                    }
                    Part::On(ShadowSpec { blur, opacity, offset })
                }
                _ => return Err("shadow: false or {blur, opacity, offset}".into()),
            });
        }
        if let Some(v) = m.get("box") {
            l.box_ = Some(match v {
                Value::Bool(false) => Part::Off,
                Value::Object(o) => {
                    check_strict_keys(o, &["color", "radius"], "box")?;
                    let color = o
                        .get("color")
                        .map_or(Ok([0.0, 0.0, 0.0, 0.6]), parse_rgba)
                        .map_err(|e| format!("box.color: {e}"))?;
                    let radius = o.get("radius").map_or(Ok(12.0), |x| num(x, "box.radius"))?;
                    if radius < 0.0 {
                        return Err("box.radius: at least 0".into());
                    }
                    Part::On(BoxSpec { color, radius })
                }
                _ => return Err("box: false or {color, radius}".into()),
            });
        }
        if let Some(v) = m.get("positionY") {
            let n = num(v, "positionY")?;
            if !(0.0..=1.0).contains(&n) {
                return Err("positionY: 0...1".into());
            }
            l.position_y = Some(n);
        }
        if let Some(v) = m.get("font") {
            l.font = Some(v.as_str().filter(|f| !f.trim().is_empty()).ok_or("font: a font name")?.to_string());
        }
        if let Some(v) = m.get("weight") {
            let w = crate::text_layers::weight(v).map_err(|e| e.to_string())?;
            if sq_text::text_style::FontWeight::from_raw(w).is_none() {
                return Err("weight: 100, 300, 400, 500, 600, 700, 800 or 900".into());
            }
            l.weight = Some(w);
        }
        Ok(l)
    }
}

/// Most frames one call renders (each is a full render).
pub const MAX_FRAMES: usize = 24;
/// Widest picture a call may ask for.
pub const MAX_WIDTH: u32 = 4096;

impl PerceiveRequest {
    /// The POST routes of this family.
    pub const POST_PATHS: [&'static str; 7] = [
        "/v1/addCaptions",
        "/v1/capture",
        "/v1/media/frames",
        "/v1/media/transcript",
        "/v1/media/levels",
        "/v1/media/scenes",
        "/v1/importPremiere",
    ];

    /// Parses the body of `path`. Unknown keys are refused.
    pub fn parse(path: &str, body: &[u8]) -> Result<PerceiveRequest, String> {
        let value: Value = if body.is_empty() {
            Value::Object(Map::new())
        } else {
            serde_json::from_slice(body).map_err(|e| format!("invalid request: {e}"))?
        };
        let Value::Object(m) = value else { return Err("the body must be a JSON object".into()) };
        let width = |m: &Map<String, Value>| -> Result<Option<u32>, String> {
            let w: Option<u32> = optional(m, "width")?;
            match w {
                Some(0) => Err("width: must be at least 1".into()),
                Some(w) if w > MAX_WIDTH => Err(format!("width: at most {MAX_WIDTH}")),
                w => Ok(w),
            }
        };
        match path {
            "/v1/capture" => {
                check_strict_keys(&m, &["sequence", "at", "width", "contactSheet"], "capture request")?;
                let sheet =
                    optional::<ContactSheetWire>(&m, "contactSheet")?.map(ContactSheetWire::checked).transpose()?;
                let at = times(&m, "at")?;
                if at.is_empty() && sheet.is_none() {
                    return Err("give `at` or `contactSheet`".into());
                }
                if at.len() > MAX_FRAMES {
                    return Err(format!("at: at most {MAX_FRAMES} times"));
                }
                Ok(PerceiveRequest::Capture {
                    sequence: optional(&m, "sequence")?,
                    at,
                    width: width(&m)?,
                    contact_sheet: sheet,
                })
            }
            "/v1/media/frames" => {
                check_strict_keys(&m, &["media", "at", "count", "width"], "media frames request")?;
                let at = times(&m, "at")?;
                let count: Option<u32> = optional(&m, "count")?;
                if at.is_empty() == count.is_none() {
                    return Err("give exactly one of `at` and `count`".into());
                }
                if at.len() > MAX_FRAMES || count.is_some_and(|c| c == 0 || c as usize > MAX_FRAMES) {
                    return Err(format!("at most {MAX_FRAMES} frames per call"));
                }
                Ok(PerceiveRequest::MediaFrames { media: required(&m, "media")?, at, count, width: width(&m)? })
            }
            "/v1/media/transcript" => {
                check_strict_keys(&m, &["media", "clip"], "transcript request")?;
                match (optional(&m, "media")?, optional(&m, "clip")?) {
                    (Some(id), None) => Ok(PerceiveRequest::Transcript { target: Target::Media(id) }),
                    (None, Some(id)) => Ok(PerceiveRequest::Transcript { target: Target::Clip(id) }),
                    _ => Err("give exactly one of `media` and `clip`".into()),
                }
            }
            "/v1/media/levels" => {
                check_strict_keys(&m, &["media", "clip", "sequence", "from", "to"], "levels request")?;
                let target = match (optional(&m, "media")?, optional(&m, "clip")?, optional(&m, "sequence")?) {
                    (Some(id), None, None) => Target::Media(id),
                    (None, Some(id), None) => Target::Clip(id),
                    (None, None, Some(id)) => Target::Sequence(id),
                    _ => return Err("give exactly one of `media`, `clip` and `sequence`".into()),
                };
                let time = |k: &str| optional::<WireTime>(&m, k).map(|t| t.map(|w| w.time));
                Ok(PerceiveRequest::Levels { target, from: time("from")?, to: time("to")? })
            }
            "/v1/addCaptions" => {
                check_strict_keys(
                    &m,
                    &[
                        "clip",
                        "sequence",
                        "style",
                        "wordByWord",
                        "position",
                        "wordsPerCaption",
                        "size",
                        "color",
                        "shadow",
                        "box",
                        "positionY",
                        "font",
                        "weight",
                        "words",
                        "look",
                    ],
                    "addCaptions request",
                )?;
                let target = match (optional(&m, "clip")?, optional(&m, "sequence")?) {
                    (Some(id), None) => Target::Clip(id),
                    (None, Some(id)) => Target::Sequence(id),
                    _ => return Err("give exactly one of `clip` and `sequence`".into()),
                };
                let style: Option<String> = optional(&m, "style")?;
                if let Some(s) = &style
                    && !CAPTION_STYLES.contains(&s.as_str())
                {
                    return Err(format!("style: unknown '{s}'; known: {}", CAPTION_STYLES.join(", ")));
                }
                let position = match optional::<String>(&m, "position")?.as_deref() {
                    None | Some("center") => CaptionSpot::Center,
                    Some("top") => CaptionSpot::Top,
                    Some("bottom") => CaptionSpot::Bottom,
                    Some(o) => return Err(format!("position: unknown '{o}'; known: top, center, bottom")),
                };
                let base =
                    if style.as_deref() == Some("paul") { CaptionLookSpec::paul() } else { CaptionLookSpec::default() };
                let look = CaptionLookSpec::parse(&m, base)?;
                let word_by_word = match look.words_per_caption {
                    Some(n) => n == 1,
                    None => optional(&m, "wordByWord")?.unwrap_or(true),
                };
                let saved_look: Option<String> = optional(&m, "look")?;
                if saved_look.is_some() {
                    let own = [
                        "style",
                        "wordByWord",
                        "wordsPerCaption",
                        "size",
                        "color",
                        "shadow",
                        "box",
                        "positionY",
                        "font",
                        "weight",
                    ];
                    if let Some(k) = own.iter().find(|k| m.contains_key(**k)) {
                        return Err(format!(
                            "look: a saved look carries its own style and segmentation; leave out `{k}` (only `position`, `words`, `clip`/`sequence` combine with it)"
                        ));
                    }
                    if saved_look.as_deref().is_some_and(|n| n.trim().is_empty()) {
                        return Err("look: the name of a saved look".into());
                    }
                }
                let words = match m.get("words") {
                    None | Some(Value::Null) => None,
                    Some(v) => Some(parse_caption_words(v)?),
                };
                Ok(PerceiveRequest::AddCaptions { target, style, word_by_word, position, look, words, saved_look })
            }
            "/v1/media/scenes" => {
                check_strict_keys(&m, &["media"], "scenes request")?;
                Ok(PerceiveRequest::Scenes { media: required(&m, "media")? })
            }
            "/v1/importPremiere" => {
                check_strict_keys(&m, &["path", "dryRun"], "importPremiere request")?;
                let path: String = required(&m, "path")?;
                if path.trim().is_empty() {
                    return Err("path: is empty".into());
                }
                Ok(PerceiveRequest::ImportPremiere { path, dry_run: optional(&m, "dryRun")?.unwrap_or(false) })
            }
            other => Err(format!("unknown endpoint {other}")),
        }
    }
}

#[derive(serde::Deserialize)]
struct ContactSheetWire {
    from: WireTime,
    to: WireTime,
    count: u32,
}

impl ContactSheetWire {
    fn checked(self) -> Result<ContactSheet, String> {
        if self.count == 0 || self.count as usize > MAX_FRAMES {
            return Err(format!("contactSheet.count: 1 to {MAX_FRAMES}"));
        }
        if self.to.time < self.from.time {
            return Err("contactSheet: `to` is before `from`".into());
        }
        Ok(ContactSheet { from: self.from.time, to: self.to.time, count: self.count })
    }
}

/// `at` as one time or a list of times; absent = empty.
fn times(m: &Map<String, Value>, key: &str) -> Result<Vec<Time>, String> {
    match m.get(key) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(_)) => Ok(required::<Vec<WireTime>>(m, key)?.into_iter().map(|w| w.time).collect()),
        Some(_) => Ok(vec![required::<WireTime>(m, key)?.time]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_takes_one_time_a_list_or_a_contact_sheet() {
        let one = br#"{"at":{"value":1,"timescale":2}}"#;
        let many = br#"{"at":[{"value":1,"timescale":1},{"value":2,"timescale":1}],"width":640}"#;
        let sheet = br#"{"contactSheet":{"from":{"value":0,"timescale":1},"to":{"value":10,"timescale":1},"count":6}}"#;
        assert!(
            matches!(PerceiveRequest::parse("/v1/capture", one), Ok(PerceiveRequest::Capture { at, .. }) if at.len() == 1)
        );
        assert!(
            matches!(PerceiveRequest::parse("/v1/capture", many), Ok(PerceiveRequest::Capture { at, width: Some(640), .. }) if at.len() == 2)
        );
        assert!(
            matches!(PerceiveRequest::parse("/v1/capture", sheet), Ok(PerceiveRequest::Capture { contact_sheet: Some(s), .. }) if s.count == 6)
        );
    }

    #[test]
    fn unknown_keys_and_bad_targets_are_refused() {
        let at = r#""at":{"value":1,"timescale":1}"#;
        assert!(
            PerceiveRequest::parse("/v1/capture", format!("{{{at},\"wdith\":9}}").as_bytes())
                .unwrap_err()
                .contains("wdith")
        );
        assert!(PerceiveRequest::parse("/v1/capture", b"{}").is_err());
        assert!(PerceiveRequest::parse("/v1/capture", format!("{{{at},\"width\":0}}").as_bytes()).is_err());
        assert!(PerceiveRequest::parse("/v1/media/transcript", b"{}").is_err());
        let id = Id::from_u128(5);
        let both = format!(r#"{{"media":"{id}","clip":"{id}"}}"#);
        assert!(PerceiveRequest::parse("/v1/media/transcript", both.as_bytes()).is_err());
        assert!(PerceiveRequest::parse("/v1/media/levels", format!(r#"{{"sequence":"{id}"}}"#).as_bytes()).is_ok());
        assert!(PerceiveRequest::parse("/v1/media/frames", format!(r#"{{"media":"{id}"}}"#).as_bytes()).is_err());
        assert!(PerceiveRequest::parse("/v1/importPremiere", br#"{"path":" "}"#).is_err());
        let ok = format!(r#"{{"clip":"{id}","style":"pill","position":"center"}}"#);
        assert!(matches!(
            PerceiveRequest::parse("/v1/addCaptions", ok.as_bytes()),
            Ok(PerceiveRequest::AddCaptions { word_by_word: true, position: CaptionSpot::Center, .. })
        ));
        let paul = PerceiveRequest::parse(
            "/v1/addCaptions",
            format!(r#"{{"clip":"{id}","style":"paul","wordsPerCaption":3,"box":{{"radius":4}}}}"#).as_bytes(),
        );
        assert!(matches!(&paul, Ok(PerceiveRequest::AddCaptions { word_by_word: false, look, .. })
            if look.words_per_caption == Some(3) && look.position_y == Some(0.7068) && matches!(look.box_, Some(Part::On(b)) if b.radius == 4.0)));
        for bad in
            [r#""wordsPerCaption":4"#, r#""shadow":true"#, r#""positionY":1.5"#, r#""weight":"huge""#, r#""size":0"#]
        {
            assert!(
                PerceiveRequest::parse("/v1/addCaptions", format!(r#"{{"clip":"{id}",{bad}}}"#).as_bytes()).is_err(),
                "{bad}"
            );
        }
        assert!(
            PerceiveRequest::parse("/v1/addCaptions", format!(r#"{{"clip":"{id}","style":"nope"}}"#).as_bytes())
                .is_err()
        );
        assert!(
            PerceiveRequest::parse("/v1/addCaptions", format!(r#"{{"clip":"{id}","track":"{id}"}}"#).as_bytes())
                .is_err()
        );
        // Own words (bare seconds and rational) and a saved look by name; a look refuses the keys it carries itself.
        let own = format!(
            r#"{{"sequence":"{id}","look":"Caption Look 1","words":[{{"text":"b","from":1.5,"to":2}},{{"text":"a","from":0,"to":{{"value":1,"timescale":2}}}}]}}"#
        );
        assert!(matches!(PerceiveRequest::parse("/v1/addCaptions", own.as_bytes()),
            Ok(PerceiveRequest::AddCaptions { words: Some(w), saved_look: Some(l), .. }) if l == "Caption Look 1" && w[0].text == "a" && w[1].from == Time::new(3, 2)));
        for bad in [
            r#""look":"x","size":50"#,
            r#""look":"x","style":"pill""#,
            r#""words":[]"#,
            r#""words":[{"text":"a","from":2,"to":1}]"#,
            r#""words":[{"text":" ","from":0,"to":1}]"#,
            r#""words":[{"text":"a","from":0,"to":1,"x":1}]"#,
        ] {
            assert!(
                PerceiveRequest::parse("/v1/addCaptions", format!(r#"{{"sequence":"{id}",{bad}}}"#).as_bytes())
                    .is_err(),
                "{bad}"
            );
        }
    }
}
