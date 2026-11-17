// Swift: StemPlan.swift, StemPreset.swift, StemExporter.swift

use super::error::{CancelToken, ExportError};
use super::settings::{AudioFileFormat, AudioSettings, ExportSettings};
use super::traits::{AudioSource, ExportEncoding};
use serde::{Deserialize, Serialize};
use sq_core_model::{AudioTag, Timeline, TrackKind};
use sq_core_time::{Id, Time};
use std::path::{Path, PathBuf};

/// Builds the mix source of a stem's timeline.
pub type AudioForStem<'a> = &'a mut dyn FnMut(&Stem) -> Result<Box<dyn AudioSource>, ExportError>;

/// One stem of the plan.
#[derive(Clone, Debug, PartialEq)]
pub struct Stem {
    /// `dialogue`, `music`, `sfx`, `other` or `me`.
    pub id: String,
    /// Shown name.
    pub title: String,
    /// Appended to the output name: `Interview_dialogue.wav`.
    pub file_suffix: String,
    /// The sequence with the other audio tracks muted.
    pub timeline: Timeline,
}

/// Stem export: the mix split by audio role, one audio file per stem, plus the music-and-effects mix (M&E: everything
/// except dialogue, for dubbing). Every stem is the sequence itself with the other audio tracks muted, so clip and
/// track volume, FX presets and ducking behave exactly as in the full mix.
pub struct StemPlan;

fn role_id(r: AudioTag) -> &'static str {
    match r {
        AudioTag::Dialogue => "dialogue",
        AudioTag::Music => "music",
        AudioTag::Sfx => "sfx",
    }
}

impl StemPlan {
    /// One stem per role that has audio tracks with clips (tracks without a role form "other"), then M&E when the
    /// sequence has dialogue and something else. Empty when no audio track carries a clip.
    pub fn stems(timeline: &Timeline) -> Vec<Stem> {
        let audio_idx: Vec<usize> = (0..timeline.tracks.len())
            .filter(|&i| timeline.tracks[i].kind == TrackKind::Audio && !timeline.tracks[i].clips().is_empty())
            .collect();
        if audio_idx.is_empty() {
            return Vec::new();
        }
        let make = |id: &str, title: &str, keep: &dyn Fn(Option<AudioTag>) -> bool| -> Option<Stem> {
            let members: Vec<usize> =
                audio_idx.iter().copied().filter(|&i| keep(timeline.tracks[i].audio_role)).collect();
            if members.is_empty() {
                return None;
            }
            let mut tl = timeline.clone();
            for i in 0..tl.tracks.len() {
                if tl.tracks[i].kind == TrackKind::Audio {
                    tl.tracks[i].is_solo = false;
                    if !members.contains(&i) {
                        tl.tracks[i].is_muted = true;
                    }
                }
            }
            Some(Stem { id: id.to_string(), title: title.to_string(), file_suffix: id.to_string(), timeline: tl })
        };
        let mut out = Vec::new();
        for role in [AudioTag::Dialogue, AudioTag::Music, AudioTag::Sfx] {
            if let Some(s) = make(role_id(role), role.title(), &|r| r == Some(role)) {
                out.push(s);
            }
        }
        if let Some(s) = make("other", "Other", &|r| r.is_none()) {
            out.push(s);
        }
        let has_dialogue = audio_idx.iter().any(|&i| timeline.tracks[i].audio_role == Some(AudioTag::Dialogue));
        let has_rest = audio_idx.iter().any(|&i| timeline.tracks[i].audio_role != Some(AudioTag::Dialogue));
        if let (true, Some(me)) =
            (has_dialogue && has_rest, make("me", "Music and Effects", &|r| r != Some(AudioTag::Dialogue)))
        {
            out.push(me);
        }
        out
    }

    /// `<base>_<suffix>.<ext>` for every stem, in plan order.
    pub fn file_names(base: &str, stems: &[Stem], ext: &str) -> Vec<String> {
        stems.iter().map(|s| format!("{base}_{}.{ext}", s.file_suffix)).collect()
    }
}

/// A saved choice of stems to export (which audio roles, M&E mix included), by `Stem::id`. Stored by the host in a
/// JSON file in the app data folder (`StemPresetStore`); not part of a project.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StemPreset {
    /// Identity.
    pub id: Id,
    /// Shown name.
    pub name: String,
    /// Stem ids (`dialogue`, `music`, `sfx`, `other`, `me`).
    pub stem_ids: Vec<String>,
    /// File format.
    pub format: AudioFileFormat,
}

impl StemPreset {
    /// "All roles".
    pub const ALL_ID: Id = Id::from_u128(0xA1);
    /// "Roles only".
    pub const ROLES_ID: Id = Id::from_u128(0xA2);
    /// "Music and Effects only".
    pub const ME_ID: Id = Id::from_u128(0xA3);

    /// A preset; Swift's default format is WAV.
    pub fn new(id: Id, name: &str, stem_ids: &[&str], format: AudioFileFormat) -> StemPreset {
        StemPreset { id, name: name.to_string(), stem_ids: stem_ids.iter().map(|s| (*s).to_string()).collect(), format }
    }

    /// The stems of `plan` this preset names, in plan order; ids the sequence lacks are skipped.
    pub fn select(&self, plan: &[Stem]) -> Vec<Stem> {
        plan.iter().filter(|s| self.stem_ids.contains(&s.id)).cloned().collect()
    }

