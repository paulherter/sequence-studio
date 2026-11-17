// Goldens dumped by the Swift code (`oracle/sq-export/core/run.sh`): loudness, GIF palette, still pixels, HDR bytes,
// progress math, GIF timing and naming, all from the real Swift source files.

use crate::core::*;
use std::collections::HashMap;
use std::sync::OnceLock;

fn golden() -> &'static HashMap<String, Vec<Vec<String>>> {
    static G: OnceLock<HashMap<String, Vec<Vec<String>>>> = OnceLock::new();
    G.get_or_init(|| {
        let path = format!("{}/../../oracle/sq-export/core/golden/core.tsv", env!("CARGO_MANIFEST_DIR"));
        let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
        let mut m: HashMap<String, Vec<Vec<String>>> = HashMap::new();
        for l in text.lines() {
            let mut f = l.split('\t').map(str::to_string);
            let name = f.next().unwrap();
            m.entry(name).or_default().push(f.collect());
        }
        m
    })
}

fn rows(name: &str) -> &'static Vec<Vec<String>> {
    golden().get(name).unwrap_or_else(|| panic!("no golden rows {name}"))
}

fn row(name: &str) -> &'static Vec<String> {
    &rows(name)[0]
}

/// "decimal|hexbits" or "-inf"/"inf" as written by the dump.
fn num(s: &str) -> f64 {
    match s {
        "-inf" => f64::NEG_INFINITY,
        "inf" => f64::INFINITY,
        _ => f64::from_bits(u64::from_str_radix(s.split('|').nth(1).unwrap(), 16).unwrap()),
    }
}

/// Same value to 1e-9 (libm differences between platforms are in the last bits).
fn close(a: f64, b: f64, what: &str) {
    assert!(a == b || (a - b).abs() <= 1e-9 * (1.0 + b.abs()), "{what}: {a} vs {b}");
}

/// The dump's `WaveSource`: a 200 Hz triangle (integer phase, no transcendental functions) with a burst every half second.
struct Wave {
    base: f32,
    burst: f32,
    burst_len: usize,
    total: usize,
    pos: usize,
}

impl Wave {
    fn new(base: f32, burst: f32, seconds: usize, burst_len: usize) -> Wave {
        Wave { base, burst, burst_len, total: seconds * 48_000, pos: 0 }
    }
}

impl AudioSource for Wave {
    fn sample_rate(&self) -> i64 {
        48_000
    }
    fn channels(&self) -> usize {
        2
    }
    fn next_chunk(&mut self, max_frames: usize) -> Result<Option<AudioChunk>, ExportError> {
        let n = max_frames.min(self.total - self.pos);
        if n == 0 {
            return Ok(None);
        }
        let mut s = vec![0.0f32; n * 2];
        for i in 0..n {
            let f = self.pos + i;
            let ph = f % 240;
            let tri = (if ph < 120 { ph } else { 240 - ph }) as f32 / 60.0 - 1.0;
            let a = if f % 24_000 < self.burst_len { self.burst } else { self.base };
            s[i * 2] = a * tri;
            s[i * 2 + 1] = a * tri * 0.5;
        }
        self.pos += n;
        Ok(Some(AudioChunk::new(s, 2)))
    }
    fn as_rewindable(&mut self) -> Option<&mut dyn RewindableAudioSource> {
        Some(self)
    }
}

impl RewindableAudioSource for Wave {
    fn rewind(&mut self) -> Result<(), ExportError> {
        self.pos = 0;
        Ok(())
    }
}

/// The dump's `SinSource` (the sine source of the Swift limiting tests).
struct Sin(Wave);

impl AudioSource for Sin {
    fn sample_rate(&self) -> i64 {
        48_000
    }
    fn channels(&self) -> usize {
        2
    }
    fn next_chunk(&mut self, max_frames: usize) -> Result<Option<AudioChunk>, ExportError> {
        let w = &mut self.0;
        if w.pos >= w.total {
            return Ok(None);
        }
        let n = max_frames.min(w.total - w.pos);
        let mut s = vec![0.0f32; n * 2];
        for i in 0..n {
            let f = w.pos + i;
            let a = if f % 24_000 < 48 { w.burst } else { w.base };
            let v = a * (2.0 * std::f64::consts::PI * 1000.0 * f as f64 / 48_000.0).sin() as f32;
            s[i * 2] = v;
            s[i * 2 + 1] = v;
        }
        w.pos += n;
        Ok(Some(AudioChunk::new(s, 2)))
    }
    fn as_rewindable(&mut self) -> Option<&mut dyn RewindableAudioSource> {
        Some(self)
    }
}

impl RewindableAudioSource for Sin {
    fn rewind(&mut self) -> Result<(), ExportError> {
        self.0.pos = 0;
        Ok(())
    }
}

