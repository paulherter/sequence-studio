//! `--present-check <out> <clip>`: drives the real Program engine and the app's window picture path (`playback::pump`, the
//! GPU display pass) offscreen through a scripted scrub (random walk, fast direction changes, steps inside and across GOPs)
//! and 1x / 2x / reverse playback, reads back every picture handed to the window and compares it with a ground truth: the
//! same clip decoded by the platform decoder (VideoToolbox on the Mac; `SQ_CHECK_TRUTH=software`: FFmpeg), one paused,
//! settled frame at a time, through the same compositor and display pass.
//! Reports wrong-position pictures (a picture of another frame than it claims), pictures that match no clean frame (torn,
//! mixed, garbage), time going backwards, skipped and held frames, and scrub latency. Numbers: docs/rust/PERF-NOTES.md.

use crate::play_bench::{BenchEngine, wait};
use crate::playback::{DisplayPath, pump};
use sq_app_hosts::MonitorPicture;
use sq_core_edit::playback::PlaybackRate;
use sq_core_time::Time;
use sq_gpu::gpu::Gpu;
use sq_playback::engine::handle::ProgramHandle;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};

const TICK: Duration = Duration::from_micros(16_667);
const GRID: (usize, usize) = (32, 18);

/// What the check runs: the clip's first `frames` frames are the ground truth and the scrub range.
#[derive(Clone, Debug)]
pub struct Plan {
    pub frames: i64,
    pub scrub_ticks: usize,
    /// Playback legs: rate and seconds, each from a settled start frame.
    pub play: Vec<(PlaybackRate, f64)>,
    pub seed: u64,
    /// The app's clip color (probed info, embedded camera LUT).
    pub color: bool,
    /// Every decode of the checked engine waits this long first (stand-ins on a small clip).
    pub decode_delay: Duration,
    /// The ground truth from the platform decoder (VideoToolbox on the Mac: bit-identical to what the checked engine decodes),
    /// else from FFmpeg software (pictures of another decoder differ by a little).
    pub truth_hardware: bool,
}

impl Plan {
    pub fn standard() -> Plan {
        Plan {
            frames: 330,
            scrub_ticks: 400,
            play: vec![(PlaybackRate::FORWARD, 4.0), (PlaybackRate::whole(2), 2.5), (PlaybackRate::REVERSE, 2.0)],
            seed: 0x2545_F491_4F6C_DD1D,
            color: std::env::var_os("SQ_CHECK_NO_COLOR").is_none(),
            decode_delay: Duration::ZERO,
            truth_hardware: std::env::var("SQ_CHECK_TRUTH").map_or(true, |v| v != "software"),
        }
    }
}

/// Defect counts of one run.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Counts {
    /// New pictures handed to the window.
    pub pictures: usize,
    /// Bit-identical to the ground truth of the frame they claim.
    pub exact: usize,
    /// Close to the claimed frame but not identical (reduced detail while moving).
    pub near: usize,
    /// A clean picture of another frame, while the picture says it is exact.
    pub wrong_exact: usize,
    /// A clean picture of another frame, declared a stand-in (`exact == false`).
    pub wrong_stand_in: usize,
    /// Matches no clean frame: torn, mixed or garbage.
    pub unmatched: usize,
    /// Playing: claimed positions or picture content going against the play direction.
    pub claimed_backwards: usize,
    pub content_backwards: usize,
    /// Playing: content frames jumped over, and ticks a picture stayed longer than its frame lasts.
    pub skipped: usize,
    pub held_long: usize,
    /// Scrubbing: a new picture farther from the requested frame than the one before it.
    pub moves_away: usize,
    /// Scrub holds that never showed the exact requested frame.
    pub hold_missed: usize,
}

pub struct Report {
    #[allow(dead_code)] // read by the tests; the CLI prints only `text`
    pub counts: Counts,
    pub text: String,
}

#[derive(Clone)]
struct Sig(Vec<f32>);

