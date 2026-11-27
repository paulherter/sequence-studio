// Swift: SharedUIController+ShellHooks.swift (`onConformToConstantFrameRate`) with `ConformRunner`
//! "Conform to Constant Frame Rate" jobs of the app: one background job per eligible media item writes the conformed file
//! (`sq_media_ffmpeg::conform`), probes it, and the next frame hands the result back here, where the item takes the new
//! file over (`replace_footage`, one undo step). The original file is never touched.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use sq_core_model::{MediaRef, MediaStatus};
use sq_core_time::Id;
use sq_editor_session::{
    ConformError, ConformFailure, ConformProbe, ConformRun, ConstantFrameRateConform, EditorSession,
};
use sq_media_ffmpeg::conform::conform_to_constant_frame_rate;
use sq_runtime::{Inbox, WorkerPool};

type Done = (Id, String, PathBuf, Result<MediaRef, ConformError>);

struct Job {
    title: String,
    name: String,
    progress: Arc<AtomicU32>,
    canceled: Arc<AtomicBool>,
}

/// Runs the conform jobs and lists them for the Jobs popover (`runs`).
pub struct ConformJobs {
    probe: ConformProbe,
    pool: Arc<WorkerPool>,
    done: Inbox<Done>,
    running: BTreeMap<Id, Job>,
}

impl ConformJobs {
    /// Jobs whose result files are probed with `probe` (the app's import probe).
    pub fn new(probe: ConformProbe) -> ConformJobs {
        ConformJobs { probe, pool: Arc::new(WorkerPool::threads(1)), done: Inbox::new(|| {}), running: BTreeMap::new() }
    }

    /// Runs `wake` on a worker thread when a job has finished.
    pub fn set_wake(&mut self, wake: Arc<dyn Fn() + Send + Sync>) {
        self.done = Inbox::new(move || wake());
    }

    /// The running conforms with their progress.
    pub fn runs(&self) -> Vec<ConformRun> {
        self.running
            .iter()
            .map(|(id, j)| ConformRun {
                id: *id,
                title: j.title.clone(),
                progress: f64::from(f32::from_bits(j.progress.load(Ordering::SeqCst))).clamp(0.0, 1.0),
            })
            .collect()
    }

    /// Stops the conform of `id`; its partial file is removed.
    pub fn cancel(&self, id: Id) {
        if let Some(j) = self.running.get(&id) {
            j.canceled.store(true, Ordering::SeqCst);
        }
    }

    /// Starts the conform of item `id` into `folder`; the status line when it is refused.
    pub fn start(&mut self, session: &EditorSession, id: Id, folder: Option<PathBuf>) -> Result<String, ConformError> {
        if self.running.contains_key(&id) {
            return Err(ConformError::Refused(ConformFailure::AlreadyRunning));
        }
        let item = session.project().media(id).ok_or(ConformError::Refused(ConformFailure::ItemGone))?;
        let fd = match (&item.info, ConstantFrameRateConform::is_eligible(item)) {
            (Some(i), true) => i.video.as_ref().map(|v| v.nominal_frame_duration),
            _ => None,
        };
        let fd = fd.ok_or(ConformError::Refused(ConformFailure::NotVariable))?;
        if item.status() == MediaStatus::Missing {
            return Err(ConformError::Refused(ConformFailure::Offline));
        }
        let source = PathBuf::from(&item.path);
        let folder = folder.or_else(|| source.parent().map(PathBuf::from)).unwrap_or_default();
        let destination = ConstantFrameRateConform::destination(item, &folder);
        let (progress, canceled) = (Arc::new(AtomicU32::new(0f32.to_bits())), Arc::new(AtomicBool::new(false)));
        let name = item.name.clone();
        self.running.insert(
            id,
            Job {
                title: format!("Conform: {name}"),
                name: name.clone(),
                progress: Arc::clone(&progress),
                canceled: Arc::clone(&canceled),
            },
        );
        let (tx, probe, dest) = (self.done.sender(), Arc::clone(&self.probe), destination);
        self.pool.execute(move || {
            let report = |p: f64| progress.store((p.clamp(0.0, 1.0) as f32).to_bits(), Ordering::SeqCst);
            let stopped = || canceled.load(Ordering::SeqCst);
            let result = match conform_to_constant_frame_rate(&source, &dest, fd, &report, &stopped) {
                Err(m) if m == "Canceled." => Err(ConformError::Canceled),
                Err(m) => Err(ConformError::Failed(m)),
                Ok(()) if stopped() => Err(ConformError::Canceled),
                Ok(()) => probe(&dest).map_err(ConformError::Failed),
            };
            if result.is_err() {
                let _ = std::fs::remove_file(&dest);
            }
            tx.send((id, name, dest, result));
        });
        Ok(format!("Conforming {} to a constant frame rate…", self.running[&id].name))
    }

