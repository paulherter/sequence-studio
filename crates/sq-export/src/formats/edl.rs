// SPDX-License-Identifier: GPL-3.0-or-later
//! CMX3600 EDL of a sequence: the first video track as `V` events, every audio track as `A` / `A2` ... events, record
//! timecode starting at the sequence's timecode start, source timecode as media time. Dissolves are a zero-length cut
//! plus a `D` event. Constant speed and reverse go into an `M2` line. Markers become `* LOC:`. Layers, effects, titles
//! and nested sequences are skipped and listed in the warnings. A video track above V1 is not in this file:
//! `layer_files` renders one more EDL per such track.

use super::{InterchangeExport, Warnings, frames_rounded, is_swift_whitespace, usable, usable_quiet, written_speed};
use sq_core_edit::clip_markers::ClipMarkersExt;
use sq_core_model::{
    Clip, ClipSpeed, MarkerColor, MediaRef, Timeline, Track, TrackKind, TransitionAlignment, TransitionKind,
};
use sq_core_time::{CmxTimecode, Time};
use std::collections::HashMap;

/// EDL writer.
pub struct EdlWriter;

/// Video tracks above V1 that hold at least one clip an EDL can carry: label ("V2" = second video track) and its file.
pub fn layer_files(timeline: &Timeline, media: &[MediaRef]) -> Vec<(String, InterchangeExport)> {
    let mut out = Vec::new();
    for (index, t) in timeline.tracks.iter().filter(|t| t.kind == TrackKind::Video).enumerate() {
        if index > 0 && t.clips().iter().any(usable_quiet) {
            out.push((format!("V{}", index + 1), EdlWriter::render_layer(timeline, media, index)));
        }
    }
    out
}

/// Source in / out (in frames) and the M2 rate of a clip.
struct Source {
    in_f: i64,
    out_f: i64,
    fps: Option<String>,
}

struct Render<'a> {
    fd: Time,
    tc: CmxTimecode,
    base: i64,
    paths: HashMap<sq_core_time::Id, &'a str>,
    w: Warnings,
    out: Vec<String>,
    number: i64,
}

impl Render<'_> {
    fn frames(&self, t: Time) -> i64 {
        frames_rounded(t, self.fd)
    }

    fn stamp(&self, f: i64) -> String {
        self.tc.string(f)
    }

    /// One event line; `src` and `rec` are (in, out) frames, the record side is shifted by the timecode start.
    fn event(&self, n: i64, track: &str, kind: &str, src: (i64, i64), rec: (i64, i64)) -> String {
        let stamps =
            [self.stamp(src.0), self.stamp(src.1), self.stamp(rec.0 + self.base), self.stamp(rec.1 + self.base)];
        format!("{n:03}  {} {} {} {}", pad("AX", 8), pad(track, 5), pad(kind, 8), stamps.join(" "))
    }

    fn source(&mut self, c: &Clip) -> Source {
        if let Some(h) = c.hold_frame {
            let f = self.frames(h);
            return Source { in_f: f, out_f: f, fps: Some("000.0".to_string()) };
        }
        let (speed, reversed) = written_speed(c, &mut self.w);
        let a = self.frames(c.source.start);
        let b = self.frames(c.source.end());
        let rate = if speed.is_normal() && !reversed { None } else { Some(fps(speed, self.fd, reversed)) };
        if reversed { Source { in_f: b, out_f: a, fps: rate } } else { Source { in_f: a, out_f: b, fps: rate } }
    }

    fn m2(&self, rate: &str, src_in: i64) -> String {
        format!("M2   AX       {} {}", pad(rate, 20), self.tc.string(src_in))
    }

    fn comments(&mut self, c: &Clip, to: bool) {
        self.out.push(format!("{}{}", if to { "* TO CLIP NAME: " } else { "* FROM CLIP NAME: " }, clean(&c.name)));
        if let Some(p) = self.paths.get(&c.media).filter(|p| !p.is_empty()) {
            self.out.push(format!("* SOURCE FILE: {}", clean(p)));
        }
    }

    /// The events of one track: `spec` is the track column ("V", "A", "A2" ...).
    fn track_events(&mut self, t: &Track, clips: &[&Clip], spec: &str, video: bool) {
        let mut previous: Option<&Clip> = None;
        for &c in clips {
            self.number += 1;
            let n = self.number;
            let s = self.source(c);
            let ri = self.frames(c.start);
            let ro = self.frames(c.timeline().end());
            let tr = previous.and_then(|p| {
                let tr = t.transitions.iter().find(|tr| tr.incoming == Some(c.id) && tr.outgoing == Some(p.id))?;
                (p.timeline().end() == c.start && p.generator.is_none()).then_some((p, tr))
            });
            if let Some((p, tr)) = tr {
                let dur = self.frames(tr.duration).max(1);
                let prior = self.source(p);
                self.out.push(self.event(n, spec, "C", (prior.out_f, prior.out_f), (ri, ri)));
                self.comments(p, false);
                self.out.push(self.event(n, spec, &format!("D    {dur:03}"), (s.in_f, s.out_f), (ri, ro)));
                if let Some(r) = &s.fps {
                    self.out.push(self.m2(r, s.in_f));
                }
                self.comments(c, true);
                if video && tr.kind != TransitionKind::CrossDissolve {
                    self.w.warn(format!("Transition \"{}\" written as a dissolve", super::raw_name(&tr.kind)));
                }
                if tr.alignment != TransitionAlignment::StartAtCut {
                    self.w.warn("Dissolves are written starting at the cut");
                }
            } else {
                self.out.push(self.event(n, spec, "C", (s.in_f, s.out_f), (ri, ro)));
                if let Some(r) = &s.fps {
                    self.out.push(self.m2(r, s.in_f));
                }
                self.comments(c, false);
            }
            previous = Some(c);
        }
    }
}