fn fnv(bytes: &[u8]) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in bytes {
        h = (h ^ u64::from(*b)).wrapping_mul(0x100000001b3);
    }
    format!("{h:x}")
}

#[test]
fn loudness_matches_swift() {
    let c = CancelToken::new();
    let cases: [(&str, f32, f32, usize, usize, f64, f64); 8] = [
        ("quiet", 0.05, 0.05, 4, 48, -14.0, -1.0),
        ("loud", 0.9, 0.9, 4, 48, -14.0, -1.0),
        ("peaky", 0.1, 0.8, 6, 48, -17.0, -1.0),
        ("lowceiling", 0.25, 0.25, 4, 48, -14.0, -20.0),
        ("ebu", 0.05, 0.3, 4, 48, -23.0, -1.0),
        ("short1", 0.2, 1.0, 6, 6, -14.0, -1.0),
        ("short2", 0.15, 0.95, 6, 12, -12.0, -3.0),
        ("short3", 0.1, 0.9, 6, 240, -16.0, -2.0),
    ];
    for (name, base, burst, secs, bl, target, ceiling) in cases {
        let s = LoudnessNormalization::new(target, ceiling);
        let mut src = Wave::new(base, burst, secs, bl);
        let m = LoudnessNormalizer::measure(&mut src, &c).unwrap();
        let g = row(&format!("measure.{name}"));
        close(m.integrated_lufs, num(&g[0]), &format!("{name} lufs"));
        close(m.true_peak_db, num(&g[1]), &format!("{name} peak"));
        close(LoudnessNormalizer::gain_db(m, s), num(&row(&format!("gain.{name}"))[0]), &format!("{name} gain"));
        let plan = LoudnessNormalizer::plan(&mut src, m, s, &c).unwrap();
        let g = row(&format!("plan.{name}"));
        close(plan.gain_db, num(&g[0]), &format!("{name} plan gain"));
        match (&g[1][..], plan.limiter_ceiling_db) {
            ("none", None) => {}
            (swift, Some(rust)) if swift != "none" => close(rust, num(swift), &format!("{name} limiter ceiling")),
            (swift, rust) => panic!("{name}: limiter {swift} vs {rust:?}"),
        }
        close(plan.result.integrated_lufs, num(&g[2]), &format!("{name} plan lufs"));
        close(plan.result.true_peak_db, num(&g[3]), &format!("{name} plan peak"));

        let mut n = NormalizedAudioSource::make(Box::new(Wave::new(base, burst, secs, bl)), s, &c).unwrap();
        let r = LoudnessReport::from_normalized(&n, s);
        let g = row(&format!("report.{name}"));
        assert_eq!(r.summary(), g[0], "{name} summary");
        assert_eq!(
            (r.limited_by_ceiling.to_string(), r.limiter_used.to_string()),
            (g[1].clone(), g[2].clone()),
            "{name}"
        );
        close(r.output_lufs(), num(&g[3]), &format!("{name} out lufs"));
        let mut bytes = Vec::new();
        for v in n.next_chunk(2048).unwrap().unwrap().samples.iter().take(4096) {
            bytes.extend(v.to_bits().to_le_bytes());
        }
        assert_eq!(fnv(&bytes), row(&format!("stream.{name}"))[0], "{name} stream bits");
    }
}

#[test]
fn loudness_with_sine_sources_matches_swift_within_tolerance() {
    let c = CancelToken::new();
    let cases = [
        ("peaky", 0.1, 0.8, 6, -17.0, -1.0),
        ("tone", 0.05, 0.05, 4, -16.0, -1.0),
        ("lowceiling", 0.25, 0.25, 4, -14.0, -20.0),
    ];
    for (name, base, burst, secs, target, ceiling) in cases {
        let s = LoudnessNormalization::new(target, ceiling);
        let g = row(&format!("sin.{name}"));
        let mut src = Sin(Wave::new(base, burst, secs, 48));
        let m = LoudnessNormalizer::measure(&mut src, &c).unwrap();
        close(m.integrated_lufs, num(&g[0]), name);
        close(m.true_peak_db, num(&g[1]), name);
        let n = NormalizedAudioSource::make(Box::new(Sin(Wave::new(base, burst, secs, 48))), s, &c).unwrap();
        close(n.gain_db, num(&g[2]), &format!("{name} gain"));
        assert_eq!(n.limiter_ceiling_db.is_some(), g[3] != "none", "{name} limiter");
        if let Some(l) = n.limiter_ceiling_db {
            close(l, num(&g[3]), &format!("{name} limiter ceiling"));
        }
        close(n.result.integrated_lufs, num(&g[4]), &format!("{name} result lufs"));
        close(n.result.true_peak_db, num(&g[5]), &format!("{name} result peak"));
        let r = LoudnessReport::from_normalized(&n, s);
        assert_eq!(
            (r.limiter_used.to_string(), r.limited_by_ceiling.to_string()),
            (g[6].clone(), g[7].clone()),
            "{name}"
        );
        assert_eq!(r.summary(), g[8], "{name} summary");
    }
}

