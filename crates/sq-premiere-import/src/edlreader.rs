// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: EDLReader.swift. CMX3600 EDL -> `IXSequence`. An EDL carries no frame rate and (usually) no media paths: the
//! rate comes from the caller, the clips are named by `* FROM CLIP NAME:` / `* SOURCE FILE:` comments and come in offline
//! until relinked. Source timecode is taken as media time (the media is assumed to start at 00:00:00:00). Record timecode
//! that begins in hour 1 or later (the 01:00:00:00 convention) has that whole-hour offset removed.

use crate::interchange_model::{IXClip, IXMarker, IXSequence, IXTrack, IXTransition, InterchangeError};
use crate::interchange_xml::{last_path_component, trim_blanks};
use crate::primport_report::Status;
use sq_core_model::{ClipSpeed, TrackKind, TransitionAlignment, TransitionKind};
use sq_core_time::{CmxTimecode, Time};

struct Event {
    reel: String,
    track_spec: String,
    kind: String,
    transition_frames: i64,
    src_in: i64,
    rec_in: i64,
    rec_out: i64,
    motion_fps: Option<String>,
    from_name: Option<String>,
    to_name: Option<String>,
    source_file: Option<String>,
}

/// `s` without its first `n` characters.
fn drop_chars(s: &str, n: usize) -> &str {
    s.char_indices().nth(n).map_or("", |(i, _)| &s[i..])
}

/// First lane (from `preferred`) of the tracks that is free over [start, end); lanes are added as needed.
fn place(lanes: &mut Vec<IXTrack>, kind: TrackKind, preferred: usize, start: Time, end: Time) -> usize {
    let mut lane = preferred;
    loop {
        while lanes.len() <= lane {
            lanes.push(IXTrack::new(kind));
        }
        if !lanes[lane].clips.iter().any(|c| c.start < end && start < c.end()) {
            return lane;
        }
        lane += 1;
    }
}

/// Reads CMX3600 EDL text.
pub struct EDLReader;

