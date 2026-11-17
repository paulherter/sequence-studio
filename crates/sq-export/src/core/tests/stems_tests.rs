// Swift: StemExporterTests.swift, AudioDeliveryExtrasTests.swift (stems per role), HDRDeliveryAndStemPresetTests.swift
// (stem presets), StemMetadataSpecTests.swift (stems, spec)

use super::queue_tests::TempDir;
use crate::core::*;
use sq_core_model::{AudioTag, Clip, Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange};
use std::path::Path;
use std::sync::Mutex;

fn audio_track(ids: &mut SequentialIds, role: Option<AudioTag>, with_clip: bool) -> Track {
    let c = Clip::new(
        ids.next_id(),
        "c",
        ids.next_id(),
        TrackKind::Audio,
        TimeRange::new(Time::ZERO, Time::new(1, 1)),
        Time::ZERO,
    );
    let mut t = Track::new(ids.next_id(), TrackKind::Audio);
    t.set_clips(if with_clip { vec![c] } else { Vec::new() });
    t.audio_role = role;
    t
}

fn timeline(tracks: Vec<Track>) -> Timeline {
    Timeline::new(Id::from_u128(77), "S", super::fmt(1920, 1080), tracks)
}

#[test]
fn stems_per_role() {
    let mut ids = SequentialIds::default();
    let tracks = vec![
        audio_track(&mut ids, Some(AudioTag::Dialogue), true),
        audio_track(&mut ids, Some(AudioTag::Music), true),
        audio_track(&mut ids, Some(AudioTag::Music), true),
        audio_track(&mut ids, None, true),
        audio_track(&mut ids, Some(AudioTag::Sfx), false),
    ];
    let stems = StemPlan::stems(&timeline(tracks));
    assert_eq!(stems.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), ["dialogue", "music", "other", "me"]);
    let muted = |s: &Stem| s.timeline.tracks.iter().map(|t| t.is_muted).collect::<Vec<_>>();
    assert_eq!(muted(&stems[1]), [true, false, false, true, true]);
    assert_eq!(muted(&stems[3]), [true, false, false, false, true]);
    assert_eq!(StemPlan::file_names("Show", &stems, "wav")[0], "Show_dialogue.wav");
    assert!(StemPlan::stems(&timeline(Vec::new())).is_empty());
}

fn plan() -> Vec<Stem> {
    let tl = timeline(Vec::new());
    ["dialogue", "music", "other", "me"]
        .iter()
        .map(|id| Stem {
            id: (*id).to_string(),
            title: format!("{}{}", id[..1].to_uppercase(), &id[1..]),
            file_suffix: (*id).to_string(),
            timeline: tl.clone(),
        })
        .collect()
}

#[test]
fn selects_in_plan_order_and_skips_missing() {
    let p = StemPreset::new(Id::from_u128(1), "x", &["me", "dialogue", "sfx"], AudioFileFormat::Wav);
    assert_eq!(p.select(&plan()).iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), ["dialogue", "me"]);
}

#[test]
fn built_in_choices() {
    let b = StemPreset::built_in(&plan());
    assert_eq!(
        b.iter().map(|p| p.name.as_str()).collect::<Vec<_>>(),
        ["All roles", "Roles only", "Music and Effects only"]
    );
    assert_eq!(b[1].stem_ids, ["dialogue", "music", "other"]);
    assert_eq!(StemPreset::built_in(&plan()[..2]).len(), 1);
    assert_eq!(b[0].id.to_string(), "00000000-0000-0000-0000-0000000000A1");
    assert_eq!(StemPreset::auto_name(&["dialogue".into(), "music".into()], &plan()), "Dialogue + Music");
    assert_eq!(StemPreset::auto_name(&[], &plan()), "Stems");
}

#[test]
fn store_saves_replaces_deletes() {
    let dir = TempDir::new();
    let store = StemPresetStore::new(dir.0.join("sub/p.json"));
    assert!(store.load().is_empty());
    store.save(&StemPreset::new(Id::from_u128(1), "Dub", &["me"], AudioFileFormat::Wav)).unwrap();
    let after = store.save(&StemPreset::new(Id::from_u128(2), "dub", &["me", "music"], AudioFileFormat::M4a)).unwrap();
    assert!(after.len() == 1 && after[0].stem_ids == ["me", "music"] && after[0].format == AudioFileFormat::M4a);
    assert_eq!(after[0].id, Id::from_u128(1)); // the replaced preset keeps its id
    assert!(store.delete(after[0].id).unwrap().is_empty());
    std::fs::write(dir.0.join("bad.json"), "garbage").unwrap();
    assert!(StemPresetStore::new(dir.0.join("bad.json")).load().is_empty());
}

