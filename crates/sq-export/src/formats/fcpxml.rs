// SPDX-License-Identifier: GPL-3.0-or-later
//! FCPXML of a sequence: first video track as the primary storyline (gaps between clips), higher video tracks and audio
//! tracks as connected clips on lanes, a video clip with its linked audio as one asset clip, constant speed and reverse
//! as a `timeMap`, adjacent dissolves as `transition`, markers on the item under them. Text clips are written as
//! `title` elements (text, font, size, color, bold, italic, alignment; the rest of the look is not carried). Other
//! generators, nested sequences and effects are not exported (listed in the warnings).

use super::{InterchangeExport, Warnings, file_url, media_by_id, raw_name};
use sq_core_model::{
    Clip, GeneratorRef, Marker, MediaFingerprint, MediaRef, Timeline, TrackKind, TransitionAlignment, TransitionKind,
};
use sq_core_time::{CmxTimecode, Id, Time};
use sq_text::text_generator::TextGenerator;
use sq_text::text_style::{FontWeight, RGBAColor};
use sq_text::text_template::TextTemplate;
use std::collections::HashMap;

/// FCPXML writer.
pub struct FcpxmlWriter;

/// DTD version written. 1.10 and later keep the media path in a `media-rep` child of the asset.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FcpxmlVersion {
    /// 1.8.
    V1_8,
    /// 1.10.
    V1_10,
    /// 1.13.
    V1_13,
}

impl FcpxmlVersion {
    /// The version text in the file.
    pub fn raw(self) -> &'static str {
        match self {
            FcpxmlVersion::V1_8 => "1.8",
            FcpxmlVersion::V1_10 => "1.10",
            FcpxmlVersion::V1_13 => "1.13",
        }
    }

    fn has_media_rep(self) -> bool {
        self != FcpxmlVersion::V1_8
    }
}

/// How times and formats are written. Resolve reads any reduced rational; Final Cut Pro wants frame-aligned times over
/// the frame rate's own denominator ("10010/30000s", not "1001/3000s") and names the color space.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FcpxmlTarget {
    /// DaVinci Resolve and other readers of reduced rationals.
    Resolve,
    /// Final Cut Pro.
    FinalCut,
}

/// Frame-aligned time over the frame duration's denominator; other times stay reduced.
pub(crate) fn frame_aligned_string(t: Time, fd: Time) -> String {
    if fd.value() <= 0 || fd.timescale() <= 0 || t.timescale() <= 0 {
        return time_string(t);
    }
    let num = i128::from(t.value()) * i128::from(fd.timescale());
    let den = i128::from(t.timescale()) * i128::from(fd.value());
    if num % den != 0 {
        return time_string(t);
    }
    let frames = num / den;
    if frames == 0 {
        return "0s".to_string();
    }
    format!("{}/{}s", frames * i128::from(fd.value()), fd.timescale())
}

/// Rational time string ("1001/30000s", "5s", "0s"), reduced.
pub(crate) fn time_string(t: Time) -> String {
    let (mut v, mut s) = (t.value(), t.timescale());
    if v == 0 || s == 0 {
        return "0s".to_string();
    }
    let (mut a, mut b) = (v.abs(), s);
    while b != 0 {
        (a, b) = (b, a % b);
    }
    v /= a;
    s /= a;
    if s == 1 { format!("{v}s") } else { format!("{v}/{s}s") }
}

/// XML text: the five entities, control characters (except tab) dropped.
pub(crate) fn escape(s: &str) -> String {
    let mut r = String::new();
    for u in s.chars() {
        match u {
            '&' => r += "&amp;",
            '<' => r += "&lt;",
            '>' => r += "&gt;",
            '"' => r += "&quot;",
            '\'' => r += "&apos;",
            _ if u as u32 >= 32 || u == '\t' => r.push(u),
            _ => {}
        }
    }
    r
}

struct Asset {
    id: String,
    media: MediaRef,
    has_video: bool,
    has_audio: bool,
    duration: Time,
}

/// A connected clip: lane number (video above V1 count up, audio count down from -1) and the audio it carries.
#[derive(Clone, Copy)]
struct Lane<'a> {
    clip: &'a Clip,
    lane: i64,
    partner: Option<&'a Clip>,
}

/// One element of the storyline or a connected clip, with what hangs off it.
struct Node<'a> {
    clip: Option<&'a Clip>, // None = gap
    pos: Time,
    duration: Time,
    partner: Option<&'a Clip>, // linked audio folded into an asset clip
    connected: Vec<Lane<'a>>,
    markers: Vec<&'a Marker>,
}

