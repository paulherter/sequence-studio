// SPDX-License-Identifier: GPL-3.0-or-later
//! Final Cut Pro 7 XML (xmeml version 4, the form Premiere and Resolve import) of a sequence: every video and audio
//! track as a `<track>` of clip items (start / end on the sequence, in / out in the file), file definitions once and
//! referenced by id, constant speed and reverse as a Time Remap filter, dissolves and fades as transition items,
//! sequence markers. Titles, generators, nested sequences and disabled clips are skipped and listed in the warnings.
//! Written from the public xmeml description; no third-party code.

use super::fcpxml::escape;
use super::{
    InterchangeExport, Warnings, file_url, frames_rounded, media_by_id, raw_name, usable, usable_quiet, written_speed,
};
use sq_core_model::{
    AudioChannelMap, Clip, ClipSpeed, MediaRef, Timeline, Track, TrackKind, Transition, TransitionAlignment,
    TransitionKind,
};
use sq_core_time::{CmxTimecode, Id, Time};
use std::collections::HashMap;

/// xmeml writer.
pub struct XmemlWriter;

/// Item id and position of a clip, so a clip can name the partners it is linked to on other tracks.
struct Slot {
    id: String,
    kind: TrackKind,
    track_index: usize,
    clip_index: usize,
}

struct Render<'a> {
    fd: Time,
    base: i64,
    ntsc: bool,
    w: Warnings,
    x: Vec<String>,
    by_id: HashMap<Id, &'a MediaRef>,
    file_ids: HashMap<Id, String>,
    slots: HashMap<Id, Slot>,
    link_members: HashMap<Id, Vec<Id>>,
    item_count: usize,
}

impl<'a> Render<'a> {
    fn frames(&self, t: Time) -> i64 {
        frames_rounded(t, self.fd)
    }

    fn line(&mut self, depth: usize, s: &str) {
        self.x.push(format!("{}{s}", "  ".repeat(depth)));
    }

    fn rate(&mut self, depth: usize) {
        let s = format!(
            "<rate><timebase>{}</timebase><ntsc>{}</ntsc></rate>",
            self.base,
            if self.ntsc { "TRUE" } else { "FALSE" }
        );
        self.line(depth, &s);
    }

    fn file_element(&mut self, c: &Clip, depth: usize, has_video: bool, has_audio: bool) {
        if let Some(id) = self.file_ids.get(&c.media).cloned() {
            self.line(depth, &format!("<file id=\"{id}\"/>"));
            return;
        }
        let id = format!("file-{}", self.file_ids.len() + 1);
        self.file_ids.insert(c.media, id.clone());
        let m = self.by_id.get(&c.media).copied();
        if m.is_none() {
            self.w.warn("Media of a clip is missing from the project; written without a path");
        }
        self.line(depth, &format!("<file id=\"{id}\">"));
        self.line(depth + 1, &format!("<name>{}</name>", escape(m.map_or(c.name.as_str(), |m| m.name.as_str()))));
        if let Some(p) = m.map(|m| m.path.as_str()).filter(|p| !p.is_empty()) {
            self.line(depth + 1, &format!("<pathurl>{}</pathurl>", escape(&file_url(p))));
        }
        self.rate(depth + 1);
        if let Some(d) = m.and_then(|m| m.duration.or(m.info.as_ref().map(|i| i.duration))) {
            self.line(depth + 1, &format!("<duration>{}</duration>", self.frames(d)));
        }
        self.line(depth + 1, "<media>");
        if has_video {
            self.line(depth + 2, "<video/>");
        }
        if has_audio {
            match m
                .and_then(|m| m.info.as_ref())
                .and_then(|i| i.audio.as_ref())
                .map(|a| a.channels)
                .filter(|ch| *ch > 0)
            {
                Some(ch) => self.line(depth + 2, &format!("<audio><channelcount>{ch}</channelcount></audio>")),
                None => self.line(depth + 2, "<audio/>"),
            }
        }
        self.line(depth + 1, "</media>");
        self.line(depth, "</file>");
    }

