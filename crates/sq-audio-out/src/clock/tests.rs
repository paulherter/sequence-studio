// Swift: ClockTests.swift, AudioClockTests.swift
use super::*;
use sq_core_edit::playback::PlaybackRate;
use sq_core_time::Time;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering::SeqCst};

const SR: i64 = 48_000;

fn t(v: i64, s: i64) -> Time {
    Time::new(v, s)
}

fn frames(n: i64) -> Time {
    Time::new(n, SR)
}

fn rate(n: i32) -> PlaybackRate {
    PlaybackRate::new(n, 1)
}

fn abs(x: Time) -> Time {
    if x.is_negative() { -x } else { x }
}

// MARK: ManualClock

#[test]
fn manual_starts_paused_at_zero() {
    let c = ManualClock::default();
    c.advance(t(5, 1));
    assert_eq!(c.now(), Time::ZERO);
    assert_eq!(c.rate(), PlaybackRate::ZERO);
}

#[test]
fn manual_rate_one_and_minus_one() {
    let c = ManualClock::new(t(10, 1), PlaybackRate::FORWARD);
    c.advance(t(1001, 30000));
    assert_eq!(c.now(), t(10, 1) + t(1001, 30000));
    let c = ManualClock::new(t(10, 1), PlaybackRate::REVERSE);
    c.advance(t(1001, 30000));
    assert_eq!(c.now(), t(10, 1) - t(1001, 30000));
    c.advance(t(20, 1));
    assert_eq!(c.now(), t(-10, 1) - t(1001, 30000));
}

#[test]
fn manual_rate_quarter_and_eight() {
    let c = ManualClock::new(Time::ZERO, PlaybackRate::new(1, 4));
    c.advance(t(1, 1));
    assert_eq!(c.now(), t(1, 4));
    c.advance(t(1, 3));
    assert_eq!(c.now(), t(1, 4) + t(1, 12));
    let c = ManualClock::new(t(1, 1), rate(8));
    c.advance(t(1001, 24000));
    assert_eq!(c.now(), t(1, 1) + t(1001, 3000));
}

#[test]
fn manual_rate_change_keeps_position_continuous() {
    let c = ManualClock::new(Time::ZERO, PlaybackRate::FORWARD);
    c.advance(t(2, 1));
    let before = c.now();
    c.set_rate(PlaybackRate::new(1, 4));
    assert_eq!(c.now(), before);
    c.advance(t(4, 1));
    assert_eq!(c.now(), t(3, 1));
    c.set_rate(PlaybackRate::REVERSE);
    c.advance(t(1, 2));
    assert_eq!(c.now(), t(5, 2));
}

#[test]
fn manual_seek_stop_start_and_zero_rate() {
    let c = ManualClock::new(Time::ZERO, rate(8));
    c.advance(t(1, 1));
    c.seek(t(100, 1));
    assert_eq!(c.now(), t(100, 1));
    assert_eq!(c.rate(), rate(8));
    c.advance(t(1, 8));
    assert_eq!(c.now(), t(101, 1));

    let c = ManualClock::new(Time::ZERO, PlaybackRate::FORWARD);
    c.advance(t(3, 2));
    assert_eq!(c.stop(), t(3, 2));
    c.advance(t(10, 1));
    assert_eq!(c.now(), t(3, 2));
    assert!(c.rate().is_paused());

    let c = ManualClock::default();
    c.advance(t(7, 1));
    c.start(t(2, 1), PlaybackRate::FORWARD);
    c.advance(t(1, 1));
    assert_eq!(c.now(), t(3, 1));

    let c = ManualClock::new(t(4, 1), PlaybackRate::ZERO);
    c.advance(t(9, 1));
    assert_eq!(c.now(), t(4, 1));
}

// MARK: HostClock

fn fake() -> (Arc<AtomicI64>, HostClock) {
    let ns = Arc::new(AtomicI64::new(0));
    let src = Arc::clone(&ns);
    (ns, HostClock::with_source(Arc::new(move || src.load(SeqCst))))
}

#[test]
fn host_one_second_matches_an_independent_wall_measurement() {
    let c = HostClock::new();
    let w0 = std::time::Instant::now();
    c.start(Time::ZERO, PlaybackRate::FORWARD);
    std::thread::sleep(std::time::Duration::from_secs(1));
    let pos = c.now();
    let wall = w0.elapsed().as_nanos() as i128;
    let pos_ns = i128::from(pos.value()) * 1_000_000_000 / i128::from(pos.timescale());
    assert!(pos_ns >= 1_000_000_000 - 5_000_000);
    assert!((pos_ns - wall).abs() < 5_000_000, "clock {pos_ns} ns vs wall {wall} ns");
}

