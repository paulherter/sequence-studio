// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: LottieGenerator.swift
//
// Lottie generator clips: a user-supplied Lottie JSON (bodymovin) drawn as a picture layer next to text and shapes. The file
// is embedded in the clip's payload (project stays portable, nothing is bundled from third parties); the rasterizer is the
// app's. This file holds only the pure logic: header parsing, limits, timing (frame at a clip time), raster size. The kind
// string is stored: never rename.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sq_core_model::project_media_ops::GeneratorPlacement;
use sq_core_model::{EditError, GeneratorRef, Project};
use sq_core_time::{Id, IdSource, Time};

/// The Lottie generator's kind.
pub const LOTTIE_KIND: &str = "lottie";

/// Limits of an accepted file.
pub struct LottieLimits;

impl LottieLimits {
    /// Largest Lottie file accepted (it is stored inside the project).
    pub const MAX_BYTES: usize = 8 << 20;
    /// Longest side in px, for the animation's own size and for the raster.
    pub const MAX_SIDE: i64 = 4096;
}

/// What a Lottie clip holds: the file's bytes and the play settings. Fields are in the key order Swift writes the payload in
/// (sorted).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LottieSpec {
    /// The file.
    #[serde(with = "sq_core_time::base64")]
    pub json: Vec<u8>,
    /// Repeat from the start when the clip is longer than the animation; false holds the last frame.
    pub loops: bool,
    /// File name the user picked (shown, never read back from disk).
    pub source_name: String,
    /// Playback speed factor.
    pub speed: f64,
}

impl LottieSpec {
    /// A spec with the Swift defaults (looping, speed 1).
    pub fn new(json: Vec<u8>, source_name: &str) -> LottieSpec {
        LottieSpec { json, loops: true, source_name: source_name.to_string(), speed: 1.0 }
    }

    /// A Lottie clip: payload is the JSON spec.
    pub fn generator(&self) -> GeneratorRef {
        GeneratorRef {
            kind: LOTTIE_KIND.to_string(),
            payload: serde_json::to_vec(self).unwrap_or_default(),
            payload_version: 1,
        }
    }
}

/// The decoded spec of a generator; `None` for another kind or an undecodable payload.
pub trait GeneratorRefLottieExt {
    /// The decoded spec; `None` for another kind or an undecodable payload.
    fn lottie_spec(&self) -> Option<LottieSpec>;
}

impl GeneratorRefLottieExt for GeneratorRef {
    fn lottie_spec(&self) -> Option<LottieSpec> {
        if self.kind == LOTTIE_KIND { serde_json::from_slice(&self.payload).ok() } else { None }
    }
}

/// The header of a Lottie document.
#[derive(Clone, Debug, PartialEq)]
pub struct LottieInfo {
    /// Width in px.
    pub width: i64,
    /// Height in px.
    pub height: i64,
    /// Frames per second.
    pub frame_rate: f64,
    /// First frame.
    pub in_point: f64,
    /// End frame.
    pub out_point: f64,
    /// The animation's name.
    pub name: Option<String>,
}

/// A JSON number as Foundation's `NSNumber` reads it (a Bool counts as 0 / 1).
fn ns_number(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::Number(n) => n.as_f64(),
        Value::Bool(b) => Some(f64::from(u8::from(*b))),
        _ => None,
    }
}

impl LottieInfo {
    /// Frames of one play.
    pub fn frame_count(&self) -> f64 {
        self.out_point - self.in_point
    }

    /// One play of the animation, exact (frames / rate in thousandths).
    pub fn duration(&self) -> Time {
        Time::new((self.frame_count() * 1000.0).round() as i64, (self.frame_rate * 1000.0).round() as i64)
    }

    /// Reads the header; `None` when `json` is not a usable Lottie document (not JSON, no layers, bad size, rate or range, or
    /// over the size limits).
    pub fn parse(json: &[u8]) -> Option<LottieInfo> {
        if json.len() > LottieLimits::MAX_BYTES || json.is_empty() {
            return None;
        }
        let root: Value = serde_json::from_slice(json).ok()?;
        let obj = root.as_object()?;
        if !obj.get("layers")?.is_array() {
            return None;
        }
        // `NSNumber.intValue` truncates toward zero.
        let w = ns_number(obj.get("w"))?.trunc() as i64;
        let h = ns_number(obj.get("h"))?.trunc() as i64;
        let fr = ns_number(obj.get("fr"))?;
        let ip = ns_number(obj.get("ip"))?;
        let op = ns_number(obj.get("op"))?;
        let ok = w > 0
            && h > 0
            && w <= LottieLimits::MAX_SIDE
            && h <= LottieLimits::MAX_SIDE
            && fr.is_finite()
            && fr > 0.0
            && fr <= 1000.0
            && ip.is_finite()
            && op.is_finite()
            && op > ip
            && op - ip <= 1_000_000.0;
        if !ok {
            return None;
        }
        Some(LottieInfo {
            width: w,
            height: h,
            frame_rate: fr,
            in_point: ip,
            out_point: op,
            name: obj.get("nm").and_then(Value::as_str).map(str::to_string),
        })
    }
}

