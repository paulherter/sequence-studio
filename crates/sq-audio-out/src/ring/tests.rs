// Swift: RingBufferTests.swift, RingFadeTests.swift
#![allow(clippy::needless_range_loop)]
use super::*;
use std::thread;

const F: usize = 240;
const NO_STALE: Duration = Duration::from_millis(100);

fn push(p: &mut RingProducer, v: &[f32]) -> usize {
    p.push(v, v)
}

fn push_const(p: &mut RingProducer, v: f32, n: usize) {
    let a = vec![v; n];
    p.push(&a, &a);
}

fn pop(c: &mut RingConsumer, n: usize) -> (Vec<f32>, Vec<f32>, usize) {
    let (mut l, mut r) = (vec![-1.0; n], vec![-1.0; n]);
    let got = c.pop(&mut l, &mut r);
    (l, r, got)
}

fn pop_l(c: &mut RingConsumer, n: usize) -> Vec<f32> {
    pop(c, n).0
}

fn g_in(k: usize) -> f32 {
    (0.5 - 0.5 * (std::f64::consts::PI * (k as f64 + 0.5) / F as f64).cos()) as f32
}

#[test]
fn wraps_around_preserving_order() {
    let (mut p, mut c) = ring(8, 0, NO_STALE);
    let mut next = 0.0f32;
    for _ in 0..10 {
        let vals: Vec<f32> = (0..5)
            .map(|_| {
                next += 1.0;
                next - 1.0
            })
            .collect();
        assert_eq!(push(&mut p, &vals), 5);
        let (l, r, got) = pop(&mut c, 5);
        assert_eq!(got, 5);
        assert_eq!(l, vals);
        assert_eq!(r, vals);
    }
    assert_eq!(c.shared().consumed_frames(), 50);
    assert_eq!(c.shared().underrun_count(), 0);
}

#[test]
fn push_is_limited_by_free_space() {
    let (mut p, mut c) = ring(4, 0, NO_STALE);
    assert_eq!(push(&mut p, &[1.0, 2.0, 3.0]), 3);
    assert_eq!(push(&mut p, &[4.0, 5.0, 6.0]), 1);
    assert_eq!(p.available_to_write(), 0);
    assert_eq!(pop_l(&mut c, 4), [1.0, 2.0, 3.0, 4.0]);
    assert_eq!(p.available_to_write(), 4);
}

#[test]
fn underrun_zero_fills_and_counts() {
    let (mut p, mut c) = ring(8, 0, NO_STALE);
    push(&mut p, &[1.0, 2.0]);
    let (l, _, got) = pop(&mut c, 4);
    assert_eq!(got, 2);
    assert_eq!(l, [1.0, 2.0, 0.0, 0.0]);
    assert_eq!(c.shared().underrun_count(), 1);
    assert_eq!(c.shared().consumed_frames(), 2);
}

#[test]
fn flush_drops_old_keeps_new() {
    let (mut p, mut c) = ring(16, 0, NO_STALE);
    push(&mut p, &[1.0, 2.0, 3.0, 4.0]);
    p.flush();
    push(&mut p, &[9.0, 8.0]);
    assert_eq!(pop_l(&mut c, 2), [9.0, 8.0]);
    assert_eq!(c.shared().consumed_frames(), 2);
}

#[test]
fn flush_while_consumer_is_paused_frees_the_whole_ring() {
    let (mut p, c) = ring(8, 0, NO_STALE);
    push_const(&mut p, 1.0, 8);
    assert_eq!(p.available_to_write(), 0);
    p.flush();
    assert_eq!(p.available_to_write(), 8);
    assert_eq!(c.shared().available_to_read(), 0);
}

#[test]
fn spsc_threads_deliver_every_frame_in_order() {
    let (mut p, mut c) = ring(64, 0, NO_STALE);
    let total = 200_000usize;
    let producer = thread::spawn(move || {
        let mut next = 0usize;
        while next < total {
            let n = 37.min(total - next);
            let vals: Vec<f32> = (0..n).map(|i| (next + i) as f32).collect();
            let mut done = 0;
            while done < n {
                let k = p.push(&vals[done..], &vals[done..]);
                done += k;
                if k == 0 {
                    thread::yield_now();
                }
            }
            next += n;
        }
    });
    let consumer = thread::spawn(move || {
        let mut expect = 0usize;
        let (mut l, mut r) = (vec![0.0f32; 29], vec![0.0f32; 29]);
        while expect < total {
            let got = c.pop(&mut l, &mut r);
            for i in 0..got {
                if l[i] != expect as f32 || r[i] != expect as f32 {
                    return false;
                }
                expect += 1;
            }
            if got == 0 {
                thread::yield_now();
            }
        }
        true
    });
    producer.join().ok();
    assert_eq!(consumer.join().ok(), Some(true));
}

