// Swift: ProjectMediaResolver.swift, ProjectThumbnails.swift, AutoProxy.swift, MediaDiskTracker.swift,
// MediaDiskWatcher.swift, EditorSession+MediaDisk.swift, EditorSession+GrowingFiles.swift, EditorSession+RelinkOffer.swift,
// EditorSession+Reconnect.swift, RenderCacheController.swift, PlaybackEngine+ProgramEngine.swift (see TASKS.md).
//! ES8: media resolver over `sq_media::MediaOpener`, thumbnails, AutoProxy, disk tracking, relink, render cache, the
//! `ProgramEngine` adapter over `sq_playback`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::Arc;

pub use sq_core_model::MediaPolicyDefaults;
use sq_core_time::{Id, Timestamp};
use sq_runtime::WorkerPool;

mod auto_proxy;
mod disk;
mod engine;
mod growing;
mod relink;
mod render_cache;
mod resolver;
#[cfg(test)]
mod session_tests;
mod thumbnails;

pub use auto_proxy::*;
pub use disk::*;
pub use engine::*;
pub use growing::*;
pub use render_cache::*;
pub use resolver::*;
pub use thumbnails::*;

/// What the ES8 async flows need from the app root besides the session: the worker pool that runs the blocking file
/// system and probe work (Swift `Task.detached`), and the mounted volumes.
pub trait MediaWorkers {
    /// The shared worker pool.
    fn workers(&self) -> Arc<WorkerPool>;
    /// The mounted volumes (`/Volumes` entries on the Mac); empty where there is no such folder.
    fn volumes(&self) -> Vec<PathBuf> {
        default_volumes()
    }
}

/// The entries of `/Volumes` (Swift's default for the `volumes:` parameters); on Windows the drive roots that exist
/// (`D:\`, `E:\`, ...; the system drive too, like the Mac's boot volume link), on Linux the mounts under `/run/media/<user>`, `/media/<user>` and `/mnt`.
pub fn default_volumes() -> Vec<PathBuf> {
    if cfg!(windows) {
        return ('A'..='Z').map(|d| PathBuf::from(format!("{d}:\\"))).filter(|p| p.exists()).collect();
    }
    if cfg!(target_os = "linux") {
        return linux_volumes(&std::env::var("USER").unwrap_or_default());
    }
    std::fs::read_dir("/Volumes").map(|d| d.flatten().map(|e| e.path()).collect()).unwrap_or_default()
}

/// Linux mounts removable drives under `/media/<user>` and `/run/media/<user>`; every entry there is a volume.
fn linux_volumes(user: &str) -> Vec<PathBuf> {
    let roots = [format!("/run/media/{user}"), format!("/media/{user}"), "/mnt".to_string()];
    roots.iter().flat_map(|r| std::fs::read_dir(r).into_iter().flatten().flatten().map(|e| e.path())).collect()
}

/// What a media file looked like on disk at one check: present or not, and its size and modification date.
// Swift: MediaDiskTracker.swift:4
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MediaDiskState {
    // Swift: MediaDiskTracker.swift:5
    pub exists: bool,
    // Swift: MediaDiskTracker.swift:6
    pub size: Option<i64>,
    // Swift: MediaDiskTracker.swift:7
    pub modified: Option<Timestamp>,
}

impl MediaDiskState {
    /// A state with the given facts.
    // Swift: MediaDiskTracker.swift:8
    pub fn new(exists: bool, size: Option<i64>, modified: Option<Timestamp>) -> MediaDiskState {
        MediaDiskState { exists, size, modified }
    }

    /// Reads the file's state (one `stat`; a missing path is `exists == false`).
    // Swift: MediaDiskTracker.swift:14
    pub fn read(path: &str) -> MediaDiskState {
        let Ok(meta) = std::fs::symlink_metadata(path) else { return MediaDiskState::new(false, None, None) };
        let modified = meta
            .modified()
            .ok()
            .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| Timestamp::from_unix_seconds(d.as_secs_f64()));
        MediaDiskState::new(true, i64::try_from(meta.len()).ok(), modified)
    }
}

/// Media files that changed since the last look (Swift `MediaDiskTracker.Changes`).
// Swift: MediaDiskTracker.swift:23
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MediaDiskChanges {
    /// Still there, but another size or modification date than at the last look.
    // Swift: MediaDiskTracker.swift:25
    pub modified: BTreeSet<Id>,
    /// Was missing at the last look, present now.
    // Swift: MediaDiskTracker.swift:27
    pub appeared: BTreeSet<Id>,
    /// Was present at the last look, missing now.
    // Swift: MediaDiskTracker.swift:29
    pub vanished: BTreeSet<Id>,
}

