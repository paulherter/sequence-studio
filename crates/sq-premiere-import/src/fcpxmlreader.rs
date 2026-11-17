// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: FCPXMLReader.swift. FCPXML 1.x (Final Cut Pro X and compatible exporters) -> `IXSequence`: the first project's
//! sequence, its primary storyline (asset clips, clips, video / audio items, gaps, cross dissolves), connected clips
//! (lane > 0 on video tracks above, lane < 0 and the audio of video clips on audio tracks), retiming from `timeMap`, and
//! markers. Titles, compound / multicam clips and generators are dropped into the report.

use crate::edlreader::EDLReader;
use crate::interchange_model::{IXClip, IXMarker, IXSequence, IXTrack, IXTransition, InterchangeError};
use crate::interchange_xml::{self, IxNodeExt, last_path_component, path_from_url, trim_blanks};
use crate::primport_report::{PRImportReport, Status};
use sq_core_model::{ClipSpeed, SpeedKeys, SpeedSegment, TrackKind, TransitionAlignment, TransitionKind};
use sq_core_time::Time;
use sq_prproj_reader::Node;
use std::collections::{HashMap, HashSet};

struct Asset {
    name: String,
    path: String,
    start: Time,
    duration: Option<Time>,
    has_video: bool,
    has_audio: bool,
}

fn attr<'a>(n: &'a Node, k: &str) -> Option<&'a str> {
    n.attributes.get(k).map(String::as_str)
}

fn attr_opt<'a>(n: Option<&'a Node>, k: &str) -> Option<&'a str> {
    n.and_then(|n| attr(n, k))
}

/// Reads FCPXML.
pub struct FCPXMLReader;

impl FCPXMLReader {
    /// "1001/30000s", "5s", "0s" (also a plain decimal such as "2.5s") as a rational.
    pub(crate) fn time(s: Option<&str>) -> Option<Time> {
        let t = trim_blanks(s?);
        if t.is_empty() {
            return None;
        }
        let t = t.strip_suffix('s').unwrap_or(t);
        let parts: Vec<&str> = t.split('/').collect();
        if parts.len() == 2
            && let (Ok(n), Ok(d)) = (parts[0].parse::<i64>(), parts[1].parse::<i64>())
            && d > 0
        {
            return Some(Time::new(n, d));
        }
        if parts.len() == 1 {
            if let Ok(n) = parts[0].parse::<i64>() {
                return Some(Time::new(n, 1));
            }
            if let Some((num, den)) = EDLReader::ratio(parts[0]) {
                return Some(Time::new(if t.starts_with('-') { -num.abs() } else { num }, den));
            }
        }
        None
    }

    /// The first project's sequence.
    pub fn read(data: &[u8], name: &str) -> Result<IXSequence, InterchangeError> {
        Self::read_all(data, name)?.into_iter().next().ok_or_else(|| InterchangeError::Malformed("no sequence".into()))
    }

    /// Every project's sequence (or, without projects, every sequence outside the resources: compound clips live there).
    pub fn read_all(data: &[u8], name: &str) -> Result<Vec<IXSequence>, InterchangeError> {
        let root = interchange_xml::parse(data)?;
        if root.name != "fcpxml" {
            return Err(InterchangeError::Unsupported("not an FCPXML file".into()));
        }
        let mut assets: HashMap<String, Asset> = HashMap::new();
        let mut formats: HashMap<&str, &Node> = HashMap::new();
        for r in root.child("resources").map(|r| r.children.iter().collect::<Vec<_>>()).unwrap_or_default() {
            let Some(id) = r.attributes.get("id") else { continue };
            match r.name.as_str() {
                "format" => {
                    formats.insert(id, r);
                }
                "asset" => {
                    let src = r
                        .attributes
                        .get("src")
                        .map(String::as_str)
                        .or_else(|| r.child("media-rep").and_then(|m| m.attributes.get("src").map(String::as_str)))
                        .unwrap_or("");
                    let path = path_from_url(src);
                    assets.insert(
                        id.clone(),
                        Asset {
                            name: r.attributes.get("name").cloned().unwrap_or_else(|| last_path_component(&path)),
                            path,
                            start: Self::time(r.attributes.get("start").map(String::as_str)).unwrap_or(Time::ZERO),
                            duration: Self::time(r.attributes.get("duration").map(String::as_str)),
                            has_video: r.attributes.get("hasVideo").map(String::as_str) != Some("0"),
                            has_audio: r.attributes.get("hasAudio").map(String::as_str) != Some("0"),
                        },
                    );
                }
                _ => {}
            }
        }
        let mut found: Vec<(Option<&Node>, &Node)> = Vec::new();
        for p in root.descendants_named("project") {
            if let Some(q) = p.child("sequence") {
                found.push((Some(p), q));
            }
        }
        if found.is_empty() {
            for c in root.children.iter().filter(|c| c.name != "resources") {
                for q in c.descendants_named("sequence") {
                    found.push((None, q));
                }
            }
        }
        if found.is_empty() {
            return Err(InterchangeError::Malformed("no sequence".into()));
        }
        found.into_iter().map(|(p, q)| Self::sequence(q, p, &assets, &formats, name)).collect()
    }