#[test]
fn host_rate_change_continuous_with_fake_source() {
    let (ns, c) = fake();
    c.start(t(10, 1), PlaybackRate::FORWARD);
    ns.fetch_add(1_500_000_000, SeqCst);
    assert_eq!(c.now(), t(23, 2));
    c.set_rate(PlaybackRate::new(1, 4));
    assert_eq!(c.now(), t(23, 2));
    ns.fetch_add(4_000_000_000, SeqCst);
    assert_eq!(c.now(), t(25, 2));
    c.set_rate(rate(-8));
    ns.fetch_add(500_000_000, SeqCst);
    assert_eq!(c.now(), t(17, 2));
    assert_eq!(c.stop(), t(17, 2));
    ns.fetch_add(1_000_000_000, SeqCst);
    assert_eq!(c.now(), t(17, 2));
}

#[test]
fn host_rate_change_rounds_only_the_elapsed_delta() {
    let (ns, c) = fake();
    c.start(Time::ZERO, PlaybackRate::new(1, 3));
    ns.fetch_add(1_000, SeqCst); // 1000/3 ns = 333.33 ns
    c.set_rate(PlaybackRate::FORWARD);
    assert_eq!(c.now(), t(333, 1_000_000_000));
}

#[test]
fn host_seek_stop_and_pause_keep_exact_positions() {
    let p = t(1001, 30000) * 2;
    let (_ns, c) = fake();
    c.start(Time::ZERO, PlaybackRate::FORWARD);
    c.seek(p);
    assert_eq!(c.stop(), p);
    assert_eq!(c.now(), p);

    let (_ns, c) = fake();
    c.start(Time::ZERO, PlaybackRate::FORWARD);
    c.seek(p);
    c.set_rate(PlaybackRate::new(1, 4));
    assert_eq!(c.now(), p);

    let (ns, c) = fake();
    c.start(p, PlaybackRate::ZERO);
    ns.fetch_add(987_654_321, SeqCst);
    c.set_rate(PlaybackRate::ZERO);
    assert_eq!(c.stop(), p);

    let (_ns, c) = fake();
    let fd = t(1001, 30000);
    c.start(fd * 2, PlaybackRate::FORWARD);
    assert_eq!(c.stop().frame_index(fd), 2);

    let (ns, c) = fake();
    c.start(Time::ZERO, PlaybackRate::FORWARD);
    ns.fetch_add(123, SeqCst);
    c.seek(t(1001, 30000));
    assert_eq!(c.now(), t(1001, 30000));
    assert_eq!(c.rate(), PlaybackRate::FORWARD);
}

#[test]
fn clocks_are_send_and_sync() {
    fn req<T: Send + Sync>() {}
    req::<HostClock>();
    req::<ManualClock>();
    req::<AudioClock>();
    req::<SwitchingClock>();
}

// MARK: AudioClock

fn pair() -> (Arc<ManualAudio>, Arc<AudioClock>) {
    let audio = Arc::new(ManualAudio::new());
    let clock = AudioClock::new(Arc::clone(&audio) as Arc<dyn AudioPlaying>);
    (audio, clock)
}

fn pair_with(latency: i64, out: Time, tp: Time, auto: bool) -> (Arc<ManualAudio>, Arc<AudioClock>) {
    let audio = Arc::new(ManualAudio::with(latency, out, tp, auto));
    let clock = AudioClock::new(Arc::clone(&audio) as Arc<dyn AudioPlaying>);
    (audio, clock)
}

#[test]
fn holds_at_anchor_until_the_flush_is_acknowledged_then_rebases_exactly() {
    let (audio, clock) = pair_with(0, Time::ZERO, Time::ZERO, false);
    audio.start();
    audio.render(1000); // audio that played before (old position)
    clock.start(t(10, 1), PlaybackRate::FORWARD);
    assert!(audio.last_seek() == Some(t(10, 1)) && audio.is_playing());
    assert_eq!(clock.now(), t(10, 1));
    audio.render(480); // old tail still consumed: feeder has not flushed yet
    assert_eq!(clock.now(), t(10, 1));
    audio.apply_flush(); // flush issued, consumer has not applied it
    assert_eq!(clock.now(), t(10, 1));
    audio.render(480); // consumer applies the flush at consumed = 1480
    assert_eq!(audio.consumed_at_epoch().1, 1480);
    assert_eq!(clock.now(), t(10, 1) + frames(480));
    audio.render(7);
    assert_eq!(clock.now(), t(10, 1) + frames(487));
}