    /// Built-in choices, never stored: every stem, the role stems without the M&E mix, and the M&E mix alone.
    pub fn built_in(plan: &[Stem]) -> Vec<StemPreset> {
        let all: Vec<String> = plan.iter().map(|s| s.id.clone()).collect();
        let roles: Vec<String> = all.iter().filter(|i| *i != "me").cloned().collect();
        let mk = |id, name: &str, ids: Vec<String>| StemPreset {
            id,
            name: name.to_string(),
            stem_ids: ids,
            format: AudioFileFormat::Wav,
        };
        let mut out = vec![mk(Self::ALL_ID, "All roles", all)];
        if plan.iter().any(|s| s.id == "me") {
            out.push(mk(Self::ROLES_ID, "Roles only", roles));
            out.push(mk(Self::ME_ID, "Music and Effects only", vec!["me".to_string()]));
        }
        out
    }

    /// A name for a selection: the stem titles joined, e.g. "Dialogue + Music".
    pub fn auto_name(ids: &[String], plan: &[Stem]) -> String {
        let titles: Vec<&str> = plan.iter().filter(|s| ids.contains(&s.id)).map(|s| s.title.as_str()).collect();
        if titles.is_empty() { "Stems".to_string() } else { titles.join(" + ") }
    }

    /// Estimated total bytes of `count` stem files of `duration` in `format` with `audio` settings.
    pub fn estimated_bytes(count: i64, duration: Time, format: AudioFileFormat, audio: &AudioSettings) -> i64 {
        let mut s = ExportSettings::default();
        s.audio = audio.clone();
        s.audio.enabled = true;
        s.audio.codec = format.codec();
        s.audio.loudness = None;
        s.audio_only = Some(format);
        s.estimated_file_size(duration) * count.max(0)
    }
}

/// The user's saved stem presets as a JSON file. A missing or damaged file reads as empty.
#[derive(Clone, Debug)]
pub struct StemPresetStore {
    /// The file.
    pub path: PathBuf,
}

impl StemPresetStore {
    /// A store at `path`.
    pub fn new(path: PathBuf) -> StemPresetStore {
        StemPresetStore { path }
    }

    /// All saved presets.
    pub fn load(&self) -> Vec<StemPreset> {
        std::fs::read(&self.path).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default()
    }

    /// Adds the preset, or replaces the one with the same name (case-insensitive), then writes the file.
    pub fn save(&self, preset: &StemPreset) -> Result<Vec<StemPreset>, ExportError> {
        let mut all = self.load();
        match all.iter().position(|p| p.name.to_lowercase() == preset.name.to_lowercase()) {
            Some(i) => {
                let mut p = preset.clone();
                p.id = all[i].id;
                all[i] = p;
            }
            None => all.push(preset.clone()),
        }
        self.write(&all)?;
        Ok(all)
    }

    /// Removes the preset with this id.
    pub fn delete(&self, id: Id) -> Result<Vec<StemPreset>, ExportError> {
        let all: Vec<StemPreset> = self.load().into_iter().filter(|p| p.id != id).collect();
        self.write(&all)?;
        Ok(all)
    }

    fn write(&self, all: &[StemPreset]) -> Result<(), ExportError> {
        let io = |e: std::io::Error| ExportError::from_io(&e);
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir).map_err(io)?;
        }
        let data = serde_json::to_vec(all).map_err(|e| ExportError::Other(e.to_string()))?;
        // Atomic like Swift's `.atomic`: write a sibling, then rename over the file.
        let tmp = self.path.with_extension("tmp");
        std::fs::write(&tmp, data).map_err(io)?;
        std::fs::rename(&tmp, &self.path).map_err(io)
    }
}

/// A stem file that was written.
#[derive(Clone, Debug, PartialEq)]
pub struct StemWritten {
    /// The stem.
    pub stem: Stem,
    /// The file.
    pub url: PathBuf,
}

/// Writes the stems of `StemPlan` as audio files next to each other: one file per role plus the M&E mix.
pub struct StemExporter;

impl StemExporter {
    /// `audio_for` builds the mix source of a stem's timeline (muted tracks stay silent, so each file is the mix by
    /// role). Files are `<base>_<suffix>.<ext>` in `directory`, written by `encoder`; `progress` is 0...1 over all stems.
    #[allow(clippy::too_many_arguments)]
    pub fn export(
        stems: &[Stem],
        base: &str,
        directory: &Path,
        format: AudioFileFormat,
        duration: Time,
        settings: &AudioSettings,
        encoder: &dyn ExportEncoding,
        audio_for: AudioForStem<'_>,
        cancel: &CancelToken,
        progress: &mut dyn FnMut(f64),
    ) -> Result<Vec<StemWritten>, ExportError> {
        let names = StemPlan::file_names(base, stems, format.file_extension());
        let mut out = Vec::new();
        let n = stems.len() as f64;
        for (i, stem) in stems.iter().enumerate() {
            cancel.check()?;
            let url = directory.join(&names[i]);
            let done = i as f64;
            if url.exists() {
                std::fs::remove_file(&url).map_err(|e| ExportError::from_io(&e))?;
            }
            let mut src = audio_for(stem)?;
            encoder.export_audio_file(src.as_mut(), format, duration, settings, &url, cancel, &mut |p| {
                progress((done + p) / n)
            })?;
            out.push(StemWritten { stem: stem.clone(), url });
        }
        progress(1.0);
        Ok(out)
    }
}