impl<'a> Node<'a> {
    fn new(clip: Option<&'a Clip>, pos: Time, duration: Time, partner: Option<&'a Clip>) -> Self {
        Node { clip, pos, duration, partner, connected: Vec::new(), markers: Vec::new() }
    }
}

/// The template of a text generator clip; `None` for other generators or a payload this build cannot read.
fn title_text(g: &GeneratorRef) -> Option<TextTemplate> {
    if g.kind != TextGenerator::KIND {
        return None;
    }
    TextGenerator::decode(g).ok().map(|(t, _)| t)
}

/// FCPXML color attribute: "r g b a", at most 6 decimals, trailing zeros dropped.
fn color_string(c: &RGBAColor) -> String {
    let f = |v: f64| {
        let mut s = format!("{v:.6}");
        while s.ends_with('0') {
            s.pop();
        }
        if s.ends_with('.') {
            s.pop();
        }
        s
    };
    format!("{} {} {} {}", f(c.red), f(c.green), f(c.blue), f(c.alpha))
}

/// A point size without a trailing ".0".
fn point_size(v: f64) -> String {
    if v == v.round() { format!("{}", v as i64) } else { format!("{v:.2}") }
}

/// Splits at `\n` the way Swift splits Characters: a CR LF pair is one Character and no separator.
fn split_lines(text: &str) -> Vec<String> {
    let mut parts = vec![String::new()];
    let mut it = text.chars().peekable();
    while let Some(c) = it.next() {
        match c {
            '\n' => parts.push(String::new()),
            '\r' if it.peek() == Some(&'\n') => {
                it.next();
                if let Some(p) = parts.last_mut() {
                    p.push_str("\r\n");
                }
            }
            _ => {
                if let Some(p) = parts.last_mut() {
                    p.push(c);
                }
            }
        }
    }
    parts
}

struct Render<'a> {
    fd: Time,
    target: FcpxmlTarget,
    w: Warnings,
    x: Vec<String>,
    by_id: HashMap<Id, &'a MediaRef>,
    assets: HashMap<Id, usize>,
    asset_order: Vec<Asset>,
    title_fx: String,
    style_count: usize,
}

impl<'a> Render<'a> {
    fn ts(&self, t: Time) -> String {
        if self.target == FcpxmlTarget::FinalCut { frame_aligned_string(t, self.fd) } else { time_string(t) }
    }

    fn line(&mut self, depth: usize, s: &str) {
        self.x.push(format!("{}{s}", "    ".repeat(depth)));
    }

    fn marker_line(&self, m: &Marker, start: Time) -> String {
        let mut s = format!(
            "<marker start=\"{}\" duration=\"{}\" value=\"{}\"",
            self.ts(start),
            self.ts(m.duration.max(self.fd)),
            escape(&m.name)
        );
        if !m.comment.is_empty() {
            s += &format!(" note=\"{}\"", escape(&m.comment));
        }
        s + "/>"
    }

    /// The channel choice of a clip's media as `audio-channel-source` (1-based source channel, output L/R). A plain
    /// stereo file or no choice writes nothing.
    fn channel_sources(&self, c: &Clip) -> Vec<String> {
        let Some(map) = self
            .by_id
            .get(&c.media)
            .and_then(|m| m.info.as_ref())
            .and_then(|i| i.audio.as_ref())
            .and_then(|a| a.channel_map.as_ref())
        else {
            return Vec::new();
        };
        if map.left() == [0] && map.right() == [1] {
            return Vec::new();
        }
        let mut all: Vec<i64> = map.left().iter().chain(map.right()).copied().collect();
        all.sort_unstable();
        all.dedup();
        all.into_iter()
            .map(|ch| {
                let (l, r) = (map.left().contains(&ch), map.right().contains(&ch));
                let out = if l && r {
                    "L, R"
                } else if l {
                    "L"
                } else {
                    "R"
                };
                format!("<audio-channel-source srcCh=\"{}\" outCh=\"{out}\" active=\"1\"/>", ch + 1)
            })
            .collect()
    }