#[test]
fn subtracts_feeder_latency_and_scaled_output_latency() {
    let (audio, clock) = pair_with(480, frames(240), Time::ZERO, true);
    clock.start(t(5, 1), rate(2));
    audio.render(900); // < M + 2 x 240 = 960: nothing audible yet
    assert_eq!(clock.now(), t(5, 1));
    audio.render(100); // 1000 - 480 - 480 = 40 timeline frames heard
    assert_eq!(clock.now(), t(5, 1) + frames(40));
}

#[test]
fn reverse_runs_backwards_with_latency_never_added() {
    let (audio, clock) = pair_with(480, frames(100), Time::ZERO, true);
    clock.start(t(5, 1), PlaybackRate::REVERSE);
    audio.render(580);
    assert_eq!(clock.now(), t(5, 1));
    audio.render(48_000);
    assert_eq!(clock.now(), t(4, 1));
    assert!(clock.rate() == PlaybackRate::REVERSE && audio.current_rate() == PlaybackRate::REVERSE);
}

#[test]
fn stop_holds_and_seek_while_paused_only_reanchors() {
    let (audio, clock) = pair();
    clock.start(Time::ZERO, PlaybackRate::FORWARD);
    audio.render(4800);
    assert_eq!(clock.stop(), frames(4800));
    assert!(!audio.is_playing() && clock.rate() == PlaybackRate::ZERO);
    audio.render(4800); // not playing: nothing consumed
    assert_eq!(clock.now(), frames(4800));
    let seeks = audio.flushed().generation;
    clock.seek(t(3, 1));
    assert!(clock.now() == t(3, 1) && audio.flushed().generation == seeks); // no restart while paused
    clock.start(clock.now(), PlaybackRate::FORWARD);
    audio.render(48);
    assert_eq!(clock.now(), t(3, 1) + frames(48));
}

#[test]
fn rate_change_and_seek_reanchor_at_the_current_position() {
    let (audio, clock) = pair();
    clock.start(Time::ZERO, PlaybackRate::FORWARD);
    audio.render(48_000);
    clock.set_rate(rate(2));
    assert!(audio.last_seek() == Some(t(1, 1)) && audio.current_rate() == rate(2));
    assert_eq!(clock.now(), t(1, 1));
    audio.render(96_000); // two timeline seconds at 2x
    assert_eq!(clock.now(), t(3, 1));
    clock.seek(t(20, 1));
    assert!(clock.now() == t(20, 1) && clock.rate() == rate(2));
    audio.render(480);
    assert_eq!(clock.now(), t(20, 1) + frames(480));
    clock.set_rate(PlaybackRate::ZERO);
    assert!(!audio.is_playing() && clock.now() == t(20, 1) + frames(480));
}

/// 10 simulated minutes per rate: the output pulls 512-frame quanta; a time stretcher consumes |rate| x 512 timeline
/// frames per quantum (exact fractional accumulator). The clock must stay within one sequence frame of the ideal audible
/// position `anchor + rate x (wall - output_latency) - M` all the way through.
#[test]
fn ten_minute_simulated_drift_stays_within_one_frame() {
    for r in [rate(1), rate(2), rate(-1), PlaybackRate::new(1, 4)] {
        let fd = t(1001, 30_000);
        let m = 480i64;
        let out_latency = frames(512);
        let (audio, clock) = pair_with(m, out_latency, Time::ZERO, true);
        let anchor = t(700, 1);
        clock.start(anchor, r);
        let mag = r.magnitude();
        let quantum = 512i64;
        let quanta = 10 * 60 * SR / quantum;
        let (mut acc, mut wall) = (0i64, 0i64);
        let mut max_error = Time::ZERO;
        for _ in 0..quanta {
            acc += quantum * i64::from(mag.num());
            let n = acc / i64::from(mag.den());
            acc %= i64::from(mag.den());
            audio.render(n);
            wall += quantum;
            let heard = scaled(frames(wall), mag) - frames(m) - scaled(out_latency, mag);
            let elapsed = heard.max(Time::ZERO);
            let ideal = if r.is_reverse() { anchor - elapsed } else { anchor + elapsed };
            max_error = max_error.max(abs(clock.now() - ideal));
        }
        assert!(max_error <= fd, "rate {r:?}: max error {max_error:?}");
        let lag = frames(m) + scaled(out_latency, mag);
        let expected = anchor + scaled(t(600, 1), r) + if r.is_reverse() { lag } else { -lag };
        assert!(abs(clock.now() - expected) <= fd);
    }
}

