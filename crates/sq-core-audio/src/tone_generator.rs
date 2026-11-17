// Swift: ToneGenerator.swift (`Project.addToneClip` waits for `Project::edit`, `Timeline.bleep` for the edit crate)
//! The Tone generator: a sine on an audio track (line-up tone, bleep). A generator clip like any other (`Clip::generator`,
//! kind `TONE_KIND`); its frequency and level live in the payload, so nothing in the saved format changes.
//!
//! The sound is identified by `media_id`, a UUID that carries the two values (see `ToneSpec::from_media_id`). The audio
//! mixer recognizes such an id and synthesizes the sine itself: no file, no lookup, and an edit of frequency or level
//! makes a new id, so no cached source can be stale. Playback, scrubbing and export share this one path.

use serde::{Deserialize, Serialize};
use sq_core_model::{Clip, EditError, GeneratorRef, Project, TrackKind};
use sq_core_time::{Id, Time, TimeRange};

/// `GeneratorRef.tone`: a sine tone on an audio track.
pub const TONE_KIND: &str = "tone";

const MAGIC: [u8; 4] = [0x53, 0x51, 0x54, 0x4E]; // "SQTN"
const FREQUENCY_RANGE: std::ops::RangeInclusive<i64> = 20_000..=20_000_000;
const LEVEL_RANGE: std::ops::RangeInclusive<i64> = -6_000..=0;

/// A tone's frequency and level. Values are clamped on construction and when decoded.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(from = "ToneSpecFields")]
pub struct ToneSpec {
    /// 20 Hz ... 20 kHz in millihertz (integers: no rounding drift between save and load).
    #[serde(rename = "frequencyMilliHz")]
    frequency_milli_hz: i64,
    /// -60 ... 0 dB (full scale) in hundredths of a dB.
    #[serde(rename = "levelCentiDB")]
    level_centi_db: i64,
}

#[derive(Deserialize)]
struct ToneSpecFields {
    #[serde(rename = "frequencyMilliHz")]
    frequency_milli_hz: i64,
    #[serde(rename = "levelCentiDB")]
    level_centi_db: i64,
}

impl From<ToneSpecFields> for ToneSpec {
    fn from(f: ToneSpecFields) -> Self {
        ToneSpec::new(f.frequency_milli_hz, f.level_centi_db)
    }
}

impl ToneSpec {
    /// 1 kHz at -12 dB: the line-up tone broadcasters expect.
    pub const DEFAULT: ToneSpec = ToneSpec { frequency_milli_hz: 1_000_000, level_centi_db: -1_200 };

    /// From millihertz and centi-dB, clamped to the ranges.
    pub fn new(frequency_milli_hz: i64, level_centi_db: i64) -> ToneSpec {
        ToneSpec {
            frequency_milli_hz: frequency_milli_hz.max(*FREQUENCY_RANGE.start()).min(*FREQUENCY_RANGE.end()),
            level_centi_db: level_centi_db.max(*LEVEL_RANGE.start()).min(*LEVEL_RANGE.end()),
        }
    }

    /// From hertz and dB (rounded to the stored units; NaN and infinity are a Swift trap, here they clamp).
    pub fn from_hz_db(frequency_hz: f64, level_db: f64) -> ToneSpec {
        let milli = (frequency_hz * 1000.0).round().clamp(i64::MIN as f64, i64::MAX as f64) as i64;
        let centi = (level_db * 100.0).round().clamp(i64::MIN as f64, i64::MAX as f64) as i64;
        ToneSpec::new(milli, centi)
    }

    /// Frequency in millihertz.
    pub fn frequency_milli_hz(&self) -> i64 {
        self.frequency_milli_hz
    }

    /// Level in hundredths of a dB.
    pub fn level_centi_db(&self) -> i64 {
        self.level_centi_db
    }

    /// Frequency in hertz.
    pub fn frequency_hz(&self) -> f64 {
        self.frequency_milli_hz as f64 / 1000.0
    }

    /// Level in dB.
    pub fn level_db(&self) -> f64 {
        self.level_centi_db as f64 / 100.0
    }

    /// Peak amplitude, 0...1.
    pub fn amplitude(&self) -> f64 {
        10.0_f64.powf(self.level_db() / 20.0)
    }

