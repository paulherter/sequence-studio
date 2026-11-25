//! The per-frame CSV of a `--play-bench` run (`SQ_BENCH_CSV=<file>`, plan H2a). The engine records (`sq_playback::engine::frame_trace`);
//! this module switches it on before Play and writes the file after. Without the variable nothing is recorded.

use sq_core_time::Time;
use std::path::PathBuf;

/// The CSV path from the environment, with the trace switched on (and emptied) when it is set.
pub fn start() -> Option<PathBuf> {
    let path = std::env::var_os("SQ_BENCH_CSV").filter(|v| !v.is_empty()).map(PathBuf::from)?;
    sq_playback::engine::frame_trace::set_enabled(true);
    Some(path)
}

/// Writes the rows recorded since [`start`] and switches the trace off; the returned line goes into the run log.
pub fn finish(path: Option<PathBuf>) -> String {
    let Some(path) = path else { return String::new() };
    let rows = sq_playback::engine::frame_trace::rows();
    sq_playback::engine::frame_trace::set_enabled(false);
    match std::fs::write(&path, sq_playback::engine::frame_trace::to_csv(&rows)) {
        Ok(()) => format!("per-frame CSV: {} rows in {}\n", rows.len(), path.display()),
        Err(e) => format!("per-frame CSV {}: {e}\n", path.display()),
    }
}

/// The frame number the korpus barcode (`scripts/perf-media.sh`) holds: 16 cells across the bottom 32 source rows, bit k of
/// the frame number (least significant bit left), white = 1. Read from RGBA8 pixels of the shown composite at any size and
/// opacity: each cell's mean light is compared with half of the brightest cell. `None` when the picture is too small.
pub fn read_barcode(rgba: &[u8], width: u32, height: u32) -> Option<u32> {
    let (w, h) = (width as usize, height as usize);
    if w < 64 || h < 64 || rgba.len() < w * h * 4 {
        return None;
    }
    // The stripe is the bottom 1.5 % of the picture; sample its middle rows, cell centers +- a quarter cell.
    let band = (h - (h / 64).max(2) - 1..h - 3).step_by(1).collect::<Vec<_>>();
    let cells: Vec<f64> = (0..16)
        .map(|k| {
            let (c0, half) = ((2 * k + 1) * w / 32, w / 64);
            let (mut sum, mut n) = (0.0, 0.0);
            for &y in &band {
                for x in c0 - half..c0 + half {
                    let p = &rgba[(y * w + x) * 4..];
                    sum += (f64::from(p[0]) + f64::from(p[1]) + f64::from(p[2])) / 3.0;
                    n += 1.0;
                }
            }
            sum / n
        })
        .collect();
    let top = cells.iter().copied().fold(0.0, f64::max);
    if top < 24.0 {
        return Some(0); // no lit cell: frame 0 (or a black picture; the position check tells them apart)
    }
    Some(cells.iter().enumerate().fold(0, |n, (k, v)| n | (u32::from(*v > top / 2.0) << k)))
}

/// `--bench-verify`: every new picture on screen is read back and its barcode compared with the position it claims, and with
/// the engine's own exact flag. Reading back costs a few ms per picture, so it only runs when asked for.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Verify {
    pub checked: u64,
    /// Barcode frame number = position on screen.
    pub barcode_correct: u64,
    /// The presenter's exact flag (no stand-in).
    pub presenter_correct: u64,
    /// Pictures where the two disagree.
    pub disagree: u64,
    pub unreadable: u64,
    last: Option<i64>,
}

impl Verify {
    /// Reads the shown picture; counts it once per position.
    pub fn sample(&mut self, engine: &dyn sq_editor_session::ProgramEngine, fps: f64) {
        let Some(s) = crate::playback::bench_shown_pixels(engine) else { return };
        let at = (s.position.value() as f64 / s.position.timescale().max(1) as f64 * fps).round() as i64;
        if self.last == Some(at) {
            return;
        }
        self.last = Some(at);
        self.checked += 1;
        let Some(n) = read_barcode(&s.rgba, s.size.0, s.size.1) else {
            self.unreadable += 1;
            return;
        };
        let right = i64::from(n) == at;
        self.barcode_correct += u64::from(right);
        self.presenter_correct += u64::from(s.exact);
        self.disagree += u64::from(right != s.exact);
    }

