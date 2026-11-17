//! Angles clip: several recordings of one event cut like one clip. The model and the edits are core; this is what the
//! commands, the dialog and the menus call.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use sq_core_edit::angles_edits::AnglesEditsExt as _;
use sq_core_edit::angles_make::{AngleInput, AnglesOffsets, AnglesProjectExt as _};
use sq_core_edit::angles_proxy::AnglesClipExt as _;
use sq_core_edit::grouping::ProjectGroupingExt as _;
use sq_core_edit::timeline_source_edit::TimelineSourceEditExt as _;
use sq_core_model::{
    AnglesSetup, AnimatedProperty, BinItemRef, Clip, EditError, Project, SequenceFormat, SourceMarks, Timeline, Track,
    TrackKind,
};
use sq_core_time::{Id, IdSource, Time, TimeRange, Vec2};

use crate::EditorSession;

/// One angle Create Angles Clip would build: its name and the media whose file the sync reads (`None`: no file).
// Swift: EditorSession+Angles.swift:7
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AngleCandidate {
    // Swift: EditorSession+Angles.swift:9
    pub name: String,
    // Swift: EditorSession+Angles.swift:10
    pub media: Option<Id>,
    // Swift: EditorSession+Angles.swift:11
    pub has_audio: bool,
}

impl AngleCandidate {
    // Swift: EditorSession+Angles.swift:12
    pub fn new(name: &str, media: Option<Id>, has_audio: bool) -> AngleCandidate {
        AngleCandidate { name: name.to_string(), media, has_audio }
    }
}

/// How the angles of a new Angles clip are lined up in time, and the choices the sheet offers.
// Swift: EditorSession+Angles.swift:17
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AngleSyncMode {
    InPoints,
    Timecode,
    Audio,
    TimelinePositions,
}

impl AngleSyncMode {
    /// Every case, in Swift's declaration order.
    pub const ALL: [AngleSyncMode; 4] =
        [AngleSyncMode::InPoints, AngleSyncMode::Timecode, AngleSyncMode::Audio, AngleSyncMode::TimelinePositions];

    // Swift: EditorSession+Angles.swift:20
    pub fn title(self) -> &'static str {
        match self {
            AngleSyncMode::InPoints => "In Points",
            AngleSyncMode::Timecode => "Timecode",
            AngleSyncMode::Audio => "Audio",
            AngleSyncMode::TimelinePositions => "Timeline Positions",
        }
    }

    /// The sync choices on offer: Timeline Positions only for clips of a timeline (and then first: it is what the
    /// editor already lined up); Audio only when at least two angles have sound.
    // Swift: EditorSession+Angles.swift:32
    pub fn choices(angles: &[AngleCandidate], from_timeline: bool) -> Vec<AngleSyncMode> {
        let mut out = if from_timeline {
            vec![AngleSyncMode::TimelinePositions, AngleSyncMode::InPoints, AngleSyncMode::Timecode]
        } else {
            vec![AngleSyncMode::InPoints, AngleSyncMode::Timecode]
        };
        if angles.iter().filter(|a| a.has_audio).count() >= 2 {
            out.push(AngleSyncMode::Audio);
        }
        out
    }

    /// The angle whose sound plays by default: the first with sound.
    // Swift: EditorSession+Angles.swift:39
    pub fn default_audio_angle(angles: &[AngleCandidate]) -> usize {
        angles.iter().position(|a| a.has_audio).unwrap_or(0)
    }

    /// First free "Angles NN" among `existing` names.
    // Swift: EditorSession+Angles.swift:42
    pub fn default_name(existing: &[String]) -> String {
        let mut n = 1;
        while existing.iter().any(|e| *e == format!("Angles {n:02}")) {
            n += 1;
        }
        format!("Angles {n:02}")
    }
}

/// What a number key did.
// Swift: EditorSession+Angles.swift:52
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AngleSwitchResult {
    Switched,
    /// The piece already shows that angle.
    Unchanged,
    NoAnglesClip,
    /// The Angles clip has only `count` angles.
    NoSuchAngle {
        count: usize,
    },
    /// Refused (locked track...): `last_error` says why.
    Refused,
}

