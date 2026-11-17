// Swift: ShellExportPreview.swift (the render runs on a worker thread here, not in a Swift Task)
//! The Export sheet's preview picture, rendered off the UI thread. A change of range, sequence or the playhead asks for a
//! new frame; one render runs at a time and only the newest request waits behind it, so dragging a field never queues
//! a stack of engines.

use crate::shell_export::FramePixels;
use sq_core_time::{Id, Time};
use sq_draw::RgbaImage;
use sq_editor_session::{ExportDialogModel, ExportPreviewMath, PreviewSourceProvider};
use sq_export::core::settings::ExportSettings;
use std::sync::{Arc, Mutex, PoisonError};

/// Longest side of the preview picture.
const PREVIEW_SIDE: i64 = 640;

/// Which frame of the preview source a job shows.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum At {
    /// A 0...1 position inside the range (where the playhead is), resolved to the frame on screen at that time.
    Fraction(f64),
    /// A frame index (clamped to the source).
    Index(usize),
}

/// A rendered preview frame and what the source says about itself (the scrub bar and the timecode need it).
pub(crate) struct PreviewShot {
    pub(crate) image: RgbaImage,
    /// The frame shown (the sheet follows its own wanted position; tests read this one).
    #[cfg_attr(not(test), allow(dead_code))]
    pub(crate) index: usize,
    pub(crate) count: usize,
    pub(crate) duration: Time,
}

type Source = Box<dyn sq_export::core::traits::FrameSource>;

/// Everything one preview render needs, taken from the model so a worker can run it.
pub(crate) struct PreviewJob {
    source: PreviewSourceProvider,
    sequence: Id,
    settings: ExportSettings,
    at: At,
    pixels: FramePixels,
}

impl PreviewJob {
    /// `None` without a preview source or for an audio-only format.
    pub(crate) fn new(model: &ExportDialogModel, at: At, pixels: &FramePixels) -> Option<PreviewJob> {
        let settings = ExportPreviewMath::preview_settings(model.settings(), PREVIEW_SIDE);
        if settings.audio_only.is_some() {
            return None;
        }
        Some(PreviewJob {
            source: Arc::clone(model.preview_source()?),
            sequence: model.selected_id(),
            settings,
            at,
            pixels: Arc::clone(pixels),
        })
    }

    /// The frame as the export would render it from `kept` (the source of the last job with the same inputs) or from a
    /// fresh one; hands the source back for the next frame. `None` when the frame fails.
    fn render(&self, kept: Option<Source>) -> (Option<PreviewShot>, Option<Source>) {
        let mut frames = match kept {
            Some(k) => k,
            None => match (self.source)(self.sequence, &self.settings) {
                Ok(f) => f,
                Err(_) => return (None, None),
            },
        };
        let count = frames.frame_count();
        let Some(last) = count.checked_sub(1) else { return (None, Some(frames)) };
        let index = match self.at {
            At::Fraction(f) => ExportPreviewMath::playhead_index(f, count as i64) as usize,
            At::Index(i) => i,
        }
        .min(last);
        let duration = frames.frame_duration();
        let shot = frames.frame(index).ok().and_then(|f| (self.pixels)(&f)).map(|image| PreviewShot {
            image,
            index,
            count,
            duration,
        });
        (shot, Some(frames))
    }

    /// One render without a kept source (tests, one-off).
    #[cfg(test)]
    pub(crate) fn render_once(&self) -> Option<PreviewShot> {
        self.render(None).0
    }

    fn same_inputs(&self, other: &(Id, ExportSettings)) -> bool {
        self.sequence == other.0 && self.settings == other.1
    }
}

#[derive(Default)]
struct State {
    busy: bool,
    wanted: Option<PreviewJob>,
    done: Option<Option<PreviewShot>>,
    /// The source of the last render and what it was made from: scrubbing and playing reuse it like the Mac model.
    kept: Option<((Id, ExportSettings), Source)>,
}

/// Renders preview jobs on worker threads, newest request wins.
#[derive(Clone, Default)]
pub(crate) struct PreviewWorker {
    state: Arc<Mutex<State>>,
}

impl PreviewWorker {
    /// Asks for a picture; it replaces a request that has not started yet.
    pub(crate) fn request(&self, job: PreviewJob) {
        self.state.lock().unwrap_or_else(PoisonError::into_inner).wanted = Some(job);
        self.start_next();
    }

    /// The finished picture (`Some(None)` = the render failed), once; starts the waiting request.
    pub(crate) fn take(&self) -> Option<Option<PreviewShot>> {
        let done = self.state.lock().unwrap_or_else(PoisonError::into_inner).done.take();
        self.start_next();
        done
    }