    fn time_map(&mut self, c: &Clip) -> Option<Vec<String>> {
        let end = self.ts(c.duration());
        let lines = |a: String, b: String| {
            vec![
                "<timeMap>".to_string(),
                format!("    <timept time=\"0s\" value=\"{a}\" interp=\"linear\"/>"),
                format!("    <timept time=\"{end}\" value=\"{b}\" interp=\"linear\"/>"),
                "</timeMap>".to_string(),
            ]
        };
        if let Some(h) = c.hold_frame {
            return Some(lines(self.ts(h), self.ts(h)));
        }
        let mut reversed = c.reversed;
        let (mut from, mut to) = (c.source.start, c.source.end());
        if c.speed_keys.is_some() {
            reversed = false;
            self.w.warn(format!("Speed ramp on \"{}\" written at its average speed", c.name));
        }
        if c.speed.is_normal() && !reversed && c.speed_keys.is_none() {
            return None;
        }
        if reversed {
            std::mem::swap(&mut from, &mut to);
        }
        Some(lines(self.ts(from), self.ts(to)))
    }

    fn children(&mut self, n: &Node<'a>, depth: usize, local_start: Time) {
        for l in &n.connected {
            let child = Node::new(Some(l.clip), l.clip.start, l.clip.duration(), l.partner);
            self.emit(&child, depth, local_start + (l.clip.start - n.pos), Some(l.lane), l.partner.is_some());
        }
        for m in &n.markers {
            let s = self.marker_line(m, local_start + (m.time - n.pos));
            self.line(depth, &s);
        }
    }

    fn emit(&mut self, n: &Node<'a>, depth: usize, offset: Time, lane: Option<i64>, partnered: bool) {
        if let Some((c, t)) = n.clip.and_then(|c| Some((c, title_text(c.generator.as_ref()?)?))) {
            self.style_count += 1;
            let ts = format!("ts{}", self.style_count);
            let mut attrs = format!("ref=\"{}\"", self.title_fx);
            if let Some(l) = lane {
                attrs += &format!(" lane=\"{l}\"");
            }
            attrs += &format!(
                " offset=\"{}\" name=\"{}\" start=\"0s\" duration=\"{}\"",
                self.ts(offset),
                escape(&c.name),
                self.ts(n.duration)
            );
            self.line(depth, &format!("<title {attrs}>"));
            let text = split_lines(&t.text).iter().map(|p| escape(p)).collect::<Vec<_>>().join("&#10;");
            self.line(depth + 1, &format!("<text><text-style ref=\"{ts}\">{text}</text-style></text>"));
            let st = &t.style;
            let mut style = format!(
                "font=\"{}\" fontSize=\"{}\" fontColor=\"{}\"",
                escape(&st.font_name),
                point_size(st.size),
                color_string(&st.color)
            );
            if st.weight >= FontWeight::Bold {
                style += " bold=\"1\"";
            }
            if st.italic {
                style += " italic=\"1\"";
            }
            style += &format!(" alignment=\"{}\"", raw_name(&st.alignment));
            self.line(depth + 1, &format!("<text-style-def id=\"{ts}\"><text-style {style}/></text-style-def>"));
            self.children(n, depth + 1, Time::ZERO);
            self.line(depth, "</title>");
            return;
        }
        if let Some(c) = n.clip {
            let tag = if partnered {
                "asset-clip"
            } else if c.kind == TrackKind::Video {
                "video"
            } else {
                "audio"
            };
            let asset_id = self.assets.get(&c.media).map_or("r0", |i| self.asset_order[*i].id.as_str());
            let mut attrs = format!("ref=\"{asset_id}\"");
            if let Some(l) = lane {
                attrs += &format!(" lane=\"{l}\"");
            }
            attrs += &format!(
                " offset=\"{}\" name=\"{}\" start=\"{}\" duration=\"{}\"",
                self.ts(offset),
                escape(&c.name),
                self.ts(c.source.start),
                self.ts(n.duration)
            );
            let map = self.time_map(c);
            let mut own: Vec<&Marker> = if c.hold_frame.is_some() {
                Vec::new()
            } else {
                c.markers.iter().flatten().filter(|m| m.time >= c.source.start && m.time < c.source.end()).collect()
            };
            own.sort_by_key(|m| m.time);
            let channels = if tag == "video" { Vec::new() } else { self.channel_sources(c) };
            let has_children = map.is_some()
                || !n.connected.is_empty()
                || !n.markers.is_empty()
                || !own.is_empty()
                || !channels.is_empty();
            if !has_children {
                self.line(depth, &format!("<{tag} {attrs}/>"));
                return;
            }
            self.line(depth, &format!("<{tag} {attrs}>"));
            for l in map.iter().flatten() {
                self.line(depth + 1, l);
            }
            self.children(n, depth + 1, c.source.start);
            for m in own {
                let s = self.marker_line(m, m.time);
                self.line(depth + 1, &s);
            }
            for l in &channels {
                self.line(depth + 1, l);
            }
            self.line(depth, &format!("</{tag}>"));
        } else {
            let attrs = format!(
                "name=\"Gap\" offset=\"{}\" start=\"0s\" duration=\"{}\"",
                self.ts(offset),
                self.ts(n.duration)
            );
            if n.connected.is_empty() && n.markers.is_empty() {
                self.line(depth, &format!("<gap {attrs}/>"));
                return;
            }
            self.line(depth, &format!("<gap {attrs}>"));
            self.children(n, depth + 1, Time::ZERO);
            self.line(depth, "</gap>");
        }
    }
}