impl EdlWriter {
    /// The sequence EDL: V1, all audio, markers.
    pub fn render(timeline: &Timeline, media: &[MediaRef]) -> InterchangeExport {
        Self::render_layer(timeline, media, 0)
    }

    /// `video_layer` 0 = the sequence EDL (V1, all audio, markers). N > 0 = only the Nth video track, as `V`, no audio.
    pub fn render_layer(timeline: &Timeline, media: &[MediaRef], video_layer: usize) -> InterchangeExport {
        let fd = timeline.format.frame_duration;
        let tc = CmxTimecode::from_frame_duration(fd, true);
        let mut paths = HashMap::new();
        for m in media {
            paths.entry(m.id).or_insert(m.path.as_str());
        }
        let mut r = Render {
            fd,
            tc,
            base: frames_rounded(timeline.timecode_start(), fd),
            paths,
            w: Warnings::default(),
            out: Vec::new(),
            number: 0,
        };
        let layer_suffix = if video_layer > 0 { format!(" V{}", video_layer + 1) } else { String::new() };
        r.out.push(format!("TITLE: {}{layer_suffix}", clean(&timeline.name)));
        r.out.push(format!("FCM: {}", if tc.drop_frame() { "DROP FRAME" } else { "NON-DROP FRAME" }));
        r.out.push(String::new());

        let (mut video_index, mut audio_index) = (0usize, 0usize);
        for t in &timeline.tracks {
            let clips: Vec<&Clip> = t.clips().iter().filter(|c| usable(c, &mut r.w)).collect();
            if t.kind == TrackKind::Video {
                let this = video_index;
                video_index += 1;
                if this != video_layer {
                    if video_layer == 0 && !clips.is_empty() {
                        r.w.warn("Video tracks above V1 are not in this EDL (an EDL has one video track): one more EDL is written per layer");
                    }
                    continue;
                }
                r.track_events(t, &clips, "V", true);
                if t.transitions.iter().any(|tr| tr.outgoing.is_none() || tr.incoming.is_none()) {
                    r.w.warn("Fade at a clip edge is not exported");
                }
            } else {
                if video_layer > 0 {
                    continue;
                }
                let lane = audio_index;
                audio_index += 1;
                let spec = if lane == 0 { "A".to_string() } else { format!("A{}", lane + 1) };
                r.track_events(t, &clips, &spec, false);
                if t.transitions.iter().any(|tr| tr.outgoing.is_none() || tr.incoming.is_none()) {
                    r.w.warn("Audio fade at a clip edge is not exported");
                }
            }
        }
        // Clip markers are written where the clip shows them (an EDL has no marker on a clip).
        let mut markers: Vec<(Time, MarkerColor, String)> = Vec::new();
        if video_layer == 0 {
            markers.extend(timeline.markers.iter().map(|m| (m.time, m.color, m.name.clone())));
            for t in &timeline.tracks {
                for c in t.clips().iter().filter(|c| usable_quiet(c)) {
                    markers.extend(c.visible_markers(fd).into_iter().map(|m| (c.start + m.time, m.color, m.name)));
                }
            }
        }
        markers.sort_by_key(|m| m.0);
        for (time, marker_color, name) in markers {
            let stamp = r.stamp(r.frames(time) + r.base);
            r.out.push(format!("* LOC: {stamp} {} {}", color(marker_color), clean(&name)));
        }
        if r.number == 0 {
            r.w.warn("The sequence has no clips an EDL can carry");
        }
        InterchangeExport::new(r.out.join("\n") + "\n", r.w.0)
    }
}

fn pad(s: &str, n: usize) -> String {
    let len = s.chars().count();
    if len >= n { s.to_string() } else { format!("{s}{}", " ".repeat(n - len)) }
}

/// One line, no control characters.
fn clean(s: &str) -> String {
    let replaced: String = s.chars().map(|c| if (c as u32) < 32 { ' ' } else { c }).collect();
    replaced.trim_matches(is_swift_whitespace).to_string()
}

fn color(c: MarkerColor) -> &'static str {
    match c {
        MarkerColor::Red => "RED",
        MarkerColor::Green => "GREEN",
        MarkerColor::Blue => "BLUE",
        MarkerColor::Cyan => "CYAN",
        MarkerColor::Purple => "MAGENTA",
        MarkerColor::Yellow | MarkerColor::Orange => "YELLOW",
        MarkerColor::White => "WHITE",
    }
}

/// Frames per second the clip plays at (speed x sequence rate), exact to 6 decimals: "050.0", "-029.97003".
fn fps(speed: ClipSpeed, fd: Time, reversed: bool) -> String {
    let den = i128::from(speed.den()) * i128::from(fd.value().max(1));
    let scaled = (i128::from(speed.num()) * i128::from(fd.timescale()) * 1_000_000 + den / 2) / den.max(1);
    let (whole, frac) = (scaled / 1_000_000, scaled % 1_000_000);
    let mut f = format!("{frac:06}");
    while f.len() > 1 && f.ends_with('0') {
        f.pop();
    }
    let w = whole.to_string();
    format!("{}{}{w}.{f}", if reversed { "-" } else { "" }, "0".repeat(3usize.saturating_sub(w.len())))
}

#[cfg(test)]
mod fps_tests {
    use super::*;

    #[test]
    fn fps_text_is_padded_and_trimmed() {
        assert_eq!(fps(ClipSpeed::new(2, 1), Time::new(1, 25), false), "050.0");
        assert_eq!(fps(ClipSpeed::new(1, 1), Time::new(1001, 30_000), true), "-029.97003");
    }
}