    fn transition_item(&mut self, t: &Transition, track: &Track, clips: &[&Clip], depth: usize) {
        let find = |id: Option<Id>| id.and_then(|id| clips.iter().copied().find(|c| c.id == id));
        let (out, inc) = (find(t.outgoing), find(t.incoming));
        let (start, alignment) = match (out, inc) {
            (Some(o), Some(i)) => {
                if o.timeline().end() != i.start {
                    self.w.warn("A transition that is not between two touching clips is not exported");
                    return;
                }
                let cut = i.start;
                match t.alignment {
                    TransitionAlignment::Center => (cut - t.duration.halved().snapped(self.fd), "center"),
                    TransitionAlignment::StartAtCut => (cut, "start"),
                    TransitionAlignment::EndAtCut => (cut - t.duration, "end"),
                    TransitionAlignment::Custom => (cut - t.custom_before, "center"),
                }
            }
            (Some(o), None) => (o.timeline().end() - t.duration, "end-black"),
            (None, Some(i)) => (i.start, "start-black"),
            (None, None) => return,
        };
        let audio = track.kind == TrackKind::Audio;
        let (mut name, mut cat) = ("Cross Dissolve", "Dissolve");
        if audio {
            name = if t.kind == TransitionKind::ConstantGain { "Cross Fade (0dB)" } else { "Cross Fade (+3dB)" };
            cat = "Crossfade";
        } else {
            match t.kind {
                TransitionKind::CrossDissolve | TransitionKind::QuickFade => {}
                TransitionKind::DipToBlack => name = "Dip to Black",
                TransitionKind::DipToWhite => name = "Dip to White",
                _ => self.w.warn(format!("Transition \"{}\" written as Cross Dissolve", raw_name(&t.kind))),
            }
        }
        let s = self.frames(start).max(0);
        self.line(depth, "<transitionitem>");
        let end = s + self.frames(t.duration).max(1);
        self.line(depth + 1, &format!("<start>{s}</start><end>{end}</end>"));
        self.line(depth + 1, &format!("<alignment>{alignment}</alignment>"));
        self.rate(depth + 1);
        self.line(
            depth + 1,
            &format!(
                "<effect><name>{name}</name><effectid>{name}</effectid><effectcategory>{cat}</effectcategory><effecttype>transition</effecttype><mediatype>{}</mediatype></effect>",
                if audio { "audio" } else { "video" }
            ),
        );
        self.line(depth, "</transitionitem>");
    }

    fn marker_line(&mut self, depth: usize, m: &sq_core_model::Marker) {
        let i = self.frames(m.time);
        let out = if m.duration > Time::ZERO { i + self.frames(m.duration).max(1) } else { -1 };
        self.line(
            depth,
            &format!(
                "<marker><name>{}</name><comment>{}</comment><in>{i}</in><out>{out}</out></marker>",
                escape(&m.name),
                escape(&m.comment)
            ),
        );
    }