    fn start_next(&self) {
        let (job, kept) = {
            let mut s = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            if s.busy {
                return;
            }
            let Some(job) = s.wanted.take() else { return };
            s.busy = true;
            let kept = match s.kept.take() {
                Some((key, src)) if job.same_inputs(&key) => Some(src),
                _ => None,
            };
            (job, kept)
        };
        let state = Arc::clone(&self.state);
        std::thread::spawn(move || {
            let (shot, source) = job.render(kept);
            let mut s = state.lock().unwrap_or_else(PoisonError::into_inner);
            s.kept = source.map(|src| ((job.sequence, job.settings.clone()), src));
            s.done = Some(shot);
            s.busy = false;
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_editor_session::SequenceItem;
    use sq_export::core::error::ExportError;
    use sq_export::core::traits::{ExportFrame, FrameSource};
    use sq_frame::sqframe::{SQFrame, SQFrameColorSpace, SQFramePixelFormat, SQFrameStorage};
    use std::time::{Duration, Instant};

    struct Nothing;
    impl SQFrameStorage for Nothing {}

    struct Frames;
    impl FrameSource for Frames {
        fn frame_count(&self) -> usize {
            100
        }
        fn frame_duration(&self) -> Time {
            Time::new(1, 25)
        }
        fn frame(&mut self, index: usize) -> Result<ExportFrame, ExportError> {
            let time = Time::new(index as i64, 25);
            Ok(SQFrame::new(2, 2, SQFramePixelFormat::Rgba8, SQFrameColorSpace::Rec709, time, Arc::new(Nothing)))
        }
    }

    fn job(at: At) -> PreviewJob {
        let item = SequenceItem::new(Id::from_u128(1), "s", Time::seconds(4));
        let mut model = ExportDialogModel::new(
            vec![item],
            None,
            ExportDialogModel::system_free_space(),
            Arc::new(|_, _| Err(ExportError::Other("none".into()))),
            Box::new(sq_core_time::SequentialIds::default()),
        );
        model.set_preview_source(Some(Arc::new(|_, _| Ok(Box::new(Frames)))));
        let pixels: FramePixels = Arc::new(|f| {
            let first = f.presentation_time.frame_index(Time::new(1, 25)) as u8;
            Some(RgbaImage { width: 1, height: 1, pixels: vec![first, 0, 0, 255] })
        });
        PreviewJob::new(&model, at, &pixels).expect("a job")
    }

    fn wait(worker: &PreviewWorker) -> Option<PreviewShot> {
        let end = Instant::now() + Duration::from_secs(10);
        while Instant::now() < end {
            if let Some(done) = worker.take() {
                return done;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        panic!("the worker did not finish");
    }

    #[test]
    fn the_worker_renders_off_the_calling_thread_and_the_newest_request_wins() {
        let worker = PreviewWorker::default();
        worker.request(job(At::Index(25)));
        // Asked while the first may still run: this replaces any request that has not started.
        worker.request(job(At::Index(50)));
        worker.request(job(At::Index(75)));
        let mut last = wait(&worker).expect("a picture");
        let end = Instant::now() + Duration::from_secs(2);
        while Instant::now() < end && last.image.pixels[0] != 75 {
            if let Some(Some(next)) = worker.take() {
                last = next;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(last.image.pixels[0], 75, "3 s at 25 fps is frame 75");
        assert_eq!((last.index, last.count, last.duration), (75, 100, Time::new(1, 25)));
    }

    #[test]
    fn a_fraction_picks_the_nearest_frame_and_the_source_is_kept_between_frames() {
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let item = SequenceItem::new(Id::from_u128(1), "s", Time::seconds(4));
        let mut model = ExportDialogModel::new(
            vec![item],
            None,
            ExportDialogModel::system_free_space(),
            Arc::new(|_, _| Err(ExportError::Other("none".into()))),
            Box::new(sq_core_time::SequentialIds::default()),
        );
        let seen = Arc::clone(&calls);
        model.set_preview_source(Some(Arc::new(move |_, _| {
            seen.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            Ok(Box::new(Frames))
        })));
        let pixels: FramePixels = Arc::new(|_| Some(RgbaImage { width: 1, height: 1, pixels: vec![0, 0, 0, 255] }));
        let worker = PreviewWorker::default();
        worker.request(PreviewJob::new(&model, At::Fraction(0.5), &pixels).expect("a job"));
        let first = wait(&worker).expect("a picture");
        assert_eq!(first.index, 50, "half of 0..99 rounds to 50");
        worker.request(PreviewJob::new(&model, At::Fraction(1.0), &pixels).expect("a job"));
        assert_eq!(wait(&worker).expect("a picture").index, 99);
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 1, "the second frame reuses the source");
    }
}
