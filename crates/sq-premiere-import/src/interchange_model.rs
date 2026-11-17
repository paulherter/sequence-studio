// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: InterchangeModel.swift. Timeline interchange (CMX3600 EDL, Final Cut Pro 7 XML, FCPXML, OpenTimelineIO): the
//! readers produce this neutral sequence, one mapper turns it into the project model. Written from the public format
//! descriptions; no third-party code. All positions are rational `Time`, never floating point.

use crate::edlreader::EDLReader;
use crate::fcpxmlreader::FCPXMLReader;
use crate::otioreader::OTIOReader;
use crate::primport_report::PRImportReport;
use crate::prmapper::{PRImportResult, STILL_EXTENSIONS, sanitized_format};
use crate::xmemlreader::XMEMLReader;
use sq_core_audio::audio_channel_map::ProjectChannelMapExt;
use sq_core_effects::transition::TransitionExt;
use sq_core_model::AudioChannelMap;
use sq_core_model::{
    Clip, ClipSpeed, Marker, MarkerColor, MediaFingerprint, MediaRef, Project, SequenceFormat, SpeedKeys, Timeline,
    Track, TrackKind, Transition, TransitionAlignment, TransitionKind,
};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::BTreeMap;
use std::fmt;

/// A marker of an interchange file.
#[derive(Debug, Clone, PartialEq)]
pub struct IXMarker {
    pub time: Time,
    pub name: String,
    pub comment: String,
    pub duration: Time,
    /// `None` = the format has no marker colors.
    pub color: Option<MarkerColor>,
}

impl IXMarker {
    /// A point marker without comment and color.
    pub fn new(time: Time, name: &str) -> IXMarker {
        IXMarker { time, name: name.to_string(), comment: String::new(), duration: Time::ZERO, color: None }
    }
}

/// A clip of an interchange file.
#[derive(Debug, Clone, PartialEq)]
pub struct IXClip {
    pub name: String,
    /// Path (or, for an EDL without a file name, the clip / reel name) that identifies the media.
    pub media_key: String,
    pub media_name: String,
    /// Position and length on the timeline.
    pub start: Time,
    pub duration: Time,
    /// First source frame played, in media time.
    pub source_in: Time,
    pub speed: ClipSpeed,
    pub reversed: bool,
    pub media_duration: Option<Time>,
    /// A frozen frame (media time) instead of playback.
    pub hold_frame: Option<Time>,
    /// Explicit link group from the file (xmeml `<link>`): clips of one group move together. `None` = none given.
    pub link_group: Option<String>,
    /// Channel of the file this audio clip plays (0-based), from the file's own track choice. `None` = not given.
    pub source_channel: Option<i64>,
    /// A real speed track (ramps, several constant segments) from the file. `None` = `speed` / `reversed` apply. When set,
    /// `duration` equals the track's duration (whole frames) and `source_in` is ignored: the track carries its origin.
    pub speed_keys: Option<SpeedKeys>,
}

impl IXClip {
    /// A clip with normal speed; `media_name` defaults to `name`.
    pub fn new(
        name: &str,
        media_key: &str,
        media_name: Option<&str>,
        start: Time,
        duration: Time,
        source_in: Time,
    ) -> IXClip {
        IXClip {
            name: name.to_string(),
            media_key: media_key.to_string(),
            media_name: media_name.unwrap_or(name).to_string(),
            start,
            duration,
            source_in,
            speed: ClipSpeed::NORMAL,
            reversed: false,
            media_duration: None,
            hold_frame: None,
            link_group: None,
            source_channel: None,
            speed_keys: None,
        }
    }

    /// End on the timeline.
    pub fn end(&self) -> Time {
        self.start + self.duration
    }
}

/// A transition of an interchange track.
#[derive(Debug, Clone, PartialEq)]
pub struct IXTransition {
    pub kind: TransitionKind,
    pub duration: Time,
    pub alignment: TransitionAlignment,
    /// Indices into the track's `clips` (`None` = one-sided).
    pub outgoing: Option<usize>,
    pub incoming: Option<usize>,
}

impl IXTransition {
    /// A cross dissolve centered on the cut.
    pub fn new(duration: Time, outgoing: Option<usize>, incoming: Option<usize>) -> IXTransition {
        IXTransition {
            kind: TransitionKind::CrossDissolve,
            duration,
            alignment: TransitionAlignment::Center,
            outgoing,
            incoming,
        }
    }
}