impl Sig {
    fn of(pixels: &[u8], w: usize, h: usize) -> Sig {
        let (gw, gh) = GRID;
        let mut sum = vec![0f64; gw * gh * 3];
        let mut n = vec![0u32; gw * gh];
        for y in (0..h).step_by(2) {
            let gy = y * gh / h;
            let row = &pixels[y * w * 4..(y + 1) * w * 4];
            for x in (0..w).step_by(2) {
                let c = gy * gw + x * gw / w;
                let p = &row[x * 4..x * 4 + 3];
                sum[c * 3] += f64::from(p[0]);
                sum[c * 3 + 1] += f64::from(p[1]);
                sum[c * 3 + 2] += f64::from(p[2]);
                n[c] += 1;
            }
        }
        Sig(sum.iter().enumerate().map(|(i, s)| (s / f64::from(n[i / 3].max(1))) as f32).collect())
    }

    /// Mean absolute difference in code values (0-255), over all cells or the cells of grid row band `band`.
    fn distance(&self, o: &Sig, band: Option<usize>) -> f32 {
        let per_row = GRID.0 * 3;
        let (a, b) = match band {
            Some(r) => (&self.0[r * per_row..(r + 1) * per_row], &o.0[r * per_row..(r + 1) * per_row]),
            None => (&self.0[..], &o.0[..]),
        };
        a.iter().zip(b).map(|(x, y)| (x - y).abs()).sum::<f32>() / a.len().max(1) as f32
    }
}

fn hash(bytes: &[u8]) -> u64 {
    let mut h = 0xcbf2_9ce4_8422_2325u64;
    for c in bytes.chunks(8) {
        let mut v = [0u8; 8];
        v[..c.len()].copy_from_slice(c);
        h = (h ^ u64::from_le_bytes(v)).wrapping_mul(0x0100_0000_01b3).rotate_left(29);
    }
    h
}

struct Glass {
    claimed: i64,
    exact: bool,
    hash: u64,
    sig: Sig,
    pixels: Vec<u8>,
    size: (usize, usize),
}

/// The window: the app's pump and display pass; every new picture read back from the texture the window samples.
struct Window {
    gpu: Arc<Gpu>,
    display: DisplayPath,
    picture: MonitorPicture,
    generation: u64,
    frame: Time,
}

impl Window {
    fn new(gpu: &Arc<Gpu>, frame: Time) -> Result<Window, String> {
        let display = DisplayPath::new(Arc::clone(gpu)).ok_or("no display pass")?;
        Ok(Window { gpu: Arc::clone(gpu), display, picture: MonitorPicture::default(), generation: 0, frame })
    }

    /// One window frame: the new picture, if the engine published one.
    fn frame(&mut self, handle: &ProgramHandle) -> Result<Option<Glass>, String> {
        let Some(shown) = pump(handle, Some(&mut self.display), None, &self.picture, &mut self.generation) else {
            return Ok(None);
        };
        if shown.frame.is_none() {
            return Ok(None);
        }
        let p = self
            .picture
            .gpu()
            .and_then(|g| g.downcast::<crate::surface::DisplayPicture>().ok())
            .ok_or("the picture did not take the GPU path")?;
        let pixels = self.gpu.read_texture(&p.texture).map_err(|e| e.to_string())?;
        let (w, h) = (p.texture.width() as usize, p.texture.height() as usize);
        Ok(Some(Glass {
            claimed: shown.position.frame_index(self.frame),
            exact: shown.exact,
            hash: hash(&pixels),
            sig: Sig::of(&pixels, w, h),
            pixels,
            size: (w, h),
        }))
    }
}

/// Ground truth: each frame decoded paused and settled.
struct Truth {
    hash: Vec<u64>,
    sig: Vec<Sig>,
    /// Per frame: below this distance a picture is that frame (a share of the distance to its neighbours).
    close: Vec<f32>,
}

