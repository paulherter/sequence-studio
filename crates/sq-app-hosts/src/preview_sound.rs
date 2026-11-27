//! The Library preview's sound on every system: an FFmpeg audio source streams the file (a few seconds ahead of the
//! play position, never the whole file), the shared cpal output (`sq-audio-out`) plays it, so a Windows or Linux preview
//! sounds like the Mac one (AVPlayer streams there). A file without sound (a silent video) and a machine without an output
//! device play on a clock of their own, so the picture and the bar still move.

use sq_audio_out::output::{AudioOut, OutputConfig, Renderer};
use sq_core_edit::playback::PlaybackRate;
use sq_core_time::Time;
use sq_library::library_preview_player_portable::{PreviewSound, SoundState};
use sq_media::demuxing::Demuxing;
use sq_media::memory_audio_source::AudioSource;
use sq_media_ffmpeg::decode::{FFmpegAudioSource, FFmpegDemuxer};
use std::path::Path;
use std::sync::atomic::{AtomicI64, AtomicU32, AtomicU64, Ordering::Relaxed};
use std::sync::mpsc::{Receiver, channel};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

const RATE: i64 = 48_000;
/// Frames the feeder reads per refill (4 s).
const WINDOW_FRAMES: usize = 4 * RATE as usize;
/// A refill starts when less than this is left ahead of the play position (1.5 s).
const LOW_WATER: i64 = RATE * 3 / 2;

/// A stretch of the file, interleaved stereo, from frame `start`.
#[derive(Default)]
struct Window {
    start: i64,
    data: Vec<f32>,
}

impl Window {
    fn frames(&self) -> i64 {
        (self.data.len() / 2) as i64
    }
}

#[derive(Default)]
struct Shared {
    window: Mutex<Window>,
    gain_bits: AtomicU32,
    /// Next frame to render.
    frame: AtomicI64,
    /// Which load the feeder thread belongs to; a thread of an older load ends.
    generation: AtomicU64,
    wake: (Mutex<()>, Condvar),
    error: Mutex<Option<String>>,
}

impl Shared {
    fn poke(&self) {
        let _g = self.wake.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        self.wake.1.notify_all();
    }
}

/// Renders the loaded file from the anchor the output restarts at.
struct StreamRenderer(Arc<Shared>);

impl Renderer for StreamRenderer {
    fn render(&mut self, out: &mut [f32]) {
        fill_block(&self.0, out);
        self.0.poke();
    }
    fn flush(&mut self, anchor: Time, _rate: PlaybackRate) {
        self.0.frame.store(anchor.value() * RATE / anchor.timescale(), Relaxed);
        self.0.poke();
    }
}

/// Copies the next block (interleaved stereo) times the gain; zeros where the window does not hold the frames (before the
/// feeder caught up, or past the end).
fn fill_block(shared: &Shared, out: &mut [f32]) {
    let gain = f32::from_bits(shared.gain_bits.load(Relaxed));
    let frame = shared.frame.load(Relaxed);
    out.fill(0.0);
    {
        let w = shared.window.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let from = frame - w.start;
        if from >= 0 && from < w.frames() {
            let start = from as usize * 2;
            let n = out.len().min(w.data.len() - start);
            for (o, s) in out[..n].iter_mut().zip(&w.data[start..start + n]) {
                *o = s * gain;
            }
        }
    }
    shared.frame.fetch_add((out.len() / 2) as i64, Relaxed);
}

/// The window must be read again: the play position left it, or less than [`LOW_WATER`] is left and the file goes on.
fn needs_refill(start: i64, frames: i64, frame: i64, total: i64) -> bool {
    let frame = frame.max(0);
    if frame >= total {
        return false;
    }
    let end = start + frames;
    frame < start || frame >= end || (end - frame < LOW_WATER && end < total)
}