impl MediaDiskChanges {
    // Swift: MediaDiskTracker.swift:30
    pub fn is_empty(&self) -> bool {
        self.modified.is_empty() && self.appeared.is_empty() && self.vanished.is_empty()
    }

    /// Items whose open decoders, thumbnails and waveforms must be dropped.
    // Swift: MediaDiskTracker.swift:32
    pub fn all(&self) -> BTreeSet<Id> {
        self.modified.union(&self.appeared).chain(&self.vanished).copied().collect()
    }
}

/// Notices project media files that changed behind the app's back. The first look at an item only records it.
// Swift: MediaDiskTracker.swift:22
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MediaDiskTracker {
    pub(crate) known: BTreeMap<Id, MediaDiskState>,
}

impl MediaDiskTracker {
    /// A tracker that has looked at nothing yet.
    // Swift: MediaDiskTracker.swift:36
    pub fn new() -> MediaDiskTracker {
        MediaDiskTracker::default()
    }

    /// Stats `paths` (call off the UI thread: a dead network volume can block a `stat`).
    // Swift: MediaDiskTracker.swift:40
    pub fn snapshot(paths: &BTreeMap<Id, String>) -> BTreeMap<Id, MediaDiskState> {
        paths.iter().map(|(id, p)| (*id, MediaDiskState::read(p))).collect()
    }

    /// Compares `snapshot` with the last one and remembers it. Items not in `snapshot` are forgotten.
    // Swift: MediaDiskTracker.swift:45
    pub fn update(&mut self, snapshot: BTreeMap<Id, MediaDiskState>) -> MediaDiskChanges {
        let mut out = MediaDiskChanges::default();
        for (id, now) in &snapshot {
            let Some(before) = self.known.get(id) else { continue };
            match (before.exists, now.exists) {
                (true, false) => {
                    out.vanished.insert(*id);
                }
                (false, true) => {
                    out.appeared.insert(*id);
                }
                (true, true) if before.size != now.size || before.modified != now.modified => {
                    out.modified.insert(*id);
                }
                _ => {}
            }
        }
        self.known = snapshot;
        out
    }

    /// Items looked at so far (0 until the first `update`).
    // Swift: MediaDiskTracker.swift:59
    pub fn known_count(&self) -> usize {
        self.known.len()
    }

    /// Present at the last look; false for an item never looked at.
    // Swift: MediaDiskTracker.swift:62
    pub fn is_online(&self, id: Id) -> bool {
        self.known.get(&id).is_some_and(|s| s.exists)
    }

    /// Records one item's state without reporting (a relink or replace the app did itself).
    // Swift: MediaDiskTracker.swift:65
    pub fn accept(&mut self, id: Id, state: MediaDiskState) {
        self.known.insert(id, state);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn changes_union_all_three_sets() {
        let mut ids = sq_core_time::SequentialIds::default();
        let (a, b) = (sq_core_time::IdSource::next_id(&mut ids), sq_core_time::IdSource::next_id(&mut ids));
        let mut c = MediaDiskChanges::default();
        assert!(c.is_empty());
        c.modified.insert(a);
        c.vanished.insert(b);
        c.appeared.insert(a);
        assert_eq!(c.all(), BTreeSet::from([a, b]));
    }
}

/// Builders for the probe types in tests (they have no constructors).
#[cfg(test)]
pub(crate) mod testing {
    use sq_core_model::{MediaInfo, PixelAspect, VideoTrackInfo};
    use sq_core_time::Time;

    /// A 30 fps progressive 8-bit video stream of the given size.
    pub(crate) fn video(width: i64, height: i64) -> VideoTrackInfo {
        VideoTrackInfo {
            width,
            height,
            codec: "avc1".to_string(),
            bit_depth: 8,
            chroma: "4:2:0".to_string(),
            nominal_frame_duration: Time::new(1, 30),
            is_variable_frame_rate: false,
            color_primaries: None,
            transfer: None,
            matrix: None,
            rotation: 0,
            pixel_aspect: PixelAspect::square(),
            pixel_aspect_override: None,
            field_order: None,
            deinterlace_off: false,
        }
    }

    /// Probe info of a file of the given length.
    pub(crate) fn info(duration: Time, video: Option<VideoTrackInfo>) -> MediaInfo {
        MediaInfo {
            duration,
            video,
            audio: None,
            detected_color_space: None,
            embedded_lut_name: None,
            is_still: false,
            sound_probed: None,
            created: None,
            camera_model: None,
            shoot_probed: None,
        }
    }
}

#[cfg(test)]
mod linux_volume_tests {
    #[test]
    fn linux_volumes_of_a_user_without_mounts_is_empty_or_mnt_only() {
        let v = super::linux_volumes("no-such-user-xyz");
        assert!(v.iter().all(|p| p.starts_with("/mnt")));
    }
}