/// Timing and raster size of a Lottie clip.
pub struct LottieTiming;

impl LottieTiming {
    /// The animation frame shown at `local_time` (seconds from the clip start): `in_point` + time x rate x speed, wrapped when
    /// looping, else held on the last frame (`out_point - 1`).
    pub fn frame(local_time: Time, info: &LottieInfo, spec: &LottieSpec) -> f64 {
        let t = (local_time.value() as f64 / local_time.timescale() as f64).max(0.0);
        let advanced = t * info.frame_rate * if spec.speed.is_finite() { spec.speed.max(0.0) } else { 1.0 };
        let span = info.frame_count();
        let local = if spec.loops { advanced % span } else { advanced.min((span - 1.0).max(0.0)) };
        info.in_point + local
    }

    /// Raster size in px (width, height): the animation scaled to fit the canvas (aspect kept, up or down), at most
    /// `MAX_SIDE` per side, so a small sticker stays sharp at full size. Both sides are at least 1.
    pub fn raster_size(info: &LottieInfo, canvas_width: i64, canvas_height: i64) -> (i64, i64) {
        let cw = canvas_width.max(1) as f64;
        let ch = canvas_height.max(1) as f64;
        let mut k = (cw / info.width as f64).min(ch / info.height as f64);
        k = k.min(LottieLimits::MAX_SIDE as f64 / info.width.max(info.height) as f64);
        let side = |v: i64| ((v as f64 * k).round() as i64).clamp(1, LottieLimits::MAX_SIDE);
        (side(info.width), side(info.height))
    }
}

/// Why a Lottie clip could not be added. Swift throws `LottieImportError` or `EditError`; both are cases here.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LottieImportError {
    /// Not a Lottie document, or over the size limits.
    Invalid,
    /// The clip could not be placed.
    Edit(EditError),
}

