//! Voice chain bench (dev tool, no app) to compare SQ's voice chain with Premiere's own render
//! (notes/proof/audio-premiere/result.md).
//!   dump <prproj>                                      audio clips with their effects
//!   render <prproj> <out.f32> <rawdir> <first> <last>  clips #first..=#last (raw `<i>.f32`, 48 kHz stereo f32) through
//!                                                      their chains (Audio Gain in front, Volume behind), mixed at their
//!                                                      timeline start
//!   analyze <a.f32> <b.f32> [from_s to_s]              1/3-octave band levels of the speech-active frames, crest factor
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::print_stdout, clippy::indexing_slicing, reason = "dev tool")]
#![allow(clippy::cast_precision_loss, clippy::cast_possible_truncation, clippy::cast_sign_loss, reason = "dev tool")]

use sq_audiofx::clip_audio_fxchain::ClipAudioFXChain;
use sq_core_audio::audio_effects::ClipAudioChainExt;
use sq_core_model::{Clip, TrackKind};
use sq_core_time::{SequentialIds, Time};
use sq_premiere_import::prdocument::PRReader;
use sq_premiere_import::prmapper::PRMapper;
use std::collections::BTreeMap;

fn secs(t: Time) -> f64 {
    t.value() as f64 / t.timescale() as f64
}

fn run_chain(c: &Clip, samples: &[f32]) -> Vec<f32> {
    let n = samples.len() / 2;
    let mut chain = ClipAudioFXChain::new(c.audio_fx_layout(), 2, 1024, None).unwrap();
    let lat = chain.latency_samples;
    let gain = 10f32.powf(c.audio_gain_db as f32 / 20.0);
    let vol = c.animation.volume.value as f32;
    let scalar = |e: &sq_core_model::ClipEffect, k: &str, at: Time| e.scalar(k, at);
    let mut out = Vec::with_capacity((n + lat) * 2);
    let mut pos = 0;
    while pos < n + lat {
        let len = 1024.min(n + lat - pos);
        let mut buf = vec![vec![0f32; len]; 2];
        for i in 0..len {
            if pos + i < n {
                for (ch, b) in buf.iter_mut().enumerate() {
                    b[i] = samples[(pos + i) * 2 + ch] * gain;
                }
            }
        }
        let s0 = c.audio_fx_steps(Time::new(pos as i64, 48_000), &scalar);
        let s1 = c.audio_fx_steps(Time::new((pos + len) as i64, 48_000), &scalar);
        chain.process_vecs(&mut buf, &s0, Some(&s1));
        for (l, r) in buf[0].iter().zip(buf[1].iter()).take(len) {
            out.push(l * vol);
            out.push(r * vol);
        }
        pos += len;
    }
    out.split_off(lat * 2)
}

/// `SQ_VARIANT` (comma list) edits a clip's chain for experiments: nonr, nomb, nolim, nopeq, drive=<dB>, limatk=<ms>,
/// limrel=<ms>, nr=<percent>.
fn variant(c: &mut Clip) {
    let v = std::env::var("SQ_VARIANT").unwrap_or_default();
    for f in v.split(',').filter(|f| !f.is_empty()) {
        let (k, val) = f.split_once('=').map_or((f, 0.0), |(k, x)| (k, x.parse::<f64>().unwrap()));
        for e in &mut c.effects {
            let margin = e.parameters.get("limMargin").map_or(0.0, |p| p.value);
            let mut set = |key: &str, x: f64| {
                if let Some(p) = e.parameters.get_mut(key) {
                    p.value = x;
                    p.track.keys.clear();
                }
            };
            match (k, e.kind.as_str()) {
                ("nonr", "audio.noiseReduction") | ("nomb", "audio.multiband") | ("nopeq", "audio.parametricEQ") => {
                    e.enabled = false;
                }
                ("nolim", "audio.multiband") => set("limOn", 0.0),
                ("drive", "audio.multiband") => {
                    set("limThr", margin - val);
                }
                ("margin", "audio.multiband") => set("limMargin", val),
                ("limatk", "audio.multiband") => set("limAtk", val),
                ("limrel", "audio.multiband") => set("limRel", val),
                ("nr", "audio.noiseReduction") => set("amount", val * 100.0),
                _ => {}
            }
        }
    }
}