    /// Takes in finished jobs: the item takes over the new file. Returns the status lines.
    pub fn poll(&mut self, session: &mut EditorSession) -> Vec<String> {
        let mut lines = Vec::new();
        for (id, name, dest, result) in self.done.drain() {
            self.running.remove(&id);
            match result {
                Ok(probed) if session.project().media(id).is_some() => {
                    session.replace_footage(id, &probed);
                    lines.push(format!("Conformed {name} to a constant frame rate."));
                }
                Ok(_) => {
                    let _ = std::fs::remove_file(&dest);
                    lines.push(ConformError::Refused(ConformFailure::ItemGone).to_string());
                }
                Err(ConformError::Canceled) => lines.push(format!("Conform of {name} canceled.")),
                Err(e) => lines.push(format!("Conform failed: {e}")),
            }
        }
        lines
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{MediaFingerprint, MediaInfo, Project};
    use sq_editor_session::SessionDeps;
    use sq_media_ffmpeg::decode::FFmpegDemuxer;
    use std::process::Command;
    use std::time::{Duration, Instant};

    fn probe_like_import(path: &std::path::Path) -> Result<MediaRef, String> {
        let demuxer = FFmpegDemuxer::open(path).map_err(|e| e.to_string())?;
        let duration = demuxer.table().index.duration();
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let mut m = MediaRef::new(Id::from_u128(900), &name, &path.to_string_lossy(), MediaFingerprint::new(2));
        m.duration = Some(duration);
        m.info = Some(MediaInfo {
            duration,
            video: Some(demuxer.track_info()),
            audio: None,
            detected_color_space: None,
            embedded_lut_name: None,
            is_still: false,
            sound_probed: None,
            created: None,
            camera_model: None,
            shoot_probed: None,
        });
        Ok(m)
    }

    #[test]
    fn a_variable_frame_rate_item_takes_over_its_conformed_file() {
        let dir = crate::test_rig::unique_dir("sq-conform-host");
        let _ = std::fs::create_dir_all(&dir);
        let src = dir.join("vfr.mp4");
        let made = Command::new("ffmpeg")
            .args(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=25:duration=1"])
            .args(["-vf", "select='lt(mod(n,5),3)'", "-fps_mode", "vfr", "-c:v", "mpeg4"])
            .arg(&src)
            .output();
        if !sq_media_ffmpeg::shim::AVAILABLE || !made.is_ok_and(|o| o.status.success()) {
            sq_os::errln!("skipped: no ffmpeg shim or command");
            return;
        }
        let mut item = probe_like_import(&src).unwrap();
        let id = Id::from_u128(77);
        item.id = id;
        let project = Project::new(Id::from_u128(2), "p", vec![item], Vec::new());
        let mut session = EditorSession::new(project, SessionDeps::headless(dir.join("support")));
        let mut jobs = ConformJobs::new(Arc::new(probe_like_import));
        assert!(jobs.start(&session, id, Some(dir.clone())).is_ok());
        assert_eq!(jobs.start(&session, id, None), Err(ConformError::Refused(ConformFailure::AlreadyRunning)));
        let started = Instant::now();
        let mut lines = Vec::new();
        while lines.is_empty() && started.elapsed() < Duration::from_secs(30) {
            std::thread::sleep(Duration::from_millis(50));
            lines = jobs.poll(&mut session);
        }
        assert_eq!(lines, vec!["Conformed vfr.mp4 to a constant frame rate.".to_string()], "{lines:?}");
        let now = session.project().media(id).unwrap();
        assert!(now.path.ends_with("vfr (CFR).mov"), "{}", now.path);
        assert!(jobs.runs().is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