/// Replaces the Angles piece `clip` and its linked pieces of the same Angles sequence by the content of the angle each
/// shows (a video piece its picture track, a sound piece its audio track). Returns the placed clip ids. Errors:
/// `NotNested` when `clip` is no Angles piece, plus the refusals of Unnest.
// Swift: Angles+Flatten.swift:12 (SQCore `Project.flattenAngles`)
// shortcut: lives here because sq-core-edit is not this crate's to change; move it next to `unnest` in grouping.rs.
fn flatten_angles_in(
    project: &mut Project,
    clip: Id,
    in_timeline: Id,
    ids: &mut dyn IdSource,
) -> Result<Vec<Id>, EditError> {
    let tl = project.timeline(in_timeline).ok_or(EditError::TimelineNotFound)?;
    let hit = tl.find(clip).ok_or(EditError::ClipNotFound)?;
    let (Some(seq), true) = (hit.clip.sequence, hit.clip.is_angles_clip()) else { return Err(EditError::NotNested) };
    let inner = project.timeline(seq).ok_or(EditError::NotNested)?;
    let pieces: Vec<Clip> = tl
        .linked_group(clip)?
        .into_iter()
        .map(|m| m.clip)
        .filter(|c| c.is_angles_clip() && c.sequence == Some(seq))
        .collect();
    // One stand-in sequence with the shown picture track and the shown sound track: Unnest then restores both halves
    // together and keeps their links.
    let mut view = inner.clone();
    view.id = ids.next_id();
    view.angles = None;
    let mut shown: HashMap<TrackKind, i64> = HashMap::new();
    for p in &pieces {
        shown.entry(p.kind).or_insert_with(|| p.angle.as_ref().map_or(0, |a| a.index));
    }
    let mut seen: HashMap<TrackKind, i64> = HashMap::new();
    let kept: Vec<Track> = inner
        .tracks
        .iter()
        .filter(|t| {
            let Some(want) = shown.get(&t.kind) else {
                return t.kind != TrackKind::Video && t.kind != TrackKind::Audio;
            };
            let n = *seen.get(&t.kind).unwrap_or(&0);
            seen.insert(t.kind, n + 1);
            let of_kind = inner.tracks.iter().filter(|x| x.kind == t.kind).count() as i64;
            n == (*want).min((of_kind - 1).max(0))
        })
        .cloned()
        .collect();
    view.tracks = kept.into();
    let mut work = project.clone();
    let view_id = view.id;
    work.timelines.push(view);
    let wanted: BTreeSet<Id> = pieces.iter().map(|c| c.id).collect();
    work.edit(in_timeline, |t| {
        for i in 0..t.tracks.len() {
            let hits: Vec<Clip> = t.tracks[i].clips().iter().filter(|c| wanted.contains(&c.id)).cloned().collect();
            for mut c in hits {
                c.sequence = Some(view_id);
                c.media = view_id;
                c.angle = None;
                t.tracks[i].replace(c);
            }
        }
        Ok(())
    })?;
    let placed = work.unnest(clip, in_timeline, ids)?;
    work.timelines.retain(|t| t.id != view_id);
    *project = work;
    Ok(placed)
}

/// What the Angle rows of the timeline menu show for one piece.
// Swift: EditorSession+Angles.swift:63
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AngleMenuState {
    // Swift: EditorSession+Angles.swift:64
    pub clip: Id,
    // Swift: EditorSession+Angles.swift:65
    pub names: Vec<String>,
    // Swift: EditorSession+Angles.swift:66
    pub active: usize,
    /// The clicked piece is the sound half: its rows choose the sound's angle.
    // Swift: EditorSession+Angles.swift:68
    pub is_audio: bool,
    /// Audio Follows Video of the piece's sound (`None`: the piece has no sound).
    // Swift: EditorSession+Angles.swift:70
    pub follows_video: Option<bool>,
}

// Wired to `sq_core_edit::angles_edits` and `angles_make`; Flatten Angles Clip is `flatten_angles_in` below.
impl EditorSession {
    /// A fresh id for a clip or link made here.
    fn new_id(&mut self) -> Id {
        self.ids.next_id()
    }

    /// The selected timeline clips in a stable order (track, then start): what Create Angles Clip works on. The app
    /// takes this list once when the sheet opens, so a selection change during the sync does not change which clips
    /// become the Angles clip.
    // Swift: EditorSession+Angles.swift:78
    pub fn angle_selection(&self) -> Vec<Id> {
        self.active_timeline().map_or_else(Vec::new, |t| {
            t.tracks.iter().flat_map(|tr| tr.clips()).filter(|c| self.selection.contains(&c.id)).map(|c| c.id).collect()
        })
    }