impl FcpxmlWriter {
    /// FCPXML 1.8 for Resolve.
    pub fn render(timeline: &Timeline, media: &[MediaRef]) -> InterchangeExport {
        Self::render_as(timeline, media, FcpxmlVersion::V1_8, FcpxmlTarget::Resolve)
    }

    /// The sequence as FCPXML of `version`, times written for `target`.
    pub fn render_as(
        timeline: &Timeline,
        media: &[MediaRef],
        version: FcpxmlVersion,
        target: FcpxmlTarget,
    ) -> InterchangeExport {
        let fd = timeline.format.frame_duration;
        let mut w = Warnings::default();

        let mut usable = |c: &Clip| -> bool {
            if let Some(g) = &c.generator {
                if title_text(g).is_some() {
                    if !c.is_enabled {
                        w.warn(format!("Disabled clip \"{}\" skipped", c.name));
                    }
                    return c.is_enabled;
                }
                w.warn(format!("Generator clip \"{}\" is not exported", c.name));
                return false;
            }
            if c.is_nested() {
                w.warn(format!("Nested sequence \"{}\" is not exported", c.name));
                return false;
            }
            if !c.is_enabled {
                w.warn(format!("Disabled clip \"{}\" skipped", c.name));
                return false;
            }
            true
        };
        let video_tracks: Vec<_> = timeline.tracks.iter().filter(|t| t.kind == TrackKind::Video).collect();
        let audio_tracks: Vec<_> = timeline.tracks.iter().filter(|t| t.kind == TrackKind::Audio).collect();
        let video_clips: Vec<Vec<&Clip>> =
            video_tracks.iter().map(|t| t.clips().iter().filter(|c| usable(c)).collect()).collect();
        let mut audio_clips: Vec<Vec<&Clip>> =
            audio_tracks.iter().map(|t| t.clips().iter().filter(|c| usable(c)).collect()).collect();

        // A video clip takes the audio clip over the same media range as its sound.
        let mut partner_of = |v: &Clip| -> Option<&Clip> {
            for list in audio_clips.iter_mut() {
                let hit = list.iter().position(|a| {
                    a.media == v.media
                        && a.start == v.start
                        && a.duration() == v.duration()
                        && a.source.start == v.source.start
                        && a.speed == v.speed
                        && a.reversed == v.reversed
                });
                if let Some(i) = hit {
                    return Some(list.remove(i));
                }
            }
            None
        };

        let mut nodes: Vec<Node> = Vec::new();
        let mut lanes: Vec<Lane> = Vec::new();
        for (ti, list) in video_clips.iter().enumerate() {
            for &c in list {
                let p = partner_of(c);
                if ti == 0 {
                    nodes.push(Node::new(Some(c), c.start, c.duration(), p));
                } else {
                    lanes.push(Lane { clip: c, lane: ti as i64, partner: p });
                }
            }
        }
        for (ti, list) in audio_clips.iter().enumerate() {
            for &c in list {
                lanes.push(Lane { clip: c, lane: -(ti as i64 + 1), partner: None });
            }
        }

        let total = nodes
            .iter()
            .map(|n| n.pos + n.duration)
            .chain(lanes.iter().map(|l| l.clip.timeline().end()))
            .max()
            .unwrap_or(Time::ZERO);
        if total == Time::ZERO {
            w.warn("The sequence has no clips FCPXML can carry");
        }

        // Gaps between storyline clips, so the spine covers the whole sequence.
        let mut spine: Vec<Node> = Vec::new();
        let mut cursor = Time::ZERO;
        for n in nodes {
            if n.pos > cursor {
                spine.push(Node::new(None, cursor, n.pos - cursor, None));
            }
            cursor = n.pos + n.duration;
            spine.push(n);
        }
        if cursor < total {
            spine.push(Node::new(None, cursor, total - cursor, None));
        }

        let owner = |spine: &[Node], t: Time| spine.iter().position(|n| n.pos <= t && t < n.pos + n.duration);
        lanes.sort_by_key(|l| (l.lane, l.clip.start));
        for l in lanes {
            if let Some(i) = owner(&spine, l.clip.start) {
                spine[i].connected.push(l);
            }
        }
        for m in &timeline.markers {
            match owner(&spine, m.time) {
                Some(i) => spine[i].markers.push(m),
                None => w.warn(format!("Marker \"{}\" lies outside the clips", m.name)),
            }
        }

        // Resources: assets in the order of the media list, only those used.
        struct Used {
            video: bool,
            audio: bool,
            end: Time,
        }
        let mut used: HashMap<Id, Used> = HashMap::new();
        let mut used_order: Vec<Id> = Vec::new();
        let mut note = |c: &Clip, partnered: bool| {
            if c.is_generator() {
                return;
            }
            if !used.contains_key(&c.media) {
                used_order.push(c.media);
            }
            let u = used.entry(c.media).or_insert(Used { video: false, audio: false, end: Time::ZERO });
            if c.kind == TrackKind::Video {
                u.video = true;
            }
            if c.kind == TrackKind::Audio || partnered {
                u.audio = true;
            }
            u.end = u.end.max(c.source.end());
        };
        for n in &spine {
            if let Some(c) = n.clip {
                note(c, n.partner.is_some());
            }
            for l in &n.connected {
                note(l.clip, l.partner.is_some());
            }
        }
        let mut assets: HashMap<Id, usize> = HashMap::new();
        let mut asset_order: Vec<Asset> = Vec::new();
        let mut next_id = 2;
        let mut add_asset = |m: &MediaRef| -> bool {
            let Some(u) = used.get(&m.id) else { return false };
            if assets.contains_key(&m.id) {
                return false;
            }
            let video = m.info.as_ref().is_some_and(|i| i.video.is_some()) || u.video;
            let audio = m.info.as_ref().is_some_and(|i| i.audio.is_some()) || u.audio;
            let duration = m.duration.or(m.info.as_ref().map(|i| i.duration)).unwrap_or(u.end);
            assets.insert(m.id, asset_order.len());
            asset_order.push(Asset {
                id: format!("r{next_id}"),
                media: m.clone(),
                has_video: video,
                has_audio: audio,
                duration,
            });
            next_id += 1;
            true
        };
        for m in media {
            add_asset(m);
        }
        for id in &used_order {
            // clip whose media is not in the list: placeholder asset
            if add_asset(&MediaRef::new(*id, "Offline", "", MediaFingerprint::new(0))) {
                w.warn("Media of a clip is missing from the project; written as an offline asset");
            }
        }

        let tc_start = timeline.timecode_start();
        let tc_drop = CmxTimecode::from_frame_duration(fd, true).drop_frame();
        let need_title_effect = video_clips.iter().flatten().any(|c| c.is_generator());
        let mut r = Render {
            fd,
            target,
            w,
            x: Vec::new(),
            by_id: media_by_id(media),
            assets,
            asset_order,
            title_fx: format!("r{next_id}"),
            style_count: 0,
        };

        // Dissolves in the primary storyline: between two storyline clips that touch.
        let mut need_dissolve_effect = false;
        let mut transition_after: HashMap<usize, Vec<String>> = HashMap::new();
        if let Some(first) = video_tracks.first() {
            for tr in &first.transitions {
                let found = tr.outgoing.zip(tr.incoming).and_then(|(o, i)| {
                    let oi = spine.iter().position(|n| n.clip.map(|c| c.id) == Some(o))?;
                    (oi + 1 < spine.len() && spine[oi + 1].clip.map(|c| c.id) == Some(i)).then_some(oi)
                });
                let Some(oi) = found else {
                    r.w.warn("A transition that is not between two touching clips is not exported");
                    continue;
                };
                let cut = spine[oi + 1].pos;
                let start = match tr.alignment {
                    TransitionAlignment::Center => cut - tr.duration.halved().snapped(fd),
                    TransitionAlignment::StartAtCut => cut,
                    TransitionAlignment::EndAtCut => cut - tr.duration,
                    TransitionAlignment::Custom => cut - tr.custom_before,
                };
                if tr.kind != TransitionKind::CrossDissolve && tr.kind != TransitionKind::QuickFade {
                    r.w.warn(format!("Transition \"{}\" written as Cross Dissolve", raw_name(&tr.kind)));
                }
                need_dissolve_effect = true;
                transition_after.insert(
                    oi,
                    vec![
                        format!(
                            "<transition name=\"Cross Dissolve\" offset=\"{}\" duration=\"{}\">",
                            r.ts(start.max(Time::ZERO) + tc_start),
                            r.ts(tr.duration)
                        ),
                        "    <filter-video ref=\"rfx\" name=\"Cross Dissolve\"/>".to_string(),
                        "</transition>".to_string(),
                    ],
                );
            }
        }

        let fx = format!("r{}", next_id + usize::from(need_title_effect));
        r.line(0, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
        r.line(0, "<!DOCTYPE fcpxml>");
        r.line(0, &format!("<fcpxml version=\"{}\">", version.raw()));
        r.line(1, "<resources>");
        let mut format_attrs = format!(
            "id=\"r1\" frameDuration=\"{}\" width=\"{}\" height=\"{}\"",
            r.ts(fd),
            timeline.format.width,
            timeline.format.height
        );
        if target == FcpxmlTarget::FinalCut && version.has_media_rep() {
            format_attrs += " colorSpace=\"1-1-1 (Rec. 709)\"";
        }
        r.line(2, &format!("<format {format_attrs}/>"));
        for i in 0..r.asset_order.len() {
            let a = &r.asset_order[i];
            let url = if a.media.path.is_empty() { String::new() } else { file_url(&a.media.path) };
            let mut s = format!(
                "<asset id=\"{}\" name=\"{}\" start=\"0s\" duration=\"{}\"",
                a.id,
                escape(&a.media.name),
                r.ts(a.duration)
            );
            s += &format!(" hasVideo=\"{}\" hasAudio=\"{}\"", u8::from(a.has_video), u8::from(a.has_audio));
            if a.has_video {
                s += " format=\"r1\"";
            }
            if url.is_empty() {
                r.line(2, &format!("{s}/>"));
            } else if version.has_media_rep() {
                r.line(2, &format!("{s}>"));
                r.line(3, &format!("<media-rep kind=\"original-media\" src=\"{}\"/>", escape(&url)));
                r.line(2, "</asset>");
            } else {
                r.line(2, &format!("{s} src=\"{}\"/>", escape(&url)));
            }
        }
        if need_title_effect {
            let s = format!(
                "<effect id=\"{}\" name=\"Basic Title\" uid=\".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti\"/>",
                r.title_fx
            );
            r.line(2, &s);
        }
        if need_dissolve_effect {
            r.line(
                2,
                &format!(
                    "<effect id=\"{fx}\" name=\"Cross Dissolve\" uid=\"FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265\"/>"
                ),
            );
        }
        r.line(1, "</resources>");
        r.line(1, "<library>");
        r.line(2, "<event name=\"Sequence Studio\">");
        r.line(3, &format!("<project name=\"{}\">", escape(&timeline.name)));
        let rate = timeline.format.audio_sample_rate;
        let audio_rate = if rate == 44_100 {
            "44.1k"
        } else if rate == 96_000 {
            "96k"
        } else {
            "48k"
        };
        let s = format!(
            "<sequence format=\"r1\" duration=\"{}\" tcStart=\"{}\" tcFormat=\"{}\" audioLayout=\"stereo\" audioRate=\"{audio_rate}\">",
            r.ts(total),
            r.ts(tc_start),
            if tc_drop { "DF" } else { "NDF" }
        );
        r.line(4, &s);
        r.line(5, "<spine>");
        for (i, n) in spine.iter().enumerate() {
            r.emit(n, 6, n.pos + tc_start, None, n.partner.is_some());
            if let Some(t) = transition_after.get(&i) {
                for l in t {
                    r.line(6, &l.replace("rfx", &fx));
                }
            }
        }
        r.line(5, "</spine>");
        r.line(4, "</sequence>");
        r.line(3, "</project>");
        r.line(2, "</event>");
        r.line(1, "</library>");
        r.line(0, "</fcpxml>");
        InterchangeExport::new(r.x.join("\n") + "\n", r.w.0)
    }
}