    fn sequence(
        sequence: &Node,
        project: Option<&Node>,
        assets: &HashMap<String, Asset>,
        formats: &HashMap<&str, &Node>,
        name: &str,
    ) -> Result<IXSequence, InterchangeError> {
        let format = sequence.attributes.get("format").and_then(|f| formats.get(f.as_str()).copied());
        let fd = Self::time(attr_opt(format, "frameDuration")).unwrap_or(Time::new(1, 25));
        let mut seq = IXSequence::new(
            attr_opt(project, "name").filter(|s| !s.is_empty()).unwrap_or(name),
            fd,
            attr_opt(format, "width").and_then(|w| w.parse().ok()).unwrap_or(1920),
            attr_opt(format, "height").and_then(|h| h.parse().ok()).unwrap_or(1080),
        );
        let spine = sequence.child("spine").ok_or_else(|| InterchangeError::Malformed("no spine".into()))?;
        let mut w = Walker {
            assets,
            fd,
            tc_start: Self::time(sequence.attributes.get("tcStart").map(String::as_str)).unwrap_or(Time::ZERO),
            video: Vec::new(),
            audio: Vec::new(),
            markers: Vec::new(),
            report: PRImportReport::default(),
            pending: None,
            last_primary: None,
        };
        w.spine(spine);
        seq.tracks = w.video.into_iter().chain(w.audio).collect();
        seq.markers = w.markers;
        for e in w.report.entries() {
            for _ in 0..e.count {
                seq.report.note(&e.feature, e.status, &e.note);
            }
        }
        Ok(seq)
    }

    /// The one file channel (0-based) an `audio-channel-source` picks, from `srcCh="2"`. `None` when none is given, when it
    /// lists several channels (stereo and pairs play as the file does), or when several different active ones are named.
    pub(crate) fn source_channel(n: &Node) -> Option<i64> {
        let mut channels: Vec<i64> = Vec::new();
        for a in n
            .kids("audio-channel-source")
            .into_iter()
            .filter(|a| a.attributes.get("active").map(String::as_str) != Some("0"))
        {
            let list: Vec<i64> = a
                .attributes
                .get("srcCh")
                .map_or("", String::as_str)
                .split(',')
                .filter(|s| !s.is_empty())
                .filter_map(|s| trim_blanks(s).parse().ok())
                .collect();
            let [ch] = list[..] else { return None };
            if ch < 1 {
                return None;
            }
            if !channels.contains(&(ch - 1)) {
                channels.push(ch - 1);
            }
        }
        if channels.len() == 1 { channels.first().copied() } else { None }
    }

    /// A timeMap with three or more points as a speed track: one constant segment per point pair (FCP keys are linear in
    /// media time, so the segments are exact), boundaries on whole frames, the length of the clip. `None` when a pair is
    /// a freeze or runs backwards in time: the caller then plays the average speed.
    pub(crate) fn speed_keys(
        points: &[(Time, Time)],
        duration: Time,
        fd: Time,
        asset_start: Time,
    ) -> Option<SpeedKeys> {
        let total = duration.snapped(fd);
        let first = points.first()?;
        if total <= Time::ZERO {
            return None;
        }
        let mut segments: Vec<SpeedSegment> = Vec::new();
        let mut cursor = Time::ZERO;
        let mut speeds: HashSet<ClipSpeed> = HashSet::new();
        for (a, b) in points.iter().zip(points.iter().skip(1)) {
            let dt = b.0 - a.0;
            let dv = b.1 - a.1;
            if dt <= Time::ZERO || dv == Time::ZERO {
                return None;
            }
            let end = std::cmp::min((b.0 - first.0).snapped(fd), total);
            if end <= cursor {
                continue;
            }
            let speed = ClipSpeed::from_source_over(if dv < Time::ZERO { Time::ZERO - dv } else { dv }, dt);
            speeds.insert(speed);
            segments.push(SpeedSegment::constant(end - cursor, speed, dv < Time::ZERO));
            cursor = end;
            if cursor >= total {
                break;
            }
        }
        if segments.is_empty() {
            return None;
        }
        if cursor < total
            && let Some(last) = segments.last_mut()
        {
            // The map ends before the clip does: the last speed goes on.
            last.duration += total - cursor;
        }
        let both_directions = segments.iter().any(|s| s.reversed) && segments.iter().any(|s| !s.reversed);
        if speeds.len() <= 1 && !both_directions {
            return None; // one constant speed: plain speed fields
        }
        let origin = first.1 - asset_start;
        Some(SpeedKeys::new(segments, if origin < Time::ZERO { Time::ZERO } else { origin }))
    }
}