impl Truth {
    fn collect(e: &BenchEngine, w: &mut Window, frames: i64) -> Result<Truth, String> {
        let (mut hash, mut sig) = (Vec::new(), Vec::new());
        for f in 0..frames {
            let g = settle(e, w, f)?;
            hash.push(g.hash);
            sig.push(g.sig);
        }
        let n = sig.len();
        let neighbour = |i: usize| -> f32 {
            let a = if i > 0 { sig[i].distance(&sig[i - 1], None) } else { f32::MAX };
            let b = if i + 1 < n { sig[i].distance(&sig[i + 1], None) } else { f32::MAX };
            a.min(b)
        };
        let close = (0..n).map(|i| (neighbour(i) * 0.4).max(0.25)).collect();
        Ok(Truth { hash, sig, close })
    }

    fn best(&self, s: &Sig, band: Option<usize>) -> (usize, f32) {
        self.sig
            .iter()
            .map(|r| s.distance(r, band))
            .enumerate()
            .min_by(|a, b| a.1.total_cmp(&b.1))
            .unwrap_or((0, f32::MAX))
    }
}

/// Seeks `e` to frame `f` paused and returns the settled exact picture.
fn settle(e: &BenchEngine, w: &mut Window, f: i64) -> Result<Glass, String> {
    let at = e.frame * f;
    e.handle.seek(at);
    wait(&e.handle, "a settled frame", |h| {
        h.latest_shown().is_some_and(|s| s.position == at && s.exact && s.frame.is_some())
    })?;
    for _ in 0..5 {
        if let Some(g) = w.frame(&e.handle)?
            && g.claimed == f
            && g.exact
        {
            return Ok(g);
        }
        if w.generation == e.handle.latest_shown().map_or(0, |s| s.generation) {
            // Taken already (the window read it before the wait ended): seek away and back.
            e.handle.seek(e.frame * if f > 0 { f - 1 } else { f + 1 });
            wait(&e.handle, "a settled neighbour", |h| h.query(|x| x.is_picture_settled()) == Some(true))?;
            let _ = w.frame(&e.handle)?;
            e.handle.seek(at);
            wait(&e.handle, "a settled frame", |h| {
                h.latest_shown().is_some_and(|s| s.position == at && s.exact && s.frame.is_some())
            })?;
        }
    }
    Err(format!("frame {f} never reached the window"))
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Class {
    Exact,
    Near,
    Wrong(i64),
    Unmatched,
}

fn classify(t: &Truth, g: &Glass) -> (Class, Option<i64>) {
    let c = g.claimed.clamp(0, t.sig.len() as i64 - 1) as usize;
    if g.claimed >= 0 && (g.claimed as usize) < t.hash.len() && t.hash[c] == g.hash {
        return (Class::Exact, Some(c as i64));
    }
    if g.sig.distance(&t.sig[c], None) <= t.close[c] {
        return (Class::Near, Some(c as i64));
    }
    if let Some(r) = t.hash.iter().position(|h| *h == g.hash) {
        return (Class::Wrong(r as i64 - c as i64), Some(r as i64));
    }
    let (r, d) = t.best(&g.sig, None);
    if d <= t.close[r] {
        return (Class::Wrong(r as i64 - c as i64), Some(r as i64));
    }
    (Class::Unmatched, None)
}

fn spread(v: &mut [f64]) -> String {
    if v.is_empty() {
        return "n/a".into();
    }
    v.sort_by(f64::total_cmp);
    let at = |q: f64| v[((v.len() - 1) as f64 * q).round() as usize];
    format!("p50 {:.1} ms, p95 {:.1} ms, max {:.1} ms", at(0.5), at(0.95), at(1.0))
}

struct Run<'a> {
    truth: &'a Truth,
    counts: Counts,
    notes: Vec<String>,
    near_notes: usize,
    /// `SQ_CHECK_DUMP=<dir>`: unmatched pictures as PNG, compared with the settled frames around them at the end.
    dump: Option<std::path::PathBuf>,
    dumped: Vec<(i64, Vec<u8>, (usize, usize))>,
}

fn write_png(path: &Path, pixels: &[u8], (w, h): (usize, usize)) {
    let image = sq_draw::RgbaImage { width: w as _, height: h as _, pixels: pixels.to_vec() };
    let _ = std::fs::write(path, crate::png::encode(&image));
}