fn read_f32(p: &str) -> Vec<f32> {
    let raw = std::fs::read(p).unwrap();
    raw.as_chunks::<4>().0.iter().map(|b| f32::from_le_bytes(*b)).collect()
}

fn fft(re: &mut [f64], im: &mut [f64]) {
    let n = re.len();
    let mut j = 0;
    for i in 1..n {
        let mut bit = n >> 1;
        while j & bit != 0 {
            j ^= bit;
            bit >>= 1;
        }
        j ^= bit;
        if i < j {
            re.swap(i, j);
            im.swap(i, j);
        }
    }
    let mut len = 2;
    while len <= n {
        let ang = -2.0 * std::f64::consts::PI / len as f64;
        for s in (0..n).step_by(len) {
            for k in 0..len / 2 {
                let (wr, wi) = ((ang * k as f64).cos(), (ang * k as f64).sin());
                let (a, b) = (s + k, s + k + len / 2);
                let (tr, ti) = (re[b] * wr - im[b] * wi, re[b] * wi + im[b] * wr);
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
            }
        }
        len <<= 1;
    }
}

/// Mean power spectrum (dB per 1/3 octave) of frames louder than -45 dBFS RMS, plus crest factor of those frames.
fn bands(x: &[f32]) -> (Vec<(f64, f64)>, f64, f64) {
    const N: usize = 8192;
    let mono: Vec<f64> = x.as_chunks::<2>().0.iter().map(|c| f64::from(c[0] + c[1]) * 0.5).collect();
    let mut acc = vec![0f64; N / 2];
    let (mut frames, mut sumsq, mut peak, mut cnt) = (0usize, 0f64, 0f64, 0usize);
    let win: Vec<f64> = (0..N).map(|i| 0.5 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / N as f64).cos()).collect();
    for f in mono.as_chunks::<{ N / 2 }>().0.iter().collect::<Vec<_>>().windows(2) {
        let fr: Vec<f64> = f[0].iter().chain(f[1].iter()).copied().collect();
        let rms = (fr.iter().map(|v| v * v).sum::<f64>() / N as f64).sqrt();
        if rms < 10f64.powf(-45.0 / 20.0) {
            continue;
        }
        frames += 1;
        sumsq += fr.iter().map(|v| v * v).sum::<f64>();
        cnt += N;
        peak = fr.iter().fold(peak, |m, v| m.max(v.abs()));
        let mut re: Vec<f64> = fr.iter().zip(&win).map(|(a, w)| a * w).collect();
        let mut im = vec![0f64; N];
        fft(&mut re, &mut im);
        for k in 0..N / 2 {
            acc[k] += re[k] * re[k] + im[k] * im[k];
        }
    }
    let mut out = Vec::new();
    for n in -13..=13 {
        let fc = 1000.0 * 2f64.powf(f64::from(n) / 3.0);
        let (lo, hi) = (fc / 2f64.powf(1.0 / 6.0), fc * 2f64.powf(1.0 / 6.0));
        let (kl, kh) = ((lo / 48_000.0 * N as f64) as usize, ((hi / 48_000.0 * N as f64) as usize).min(N / 2));
        let p: f64 = acc[kl..kh.max(kl + 1)].iter().sum::<f64>() / frames.max(1) as f64;
        out.push((fc, 10.0 * (p / (N as f64 * N as f64 / 4.0 * 0.375)).max(1e-20).log10()));
    }
    let rms = (sumsq / cnt.max(1) as f64).sqrt();
    (out, 20.0 * (peak / rms.max(1e-12)).log10(), 20.0 * rms.max(1e-12).log10())
}