#[test]
fn size_estimate_scales_with_count() {
    let one = StemPreset::estimated_bytes(1, Time::new(60, 1), AudioFileFormat::Wav, &AudioSettings::default());
    assert_eq!(one, 48_000 * 2 * 24 * 60 / 8); // 48 kHz x 2 ch x 24 bit x 60 s / 8
    assert_eq!(
        StemPreset::estimated_bytes(3, Time::new(60, 1), AudioFileFormat::Wav, &AudioSettings::default()),
        one * 3
    );
}

struct Silence;

impl AudioSource for Silence {
    fn sample_rate(&self) -> i64 {
        48_000
    }
    fn channels(&self) -> usize {
        2
    }
    fn next_chunk(&mut self, _: usize) -> Result<Option<AudioChunk>, ExportError> {
        Ok(None)
    }
}

/// Records the audio files it is asked for (name, format, duration, no loudness) and writes a byte.
#[derive(Default)]
struct Recorder {
    files: Mutex<Vec<(String, AudioFileFormat, Time, bool)>>,
}

impl ExportEncoding for Recorder {
    fn export(
        &self,
        _: &mut dyn FrameSource,
        _: Option<&mut dyn AudioSource>,
        _: &ExportSettings,
        _: &Path,
        _: &CancelToken,
        _: &mut dyn FnMut(f64),
    ) -> Result<Option<LoudnessReport>, ExportError> {
        Ok(None)
    }

    fn export_audio_file(
        &self,
        _: &mut dyn AudioSource,
        format: AudioFileFormat,
        duration: Time,
        settings: &AudioSettings,
        url: &Path,
        _: &CancelToken,
        progress: &mut dyn FnMut(f64),
    ) -> Result<Option<LoudnessReport>, ExportError> {
        self.files.lock().unwrap().push((
            url.file_name().unwrap().to_string_lossy().into_owned(),
            format,
            duration,
            settings.loudness.is_none(),
        ));
        std::fs::write(url, [1u8]).unwrap();
        progress(1.0);
        Ok(None)
    }
}

#[test]
fn every_stem_goes_through_the_encoder() {
    let mut ids = SequentialIds::default();
    let tracks =
        vec![audio_track(&mut ids, Some(AudioTag::Dialogue), true), audio_track(&mut ids, Some(AudioTag::Music), true)];
    let stems = StemPlan::stems(&timeline(tracks));
    assert_eq!(stems.len(), 3); // dialogue, music, M&E
    let dir = TempDir::new();
    std::fs::write(dir.0.join("Show_music.flac"), [0u8]).unwrap(); // an old file is replaced
    let rec = Recorder::default();
    let a = AudioSettings { codec: AudioCodec::Pcm, pcm_bit_depth: 24, ..Default::default() };
    let mut seen = Vec::new();
    let out = StemExporter::export(
        &stems,
        "Show",
        &dir.0,
        AudioFileFormat::Flac,
        Time::new(2, 1),
        &a,
        &rec,
        &mut |_| Ok(Box::new(Silence)),
        &CancelToken::new(),
        &mut |p| seen.push(p),
    )
    .unwrap();
    let names = ["Show_dialogue.flac", "Show_music.flac", "Show_me.flac"];
    assert_eq!(
        out.iter().map(|w| w.url.file_name().unwrap().to_string_lossy().into_owned()).collect::<Vec<_>>(),
        names
    );
    let files = rec.files.lock().unwrap();
    assert_eq!(files.iter().map(|f| f.0.as_str()).collect::<Vec<_>>(), names);
    assert!(files.iter().all(|f| f.1 == AudioFileFormat::Flac && f.2 == Time::new(2, 1) && f.3));
    assert_eq!(seen.last(), Some(&1.0));
    assert!(seen.windows(2).all(|w| w[0] <= w[1]));
    assert_eq!(std::fs::read(dir.0.join("Show_music.flac")).unwrap(), vec![1u8]);
}

#[test]
fn a_cancelled_stem_export_stops_before_the_next_file() {
    let mut ids = SequentialIds::default();
    let stems = StemPlan::stems(&timeline(vec![audio_track(&mut ids, Some(AudioTag::Music), true)]));
    let dir = TempDir::new();
    let c = CancelToken::new();
    c.cancel();
    let r = StemExporter::export(
        &stems,
        "S",
        &dir.0,
        AudioFileFormat::Wav,
        Time::new(1, 1),
        &AudioSettings::default(),
        &Recorder::default(),
        &mut |_| Ok(Box::new(Silence)),
        &c,
        &mut |_| {},
    );
    assert_eq!(r, Err(ExportError::Cancelled));
}