/// Per-pixel difference of two pictures: mean, max, share of differing pixels, and the rows (in eighths) that differ.
fn pixel_diff(a: &[u8], b: &[u8], (w, h): (usize, usize)) -> String {
    let (mut sum, mut max, mut differ) = (0u64, 0u8, 0usize);
    let mut bands = [0usize; 8];
    for y in 0..h {
        for x in 0..w {
            let i = (y * w + x) * 4;
            let d = (0..3).map(|c| a[i + c].abs_diff(b[i + c])).max().unwrap_or(0);
            sum += u64::from(d);
            max = max.max(d);
            if d > 2 {
                differ += 1;
                bands[y * 8 / h] += 1;
            }
        }
    }
    let n = (w * h).max(1);
    let bands: Vec<String> = bands.iter().map(|b| format!("{:.0}", *b as f64 * 800.0 / n as f64)).collect();
    format!(
        "mean {:.3}, max {max}, differing {:.2} %, per eighth of rows % [{}]",
        sum as f64 / n as f64,
        differ as f64 * 100.0 / n as f64,
        bands.join(" ")
    )
}

impl Run<'_> {
    fn count(&mut self, g: &Glass, phase: &str) -> (Class, Option<i64>) {
        let (class, content) = classify(self.truth, g);
        self.counts.pictures += 1;

        match class {
            Class::Exact => self.counts.exact += 1,
            Class::Near => self.counts.near += 1,
            Class::Wrong(_) if g.exact => self.counts.wrong_exact += 1,
            Class::Wrong(_) => self.counts.wrong_stand_in += 1,
            Class::Unmatched => self.counts.unmatched += 1,
        }
        let bad = matches!(class, Class::Unmatched) || (matches!(class, Class::Wrong(_)) && g.exact);
        if bad
            && let Some(dir) = &self.dump
            && self.dumped.len() < 4
        {
            write_png(
                &dir.join(format!("{phase}-{}-claimed-{}.png", self.counts.pictures, g.claimed)),
                &g.pixels,
                g.size,
            );
            self.dumped.push((g.claimed, g.pixels.clone(), g.size));
        }
        if class == Class::Near && g.exact && self.near_notes < 3 {
            self.near_notes += 1;
            let c = g.claimed.clamp(0, self.truth.sig.len() as i64 - 1) as usize;
            self.notes.push(format!(
                "{phase}: claimed {} exact -> Near at {:.2} (close {:.2})",
                g.claimed,
                g.sig.distance(&self.truth.sig[c], None),
                self.truth.close[c]
            ));
        }
        if bad && self.notes.len() < 16 {
            let bands: Vec<usize> = (0..GRID.1).map(|b| self.truth.best(&g.sig, Some(b)).0).collect();
            let (r, d) = self.truth.best(&g.sig, None);
            self.notes.push(format!(
                "{phase}: claimed {} exact {} -> {class:?}, hash equal to frame {:?}, nearest frame {r} at {d:.2} (close {:.2}); \
                 row bands nearest {bands:?}",
                g.claimed,
                g.exact,
                self.truth.hash.iter().position(|h| *h == g.hash),
                self.truth.close[r]
            ));
        }
        (class, content)
    }
}

