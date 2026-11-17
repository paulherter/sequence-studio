//! The picture of the Library's video preview: a worker decodes the frame the preview sound is at and the host puts it
//! into the thumbnail atlas for the viewer. The decode never blocks the window: the host names the time it wants every
//! frame and only the newest wish is served (a slow decode drops frames and keeps up with the sound, it does not lag).

use crate::project_services::{poster_size, upright_thumbnail};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};

use sq_core_time::{Id, Time};
use sq_media::demuxing::Demuxing;
use sq_media_ffmpeg::decode::{FFmpegDemuxer, FFmpegFrame, FFmpegVideoDecoder};

/// The box a preview picture fits in, in pixels: the viewer is a few hundred points wide, and a bigger picture only costs
/// decode time.
pub const MAX_WIDTH: usize = 640;
/// See [`MAX_WIDTH`].
pub const MAX_HEIGHT: usize = 360;
/// The most frames a decode runs through to reach the wanted one without a seek (the sound is ahead by a few frames at most;
/// a longer way is cheaper as a seek to the nearest key frame).
const MAX_RUN: usize = 24;

/// One upright picture of the previewed video.
#[derive(Clone, Debug, PartialEq)]
pub struct PreviewPicture {
    /// Width in pixels (at most [`MAX_WIDTH`]).
    pub width: usize,
    /// Height in pixels (at most [`MAX_HEIGHT`]).
    pub height: usize,
    /// RGBA, `width * height * 4` bytes.
    pub rgba: Vec<u8>,
}

/// Decodes the pictures of one file.
pub trait PictureSource: Send {
    /// The picture at `seconds`; `None` when that is the picture already handed out or the frame cannot be decoded.
    fn picture_at(&mut self, seconds: f64) -> Option<PreviewPicture>;
}

/// Opens a file for [`PreviewVideo`]; `None` when it holds no picture to decode.
pub type OpenSource = Arc<dyn Fn(&Path) -> Option<Box<dyn PictureSource>> + Send + Sync>;

/// Runs on the worker when a new picture is ready (the window redraws).
type Wake = Arc<dyn Fn() + Send + Sync>;

#[derive(Default)]
struct State {
    /// Counts loads and unloads; a picture of an older one is dropped.
    generation: u64,
    path: Option<PathBuf>,
    want: Option<f64>,
    ready: Option<PreviewPicture>,
    wake: Option<Wake>,
    quit: bool,
}

struct Shared {
    state: Mutex<State>,
    changed: Condvar,
}

fn lock(shared: &Shared) -> MutexGuard<'_, State> {
    shared.state.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The preview's picture decoder on its own worker thread (started by the first load).
pub struct PreviewVideo {
    open: OpenSource,
    shared: Arc<Shared>,
    started: bool,
}

impl PreviewVideo {
    /// A decoder over `open` (the FFmpeg one in the app, a stand-in in tests); no thread yet.
    pub fn new(open: OpenSource) -> PreviewVideo {
        PreviewVideo {
            open,
            shared: Arc::new(Shared { state: Mutex::new(State::default()), changed: Condvar::new() }),
            started: false,
        }
    }

    /// Runs `wake` (from the worker) whenever a new picture is ready.
    pub fn set_wake(&mut self, wake: Wake) {
        lock(&self.shared).wake = Some(wake);
    }

    /// Starts on `path`: the next [`PreviewVideo::show`] decodes from there. Pictures of the previous file are dropped.
    pub fn load(&mut self, path: &Path) {
        self.replace(Some(path.to_path_buf()));
        if !self.started {
            self.started = true;
            let (shared, open) = (Arc::clone(&self.shared), Arc::clone(&self.open));
            // A failed spawn leaves the preview on its poster, the same as a file that has no picture.
            let _ =
                std::thread::Builder::new().name("library-preview-video".into()).spawn(move || work(&shared, &open));
        }
    }

    /// Drops the file and every waiting picture.
    pub fn unload(&mut self) {
        self.replace(None);
    }

    fn replace(&mut self, path: Option<PathBuf>) {
        let mut s = lock(&self.shared);
        s.generation += 1;
        s.path = path;
        s.want = None;
        s.ready = None;
        self.shared.changed.notify_all();
    }

    /// The picture for `seconds` of the file is wanted; the newest wish wins.
    pub fn show(&mut self, seconds: f64) {
        let mut s = lock(&self.shared);
        if s.path.is_some() {
            s.want = Some(seconds);
            self.shared.changed.notify_all();
        }
    }

    /// The newest picture that arrived since the last call.
    pub fn take(&mut self) -> Option<PreviewPicture> {
        lock(&self.shared).ready.take()
    }
}

impl Drop for PreviewVideo {
    fn drop(&mut self) {
        // The worker ends after the decode it is in; the window does not wait for it.
        lock(&self.shared).quit = true;
        self.shared.changed.notify_all();
    }
}

fn work(shared: &Shared, open: &OpenSource) {
    let mut source: Option<Box<dyn PictureSource>> = None;
    let mut seen = 0;
    loop {
        let (generation, path, want) = {
            let mut s = lock(shared);
            while !s.quit && s.generation == seen && s.want.is_none() {
                s = shared.changed.wait(s).unwrap_or_else(PoisonError::into_inner);
            }
            if s.quit {
                return;
            }
            (s.generation, s.path.clone(), s.want.take())
        };
        if generation != seen {
            source = path.and_then(|p| open(&p));
            seen = generation;
        }
        let (Some(src), Some(at)) = (source.as_mut(), want) else { continue };
        let Some(picture) = src.picture_at(at) else { continue };
        let mut s = lock(shared);
        if s.generation != generation {
            continue;
        }
        s.ready = Some(picture);
        let wake = s.wake.clone();
        drop(s);
        if let Some(wake) = wake {
            wake();
        }
    }
}