#[test]
fn time_pitch_latency_is_taken_at_each_rate_change() {
    let (audio, clock) = pair_with(0, frames(100), frames(1000), true);
    clock.start(Time::ZERO, PlaybackRate::FORWARD);
    audio.render(300); // 1x: stretcher bypassed, only 100 frames latency
    assert_eq!(clock.now(), frames(200));
    clock.set_rate(rate(2)); // 1100 output frames x 2 = 2200 timeline frames
    audio.render(2300);
    assert_eq!(clock.now(), frames(300));
    clock.set_rate(PlaybackRate::FORWARD);
    audio.render(150);
    assert_eq!(clock.now(), frames(350));
}

#[test]
fn restart_handler_reseeks_at_the_current_position() {
    let (audio, clock) = pair();
    clock.start(t(2, 1), PlaybackRate::FORWARD);
    audio.render(4800);
    let gen_ = audio.flushed().generation;
    audio.simulate_restart(); // e.g. output device changed
    assert!(audio.last_seek() == Some(t(2, 1) + frames(4800)) && clock.now() == t(2, 1) + frames(4800));
    audio.render(480);
    assert!(audio.flushed().generation == gen_ + 1 && clock.now() == t(2, 1) + frames(5280));
}

#[test]
fn watchdog_reports_a_stall_only_while_running() {
    let (audio, clock) = pair();
    clock.start(Time::ZERO, PlaybackRate::FORWARD);
    audio.render(480);
    audio.advance_time(200_000_000);
    assert!(!clock.sample().1);
    audio.render(480); // progress resets the watchdog
    audio.advance_time(200_000_000);
    assert!(!clock.sample().1);
    audio.advance_time(100_000_000);
    assert!(clock.sample().1);
    clock.stop();
    assert!(!clock.sample().1);
}

/// 1024-frame render calls arriving with up to +-4 ms jitter; `now()` sampled every 1 ms must be monotonic, close to the
/// ideal position (the device plays at a steady rate) and move between calls instead of in 21 ms steps.
#[test]
fn interpolates_between_jittery_render_calls() {
    for r in [rate(1), rate(-1), rate(2)] {
        let (audio, clock) = pair();
        let anchor = t(10, 1);
        clock.start(anchor, r);
        let mag = r.magnitude();
        let q = 1024i64;
        let q_nanos = q * 1_000_000_000 / SR;
        let mut seed: u64 = 0x9E37_79B9_7F4A_7C15;
        let mut jitter = || {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (seed >> 33) as i64 % 8_000_001 - 4_000_000
        };
        let (mut next_call, mut calls, mut clock_nanos) = (jitter().max(0), 0i64, 0i64);
        let (mut prev, mut increasing, mut samples) = (None::<Time>, 0, 0);
        let (mut max_err, mut max_step) = (Time::ZERO, Time::ZERO);
        for ms in 1..=3000i64 {
            let now = ms * 1_000_000;
            while next_call <= now {
                audio.advance_time(next_call - clock_nanos);
                clock_nanos = next_call;
                audio.render_with(q * i64::from(mag.num()) / i64::from(mag.den()), false);
                calls += 1;
                next_call = calls * q_nanos + jitter();
            }
            audio.advance_time(now - clock_nanos);
            clock_nanos = now;
            let p = clock.now();
            let ideal = anchor + scaled(t(now, 1_000_000_000), r);
            max_err = max_err.max(abs(p - ideal));
            if let Some(prev) = prev {
                let d = if r.is_reverse() { prev - p } else { p - prev };
                assert!(!d.is_negative(), "clock ran backwards at {ms} ms");
                if d > Time::ZERO {
                    increasing += 1;
                }
                max_step = max_step.max(d);
                samples += 1;
            }
            prev = Some(p);
        }
        assert!(max_err <= scaled(t(10, 1000), mag), "rate {r:?}: max error {max_err:?}");
        assert!(f64::from(increasing) / f64::from(samples) > 0.8, "only {increasing} of {samples} samples moved");
        // An early call after a late one jumps by at most the jitter spread (8 ms), never by a whole 21 ms call.
        assert!(max_step <= scaled(t(9, 1000), mag), "rate {r:?}: max step {max_step:?}");
    }
}

