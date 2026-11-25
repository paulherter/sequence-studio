// SPDX-License-Identifier: GPL-3.0-or-later
//! Swift: PRMapper.swift. `PRDocument` -> project model. Maps only to existing model features; everything else lands in the
//! report. Coordinates: Premiere points are normalized (Motion/Geometry2 Position to the frame they live in, Motion Anchor
//! to the clip's own frame); SQ uses px offsets from the center (sequence px for Motion position, clip px for anchors and
//! stages).
//!
//! The Swift file is split by topic: `audio`, `effects`, `lumetri`, `shapes` and `text` are children of this module.

mod audio;
mod effects;
mod lumetri;
pub(crate) mod masks;
pub(crate) mod shapes;
pub(crate) mod text;

use crate::interchange_model::LinkKey;
use crate::prcontainer::PRTicks;
use crate::prdocument::{
    PRDocument, PRItem, PRMarker, PRMedia, PRParamValue, PRSequence, PRSource, PRTrack, PRTransitionItem,
};
use crate::primport_report::{Location, PRImportReport, Status};
use sq_core_color::{ClipEffectColorExt, ColorMatteColor, ColorMatteGeneratorExt};
use sq_core_effects::adjustment_clip::adjustment_layer;
use sq_core_effects::transition::TransitionExt;
use sq_core_model::{
    AnimatedProperty, BlendMode, Clip, ClipAnimation, ClipFootageColor, ClipSpeed, ColorSpaceID, EffectColor,
    GeneratorRef, Marker, MarkerColor, MediaFingerprint, MediaRef, Project, SequenceFormat, Timeline, Track, TrackKind,
    Transition, TransitionAlignment, TransitionKind,
};
use sq_core_project::media_path_resolver::{Hit, MediaPathResolver, Request};
use sq_core_time::{
    EaseHandle, Id, IdSource, Interpolation, Keyframe, KeyframeTrack, KeyframeValue, Time, TimeRange, Vec2,
};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

/// The mapped project and what the import did with each feature.
#[derive(Debug, Clone)]
pub struct PRImportResult {
    pub project: Project,
    pub report: PRImportReport,
}

/// Extensions of still image files (judged by name when the media is not probed).
pub(crate) const STILL_EXTENSIONS: [&str; 14] =
    ["png", "jpg", "jpeg", "tif", "tiff", "heic", "heif", "gif", "bmp", "webp", "psd", "tga", "exr", "dpx"];

/// `SequenceFormat.sanitized()` with the probe fallback (1920x1080 at 1/30 s, 48 kHz).
pub(crate) fn sanitized_format(f: &SequenceFormat) -> SequenceFormat {
    f.sanitized(&SequenceFormat::new(Time::new(1, 30)))
}

/// Every media path of the sequences' video and audio items, in order of first use.
fn media_items(doc: &PRDocument) -> Vec<&PRMedia> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();
    for s in &doc.sequences {
        for item in s.video_tracks.iter().chain(&s.audio_tracks).flat_map(|t| &t.items) {
            if let PRSource::Media(m) = &item.source
                && let Some(p) = &m.path
                && seen.insert(p.clone())
            {
                out.push(m);
            }
        }
    }
    out
}

/// Maps Premiere documents.
pub struct PRMapper;

impl PRMapper {
    /// Absolute paths of every media file the document uses (what the caller should probe before `map`).
    pub fn media_paths(doc: &PRDocument) -> Vec<String> {
        media_items(doc).into_iter().filter_map(|m| m.path.clone()).collect()
    }

    /// Where each stored media path is on this machine (`MediaPathResolver` order: as stored, RelativePath against the
    /// project folder, same name in the project folder tree and its parent, then `search_folders` from earlier Locates).
    /// Keyed by the stored path (what `map` expects); unresolved paths are absent. File I/O: call off the main thread.
    pub fn resolve_media(doc: &PRDocument, project_file: &Path, search_folders: Vec<PathBuf>) -> BTreeMap<String, Hit> {
        let requests: Vec<Request> = media_items(doc)
            .into_iter()
            .filter_map(|m| {
                let mut r = Request::new(m.path.as_deref()?);
                r.relative_path = m.relative_path.clone();
                Some(r)
            })
            .collect();
        MediaPathResolver::new(project_file.parent().map(Path::to_path_buf), search_folders).resolve(&requests)
    }