    /// bytes 0-3 magic, 4-7 millihertz, 8-11 centi-dB (offset by 6000, so unsigned), 12-15 zero.
    pub fn media_id(&self) -> Id {
        let mut b = MAGIC.to_vec();
        b.extend((self.frequency_milli_hz as u32).to_be_bytes());
        b.extend(((self.level_centi_db - *LEVEL_RANGE.start()) as u32).to_be_bytes());
        b.extend([0, 0, 0, 0]);
        let mut v = 0u128;
        for byte in b {
            v = v << 8 | u128::from(byte);
        }
        Id::from_u128(v)
    }

    /// `None` when `id` is not a tone id (an ordinary media UUID).
    pub fn from_media_id(id: Id) -> Option<ToneSpec> {
        let b = id.as_u128().to_be_bytes();
        if b[..4] != MAGIC || b[12..].iter().any(|x| *x != 0) {
            return None;
        }
        let word = |at: usize| i64::from(u32::from_be_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]]));
        let (f, l) = (word(4), word(8) + *LEVEL_RANGE.start());
        (FREQUENCY_RANGE.contains(&f) && LEVEL_RANGE.contains(&l)).then(|| ToneSpec::new(f, l))
    }

    /// The generator reference carrying this tone.
    pub fn generator(&self) -> GeneratorRef {
        // Plain integers: serialization cannot fail; the empty payload is Swift's `?? Data()`.
        let payload = serde_json::to_vec(self).unwrap_or_default();
        GeneratorRef { kind: TONE_KIND.to_string(), payload, payload_version: 1 }
    }

    /// The tone of a generator; `None` for any other generator or a damaged payload.
    pub fn from_generator(g: &GeneratorRef) -> Option<ToneSpec> {
        if g.kind != TONE_KIND {
            return None;
        }
        serde_json::from_slice(&g.payload).ok()
    }
}

/// `extension Clip` of ToneGenerator.swift.
pub trait ToneClipExt {
    /// The tone this clip plays; `None` for any other clip.
    fn tone(&self) -> Option<ToneSpec>;
    /// What the audio mixer opens for this clip: a tone's synthetic id, else `media`.
    fn audio_media_id(&self) -> Id;
    /// A tone clip.
    fn make_tone(id: Id, spec: &ToneSpec, start: Time, duration: Time, name: &str) -> Clip;
}

impl ToneClipExt for Clip {
    fn tone(&self) -> Option<ToneSpec> {
        self.generator.as_ref().and_then(ToneSpec::from_generator)
    }

    fn audio_media_id(&self) -> Id {
        self.tone().map_or(self.media, |t| t.media_id())
    }

    fn make_tone(id: Id, spec: &ToneSpec, start: Time, duration: Time, name: &str) -> Clip {
        let mut c = Clip::new(id, name, spec.media_id(), TrackKind::Audio, TimeRange::new(Time::ZERO, duration), start);
        c.generator = Some(spec.generator());
        c
    }
}

/// `Project.setTone`.
pub trait ProjectToneExt {
    /// Changes frequency and level of a tone clip. One mutation (one undo step). Fails with `ClipNotFound` for an unknown
    /// clip or one that is not a tone, `TrackLocked` on a locked track.
    fn set_tone(&mut self, clip_id: Id, spec: &ToneSpec) -> Result<(), EditError>;
}