    /// The angles the selected timeline clips would become, in angle order (empty: fewer than two).
    // Swift: EditorSession+Angles.swift:81
    pub fn angle_candidates_of_selection(&self) -> Vec<AngleCandidate> {
        self.angle_candidates_clips(&self.angle_selection())
    }

    /// The angles the timeline clips `ids` would become, in angle order (empty: fewer than two).
    // Swift: EditorSession+Angles.swift:84
    pub fn angle_candidates_clips(&self, ids: &[Id]) -> Vec<AngleCandidate> {
        let Some(groups) = self.active_timeline().and_then(|t| t.angle_candidates(ids).ok()).filter(|g| g.len() >= 2)
        else {
            return Vec::new();
        };
        groups
            .iter()
            .map(|g| {
                let lead = g.iter().find(|c| c.kind == TrackKind::Video).unwrap_or(&g[0]);
                AngleCandidate::new(&lead.name, Some(lead.media), g.iter().any(|c| c.kind == TrackKind::Audio))
            })
            .collect()
    }

    /// The angles the media items would become (items without a known length are left out).
    // Swift: EditorSession+Angles.swift:93
    pub fn angle_candidates_media(&self, ids: &[Id]) -> Vec<AngleCandidate> {
        ids.iter()
            .filter_map(|id| {
                let r = self.project().media(*id)?;
                let known = r.info.as_ref().map(|i| i.duration).or(r.duration).is_some();
                if r.info.as_ref().is_some_and(|i| i.is_still) || !known {
                    return None;
                }
                Some(AngleCandidate::new(&r.name, Some(*id), r.info.as_ref().is_some_and(|i| i.audio.is_some())))
            })
            .collect()
    }

    /// Create Angles Clip from media items of the Project panel: one angle per item (its In/Out range, else the whole
    /// file), filed next to the first item. `origins`: where each file's time 0 lies on the common clock; empty = sync
    /// by In point. Returns the new sequence.
    // Swift: EditorSession+Angles.swift:108
    pub fn create_angles_sequence(
        &mut self,
        media: &[Id],
        name: Option<&str>,
        origins: &BTreeMap<Id, Time>,
        audio_angle: usize,
        audio_follows_video: bool,
    ) -> Option<Id> {
        let refs: Vec<_> = media
            .iter()
            .filter_map(|id| self.project().media(*id))
            .filter(|r| !r.info.as_ref().is_some_and(|i| i.is_still))
            .cloned()
            .collect();
        let marks = self.project().source_marks.clone();
        let lead = refs.iter().find_map(|r| r.info.as_ref().and_then(|i| i.video.clone()));
        let base = self.active_timeline().map_or_else(
            || SequenceFormat {
                width: 1920,
                height: 1080,
                frame_duration: Time::new(1, 30),
                audio_sample_rate: 48_000,
                pixel_aspect_store: None,
                unknown: sq_core_model::UnknownKeys::default(),
            },
            |t| t.format.clone(),
        );
        let format = lead.map_or_else(
            || base.clone(),
            |v| {
                SequenceFormat {
                    width: v.display_width(),
                    height: v.display_height(),
                    frame_duration: v.nominal_frame_duration,
                    audio_sample_rate: base.audio_sample_rate,
                    pixel_aspect_store: None,
                    unknown: sq_core_model::UnknownKeys::default(),
                }
                .sanitized(&base)
            },
        );
        let mut inputs: Vec<AngleInput> = Vec::new();
        let mut placing: Vec<(Option<Time>, Time)> = Vec::new();
        for r in &refs {
            let Some(total) = r.info.as_ref().map(|i| i.duration).or(r.duration) else { continue };
            let Some(range) =
                Timeline::source_edit_range(&marks.get(&r.id).cloned().unwrap_or_else(SourceMarks::default), total)
            else {
                continue;
            };
            let source = TimeRange::new(range.start, range.duration.snapped(format.frame_duration));
            if source.is_empty() {
                continue;
            }
            let video = r.info.as_ref().is_some_and(|i| i.video.is_some()) || r.info.is_none();
            let audio = r.info.as_ref().is_some_and(|i| i.audio.is_some());
            let link = (video && audio).then(|| self.new_id());
            let mut clips: Vec<Clip> = Vec::new();
            if video {
                let mut c = Clip::new(self.new_id(), &r.name, r.id, TrackKind::Video, source, Time::ZERO);
                c.link = link;
                c.media_duration = Some(total);
                let fit = r
                    .info
                    .as_ref()
                    .and_then(|i| i.video.as_ref())
                    .map_or(1.0, |v| format.fit_scale(v.display_width(), v.display_height()));
                if (fit - 1.0).abs() > 1e-12 {
                    c.animation.scale = AnimatedProperty::new(Vec2::new(fit, fit));
                }
                clips.push(c);
            }
            if audio {
                let mut c = Clip::new(self.new_id(), &r.name, r.id, TrackKind::Audio, source, Time::ZERO);
                c.link = link;
                c.media_duration = Some(total);
                clips.push(c);
            }
            if clips.is_empty() {
                continue;
            }
            inputs.push(AngleInput::new(&r.name, clips));
            placing.push((origins.get(&r.id).copied(), source.start));
        }
        for (i, start) in AnglesOffsets::starts(&placing).into_iter().enumerate() {
            inputs[i].offset = start;
        }
        if inputs.len() < 2 {
            self.set_error("An Angles clip needs at least two clips.");
            return None;
        }
        let bin = refs.first().and_then(|r| self.project().root_bin.parent_of(BinItemRef::Media(r.id)));
        // shortcut: `trim` is not Foundation's whitespace set (U+200B, U+FEFF); names with those are an edge case.
        let trimmed = name.map_or("", str::trim);
        let name = (!trimmed.is_empty()).then_some(trimmed);
        let setup = AnglesSetup { audio_angle: i64::try_from(audio_angle).unwrap_or(i64::MAX), audio_follows_video };
        let mut made: Option<Id> = None;
        let result = self.with_ids(|s, ids| {
            s.try_perform("Create Angles Clip", None, |p| {
                made = Some(p.make_angles_sequence(name, &format, &inputs, &setup, bin, ids)?);
                Ok(())
            })
        });
        if let Err(e) = result {
            self.set_error(Self::message_for(&e));
            return None;
        }
        made
    }

