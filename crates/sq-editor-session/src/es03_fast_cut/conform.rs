//! "Conform to Constant Frame Rate" for variable-frame-rate media: the file is re-encoded to a constant rate in the
//! background, probed, and the library item takes it over (`replace_footage`, one undo step), so clips, marks and labels
//! stay and cuts and audio stay in sync. The original file is never touched.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use sq_core_model::{MediaRef, MediaStatus};
use sq_core_time::{Id, Time};
use sq_runtime::{UiRef, WorkerPool};

use crate::SessionRoot;

/// Why a conform was refused.
// Swift: ConstantFrameRateConform.swift:11
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConformFailure {
    NotVariable,
    Offline,
    AlreadyRunning,
    ItemGone,
}

impl fmt::Display for ConformFailure {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            ConformFailure::NotVariable => "The clip does not have a variable frame rate.",
            ConformFailure::Offline => "The media is offline.",
            ConformFailure::AlreadyRunning => "A conform of this media is already running.",
            ConformFailure::ItemGone => "The media item is gone.",
        })
    }
}

/// How a conform ended without a new file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ConformError {
    Refused(ConformFailure),
    Canceled,
    /// The converter or the probe failed (message for the status line).
    Failed(String),
}

impl fmt::Display for ConformError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ConformError::Refused(r) => r.fmt(f),
            ConformError::Canceled => f.write_str("Canceled."),
            ConformError::Failed(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for ConformError {}

/// Rules of the conform command (a caseless namespace in Swift).
pub enum ConstantFrameRateConform {}

impl ConstantFrameRateConform {
    /// Variable-frame-rate video that is not a still.
    // Swift: ConstantFrameRateConform.swift:13
    pub fn is_eligible(r: &MediaRef) -> bool {
        match &r.info {
            Some(i) if !i.is_still => i.video.as_ref().is_some_and(|v| v.is_variable_frame_rate),
            _ => false,
        }
    }

    /// "Name (CFR).mov" in `folder`; "Name (CFR 2).mov"... when taken.
    // Swift: ConstantFrameRateConform.swift:19
    pub fn destination(r: &MediaRef, folder: &Path) -> PathBuf {
        // `NSString.deletingPathExtension`: only the last path component loses its extension.
        let component_start = r.name.rfind('/').map_or(0, |i| i + 1);
        let mut stem = match r.name.rfind('.') {
            Some(dot) if dot > component_start => r.name[..dot].to_string(),
            _ => r.name.clone(),
        };
        if stem.is_empty() {
            stem = "Media".to_string();
        }
        stem = stem.replace('/', "-");
        let mut n = 1;
        loop {
            let name = if n == 1 { format!("{stem} (CFR).mov") } else { format!("{stem} (CFR {n}).mov") };
            let url = folder.join(name);
            if !url.exists() {
                return url;
            }
            n += 1;
        }
    }
}

/// One running conform, as the Jobs popover lists it.
// Swift: ConstantFrameRateConform.swift:36
#[derive(Clone, Debug, PartialEq)]
pub struct ConformRun {
    // Swift: ConstantFrameRateConform.swift:37
    pub id: Id,
    // Swift: ConstantFrameRateConform.swift:38
    pub title: String,
    /// 0...1.
    // Swift: ConstantFrameRateConform.swift:40
    pub progress: f64,
}

/// Re-encodes `source` to `destination` at a constant `frame_duration`, reporting 0...1 progress.
// Swift: ConstantFrameRateConform.swift:42
pub type ConformConvert = Arc<dyn Fn(&Path, &Path, Time, &dyn Fn(f64)) -> Result<(), String> + Send + Sync>;
/// Probes the new file.
// Swift: ConstantFrameRateConform.swift:44
pub type ConformProbe = Arc<dyn Fn(&Path) -> Result<MediaRef, String> + Send + Sync>;

struct Work {
    title: String,
    progress: Arc<AtomicU32>,
    canceled: Arc<AtomicBool>,
}

/// Runs and tracks conform jobs (the Jobs popover lists `runs`). Held by the app next to the session.
pub struct ConformRunner {
    work: BTreeMap<Id, Work>,
    convert: ConformConvert,
    probe: ConformProbe,
}

impl ConformRunner {
    /// A runner with the given converter and probe.
    // Swift: ConstantFrameRateConform.swift:52
    pub fn new(convert: ConformConvert, probe: ConformProbe) -> ConformRunner {
        ConformRunner { work: BTreeMap::new(), convert, probe }
    }

    /// The portable default: no conform or probe yet.
    // The Swift non-Mac default also throws `unsupportedCodec`; the app injects the FFmpeg transcoder and probe.
    // Swift: ConstantFrameRateConform.swift:61
    pub fn unsupported() -> ConformRunner {
        ConformRunner::new(
            Arc::new(|_, _, _, _| Err("Unsupported codec: conform".to_string())),
            Arc::new(|_| Err("Unsupported codec: probe".to_string())),
        )
    }

    /// The running conforms with their progress.
    pub fn runs(&self) -> Vec<ConformRun> {
        self.work
            .iter()
            .map(|(id, w)| ConformRun {
                id: *id,
                title: w.title.clone(),
                progress: f64::from(f32::from_bits(w.progress.load(Ordering::SeqCst))).clamp(0.0, 1.0),
            })
            .collect()
    }

    // Swift: ConstantFrameRateConform.swift:66
    pub fn is_running(&self, id: Id) -> bool {
        self.work.contains_key(&id)
    }

    // Swift: ConstantFrameRateConform.swift:68
    pub fn cancel(&self, id: Id) {
        if let Some(w) = self.work.get(&id) {
            w.canceled.store(true, Ordering::SeqCst);
        }
    }

    /// Conforms item `id` into `folder` and, when done, lets the item take over the new file. Returns the new file.
    /// `Canceled` when canceled (the partial file is removed).
    // Swift: ConstantFrameRateConform.swift:73
    pub async fn conform<R: SessionRoot + ?Sized>(
        runner: Rc<RefCell<ConformRunner>>,
        h: UiRef<R>,
        pool: Arc<WorkerPool>,
        id: Id,
        folder: PathBuf,
    ) -> Result<PathBuf, ConformError> {
        if runner.borrow().is_running(id) {
            return Err(ConformError::Refused(ConformFailure::AlreadyRunning));
        }
        let checked = h.with(|r| {
            let r = r.session().project().media(id).cloned().ok_or(ConformFailure::ItemGone)?;
            let fd = match (&r.info, ConstantFrameRateConform::is_eligible(&r)) {
                (Some(i), true) => i.video.as_ref().map(|v| v.nominal_frame_duration),
                _ => None,
            };
            let fd = fd.ok_or(ConformFailure::NotVariable)?;
            if r.status() == MediaStatus::Missing {
                return Err(ConformFailure::Offline);
            }
            Ok((r, fd))
        });
        let Some(checked) = checked else { return Err(ConformError::Refused(ConformFailure::ItemGone)) };
        let (item, fd) = checked.map_err(ConformError::Refused)?;
        let source = PathBuf::from(&item.path);
        let destination = ConstantFrameRateConform::destination(&item, &folder);
        let progress = Arc::new(AtomicU32::new(0f32.to_bits()));
        let canceled = Arc::new(AtomicBool::new(false));
        let (convert, probe) = {
            let mut me = runner.borrow_mut();
            me.work.insert(
                id,
                Work {
                    title: format!("Conform: {}", item.name),
                    progress: Arc::clone(&progress),
                    canceled: Arc::clone(&canceled),
                },
            );
            (Arc::clone(&me.convert), Arc::clone(&me.probe))
        };
        let (dest, flag, prog) = (destination.clone(), Arc::clone(&canceled), Arc::clone(&progress));
        let job = pool.run(move |ctl| -> Result<MediaRef, ConformError> {
            let stopped = || flag.load(Ordering::SeqCst) || ctl.is_cancelled();
            let report = |p: f64| prog.store((p.clamp(0.0, 1.0) as f32).to_bits(), Ordering::SeqCst);
            convert(&source, &dest, fd, &report).map_err(ConformError::Failed)?;
            if stopped() {
                return Err(ConformError::Canceled);
            }
            probe(&dest).map_err(ConformError::Failed)
        });
        let result = job.await;
        runner.borrow_mut().work.remove(&id);
        let probed = match result {
            Ok(Ok(p)) => p,
            Ok(Err(e)) => {
                let _ = std::fs::remove_file(&destination);
                return Err(e);
            }
            Err(_) => {
                let _ = std::fs::remove_file(&destination);
                return Err(ConformError::Failed("The conform job stopped unexpectedly.".to_string()));
            }
        };
        let alive = h.with(|r| r.session().project().media(id).is_some());
        if alive != Some(true) {
            let _ = std::fs::remove_file(&destination);
            return Err(ConformError::Refused(ConformFailure::ItemGone));
        }
        h.with(|r| r.session().replace_footage(id, &probed));
        Ok(destination)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{MediaFingerprint, MediaInfo, PixelAspect, VideoTrackInfo};

    /// A media item with picture info; `vfr` and `still` set the flags the rules read.
    fn item(name: &str, vfr: bool, still: bool) -> MediaRef {
        let video = VideoTrackInfo {
            width: 10,
            height: 10,
            codec: "avc1".to_string(),
            bit_depth: 8,
            chroma: "4:2:0".to_string(),
            nominal_frame_duration: Time::new(1, 30),
            is_variable_frame_rate: vfr,
            color_primaries: None,
            transfer: None,
            matrix: None,
            rotation: 0,
            pixel_aspect: PixelAspect::square(),
            pixel_aspect_override: None,
            field_order: None,
            deinterlace_off: false,
        };
        let info = MediaInfo {
            duration: Time::new(1, 1),
            video: Some(video),
            audio: None,
            detected_color_space: None,
            embedded_lut_name: None,
            is_still: still,
            sound_probed: None,
            created: None,
            camera_model: None,
            shoot_probed: None,
        };
        let mut r = MediaRef::new(Id::from_u128(1), name, "/x/a.mov", MediaFingerprint::new(1));
        r.info = Some(info);
        r
    }

    #[test]
    fn only_variable_frame_rate_video_is_eligible() {
        assert!(ConstantFrameRateConform::is_eligible(&item("a.mov", true, false)));
        assert!(!ConstantFrameRateConform::is_eligible(&item("a.mov", false, false)));
        assert!(!ConstantFrameRateConform::is_eligible(&item("a.png", true, true)));
        let mut audio = item("a.wav", true, false);
        audio.info = None;
        assert!(!ConstantFrameRateConform::is_eligible(&audio));
    }

    #[test]
    fn destination_numbers_taken_names() {
        let dir = std::env::temp_dir().join(format!("sq-cfr-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap_or_else(|e| panic!("{e}"));
        let r = item("Clip 1/2.mp4", true, false);
        let first = ConstantFrameRateConform::destination(&r, &dir);
        assert_eq!(first, dir.join("Clip 1-2 (CFR).mov"));
        std::fs::write(&first, b"x").unwrap_or_else(|e| panic!("{e}"));
        assert_eq!(ConstantFrameRateConform::destination(&r, &dir), dir.join("Clip 1-2 (CFR 2).mov"));
        let empty = item("", true, false);
        assert_eq!(ConstantFrameRateConform::destination(&empty, &dir), dir.join("Media (CFR).mov"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn runner_lists_runs_and_cancel_sets_the_flag() {
        let mut runner = ConformRunner::unsupported();
        assert!(!runner.is_running(Id::from_u128(1)) && runner.runs().is_empty());
        let w = Work {
            title: "Conform: a".to_string(),
            progress: Arc::new(AtomicU32::new(0.5f32.to_bits())),
            canceled: Arc::new(AtomicBool::new(false)),
        };
        let flag = Arc::clone(&w.canceled);
        runner.work.insert(Id::from_u128(1), w);
        assert_eq!(
            runner.runs(),
            vec![ConformRun { id: Id::from_u128(1), title: "Conform: a".to_string(), progress: 0.5 }]
        );
        runner.cancel(Id::from_u128(1));
        assert!(flag.load(Ordering::SeqCst));
    }
}