impl std::fmt::Display for LottieImportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LottieImportError::Invalid => f.write_str(
                "This is not a Lottie animation Sequence Studio can use. It needs to be a Lottie .json file of at most 8 MB and 4096 px.",
            ),
            LottieImportError::Edit(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for LottieImportError {}

/// `NSString.deletingPathExtension` for a plain file name: drops the text after the last dot when something stands before it.
fn deleting_path_extension(name: &str) -> &str {
    match name.rfind('.') {
        Some(i) if i > 0 && i + 1 < name.len() => &name[..i],
        _ => name,
    }
}

/// The Lottie clip command.
pub trait ProjectLottieExt {
    /// Places a Lottie clip of the animation's own length (rounded up to whole frames) on a video track. Fails with
    /// `Invalid` for unusable JSON, else with what `add_generator_clip` fails with.
    fn add_lottie_clip(
        &mut self,
        json: Vec<u8>,
        name: &str,
        at: GeneratorPlacement,
        loops: bool,
        ids: &mut dyn IdSource,
    ) -> Result<Id, LottieImportError>;
}

impl ProjectLottieExt for Project {
    /// `at.duration` is ignored: the clip takes the animation's length.
    fn add_lottie_clip(
        &mut self,
        json: Vec<u8>,
        name: &str,
        at: GeneratorPlacement,
        loops: bool,
        ids: &mut dyn IdSource,
    ) -> Result<Id, LottieImportError> {
        let info = LottieInfo::parse(&json).ok_or(LottieImportError::Invalid)?;
        let frame_duration = self
            .timelines
            .iter()
            .find(|t| t.id == at.timeline)
            .map(|t| t.format.frame_duration)
            .ok_or(LottieImportError::Edit(EditError::TimelineNotFound))?;
        let mut spec = LottieSpec::new(json, name);
        spec.loops = loops;
        let base = deleting_path_extension(name);
        let placement = GeneratorPlacement { duration: info.duration().ceiled(frame_duration), ..at };
        self.add_generator_clip(spec.generator(), Some(if base.is_empty() { "Lottie" } else { base }), placement, ids)
            .map_err(LottieImportError::Edit)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::graphics_create::test_support::{project, s};
    use sq_core_model::TrackKind;
    use sq_core_time::{SequentialIds, TimeRange};

    /// A minimal valid Lottie document: 100 x 50, 30 fps, frames 0...60 (2 s).
    fn lottie_json(w: i64, h: i64, fr: f64, ip: f64, op: f64) -> Vec<u8> {
        format!(r#"{{"v":"5.7.0","fr":{fr},"ip":{ip},"op":{op},"w":{w},"h":{h},"nm":"Demo","layers":[]}}"#).into_bytes()
    }

    fn demo() -> Vec<u8> {
        lottie_json(100, 50, 30.0, 0.0, 60.0)
    }

    fn spec(loops: bool, speed: f64) -> LottieSpec {
        LottieSpec { json: Vec::new(), loops, source_name: String::new(), speed }
    }

    #[test]
    fn parse_reads_size_and_timing() {
        let info = LottieInfo::parse(&demo()).unwrap();
        assert_eq!((info.width, info.height), (100, 50));
        assert_eq!((info.frame_rate, info.in_point, info.out_point), (30.0, 0.0, 60.0));
        assert_eq!(info.frame_count(), 60.0);
        assert_eq!(info.name.as_deref(), Some("Demo"));
        assert_eq!(info.duration(), Time::new(2, 1));
    }

    #[test]
    fn duration_is_rational_for_ntsc_rates() {
        let info = LottieInfo::parse(&lottie_json(100, 50, 29.97, 0.0, 30.0)).unwrap();
        // 30 frames at 29.97 fps = 30 * 1000/29970 s, kept exact.
        assert_eq!(info.duration(), Time::new(30 * 1000, 29970));
    }

    #[test]
    fn parse_rejects_non_lottie() {
        assert!(LottieInfo::parse(b"nope").is_none());
        assert!(LottieInfo::parse(b"{}").is_none());
        assert!(LottieInfo::parse(br#"{"fr":30,"ip":0,"op":10,"w":10,"h":10}"#).is_none()); // no layers
        assert!(LottieInfo::parse(&lottie_json(0, 50, 30.0, 0.0, 60.0)).is_none());
        assert!(LottieInfo::parse(&lottie_json(100, 50, 0.0, 0.0, 60.0)).is_none());
        assert!(LottieInfo::parse(&lottie_json(100, 50, 30.0, 10.0, 10.0)).is_none()); // empty range
        assert!(LottieInfo::parse(&lottie_json(LottieLimits::MAX_SIDE + 1, 50, 30.0, 0.0, 60.0)).is_none());
        assert!(LottieInfo::parse(&vec![0u8; LottieLimits::MAX_BYTES + 1]).is_none());
    }

    #[test]
    fn spec_round_trips_through_the_generator_ref() {
        let sp = LottieSpec { json: demo(), loops: false, source_name: "demo.json".to_string(), speed: 2.0 };
        let r = sp.generator();
        assert_eq!(r.kind, LOTTIE_KIND);
        assert_eq!(r.lottie_spec(), Some(sp));
        let other = GeneratorRef { kind: "text".to_string(), ..r };
        assert_eq!(other.lottie_spec(), None);
    }

    #[test]
    fn timing_loops_and_holds() {
        let info = LottieInfo::parse(&demo()).unwrap();
        let frame = |t: Time, sp: &LottieSpec| LottieTiming::frame(t, &info, sp);
        let lp = spec(true, 1.0);
        assert_eq!(frame(Time::ZERO, &lp), 0.0);
        assert_eq!(frame(Time::new(1, 1), &lp), 30.0);
        assert_eq!(frame(Time::new(3, 1), &lp), 30.0); // 90 frames wraps to 30
        assert_eq!(frame(Time::new(5, 1), &spec(false, 1.0)), 59.0); // last frame (op - 1)
        assert_eq!(frame(Time::new(1, 2), &spec(false, 2.0)), 30.0);
    }

    #[test]
    fn timing_honours_in_point() {
        let info = LottieInfo::parse(&lottie_json(100, 50, 30.0, 10.0, 40.0)).unwrap();
        let lp = spec(true, 1.0);
        assert_eq!(LottieTiming::frame(Time::ZERO, &info, &lp), 10.0);
        assert_eq!(LottieTiming::frame(Time::new(1, 1), &info, &lp), 10.0); // 30 frames wraps to start
    }

    #[test]
    fn raster_size_fits_canvas_within_cap() {
        let info = LottieInfo::parse(&lottie_json(512, 256, 30.0, 0.0, 60.0)).unwrap();
        assert_eq!(LottieTiming::raster_size(&info, 1920, 1080), (1920, 960)); // contain, aspect kept
        let big = LottieTiming::raster_size(&info, 20000, 20000);
        assert!(big.0.max(big.1) <= LottieLimits::MAX_SIDE);
    }

    #[test]
    fn add_lottie_clip_uses_animation_length() {
        let mut ids = SequentialIds::default();
        let (mut p, tl, tr) = project(&[TrackKind::Video, TrackKind::Audio], &mut ids);
        let at = GeneratorPlacement { timeline: tl, track: tr[0], start: s(1), duration: s(1) };
        let id = p.add_lottie_clip(demo(), "Stamp.json", at, true, &mut ids).unwrap();
        let c = p.timelines[0].tracks[0].clip(id).unwrap();
        assert_eq!(c.timeline(), TimeRange::new(s(1), s(2)));
        assert_eq!(c.name, "Stamp");
        assert_eq!(
            c.generator.as_ref().and_then(|g| g.lottie_spec()).map(|s| s.source_name),
            Some("Stamp.json".to_string())
        );
        let bad = p.add_lottie_clip(b"x".to_vec(), "x", GeneratorPlacement { start: Time::ZERO, ..at }, true, &mut ids);
        assert_eq!(bad, Err(LottieImportError::Invalid));
    }
}