    /// `media`: probed refs by absolute path (the app probes before mapping); paths without one get a placeholder ref
    /// (offline until relinked). `shapes`: map the Shape layers of a graphic onto Graphics layers (templates); a project
    /// import leaves them out.
    pub fn map(
        doc: &PRDocument,
        name: &str,
        media: &BTreeMap<String, MediaRef>,
        shapes: bool,
        ids: &mut dyn IdSource,
    ) -> PRImportResult {
        // shortcut: the Swift importer wraps this in FontResolver.withScopedCache; add it with the text generator (see
        // `text.rs`) so point text resolves each font once per map.
        let mut m = Mapping::new(doc, media, ids);
        m.map_shapes = shapes;
        let timelines: Vec<Timeline> = doc.sequences.iter().map(|s| m.timeline(s)).collect();
        // Active: a sequence no other one nests, the longest such.
        let nested: BTreeSet<&str> = doc
            .sequences
            .iter()
            .flat_map(|s| {
                let cyclic = &m.cyclic_edges;
                s.video_tracks.iter().chain(&s.audio_tracks).flat_map(|t| &t.items).filter_map(move |i| {
                    match &i.source {
                        PRSource::Sequence { id } if !cyclic.contains(&format!("{}|{id}", s.id)) => Some(id.as_str()),
                        _ => None,
                    }
                })
            })
            .collect();
        let mut top: Option<&PRSequence> = None;
        for s in doc.sequences.iter().filter(|s| !nested.contains(s.id.as_str())) {
            // Swift `max(by:)` keeps the first of equal lengths.
            if top.is_none_or(|t| Mapping::length_of(t) < Mapping::length_of(s)) {
                top = Some(s);
            }
        }
        let media_list: Vec<MediaRef> = m.media_order.iter().filter_map(|k| m.refs.get(k).cloned()).collect();
        let active = top.and_then(|t| m.timeline_ids.get(&t.id).copied());
        let report = std::mem::take(&mut m.report);
        let mut project = Project::new(m.ids.next_id(), name, media_list, timelines);
        if active.is_some() {
            project.active_timeline = active;
        }
        PRImportResult { project, report }
    }
}

/// Premiere's marker colors in index order (0 green, 1 red, ...).
const MARKER_COLORS: [MarkerColor; 8] = [
    MarkerColor::Green,
    MarkerColor::Red,
    MarkerColor::Purple,
    MarkerColor::Orange,
    MarkerColor::Yellow,
    MarkerColor::White,
    MarkerColor::Blue,
    MarkerColor::Cyan,
];

/// The state of one mapping run.
pub(crate) struct Mapping<'a> {
    pub(crate) refs: BTreeMap<String, MediaRef>,
    pub(crate) media_order: Vec<String>,
    pub(crate) timeline_ids: BTreeMap<String, Id>,
    pub(crate) report: PRImportReport,
    pub(crate) map_shapes: bool,
    sequences: BTreeMap<String, &'a PRSequence>,
    /// Nesting edges "from|to" that close a cycle (A nests B nests A): dropped on import.
    pub(crate) cyclic_edges: BTreeSet<String>,
    pub(crate) ids: &'a mut dyn IdSource,
    /// Masks collected by `effects` for the clip being built (taken by `take_masks`).
    pub(crate) pending_masks: Vec<sq_core_model::ClipMask>,
}