/// The FFmpeg decoder behind [`PictureSource`]: one demuxer and decoder per file, so playing on needs no seek.
struct FfmpegPictures {
    demuxer: Arc<FFmpegDemuxer>,
    decoder: FFmpegVideoDecoder,
    /// The frame index of the last picture handed out.
    last: Option<usize>,
}

/// Opens the file with FFmpeg (the app's source).
pub fn ffmpeg_pictures() -> OpenSource {
    Arc::new(|path| {
        let demuxer = FFmpegDemuxer::open_shared(path).ok()?;
        let decoder = FFmpegVideoDecoder::new(Arc::clone(&demuxer), Id::from_u128(0), false, 0).ok()?;
        Some(Box::new(FfmpegPictures { demuxer, decoder, last: None }) as Box<dyn PictureSource>)
    })
}

impl PictureSource for FfmpegPictures {
    fn picture_at(&mut self, seconds: f64) -> Option<PreviewPicture> {
        let index = self.demuxer.index();
        let count = index.count();
        // The end of the file shows its last frame (`frame_at` knows nothing at or after the end).
        let at = Time::new((seconds.max(0.0) * 90_000.0).round() as i64, 90_000);
        let wanted = index.frame_at(at).unwrap_or(if seconds > 0.0 { count.saturating_sub(1) } else { 0 });
        if self.last == Some(wanted) {
            return None;
        }
        let from = match self.last {
            Some(last) if wanted > last && wanted - last <= MAX_RUN => last + 1,
            _ => wanted,
        };
        let decoded = self.decoder.decode_blocking(from..=wanted, None, None).ok().and_then(|mut f| f.pop());
        self.last = decoded.as_ref().map(|_| wanted);
        let decoded = decoded?;
        let rgba = decoded.frame.storage_as::<FFmpegFrame>()?.download_rgba().ok()?;
        let (w, h) = (decoded.frame.width, decoded.frame.height);
        let info = self.demuxer.track_info();
        let aspect = Some(info.pixel_aspect);
        // The height that makes the upright picture fit the box.
        let sideways = ((self.demuxer.rotation() / 90) % 2 + 2) % 2 == 1;
        let (shown_w, shown_h) = if sideways { (h, w) } else { (w, h) };
        let (full_w, _) = poster_size(shown_w, shown_h, i64::MAX, aspect);
        let by_width = MAX_WIDTH * shown_h / full_w.max(1);
        let target = MAX_HEIGHT.min(by_width).max(1);
        let t = upright_thumbnail(&rgba, w, h, self.demuxer.rotation(), target as i64, aspect);
        Some(PreviewPicture {
            width: t.width,
            height: t.height,
            rgba: Arc::try_unwrap(t.rgba).unwrap_or_else(|a| (*a).clone()),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::{Duration, Instant};

    /// A picture whose first byte is the frame number at 10 frames a second.
    struct Counting(Arc<AtomicUsize>);

    impl PictureSource for Counting {
        fn picture_at(&mut self, seconds: f64) -> Option<PreviewPicture> {
            self.0.fetch_add(1, Ordering::SeqCst);
            let frame = (seconds * 10.0).round() as u8;
            Some(PreviewPicture { width: 1, height: 1, rgba: vec![frame, 0, 0, 255] })
        }
    }

    fn counting() -> (OpenSource, Arc<AtomicUsize>) {
        let calls = Arc::new(AtomicUsize::new(0));
        let c = Arc::clone(&calls);
        (Arc::new(move |_| Some(Box::new(Counting(Arc::clone(&c))) as Box<dyn PictureSource>)), calls)
    }

    fn wait_for(video: &mut PreviewVideo) -> Option<PreviewPicture> {
        let end = Instant::now() + Duration::from_secs(5);
        while Instant::now() < end {
            if let Some(p) = video.take() {
                return Some(p);
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        None
    }

    #[test]
    fn a_wish_becomes_a_picture_and_wakes_the_window() {
        let (open, _) = counting();
        let mut video = PreviewVideo::new(open);
        let woken = Arc::new(AtomicUsize::new(0));
        let w = Arc::clone(&woken);
        video.set_wake(Arc::new(move || {
            w.fetch_add(1, Ordering::SeqCst);
        }));
        video.show(1.0);
        assert!(wait_for(&mut video).is_none(), "nothing is loaded: no picture");
        video.load(Path::new("a.mp4"));
        video.show(1.5);
        assert_eq!(wait_for(&mut video).map(|p| p.rgba[0]), Some(15));
        video.show(2.5);
        assert_eq!(wait_for(&mut video).map(|p| p.rgba[0]), Some(25));
        assert_eq!(woken.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn a_picture_of_the_previous_file_is_dropped() {
        let (open, _) = counting();
        let mut video = PreviewVideo::new(open);
        video.load(Path::new("a.mp4"));
        video.show(1.0);
        assert!(wait_for(&mut video).is_some());
        video.show(2.0);
        std::thread::sleep(Duration::from_millis(50));
        video.unload();
        assert!(video.take().is_none(), "the picture that was ready belongs to the file that is gone");
        video.show(3.0);
        assert!(wait_for(&mut video).is_none(), "unloaded: wishes are ignored");
    }

    #[test]
    fn a_file_that_cannot_be_opened_stays_without_a_picture() {
        let mut video = PreviewVideo::new(Arc::new(|_| None));
        video.load(Path::new("none.mp4"));
        video.show(1.0);
        assert!(wait_for(&mut video).is_none());
    }
}