/// A track of an interchange sequence.
#[derive(Debug, Clone, PartialEq)]
pub struct IXTrack {
    pub kind: TrackKind,
    pub clips: Vec<IXClip>,
    pub transitions: Vec<IXTransition>,
}

impl IXTrack {
    /// An empty track.
    pub fn new(kind: TrackKind) -> IXTrack {
        IXTrack { kind, clips: Vec::new(), transitions: Vec::new() }
    }
}

/// A sequence of an interchange file.
#[derive(Debug, Clone)]
pub struct IXSequence {
    pub name: String,
    pub frame_duration: Time,
    pub width: i64,
    pub height: i64,
    pub tracks: Vec<IXTrack>,
    pub markers: Vec<IXMarker>,
    /// What the reader approximated or dropped.
    pub report: PRImportReport,
}

impl IXSequence {
    /// An empty sequence.
    pub fn new(name: &str, frame_duration: Time, width: i64, height: i64) -> IXSequence {
        IXSequence {
            name: name.to_string(),
            frame_duration,
            width,
            height,
            tracks: Vec::new(),
            markers: Vec::new(),
            report: PRImportReport::default(),
        }
    }
}

/// Why an interchange file was not read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InterchangeError {
    Unsupported(String),
    Malformed(String),
    Empty,
}

impl fmt::Display for InterchangeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            InterchangeError::Unsupported(s) => write!(f, "Not a supported interchange file: {s}"),
            InterchangeError::Malformed(s) => write!(f, "The file could not be read: {s}"),
            InterchangeError::Empty => write!(f, "The file contains no clips."),
        }
    }
}

impl std::error::Error for InterchangeError {}

/// Which format a file holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InterchangeFormat {
    Edl,
    FinalCutXML,
    Fcpxml,
    Otio,
}

impl InterchangeFormat {
    /// By content first (an `.xml` file is either FCP7 or FCPXML), then by extension.
    pub fn detect(data: &[u8], file_extension: &str) -> Option<InterchangeFormat> {
        let head = String::from_utf8_lossy(&data[..data.len().min(4096)]);
        if head.contains("<fcpxml") {
            return Some(InterchangeFormat::Fcpxml);
        }
        if head.contains("OTIO_SCHEMA") {
            return Some(InterchangeFormat::Otio);
        }
        if head.contains("<xmeml") {
            return Some(InterchangeFormat::FinalCutXML);
        }
        match file_extension.to_lowercase().as_str() {
            "edl" => return Some(InterchangeFormat::Edl),
            "fcpxml" => return Some(InterchangeFormat::Fcpxml),
            "otio" => return Some(InterchangeFormat::Otio),
            _ => {}
        }
        if !head.contains('<') && (head.contains("TITLE:") || has_event_line(&head)) {
            return Some(InterchangeFormat::Edl);
        }
        None
    }
}