struct Walker<'a> {
    assets: &'a HashMap<String, Asset>,
    fd: Time,
    tc_start: Time,
    video: Vec<IXTrack>,
    audio: Vec<IXTrack>,
    markers: Vec<IXMarker>,
    report: PRImportReport,
    /// A transition waiting for the next primary clip: lane, outgoing clip, duration, name.
    pending: Option<(usize, usize, Time, String)>,
    last_primary: Option<(usize, usize)>,
}

impl Walker<'_> {
    fn place(&mut self, kind: TrackKind, preferred: i64, start: Time, end: Time) -> usize {
        let mut lane = preferred.max(0) as usize;
        loop {
            let lanes = if kind == TrackKind::Video { &mut self.video } else { &mut self.audio };
            while lanes.len() <= lane {
                lanes.push(IXTrack::new(kind));
            }
            if !lanes[lane].clips.iter().any(|c| c.start < end && start < c.end()) {
                return lane;
            }
            lane += 1;
        }
    }

    fn spine(&mut self, s: &Node) {
        for n in &s.children {
            if n.name == "transition" {
                let Some(d) = FCPXMLReader::time(n.attributes.get("duration").map(String::as_str)) else { continue };
                // Joined to the clips on either side when the next clip arrives.
                if let Some((lane, index)) = self.last_primary {
                    self.pending = Some((lane, index, d, n.attributes.get("name").cloned().unwrap_or_default()));
                }
                continue;
            }
            let Some(off) = FCPXMLReader::time(n.attributes.get("offset").map(String::as_str)) else { continue };
            let pos = if off >= self.tc_start { off - self.tc_start } else { off };
            self.item(n, pos, 0, true);
        }
    }

    fn item(&mut self, n: &Node, pos: Time, lane: i64, primary: bool) {
        let duration = FCPXMLReader::time(attr(n, "duration")).unwrap_or(Time::ZERO);
        let local_start = FCPXMLReader::time(attr(n, "start")).unwrap_or(Time::ZERO);
        match n.name.as_str() {
            "asset-clip" | "clip" | "video" | "audio" => {
                if duration > Time::ZERO {
                    self.media(n, pos, lane, primary, duration);
                }
            }
            "gap" => {}
            "title" | "caption" => self.report.note("Title", Status::Dropped, "titles are not read from FCPXML"),
            "ref-clip" | "mc-clip" | "sync-clip" => {
                self.report.note("Compound or multicam clip", Status::Dropped, "not read from FCPXML")
            }
            _ => return,
        }
        for c in &n.children {
            match c.name.as_str() {
                "marker" | "chapter-marker" => {
                    let Some(s) = FCPXMLReader::time(attr(c, "start")) else { continue };
                    let at = pos + (s - local_start);
                    if at < Time::ZERO {
                        continue;
                    }
                    let duration = if c.name == "marker" {
                        FCPXMLReader::time(attr(c, "duration")).filter(|d| *d > self.fd).unwrap_or(Time::ZERO)
                    } else {
                        Time::ZERO
                    };
                    self.markers.push(IXMarker {
                        time: at,
                        name: attr(c, "value").unwrap_or("").to_string(),
                        comment: attr(c, "note").unwrap_or("").to_string(),
                        duration,
                        color: None,
                    });
                }
                _ => {
                    let Some(l) = attr(c, "lane").and_then(|l| l.parse::<i64>().ok()).filter(|&l| l != 0) else {
                        continue;
                    };
                    let Some(o) = FCPXMLReader::time(attr(c, "offset")) else { continue };
                    self.item(c, pos + (o - local_start), l, false);
                }
            }
        }
    }

    fn media(&mut self, n: &Node, pos: Time, lane: i64, primary: bool, duration: Time) {
        // A `clip` container holds its media as a video / audio child.
        let mut carrier = n;
        if n.name == "clip" {
            let Some(inner) = n
                .children
                .iter()
                .find(|c| (c.name == "video" || c.name == "audio") && c.attributes.contains_key("ref"))
            else {
                self.report.note("Clip without media", Status::Dropped, "");
                return;
            };
            carrier = inner;
        }
        let Some(asset) = attr(carrier, "ref").and_then(|r| self.assets.get(r)) else {
            self.report.note("Generator", Status::Dropped, "effects, solids and generators are not read from FCPXML");
            return;
        };
        if attr(n, "enabled") == Some("0") {
            self.report.note("Disabled clip", Status::Dropped, "");
            return;
        }
        let fd = self.fd;
        let clip_start = FCPXMLReader::time(attr(n, "start"))
            .or_else(|| FCPXMLReader::time(attr(carrier, "start")))
            .unwrap_or(asset.start);
        let mut source_in = clip_start - asset.start;
        let mut speed = ClipSpeed::NORMAL;
        let mut reversed = false;
        let mut duration = duration;
        let mut keys: Option<SpeedKeys> = None;
        if let Some(map) = n.child("timeMap") {
            let pts: Vec<(Time, Time)> = map
                .kids("timept")
                .into_iter()
                .filter_map(|p| Some((FCPXMLReader::time(attr(p, "time"))?, FCPXMLReader::time(attr(p, "value"))?)))
                .collect();
            let smooth = map.kids("timept").into_iter().any(|p| attr(p, "interp").unwrap_or("linear") != "linear");
            let ramp = if pts.len() > 2 { FCPXMLReader::speed_keys(&pts, duration, fd, asset.start) } else { None };
            if let Some(k) = ramp {
                duration = k.duration();
                source_in = k.hull().start;
                keys = Some(k);
                self.report.note(
                    "Speed",
                    if smooth { Status::Approximated } else { Status::Mapped },
                    if smooth { "eased ramp imported as constant steps" } else { "speed ramp imported as retime keys" },
                );
            } else if let (Some(a), Some(b)) = (pts.first(), pts.last())
                && b.0 > a.0
                && b.1 != a.1
            {
                let dv = b.1 - a.1;
                let dt = b.0 - a.0;
                reversed = dv < Time::ZERO;
                speed = ClipSpeed::from_source_over(if reversed { -dv } else { dv }, dt);
                source_in = std::cmp::min(a.1, b.1) - asset.start;
                self.report.note(
                    "Speed",
                    if pts.len() > 2 { Status::Approximated } else { Status::Mapped },
                    if pts.len() > 2 { "speed ramp played at its average speed" } else { "" },
                );
            }
        }
        if source_in < Time::ZERO {
            source_in = Time::ZERO;
        }
        let name = attr(n, "name").unwrap_or(&asset.name);
        let mut clip = IXClip::new(name, &asset.path, Some(&asset.name), pos, duration, source_in);
        clip.speed = speed;
        clip.reversed = reversed;
        clip.media_duration = asset.duration;
        clip.speed_keys = keys;
        let audio_only = n.name == "audio" || carrier.name == "audio" || !asset.has_video;
        if !audio_only {
            let l = self.place(TrackKind::Video, lane, pos, pos + duration);
            self.video[l].clips.push(clip.clone());
            let idx = self.video[l].clips.len() - 1;
            if primary {
                if let Some((_, p_out, p_dur, p_name)) = self.pending.take().filter(|p| p.0 == l && p.1 < idx) {
                    self.video[l].transitions.push(IXTransition {
                        kind: TransitionKind::CrossDissolve,
                        duration: p_dur,
                        alignment: TransitionAlignment::Center,
                        outgoing: Some(p_out),
                        incoming: Some(idx),
                    });
                    if !p_name.is_empty() && !p_name.to_lowercase().contains("dissolve") {
                        self.report.note(
                            &format!("Transition {p_name}"),
                            Status::Approximated,
                            "played as Cross Dissolve",
                        );
                    }
                }
                self.pending = None;
                self.last_primary = Some((l, idx));
            }
        }
        // A `video` element is the picture alone (the writer emits it when the sound is not on the timeline).
        if audio_only || (asset.has_audio && n.name != "video" && carrier.name != "video") {
            let l = self.place(TrackKind::Audio, lane.abs(), pos, pos + duration);
            let mut sound = clip;
            sound.source_channel = FCPXMLReader::source_channel(n).or_else(|| FCPXMLReader::source_channel(carrier));
            self.audio[l].clips.push(sound);
        }
    }
}
