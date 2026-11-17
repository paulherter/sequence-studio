//! Mascot numbers recorded from the frozen Swift code (`oracle/sq-uikit/run-mascot.sh`): the random generator exactly, the
//! easings and the per-animation player traces within 1e-9 (libm may differ in the last bits).

use sq_uikit::sqmascot_model::{SQMascotAnim, SQMascotEase, SQMascotKey, SQMascotLibrary};
use sq_uikit::sqmascot_player::{SQMascotPlayer, SQMascotRandom};

const GOLDEN: &str = include_str!("../../../oracle/sq-uikit/golden/mascot.tsv");

fn bits(hex: &str) -> f64 {
    f64::from_bits(u64::from_str_radix(hex, 16).unwrap_or(0))
}

fn close(got: f64, want: f64, what: &str) {
    assert!((got - want).abs() <= 1e-9, "{what}: got {got}, want {want}");
}

fn records(kind: &str) -> impl Iterator<Item = Vec<&'static str>> + use<'_> {
    GOLDEN
        .lines()
        .filter(|l| !l.starts_with('#'))
        .map(|l| l.split('\t').collect::<Vec<_>>())
        .filter(move |f| f.first() == Some(&kind))
}

#[test]
fn random_generator_matches_swift_exactly() {
    let mut n = 0;
    for f in records("rng") {
        let seed: u64 = f[1].parse().unwrap_or(0);
        let index: usize = f[2].parse().unwrap_or(0);
        let mut r = SQMascotRandom::new(seed);
        let mut v = 0.0;
        for _ in 0..=index {
            v = r.next();
        }
        assert_eq!(v.to_bits(), bits(f[3]).to_bits(), "seed {seed} index {index}");
        n += 1;
    }
    assert_eq!(n, 18);
}

#[test]
fn easings_match_swift() {
    let mut n = 0;
    for f in records("ease") {
        let ease = SQMascotEase::from_raw(f[1]).unwrap_or(SQMascotEase::Lin);
        close(ease.value(bits(f[2])), bits(f[3]), &format!("{} at {}", f[1], bits(f[2])));
        n += 1;
    }
    assert_eq!(n, 42);
}

#[test]
fn player_traces_match_swift() {
    let lib = SQMascotLibrary::shared();
    let mut n = 0;
    for a in SQMascotAnim::ALL {
        let mut p = SQMascotPlayer::new(lib.animation(a).clone(), lib.idle.clone(), 7, None);
        p.start();
        let rows: Vec<Vec<&str>> = records("trace").filter(|f| f[1] == a.raw_value()).collect();
        let mut frame = 0;
        let mut pose = p.pose().clone();
        for row in &rows {
            let target: i64 = row[3].parse().unwrap_or(0);
            while frame < target {
                pose = p.advance(16.7);
                frame += 1;
            }
            let at = format!("{} frame {frame}", a.raw_value());
            assert_eq!(p.resting().to_string(), row[4], "{at} resting");
            assert_eq!(p.blink_count().to_string(), row[5], "{at} blink count");
            assert_eq!(p.is_busy().to_string(), row[6], "{at} busy");
            let keys = [SQMascotKey::Tx, SQMascotKey::Sy, SQMascotKey::Sx, SQMascotKey::Rot];
            for (i, k) in keys.iter().enumerate() {
                close(pose[*k], bits(row[7 + i]), &format!("{at} {k:?}"));
            }
            close(pose.blink, bits(row[11]), &format!("{at} blink"));
            close(pose[SQMascotKey::Esp], bits(row[12]), &format!("{at} esp"));
            close(pose[SQMascotKey::Hide], bits(row[13]), &format!("{at} hide"));
            n += 1;
        }
        assert_eq!(rows.len(), 7, "{}", a.raw_value());
    }
    assert_eq!(n, 98);
}