#[test]
fn fixed_reports_match_swift() {
    for g in rows("report.fixed") {
        let (l, p): (f64, f64) = (g[0].parse().unwrap(), g[1].parse().unwrap());
        let r = LoudnessReport::new(
            LoudnessMeasurement { integrated_lufs: l, true_peak_db: p },
            LoudnessNormalization::default(),
        );
        assert_eq!(r.gain_db, num(&g[2]));
        assert_eq!(r.limited_by_ceiling.to_string(), g[3]);
        // Swift prints "-inf" through "%.1f" as "-inf"; Rust prints "-inf" too.
        assert_eq!(r.summary(), g[4]);
    }
}

fn rgba(w: usize, h: usize, f: impl Fn(usize, usize) -> (u8, u8, u8)) -> Vec<u8> {
    let mut out = Vec::new();
    for y in 0..h {
        for x in 0..w {
            let c = f(x, y);
            out.extend([c.0, c.1, c.2, 255]);
        }
    }
    out
}

#[test]
fn gif_palettes_match_swift() {
    let images: [(&str, usize, usize, Vec<u8>); 5] = [
        (
            "flat",
            4,
            2,
            rgba(4, 2, |x, y| {
                if x < 2 {
                    (255, 0, 0)
                } else if y == 0 {
                    (0, 0, 255)
                } else {
                    (12, 200, 99)
                }
            }),
        ),
        ("gradient", 256, 64, rgba(256, 64, |x, y| (x as u8, ((y * 4) & 255) as u8, (255 - x) as u8))),
        ("xor", 64, 64, rgba(64, 64, |x, y| ((x * 4) as u8, (y * 4) as u8, ((x ^ y) * 4) as u8))),
        (
            "noise",
            97,
            53,
            rgba(97, 53, |x, y| {
                let v = (x as u32)
                    .wrapping_mul(2_654_435_761)
                    .wrapping_add((y as u32).wrapping_mul(40_503))
                    .wrapping_add((x * y) as u32);
                ((v >> 8 & 255) as u8, (v >> 16 & 255) as u8, (v >> 24 & 255) as u8)
            }),
        ),
        ("sky", 120, 80, rgba(120, 80, |x, y| ((40 + y) as u8, (90 + y * 2 / 3) as u8, (200 - x / 3) as u8))),
    ];
    for (name, w, h, px) in images {
        let f = GifPalette::quantize(&px, w, h, w * 4, 0, 1, 2, 256);
        let g = row(&format!("gif.{name}"));
        assert_eq!(f.colors.len().to_string(), g[0], "{name} colors");
        assert_eq!(fnv(&f.indices), g[1], "{name} indices");
        let flat: Vec<u8> = f.colors.iter().flat_map(|c| [c.0, c.1, c.2]).collect();
        assert_eq!(fnv(&flat), g[2], "{name} palette");
    }
    let bgra = [10u8, 20, 30, 255, 200, 100, 50, 255];
    let f = GifPalette::quantize(&bgra, 2, 1, 8, 2, 1, 0, 256);
    let g = row("gif.bgra");
    assert_eq!(fnv(&f.indices), g[0]);
    assert_eq!(fnv(&f.colors.iter().flat_map(|c| [c.0, c.1, c.2]).collect::<Vec<u8>>()), g[1]);
}