#[test]
fn flush_racing_the_pop_window_never_leaks_pre_cut_data() {
    // A flush plus new pushes land between the consumer's epoch load and its write-index load.
    let (mut p, mut c) = ring(64, 0, NO_STALE);
    push(&mut p, &[1.0, 2.0, 3.0]);
    let p = std::sync::Arc::new(std::sync::Mutex::new(p));
    let hook_p = std::sync::Arc::clone(&p);
    let mut fired = false;
    c.after_epoch_load = Some(Box::new(move || {
        if !fired {
            fired = true;
            if let Ok(mut p) = hook_p.lock() {
                p.flush();
                push(&mut p, &[7.0, 8.0]);
            }
        }
    }));
    let (l, _, got) = pop(&mut c, 2);
    assert_eq!((got, l), (2, vec![7.0, 8.0]));
}

#[test]
fn flush_returns_epoch_and_consumer_publishes_consumed_at_apply() {
    let (mut p, mut c) = ring(2048, 0, NO_STALE);
    let sh = c.shared();
    assert_eq!(sh.consumed_at_epoch().0, 0);
    push_const(&mut p, 1.0, 500);
    pop_l(&mut c, 100);
    let e = p.flush();
    assert_eq!(e, 1);
    assert_eq!(sh.consumed_at_epoch().0, 0); // consumer has not run yet
    push_const(&mut p, 1.0, 200);
    pop_l(&mut c, 50);
    assert_eq!(sh.consumed_at_epoch(), (e, 100)); // consumed_frames at the moment the flush was applied
    assert_eq!(sh.consumed_frames(), 150);
    assert_eq!(p.flush(), 2);
}

#[test]
fn coalesced_flushes_publish_latest_epoch() {
    let (mut p, mut c) = ring(2048, 0, NO_STALE);
    push_const(&mut p, 1.0, 300);
    pop_l(&mut c, 10);
    p.flush();
    let e2 = p.flush();
    push_const(&mut p, 1.0, 100);
    pop_l(&mut c, 10);
    assert_eq!(c.shared().consumed_at_epoch(), (e2, 10));
}

#[test]
fn fresh_start_fades_in_over_five_ms() {
    let (mut p, mut c) = ring(4096, F, NO_STALE);
    push_const(&mut p, 1.0, 100);
    p.flush(); // seek: nothing was playing
    push_const(&mut p, 1.0, 1000);
    let o = pop_l(&mut c, 1000);
    for k in 0..F {
        assert!((o[k] - g_in(k)).abs() < 1e-6, "k={k}");
    }
    assert!(o[..F].windows(2).all(|w| w[1] > w[0]));
    assert!(o[0] < 0.001 && o[F - 1] > 0.999);
    assert!(o[F..].iter().all(|&v| v == 1.0));
}

#[test]
fn flush_during_playback_crossfades_old_tail_out() {
    let (mut p, mut c) = ring(4096, F, NO_STALE);
    push_const(&mut p, 1.0, 1000);
    pop_l(&mut c, 100); // playing; 900 old frames still queued
    p.flush();
    push_const(&mut p, 0.0, 1000); // new material is silent: output = fade-out envelope of the old tail
    let o = pop_l(&mut c, 400);
    for k in 0..F {
        assert!((o[k] - (1.0 - g_in(k))).abs() < 1e-6, "k={k}");
    }
    assert!(o[..F].windows(2).all(|w| w[1] < w[0]));
    assert!(o[F..].iter().all(|&v| v == 0.0));
    assert_eq!(c.shared().consumed_frames(), 500); // the old tail is not counted: clock re-bases exactly
}

#[test]
fn same_signal_across_flush_stays_at_unity() {
    let (mut p, mut c) = ring(4096, F, NO_STALE);
    push_const(&mut p, 1.0, 1000);
    pop_l(&mut c, 100);
    p.flush();
    push_const(&mut p, 1.0, 1000);
    assert!(pop_l(&mut c, 300).iter().all(|v| (v - 1.0).abs() < 1e-6));
}

#[test]
fn stale_tail_is_not_played_after_long_pause() {
    let (mut p, mut c) = ring(4096, F, Duration::from_millis(10));
    push_const(&mut p, 1.0, 1000);
    pop_l(&mut c, 100);
    thread::sleep(Duration::from_millis(60)); // consumer paused
    p.flush();
    push_const(&mut p, 0.0, 1000);
    assert!(pop_l(&mut c, 300).iter().all(|&v| v == 0.0)); // no 5 ms blip of the old material
}

#[test]
fn fade_in_advances_only_with_real_data() {
    let (mut p, mut c) = ring(4096, F, NO_STALE);
    p.flush();
    let first = pop_l(&mut c, 100); // underrun: silence, ramp must not be consumed
    assert!(first.iter().all(|&v| v == 0.0));
    push_const(&mut p, 1.0, 500);
    let o = pop_l(&mut c, 300);
    assert!((o[0] - g_in(0)).abs() < 1e-6);
}

#[test]
fn partial_first_pop_keeps_crossfade_at_unity() {
    let (mut p, mut c) = ring(4096, F, NO_STALE);
    push_const(&mut p, 1.0, 1000);
    pop_l(&mut c, 100);
    p.flush();
    push_const(&mut p, 1.0, 100);
    let (l, _, n) = pop(&mut c, 300);
    assert_eq!(n, 100);
    assert!(l[..100].iter().all(|v| (v - 1.0).abs() < 1e-6));
    push_const(&mut p, 1.0, 500);
    assert!(pop_l(&mut c, 200).iter().all(|v| (v - 1.0).abs() < 1e-6));
}