    fn track_element(&mut self, t: &Track, depth: usize) {
        let clips: Vec<&Clip> = t.clips().iter().filter(|c| usable(c, &mut self.w)).collect();
        self.line(depth, "<track>");
        for (i, &c) in clips.iter().enumerate() {
            // A transition in front of the clip goes before it (cut between two clips, or a fade-in).
            for tr in t.transitions.iter().filter(|tr| tr.incoming == Some(c.id)) {
                if tr.outgoing.is_none() || (i > 0 && Some(clips[i - 1].id) == tr.outgoing) {
                    self.transition_item(tr, t, &clips, depth + 1);
                }
            }
            self.item_count += 1;
            let item = self.slots.get(&c.id).map_or_else(|| format!("clipitem-{}", self.item_count), |s| s.id.clone());
            self.line(depth + 1, &format!("<clipitem id=\"{item}\">"));
            self.line(depth + 2, &format!("<name>{}</name>", escape(&c.name)));
            self.line(depth + 2, "<enabled>TRUE</enabled>");
            let hold = c.hold_frame;
            let in_f = self.frames(hold.unwrap_or(c.source.start));
            let out_f =
                if hold.is_some() { in_f + self.frames(c.duration()).max(1) } else { self.frames(c.source.end()) };
            if hold.is_some() {
                self.w.warn(format!("Hold frame on \"{}\" written as plain playback from that frame", c.name));
            }
            let dur = self.frames(c.duration()).max(1);
            self.line(depth + 2, &format!("<duration>{dur}</duration>"));
            self.rate(depth + 2);
            let (start, end) = (self.frames(c.start), self.frames(c.timeline().end()));
            self.line(depth + 2, &format!("<start>{start}</start><end>{end}</end>"));
            self.line(depth + 2, &format!("<in>{in_f}</in><out>{out_f}</out>"));
            self.file_element(c, depth + 2, t.kind == TrackKind::Video, t.kind == TrackKind::Audio);
            if t.kind == TrackKind::Audio {
                // The file channel this clip plays (a split channel is a mono map; 1-based in the file).
                let mut channel = 0;
                if let Some(map) = self
                    .by_id
                    .get(&c.media)
                    .and_then(|m| m.info.as_ref())
                    .and_then(|i| i.audio.as_ref())
                    .and_then(|a| a.channel_map.as_ref())
                {
                    channel = map.left().first().or(map.right().first()).copied().unwrap_or(0);
                    if matches!(layout(map), Layout::Custom | Layout::DualMono) {
                        self.w.warn(format!("Channel choice on \"{}\" written as its first channel", c.name));
                    }
                }
                self.line(
                    depth + 2,
                    &format!(
                        "<sourcetrack><mediatype>audio</mediatype><trackindex>{}</trackindex></sourcetrack>",
                        channel + 1
                    ),
                );
            }
            let (speed, reversed) = written_speed(c, &mut self.w);
            if hold.is_none() && (!speed.is_normal() || reversed) {
                self.line(depth + 2, "<filter><effect><name>Time Remap</name><effectid>timeremap</effectid><effectcategory>motion</effectcategory><effecttype>motion</effecttype><mediatype>video</mediatype>");
                self.line(
                    depth + 3,
                    &format!(
                        "<parameter><parameterid>speed</parameterid><name>speed</name><value>{}{}</value></parameter>",
                        if reversed { "-" } else { "" },
                        percent(speed)
                    ),
                );
                self.line(depth + 2, "</effect></filter>");
            }
            if hold.is_none() {
                let mut own: Vec<&sq_core_model::Marker> = c.markers.iter().flatten().collect();
                own.sort_by_key(|m| m.time);
                for m in own.into_iter().filter(|m| m.time >= c.source.start && m.time < c.source.end()) {
                    self.marker_line(depth + 2, m);
                }
            }
            if let Some(members) = c.link.and_then(|g| self.link_members.get(&g)).filter(|m| m.len() > 1).cloned() {
                for id in members {
                    let Some(sl) = self.slots.get(&id) else { continue };
                    let s = format!(
                        "<link><linkclipref>{}</linkclipref><mediatype>{}</mediatype><trackindex>{}</trackindex><clipindex>{}</clipindex></link>",
                        sl.id,
                        if sl.kind == TrackKind::Video { "video" } else { "audio" },
                        sl.track_index,
                        sl.clip_index
                    );
                    self.line(depth + 2, &s);
                }
            }
            self.line(depth + 1, "</clipitem>");
            for tr in t.transitions.iter().filter(|tr| tr.outgoing == Some(c.id) && tr.incoming.is_none()) {
                self.transition_item(tr, t, &clips, depth + 1);
            }
        }
        self.line(depth, "</track>");
    }
}

#[derive(PartialEq)]
enum Layout {
    Mono,
    Stereo,
    DualMono,
    Custom,
}

/// `AudioChannelMap.layout` of the Swift model.
fn layout(m: &AudioChannelMap) -> Layout {
    let (l, r) = (m.left(), m.right());
    if l == r {
        return match l.len() {
            1 => Layout::Mono,
            2 => Layout::DualMono,
            _ => Layout::Custom,
        };
    }
    if l.len() == 1 && r.len() == 1 { Layout::Stereo } else { Layout::Custom }
}

/// Speed as percent text: "200", "33.3333".
fn percent(s: ClipSpeed) -> String {
    let whole = s.num() * 100;
    if whole % s.den() == 0 {
        return (whole / s.den()).to_string();
    }
    let scaled = (i128::from(s.num()) * 1_000_000 + i128::from(s.den()) / 2) / i128::from(s.den()); // percent with 4 decimals
    let mut text = format!("{}.{:04}", scaled / 10_000, scaled % 10_000);
    while text.ends_with('0') {
        text.pop();
    }
    text
}

