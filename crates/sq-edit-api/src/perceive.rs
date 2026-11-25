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
    AddCaptions { target: Target, style: Option<String>, word_by_word: bool, position: CaptionSpot },
    /// `GET /v1/captionStyles`.
    CaptionStyles,
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
pub const CAPTION_STYLES: [&str; 3] = ["default", "outline", "pill"];

/// Most frames one call renders (each is a full render).
pub const MAX_FRAMES: usize = 24;
/// Widest picture a call may ask for.
pub const MAX_WIDTH: u32 = 4096;

impl PerceiveRequest {
    /// The POST routes of this family.
    pub const POST_PATHS: [&'static str; 7] =
        ["/v1/addCaptions", "/v1/capture", "/v1/media/frames", "/v1/media/transcript", "/v1/media/levels", "/v1/media/scenes", "/v1/importPremiere"];

    /// Parses the body of `path`. Unknown keys are refused.
    pub fn parse(path: &str, body: &[u8]) -> Result<PerceiveRequest, String> {
        let value: Value = if body.is_empty() { Value::Object(Map::new()) } else { serde_json::from_slice(body).map_err(|e| format!("invalid request: {e}"))? };
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
                let sheet = optional::<ContactSheetWire>(&m, "contactSheet")?.map(ContactSheetWire::checked).transpose()?;
                let at = times(&m, "at")?;
                if at.is_empty() && sheet.is_none() {
                    return Err("give `at` or `contactSheet`".into());
                }
                if at.len() > MAX_FRAMES {
                    return Err(format!("at: at most {MAX_FRAMES} times"));
                }
                Ok(PerceiveRequest::Capture { sequence: optional(&m, "sequence")?, at, width: width(&m)?, contact_sheet: sheet })
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
                check_strict_keys(&m, &["clip", "sequence", "style", "wordByWord", "position"], "addCaptions request")?;
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
                Ok(PerceiveRequest::AddCaptions { target, style, word_by_word: optional(&m, "wordByWord")?.unwrap_or(true), position })
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
        assert!(matches!(PerceiveRequest::parse("/v1/capture", one), Ok(PerceiveRequest::Capture { at, .. }) if at.len() == 1));
        assert!(matches!(PerceiveRequest::parse("/v1/capture", many), Ok(PerceiveRequest::Capture { at, width: Some(640), .. }) if at.len() == 2));
        assert!(matches!(PerceiveRequest::parse("/v1/capture", sheet), Ok(PerceiveRequest::Capture { contact_sheet: Some(s), .. }) if s.count == 6));
    }

    #[test]
    fn unknown_keys_and_bad_targets_are_refused() {
        let at = r#""at":{"value":1,"timescale":1}"#;
        assert!(PerceiveRequest::parse("/v1/capture", format!("{{{at},\"wdith\":9}}").as_bytes()).unwrap_err().contains("wdith"));
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
        assert!(matches!(PerceiveRequest::parse("/v1/addCaptions", ok.as_bytes()), Ok(PerceiveRequest::AddCaptions { word_by_word: true, position: CaptionSpot::Center, .. })));
        assert!(PerceiveRequest::parse("/v1/addCaptions", format!(r#"{{"clip":"{id}","style":"nope"}}"#).as_bytes()).is_err());
        assert!(PerceiveRequest::parse("/v1/addCaptions", format!(r#"{{"clip":"{id}","track":"{id}"}}"#).as_bytes()).is_err());
    }
}