// MARK: SwitchingClock

#[test]
fn switching_clock_hands_over_position_and_falls_back_on_a_stall() {
    let (audio, audio_clock) = pair();
    let host = Arc::new(ManualClock::default());
    let sw = SwitchingClock::new(Arc::clone(&host) as Arc<dyn PlaybackClock>, Some(Arc::clone(&audio_clock)));
    sw.start(t(1, 1), PlaybackRate::FORWARD);
    host.advance(t(1, 2));
    assert_eq!(sw.now(), t(3, 2));
    sw.use_audio(true);
    assert!(sw.is_audio());
    assert_eq!(audio.last_seek(), Some(t(3, 2)));
    audio.render(4800);
    assert_eq!(sw.now(), t(3, 2) + frames(4800));
    // The audio stops delivering: after the watchdog limit the host clock takes over at the audio position.
    audio.advance_time(2_100_000_000);
    let at = sw.now();
    assert!(!sw.is_audio() && sw.audio_failed());
    assert_eq!(host.now(), at);
    assert_eq!(sw.rate(), PlaybackRate::FORWARD);
    sw.clear_audio_failure();
    assert!(!sw.audio_failed());
}

#[test]
fn the_next_play_after_a_stall_returns_to_the_audio_clock() {
    let (audio, audio_clock) = pair();
    let host = Arc::new(ManualClock::default());
    let sw = SwitchingClock::new(Arc::clone(&host) as Arc<dyn PlaybackClock>, Some(Arc::clone(&audio_clock)));
    sw.use_audio(true);
    sw.start(t(1, 1), PlaybackRate::FORWARD);
    audio.render(4800);
    audio.advance_time(2_100_000_000);
    let _ = sw.now();
    assert!(!sw.is_audio() && sw.audio_failed(), "the stall falls back to the host clock");
    let paused_at = sw.stop();
    sw.start(paused_at, PlaybackRate::FORWARD);
    assert!(sw.is_audio() && !sw.audio_failed(), "Play brings the sound back");
    assert_eq!(audio.last_seek(), Some(paused_at));
    assert!(host.rate().is_paused(), "the host clock no longer runs");
}

// MARK: StampSmoother

/// The Windows pattern from g6: callbacks nominally every 10 ms arrive 8/12 ms apart, with a 12 ms spike now and then.
#[test]
fn smoother_removes_callback_jitter_and_never_goes_backwards() {
    let mut s = StampSmoother::new(48_000, 0.3);
    let period = 10_000_000i64; // 480 frames
    let mut raw_err = Vec::new();
    let mut flt_err = Vec::new();
    let mut last = i64::MIN;
    for i in 0..6000i64 {
        let ideal = 1_000_000_000 + i * period;
        let jitter = match i % 4 {
            0 => -2_000_000,
            1 => 2_000_000,
            2 => -1_000_000,
            _ => 1_000_000,
        } + if i % 997 == 5 { 10_000_000 } else { 0 };
        let raw = ideal + jitter;
        let out = s.filter(raw, 480);
        assert!(out >= last, "smoothed stamp went backwards at {i}");
        last = out;
        if i > 1000 {
            raw_err.push((raw - ideal).abs());
            flt_err.push((out - ideal).abs());
        }
    }
    raw_err.sort_unstable();
    flt_err.sort_unstable();
    let p99 = |v: &[i64]| v[v.len() * 99 / 100];
    assert!(p99(&flt_err) < 1_000_000, "smoothed p99 {} ns", p99(&flt_err));
    assert!(p99(&flt_err) < p99(&raw_err));
}

#[test]
fn smoother_reseeds_after_a_gap_and_tracks_a_fast_device_clock() {
    let mut s = StampSmoother::new(48_000, 0.3);
    assert_eq!(s.filter(5_000_000_000, 480), 5_000_000_000);
    // paused for 3 s: next stamp is taken as is
    assert_eq!(s.filter(8_000_000_000, 480), 8_000_000_000);
    // device 200 ppm fast: 480 frames take 9.998 ms of host time
    let mut raw = 8_000_000_000i64;
    let mut out = 0;
    for _ in 0..30_000 {
        raw += 9_998_000;
        out = s.filter(raw, 480);
    }
    assert!((out - raw).abs() < 200_000, "locked to within 0.2 ms, off by {}", out - raw);
}