    /// Create Angles Clip from the selected timeline clips: the Angles clip takes their place. `origins` as in
    /// `create_angles_sequence`; `None` = the clips keep the positions they have in the timeline.
    // Swift: EditorSession+Angles.swift:159
    pub fn create_angles_clip_from_selection(
        &mut self,
        name: Option<&str>,
        origins: Option<&BTreeMap<Id, Time>>,
        audio_angle: usize,
        audio_follows_video: bool,
    ) -> Option<Id> {
        let ids = self.angle_selection();
        self.create_angles_clip(&ids, name, origins, audio_angle, audio_follows_video)
    }

    /// Create Angles Clip from the timeline clips `ids` of the active sequence.
    // Swift: EditorSession+Angles.swift:166
    pub fn create_angles_clip(
        &mut self,
        ids: &[Id],
        name: Option<&str>,
        origins: Option<&BTreeMap<Id, Time>>,
        audio_angle: usize,
        audio_follows_video: bool,
    ) -> Option<Id> {
        let (id, t) = (self.active_timeline_id?, self.active_timeline()?);
        let groups = match t.angle_candidates(ids) {
            Ok(g) if g.len() >= 2 => g,
            _ => {
                self.set_error("An Angles clip needs at least two clips.");
                return None;
            }
        };
        let offsets: Option<BTreeMap<Id, Time>> = origins.map(|origins| {
            let firsts: Vec<Option<&Clip>> = groups.iter().map(|g| g.iter().min_by_key(|c| c.start)).collect();
            let placing: Vec<(Option<Time>, Time)> = firsts
                .iter()
                .map(|f| (f.and_then(|c| origins.get(&c.media).copied()), f.map_or(Time::ZERO, |c| c.source.start)))
                .collect();
            let mut o = BTreeMap::new();
            for (g, at) in groups.iter().zip(AnglesOffsets::starts(&placing)) {
                for c in g {
                    o.insert(c.id, at);
                }
            }
            o
        });
        // shortcut: `trim` is not Foundation's whitespace set (U+200B, U+FEFF); names with those are an edge case.
        let trimmed = name.map_or("", str::trim);
        let name = (!trimmed.is_empty()).then_some(trimmed);
        let setup = AnglesSetup { audio_angle: i64::try_from(audio_angle).unwrap_or(i64::MAX), audio_follows_video };
        let mut made: Option<Id> = None;
        let result = self.with_ids(|s, src| {
            s.try_perform("Create Angles Clip", None, |p| {
                made = Some(p.make_angles_clip(ids, id, name, offsets.as_ref(), &setup, src)?);
                Ok(())
            })
        });
        if let Err(e) = result {
            self.set_error(Self::message_for(&e));
            return None;
        }
        if let Some(made) = made
            && let Some(now) = self.active_timeline()
        {
            let sel: BTreeSet<Id> = now
                .tracks
                .iter()
                .flat_map(|tr| tr.clips())
                .filter(|c| c.sequence == Some(made))
                .map(|c| c.id)
                .collect();
            self.select(sel, BTreeSet::new());
        }
        made
    }

