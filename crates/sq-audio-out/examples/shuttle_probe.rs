// SPDX-License-Identifier: GPL-3.0-or-later
//! `cargo run -p sq-audio-out --example shuttle_probe --release`: plays a tone through `AudioOut::open` (the code path of
//! the app, a real device) and presses L four times: the audio clock is started at 1x, then `set_rate` 2x, 4x and 8x like the
//! shuttle does. Prints how far the clock moved per second of wall time at each rate (expected 1, 2, 4, 8) and the underruns of each second.
use sq_audio_out::clock::PlaybackClock;
use sq_audio_out::output::{AudioOut, OutputConfig, Renderer};
use sq_core_edit::playback::PlaybackRate;
use sq_core_time::Time;
use std::time::{Duration, Instant};

struct Tone(f64);
impl Renderer for Tone {
    fn render(&mut self, out: &mut [f32]) {
        for f in out.chunks_mut(2) {
            let s = (self.0 * 2.0 * std::f64::consts::PI * 440.0 / 48_000.0).sin() as f32 * 0.1;
            f[0] = s;
            f[1] = s;
            self.0 += 1.0;
        }
    }
    fn flush(&mut self, _: Time, _: PlaybackRate) {}
}

fn seconds(t: Time) -> f64 {
    t.value() as f64 / t.timescale() as f64
}

fn main() {
    let (tx, _rx) = std::sync::mpsc::channel();
    let out = match AudioOut::open(OutputConfig::default(), Box::new(Tone(0.0)), tx) {
        Ok(o) => o,
        Err(e) => return println!("OPEN FAILED: {e}"),
    };
    let handle = out.clock();
    let clock = handle.playback_clock();
    clock.start(Time::new(10, 1), PlaybackRate::FORWARD);
    for (press, rate) in [(1, 1), (2, 2), (3, 4), (4, 8)] {
        if press > 1 {
            clock.set_rate(PlaybackRate::whole(rate));
        }
        std::thread::sleep(Duration::from_millis(700)); // restart settles
        let under0 = out.stats().underruns;
        let (t0, c0) = (Instant::now(), seconds(handle.now()));
        std::thread::sleep(Duration::from_secs(2));
        let (dt, dc) = (t0.elapsed().as_secs_f64(), seconds(handle.now()) - c0);
        println!(
            "press {press}: rate {rate}x clock moved {dc:.3} s in {dt:.3} s wall = {:.2}x (stalled {}, underruns {})",
            dc / dt,
            handle.stalled(),
            out.stats().underruns - under0
        );
    }
    println!("stats {:?} latency {:?}", out.stats(), out.latency());
}