/// `(?m)^\d{3,6}\s+\S+\s+\S+\s+[CDW]`: an EDL event line, at the start of any line.
fn has_event_line(head: &str) -> bool {
    let chars: Vec<char> = head.chars().collect();
    let line_starts = std::iter::once(0).chain(
        (0..chars.len())
            .filter(|&i| matches!(chars[i], '\n' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'))
            .map(|i| i + 1),
    );
    for start in line_starts {
        let mut p = start;
        while p < chars.len() && chars[p].is_ascii_digit() {
            p += 1;
        }
        if !(3..=6).contains(&(p - start)) {
            continue;
        }
        let mut ok = true;
        for _ in 0..2 {
            let s = p;
            while p < chars.len() && chars[p].is_whitespace() {
                p += 1;
            }
            let t = p;
            while p < chars.len() && !chars[p].is_whitespace() {
                p += 1;
            }
            if t == s || p == t {
                ok = false;
                break;
            }
        }
        if !ok {
            continue;
        }
        let s = p;
        while p < chars.len() && chars[p].is_whitespace() {
            p += 1;
        }
        if p > s && matches!(chars.get(p), Some('C' | 'D' | 'W')) {
            return true;
        }
    }
    false
}

/// Reads interchange files into the neutral sequence.
pub struct InterchangeReader;

impl InterchangeReader {
    /// The rate of an EDL (it carries none): 25 fps.
    pub fn default_frame_duration() -> Time {
        Time::new(1, 25)
    }

    fn unsupported(file_extension: &str) -> InterchangeError {
        InterchangeError::Unsupported(if file_extension.is_empty() {
            "unknown format".to_string()
        } else {
            format!(".{file_extension}")
        })
    }

    /// Reads a file into the neutral sequence. `default_frame_duration`: the rate of an EDL (it carries none).
    pub fn read(
        data: &[u8],
        file_extension: &str,
        name: &str,
        default_frame_duration: Time,
    ) -> Result<IXSequence, InterchangeError> {
        let format =
            InterchangeFormat::detect(data, file_extension).ok_or_else(|| Self::unsupported(file_extension))?;
        let seq = match format {
            InterchangeFormat::Edl => EDLReader::read(&String::from_utf8_lossy(data), name, default_frame_duration)?,
            InterchangeFormat::FinalCutXML => XMEMLReader::read(data, name)?,
            InterchangeFormat::Fcpxml => FCPXMLReader::read(data, name)?,
            InterchangeFormat::Otio => OTIOReader::read(data, name)?,
        };
        if !seq.tracks.iter().any(|t| !t.clips.is_empty()) {
            return Err(InterchangeError::Empty);
        }
        Ok(seq)
    }

    /// Every sequence of the file that has clips (FCPXML projects, xmeml sequences). OTIO collections give one per
    /// timeline; one entry for EDL.
    pub fn read_all(
        data: &[u8],
        file_extension: &str,
        name: &str,
        default_frame_duration: Time,
    ) -> Result<Vec<IXSequence>, InterchangeError> {
        let format =
            InterchangeFormat::detect(data, file_extension).ok_or_else(|| Self::unsupported(file_extension))?;
        let all = match format {
            InterchangeFormat::Fcpxml => FCPXMLReader::read_all(data, name)?,
            InterchangeFormat::FinalCutXML => XMEMLReader::read_all(data, name)?,
            InterchangeFormat::Otio => OTIOReader::read_all(data, name)?,
            InterchangeFormat::Edl => return Ok(vec![Self::read(data, file_extension, name, default_frame_duration)?]),
        };
        let usable: Vec<IXSequence> =
            all.into_iter().filter(|s| s.tracks.iter().any(|t| !t.clips.is_empty())).collect();
        if usable.is_empty() {
            return Err(InterchangeError::Empty);
        }
        Ok(usable)
    }
}

/// `IXSequence` -> project (one timeline per sequence). Missing media become offline placeholders until relinked.
pub struct InterchangeMapper;

impl InterchangeMapper {
    /// Keys of the media that look like absolute paths (what the caller probes before `map`).
    pub fn media_paths(all: &[IXSequence]) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for c in all.iter().flat_map(|s| s.tracks.iter().flat_map(|t| t.clips.iter())) {
            if (c.media_key.starts_with('/') || c.media_key.contains(":\\")) && !out.contains(&c.media_key) {
                out.push(c.media_key.clone());
            }
        }
        out
    }

    /// One project with a timeline per sequence (the first is active); media shared between them are one item.
    pub fn map(
        all: &[IXSequence],
        name: Option<&str>,
        probed: &BTreeMap<String, MediaRef>,
        ids: &mut dyn IdSource,
    ) -> PRImportResult {
        let mut report = PRImportReport::default();
        let mut refs = probed.clone();
        let mut order: Vec<String> = Vec::new();
        let mut timelines = Vec::new();
        let mut channel_of: BTreeMap<Id, Vec<i64>> = BTreeMap::new(); // media -> channels played
        for s in all {
            for e in s.report.entries() {
                for _ in 0..e.count {
                    report.note(&e.feature, e.status, &e.note);
                }
            }
            timelines.push(timeline(s, &mut refs, &mut order, &mut channel_of, &mut report, ids));
        }
        if all.len() > 1 {
            report.note("Sequences", crate::primport_report::Status::Mapped, &all.len().to_string());
        }
        let media = order.iter().filter_map(|k| refs.get(k).cloned()).collect();
        let default_name = all.first().map_or("Imported", |s| s.name.as_str());
        let mut project = Project::new(ids.next_id(), name.unwrap_or(default_name), media, timelines);
        // shortcut: one channel choice per media item; applied only when every audio clip of the file names the same
        // channel above the first and the file is probed, upgrade when clips can carry their own channel map.
        for (id, channels) in &channel_of {
            let Some(&ch) = channels.first() else { continue };
            if ch <= 0 || !channels.iter().all(|&c| c == ch) {
                continue;
            }
            let Some(map) = AudioChannelMap::mono(ch) else { continue };
            if !project.set_audio_channel_map(Some(&map), *id) {
                report.note(
                    "Audio channel",
                    crate::primport_report::Status::Approximated,
                    &format!("the file plays channel {} only: set it under source settings after relinking", ch + 1),
                );
            }
        }
        PRImportResult { project, report }
    }
}

fn ref_for(
    c: &IXClip,
    refs: &mut BTreeMap<String, MediaRef>,
    order: &mut Vec<String>,
    report: &mut PRImportReport,
    ids: &mut dyn IdSource,
) -> MediaRef {
    let r = refs.entry(c.media_key.clone()).or_insert_with(|| {
        let mut r = MediaRef::new(ids.next_id(), &c.media_name, &c.media_key, MediaFingerprint::new(0));
        r.duration = c.media_duration;
        report.note(
            "Offline media",
            crate::primport_report::Status::Approximated,
            "not found: placeholder until relinked",
        );
        r
    });
    let r = r.clone();
    if !order.contains(&c.media_key) {
        order.push(c.media_key.clone());
    }
    r
}

pub(crate) fn file_extension_of(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    match name.rfind('.') {
        Some(i) if i > 0 && i + 1 < name.len() => name[i + 1..].to_lowercase(),
        _ => String::new(),
    }
}

fn timeline(
    s: &IXSequence,
    refs: &mut BTreeMap<String, MediaRef>,
    order: &mut Vec<String>,
    channel_of: &mut BTreeMap<Id, Vec<i64>>,
    report: &mut PRImportReport,
    ids: &mut dyn IdSource,
) -> Timeline {
    use crate::primport_report::Status::{Dropped, Mapped};
    let fd = s.frame_duration;
    let mut lanes: Vec<Vec<Clip>> = Vec::new();
    let mut kinds: Vec<TrackKind> = Vec::new();
    let mut transitions: Vec<Vec<Transition>> = Vec::new();
    let mut group_of: BTreeMap<Id, String> = BTreeMap::new(); // clip -> explicit link group
    for t in &s.tracks {
        let mut clips: Vec<Clip> = Vec::new();
        let mut id_of: BTreeMap<usize, Id> = BTreeMap::new();
        let mut idx: Vec<usize> = (0..t.clips.len()).collect();
        idx.sort_by_key(|&i| t.clips[i].start);
        for i in idx {
            let c = &t.clips[i];
            let start = c.start.snapped(fd);
            let duration =
                c.speed_keys.as_ref().map_or_else(|| std::cmp::max(c.duration.snapped(fd), fd), SpeedKeys::duration);
            if clips.last().is_some_and(|last| last.timeline().end() > start) {
                report.note("Overlapping clip", Dropped, "a clip starting inside the previous one on the same track");
                continue;
            }
            let r = ref_for(c, refs, order, report, ids);
            let still = r
                .info
                .as_ref()
                .map_or_else(|| STILL_EXTENSIONS.contains(&file_extension_of(&r.path).as_str()), |i| i.is_still);
            let name = if c.name.is_empty() { &c.media_name } else { &c.name };
            let source = TimeRange::new(if still { Time::ZERO } else { c.source_in }, c.speed.scale(duration));
            let mut clip = Clip::new(ids.next_id(), name, r.id, t.kind, source, start);
            clip.media_duration = r.duration.or(c.media_duration);
            clip.is_still = still;
            clip.speed = c.speed;
            clip.reversed = c.reversed;
            if let Some(keys) = &c.speed_keys
                && !still
            {
                clip.set_speed_keys(Some(keys.clone()));
            }
            if let Some(h) = c.hold_frame {
                clip.hold_frame = Some(h);
            }
            id_of.insert(i, clip.id);
            if let Some(g) = &c.link_group {
                group_of.insert(clip.id, g.clone());
            }
            if t.kind == TrackKind::Audio {
                channel_of.entry(r.id).or_default().push(c.source_channel.unwrap_or(-1));
            }
            clips.push(clip);
            report.note(if t.kind == TrackKind::Video { "Video clip" } else { "Audio clip" }, Mapped, "");
            if c.speed_keys.is_some() && !still {
                report.note("Speed ramp", Mapped, "imported as retime keys");
            } else if !c.speed.is_normal() || c.reversed {
                report.note("Speed", Mapped, "");
            }
        }
        lanes.push(clips);
        kinds.push(t.kind);
        let mut trs = Vec::new();
        for x in &t.transitions {
            let out = x.outgoing.and_then(|i| id_of.get(&i).copied());
            let inc = x.incoming.and_then(|i| id_of.get(&i).copied());
            if out.is_none() && inc.is_none() {
                continue;
            }
            report.note("Cross Dissolve", Mapped, "");
            let mut tr = Transition::new(ids.next_id(), x.kind, std::cmp::max(x.duration.snapped(fd), fd), out, inc);
            tr.alignment = x.alignment;
            trs.push(tr);
        }
        transitions.push(trs);
    }
    link(&mut lanes, &kinds, &group_of, ids);
    let mut counts: BTreeMap<u8, i64> = BTreeMap::new();
    let mut tracks = Vec::new();
    for (i, clips) in lanes.into_iter().enumerate() {
        let n = counts.entry(kinds[i] as u8).or_insert(0);
        *n += 1;
        let mut track = Track::new(ids.next_id(), kinds[i]);
        track.set_clips(clips);
        track.name = format!("{}{}", if kinds[i] == TrackKind::Video { "V" } else { "A" }, n);
        track.transitions = std::mem::take(&mut transitions[i]);
        tracks.push(track);
    }
    let mut format = SequenceFormat::new(fd);
    format.width = s.width;
    format.height = s.height;
    let format = sanitized_format(&format);
    let mut timeline = Timeline::new(ids.next_id(), &s.name, format, tracks);
    timeline.markers = s
        .markers
        .iter()
        .map(|m| Marker {
            id: ids.next_id(),
            time: m.time.snapped(fd),
            name: m.name.clone(),
            color: m.color.unwrap_or(MarkerColor::Green),
            comment: m.comment.clone(),
            duration: m.duration.snapped(fd),
        })
        .collect();
    if !s.markers.is_empty() {
        report.note("Sequence markers", Mapped, &s.markers.len().to_string());
    }
    timeline
}

/// Media, start and end of a clip: clips with the same key are one linked pair.
pub(crate) type LinkKey = (Id, Time, Time);

/// Links a video clip and the audio clips of the same media over the same range.
pub(crate) fn link(
    lanes: &mut [Vec<Clip>],
    kinds: &[TrackKind],
    explicit: &BTreeMap<Id, String>,
    ids: &mut dyn IdSource,
) {
    // Groups the file names win; clips of a group of one are left to the heuristic below.
    let mut by_group: BTreeMap<&str, Vec<(usize, usize)>> = BTreeMap::new();
    for (li, lane) in lanes.iter().enumerate() {
        for (ci, c) in lane.iter().enumerate() {
            if let Some(g) = explicit.get(&c.id) {
                by_group.entry(g.as_str()).or_default().push((li, ci));
            }
        }
    }
    let groups: Vec<Vec<(usize, usize)>> = by_group.into_values().filter(|m| m.len() > 1).collect();
    for members in groups {
        let id = ids.next_id();
        for (li, ci) in members {
            lanes[li][ci].link = Some(id);
        }
    }
    let mut by_key: Vec<(LinkKey, Vec<(usize, usize)>)> = Vec::new();
    for (li, lane) in lanes.iter().enumerate() {
        for (ci, c) in lane.iter().enumerate().filter(|(_, c)| c.link.is_none()) {
            let key = (c.media, c.start, c.timeline().end());
            match by_key.iter_mut().find(|(k, _)| *k == key) {
                Some((_, v)) => v.push((li, ci)),
                None => by_key.push((key, vec![(li, ci)])),
            }
        }
    }
    for (_, members) in by_key {
        let video = members.iter().filter(|m| kinds[m.0] == TrackKind::Video).count();
        if video != 1 || !members.iter().any(|m| kinds[m.0] == TrackKind::Audio) {
            continue;
        }
        let id = ids.next_id();
        for (li, ci) in members {
            lanes[li][ci].link = Some(id);
        }
    }
}