    /// Number key `n` (1...9). Playing: the Angles piece under the playhead is cut there and shows angle `n` from there
    /// on (one undo step per switch). Stopped: the selected Angles pieces take angle `n` (picture pieces first: their
    /// sound follows or stays as set; only sound pieces selected: their sound switches), else the piece under the playhead.
    // Swift: EditorSession+Angles.swift:200
    pub fn switch_angle(&mut self, n: i64) -> AngleSwitchResult {
        let Some(t) = self.active_timeline().cloned() else { return AngleSwitchResult::NoAnglesClip };
        if n < 1 {
            return AngleSwitchResult::NoAnglesClip;
        }
        let index = n - 1;
        // A picture piece has as many angles as the Angles sequence has video tracks, a sound piece as it has audio tracks.
        let count = |c: &Clip| {
            c.sequence
                .and_then(|s| self.project().timeline(s))
                .map_or(0, |s| s.tracks.iter().filter(|tr| tr.kind == c.kind).count())
        };
        let silent = |c: &Clip| {
            c.sequence.and_then(|s| self.project().timeline(s)).map(|s| s.silent_angles()).unwrap_or_default()
        };
        if self.is_playing() {
            let at = self.playhead.snapped(t.frame_duration());
            let Some(piece) = t.angles_clip_at(at) else { return AngleSwitchResult::NoAnglesClip };
            if index as usize >= count(&piece) {
                return AngleSwitchResult::NoSuchAngle { count: count(&piece) };
            }
            let mute = silent(&piece);
            return self.commit_angle(&t, move |tl, ids| tl.switch_angle(index, at, piece.id, &mute, ids).map(|_| ()));
        }
        let chosen: Vec<Clip> = t
            .tracks
            .iter()
            .flat_map(|tr| tr.clips())
            .filter(|c| self.selection.contains(&c.id) && c.is_angles_clip())
            .cloned()
            .collect();
        let mut pieces: Vec<Clip> = chosen.iter().filter(|c| c.kind == TrackKind::Video).cloned().collect();
        if pieces.is_empty() {
            pieces = chosen;
        }
        if pieces.is_empty()
            && let Some(under) = t.angles_clip_at(self.playhead)
        {
            pieces = vec![under];
        }
        if pieces.is_empty() {
            return AngleSwitchResult::NoAnglesClip;
        }
        let fits: Vec<&Clip> = pieces.iter().filter(|c| (index as usize) < count(c)).collect();
        if fits.is_empty() {
            return AngleSwitchResult::NoSuchAngle { count: pieces.iter().map(&count).max().unwrap_or(0) };
        }
        let mutes: Vec<(Id, BTreeSet<i64>)> = fits.iter().map(|c| (c.id, silent(c))).collect();
        self.commit_angle(&t, move |tl, _| {
            for (id, mute) in &mutes {
                tl.set_angle(index, *id, mute)?;
            }
            Ok(())
        })
    }

    /// Tries the switch on a copy first: a key that changes nothing cuts nothing and adds no undo step.
    fn commit_angle(
        &mut self,
        t: &Timeline,
        body: impl Fn(&mut Timeline, &mut dyn IdSource) -> Result<(), EditError>,
    ) -> AngleSwitchResult {
        self.clear_error();
        let mut trial = t.clone();
        if let Err(e) = body(&mut trial, &mut sq_core_time::SequentialIds::default()) {
            self.set_error(Self::message_for(&e));
            return AngleSwitchResult::Refused;
        }
        if trial == *t {
            return AngleSwitchResult::Unchanged;
        }
        if self.attempt_ids("Switch Angle", |tl, ids| body(tl, ids)) {
            return AngleSwitchResult::Switched;
        }
        if self.last_error().is_none() { AngleSwitchResult::Unchanged } else { AngleSwitchResult::Refused }
    }