impl ProjectToneExt for Project {
    fn set_tone(&mut self, clip_id: Id, spec: &ToneSpec) -> Result<(), EditError> {
        for tl in self.timelines.iter_mut() {
            for track in tl.tracks.iter_mut() {
                let Some(mut c) = track.clips().iter().find(|c| c.id == clip_id).cloned() else { continue };
                if c.tone().is_none() {
                    return Err(EditError::ClipNotFound);
                }
                if track.is_locked {
                    return Err(EditError::TrackLocked);
                }
                c.generator = Some(spec.generator());
                c.media = spec.media_id();
                track.replace(c);
                return Ok(());
            }
        }
        Err(EditError::ClipNotFound)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio_role::tests::{clip, fresh_id, timeline, track};

    #[test]
    fn default_is_one_kilohertz_minus_twelve() {
        let d = ToneSpec::DEFAULT;
        assert!(d.frequency_hz() == 1000.0 && d.level_db() == -12.0);
        assert!((d.amplitude() - 0.2512).abs() < 0.0001);
    }

    #[test]
    fn media_id_round_trips_and_ordinary_ids_are_no_tone() {
        let spec = ToneSpec::from_hz_db(440.5, -20.25);
        assert_eq!(ToneSpec::from_media_id(spec.media_id()), Some(spec));
        assert_eq!(ToneSpec::from_media_id(fresh_id()), None);
        assert_ne!(ToneSpec::DEFAULT.media_id(), ToneSpec::from_hz_db(1001.0, -12.0).media_id());
        // Layout of the id: "SQTN", millihertz, centi-dB offset by 6000, zeros.
        assert_eq!(ToneSpec::DEFAULT.media_id().to_string(), "5351544E-000F-4240-0000-12C000000000");
    }

    #[test]
    fn values_are_clamped() {
        let s = ToneSpec::new(5, 900);
        assert!(s.frequency_hz() == 20.0 && s.level_db() == 0.0);
    }

    #[test]
    fn payload_round_trips_and_other_generators_are_no_tone() {
        let spec = ToneSpec::from_hz_db(800.0, -6.0);
        let g = spec.generator();
        assert_eq!((g.kind.as_str(), g.payload_version), ("tone", 1));
        assert_eq!(ToneSpec::from_generator(&g), Some(spec));
        let solid = GeneratorRef { kind: "solid".to_string(), payload: g.payload.clone(), payload_version: 1 };
        assert_eq!(ToneSpec::from_generator(&solid), None);
        let damaged = GeneratorRef { kind: "tone".to_string(), payload: b"{".to_vec(), payload_version: 1 };
        assert_eq!(ToneSpec::from_generator(&damaged), None);
        // A payload outside the ranges decodes clamped.
        let wild = GeneratorRef {
            kind: "tone".to_string(),
            payload: br#"{"frequencyMilliHz":5,"levelCentiDB":900}"#.to_vec(),
            payload_version: 1,
        };
        assert_eq!(ToneSpec::from_generator(&wild), Some(ToneSpec::new(20_000, 0)));
    }

    #[test]
    fn tone_clip_carries_the_tone_and_its_media_id() {
        let c = Clip::make_tone(fresh_id(), &ToneSpec::DEFAULT, Time::new(2, 1), Time::new(3, 1), "Tone");
        assert!(c.kind == TrackKind::Audio && c.is_generator() && c.tone() == Some(ToneSpec::DEFAULT));
        assert_eq!(c.timeline(), TimeRange::new(Time::new(2, 1), Time::new(3, 1)));
        assert_eq!(c.audio_media_id(), ToneSpec::DEFAULT.media_id());
        // Conform/title-block copies set `media = id` on generators; the mixer still plays the tone.
        let mut copy = c.clone();
        copy.media = copy.id;
        assert_eq!(copy.audio_media_id(), ToneSpec::DEFAULT.media_id());
        let plain = clip(0, 1, None);
        assert_eq!(plain.audio_media_id(), plain.media);
    }

    #[test]
    fn set_tone_changes_payload_and_media() {
        let tone = Clip::make_tone(fresh_id(), &ToneSpec::DEFAULT, Time::ZERO, Time::new(4, 1), "Tone");
        let mut tr = track(1, None, vec![]);
        tr.set_clips(vec![tone.clone()]);
        let mut p = Project::new(Id::from_u128(1), "P", vec![], vec![timeline(vec![tr])]);
        let spec = ToneSpec::from_hz_db(800.0, -6.0);
        assert_eq!(p.set_tone(tone.id, &spec), Ok(()));
        let c = p.timelines[0].tracks[0].clips()[0].clone();
        assert!(c.tone() == Some(spec) && c.media == spec.media_id());
        // Not a tone, unknown clip, locked track.
        let plain = clip(10, 2, None);
        p.timelines[0].tracks[0].set_clips(vec![c.clone(), plain.clone()]);
        assert_eq!(p.set_tone(plain.id, &spec), Err(EditError::ClipNotFound));
        assert_eq!(p.set_tone(fresh_id(), &spec), Err(EditError::ClipNotFound));
        p.timelines[0].tracks[0].is_locked = true;
        assert_eq!(p.set_tone(c.id, &spec), Err(EditError::TrackLocked));
    }
}