    pub fn line(&self) -> String {
        format!(
            "bench-verify: {} pictures read back, barcode correct {}, presenter correct {}, disagree {}, unreadable {}\n",
            self.checked, self.barcode_correct, self.presenter_correct, self.disagree, self.unreadable
        )
    }
}

/// `SQ_BENCH_DUMP=<dir>` with `SQ_BENCH_DUMP_AT=<s,s,..>` (measurement only, `scripts/fxsize-pixels.sh`): writes the shown picture
/// of the first new position at or after each timeline second as `<dir>/play.<frame>.<w>x<h>.rgba`, and after the run the
/// same frame paused (full size) as `full.<frame>.<w>x<h>.rgba`.
pub struct Dump {
    dir: PathBuf,
    todo: Vec<f64>,
    pub taken: Vec<(i64, Time)>,
}

impl Dump {
    pub fn from_env() -> Option<Self> {
        let dir = std::env::var_os("SQ_BENCH_DUMP").filter(|v| !v.is_empty()).map(PathBuf::from)?;
        let mut todo: Vec<f64> =
            std::env::var("SQ_BENCH_DUMP_AT").ok()?.split(',').filter_map(|t| t.trim().parse().ok()).collect();
        todo.reverse();
        std::fs::create_dir_all(&dir).ok()?;
        Some(Self { dir, todo, taken: Vec::new() })
    }

    fn write(&self, kind: &str, frame: i64, s: &crate::playback::ShownPixels) {
        let name = format!("{kind}.{frame}.{}x{}.rgba", s.size.0, s.size.1);
        let _ = std::fs::write(self.dir.join(name), &s.rgba);
    }

    /// Called for every new position while playing.
    pub fn sample(&mut self, engine: &dyn sq_editor_session::ProgramEngine, fps: f64) {
        let Some(&next) = self.todo.last() else { return };
        let Some(s) = crate::playback::bench_shown_pixels(engine) else { return };
        let secs = s.position.value() as f64 / s.position.timescale().max(1) as f64;
        if secs < next || !s.exact {
            return;
        }
        self.todo.pop();
        let frame = (secs * fps).round() as i64;
        self.write("play", frame, &s);
        self.taken.push((frame, s.position));
    }

    /// Stores the paused (full size) picture of a position the run dumped; false when it never arrived.
    pub fn store_full(&self, engine: &dyn sq_editor_session::ProgramEngine, frame: i64, at: Time) -> bool {
        let Some(s) = crate::playback::bench_shown_pixels(engine) else { return false };
        if s.position != at || !s.exact {
            return false;
        }
        self.write("full", frame, &s);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A picture of `w x h` with the barcode of `n` (cells at `level`) in the bottom rows.
    fn picture(n: u32, level: u8, w: usize, h: usize) -> Vec<u8> {
        let mut px = vec![40u8; w * h * 4];
        for y in h - h / 64 - 1..h {
            for x in 0..w {
                let on = (n >> (x * 16 / w)) & 1 == 1;
                let v = if on { level } else { 0 };
                px[(y * w + x) * 4..(y * w + x) * 4 + 3].fill(v);
            }
        }
        px
    }

    #[test]
    fn the_barcode_is_read_at_any_size_and_opacity() {
        for (w, h) in [(1920, 1080), (480, 270)] {
            for level in [255u8, 128] {
                for n in [0u32, 1, 599, 0x5555, 0xFFFF & 0xA5A5] {
                    let n_expected = n;
                    assert_eq!(
                        read_barcode(&picture(n, level, w, h), w as u32, h as u32),
                        Some(n_expected),
                        "{n} {level} {w}"
                    );
                }
            }
        }
        assert_eq!(read_barcode(&[0; 16], 2, 2), None);
    }
}