/// The feeder: keeps the window around the play position filled until the load is replaced.
fn feed(shared: &Shared, generation: u64, source: &dyn AudioSource, total: i64) {
    // Where the file really ends: a container may promise more frames than it holds (an empty read moves it here).
    let mut end = total;
    while shared.generation.load(Relaxed) == generation {
        let frame = shared.frame.load(Relaxed).max(0);
        let need = {
            let w = shared.window.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            needs_refill(w.start, w.frames(), frame, end)
        };
        if !need {
            let g = shared.wake.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let _ = shared.wake.1.wait_timeout(g, Duration::from_millis(40));
            continue;
        }
        let n = WINDOW_FRAMES.min(usize::try_from(end - frame).unwrap_or(0));
        let (mut left, mut right) = (vec![0.0f32; n], vec![0.0f32; n]);
        let got = match (source.read(frame, &mut left, 0), source.read(frame, &mut right, 1)) {
            (Ok(a), Ok(b)) => {
                // The retry worked: the sound is whole again, so the problem is not shown any longer.
                *shared.error.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = None;
                a.min(b)
            }
            (Err(e), _) | (_, Err(e)) => {
                // Shown while it lasts; the feeder stays and retries, so a later seek or play can still sound.
                *shared.error.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(e.to_string());
                let g = shared.wake.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                let _ = shared.wake.1.wait_timeout(g, Duration::from_millis(250));
                continue;
            }
        };
        let mut data = Vec::with_capacity(got * 2);
        for i in 0..got {
            data.push(left[i]);
            data.push(right[i]);
        }
        if got == 0 {
            // The container promised more than it holds: the file ends here, a seek before it still refills.
            end = frame.min(end);
            continue;
        }
        // Checked under the window lock: `reset_stream` bumps the generation before it clears the window, so a stale
        // window of an older load never survives a new one.
        let mut w = shared.window.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if shared.generation.load(Relaxed) != generation {
            return;
        }
        *w = Window { start: frame, data };
    }
}

/// What the open thread found in the file.
struct Loaded {
    /// Length in frames at [`RATE`].
    frames: i64,
    /// The file has no sound but a picture ([`silent_frames`]).
    silent: bool,
}

/// The length in [`RATE`] frames of a file that shows a picture but has no sound; `None` when it has no picture either.
fn silent_frames(path: &Path) -> Option<i64> {
    let end = FFmpegDemuxer::open_shared(path).ok()?.index().duration();
    let frames = end.value() * RATE / end.timescale();
    (frames > 0).then_some(frames)
}

/// FFmpeg streaming and cpal output behind [`PreviewSound`].
pub struct FfmpegSound {
    shared: Arc<Shared>,
    out: Option<AudioOut>,
    pending: Option<Receiver<Result<Loaded, String>>>,
    frames: i64,
    /// The file has no sound (a silent video): the position runs on `clock` and nothing is sent to the output.
    silent: bool,
    /// Where `held` was taken up while a silent file plays.
    clock: Option<Instant>,
    /// Where the sound holds while not playing, in frames.
    held: i64,
    playing: bool,
    started: bool,
    error: Option<String>,
}

impl Default for FfmpegSound {
    fn default() -> Self {
        FfmpegSound::new()
    }
}

impl FfmpegSound {
    /// No file loaded; the output opens at the first play.
    pub fn new() -> FfmpegSound {
        let shared = Arc::new(Shared::default());
        shared.gain_bits.store(0.8_f32.to_bits(), Relaxed);
        FfmpegSound {
            shared,
            out: None,
            pending: None,
            frames: 0,
            silent: false,
            clock: None,
            held: 0,
            playing: false,
            started: false,
            error: None,
        }
    }

    fn position_frames(&self) -> i64 {
        if self.started && self.playing {
            if let Some(since) = self.clock {
                return self.held + (since.elapsed().as_secs_f64() * RATE as f64) as i64;
            }
            if let Some(out) = &self.out {
                let t = out.clock().now();
                return t.value() * RATE / t.timescale();
            }
        }
        self.held
    }

    /// Opens the output the first time; false when the machine has none.
    fn open_output(&mut self) -> bool {
        if self.out.is_some() {
            return true;
        }
        let (tx, _rx) = channel();
        self.out = AudioOut::open(OutputConfig::default(), Box::new(StreamRenderer(Arc::clone(&self.shared))), tx).ok();
        self.out.is_some()
    }

    /// Starts the output at the held position once the file is decoded.
    fn start(&mut self) {
        if self.frames == 0 || self.error.is_some() {
            return;
        }
        // No output device: the preview still runs, silently, on a clock (the main player does the same).
        if !self.silent && !self.open_output() {
            self.silent = true;
        }
        if self.silent {
            self.clock = Some(Instant::now());
            self.started = true;
        } else if let Some(out) = &self.out {
            out.restart(Time::new(self.held, RATE), PlaybackRate::FORWARD);
            self.started = true;
        }
    }

