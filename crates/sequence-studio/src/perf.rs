//! `SQ_PERF=1`: once a second the window loop prints how many frames it drew and what the video upload and the whole
//! draw cost, so a slow playback can be told apart from a slow decode.

use std::time::{Duration, Instant};

/// Per-second frame statistics of the window loop; inert unless `SQ_PERF` is set.
pub struct FramePerf {
    on: bool,
    play_after: Option<Instant>,
    since: Instant,
    frames: u32,
    first_generation: Option<i64>,
    upload: Duration,
    total: Duration,
}

impl FramePerf {
    pub fn new() -> FramePerf {
        FramePerf {
            on: std::env::var_os("SQ_PERF").is_some(),
            play_after: None,
            since: Instant::now(),
            frames: 0,
            first_generation: None,
            upload: Duration::ZERO,
            total: Duration::ZERO,
        }
    }

    /// With `SQ_PERF=play`, true once, 3 s after the first picture: the caller starts playback (no key injection needed).
    pub fn autoplay(&mut self, has_picture: bool) -> bool {
        if std::env::var("SQ_PERF").as_deref() != Ok("play") || !has_picture {
            return false;
        }
        match self.play_after {
            None => {
                self.play_after = Some(Instant::now() + Duration::from_secs(3));
                false
            }
            Some(at) if Instant::now() >= at => {
                self.play_after = Some(Instant::now() + Duration::from_secs(86_400));
                true
            }
            Some(_) => false,
        }
    }

    /// Records one drawn frame: the picture upload and the upload plus draw and present.
    pub fn frame(&mut self, upload: Duration, total: Duration, generation: i64, playhead: f64) {
        if !self.on {
            return;
        }
        self.frames += 1;
        let first = *self.first_generation.get_or_insert(generation);
        self.upload += upload;
        self.total += total;
        let secs = self.since.elapsed().as_secs_f64();
        if secs >= 1.0 {
            let n = f64::from(self.frames);
            eprintln!(
                "perf: {:.1} frames/s, {:.1} pictures/s, upload {:.2} ms, upload+draw+present {:.2} ms, playhead {playhead:.2} s",
                n / secs,
                (generation - first) as f64 / secs,
                self.upload.as_secs_f64() * 1e3 / n,
                self.total.as_secs_f64() * 1e3 / n
            );
            *self = FramePerf {
                on: true,
                play_after: self.play_after,
                since: Instant::now(),
                frames: 0,
                first_generation: None,
                upload: Duration::ZERO,
                total: Duration::ZERO,
            };
        }
    }
}
