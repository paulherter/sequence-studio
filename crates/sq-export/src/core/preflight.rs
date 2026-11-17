// Swift: ExportPreflight.swift

use super::error::ExportError;
use super::queue::{ExportJob, sanitize};
use sq_core_model::{ColorSpaceID, MediaRef, MediaStatus, Project};
use sq_core_time::Id;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// What the platform layer answers for the portable crates.
struct HostProbes {
    free_bytes: fn(&Path) -> Option<i64>,
    physical_memory: fn() -> Option<u64>,
}

static HOST_PROBES: OnceLock<HostProbes> = OnceLock::new();

/// How the free space compares with the estimate.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpaceVerdict {
    /// Plenty.
    Ok,
    /// Less than 20 % of the estimate would be left over.
    Tight,
    /// Not enough.
    Insufficient,
}

/// Checks that run before an export starts (so the user decides first) and the friendly text for a failed one.
pub struct ExportPreflight;

impl ExportPreflight {
    /// A running export stops when the output volume has less than this left.
    pub const RUNNING_FLOOR_BYTES: i64 = 200_000_000;

    /// Below this the volume counts as full when a write failed.
    const LOW_SPACE_BYTES: i64 = 100_000_000;

    /// Files an export of `jobs` would overwrite: the exact `<name>.<ext>` (and sidecar) already in the folder.
    /// Without a choice the queue keeps both (`name 2.mp4`); with `replace_existing` the old file is replaced.
    pub fn existing_targets(jobs: &[ExportJob]) -> Vec<PathBuf> {
        let mut seen = BTreeSet::new();
        let mut out = Vec::new();
        for job in jobs {
            let stem = sanitize(&job.name);
            let mut exts = vec![job.settings.file_extension()];
            if let Some(e) = job.settings.captions.sidecar_extension() {
                exts.push(e);
            }
            for e in exts {
                let url = job.output_directory.join(format!("{stem}.{e}"));
                if url.exists() && seen.insert(url.to_string_lossy().to_lowercase()) {
                    out.push(url);
                }
            }
        }
        out
    }

    /// Media of the sequence (and every sequence nested in it) that its clips use.
    fn used_media(sequence: Id, project: &Project) -> Vec<&MediaRef> {
        let mut ids: BTreeSet<Id> = project.reachable_sequences(sequence);
        ids.insert(sequence);
        let mut used = BTreeSet::new();
        for t in project.timelines.iter().filter(|t| ids.contains(&t.id)) {
            for track in &t.tracks {
                for clip in track.clips().iter().filter(|c| c.sequence.is_none()) {
                    used.insert(clip.media);
                }
            }
        }
        project.media.iter().filter(|m| used.contains(&m.id)).collect()
    }

    /// Media files of the sequence (and every sequence nested in it) that are not at their path.
    pub fn offline_media(sequence: Id, project: &Project) -> Vec<&MediaRef> {
        Self::used_media(sequence, project).into_iter().filter(|m| m.status() == MediaStatus::Missing).collect()
    }

    /// Used media whose source is HDR (HLG / PQ). The export is Rec. 709 only, so these are tone-mapped down.
    pub fn hdr_media(sequence: Id, project: &Project) -> Vec<&MediaRef> {
        Self::used_media(sequence, project)
            .into_iter()
            .filter(|m| {
                m.info
                    .as_ref()
                    .is_some_and(|i| matches!(i.color_space(), ColorSpaceID::HlgBT2020 | ColorSpaceID::PqBT2020))
            })
            .collect()
    }

    /// Extensions the check opens itself (the Swift list): other containers are not second-guessed.
    const PROBE_EXTENSIONS: [&'static str; 9] = ["mov", "mp4", "m4v", "m4a", "wav", "aif", "aiff", "caf", "mp3"];

    /// Media the export would hit as damaged frames: files that are there but empty, or whose container FFmpeg cannot
    /// open or shows no track in. Offline (missing) files are `offline_media`, not listed here.
    // Swift: ExportPreflight.swift:54 (AVFoundation there, the FFmpeg shim here: the Rust app has no AVFoundation path)
    pub fn unreadable_media(sequence: Id, project: &Project) -> Vec<&MediaRef> {
        Self::unreadable_media_with(sequence, project, Self::container_has_a_track)
    }

    /// `unreadable_media` with the container check replaced (tests).
    pub fn unreadable_media_with(sequence: Id, project: &Project, has_track: fn(&Path) -> bool) -> Vec<&MediaRef> {
        Self::used_media(sequence, project)
            .into_iter()
            .filter(|m| {
                let Ok(attrs) = std::fs::metadata(&m.path) else { return false };
                if attrs.len() == 0 {
                    return true;
                }
                let ext = Path::new(&m.path).extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
                Self::PROBE_EXTENSIONS.contains(&ext.as_str()) && !has_track(Path::new(&m.path))
            })
            .collect()
    }

    /// True when FFmpeg opens the file and finds a picture or a sound track.
    fn container_has_a_track(path: &Path) -> bool {
        use sq_media_ffmpeg::shim;
        shim::Demux::open(path).is_ok() || shim::probe_audio(path).is_ok_and(|p| p.audio.is_some())
    }

    /// The estimate against the free bytes: `Tight` when less than 20 % of the estimate would be left over.
    pub fn space_verdict(free_bytes: Option<i64>, estimated_bytes: i64) -> SpaceVerdict {
        let Some(free) = free_bytes else { return SpaceVerdict::Ok };
        if free < estimated_bytes {
            return SpaceVerdict::Insufficient;
        }
        if ((free - estimated_bytes) as f64) < 0.2 * estimated_bytes as f64 {
            SpaceVerdict::Tight
        } else {
            SpaceVerdict::Ok
        }
    }

    /// Message of a job stopped because the output volume filled up.
    pub fn ran_out_of_space_message(free_bytes: Option<i64>) -> String {
        match free_bytes {
            None => "The output disk ran out of space. The export stopped and the partial file was removed. Free some space and export again.".to_string(),
            Some(free) => format!(
                "The output disk ran out of space ({:.0} MB left). The export stopped and the partial file was removed. Free some space and export again.",
                free.max(0) as f64 / 1_000_000.0
            ),
        }
    }

    /// Free bytes on the volume of `folder`; `None` when unknown (no probe installed).
    pub fn free_bytes(folder: &Path) -> Option<i64> {
        HOST_PROBES.get().and_then(|p| (p.free_bytes)(folder))
    }

    /// Physical memory of the machine in bytes; `None` when unknown (no probe installed).
    pub fn physical_memory() -> Option<u64> {
        HOST_PROBES.get().and_then(|p| (p.physical_memory)())
    }

    /// Installs the platform's probes once at start (the portable crates cannot call `statvfs` or Win32 themselves).
    /// Returns false when probes were installed before; the first ones stay.
    pub fn install_host_probes(free_bytes: fn(&Path) -> Option<i64>, physical_memory: fn() -> Option<u64>) -> bool {
        HOST_PROBES.set(HostProbes { free_bytes, physical_memory }).is_ok()
    }

    /// Text for a failed job. A disk-full error (or any write failure on a nearly full volume) says so in plain words.
    pub fn failure_message(error: &ExportError, free_bytes: Option<i64>) -> String {
        let low_and_write_failed =
            matches!(error, ExportError::WriterFailed(_)) && free_bytes.is_some_and(|f| f < Self::LOW_SPACE_BYTES);
        if matches!(error, ExportError::DiskFull) || low_and_write_failed {
            return "The disk is full. Free some space on the output volume and export again.".to_string();
        }
        error.to_string()
    }
}
