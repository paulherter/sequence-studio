// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: XMEMLReader.swift. Final Cut Pro 7 XML (xmeml, also written by Premiere "Export Final Cut Pro XML") ->
//! `IXSequence`: the first sequence, its video and audio tracks (clip items with start / end / in / out, file path, speed
//! from a time-remap filter), transitions with cut position, and sequence / clip markers. Generators and nested sequences
//! are dropped.

use crate::edlreader::EDLReader;
use crate::interchange_model::{IXClip, IXMarker, IXSequence, IXTrack, IXTransition, InterchangeError};
use crate::interchange_xml::{self, IxNodeExt, last_path_component, path_from_url};
use crate::primport_report::Status;
use sq_core_model::{ClipSpeed, TrackKind, TransitionAlignment, TransitionKind};
use sq_core_time::Time;
use sq_prproj_reader::Node;
use std::collections::{BTreeMap, HashMap};

/// Reads FCP7 XML.
pub struct XMEMLReader;

fn nonempty(s: Option<&str>) -> Option<&str> {
    s.filter(|s| !s.is_empty())
}

impl XMEMLReader {
    /// The first sequence of the file.
    pub fn read(data: &[u8], name: &str) -> Result<IXSequence, InterchangeError> {
        Self::read_all(data, name)?.into_iter().next().ok_or_else(|| InterchangeError::Malformed("no sequence".into()))
    }