/// Mean 1/3-octave levels over the quietest frames of the reference `y` (pauses: the lowest 20 % by RMS above -85 dBFS),
/// the same frames in `x`. Returns (band, x dB, y dB) and the frame RMS of both in dBFS.
fn pause_bands(x: &[f32], y: &[f32]) -> (Vec<(f64, f64, f64)>, f64, f64) {
    const N: usize = 8192;
    let mono = |v: &[f32]| -> Vec<f64> { v.as_chunks::<2>().0.iter().map(|c| f64::from(c[0] + c[1]) * 0.5).collect() };
    let (mx, my) = (mono(x), mono(y));
    let n = mx.len().min(my.len()) / N * N;
    let rms = |f: &[f64]| (f.iter().map(|v| v * v).sum::<f64>() / f.len() as f64).sqrt();
    let mut lv: Vec<(f64, usize)> = (0..n / N)
        .map(|i| (20.0 * rms(&my[i * N..(i + 1) * N]).max(1e-12).log10(), i))
        .filter(|(l, _)| *l > -85.0)
        .collect();
    lv.sort_by(|a, b| a.0.total_cmp(&b.0));
    let pick: Vec<usize> = lv.iter().take(lv.len() / 5).map(|v| v.1).collect();
    let win: Vec<f64> = (0..N).map(|i| 0.5 - 0.5 * (2.0 * std::f64::consts::PI * i as f64 / N as f64).cos()).collect();
    let spec = |m: &[f64]| -> Vec<f64> {
        let mut acc = vec![0f64; N / 2];
        for &i in &pick {
            let mut re: Vec<f64> = m[i * N..(i + 1) * N].iter().zip(&win).map(|(a, w)| a * w).collect();
            let mut im = vec![0f64; N];
            fft(&mut re, &mut im);
            for k in 0..N / 2 {
                acc[k] += re[k] * re[k] + im[k] * im[k];
            }
        }
        acc
    };
    let (ax, ay) = (spec(&mx), spec(&my));
    let mut out = Vec::new();
    for k3 in -13..=13 {
        let fc = 1000.0 * 2f64.powf(f64::from(k3) / 3.0);
        let (lo, hi) = (fc / 2f64.powf(1.0 / 6.0), fc * 2f64.powf(1.0 / 6.0));
        let (kl, kh) = ((lo / 48_000.0 * N as f64) as usize, ((hi / 48_000.0 * N as f64) as usize).min(N / 2));
        let db = |a: &[f64]| {
            10.0 * (a[kl..kh.max(kl + 1)].iter().sum::<f64>()
                / pick.len().max(1) as f64
                / (N as f64 * N as f64 / 4.0 * 0.375))
                .max(1e-20)
                .log10()
        };
        out.push((fc, db(&ax), db(&ay)));
    }
    let tot = |m: &[f64]| {
        20.0 * rms(&pick.iter().flat_map(|&i| m[i * N..(i + 1) * N].to_vec()).collect::<Vec<_>>()).max(1e-12).log10()
    };
    (out, tot(&mx), tot(&my))
}