impl EDLReader {
    /// Reads `text` as an EDL at the rate of `fd`.
    pub fn read(text: &str, name: &str, fd: Time) -> Result<IXSequence, InterchangeError> {
        let mut title: Option<String> = None;
        let mut drop = false;
        let mut events: Vec<Event> = Vec::new();
        let mut locs: Vec<(String, String)> = Vec::new();
        let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
        let lines: Vec<&str> = normalized.split('\n').filter(|l| !l.is_empty()).collect();
        // First pass: the drop-frame flag and the title must be known before any timecode is read.
        for l in &lines {
            let line = trim_blanks(l);
            let upper = line.to_uppercase();
            if upper.starts_with("FCM:") {
                drop = upper.contains("DROP") && !upper.contains("NON");
            }
            if upper.starts_with("TITLE:") {
                title = Some(trim_blanks(drop_chars(line, 6)).to_string());
            }
        }
        let tc = CmxTimecode::from_frame_duration(fd, false);
        let clock = CmxTimecode::new(tc.nominal_rate(), drop);
        let mut last: Option<usize> = None;
        for l in &lines {
            let line = trim_blanks(l);
            let tokens: Vec<&str> = line.split([' ', '\t']).filter(|t| !t.is_empty()).collect();
            let Some(&first) = tokens.first() else { continue };
            if first.starts_with('*') {
                let body = trim_blanks(drop_chars(line, 1));
                let upper = body.to_uppercase();
                if upper.starts_with("LOC:") {
                    let rest = trim_blanks(drop_chars(body, 4));
                    let parts: Vec<&str> = rest.splitn(3, ' ').filter(|p| !p.is_empty()).collect();
                    if let Some(t) = parts.first() {
                        locs.push((
                            (*t).to_string(),
                            if parts.len() > 2 { trim_blanks(parts[2]).to_string() } else { String::new() },
                        ));
                    }
                } else if let Some(i) = last {
                    let value = |prefix: &str| {
                        upper
                            .starts_with(prefix)
                            .then(|| trim_blanks(drop_chars(body, prefix.chars().count())).to_string())
                    };
                    if let Some(v) = value("FROM CLIP NAME:") {
                        events[i].from_name = Some(v);
                    } else if let Some(v) = value("TO CLIP NAME:") {
                        events[i].to_name = Some(v);
                    } else if let Some(v) = value("SOURCE FILE:") {
                        events[i].source_file = Some(v);
                    }
                }
                continue;
            }
            if first.to_uppercase() == "M2"
                && tokens.len() >= 3
                && let Some(i) = last
            {
                events[i].motion_fps = Some(tokens[2].to_string());
                continue;
            }
            // Event: number reel track type [duration] srcIn srcOut recIn recOut
            if !first.chars().all(char::is_numeric) || tokens.len() < 8 {
                continue;
            }
            let stamps: Vec<&str> = tokens.iter().copied().filter(|t| t.contains(':') || t.contains(';')).collect();
            if stamps.len() < 4 {
                continue;
            }
            let t = &stamps[stamps.len() - 4..];
            let (Some(si), Some(_), Some(ri), Some(ro)) =
                (clock.frames(t[0]), clock.frames(t[1]), clock.frames(t[2]), clock.frames(t[3]))
            else {
                continue;
            };
            let mut e = Event {
                reel: tokens[1].to_string(),
                track_spec: tokens[2].to_uppercase(),
                kind: tokens[3].to_uppercase(),
                transition_frames: 0,
                src_in: si,
                rec_in: ri,
                rec_out: ro,
                motion_fps: None,
                from_name: None,
                to_name: None,
                source_file: None,
            };
            if e.kind != "C"
                && tokens.len() > 4
                && let Ok(n) = tokens[4].parse::<i64>()
            {
                e.transition_frames = n;
            }
            events.push(e);
            last = Some(events.len() - 1);
        }
        if events.is_empty() {
            return Err(InterchangeError::Empty);
        }

        let mut seq = IXSequence::new(title.filter(|t| !t.is_empty()).as_deref().unwrap_or(name), fd, 1920, 1080);
        seq.report.note(
            "Frame rate",
            Status::Approximated,
            &format!("an EDL has no rate: {} fps clock", clock.nominal_rate()),
        );
        // Hour offset of the record side.
        let hour = clock.frames("01:00:00:00").unwrap_or(1);
        let min_rec = events.iter().filter(|e| e.rec_out > e.rec_in).map(|e| e.rec_in).min().unwrap_or(0);
        let base = if hour > 0 { (min_rec / hour) * hour } else { 0 };
        let time = |frames: i64| fd * frames;

        let mut video: Vec<IXTrack> = Vec::new();
        let mut audio: Vec<IXTrack> = Vec::new();
        for e in &events {
            let start = time(e.rec_in - base);
            let duration = time(e.rec_out - e.rec_in);
            if duration <= Time::ZERO {
                continue; // the zero-length cut that precedes a dissolve
            }
            if e.reel.to_uppercase() == "BL" {
                continue; // black
            }
            let name = e.to_name.as_ref().or(e.from_name.as_ref()).unwrap_or(&e.reel).clone();
            let key = e
                .source_file
                .clone()
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| e.from_name.as_ref().or(e.to_name.as_ref()).unwrap_or(&e.reel).clone());
            let mut speed = ClipSpeed::NORMAL;
            let mut reversed = false;
            if let Some(f) = &e.motion_fps
                && let Some((num, den)) = Self::ratio(f)
            {
                speed = ClipSpeed::new(num.abs() * fd.value(), den * fd.timescale());
                reversed = num < 0;
            }
            let mut src_in = time(e.src_in);
            if reversed {
                // the listed In is the last frame shown; the range starts below it
                src_in = std::cmp::max(src_in - speed.scale(duration), Time::ZERO);
            }
            let media_name = last_path_component(&key);
            let mut clip = IXClip::new(&name, &key, Some(&media_name), start, duration, src_in);
            clip.speed = speed;
            clip.reversed = reversed;
            let spec = e.track_spec.as_str();
            let wants_video = spec == "B" || spec.contains('V') && !spec.starts_with("NONE");
            let mut audio_lanes: Vec<usize> = Vec::new();
            if spec == "B" {
                audio_lanes = vec![0];
            } else if spec.starts_with("AA") {
                audio_lanes = vec![0, 1];
            } else if spec.starts_with('A') {
                let digits: String = spec.chars().skip(1).take_while(|c| c.is_numeric()).collect();
                audio_lanes = vec![(digits.parse::<i64>().unwrap_or(1) - 1).max(0) as usize];
            }
            if spec.contains("/V") && spec.starts_with('A') && audio_lanes.is_empty() {
                audio_lanes = vec![0];
            }
            if wants_video {
                let mut preferred = 0;
                if e.kind != "C" {
                    // A dissolve's incoming clip joins the lane of the clip it comes from.
                    if let Some(i) = video.iter().position(|t| t.clips.iter().any(|c| c.end() == start)) {
                        preferred = i;
                    }
                }
                let lane = place(&mut video, TrackKind::Video, preferred, start, clip.end());
                video[lane].clips.push(clip.clone());
                if e.kind != "C" {
                    let into = video[lane].clips.len() - 1;
                    let out = video[lane].clips.iter().position(|c| c.end() == start);
                    if e.transition_frames > 0 {
                        if e.kind.starts_with('W') {
                            seq.report.note("Wipe", Status::Approximated, "played as Cross Dissolve");
                        }
                        let mut tr = IXTransition::new(time(e.transition_frames), out, Some(into));
                        tr.alignment = TransitionAlignment::StartAtCut;
                        video[lane].transitions.push(tr);
                    }
                }
            }
            for a in audio_lanes {
                let lane = place(&mut audio, TrackKind::Audio, a, start, clip.end());
                let out = if e.kind != "C" { audio[lane].clips.iter().position(|c| c.end() == start) } else { None };
                audio[lane].clips.push(clip.clone());
                // An audio dissolve is a crossfade between the clip before and this one.
                if let Some(out) = out
                    && e.transition_frames > 0
                {
                    let mut tr =
                        IXTransition::new(time(e.transition_frames), Some(out), Some(audio[lane].clips.len() - 1));
                    tr.kind = TransitionKind::ConstantPower;
                    tr.alignment = TransitionAlignment::StartAtCut;
                    audio[lane].transitions.push(tr);
                }
            }
        }
        seq.tracks = video.into_iter().chain(audio).collect();
        seq.markers = locs
            .iter()
            .filter_map(|(tcs, text)| clock.frames(tcs).map(|f| IXMarker::new(time((f - base).max(0)), text)))
            .collect();
        Ok(seq)
    }

    /// "050.0" / "-24" / "12.5" as a rational (numerator signed, denominator a power of ten).
    pub(crate) fn ratio(s: &str) -> Option<(i64, i64)> {
        let neg = s.starts_with('-');
        let t = s.trim_matches(['+', '-']);
        let parts: Vec<&str> = t.split('.').collect();
        if parts.len() > 2 {
            return None;
        }
        let whole: i64 = (if parts[0].is_empty() { "0" } else { parts[0] }).parse().ok()?;
        let (mut frac, mut den) = (0i64, 1i64);
        if parts.len() == 2 {
            let f: String = parts[1].chars().take(6).collect();
            if !f.chars().all(char::is_numeric) {
                return None;
            }
            frac = f.parse().unwrap_or(0);
            for _ in f.chars() {
                den *= 10;
            }
        }
        let n = whole * den + frac;
        if n <= 0 {
            return None;
        }
        Some((if neg { -n } else { n }, den))
    }
}