impl<'a> Mapping<'a> {
    pub(crate) fn new(
        doc: &'a PRDocument,
        probed: &BTreeMap<String, MediaRef>,
        ids: &'a mut dyn IdSource,
    ) -> Mapping<'a> {
        let mut timeline_ids = BTreeMap::new();
        let mut sequences = BTreeMap::new();
        for s in &doc.sequences {
            timeline_ids.insert(s.id.clone(), ids.next_id());
            sequences.insert(s.id.clone(), s);
        }
        Mapping {
            refs: probed.clone(),
            media_order: Vec::new(),
            timeline_ids,
            report: PRImportReport::default(),
            map_shapes: false,
            sequences,
            cyclic_edges: Self::cyclic_nesting(&doc.sequences),
            ids,
            pending_masks: Vec::new(),
        }
    }

    fn nested_ids(s: &PRSequence) -> Vec<&str> {
        s.video_tracks
            .iter()
            .chain(&s.audio_tracks)
            .flat_map(|t| &t.items)
            .filter_map(|i| match &i.source {
                PRSource::Sequence { id } => Some(id.as_str()),
                _ => None,
            })
            .collect()
    }

    /// Back edges of the nesting graph (depth-first in document order): removing them leaves it acyclic.
    fn cyclic_nesting(list: &[PRSequence]) -> BTreeSet<String> {
        let mut edges: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
        let mut known: BTreeSet<&str> = BTreeSet::new();
        for s in list {
            known.insert(&s.id);
            edges.insert(&s.id, Self::nested_ids(s));
        }
        let mut state: BTreeMap<&str, u8> = BTreeMap::new(); // 1 = on the stack, 2 = done
        let mut back = BTreeSet::new();
        for root in list.iter().map(|s| s.id.as_str()) {
            if state.contains_key(root) {
                continue;
            }
            let mut stack: Vec<(&str, usize)> = vec![(root, 0)];
            state.insert(root, 1);
            while let Some(&(node, i)) = stack.last() {
                let out = edges.get(node).map_or(&[][..], Vec::as_slice);
                if i >= out.len() {
                    state.insert(node, 2);
                    stack.pop();
                    continue;
                }
                if let Some(top) = stack.last_mut() {
                    top.1 += 1;
                }
                let next = out[i];
                if !known.contains(next) {
                    continue;
                }
                match state.get(next) {
                    Some(1) => {
                        back.insert(format!("{node}|{next}"));
                    }
                    None => {
                        state.insert(next, 1);
                        stack.push((next, 0));
                    }
                    _ => {}
                }
            }
        }
        back
    }

    pub(crate) fn length_of(s: &PRSequence) -> i64 {
        s.video_tracks.iter().chain(&s.audio_tracks).flat_map(|t| &t.items).map(|i| i.end).max().unwrap_or(0)
    }

    // MARK: Sequences and tracks

    pub(crate) fn timeline(&mut self, s: &PRSequence) -> Timeline {
        use Status::Mapped;
        let mut format = SequenceFormat::new(s.frame_duration);
        format.width = s.width;
        format.height = s.height;
        let format = sanitized_format(&format);
        let all: Vec<(TrackKind, &PRTrack)> = s
            .video_tracks
            .iter()
            .map(|t| (TrackKind::Video, t))
            .chain(s.audio_tracks.iter().map(|t| (TrackKind::Audio, t)))
            .collect();
        let mut lanes: Vec<Vec<Clip>> = all.iter().map(|(kind, t)| self.clips(t, *kind, s)).collect();
        let kinds: Vec<TrackKind> = all.iter().map(|a| a.0).collect();
        self.link(&mut lanes, &kinds);
        let (mut videos, mut audios) = (0, 0);
        let mut tracks = Vec::new();
        for ((kind, t), clips) in all.iter().zip(lanes) {
            let n = if *kind == TrackKind::Video { &mut videos } else { &mut audios };
            *n += 1;
            let mut track = Track::new(self.ids.next_id(), *kind);
            track.name = format!("{}{n}", if *kind == TrackKind::Video { "V" } else { "A" });
            track.is_muted = t.is_muted && *kind == TrackKind::Audio;
            // A muted video track is Premiere's "output off" (the eye): hidden in SQ.
            if t.is_muted && *kind == TrackKind::Video {
                track.is_visible = false;
            }
            if t.is_muted {
                self.report.note(
                    if *kind == TrackKind::Audio { "Track mute" } else { "Video track output off" },
                    Mapped,
                    "",
                );
            }
            track.transitions = t.transitions.iter().filter_map(|x| self.transition(x, *kind, &clips, s)).collect();
            track.set_clips(clips);
            tracks.push(track);
        }
        let id = self.timeline_ids.get(&s.id).copied().unwrap_or(Id::NIL);
        let mut timeline = Timeline::new(id, &s.name, format, tracks);
        timeline.markers =
            s.markers.iter().map(|m| self.sequence_marker(m, PRTicks::time(m.ticks), s.frame_duration)).collect();
        if !s.markers.is_empty() {
            self.report.note("Sequence markers", Mapped, &s.markers.len().to_string());
        }
        timeline
    }

    fn clips(&mut self, t: &PRTrack, kind: TrackKind, seq: &PRSequence) -> Vec<Clip> {
        let mut clips: Vec<Clip> = Vec::new();
        for item in &t.items {
            let Some(c) = self.clip(item, kind, seq) else { continue };
            if clips.last().is_some_and(|last| last.timeline().end() > c.start) {
                self.report.note(
                    "Overlapping clip",
                    Status::Dropped,
                    "a clip starting inside the previous one on the same track",
                );
                continue;
            }
            clips.push(c);
        }
        clips
    }

    fn transition(
        &mut self,
        t: &PRTransitionItem,
        track_kind: TrackKind,
        clips: &[Clip],
        seq: &PRSequence,
    ) -> Option<Transition> {
        let start = PRTicks::time(t.start);
        let end = PRTicks::time(t.end);
        let n = t.match_name.as_str();
        let audio = track_kind == TrackKind::Audio;
        let (kind, name) = if audio && n.contains("Constant Gain") {
            (TransitionKind::ConstantGain, "constantGain")
        } else if audio && n.contains("Constant Power") {
            (TransitionKind::ConstantPower, "constantPower")
        } else if audio {
            // Exponential Fade, Custom Fade (curve unknown): SQ's default audio crossfade.
            self.report.note(&format!("Transition {n}"), Status::Approximated, "played as Constant Power");
            (TransitionKind::ConstantPower, "constantPower")
        } else if n.contains("Cross Dissolve") || n.contains("Impact_Dissolve") {
            (TransitionKind::CrossDissolve, "Cross Dissolve")
        } else if n.contains("Dip to Black") || n.contains("DipToBlack") {
            (TransitionKind::DipToBlack, "dipToBlack")
        } else if n.contains("Dip to White") || n.contains("DipToWhite") {
            (TransitionKind::DipToWhite, "dipToWhite")
        } else {
            self.report.note(&format!("Transition {n}"), Status::Approximated, "played as Cross Dissolve");
            (TransitionKind::CrossDissolve, "Cross Dissolve")
        };
        // The cut: a clip ending inside the transition span, or the span's edge for a one-sided one.
        let out = clips.iter().find(|c| c.timeline().end() > start && c.timeline().end() <= end);
        let inc = clips.iter().find(|c| c.start >= start && c.start < end && Some(c.id) != out.map(|o| o.id));
        if out.is_none() && inc.is_none() {
            self.report.note("Transition", Status::Dropped, "no clip at its cut");
            return None;
        }
        let mut tr = Transition::new(
            self.ids.next_id(),
            kind,
            (end - start).snapped(seq.frame_duration),
            out.map(|c| c.id),
            inc.map(|c| c.id),
        );
        let cut = out.map(|o| o.timeline().end()).or(inc.map(|i| i.start))?;
        if cut == start {
            tr.alignment = TransitionAlignment::StartAtCut;
        } else if cut == end {
            tr.alignment = TransitionAlignment::EndAtCut;
        } else if cut - start != end - cut {
            tr.alignment = TransitionAlignment::Custom;
            tr.custom_before = cut - start;
        }
        self.report.note(name, Status::Mapped, "");
        Some(tr)
    }

    /// Links video and audio clips of the same media over the same range (Premiere's linked A/V pair; stereo pairs on two
    /// audio tracks join the same link).
    fn link(&mut self, lanes: &mut [Vec<Clip>], kinds: &[TrackKind]) {
        let mut by_key: Vec<(LinkKey, Vec<(usize, usize)>)> = Vec::new();
        for (li, lane) in lanes.iter().enumerate() {
            for (ci, c) in lane.iter().enumerate().filter(|(_, c)| !c.is_generator()) {
                let key = (c.media, c.start, c.timeline().end());
                match by_key.iter_mut().find(|(k, _)| *k == key) {
                    Some((_, v)) => v.push((li, ci)),
                    None => by_key.push((key, vec![(li, ci)])),
                }
            }
        }
        for (_, members) in by_key {
            let has_video = members.iter().any(|m| kinds[m.0] == TrackKind::Video);
            let has_audio = members.iter().any(|m| kinds[m.0] == TrackKind::Audio);
            if !has_video || !has_audio || members.iter().filter(|m| kinds[m.0] == TrackKind::Video).count() != 1 {
                continue;
            }
            let id = self.ids.next_id();
            for (li, ci) in members {
                lanes[li][ci].link = Some(id);
            }
        }
    }

    // MARK: Clips

    fn media_ref(&mut self, m: &PRMedia) -> Option<MediaRef> {
        let path = m.path.as_ref()?;
        if !self.refs.contains_key(path) {
            let r = MediaRef::new(self.ids.next_id(), &m.title, path, MediaFingerprint::new(0));
            self.refs.insert(path.clone(), r);
            self.report.note(
                "Offline media",
                Status::Approximated,
                "not probed (missing file): placeholder until relinked",
            );
        }
        if !self.media_order.contains(path) {
            self.media_order.push(path.clone());
        }
        self.refs.get(path).cloned()
    }

    /// Maps one item and ties every approximated / dropped note it caused to the new clip, for the checklist's "Show".
    pub(crate) fn clip(&mut self, item: &PRItem, kind: TrackKind, seq: &PRSequence) -> Option<Clip> {
        self.report.begin_collect();
        let c = self.clip_untracked(item, kind, seq);
        let loc =
            c.as_ref().and_then(|c| self.timeline_ids.get(&seq.id).map(|t| Location { timeline: *t, clip: c.id }));
        self.report.end_collect(loc);
        if let Some(loc) = loc
            && let PRSource::Media(pm) = &item.source
            && let Some(path) = &pm.path
            && let Some(r) = self.refs.get(path)
            && r.fingerprint.size == 0
            && r.info.is_none()
        {
            self.report.attach("Offline media", Status::Approximated, loc);
        }
        c
    }

    fn clip_untracked(&mut self, item: &PRItem, kind: TrackKind, seq: &PRSequence) -> Option<Clip> {
        let start = PRTicks::time(item.start);
        let end = PRTicks::time(item.end);
        if end <= start {
            return None;
        }
        if item.is_adjustment_layer {
            return self.adjustment_clip(item, kind, seq, start, end - start);
        }
        let mut speed = ClipSpeed::NORMAL;
        let mut reversed = false;
        if item.speed != 1.0 {
            speed = ClipSpeed::from_percent(item.speed.abs() * 100.0);
            reversed = item.speed < 0.0;
            self.report.note("Speed", Status::Mapped, "");
        }
        let duration = end - start;
        let source_duration = speed.scale(duration);
        let ctx = ClipContext { in_point: item.in_point, speed, sequence: seq };
        let mut c: Clip;
        let mut frame = Vec2::new(seq.width as f64, seq.height as f64);
        let mut text_offset = Vec2::ZERO;
        let mut stage_offset = Vec2::ZERO;
        let mut pixel_aspect = 1.0;
        match &item.source {
            PRSource::Media(pm) => {
                let r = self.media_ref(pm)?;
                // Unprobed (offline at import): judged by the extension, so the clip is a still before the relink probe too.
                let still = r.info.as_ref().map_or_else(
                    || STILL_EXTENSIONS.contains(&crate::interchange_model::file_extension_of(&r.path).as_str()),
                    |i| i.is_still,
                );
                // The media item already desqueezes by its own pixel aspect (the file's tag); only what Premiere's
                // interpretation adds on top of it becomes a horizontal scale, so a tagged file is not stretched twice.
                // A project that does not say how it read the pixels (no OriginalPAR) adds nothing: unknown is not square.
                let own =
                    r.info.as_ref().and_then(|i| i.video.as_ref()).map_or(1.0, |v| v.display_pixel_aspect().value());
                if let Some(v) = r.info.as_ref().and_then(|i| i.video.as_ref()) {
                    frame = Vec2::new(v.desqueezed_width() as f64, v.height as f64);
                }
                if let Some(theirs) = pm.pixel_aspect {
                    pixel_aspect = if (theirs / own - 1.0).abs() < 0.005 { 1.0 } else { theirs / own };
                }
                if pixel_aspect != 1.0 {
                    self.report.note("Pixel aspect ratio", Status::Mapped, "non-square pixels as a horizontal scale");
                }
                let name = if item.name.is_empty() { &pm.title } else { &item.name };
                let source =
                    TimeRange::new(if still { Time::ZERO } else { PRTicks::time(item.in_point) }, source_duration);
                c = Clip::new(self.ids.next_id(), name, r.id, kind, source, start);
                c.media_duration = r.duration;
                c.is_still = still;
                c.speed = speed;
                c.reversed = reversed;
            }
            PRSource::Sequence { id } => {
                let (Some(tl), Some(inner)) = (self.timeline_ids.get(id).copied(), self.sequences.get(id).copied())
                else {
                    self.report.note("Nested sequence", Status::Dropped, "unknown sequence");
                    return None;
                };
                if self.cyclic_edges.contains(&format!("{}|{id}", seq.id)) {
                    self.report.note("Nested sequence", Status::Dropped, "cyclic nesting");
                    return None;
                }
                frame = Vec2::new(inner.width as f64, inner.height as f64);
                let name = if item.name.is_empty() { &inner.name } else { &item.name };
                c = Clip::new(
                    self.ids.next_id(),
                    name,
                    tl,
                    kind,
                    TimeRange::new(PRTicks::time(item.in_point), source_duration),
                    start,
                );
                c.media_duration = Some(PRTicks::time(Self::length_of(inner)));
                c.sequence = Some(tl);
                c.speed = speed;
                c.reversed = reversed;
                self.report.note("Nested sequence", Status::Mapped, "");
            }
            PRSource::Graphic { title } => {
                if kind != TrackKind::Video {
                    return None;
                }
                let built = self.graphic_clip(item, seq, &ctx, frame, title, TimeRange::new(start, duration))?;
                (c, text_offset, stage_offset) = built;
            }
            PRSource::ColorMatte { rgb } => {
                if kind != TrackKind::Video {
                    return None;
                }
                let id = self.ids.next_id();
                let name = if item.name.is_empty() { "Color Matte" } else { &item.name };
                c = Clip::new(id, name, id, TrackKind::Video, TimeRange::new(Time::ZERO, duration), start);
                c.generator = Some(GeneratorRef::color_matte(ColorMatteColor { r: rgb[0], g: rgb[1], b: rgb[2] }));
                self.report.note("Color matte", Status::Mapped, "solid color generator");
            }
            PRSource::Unknown => {
                self.report.note("Clip without source", Status::Dropped, "");
                return None;
            }
        }
        if kind == TrackKind::Video {
            c.animation = self.motion(item, &ctx, frame, text_offset, pixel_aspect);
            c.effects = self.effects(item, &ctx, frame, stage_offset);
            self.take_masks(&mut c);
            c.blend_mode = self.blend_mode(item);
            // Premiere shows camera log as is (no source conversion) and the look LUT does the log-to-display mapping;
            // our automatic conversion would apply it twice. A look LUT therefore pins the footage to Rec. 709 as shot.
            if matches!(item.source, PRSource::Media(_))
                && c.effects.iter().any(|e| e.is_color() && e.color_data().look.is_some())
            {
                c.footage_color = ClipFootageColor {
                    source: Some(ColorSpaceID::Rec709),
                    use_embedded_lut: false,
                    ..ClipFootageColor::default()
                };
            }
            if let PRSource::Media(pm) = &item.source
                && Self::is_display_referred_709(pm.color_profile.as_deref())
            {
                self.apply_display_gamma(&mut c);
            }
        } else {
            self.audio(item, &ctx, &mut c);
        }
        self.clip_markers(item, &mut c, seq);
        self.report.note(if kind == TrackKind::Video { "Video clip" } else { "Audio clip" }, Status::Mapped, "");
        Some(c)
    }

    /// An SQ marker for a Premiere sequence marker placed at `time` (snapped to `frame`); unknown color indices become green.
    fn sequence_marker(&mut self, m: &PRMarker, time: Time, frame: Time) -> Marker {
        let duration = PRTicks::time(m.duration_ticks).snapped(frame);
        self.marker(m, time.snapped(frame), duration)
    }

    fn marker(&mut self, m: &PRMarker, time: Time, duration: Time) -> Marker {
        Marker {
            id: self.ids.next_id(),
            time,
            name: m.name.clone(),
            color: usize::try_from(m.color_index)
                .ok()
                .and_then(|i| MARKER_COLORS.get(i))
                .copied()
                .unwrap_or(MarkerColor::Green),
            comment: m.comment.clone(),
            duration,
        }
    }

    /// Clip markers (media ticks, like the in point) as `Clip.markers` in SQ source time: `source.start` is the in point
    /// for media and nested clips and 0 for generators. Only the markers inside the used source range are kept; the rest
    /// are master-clip markers Premiere shows only when the clip is trimmed out to them.
    /// Snapping happens where the marker shows: the clip-local time ((t - source.start) / speed, from the end for a
    /// reversed clip) goes onto the sequence frame and is mapped back to source time, and so does the length. Snapping the
    /// source time itself with the sequence frame would put markers of a retimed clip between the frames it plays.
    pub(crate) fn clip_markers(&mut self, item: &PRItem, c: &mut Clip, seq: &PRSequence) {
        if item.markers.is_empty() {
            return;
        }
        let shift = c.source.start - PRTicks::time(item.in_point);
        let fd = seq.frame_duration;
        let mut kept = Vec::new();
        let mut outside = 0;
        for m in &item.markers {
            let t = PRTicks::time(m.ticks) + shift;
            if !(t >= c.source.start && t < c.source.end()) {
                outside += 1;
                continue;
            }
            let local =
                std::cmp::min(c.local_time_for_instant(t).snapped(fd), std::cmp::max(Time::ZERO, c.duration() - fd));
            let length = c.speed.scale(c.speed.unscale(PRTicks::time(m.duration_ticks)).snapped(fd));
            let at = std::cmp::min(std::cmp::max(c.source_instant(local), c.source.start), c.source.end());
            kept.push(self.marker(m, at, length));
        }
        if !kept.is_empty() {
            c.markers = Some(kept);
            self.report.note(
                "Clip markers",
                Status::Mapped,
                "in source time, on the sequence frame the clip shows them at",
            );
        }
        if outside > 0 {
            self.report.note(
                "Clip markers outside the used range",
                Status::Dropped,
                "master-clip markers Premiere shows only after trimming out to them",
            );
        }
    }

    /// A Premiere adjustment layer (also a graphic flagged as one) becomes an SQ Adjustment Layer clip with its Motion,
    /// Opacity and effects. Text and Shape layers of such a graphic are not drawn (as in Premiere); see the area note below.
    fn adjustment_clip(
        &mut self,
        item: &PRItem,
        kind: TrackKind,
        seq: &PRSequence,
        start: Time,
        duration: Time,
    ) -> Option<Clip> {
        if kind != TrackKind::Video {
            return None;
        }
        let id = self.ids.next_id();
        let name = if item.name.is_empty() { "Adjustment Layer" } else { &item.name };
        let mut c = Clip::new(id, name, id, TrackKind::Video, TimeRange::new(Time::ZERO, duration), start);
        c.generator = Some(adjustment_layer());
        let ctx = ClipContext { in_point: item.in_point, speed: ClipSpeed::NORMAL, sequence: seq };
        let frame = Vec2::new(seq.width as f64, seq.height as f64);
        c.animation = self.motion(item, &ctx, frame, Vec2::ZERO, 1.0);
        c.effects = self.effects(item, &ctx, frame, Vec2::ZERO);
        self.take_masks(&mut c);
        c.blend_mode = self.blend_mode(item);
        // Text and Shape layers of an adjustment graphic are not drawn by Premiere either; they only limit where the effects
        // reach. Checked 2026-10-06: all 140 such clips in the maintainer's projects are Mister Horse carriers (texts "Mister
        // Horse Adjustment" and a help note, one Shape covering the frame), so the whole frame is affected, as in SQ: silent.
        // Any other text / shape content means Premiere's effect area is smaller than SQ's: reported.
        let shapes = item.components_named("AE.ADBE Shape");
        if !(shapes.is_empty() && item.components_named("AE.ADBE Text").is_empty())
            && !shapes.iter().any(|s| shapes::shape_covers_frame(s, frame))
        {
            self.report.note(
                "Adjustment layer area",
                Status::Approximated,
                "effect area not limited to the shape/text: SQ applies the effects to the whole frame",
            );
        }
        self.clip_markers(item, &mut c, seq);
        self.report.note("Adjustment layer", Status::Mapped, "");
        Some(c)
    }

    // MARK: Motion / Opacity

    /// `pixel_aspect`: the source's pixel width / height (Premiere shows non-square pixels stretched; SQ has no PAR, so it
    /// becomes part of the horizontal scale).
    pub(crate) fn motion(
        &mut self,
        item: &PRItem,
        ctx: &ClipContext,
        frame: Vec2,
        text_offset: Vec2,
        pixel_aspect: f64,
    ) -> ClipAnimation {
        let mut a = ClipAnimation::default();
        let par = pixel_aspect;
        if par != 1.0 {
            a.scale = AnimatedProperty::new(Vec2::new(par, 1.0));
        }
        let canvas = Vec2::new(ctx.sequence.width as f64, ctx.sequence.height as f64);
        let motion = item.components_named("AE.ADBE Motion");
        if let Some(m) = motion.first() {
            a.position = ctx.animated(self.ids, m.param(1), Vec2::ZERO, PRParamValue::point, |p| {
                Vec2::new((p.x - 0.5) * canvas.x, (p.y - 0.5) * canvas.y)
            });
            let uniform = PRParamValue::bool(m.param(4).and_then(|p| p.static_value.as_deref())).unwrap_or(true);
            if uniform {
                a.scale = ctx.animated(self.ids, m.param(2), Vec2::new(par, 1.0), PRParamValue::double, |s| {
                    Vec2::new(par * s / 100.0, s / 100.0)
                });
            } else {
                let w = PRParamValue::double(m.param(3).and_then(|p| p.static_value.as_deref())).unwrap_or(100.0);
                a.scale = ctx.animated(self.ids, m.param(2), Vec2::new(par, 1.0), PRParamValue::double, |s| {
                    Vec2::new(par * w / 100.0, s / 100.0)
                });
                if m.param(3).is_some_and(PRParamValue::is_animated) {
                    self.report.note("Motion non-uniform scale keys", Status::Approximated, "width keys dropped");
                }
            }
            a.rotation = ctx.animated(self.ids, m.param(5), 0.0, PRParamValue::double, |r| r);
            a.anchor = ctx.animated(self.ids, m.param(6), Vec2::ZERO, PRParamValue::point, |p| {
                Vec2::new((p.x - 0.5) * frame.x - text_offset.x, (p.y - 0.5) * frame.y - text_offset.y)
            });
            self.report.note("AE.ADBE Motion", Status::Mapped, "");
        }
        if text_offset != Vec2::ZERO && !a.anchor.is_animated() && motion.is_empty() {
            a.anchor = AnimatedProperty::new(Vec2::new(-text_offset.x, -text_offset.y));
        }
        // Basic 3D: Swivel turns about the vertical axis (SQ Tilt Y), Tilt about the horizontal one (Tilt X); the same
        // card-in-front-of-camera idea. Signs follow the AE convention (top / right edge away for positive values),
        // not yet checked against a Premiere render. Distance to Image and Specular Highlight have no SQ control.
        if let Some(b) = item.components_named("AE.ADBE Basic 3D").first() {
            a.tilt_y = ctx.animated(self.ids, b.param(1), 0.0, PRParamValue::double, |d| d.clamp(-89.0, 89.0));
            a.tilt_x = ctx.animated(self.ids, b.param(2), 0.0, PRParamValue::double, |d| d.clamp(-89.0, 89.0));
            let lost = b.param(3).is_some_and(|p| {
                p.is_animated() || PRParamValue::double(p.static_value.as_deref()).unwrap_or(0.0) != 0.0
            }) || PRParamValue::bool(b.param(4).and_then(|p| p.static_value.as_deref())) == Some(true);
            if lost {
                self.report.note(
                    "AE.ADBE Basic 3D",
                    Status::Approximated,
                    "Swivel and Tilt as Tilt Y / X; Distance to Image and Specular Highlight dropped",
                );
            } else {
                self.report.note("AE.ADBE Basic 3D", Status::Mapped, "Swivel / Tilt as Tilt Y / X");
            }
        }
        if let Some(o) = item.components_named("AE.ADBE Opacity").first() {
            a.opacity = ctx.animated(self.ids, o.param(1), 1.0, PRParamValue::double, |v| v / 100.0);
            self.report.note("AE.ADBE Opacity", Status::Mapped, "");
        }
        a
    }

    /// Opacity > Blend Mode: param 2 is Premiere's internal code (18 Normal, 22 Add, 11 Color Dodge, 17 Color Burn, 12 Soft
    /// Light), param 3 the position in the blend menu (Normal 0, Dissolve 1, Darken 2 ... Add 10, Lighter Color 11, Overlay 12
    /// ... Exclusion 20 ... Luminosity 26). Pairs measured on 662 clips of the maintainer's projects; the menu index covers
    /// the modes no sample used. Static only.
    pub(crate) fn blend_mode(&mut self, item: &PRItem) -> BlendMode {
        let opacity = item.components_named("AE.ADBE Opacity");
        let Some(o) = opacity.first() else { return BlendMode::Normal };
        // The menu index is the position in the standard 27-mode list, which is SQ's `BlendMode::ALL` order too.
        let by_code = |code: i64| match code {
            18 => Some(BlendMode::Normal),
            22 => Some(BlendMode::Add),
            11 => Some(BlendMode::ColorDodge),
            17 => Some(BlendMode::ColorBurn),
            12 => Some(BlendMode::SoftLight),
            _ => None,
        };
        let code = PRParamValue::double(o.param(2).and_then(|p| p.static_value.as_deref()))
            .and_then(|d| crate::prcontainer::safe_int(Some(d)));
        let index = PRParamValue::double(o.param(3).and_then(|p| p.static_value.as_deref()))
            .and_then(|d| crate::prcontainer::safe_int(Some(d)));
        if code.is_none() && index.is_none() {
            return BlendMode::Normal;
        }
        let mode = index
            .and_then(|i| usize::try_from(i).ok().and_then(|i| BlendMode::ALL.get(i).copied()))
            .or_else(|| if index.is_none() { code.and_then(by_code) } else { None });
        if o.param(2).is_some_and(PRParamValue::is_animated) {
            self.report.note("Opacity blend mode", Status::Approximated, "keys dropped");
        }
        if let Some(mode) = mode {
            if mode != BlendMode::Normal {
                self.report.note("Opacity blend mode", Status::Mapped, mode.title());
            }
            return mode;
        }
        self.report.note("Opacity blend mode", Status::Dropped, "unknown blend menu index: drawn as Normal");
        BlendMode::Normal
    }

    /// Moves the masks `effects` collected onto the clip.
    pub(crate) fn take_masks(&mut self, c: &mut Clip) {
        use sq_core_masks::ClipMasksExt;
        c.set_masks(std::mem::take(&mut self.pending_masks));
    }

    /// A fresh effect of a catalog `kind` (Swift force-unwraps `ClipEffect.make`).
    pub(crate) fn make_effect(&mut self, kind: &str) -> sq_core_model::ClipEffect {
        let id = self.ids.next_id();
        sq_core_model::ClipEffect::make(id, kind).unwrap_or_else(|| sq_core_model::ClipEffect::new(id, kind))
    }

    /// `animated` with this run's id source.
    pub(crate) fn anim<R: RawValue, V: KeyframeValue>(
        &mut self,
        ctx: &ClipContext,
        p: Option<&crate::prdocument::PRParamValue>,
        fallback: V,
        parse: fn(Option<&str>) -> Option<R>,
        convert: impl Fn(R) -> V,
    ) -> AnimatedProperty<V> {
        ctx.animated(self.ids, p, fallback, parse, convert)
    }
}