/// Runs the check on `clip` and returns the counts and the report.
pub fn run(clip: &Path, plan: &Plan) -> Result<Report, String> {
    let gpu = Gpu::new().map_err(|e| format!("no GPU: {e}"))?;
    let seconds = plan.frames / 25 + 2;
    let truth_engine = BenchEngine::open(&gpu, clip, seconds, plan.truth_hardware, false, plan.color, Duration::ZERO)?;
    let frame = truth_engine.frame;
    let fps = 1.0 / (frame.value() as f64 / frame.timescale() as f64);
    let frames = plan.frames.min((seconds as f64 * fps) as i64 - 1);
    let started = Instant::now();
    let mut tw = Window::new(&gpu, frame)?;
    let truth = Truth::collect(&truth_engine, &mut tw, frames)?;
    let truth_secs = started.elapsed().as_secs_f64();
    let truth_from = if plan.truth_hardware { "platform decoder" } else { "FFmpeg software" };
    let repeats = (1..truth.hash.len()).filter(|&i| truth.hash[..i].contains(&truth.hash[i])).count();
    drop(truth_engine);

    let e = BenchEngine::open(&gpu, clip, seconds, true, true, plan.color, plan.decode_delay)?;
    let mut w = Window::new(&gpu, frame)?;
    let dump = std::env::var_os("SQ_CHECK_DUMP").map(std::path::PathBuf::from);
    if let Some(d) = &dump {
        let _ = std::fs::create_dir_all(d);
    }
    let mut run =
        Run { truth: &truth, counts: Counts::default(), notes: Vec::new(), near_notes: 0, dump, dumped: Vec::new() };

    // The hardware path's settled pictures against the software truth.
    let mut paused_mismatch = 0;
    for f in (3..frames - 3).step_by(((frames / 12) as usize).max(1)) {
        let g = settle(&e, &mut w, f)?;
        if g.hash != truth.hash[f as usize] {
            paused_mismatch += 1;
            if g.sig.distance(&truth.sig[f as usize], None) > truth.close[f as usize] {
                run.notes
                    .push(format!("paused frame {f}: hardware picture differs from software beyond the frame gap"));
            }
        }
    }

    // Scrub: a random walk, one request per display tick.
    let (lo, hi) = (2, frames - 3);
    let mut seed = plan.seed;
    let mut rand = |n: u64| {
        seed = seed.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        (seed >> 33) % n
    };
    let mut at = lo + (hi - lo) / 2;
    let mut dir = 1i64;
    let mut latencies = Vec::new();
    let (mut requested_at, mut pending) = (Instant::now(), Some(at));
    let mut prev_content: Option<i64> = None;
    let mut late_ticks = 0;
    settle(&e, &mut w, at)?;
    e.handle.begin_scrub();
    let ticks = plan.scrub_ticks;
    let mut holds = 0;
    let mut t = 0;
    let mut next = Instant::now();
    while t < ticks {
        // Every 50 ticks a hold of 20 ticks: the exact frame must arrive.
        let holding = t % 50 >= 30;
        if !holding && rand(100) >= 10 {
            if rand(100) < 30 {
                dir = -dir;
            }
            let step = [1, 1, 1, 2, 2, 3, 5, 8, 15, 30][rand(10) as usize];
            let mut n = at + dir * step;
            if n < lo || n > hi {
                dir = -dir;
                n = (at + dir * step).clamp(lo, hi);
            }
            if n != at {
                at = n;
                (requested_at, pending) = (Instant::now(), Some(at));
                e.handle.scrub(e.frame * at);
            }
        }
        next += TICK;
        e.timing.tick(Instant::now(), TICK, Duration::from_millis(1));
        std::thread::sleep(next.saturating_duration_since(Instant::now()));
        if Instant::now() > next + TICK {
            late_ticks += 1;
            next = Instant::now();
        }
        if let Some(g) = w.frame(&e.handle)? {
            let (class, content) = run.count(&g, "scrub");
            if let (Some(p), Some(c)) = (prev_content, content)
                && (c - at).abs() > (p - at).abs()
            {
                run.counts.moves_away += 1;
            }
            if content.is_some() {
                prev_content = content;
            }
            // Scrubbing draws reduced detail by design (the scrub preview rule): exact = the scrub's own picture.
            if pending == Some(g.claimed) && g.exact && matches!(class, Class::Exact | Class::Near) {
                latencies.push(requested_at.elapsed().as_secs_f64() * 1e3);
                pending = None;
            }
        }
        if t % 50 == 49 {
            holds += 1;
            if pending.is_some() {
                run.counts.hold_missed += 1;
            }
        }
        t += 1;
    }
    e.handle.end_scrub();
    let scrub_counts = run.counts.clone();

    // Playback legs.
    let mut legs = Vec::new();
    for &(rate, secs) in &plan.play {
        let start = if rate.is_forward() { 5 } else { frames - 5 };
        settle(&e, &mut w, start)?;
        let before = run.counts.clone();
        let fwd = rate.is_forward();
        let per_frame_ticks = (1.0 / fps) / TICK.as_secs_f64() / (f64::from(rate.num().abs()) / f64::from(rate.den()));
        let allowed_hold = per_frame_ticks.ceil().max(1.0) as usize;
        let allowed_step = (1.0 / per_frame_ticks).ceil().max(1.0) as i64;
        e.handle.play(rate);
        let begin = Instant::now();
        let mut next = begin;
        let (mut last_claimed, mut last_content, mut held, mut last_new) = (None::<i64>, None::<i64>, 0usize, None);
        let mut gaps = Vec::new();
        while begin.elapsed().as_secs_f64() < secs {
            next += TICK;
            e.timing.tick(Instant::now(), TICK, Duration::from_millis(1));
            std::thread::sleep(next.saturating_duration_since(Instant::now()));
            if Instant::now() > next + TICK {
                late_ticks += 1;
                next = Instant::now();
            }
            let Some(g) = w.frame(&e.handle)? else {
                held += 1;
                continue;
            };
            let now = Instant::now();
            if let Some(l) = last_new {
                gaps.push(now.duration_since(l).as_secs_f64() * 1e3);
            }
            last_new = Some(now);
            let (_, content) = run.count(&g, "play");
            let against = |a: i64, b: i64| if fwd { b < a } else { b > a };
            if let Some(l) = last_claimed
                && against(l, g.claimed)
            {
                run.counts.claimed_backwards += 1;
            }
            last_claimed = Some(g.claimed);
            if let Some(c) = content {
                if let Some(l) = last_content {
                    if against(l, c) {
                        run.counts.content_backwards += 1;
                    } else if (c - l).abs() > allowed_step {
                        run.counts.skipped += ((c - l).abs() - allowed_step) as usize;
                    }
                    if c == l {
                        held += 1;
                    } else {
                        held = 0;
                    }
                } else {
                    held = 0;
                }
                last_content = Some(c);
            }
            if held + 1 > allowed_hold {
                run.counts.held_long += 1;
            }
        }
        e.handle.pause();
        e.handle.sync();
        let d = diff(&before, &run.counts);
        legs.push(format!(
            "play {}x{} {secs:.1} s: {} pictures, {} exact, {} near, {} wrong (exact) / {} wrong (stand-in), {} unmatched, \
             claimed backwards {}, content backwards {}, skipped {}, held long {}; gaps {}",
            rate.num(),
            if rate.den() != 1 { format!("/{}", rate.den()) } else { String::new() },
            d.pictures,
            d.exact,
            d.near,
            d.wrong_exact,
            d.wrong_stand_in,
            d.unmatched,
            d.claimed_backwards,
            d.content_backwards,
            d.skipped,
            d.held_long,
            spread(&mut gaps),
        ));
    }
    // Dumped pictures against the settled frames around the one they claim.
    if let Some(dir) = run.dump.clone() {
        for (claimed, pixels, size) in std::mem::take(&mut run.dumped) {
            for f in (claimed - 3).max(0)..=(claimed + 3).min(frames - 1) {
                let g = settle(&e, &mut w, f)?;
                write_png(&dir.join(format!("settled-{f}.png")), &g.pixels, g.size);
                if g.size == size {
                    run.notes.push(format!(
                        "dump claimed {claimed} vs settled {f}: {}",
                        pixel_diff(&pixels, &g.pixels, size)
                    ));
                }
            }
        }
    }
    let c = &scrub_counts;
    let text = format!(
        "clip: {} ({}, {}x{} {} {}-bit {})\ntruth: {frames} frames, {truth_from}, {truth_secs:.1} s, {repeats} repeat an earlier frame; checked engine's paused \
         pictures differing from it: {paused_mismatch}\n\
         scrub {ticks} ticks: {} pictures, {} exact, {} near, {} wrong (exact) / {} wrong (stand-in), {} unmatched, \
         {} moves away from the request, {}/{holds} holds missed; request to exact frame {}\n{}\nloop ticks late: {late_ticks}\n{}\n",
        clip.display(),
        e.label,
        e.track.width,
        e.track.height,
        e.track.codec,
        e.track.bit_depth,
        e.track.chroma,
        c.pictures,
        c.exact,
        c.near,
        c.wrong_exact,
        c.wrong_stand_in,
        c.unmatched,
        c.moves_away,
        c.hold_missed,
        spread(&mut latencies),
        legs.join("\n"),
        run.notes.join("\n"),
    );
    Ok(Report { counts: run.counts, text })
}