    /// Every sequence of the file, not the ones nested inside a clip item (those play where they are used).
    pub fn read_all(data: &[u8], name: &str) -> Result<Vec<IXSequence>, InterchangeError> {
        let root = interchange_xml::parse(data)?;
        if root.name != "xmeml" {
            return Err(InterchangeError::Unsupported("not a Final Cut Pro XML file".into()));
        }
        fn walk<'a>(n: &'a Node, found: &mut Vec<&'a Node>) {
            for c in &n.children {
                if c.name == "sequence" {
                    found.push(c);
                } else if c.name != "clipitem" {
                    walk(c, found);
                }
            }
        }
        let mut found = Vec::new();
        walk(&root, &mut found);
        if found.is_empty()
            && let Some(any) = root.descendants_named("sequence").into_iter().next()
        {
            found = vec![any];
        }
        if found.is_empty() {
            return Err(InterchangeError::Malformed("no sequence".into()));
        }
        Ok(found.into_iter().map(|s| Self::sequence(s, &root, name)).collect())
    }

    fn sequence(sequence: &Node, root: &Node, name: &str) -> IXSequence {
        let fd = Self::frame_duration(sequence.child("rate")).unwrap_or(Time::new(1, 25));
        let format = sequence
            .child("media")
            .and_then(|m| m.child("video"))
            .and_then(|v| v.child("format"))
            .and_then(|f| f.child("samplecharacteristics"));
        let mut seq = IXSequence::new(
            nonempty(sequence.kid_text("name")).unwrap_or(name),
            fd,
            format.and_then(|f| f.kid_int("width")).unwrap_or(1920),
            format.and_then(|f| f.kid_int("height")).unwrap_or(1080),
        );
        // A file is defined in full once and referenced by id later.
        let mut files: HashMap<&str, &Node> = HashMap::new();
        for f in root.descendants_named("file") {
            let Some(id) = f.attributes.get("id") else { continue };
            if !files.contains_key(id.as_str()) || f.child("pathurl").is_some() {
                files.insert(id, f);
            }
        }
        let groups = Self::link_groups(sequence);
        for (kind, group) in [(TrackKind::Video, "video"), (TrackKind::Audio, "audio")] {
            for t in sequence.child("media").and_then(|m| m.child(group)).map(|g| g.kids("track")).unwrap_or_default() {
                let track = Self::track(t, kind, fd, &files, &groups, &mut seq);
                seq.tracks.push(track);
            }
        }
        for m in sequence.kids("marker") {
            let Some(t) = m.kid_int("in").filter(|&t| t >= 0) else { continue };
            seq.markers.push(IXMarker {
                time: fd * t,
                name: m.kid_text("name").unwrap_or("").to_string(),
                comment: m.kid_text("comment").unwrap_or("").to_string(),
                duration: Self::duration(m, fd),
                color: None,
            });
        }
        seq
    }

    /// timebase + ntsc flag -> frame duration.
    pub(crate) fn frame_duration(rate: Option<&Node>) -> Option<Time> {
        let base = rate?.kid_int("timebase").filter(|&b| b > 0)?;
        let ntsc = rate?.kid_text("ntsc").map(str::to_uppercase).as_deref() == Some("TRUE");
        Some(if ntsc { Time::new(1001, base * 1000) } else { Time::new(1, base) })
    }

    fn duration(marker: &Node, fd: Time) -> Time {
        match (marker.kid_int("in"), marker.kid_int("out")) {
            (Some(i), Some(o)) if o > i && i >= 0 => fd * (o - i),
            _ => Time::ZERO,
        }
    }

    /// `<link>` elements: clipitem id -> group name (the smallest id of the connected set).
    pub(crate) fn link_groups(sequence: &Node) -> HashMap<String, String> {
        let mut parent: HashMap<String, String> = HashMap::new();
        fn find(parent: &HashMap<String, String>, x: &str) -> String {
            let mut r = x.to_string();
            while let Some(p) = parent.get(&r) {
                if *p == r {
                    break;
                }
                r = p.clone();
            }
            r
        }
        for item in sequence.descendants_named("clipitem") {
            let Some(id) = item.attributes.get("id") else { continue };
            for l in item.kids("link") {
                let Some(r) = nonempty(l.kid_text("linkclipref")) else { continue };
                let (a, b) = (find(&parent, id), find(&parent, r));
                if a != b {
                    let (lo, hi) = if a < b { (a, b) } else { (b, a) };
                    parent.insert(hi, lo.clone());
                    parent.insert(lo.clone(), lo);
                } else {
                    parent.insert(a.clone(), a);
                }
            }
        }
        parent.keys().map(|k| (k.clone(), find(&parent, k))).collect()
    }

    fn track(
        t: &Node,
        kind: TrackKind,
        fd: Time,
        files: &HashMap<&str, &Node>,
        groups: &HashMap<String, String>,
        seq: &mut IXSequence,
    ) -> IXTrack {
        let mut track = IXTrack::new(kind);
        let items: Vec<&Node> = t
            .children
            .iter()
            .filter(|c| ["clipitem", "transitionitem", "generatoritem"].contains(&c.name.as_str()))
            .collect();
        // Where a transition's cut lies, from its alignment.
        let cut = |tr: &Node| -> Option<Time> {
            let (s, e) = (tr.kid_int("start")?, tr.kid_int("end")?);
            Some(match tr.kid_text("alignment").map_or_else(|| "center".to_string(), str::to_lowercase).as_str() {
                "start" | "start-black" => fd * s,
                "end" | "end-black" => fd * e,
                _ => fd * s + (fd * (e - s)).halved().snapped(fd),
            })
        };
        let mut index_of_item: BTreeMap<usize, usize> = BTreeMap::new(); // item position -> clip index
        for (i, item) in items.iter().enumerate() {
            if item.name != "clipitem" {
                if item.name == "generatoritem" {
                    seq.report.note("Generator", Status::Dropped, "titles, bars and solids are not read from XML");
                }
                continue;
            }
            if item.kid_text("enabled").map(str::to_uppercase).as_deref() == Some("FALSE") {
                seq.report.note("Disabled clip", Status::Dropped, "");
                continue;
            }
            let file: Option<&Node> = item.child("file").map(|f| {
                if f.child("pathurl").is_some() || f.child("name").is_some() {
                    f
                } else {
                    f.attributes.get("id").and_then(|id| files.get(id.as_str()).copied()).unwrap_or(f)
                }
            });
            if item.child("sequence").is_some() && file.is_none() {
                seq.report.note("Nested sequence", Status::Dropped, "not read from XML");
                continue;
            }
            if file.is_none() && item.kid_text("name").is_none() {
                continue;
            }
            let item_fd = Self::frame_duration(item.child("rate"))
                .or_else(|| Self::frame_duration(file.and_then(|f| f.child("rate"))))
                .unwrap_or(fd);
            let mut start = item.kid_int("start").unwrap_or(-1);
            let mut end = item.kid_int("end").unwrap_or(-1);
            let mut start_time = fd * start;
            let mut end_time = fd * end;
            if start < 0
                && i > 0
                && items[i - 1].name == "transitionitem"
                && let Some(c) = cut(items[i - 1])
            {
                start_time = c;
                start = 0;
            }
            if end < 0
                && i + 1 < items.len()
                && items[i + 1].name == "transitionitem"
                && let Some(c) = cut(items[i + 1])
            {
                end_time = c;
                end = 0;
            }
            if !(start >= 0 && end >= 0 && end_time > start_time) {
                seq.report.note("Clip without position", Status::Dropped, "");
                continue;
            }
            let in_frame = item.kid_int("in").unwrap_or(0);
            let mut speed = ClipSpeed::NORMAL;
            let mut reversed = false;
            let mut retimed = false;
            for f in item.kids("filter") {
                if f.child("effect").and_then(|e| e.kid_text("effectid")).map(str::to_lowercase).as_deref()
                    != Some("timeremap")
                {
                    continue;
                }
                for p in f.child("effect").map(|e| e.kids("parameter")).unwrap_or_default() {
                    match p.kid_text("parameterid").map(str::to_lowercase).as_deref() {
                        Some("speed") => {
                            if let Some((num, den)) =
                                p.kid_text("value").and_then(EDLReader::ratio).filter(|v| v.0 != 0)
                            {
                                // percent: num/den % -> num/(den*100)
                                speed = ClipSpeed::new(num.abs(), den * 100);
                                retimed = true;
                                if num < 0 {
                                    reversed = true;
                                }
                            }
                        }
                        Some("reverse") if p.kid_text("value").map(str::to_uppercase).as_deref() == Some("TRUE") => {
                            reversed = true;
                            retimed = true;
                        }
                        _ => {}
                    }
                }
            }
            if retimed {
                seq.report.note("Speed", Status::Mapped, "");
            }
            let (key, media_name) = if let Some(p) = nonempty(file.and_then(|f| f.kid_text("pathurl"))) {
                let key = path_from_url(p);
                let media_name =
                    file.and_then(|f| f.kid_text("name")).map_or_else(|| last_path_component(&key), str::to_string);
                (key, media_name)
            } else {
                let media_name = file
                    .and_then(|f| f.kid_text("name"))
                    .or_else(|| item.kid_text("name"))
                    .unwrap_or("Media")
                    .to_string();
                (media_name.clone(), media_name)
            };
            let file_duration = file
                .and_then(|f| f.kid_int("duration"))
                .map(|d| Self::frame_duration(file.and_then(|f| f.child("rate"))).unwrap_or(item_fd) * d);
            let clip_name = item.kid_text("name").map_or_else(|| media_name.clone(), str::to_string);
            index_of_item.insert(i, track.clips.len());
            let mut ix_clip =
                IXClip::new(&clip_name, &key, Some(&media_name), start_time, end_time - start_time, item_fd * in_frame);
            ix_clip.speed = speed;
            ix_clip.reversed = reversed;
            ix_clip.media_duration = file_duration;
            ix_clip.link_group = item.attributes.get("id").and_then(|id| groups.get(id).cloned());
            if kind == TrackKind::Audio
                && let Some(idx) = item.child("sourcetrack").and_then(|s| s.kid_int("trackindex")).filter(|&i| i >= 1)
            {
                ix_clip.source_channel = Some(idx - 1);
            }
            track.clips.push(ix_clip);
            // Clip markers (source time) land on the timeline where the clip shows that frame.
            for m in item.kids("marker") {
                let Some(at) = m.kid_int("in").filter(|&a| a >= in_frame) else { continue };
                let local = speed.unscale(item_fd * (at - in_frame));
                if local >= end_time - start_time {
                    continue;
                }
                seq.markers.push(IXMarker {
                    time: start_time + local,
                    name: m.kid_text("name").unwrap_or("").to_string(),
                    comment: m.kid_text("comment").unwrap_or("").to_string(),
                    duration: Time::ZERO,
                    color: None,
                });
            }
        }
        // Transitions between the clip items before and after them.
        for (i, item) in items.iter().enumerate().filter(|(_, it)| it.name == "transitionitem") {
            let (Some(s), Some(e)) = (item.kid_int("start"), item.kid_int("end")) else { continue };
            let Some(c) = cut(item).filter(|_| e > s) else { continue };
            let out = (0..i).rev().find_map(|k| index_of_item.get(&k).copied());
            let inc = ((i + 1)..items.len().max(i + 1)).find_map(|k| index_of_item.get(&k).copied());
            let effect = item.child("effect");
            let label = effect
                .and_then(|x| x.kid_text("name"))
                .or_else(|| effect.and_then(|x| x.kid_text("effectid")))
                .unwrap_or("")
                .to_lowercase();
            let mut tkind = TransitionKind::CrossDissolve;
            if track.kind == TrackKind::Audio {
                tkind =
                    if label.contains("0db") { TransitionKind::ConstantGain } else { TransitionKind::ConstantPower };
            } else if label.contains("dip") && label.contains("white") {
                tkind = TransitionKind::DipToWhite;
            } else if label.contains("dip") || label.contains("fade") {
                tkind = TransitionKind::DipToBlack;
            } else if !label.is_empty() && !label.contains("dissolve") {
                let shown = effect.and_then(|x| x.kid_text("name")).unwrap_or(&label);
                seq.report.note(&format!("Transition {shown}"), Status::Approximated, "played as Cross Dissolve");
            }
            let length = fd * (e - s);
            let mut alignment = TransitionAlignment::Center;
            if c == fd * s {
                alignment = TransitionAlignment::StartAtCut;
            } else if c == fd * e {
                alignment = TransitionAlignment::EndAtCut;
            }
            track.transitions.push(IXTransition {
                kind: tkind,
                duration: length,
                alignment,
                outgoing: out,
                incoming: inc,
            });
        }
        track
    }
}
