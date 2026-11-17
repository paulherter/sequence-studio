// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: AnimatedImage.swift
//! Animated GIF / APNG / WebP and numbered image sequences become a clip without any project-file field. Swift renders
//! the frames once into a cached ProRes 4444 strip (alpha straight) that the normal video path plays. This module holds
//! the portable rules: browser frame timing, straight-alpha conversion, the strip cache key and the sequence grouping.
//! The strip writer and `probe_animated` live in sq-media-ffmpeg (`animated`); the portable rules stay here.

use sq_core_time::{Time, sha256_digest};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Longest side of a strip frame; larger pictures are scaled down.
pub const MAX_DIMENSION: i64 = 2048;
/// Default frame rate of an image sequence.
pub const DEFAULT_SEQUENCE_FPS: i64 = 30;

/// Frame count and per-frame delays of an animation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Info {
    pub delays: Vec<Time>,
}

impl Info {
    pub fn count(&self) -> usize {
        self.delays.len()
    }

    pub fn duration(&self) -> Time {
        self.delays.iter().fold(Time::ZERO, |a, d| a + *d)
    }
}

/// Browser rule: a missing, zero or <= 10 ms delay plays at 100 ms.
pub fn frame_duration(seconds: Option<f64>) -> Time {
    match seconds {
        Some(s) if s > 0.01 => Time::new((s * 1000.0).round() as i64, 1000),
        _ => Time::new(100, 1000),
    }
}

/// `Info` of a file with these per-frame delays (seconds, None = unspecified); None for single-frame images.
pub fn info(delays: &[Option<f64>]) -> Option<Info> {
    (delays.len() > 1).then(|| Info { delays: delays.iter().map(|d| frame_duration(*d)).collect() })
}

/// In-place conversion of premultiplied BGRA to straight alpha (what ProRes 4444 alpha is tagged as).
pub fn unpremultiply(bgra: &mut [u8]) {
    for p in bgra.as_chunks_mut::<4>().0.iter_mut() {
        let a = i32::from(p[3]);
        if a == 255 {
            continue;
        }
        if a == 0 {
            p[0] = 0;
            p[1] = 0;
            p[2] = 0;
            continue;
        }
        for c in &mut p[..3] {
            *c = ((i32::from(*c) * 255 + a / 2) / a).min(255) as u8;
        }
    }
}

/// Cache file for a source description (paths with size and date, so an edited file gets a new strip):
/// `<cache>/<first 10 digest bytes as hex>.mov`.
pub fn strip_path(key_parts: &[String], cache: &Path) -> PathBuf {
    let d = sha256_digest::hash(key_parts.join("|").as_bytes());
    let hex: String = d.iter().take(10).map(|b| format!("{b:02x}")).collect();
    cache.join(format!("{hex}.mov"))
}

/// Render formats only: camera photos (IMG_0001.jpg ...) are numbered too but are not frames.
const SEQUENCE_EXTENSIONS: [&str; 6] = ["png", "tif", "tiff", "exr", "dpx", "tga"];

struct Part {
    path: PathBuf,
    prefix: String,
    digits: String,
    number: u64,
    ext: String,
}

fn part(path: &Path) -> Option<Part> {
    let ext = path.extension()?.to_string_lossy().to_lowercase();
    if !SEQUENCE_EXTENSIONS.contains(&ext.as_str()) {
        return None;
    }
    let stem = path.file_stem()?.to_string_lossy().into_owned();
    let digits: String =
        stem.chars().rev().take_while(char::is_ascii_digit).collect::<Vec<_>>().into_iter().rev().collect();
    if digits.is_empty() || digits.len() > 9 {
        return None;
    }
    let number = digits.parse().ok()?;
    let prefix = stem[..stem.len() - digits.len()].to_string();
    Some(Part { path: path.to_path_buf(), prefix, digits, number, ext })
}