#[test]
fn still_pixels_match_swift() {
    let g = row("oetf");
    let xs = [0.0f32, 0.001, 0.018, 0.018053968510807f64 as f32, 0.02, 0.1, 0.18, 0.5, 0.9, 1.0, 2.0, -1.0];
    for (x, want) in xs.iter().zip(g) {
        let got = FrameStillPixels::oetf(*x).to_bits();
        let want: u32 = want.parse().unwrap();
        assert!(got.abs_diff(want) <= 1, "oetf({x}): {got} vs {want}"); // powf may differ by one ulp between libms
    }
    let hs = [0x0001u16, 0x03FF, 0x0400, 0x3C00, 0x7BFF, 0x7C00, 0xFC00, 0x8001];
    for (h, want) in hs.iter().zip(row("half")) {
        assert_eq!(FrameStillPixels::float(*h).to_bits().to_string(), *want, "half {h:#x}");
    }
    let mut halves: Vec<u16> = Vec::new();
    for i in 0..(7 * 5) {
        let (r, g, b) = (0x2000 + i * 211 % 0x1C00, 0x3000 + i * 97 % 0x0F00, (i * 331) % 0x3C00);
        let a = if i % 3 == 0 { 0 } else { 0x3800 + i * 13 % 0x0600 };
        halves.extend([r as u16, g as u16, b as u16, a as u16]);
    }
    let bytes: Vec<u8> = halves.iter().flat_map(|h| h.to_le_bytes()).collect();
    for fmt in FrameStillFormat::ALL {
        let img = FrameStillPixels::image(&bytes, 7, 5, 56, fmt).unwrap();
        let name = match fmt {
            FrameStillFormat::Png => "png",
            FrameStillFormat::PngAlpha => "pngAlpha",
            FrameStillFormat::Jpeg => "jpeg",
            FrameStillFormat::Tiff16 => "tiff16",
            FrameStillFormat::Tiff16Alpha => "tiff16Alpha",
            FrameStillFormat::Exr => "exr",
        };
        let g = row(&format!("still.{name}"));
        assert_eq!(fnv(&img.bytes), g[0], "{name} bytes");
        assert_eq!(
            (img.bits_per_channel.to_string(), img.is_float.to_string(), img.has_alpha.to_string()),
            (g[1].clone(), g[2].clone(), g[3].clone())
        );
    }
}

#[test]
fn hdr_bytes_match_swift() {
    let ds = [
        HdrDelivery::default(),
        HdrDelivery::new(HdrTransfer::Hlg, 600.0, 180.0, 0.01),
        HdrDelivery::new(HdrTransfer::Pq, 99_999.0, 50_000.0, 0.005),
    ];
    let hex = |b: Vec<u8>| b.iter().map(|x| format!("{x:x}")).collect::<Vec<_>>().join(",");
    for (d, g) in ds.iter().zip(rows("hdr")) {
        assert_eq!((format!("{:?}", d.peak_nits), format!("{:?}", d.frame_average_nits)), (g[0].clone(), g[1].clone()));
        assert_eq!(hex(d.mastering_display_data()), g[2]);
        assert_eq!(hex(d.content_light_level_data()), g[3]);
    }
}

#[test]
fn progress_math_matches_swift() {
    let mut t = ExportProgressTracker::new();
    let bits = |v: Option<f64>| v.map_or("-".to_string(), |x| format!("{:x}", x.to_bits()));
    let want = &row("progress");
    for (i, p) in [0.0, 0.005, 0.02, 0.05, 0.05, 0.2, 0.21, 0.6, 1.0].into_iter().enumerate() {
        t.record(p, i as f64 * 1.5);
        let got = format!("{:?}/{}/{}", t.progress(), bits(t.rate()), bits(t.remaining()));
        assert_eq!(got, want[i], "step {i}");
    }
    let f: Vec<String> = [0.0, 59.4, 61.0, 3725.0, 86399.9]
        .iter()
        .map(|s| ExportProgressTracker::format(*s))
        .chain([
            ExportProgressTracker::remaining_text(None),
            ExportProgressTracker::remaining_text(Some(75.0)),
            ExportProgressTracker::remaining_text(Some(0.2)),
        ])
        .collect();
    assert_eq!(&f, row("progress.format"));
}

#[test]
fn gif_timing_and_naming_match_swift() {
    use sq_core_time::Time;
    let cases = [
        ("24", Time::new(1, 24), 240),
        ("2398", Time::new(1001, 24000), 240),
        ("2997", Time::new(1001, 30000), 300),
        ("25", Time::new(1, 25), 50),
        ("15", Time::new(1, 15), 31),
    ];
    for (name, fd, n) in cases {
        let d = GifTiming::delays_centiseconds(fd, n);
        let g = row(&format!("gifdelay.{name}"));
        assert_eq!(fnv(&d.iter().map(|x| *x as u8).collect::<Vec<u8>>()), g[0], "{name}");
        assert_eq!(d.iter().sum::<i64>().to_string(), g[1], "{name}");
        assert_eq!(format!("{:?}", &d[..8]), g[2], "{name}");
    }
    let g = row("naming");
    assert_eq!(ImageSequenceNaming::file_name("a/b:c", 7, 4, "png"), g[0]);
    assert_eq!(ImageSequenceNaming::digits(99_990, 20).to_string(), g[1]);
    assert_eq!(ImageSequenceNaming::file_names(" .Shot ", 8, 3, "tiff").join(","), g[2]);
    let names: Vec<String> =
        ["a/b:c", "  .hidden ", "   ", "tab\there", "ok name", "x\u{1}y"].iter().map(|n| sanitize(n)).collect();
    assert_eq!(&names, row("sanitize"));
}
