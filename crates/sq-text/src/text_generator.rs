// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: TextGenerator.swift
//! Bridge between a generator clip (`GeneratorRef` kind "text") and the text renderer.
//!
//! shortcut: the encode memo and the scoped payload table of the Swift version are not ported (`TextTemplate` has no `Hash`
//! and encoding is a pure function, so the bytes are the same); add them when encoding shows in a playback profile.

use crate::text_template::TextTemplate;
use serde::{Deserialize, Serialize};
use sq_core_model::GeneratorRef;
use sq_core_model::anchored_animation::AnimationSet;
use std::collections::HashMap;
use std::fmt;
use std::sync::{LazyLock, Mutex, PoisonError};

/// Why a text payload could not be made or read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TextGeneratorError {
    /// The ref is not a text generator.
    WrongKind(String),
    /// Payload written by a newer app version.
    UnsupportedPayloadVersion {
        /// Version in the ref.
        found: i64,
        /// Newest version this build reads.
        supported: i64,
    },
    /// The payload does not decode.
    InvalidPayload(String),
}

impl fmt::Display for TextGeneratorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TextGeneratorError::WrongKind(k) => write!(f, "Not a text generator: {k}"),
            TextGeneratorError::UnsupportedPayloadVersion { found, supported } => {
                write!(f, "Text payload version {found} is newer than the supported version {supported}.")
            }
            TextGeneratorError::InvalidPayload(why) => write!(f, "Invalid text payload: {why}"),
        }
    }
}

impl std::error::Error for TextGeneratorError {}

/// The coded payload of a text generator.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Payload {
    /// The text and its look.
    pub template: TextTemplate,
    /// The animations.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub animations: Option<AnimationSet>,
}

#[derive(Default)]
struct DecodeMemo {
    map: HashMap<GeneratorRef, Payload>,
    hits: u64,
}

static DECODE_MEMO: LazyLock<Mutex<DecodeMemo>> = LazyLock::new(|| Mutex::new(DecodeMemo::default()));

/// Namespace of the text generator functions.
pub enum TextGenerator {}

impl TextGenerator {
    /// The generator kind of a text layer (`GeneratorRef.text`).
    pub const KIND: &'static str = "text";
    /// Version of the payload format.
    pub const PAYLOAD_VERSION: i64 = 1;
    /// Most decoded payloads kept.
    const DECODE_MEMO_LIMIT: usize = 1024;

    /// The generator ref of a text layer: sorted-key JSON of the payload.
    pub fn make_ref(
        template: &TextTemplate,
        animations: Option<&AnimationSet>,
    ) -> Result<GeneratorRef, serde_json::Error> {
        let payload = Payload { template: template.clone(), animations: animations.cloned() };
        // `Value` objects keep their keys sorted.
        let data = serde_json::to_vec(&sq_core_time::json_sorted::to_value(payload)?)?;
        Ok(GeneratorRef { kind: Self::KIND.to_string(), payload: data, payload_version: Self::PAYLOAD_VERSION })
    }

    /// The template and animations of a text ref.
    pub fn decode(r: &GeneratorRef) -> Result<(TextTemplate, Option<AnimationSet>), TextGeneratorError> {
        if r.kind != Self::KIND {
            return Err(TextGeneratorError::WrongKind(r.kind.clone()));
        }
        if r.payload_version > Self::PAYLOAD_VERSION {
            return Err(TextGeneratorError::UnsupportedPayloadVersion {
                found: r.payload_version,
                supported: Self::PAYLOAD_VERSION,
            });
        }
        if r.payload_version < 1 {
            return Err(TextGeneratorError::InvalidPayload(format!("version {}", r.payload_version)));
        }
        {
            // Decoded payloads by ref: playback decoded every text layer twice per frame. Decoding is a pure function
            // of the ref, so the value is the same; failures are not kept.
            let mut m = DECODE_MEMO.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(p) = m.map.get(r).cloned() {
                m.hits = m.hits.wrapping_add(1);
                return Ok((p.template, p.animations));
            }
        }
        let p: Payload =
            serde_json::from_slice(&r.payload).map_err(|e| TextGeneratorError::InvalidPayload(e.to_string()))?;
        let mut m = DECODE_MEMO.lock().unwrap_or_else(PoisonError::into_inner);
        if m.map.len() >= Self::DECODE_MEMO_LIMIT {
            m.map.clear();
        }
        m.map.insert(r.clone(), p.clone());
        Ok((p.template, p.animations))
    }

    /// Memo hits since launch (tests).
    pub fn decode_memo_hits() -> u64 {
        DECODE_MEMO.lock().unwrap_or_else(PoisonError::into_inner).hits
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text_style::{FontWeight, RGBAColor, TextStyle};
    use sq_core_model::anchored_animation::{AnimationTrack, KeyframeTemplate, SegmentShape};
    use sq_core_time::Time;

    fn template() -> TextTemplate {
        TextTemplate::new("t", "Hello", TextStyle::new("Helvetica-Bold", 100.0, FontWeight::Regular, RGBAColor::WHITE))
    }

    fn fade_in() -> KeyframeTemplate {
        KeyframeTemplate {
            tracks: vec![AnimationTrack::from_shapes(
                "opacity",
                &[(Time::ZERO, 0.0, SegmentShape::Linear), (Time::new(1, 2), 1.0, SegmentShape::Linear)],
            )],
            duration: Time::new(1, 2),
            ..KeyframeTemplate::none()
        }
    }

    #[test]
    fn codec_round_trip() {
        let set = AnimationSet::new(Some(fade_in()), None);
        let r = TextGenerator::make_ref(&template(), Some(&set)).unwrap();
        assert_eq!(r.kind, "text");
        assert_eq!(r.payload_version, TextGenerator::PAYLOAD_VERSION);
        let (t, a) = TextGenerator::decode(&r).unwrap();
        assert_eq!(t, template());
        assert_eq!(a, Some(set.clone()));
        // Stable bytes.
        assert_eq!(TextGenerator::make_ref(&template(), Some(&set)).unwrap().payload, r.payload);
        let (_, none) = TextGenerator::decode(&TextGenerator::make_ref(&template(), None).unwrap()).unwrap();
        assert_eq!(none, None);
    }

    #[test]
    fn newer_version_and_wrong_kind_fail() {
        let mut r = TextGenerator::make_ref(&template(), None).unwrap();
        r.payload_version = TextGenerator::PAYLOAD_VERSION + 1;
        assert_eq!(
            TextGenerator::decode(&r).err(),
            Some(TextGeneratorError::UnsupportedPayloadVersion {
                found: TextGenerator::PAYLOAD_VERSION + 1,
                supported: TextGenerator::PAYLOAD_VERSION
            })
        );
        let other = GeneratorRef { kind: "solid".into(), payload: Vec::new(), payload_version: 1 };
        assert_eq!(TextGenerator::decode(&other).err(), Some(TextGeneratorError::WrongKind("solid".into())));
        let bad = GeneratorRef { kind: "text".into(), payload: b"nope".to_vec(), payload_version: 1 };
        assert!(matches!(TextGenerator::decode(&bad), Err(TextGeneratorError::InvalidPayload(_))));
    }

    #[test]
    fn decoded_payloads_are_remembered() {
        let r = TextGenerator::make_ref(&template(), None).unwrap();
        TextGenerator::decode(&r).unwrap();
        let before = TextGenerator::decode_memo_hits();
        TextGenerator::decode(&r).unwrap();
        assert!(TextGenerator::decode_memo_hits() > before);
    }
}