fn diff(a: &Counts, b: &Counts) -> Counts {
    Counts {
        pictures: b.pictures - a.pictures,
        exact: b.exact - a.exact,
        near: b.near - a.near,
        wrong_exact: b.wrong_exact - a.wrong_exact,
        wrong_stand_in: b.wrong_stand_in - a.wrong_stand_in,
        unmatched: b.unmatched - a.unmatched,
        claimed_backwards: b.claimed_backwards - a.claimed_backwards,
        content_backwards: b.content_backwards - a.content_backwards,
        skipped: b.skipped - a.skipped,
        held_long: b.held_long - a.held_long,
        moves_away: b.moves_away - a.moves_away,
        hold_missed: b.hold_missed - a.hold_missed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Command, Stdio};

    /// An 11 s 320x180 long-GOP clip with motion (GOP 15, 2 B-frames, 10-bit 4:2:2 like the camera files); `None` without ffmpeg.
    fn clip() -> Option<std::path::PathBuf> {
        let dir = std::env::temp_dir().join(format!("sq-present-check-{}", std::process::id()));
        std::fs::create_dir_all(&dir).ok()?;
        let out = dir.join("motion.mp4");
        // The LGPL FFmpeg builds (Windows) have no libx264: MPEG-4 Part 2 is long-GOP with B-frames as well.
        let encoders: [&[&str]; 2] = [
            &["-c:v", "libx264", "-pix_fmt", "yuv422p10le", "-g", "15", "-bf", "2"],
            &["-c:v", "mpeg4", "-q:v", "2", "-g", "15", "-bf", "2"],
        ];
        encoders
            .iter()
            .any(|enc| {
                Command::new("ffmpeg")
                    .args(["-v", "quiet", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=30:duration=11"])
                    .args(*enc)
                    .arg(&out)
                    .stdin(Stdio::null())
                    .status()
                    .is_ok_and(|s| s.success())
            })
            .then_some(out)
    }

    /// Every picture the window gets while scrubbing back and forth and playing forward and back shows the frame it claims
    /// (or a declared stand-in), never a torn or mixed one, and time never runs backwards.
    #[test]
    fn scrub_and_play_hand_the_window_only_the_frames_they_claim() {
        if !sq_media_ffmpeg::shim::AVAILABLE || Gpu::new().is_err() {
            sq_os::errln!("skipped: no FFmpeg or no GPU");
            return;
        }
        let Some(path) = clip() else {
            sq_os::errln!("skipped: no ffmpeg tool");
            return;
        };
        let plan = Plan {
            frames: 300,
            scrub_ticks: 150,
            play: vec![(PlaybackRate::FORWARD, 1.5), (PlaybackRate::REVERSE, 1.0)],
            seed: 7,
            color: false,
            decode_delay: Duration::from_millis(60),
            truth_hardware: true,
        };
        let r = run(&path, &plan).expect("present check");
        let _ = std::fs::remove_dir_all(path.parent().expect("dir"));
        sq_os::errln!("{}", r.text);
        let c = &r.counts;
        assert!(c.pictures > 100, "{}", r.text);
        assert_eq!((c.wrong_exact, c.unmatched), (0, 0), "{}", r.text);
        assert_eq!((c.claimed_backwards, c.content_backwards), (0, 0), "{}", r.text);
        assert_eq!(c.hold_missed, 0, "{}", r.text);
    }
}