    /// Angle `index` (0-based) for the piece `id`: the timeline menu's Angle rows.
    // Swift: EditorSession+Angles.swift:236
    pub fn set_angle(&mut self, index: usize, id: Id) -> bool {
        let seq =
            self.active_timeline().and_then(|t| t.tracks.iter().find_map(|tr| tr.clip(id))).and_then(|c| c.sequence);
        let mute = seq.and_then(|s| self.project().timeline(s)).map(|s| s.silent_angles()).unwrap_or_default();
        self.attempt("Switch Angle", None, |tl| tl.set_angle(index as i64, id, &mute).map(|_| ()))
    }

    /// Audio Follows Video for the piece `id` and its linked pieces.
    // Swift: EditorSession+Angles.swift:246
    pub fn set_audio_follows_video(&mut self, on: bool, id: Id) -> bool {
        self.attempt("Audio Follows Video", None, |tl| tl.set_audio_follows_video(on, id).map(|_| ()))
    }

    /// Flatten Angles Clip: the piece `id` and its linked pieces become the plain clips of the angles they show.
    // Swift: EditorSession+Angles.swift:252
    pub fn flatten_angles(&mut self, id: Id) -> bool {
        let Some(tid) = self.active_timeline_id else { return false };
        self.clear_error();
        match self.perform_ids("Flatten Angles Clip", None, |p, ids| flatten_angles_in(p, id, tid, ids).map(|_| ())) {
            Ok(()) => true,
            Err(e) => {
                self.set_error(Self::message_for(&e));
                false
            }
        }
    }

    /// The Angle rows for the piece `id` (`None`: not an Angles clip).
    // Swift: EditorSession+Angles.swift:263
    pub fn angle_menu_state(&self, id: Id) -> Option<AngleMenuState> {
        let t = self.active_timeline()?;
        let c = t.tracks.iter().find_map(|tr| tr.clip(id))?;
        let angle = c.angle.as_ref().filter(|_| c.is_angles_clip())?;
        let inner = c.sequence.and_then(|s| self.project().timeline(s))?;
        let names = inner.angle_names();
        // The linked sound part; on a locked sound track the live switch left the sound whole, linked to an earlier part:
        // then the sound of the same Angles sequence that plays where this part starts.
        let sounds: Vec<&Clip> = t
            .tracks
            .iter()
            .flat_map(|tr| tr.clips())
            .filter(|x| x.kind == TrackKind::Audio && x.is_angles_clip())
            .collect();
        let sound: Option<&Clip> = if c.kind == TrackKind::Audio {
            Some(c)
        } else {
            sounds
                .iter()
                .find(|x| x.link.is_some() && x.link == c.link)
                .or_else(|| {
                    sounds
                        .iter()
                        .find(|x| x.sequence == c.sequence && x.start <= c.start && c.start < x.timeline().end())
                })
                .copied()
        };
        let last = names.len().saturating_sub(1) as i64;
        Some(AngleMenuState {
            clip: id,
            names,
            active: angle.index.clamp(0, last) as usize,
            is_audio: c.kind == TrackKind::Audio,
            follows_video: sound.and_then(|x| x.angle.as_ref().map(|a| a.follows_video)),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn angle(has_audio: bool) -> AngleCandidate {
        AngleCandidate::new("a", None, has_audio)
    }

    #[test]
    fn choices_offer_timeline_first_and_audio_only_with_two_sounds() {
        let two = [angle(true), angle(true)];
        assert_eq!(
            AngleSyncMode::choices(&two, true),
            [AngleSyncMode::TimelinePositions, AngleSyncMode::InPoints, AngleSyncMode::Timecode, AngleSyncMode::Audio]
        );
        assert_eq!(
            AngleSyncMode::choices(&[angle(true), angle(false)], false),
            [AngleSyncMode::InPoints, AngleSyncMode::Timecode]
        );
    }

    #[test]
    fn default_audio_angle_is_the_first_with_sound() {
        assert_eq!(AngleSyncMode::default_audio_angle(&[angle(false), angle(true)]), 1);
        assert_eq!(AngleSyncMode::default_audio_angle(&[angle(false)]), 0);
    }

    #[test]
    fn default_name_takes_the_first_free_number() {
        assert_eq!(AngleSyncMode::default_name(&[]), "Angles 01");
        assert_eq!(AngleSyncMode::default_name(&["Angles 01".into(), "Angles 03".into()]), "Angles 02");
    }

    #[test]
    fn titles_match_the_sheet() {
        assert_eq!(AngleSyncMode::TimelinePositions.title(), "Timeline Positions");
    }
}