    /// Ends the feeder of the previous load and empties the window.
    fn reset_stream(&mut self) {
        self.shared.generation.fetch_add(1, Relaxed);
        *self.shared.window.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Window::default();
        *self.shared.error.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = None;
        self.shared.poke();
    }

    fn halt(&mut self) {
        if self.started {
            self.held = self.position_frames();
            if let Some(out) = &self.out {
                let _ = out.stop();
            }
            self.clock = None;
            self.started = false;
        }
    }
}

impl PreviewSound for FfmpegSound {
    fn load(&mut self, path: &Path) {
        self.halt();
        self.playing = false;
        self.frames = 0;
        self.silent = false;
        self.held = 0;
        self.error = None;
        self.reset_stream();
        let generation = self.shared.generation.load(Relaxed);
        let (tx, rx) = channel();
        self.pending = Some(rx);
        let path = path.to_path_buf();
        let shared = Arc::clone(&self.shared);
        std::thread::spawn(move || {
            let source = match FFmpegAudioSource::open(&path, RATE as i32) {
                Ok(s) if s.frame_count() > 0 => s,
                opened => {
                    // No sound: a video still plays, as its picture on a clock of its own.
                    let reply = match (silent_frames(&path), opened) {
                        (Some(frames), _) => Ok(Loaded { frames, silent: true }),
                        (None, Ok(_)) => Err("This file has no sound.".to_string()),
                        (None, Err(e)) => Err(e.to_string()),
                    };
                    let _ = tx.send(reply);
                    return;
                }
            };
            let total = source.frame_count();
            let _ = tx.send(Ok(Loaded { frames: total, silent: false }));
            feed(&shared, generation, &source, total);
        });
    }

    fn play(&mut self) {
        self.playing = true;
        if !self.started {
            self.start();
        }
    }

    fn pause(&mut self) {
        self.halt();
        self.playing = false;
    }

    fn seek(&mut self, seconds: f64) {
        let target = ((seconds * RATE as f64) as i64).clamp(0, self.frames.max(0));
        self.held = target;
        if self.silent {
            if self.started {
                self.clock = Some(Instant::now());
            }
        } else if self.started {
            if let Some(out) = &self.out {
                out.restart(Time::new(target, RATE), PlaybackRate::FORWARD);
            }
        } else {
            // Prefill the window at the new place so the first play starts without a gap.
            self.shared.frame.store(target, Relaxed);
            self.shared.poke();
        }
    }

    fn set_gain(&mut self, gain: f32) {
        self.shared.gain_bits.store(gain.clamp(0.0, 1.0).to_bits(), Relaxed);
    }

    fn unload(&mut self) {
        self.halt();
        self.playing = false;
        self.pending = None;
        self.frames = 0;
        self.silent = false;
        self.held = 0;
        self.error = None;
        self.reset_stream();
    }

