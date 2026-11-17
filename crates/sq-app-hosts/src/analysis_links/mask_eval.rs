// Swift: Tools/SQMaskEval (the Magic Mask scoring tool; this is the headless run of the same idea on the app's own engine)
//! Headless Magic Mask check: tracks one click through a clip with the real EdgeTAM model and, when the clip's object is
//! known (a synthetic disk), scores every frame's matte against it (IoU). Run through the app: `sequence-studio
//! --mask-eval <out.txt> <clip> --eval-click 0.25,0.5 --eval-disk 0.25,0.5,0.004,0,0.08`.

use super::ffmpeg_frames::FfmpegTrackFrames;
use super::magic_job::{EdgeTamTracker, TrackFrames, Tracker, model_folder};
use sq_analysis::mask_metrics::MaskMetrics;
use sq_core_time::{Time, Vec2};
use std::collections::HashMap;
use std::path::Path;

/// A disk in frame fractions: its center starts at `(x, y)` and moves `(vx, vy)` per frame; `r` is a share of the width.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Disk {
    /// Start center x.
    pub x: f64,
    /// Start center y.
    pub y: f64,
    /// Motion per frame, x.
    pub vx: f64,
    /// Motion per frame, y.
    pub vy: f64,
    /// Radius, share of the width.
    pub r: f64,
}

impl Disk {
    /// Parses `x,y,vx,vy,r`.
    pub fn parse(text: &str) -> Result<Disk, String> {
        let v: Vec<f64> = text
            .split(',')
            .map(|p| p.trim().parse::<f64>().map_err(|e| format!("{p}: {e}")))
            .collect::<Result<_, _>>()?;
        match v.as_slice() {
            [x, y, vx, vy, r] => Ok(Disk { x: *x, y: *y, vx: *vx, vy: *vy, r: *r }),
            _ => Err("a disk is x,y,vx,vy,r".to_string()),
        }
    }

    /// The disk at frame `i` on a `w` x `h` grid.
    pub fn truth(&self, i: usize, w: usize, h: usize) -> Vec<bool> {
        let (cx, cy) = ((self.x + self.vx * i as f64) * w as f64, (self.y + self.vy * i as f64) * h as f64);
        let r = self.r * w as f64;
        let mut out = vec![false; w * h];
        for y in 0..h {
            for x in 0..w {
                let (px, py) = (x as f64 + 0.5 - cx, y as f64 + 0.5 - cy);
                out[y * w + x] = px * px + py * py <= r * r;
            }
        }
        out
    }
}

/// Tracks `click` (frame fractions) from the first frame of `clip` to its end and reports the numbers as text. `models`: the
/// EdgeTAM folder (default: where the app looks).
pub fn run(clip: &Path, click: Vec2, disk: Option<Disk>, models: Option<&Path>) -> Result<String, String> {
    let environment: HashMap<String, String> = std::env::vars().collect();
    let folder = match models {
        Some(m) => m.to_path_buf(),
        None => model_folder(&std::env::temp_dir(), &environment)?,
    };
    let started = std::time::Instant::now();
    let mut tracker = EdgeTamTracker::load(&folder)?;
    let loaded = started.elapsed().as_secs_f64();
    let mut frames = FfmpegTrackFrames::open(clip, Time::ZERO, Time::seconds(3600))?;
    let (mut ious, mut lost) = (Vec::new(), 0usize);
    let mut size = (0usize, 0usize);
    let run_start = std::time::Instant::now();
    for i in 0..frames.count() {
        let (_, frame) = frames.frame(i).ok_or("a frame could not be read")?;
        size = (frame.width, frame.height);
        let matte = if i == 0 { tracker.start(&frame, &[(click, false)]).map(Some)? } else { tracker.next(&frame)? };
        let Some(matte) = matte else {
            lost += frames.count() - i;
            break;
        };
        if let Some(d) = disk {
            let guess: Vec<bool> = matte.values.iter().map(|v| *v > 0.5).collect();
            let truth = d.truth(i, matte.width(), matte.height());
            ious.push(MaskMetrics::jaccard(&guess, &truth));
        }
    }
    let secs = run_start.elapsed().as_secs_f64();
    let n = frames.count();
    let mut text = format!(
        "clip {}\nmodel load {loaded:.2} s, {n} frames at {}x{} in {secs:.2} s ({:.0} ms/frame), lost frames {lost}\n",
        clip.display(),
        size.0,
        size.1,
        secs * 1000.0 / n.max(1) as f64
    );
    if !ious.is_empty() {
        let mean = ious.iter().sum::<f64>() / ious.len() as f64;
        let min = ious.iter().copied().fold(f64::INFINITY, f64::min);
        text += &format!("IoU mean {mean:.3}, min {min:.3} over {} frames\n", ious.len());
    }
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_disk_is_parsed_and_rasterized() {
        let d = Disk::parse("0.5,0.5,0.05,0,0.15").expect("disk");
        let t = d.truth(0, 20, 20);
        assert!(t[10 * 20 + 10] && !t[0]);
        let moved = d.truth(4, 20, 20);
        assert!(moved[10 * 20 + 14] && !moved[10 * 20 + 6]);
        assert!(Disk::parse("1,2").is_err());
    }
}