fn analyze(a: &[String]) {
    let rate = 48_000.0;
    let cut = |x: Vec<f32>| -> Vec<f32> {
        if a.len() >= 5 {
            let (f, t) = (a[3].parse::<f64>().unwrap(), a[4].parse::<f64>().unwrap());
            let (i, j) = ((f * rate) as usize * 2, (((t * rate) as usize) * 2).min(x.len()));
            x[i..j].to_vec()
        } else {
            x
        }
    };
    let (x, y) = (cut(read_f32(&a[1])), cut(read_f32(&a[2])));
    let env = |v: &[f32]| -> Vec<f64> {
        v.as_chunks::<96>().0.iter().map(|c| c.iter().map(|s| f64::from(s.abs())).sum::<f64>() / 96.0).collect()
    };
    let (ex, ey) = (env(&x), env(&y));
    let (mut best, mut lag) = (f64::MIN, 0i64);
    for l in -1000i64..=1000 {
        let mut sum = 0.0;
        for (i, v) in ex.iter().enumerate() {
            if let Some(w) = ey.get((i as i64 + l).max(0) as usize) {
                sum += v * w;
            }
        }
        if sum > best {
            best = sum;
            lag = l;
        }
    }
    println!("envelope lag B vs A: {} ms (1 ms steps at 2 ms envelope)", lag * 2);
    let (bx, cx, rx) = bands(&x);
    let (by, cy, ry) = bands(&y);
    let pk = |v: &[f32]| 20.0 * v.iter().fold(0f32, |m, s| m.max(s.abs())).max(1e-9).log10();
    println!("sample peak A {:.2} dBFS, B {:.2} dBFS", pk(&x), pk(&y));
    println!("A: active-frame rms {rx:.1} dBFS, crest {cx:.1} dB   B: rms {ry:.1} dBFS, crest {cy:.1} dB");
    println!("band_hz   A_dB    B_dB   A-B");
    for (p, q) in bx.iter().zip(&by) {
        println!("{:7.0} {:7.1} {:7.1} {:6.1}", p.0, p.1, q.1, p.1 - q.1);
    }
    let (pb, ra, rb) = pause_bands(&x, &y);
    println!("pauses (quietest 20 % frames of B): A rms {ra:.1} dBFS, B rms {rb:.1} dBFS");
    println!("pband_hz  A_dB    B_dB   A-B");
    for p in &pb {
        println!("p{:<6.0} {:7.1} {:7.1} {:6.1}", p.0, p.1, p.2, p.1 - p.2);
    }
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a[1] == "analyze" {
        analyze(&a[1..]);
        return;
    }
    let data = std::fs::read(&a[2]).unwrap();
    let r = PRMapper::map(&PRReader::read(&data).unwrap(), "T", &BTreeMap::new(), false, &mut SequentialIds::default());
    let mut clips = Vec::new();
    for t in r.project.timelines.iter() {
        for tr in t.tracks.iter().filter(|tr| tr.kind == TrackKind::Audio) {
            for c in tr.clips() {
                if c.has_audio_effects() {
                    clips.push((t.name.clone(), c.clone()));
                }
            }
        }
    }
    if a[1] == "dump" {
        for (i, (tn, c)) in clips.iter().enumerate() {
            let m = r.project.media.iter().find(|m| m.id == c.media).map(|m| m.path.clone());
            println!(
                "#{i} seq={tn} clip={} media={:?} start={:.3} src_in={:.3} dur={:.3} gain_db={} vol={}",
                c.name,
                m,
                secs(c.start),
                secs(c.source.start),
                secs(c.source.duration),
                c.audio_gain_db,
                c.animation.volume.value
            );
            for e in &c.effects {
                let p: BTreeMap<_, _> = e.parameters.iter().map(|(k, v)| (k.clone(), v.value)).collect();
                println!("   {} enabled={} {:?}", e.kind, e.enabled, p);
            }
        }
        return;
    }
    // render
    let (first, last) = (a[5].parse::<usize>().unwrap(), a[6].parse::<usize>().unwrap());
    let mut mix = vec![0f32; 90 * 48_000 * 2];
    for (i, entry) in clips.iter().enumerate().take(last + 1).skip(first) {
        let mut clip = entry.1.clone();
        variant(&mut clip);
        let out = run_chain(&clip, &read_f32(&format!("{}/{i}.f32", a[4])));
        let pk = out.iter().fold(0f32, |m, s| m.max(s.abs()));
        eprintln!(
            "clip #{i} peak {:.2} dBFS effects {:?}",
            20.0 * pk.max(1e-9).log10(),
            clip.effects.iter().map(|e| e.kind.as_str()).collect::<Vec<_>>()
        );
        let at = (secs(clips[i].1.start) * 48_000.0).round() as usize * 2;
        for (k, v) in out.iter().enumerate() {
            if let Some(m) = mix.get_mut(at + k) {
                *m += v;
            }
        }
    }
    let bytes: Vec<u8> = mix.iter().flat_map(|f| f.to_le_bytes()).collect();
    std::fs::write(&a[3], bytes).unwrap();
}