    fn poll(&mut self) -> SoundState {
        if let Some(rx) = &self.pending
            && let Ok(result) = rx.try_recv()
        {
            self.pending = None;
            match result {
                Ok(Loaded { frames, silent }) => {
                    self.frames = frames;
                    self.silent = silent;
                    if self.playing {
                        self.start();
                    }
                }
                Err(e) => self.error = Some(e),
            }
        }
        // The file's own error stays until the next load; the feeder's goes when its retry works.
        let feeder_error = self.shared.error.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone();
        let duration = self.frames as f64 / RATE as f64;
        let mut position = self.position_frames().clamp(0, self.frames.max(0));
        if self.started && self.playing && self.frames > 0 && position >= self.frames {
            self.halt();
            self.playing = false;
            self.held = self.frames;
            position = self.frames;
        }
        SoundState {
            duration,
            position: position as f64 / RATE as f64,
            playing: self.playing,
            error: self.error.clone().or(feeder_error),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn put(shared: &Shared, start: i64, data: Vec<f32>) {
        *shared.window.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Window { start, data };
    }

    #[test]
    fn a_block_is_the_window_from_the_frame_times_the_gain_and_silence_outside_it() {
        let shared = Shared::default();
        shared.gain_bits.store(0.5_f32.to_bits(), Relaxed);
        put(&shared, 10, vec![1.0, -1.0, 0.5, 0.5, 0.25, 0.25]);
        shared.frame.store(11, Relaxed);
        let mut out = vec![9.0; 8];
        fill_block(&shared, &mut out);
        assert_eq!(out, [0.25, 0.25, 0.125, 0.125, 0.0, 0.0, 0.0, 0.0]);
        assert_eq!(shared.frame.load(Relaxed), 15);
        // Before the window (the feeder has not caught up): silence, the position still advances.
        shared.frame.store(2, Relaxed);
        fill_block(&shared, &mut out);
        assert_eq!(out, [0.0; 8]);
        assert_eq!(shared.frame.load(Relaxed), 6);
    }

    #[test]
    fn the_window_is_read_again_when_left_or_running_low_but_not_at_the_end() {
        let total = RATE * 600;
        assert!(needs_refill(0, 0, 0, total), "empty window");
        assert!(!needs_refill(0, WINDOW_FRAMES as i64, 1000, total), "plenty ahead");
        assert!(needs_refill(0, WINDOW_FRAMES as i64, WINDOW_FRAMES as i64 - LOW_WATER + 1, total), "running low");
        assert!(needs_refill(RATE, WINDOW_FRAMES as i64, 10, total), "seeked before the window");
        assert!(needs_refill(0, WINDOW_FRAMES as i64, WINDOW_FRAMES as i64 + 5, total), "seeked past the window");
        let short = WINDOW_FRAMES as i64;
        assert!(!needs_refill(0, short, short - 10, short), "the file ends with the window");
        assert!(!needs_refill(0, short, short, short), "at the end nothing is read");
    }

    #[test]
    fn the_feeder_streams_a_long_source_in_windows_and_follows_a_seek() {
        let total = (RATE * 60) as usize;
        let left: Vec<f32> = (0..total).map(|i| i as f32).collect();
        let right: Vec<f32> = (0..total).map(|i| -(i as f32)).collect();
        let source = Arc::new(sq_media::memory_audio_source::MemoryAudioSource::new(left, right));
        let shared = Arc::new(Shared::default());
        shared.gain_bits.store(1.0_f32.to_bits(), Relaxed);
        let generation = shared.generation.fetch_add(1, Relaxed) + 1;
        let (s2, src) = (Arc::clone(&shared), Arc::clone(&source));
        let t = std::thread::spawn(move || feed(&s2, generation, &*src, total as i64));
        let wait = |want: i64| {
            for _ in 0..500 {
                let w = shared.window.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                if w.start == want && w.frames() > 0 {
                    return w.frames();
                }
                drop(w);
                shared.poke();
                std::thread::sleep(Duration::from_millis(5));
            }
            panic!("no window at {want}");
        };
        assert_eq!(wait(0), WINDOW_FRAMES as i64, "a window of 4 s, not the whole minute");
        shared.frame.store(RATE * 30, Relaxed);
        shared.poke();
        wait(RATE * 30);
        let mut out = vec![0.0; 4];
        fill_block(&shared, &mut out);
        assert_eq!(out, [(RATE * 30) as f32, -((RATE * 30) as f32), (RATE * 30 + 1) as f32, -((RATE * 30 + 1) as f32)]);
        shared.generation.fetch_add(1, Relaxed);
        shared.poke();
        t.join().expect("feeder ends with its load");
    }

    #[test]
    fn a_read_past_the_real_end_keeps_the_feeder_and_a_seek_back_refills() {
        // The container claims ten seconds but holds one: the empty read must not end the feeder.
        let real = RATE as usize;
        let left: Vec<f32> = (0..real).map(|i| i as f32).collect();
        let source = Arc::new(sq_media::memory_audio_source::MemoryAudioSource::new(left.clone(), left));
        let shared = Arc::new(Shared::default());
        let generation = shared.generation.fetch_add(1, Relaxed) + 1;
        shared.frame.store(RATE * 5, Relaxed);
        let (s2, src) = (Arc::clone(&shared), Arc::clone(&source));
        let t = std::thread::spawn(move || feed(&s2, generation, &*src, RATE * 10));
        std::thread::sleep(Duration::from_millis(50));
        assert!(!t.is_finished(), "the feeder waits for the next seek");
        shared.frame.store(0, Relaxed);
        let mut filled = false;
        for _ in 0..500 {
            shared.poke();
            let w = shared.window.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            if w.start == 0 && w.frames() > 0 {
                filled = true;
                break;
            }
            drop(w);
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(filled, "the seek back to the start refilled the window");
        shared.generation.fetch_add(1, Relaxed);
        shared.poke();
        t.join().expect("feeder ends with its load");
    }

    #[test]
    fn a_missing_file_ends_as_an_error_not_a_hang() {
        let mut s = FfmpegSound::new();
        s.load(Path::new("/nonexistent/none.wav"));
        s.play();
        let mut st = s.poll();
        for _ in 0..200 {
            if st.error.is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
            st = s.poll();
        }
        assert!(st.error.is_some(), "the decode error is reported");
    }

    /// Fails its first `fails` reads, then reads like the memory source.
    struct Flaky {
        inner: sq_media::memory_audio_source::MemoryAudioSource,
        fails: std::sync::atomic::AtomicI64,
    }

    impl AudioSource for Flaky {
        fn read(
            &self,
            at: i64,
            buffer: &mut [f32],
            channel: usize,
        ) -> Result<usize, sq_media::media_error::MediaError> {
            if self.fails.fetch_sub(1, Relaxed) > 0 {
                return Err(sq_media::media_error::MediaError::DecodeFailed(-5));
            }
            self.inner.read(at, buffer, channel)
        }
    }

    #[test]
    fn a_read_error_shows_while_it_lasts_and_goes_when_the_retry_works() {
        let tone: Vec<f32> = vec![0.5; RATE as usize];
        let source = Arc::new(Flaky {
            inner: sq_media::memory_audio_source::MemoryAudioSource::new(tone.clone(), tone),
            fails: std::sync::atomic::AtomicI64::new(2),
        });
        let shared = Arc::new(Shared::default());
        let generation = shared.generation.fetch_add(1, Relaxed) + 1;
        let (s2, src) = (Arc::clone(&shared), Arc::clone(&source));
        let t = std::thread::spawn(move || feed(&s2, generation, &*src, RATE));
        let error = || shared.error.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone();
        let mut shown = false;
        let mut gone = false;
        for _ in 0..600 {
            shared.poke();
            shown |= error().is_some();
            let filled = shared.window.lock().unwrap_or_else(std::sync::PoisonError::into_inner).frames() > 0;
            if shown && filled && error().is_none() {
                gone = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(shown, "the failing read was reported");
        assert!(gone, "the error is gone once the sound reads again");
        shared.generation.fetch_add(1, Relaxed);
        shared.poke();
        t.join().expect("feeder ends with its load");
    }

    fn ffmpeg() -> std::path::PathBuf {
        std::env::var_os("SQ_FFMPEG")
            .map(|d| std::path::PathBuf::from(d).join("bin/ffmpeg"))
            .filter(|p| p.exists())
            .unwrap_or_else(|| "ffmpeg".into())
    }

    #[test]
    fn a_video_without_sound_plays_on_a_clock_of_its_own() {
        let dir = std::env::temp_dir().join(format!("sq-silent-preview-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let clip = dir.join("silent.mp4");
        let made = std::process::Command::new(ffmpeg())
            .args(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=25:duration=1", "-c:v", "mpeg4"])
            .arg(&clip)
            .output()
            .is_ok_and(|o| o.status.success());
        if !made {
            sq_os::errln!("skipped: ffmpeg cannot write the clip");
            return;
        }
        let mut s = FfmpegSound::new();
        s.load(&clip);
        s.play();
        let mut st = s.poll();
        for _ in 0..500 {
            if st.duration > 0.0 || st.error.is_some() {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
            st = s.poll();
        }
        assert_eq!(st.error, None, "a silent video is not an error");
        assert!((st.duration - 1.0).abs() < 0.1, "the length comes from the picture: {}", st.duration);
        std::thread::sleep(Duration::from_millis(300));
        let st = s.poll();
        assert!(st.playing && (0.2..0.7).contains(&st.position), "the position runs: {st:?}");
        s.seek(0.8);
        assert!(s.poll().position >= 0.8, "a seek moves the clock");
        let mut st = s.poll();
        for _ in 0..300 {
            if !st.playing {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
            st = s.poll();
        }
        assert!(!st.playing && (st.position - st.duration).abs() < 0.05, "it ends at its length: {st:?}");
        std::fs::remove_dir_all(dir).ok();
    }
}
