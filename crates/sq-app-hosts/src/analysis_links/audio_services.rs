//! What the shell's audio and import tools need from the app besides the analysis flows: the loudness of a one-track
//! sequence (Match Loudness, Voice Chain, Audio Gain readout) and Motion Graphics Template reading (Swift
//! `EditorSession.measureLoudness`, `MogrtImporter.read(url:)`).

use crate::export_audio::{FeederMix, channel_maps};
use crate::speech::RandomIds;
use sq_core_model::{MediaRef, Timeline};
use sq_core_time::TimeRange;
use sq_draw_shell::MogrtRead;
use sq_export::core::error::CancelToken;
use sq_export::core::loudness::LoudnessNormalizer;
use sq_export::core::timeline_audio::TimelineAudioSource;
use sq_library::title_template_preset::TitleTemplatePreset;
use sq_premiere_import::mogrt::{MogrtImportResult, MogrtImporter};
use sq_premiere_import::primport_report::Status;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Integrated LUFS of `timeline` over `range`, mixed offline the way an export mixes it (sequences nested in the clips
/// come from `sequences`); `None` for silence, when the mix cannot be read or `cancel` fired.
pub fn measure_lufs(
    media: &[MediaRef],
    sequences: &[Timeline],
    timeline: &Timeline,
    range: TimeRange,
    cancel: &CancelToken,
) -> Option<f64> {
    let paths: HashMap<_, _> = media.iter().map(|m| (m.id, PathBuf::from(&m.path))).collect();
    let nested: HashMap<_, _> = sequences.iter().map(|t| (t.id, t.clone())).collect();
    let feed = FeederMix::new(timeline, nested, paths, channel_maps(media));
    let mut source = TimelineAudioSource::new(feed, 2, range);
    let m = LoudnessNormalizer::measure(&mut source, cancel).ok()?;
    m.integrated_lufs.is_finite().then_some(m.integrated_lufs)
}

/// Reads one `.mogrt` file into a title template for the Library.
pub fn read_mogrt(url: &Path) -> Result<MogrtRead, String> {
    let data = std::fs::read(url).map_err(|e| e.to_string())?;
    let file_name = url.file_stem().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let result = MogrtImporter::read(&data, &file_name, &mut RandomIds).map_err(|e| e.to_string())?;
    mogrt_read(result)
}

fn mogrt_read(result: MogrtImportResult) -> Result<MogrtRead, String> {
    let MogrtImportResult { template, thumbnail, report, .. } = result;
    let value = serde_json::to_value(&template).map_err(|e| e.to_string())?;
    let dropped_count = report.entries().iter().filter(|e| e.status == Status::Dropped).map(|e| e.count).sum();
    Ok(MogrtRead {
        name: template.name.clone(),
        preset: TitleTemplatePreset { template: value, thumbnail },
        slot_count: template.slots.len(),
        dropped_count,
        report,
    })
}

#[cfg(test)]
mod tests;