/// Converts one item's Premiere params into clip-local animated properties.
pub(crate) struct ClipContext<'a> {
    pub(crate) in_point: i64,
    pub(crate) speed: ClipSpeed,
    pub(crate) sequence: &'a PRSequence,
}

/// A parsed Premiere value: how far apart two of them are, for the bezier handle scale.
pub(crate) trait RawValue: Copy {
    fn distance(a: Self, b: Self) -> f64;
}

impl RawValue for f64 {
    fn distance(a: f64, b: f64) -> f64 {
        b - a
    }
}

impl RawValue for Vec2 {
    fn distance(a: Vec2, b: Vec2) -> f64 {
        (b - a).length()
    }
}

impl RawValue for EffectColor {
    fn distance(_: EffectColor, _: EffectColor) -> f64 {
        1.0
    }
}

impl ClipContext<'_> {
    /// Key time (absolute source ticks) -> clip-local timeline time.
    fn local(&self, ticks: i64) -> Time {
        self.speed.unscale(PRTicks::time(PRTicks::sub(ticks, self.in_point)))
    }

    /// The param as an animated property: static value (or `fallback`) plus its keys, converted by `convert`.
    pub(crate) fn animated<R: RawValue, V: KeyframeValue>(
        &self,
        ids: &mut dyn IdSource,
        p: Option<&crate::prdocument::PRParamValue>,
        fallback: V,
        parse: fn(Option<&str>) -> Option<R>,
        convert: impl Fn(R) -> V,
    ) -> AnimatedProperty<V> {
        let Some(p) = p else { return AnimatedProperty::new(fallback) };
        let value = parse(p.static_value.as_deref()).map_or(fallback, &convert);
        // Raw (Premiere unit) values: slopes are in those units per second.
        let parsed: Vec<(&crate::prdocument::PRKey, R, V)> =
            p.keys.iter().filter_map(|k| parse(Some(&k.value)).map(|raw| (k, raw, convert(raw)))).collect();
        let mut keys: Vec<Keyframe<V>> = Vec::new();
        for (i, (k, raw, v)) in parsed.iter().enumerate() {
            let mut key = Keyframe::new(ids.next_id(), self.local(k.ticks), v.clone());
            match k.interpolation {
                4 => key.interpolation = Interpolation::Hold,
                5..=8 => {
                    key.interpolation = Interpolation::Bezier;
                    if let Some((nk, nraw, _)) = parsed.get(i + 1) {
                        key.out_handle = Self::handle(k.out_slope, k.out_influence, k, *raw, nk, *nraw);
                    }
                }
                _ => {}
            }
            // The in-handle shapes the segment that ends here: it counts whenever that segment is a curve (this key or the
            // one before is bezier), also on a linear key after a bezier one.
            if i > 0 && ((5..=8).contains(&k.interpolation) || (5..=8).contains(&parsed[i - 1].0.interpolation)) {
                let (pk, praw, _) = &parsed[i - 1];
                key.in_handle = Self::handle(k.in_slope, k.in_influence, pk, *praw, k, *raw);
            }
            keys.push(key);
        }
        let first = keys.first().map_or(value, |k| k.value.clone());
        AnimatedProperty { value: first, track: KeyframeTrack::with_keys(keys) }
    }

    /// Premiere's speed (value units per second) + influence (share of the segment) as a normalized bezier handle.
    fn handle<R: RawValue>(
        slope: f64,
        influence: f64,
        a: &crate::prdocument::PRKey,
        va: R,
        b: &crate::prdocument::PRKey,
        vb: R,
    ) -> EaseHandle {
        let dx = influence.clamp(0.0, 1.0);
        let seconds = (b.ticks as f64 - a.ticks as f64) / PRTicks::PER_SECOND as f64;
        let delta = R::distance(va, vb);
        if delta.abs() <= 1e-12 {
            return EaseHandle { dx, dy: 0.0 };
        }
        EaseHandle { dx, dy: slope * dx * seconds / delta }
    }
}
