//! Microbenchmark: 200 undo snapshots of a 50 x 500 clip project, plain `Vec` deep clones vs `CowVec` sharing.
//! Run: `cargo test -p sq-core-model --release -- --ignored cow_bench --nocapture`.
use sq_core_model::prelude::*;
use std::mem::size_of;
use std::time::Instant;

const TRACKS: usize = 50;
const CLIPS: usize = 500;
const STEPS: usize = 200;

fn clip(n: u128, start: i64) -> Clip {
    Clip::new(
        Id::from_u128(n),
        "c",
        Id::from_u128(1),
        TrackKind::Video,
        TimeRange::new(Time::ZERO, Time::new(20, 30)),
        Time::new(start, 30),
    )
}

fn lane(t: usize) -> Vec<Clip> {
    (0..CLIPS).map(|i| clip((t * CLIPS + i) as u128 + 10, i as i64 * 30)).collect()
}

#[test]
#[ignore = "benchmark"]
fn cow_bench() {
    let lanes: Vec<Vec<Clip>> = (0..TRACKS).map(lane).collect();

    // Plain Vec: every snapshot deep-copies every clip.
    let started = Instant::now();
    let mut plain = lanes.clone();
    let mut history: Vec<Vec<Vec<Clip>>> = Vec::new();
    for step in 0..STEPS {
        history.push(plain.clone());
        plain[step % TRACKS][step % CLIPS].start += Time::new(1, 30);
    }
    let plain_time = started.elapsed();
    let plain_bytes = STEPS * TRACKS * CLIPS * size_of::<Clip>();

    // CowVec: a snapshot copies pointers; an edit copies the changed track only.
    let mut ids = 0_u128;
    let mut tracks: sq_core_model::CowVec<Track> = lanes
        .into_iter()
        .map(|cs| {
            ids += 1;
            let mut t = Track::new(Id::from_u128(ids), TrackKind::Video);
            t.set_clips(cs);
            t
        })
        .collect();
    let started = Instant::now();
    let mut snapshots = Vec::new();
    for step in 0..STEPS {
        snapshots.push(tracks.clone());
        let mut c = tracks[step % TRACKS].clips()[step % CLIPS].clone();
        c.start += Time::new(1, 30);
        tracks[step % TRACKS].replace(c);
    }
    let cow_time = started.elapsed();
    let cow_bytes = STEPS * (TRACKS * size_of::<Track>() + CLIPS * size_of::<Clip>());

    println!("plain Vec: {plain_time:?}, about {} MiB shallow", plain_bytes >> 20);
    println!("CowVec:    {cow_time:?}, about {} MiB shallow", cow_bytes >> 20);
    assert!(cow_time < plain_time);
    drop(history);
}