impl XmemlWriter {
    /// The sequence as xmeml text.
    pub fn render(timeline: &Timeline, media: &[MediaRef]) -> InterchangeExport {
        let fd = timeline.format.frame_duration;
        let fps = fd.timescale() as f64 / fd.value().max(1) as f64;
        let base = fps.round() as i64;
        let mut w = Warnings::default();
        // A rate whose timebase is not positive cannot be an NTSC rate (Swift traps there).
        let ntsc = base > 0 && fd == Time::new(1001, base * 1000);
        if !ntsc && !(base > 0 && fd == Time::new(1, base)) {
            w.warn(format!("Frame rate is not a whole or NTSC rate; written as {base} fps"));
        }

        // Item ids and positions up front, so a clip can name the partners it is linked to on other tracks.
        let mut slots = HashMap::new();
        let mut link_members: HashMap<Id, Vec<Id>> = HashMap::new();
        let (mut n, mut v, mut a) = (0, 0, 0);
        for t in &timeline.tracks {
            if t.kind == TrackKind::Video {
                v += 1
            } else {
                a += 1
            }
            for (k, c) in t.clips().iter().filter(|c| usable_quiet(c)).enumerate() {
                n += 1;
                let track_index = if t.kind == TrackKind::Video { v } else { a };
                slots.insert(c.id, Slot { id: format!("clipitem-{n}"), kind: t.kind, track_index, clip_index: k + 1 });
                if let Some(l) = c.link {
                    link_members.entry(l).or_default().push(c.id);
                }
            }
        }
        let mut r = Render {
            fd,
            base,
            ntsc,
            w,
            x: Vec::new(),
            by_id: media_by_id(media),
            file_ids: HashMap::new(),
            slots,
            link_members,
            item_count: 0,
        };

        let video: Vec<&Track> = timeline.tracks.iter().filter(|t| t.kind == TrackKind::Video).collect();
        let audio: Vec<&Track> = timeline.tracks.iter().filter(|t| t.kind == TrackKind::Audio).collect();
        let total = timeline
            .tracks
            .iter()
            .flat_map(|t| t.clips())
            .filter(|c| usable_quiet(c))
            .map(|c| c.timeline().end())
            .max()
            .unwrap_or(Time::ZERO);
        if total == Time::ZERO {
            r.w.warn("The sequence has no clips Final Cut Pro XML can carry");
        }
        let tc = CmxTimecode::from_frame_duration(fd, true);
        let tc_frames = r.frames(timeline.timecode_start());

        r.line(0, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
        r.line(0, "<!DOCTYPE xmeml>");
        r.line(0, "<xmeml version=\"4\">");
        r.line(1, "<sequence id=\"sequence-1\">");
        r.line(2, &format!("<name>{}</name>", escape(&timeline.name)));
        let total_frames = r.frames(total);
        r.line(2, &format!("<duration>{total_frames}</duration>"));
        r.rate(2);
        r.line(2, "<timecode>");
        r.rate(3);
        r.line(
            3,
            &format!(
                "<string>{}</string><frame>{tc_frames}</frame><displayformat>{}</displayformat>",
                tc.string(tc_frames),
                if tc.drop_frame() { "DF" } else { "NDF" }
            ),
        );
        r.line(2, "</timecode>");
        let mut markers: Vec<_> = timeline.markers.iter().collect();
        markers.sort_by_key(|m| m.time);
        for m in markers {
            r.marker_line(2, m);
        }
        r.line(2, "<media>");
        r.line(3, "<video>");
        r.line(4, "<format><samplecharacteristics>");
        r.rate(5);
        r.line(
            5,
            &format!(
                "<width>{}</width><height>{}</height><pixelaspectratio>square</pixelaspectratio>",
                timeline.format.width, timeline.format.height
            ),
        );
        r.line(4, "</samplecharacteristics></format>");
        for t in video {
            r.track_element(t, 4);
        }
        r.line(3, "</video>");
        r.line(3, "<audio>");
        r.line(4, "<numOutputChannels>2</numOutputChannels>");
        r.line(4, &format!("<format><samplecharacteristics><depth>16</depth><samplerate>{}</samplerate></samplecharacteristics></format>", timeline.format.audio_sample_rate));
        for t in audio {
            r.track_element(t, 4);
        }
        r.line(3, "</audio>");
        r.line(2, "</media>");
        r.line(1, "</sequence>");
        r.line(0, "</xmeml>");
        InterchangeExport::new(r.x.join("\n") + "\n", r.w.0)
    }
}