/// Runs of at least `min_count` (two) consecutively numbered files with the same folder, name and type, in frame order.
pub fn sequence_groups(paths: &[PathBuf], min_count: usize) -> Vec<Vec<PathBuf>> {
    let mut buckets: BTreeMap<String, Vec<Part>> = BTreeMap::new();
    for p in paths {
        if let Some(x) = part(p) {
            let dir = p.parent().map(|d| d.to_string_lossy().into_owned()).unwrap_or_default();
            buckets.entry(format!("{dir}\0{}\0{}", x.prefix, x.ext)).or_default().push(x);
        }
    }
    let mut out: Vec<(String, Vec<PathBuf>)> = Vec::new();
    for (key, mut parts) in buckets {
        parts.sort_by_key(|p| p.number);
        let mut run: Vec<&Part> = Vec::new();
        let mut flush = |run: &mut Vec<&Part>| {
            if run.len() >= min_count.max(2) {
                out.push((format!("{key}{:012}", run[0].number), run.iter().map(|p| p.path.clone()).collect()));
            }
            run.clear();
        };
        for p in &parts {
            if run.last().is_some_and(|l| p.number != l.number + 1) {
                flush(&mut run);
            }
            run.push(p);
        }
        flush(&mut run);
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out.into_iter().map(|g| g.1).collect()
}

/// "fx_[001-004].png"
pub fn sequence_display_name(frames: &[PathBuf]) -> String {
    let (Some(f), Some(l)) = (frames.first().and_then(|p| part(p)), frames.last().and_then(|p| part(p))) else {
        return frames
            .first()
            .and_then(|p| p.file_name())
            .map_or("Sequence".into(), |n| n.to_string_lossy().into_owned());
    };
    let ext = frames[0].extension().map(|e| e.to_string_lossy().into_owned()).unwrap_or_default();
    format!("{}[{}-{}].{}", f.prefix, f.digits, l.digits, ext)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(n: &str) -> PathBuf {
        PathBuf::from("/tmp/x").join(n)
    }

    fn names(g: &[PathBuf]) -> Vec<String> {
        g.iter().map(|p| p.file_name().unwrap().to_string_lossy().into_owned()).collect()
    }

    #[test]
    fn delay_is_clamped_like_browsers() {
        assert_eq!(frame_duration(Some(0.2)), Time::new(200, 1000));
        assert_eq!(frame_duration(Some(0.0)), Time::new(100, 1000));
        assert_eq!(frame_duration(Some(0.01)), Time::new(100, 1000));
        assert_eq!(frame_duration(None), Time::new(100, 1000));
        assert_eq!(frame_duration(Some(0.033)), Time::new(33, 1000));
    }

    #[test]
    fn info_of_three_frames_and_of_a_still() {
        let i = info(&[Some(0.1), Some(0.2), Some(0.1)]).expect("animated");
        assert_eq!(i.count(), 3);
        assert_eq!(i.delays, vec![Time::new(100, 1000), Time::new(200, 1000), Time::new(100, 1000)]);
        assert_eq!(i.duration(), Time::new(400, 1000));
        assert!(info(&[Some(0.1)]).is_none());
    }

    #[test]
    fn sequence_groups_numbered_files() {
        let urls = [u("fx_0003.png"), u("fx_0001.png"), u("fx_0002.png"), u("photo.png"), u("other_1.png")];
        let g = sequence_groups(&urls, 2);
        assert_eq!(g.len(), 1);
        assert_eq!(names(&g[0]), ["fx_0001.png", "fx_0002.png", "fx_0003.png"]);
    }

    #[test]
    fn sequence_splits_at_gaps_and_mixed_extensions() {
        let urls = [u("a1.png"), u("a2.png"), u("a5.png"), u("a6.png"), u("a7.png"), u("a8.jpg"), u("b.png")];
        let g: Vec<Vec<String>> = sequence_groups(&urls, 2).iter().map(|x| names(x)).collect();
        assert_eq!(g, vec![vec!["a1.png", "a2.png"], vec!["a5.png", "a6.png", "a7.png"]]);
    }

    #[test]
    fn single_numbered_file_is_not_a_sequence() {
        assert!(sequence_groups(&[u("shot_01.png")], 2).is_empty());
        assert!(sequence_groups(&[u("a1.mov"), u("a2.mov")], 2).is_empty());
    }

    #[test]
    fn display_name_shows_the_range() {
        let f: Vec<PathBuf> = (1..=4).map(|i| u(&format!("fx_{i:03}.png"))).collect();
        assert_eq!(sequence_display_name(&f), "fx_[001-004].png");
    }

    #[test]
    fn straight_alpha_conversion() {
        let mut px = [64u8, 32, 16, 128, 10, 20, 30, 0, 200, 100, 50, 255]; // BGRA premultiplied
        unpremultiply(&mut px);
        assert!(
            (i32::from(px[0]) - 127).abs() <= 1
                && (i32::from(px[1]) - 64).abs() <= 1
                && (i32::from(px[2]) - 32).abs() <= 1
                && px[3] == 128
        );
        assert_eq!(&px[4..8], &[0, 0, 0, 0]);
        assert!(px[8] == 200 && px[11] == 255);
    }

    #[test]
    fn strip_path_depends_on_the_key_and_stays_in_the_cache() {
        let c = Path::new("/cache");
        let a = strip_path(&["anim".into(), "/a.gif:10:1".into()], c);
        let b = strip_path(&["anim".into(), "/a.gif:11:1".into()], c);
        assert_ne!(a, b);
        assert_eq!(a, strip_path(&["anim".into(), "/a.gif:10:1".into()], c));
        assert!(a.starts_with(c) && a.extension().is_some_and(|e| e == "mov") && a.file_stem().unwrap().len() == 20);
    }
}
