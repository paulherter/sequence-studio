// SPDX-License-Identifier: GPL-3.0-or-later
// Gate G6 soak, re-run on the real crate: `cargo test -p sq-audio-out --release -- --ignored soak`
// (SQ_SOAK_SECS, default 180). Needs a default audio output device; skips with a message without one.
//
// Pass: device clock drift < 50 ppm, 0 underruns at 1x, smoothed clock error p99 < 2 ms, never backwards.

use sq_audio_out::output::{AudioOut, AudioOutError, OutputConfig, OutputEvent, Renderer};
use sq_core_edit::playback::PlaybackRate;
use sq_core_time::Time;
use std::sync::mpsc::channel;
use std::time::{Duration, Instant};

/// Eight quiet sines (-60 dBFS in total), position-locked to the anchor.
struct Sines {
    pos: f64,
    dir: f64,
}

impl Renderer for Sines {
    fn render(&mut self, out: &mut [f32]) {
        for frame in out.chunks_mut(2) {
            let mut v = 0.0f64;
            for k in 0..8 {
                v += (self.pos * 2.0 * std::f64::consts::PI * 220.0 * (1.0 + 0.37 * f64::from(k)) / 48_000.0).sin();
            }
            let s = (v * 0.001 / 8.0) as f32;
            frame[0] = s;
            frame[1] = s;
            self.pos += self.dir;
        }
    }

    fn flush(&mut self, anchor: Time, rate: PlaybackRate) {
        self.pos = anchor.value() as f64 * 48_000.0 / anchor.timescale() as f64;
        self.dir = if rate.is_reverse() { -1.0 } else { 1.0 };
    }
}

/// Least squares y = a + b x; returns (a, b, residuals).
fn fit(x: &[f64], y: &[f64]) -> (f64, f64, Vec<f64>) {
    let n = x.len() as f64;
    let (mx, my) = (x.iter().sum::<f64>() / n, y.iter().sum::<f64>() / n);
    let sxy: f64 = x.iter().zip(y).map(|(a, b)| (a - mx) * (b - my)).sum();
    let sxx: f64 = x.iter().map(|a| (a - mx) * (a - mx)).sum();
    let b = sxy / sxx;
    let a = my - b * mx;
    (a, b, x.iter().zip(y).map(|(xi, yi)| yi - (a + b * xi)).collect())
}

fn pct(v: &mut [f64], p: f64) -> f64 {
    v.sort_by(|a, b| a.total_cmp(b));
    v[((v.len() - 1) as f64 * p) as usize]
}

#[test]
#[ignore = "needs an audio output device and runs for SQ_SOAK_SECS (default 180)"]
fn soak() {
    let secs: u64 = std::env::var("SQ_SOAK_SECS").ok().and_then(|v| v.parse().ok()).unwrap_or(180);
    let (etx, erx) = channel();
    let out = match AudioOut::open(OutputConfig::default(), Box::new(Sines { pos: 0.0, dir: 1.0 }), etx) {
        Ok(o) => o,
        Err(e @ (AudioOutError::NoDevice | AudioOutError::Build(_))) => {
            eprintln!("SKIP soak: no usable audio output ({e})");
            return;
        }
        Err(e) => panic!("open failed: {e}"),
    };
    let clock = out.clock();
    let audio = out.audio();
    out.restart(Time::ZERO, PlaybackRate::FORWARD);
    // Wait for the first audible sample (the clock holds at the anchor until then).
    let t0 = Instant::now();
    while clock.now() == Time::ZERO && t0.elapsed() < Duration::from_secs(3) {
        std::thread::sleep(Duration::from_millis(1));
    }
    assert!(clock.now() > Time::ZERO, "the clock never started (no audio consumed within 3 s)");
    println!("start: first audio after {:?}, output latency {:?}", t0.elapsed(), out.latency());

    // Sample the clock every ~2 ms; record the stamps the callback publishes too (device clock vs monotonic).
    let (mut xs, mut ys) = (Vec::new(), Vec::new());
    let (mut sx, mut sy) = (Vec::new(), Vec::new());
    let (mut last_frames, mut backwards) = (-1i64, 0u32);
    let mut prev: Option<Time> = None;
    let begin = Instant::now();
    while begin.elapsed() < Duration::from_secs(secs) {
        let ns = audio.host_nanoseconds();
        let p = clock.now();
        if prev.is_some_and(|prev| p < prev) {
            backwards += 1;
        }
        prev = Some(p);
        xs.push(ns as f64 * 1e-9);
        ys.push(p.value() as f64 / p.timescale() as f64);
        let st = audio.last_render();
        if st.frames != last_frames {
            last_frames = st.frames;
            sx.push(st.host_nanos as f64 * 1e-9);
            sy.push(st.frames as f64 / 48_000.0);
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    let stats = out.stats();
    println!("output latency at the end {:?}", out.latency());
    // Skip the first 2 s (filter settling) for the fits.
    let skip = xs.iter().position(|&x| x > xs[0] + 2.0).unwrap_or(0);
    let (_, slope, resid) = fit(&xs[skip..], &ys[skip..]);
    let mut err_ms: Vec<f64> = resid.iter().map(|r| r.abs() * 1e3).collect();
    let skip_s = sx.iter().position(|&x| x > sx[0] + 2.0).unwrap_or(0);
    let (_, dev_slope, _) = fit(&sx[skip_s..], &sy[skip_s..]);
    let (clock_ppm, device_ppm) = ((slope - 1.0) * 1e6, (dev_slope - 1.0) * 1e6);
    let (p99, max) = (pct(&mut err_ms, 0.99), pct(&mut err_ms, 1.0));
    println!("samples {} over {secs} s, callbacks {}, backwards steps {backwards}", xs.len(), stats.callbacks);
    println!("clock slope {clock_ppm:+.1} ppm, device stamps slope {device_ppm:+.1} ppm");
    println!("clock error after linear fit: p99 {p99:.3} ms, max {max:.3} ms");
    println!(
        "underruns {}, min ring fill {:?} of {} frames",
        stats.underruns, stats.min_fill_frames, stats.ring_frames
    );
    while let Ok(e) = erx.try_recv() {
        println!("event: {e:?}");
        assert!(!matches!(e, OutputEvent::Underrun(_)), "underrun event at 1x");
    }
    // A slope fit over a short run is dominated by the callback jitter (+-2 ms over 6 s is already 300 ppm): only judge it from 60 s on.
    if secs >= 60 {
        assert!(clock_ppm.abs() < 50.0, "clock drift {clock_ppm} ppm");
        assert!(device_ppm.abs() < 50.0, "device drift {device_ppm} ppm");
    }
    assert_eq!(stats.underruns, 0, "underruns at 1x");
    assert!(p99 < 2.0, "smoothed clock error p99 {p99} ms");
    assert_eq!(backwards, 0, "clock ran backwards");
}
