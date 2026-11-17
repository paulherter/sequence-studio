// Swift: DropPreview.swift
//! Live preview of a drop onto the timeline (Premiere): pure reducer, the view feeds it the pointer.

use crate::timeline_geometry::{TimelineGeometry, TimelineHit};
use sq_core_edit::snapping::{SnappingTimelineExt, snap_move};
use sq_core_edit::timeline_beat_snap::{BeatSnapLevel, TimelineBeatSnapExt};
use sq_core_edit::timeline_drop_targets::TimelineDropTargetsExt;
use sq_core_edit::timeline_magnetic_ops::MagneticOpsExt;
use sq_core_edit::timeline_source_edit::SourceStreams;
use sq_core_model::{Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use sq_uikit::keyframe_graph_geometry::Point;
use std::collections::BTreeSet;

/// One item being dragged into the timeline (media from Project or Library, or a text template).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct DropItem {
    /// Shown name.
    pub name: String,
    /// Length.
    pub duration: Time,
    /// Carries picture.
    pub has_video: bool,
    /// Carries sound.
    pub has_audio: bool,
}

impl DropItem {
    /// A video-only item (`hasVideo: true, hasAudio: false` are the Swift defaults).
    pub fn new(name: &str, duration: Time) -> DropItem {
        DropItem { name: name.to_string(), duration, has_video: true, has_audio: false }
    }

    /// An item with explicit streams.
    pub fn with_streams(name: &str, duration: Time, has_video: bool, has_audio: bool) -> DropItem {
        DropItem { name: name.to_string(), duration, has_video, has_audio }
    }
}

/// A ghost clip: where the dropped item would land.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct DropGhost {
    /// Track the clip lands on; a stand-in id when `new_track_ordinal` is set (the track does not exist yet).
    pub track: Id,
    /// Zero-based audio track ordinal of an audio track the drop would create (drawn below the last audio row).
    pub new_track_ordinal: Option<usize>,
    /// Where it lands.
    pub range: TimeRange,
    /// Kind of the ghost.
    pub kind: TrackKind,
    /// Shown name.
    pub name: String,
    /// The ghost sits on a ghost track row (under the last track); the drop creates that track.
    pub on_ghost_row: bool,
}

/// What the preview reads from the timeline view for one pointer update.
#[derive(Clone, Copy)]
pub struct DropContext<'a> {
    /// The timeline under the pointer.
    pub timeline: &'a Timeline,
    /// The view geometry.
    pub geometry: &'a TimelineGeometry,
    /// Snapping on.
    pub snapping: bool,
    /// Playhead (a snap target).
    pub playhead: Time,
    /// Which beat markers snap.
    pub beat_level: BeatSnapLevel,
}

/// What a release commits.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DropCommit {
    /// Start time.
    pub time: Time,
    /// Video track (or the audio track of an audio-only drop); `None` = host default.
    pub track: Option<Id>,
    /// Insert instead of overwrite.
    pub insert: bool,
}

/// Live preview of a drop onto the timeline (Premiere): pure reducer, the view feeds it the pointer.
/// Items are laid out one after another from the snapped start. Command switches overwrite to insert.
/// `cancel()` (drag left the timeline, Esc) clears everything; nothing is ever written to the model here.
#[derive(Clone, Debug)]
pub struct DropPreview {
    items: Vec<DropItem>,
    is_active: bool,
    insert: bool,
    start: Time,
    video_track: Option<Id>,
    pointer_track: Option<Id>,
    ghosts: Vec<DropGhost>,
    ghost_kind: Option<TrackKind>,
    snap_time: Option<Time>,
    can_create_tracks: bool,
    streams: SourceStreams,
}

impl Default for DropPreview {
    fn default() -> DropPreview {
        DropPreview::new()
    }
}

impl DropPreview {
    /// An inactive preview.
    pub fn new() -> DropPreview {
        DropPreview {
            items: Vec::new(),
            is_active: false,
            insert: false,
            start: Time::ZERO,
            video_track: None,
            pointer_track: None,
            ghosts: Vec::new(),
            ghost_kind: None,
            snap_time: None,
            can_create_tracks: false,
            streams: SourceStreams::Both,
        }
    }

    /// The dragged items.
    pub fn items(&self) -> &[DropItem] {
        &self.items
    }

    /// A drag is previewed.
    pub fn is_active(&self) -> bool {
        self.is_active
    }

    /// Insert instead of overwrite.
    pub fn insert(&self) -> bool {
        self.insert
    }

    /// Snapped drop time (valid while active).
    pub fn start(&self) -> Time {
        self.start
    }

    /// Video track under the pointer (`None` = host default: targeted or first).
    pub fn video_track(&self) -> Option<Id> {
        self.video_track
    }

    /// Track of any kind under the pointer.
    pub fn pointer_track(&self) -> Option<Id> {
        self.pointer_track
    }

    /// The ghost clips.
    pub fn ghosts(&self) -> &[DropGhost] {
        &self.ghosts
    }

    /// Set while the pointer is over a ghost track row: the drop creates a track of this kind.
    pub fn ghost_kind(&self) -> Option<TrackKind> {
        self.ghost_kind
    }

    /// Time the start or end snapped to (snap line), `None` when free.
    pub fn snap_time(&self) -> Option<Time> {
        self.snap_time
    }

    /// Whether this drop may create tracks (ghost rows): Project-panel media only.
    pub fn can_create_tracks(&self) -> bool {
        self.can_create_tracks
    }

    /// Streams the drop places (V/A drag toggles).
    pub fn streams(&self) -> SourceStreams {
        self.streams
    }

    /// Sum of the item durations.
    pub fn total_duration(&self) -> Time {
        self.items.iter().fold(Time::ZERO, |a, i| a + i.duration)
    }

    /// Starts a drag of `items`.
    pub fn begin(&mut self, items: Vec<DropItem>, can_create_tracks: bool, streams: SourceStreams) {
        self.can_create_tracks = can_create_tracks;
        self.streams = streams;
        self.is_active = !items.is_empty();
        self.items = items;
    }

    /// Drops everything.
    pub fn cancel(&mut self) {
        *self = DropPreview::new();
    }

    /// Pointer at `point` (view coordinates). Outside the track area (ruler, tool column) the ghost disappears.
    /// `ids` makes the stand-in ids of the ghosts of tracks that do not exist yet.
    pub fn update(&mut self, point: Point, insert: bool, ctx: &DropContext<'_>, ids: &mut dyn IdSource) {
        let DropContext { timeline, geometry, snapping, playhead, beat_level } = *ctx;
        if !self.is_active {
            return;
        }
        self.insert = insert;
        if !(point.y >= TimelineGeometry::RULER_HEIGHT && point.x >= TimelineGeometry::TOOL_COLUMN_WIDTH) {
            self.ghosts = Vec::new();
            self.snap_time = None;
            return;
        }
        let mut t = geometry.time(point.x.max(TimelineGeometry::CONTENT_ORIGIN_X)).max(Time::ZERO);
        self.snap_time = None;
        if snapping && self.total_duration() > Time::ZERO {
            let pts = timeline.snap_points(
                &BTreeSet::new(),
                Some(playhead),
                &timeline.marker_snap_times(beat_level, 4),
                false,
            );
            let r = snap_move(
                t,
                self.total_duration(),
                &pts,
                geometry.snap_threshold(TimelineGeometry::DEFAULT_SNAP_THRESHOLD_POINTS),
                Some(geometry.frame_duration),
            );
            t += r.0;
            self.snap_time = r.1.map(|h| h.time);
        }
        self.start = t.max(Time::ZERO);
        self.ghost_kind = if self.can_create_tracks { geometry.ghost_kind(point, timeline) } else { None };
        self.pointer_track = Self::track_at(point, timeline, geometry);
        self.video_track = self.pointer_track.filter(|t| timeline.track(*t).map(|t| t.kind) == Some(TrackKind::Video));
        self.ghosts = match self.ghost_kind {
            Some(k) => self.ghost_layout(k, ids),
            None => self.layout(timeline, ids),
        };
        // Fast Cut: a drop onto the main track inserts at its nearest edit (V1 never gets a hole or a cut clip); Command
        // overwrites from the pointer instead. Past the end of V1 it lands at the end. Elsewhere the clips attach.
        if timeline.is_fast_cut()
            && self.ghost_kind.is_none()
            && let Some(main) = timeline.main_track_id()
            && self.ghosts.iter().any(|g| g.track == main)
        {
            self.insert = !insert;
            self.start = (if insert { self.start } else { timeline.main_track_drop_point(self.start, None) })
                .min(timeline.main_track_end());
            self.ghosts = self.layout(timeline, ids);
        }
        // A locked target refuses the edit on release: show no ghost (and so no copy cursor) instead of a promise.
        if self.ghosts.iter().any(|g| !g.on_ghost_row && timeline.track(g.track).is_some_and(|t| t.is_locked)) {
            self.ghosts = Vec::new();
        }
    }

    /// The track (any kind) under the pointer; `None` over the ruler or empty space.
    pub(crate) fn track_at(p: Point, timeline: &Timeline, geometry: &TimelineGeometry) -> Option<Id> {
        match geometry.hit_test(p, timeline) {
            TimelineHit::Clip(cid, _) => {
                timeline.tracks.iter().find(|t| t.clips().iter().any(|c| c.id == cid)).map(|t| t.id)
            }
            TimelineHit::Gap(t, _) => Some(t),
            TimelineHit::Header(t) => Some(t),
            _ => None,
        }
    }

    /// Same target rules as `EditorSession::place_media` (`Timeline::drop_targets`): video on the pointer's track (else
    /// targeted, else first), audio on the mirrored audio track V(n) -> A(n); a missing one is drawn as a new track.
    fn layout(&self, t: &Timeline, ids: &mut dyn IdSource) -> Vec<DropGhost> {
        let mut at = self.start;
        let mut out = Vec::new();
        for item in &self.items {
            let r = TimeRange::new(at, item.duration);
            // Only the streams the V/A toggles place (same filter as `placeMedia`).
            let d = t.drop_targets(
                self.pointer_track,
                item.has_video && self.streams.includes_video(),
                item.has_audio && self.streams.includes_audio(),
            );
            if let Some(v) = d.video {
                out.push(DropGhost {
                    track: v,
                    new_track_ordinal: None,
                    range: r,
                    kind: TrackKind::Video,
                    name: item.name.clone(),
                    on_ghost_row: false,
                });
            }
            if let Some(a) = d.audio {
                out.push(DropGhost {
                    track: a,
                    new_track_ordinal: None,
                    range: r,
                    kind: TrackKind::Audio,
                    name: item.name.clone(),
                    on_ghost_row: false,
                });
            } else if let Some(n) = d.new_audio_ordinal {
                out.push(DropGhost {
                    track: ids.next_id(),
                    new_track_ordinal: Some(n),
                    range: r,
                    kind: TrackKind::Audio,
                    name: item.name.clone(),
                    on_ghost_row: false,
                });
            }
            at += item.duration;
        }
        out
    }

    /// Items over a ghost track row: video items on a new video ghost, audio items on a new audio ghost.
    fn ghost_layout(&self, kind: TrackKind, ids: &mut dyn IdSource) -> Vec<DropGhost> {
        let mut at = self.start;
        let mut out = Vec::new();
        for item in &self.items {
            let fits = if kind == TrackKind::Video {
                item.has_video && self.streams.includes_video()
            } else {
                item.has_audio && self.streams.includes_audio()
            };
            if fits {
                out.push(DropGhost {
                    track: ids.next_id(),
                    new_track_ordinal: None,
                    range: TimeRange::new(at, item.duration),
                    kind,
                    name: item.name.clone(),
                    on_ghost_row: true,
                });
            }
            at += item.duration;
        }
        out
    }

    /// The kind of track a release creates (ghost row under the pointer), `None` for a normal drop.
    pub fn commit_ghost_kind(&self) -> Option<TrackKind> {
        if self.is_active && !self.ghosts.is_empty() { self.ghost_kind } else { None }
    }

    /// What a release commits: start time and video track, or `None` when nothing is previewed.
    pub fn commit_target(&self) -> Option<DropCommit> {
        if !(self.is_active && !self.ghosts.is_empty()) {
            return None;
        }
        // Audio-only drops keep the audio track under the pointer; everything else is placed from the video track.
        let audio_only = !self.streams.includes_video() || !self.items.iter().any(|i| i.has_video);
        Some(DropCommit {
            time: self.start,
            track: if audio_only { self.pointer_track } else { self.video_track },
            insert: self.insert,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::*;
    use sq_core_model::Clip;
    use sq_core_time::SequentialIds;

    struct Fx {
        t: Timeline,
        g: TimelineGeometry,
        v1: Id,
        a1: Id,
    }

    fn fixture() -> Fx {
        let c = Clip::new(uid(), "c", uid(), TrackKind::Video, TimeRange::new(Time::ZERO, FD * 48), FD * 100);
        let v1 = track(TrackKind::Video, vec![c]);
        let a1 = track(TrackKind::Audio, vec![]);
        let (v1id, a1id) = (v1.id, a1.id);
        Fx { t: timeline(vec![v1, a1]), g: TimelineGeometry::with_points_per_frame(FD, 10.0), v1: v1id, a1: a1id }
    }

    fn point_on(track: Id, frame: i64, t: &Timeline, g: &TimelineGeometry) -> Point {
        let row = g.rows(t).into_iter().find(|r| r.track == track).unwrap();
        pt(g.x(FD * frame) + 1.0, row.y + row.height / 2.0)
    }

    fn update(p: &mut DropPreview, point: Point, insert: bool, t: &Timeline, g: &TimelineGeometry, snapping: bool) {
        let ctx = DropContext {
            timeline: t,
            geometry: g,
            snapping,
            playhead: Time::ZERO,
            beat_level: BeatSnapLevel::EveryBeat,
        };
        p.update(point, insert, &ctx, &mut SequentialIds::default());
    }

    fn begin(p: &mut DropPreview, items: Vec<DropItem>) {
        p.begin(items, true, SourceStreams::Both);
    }

    #[test]
    fn ghost_length_and_linked_audio() {
        let f = fixture();
        let mut p = DropPreview::new();
        begin(&mut p, vec![DropItem::with_streams("m", FD * 24, true, true)]);
        update(&mut p, point_on(f.v1, 10, &f.t, &f.g), false, &f.t, &f.g, false);
        assert_eq!(p.ghosts().len(), 2);
        assert!(p.ghosts()[0].track == f.v1 && p.ghosts()[1].track == f.a1);
        assert_eq!(p.ghosts()[0].range, TimeRange::new(FD * 10, FD * 24));
        assert_eq!(p.commit_target().map(|c| c.insert), Some(false));
    }

    #[test]
    fn command_means_insert() {
        let f = fixture();
        let mut p = DropPreview::new();
        begin(&mut p, vec![DropItem::new("m", FD * 24)]);
        update(&mut p, point_on(f.v1, 10, &f.t, &f.g), true, &f.t, &f.g, false);
        assert_eq!(p.commit_target().map(|c| c.insert), Some(true));
    }

    #[test]
    fn snaps_end_to_clip_start() {
        let f = fixture();
        let g = TimelineGeometry::with_points_per_frame(FD, 2.0); // 8 pt threshold = 4 frames
        let mut p = DropPreview::new();
        begin(&mut p, vec![DropItem::new("m", FD * 24)]);
        // Pointer at frame 77 -> end 101, within 4 frames of clip start 100.
        update(&mut p, point_on(f.v1, 77, &f.t, &g), false, &f.t, &g, true);
        assert_eq!(p.start(), FD * 76);
        assert_eq!(p.snap_time(), Some(FD * 100));
        update(&mut p, point_on(f.v1, 77, &f.t, &g), false, &f.t, &g, false);
        assert!(p.snap_time().is_none() && p.start() >= FD * 76 && p.start() <= FD * 78);
    }

    #[test]
    fn ruler_hides_ghost_and_cancel_clears() {
        let f = fixture();
        let mut p = DropPreview::new();
        begin(&mut p, vec![DropItem::new("m", FD * 24)]);
        update(&mut p, point_on(f.v1, 10, &f.t, &f.g), false, &f.t, &f.g, false);
        update(&mut p, pt(300.0, 5.0), false, &f.t, &f.g, false);
        assert!(p.ghosts().is_empty() && p.commit_target().is_none());
        update(&mut p, point_on(f.v1, 10, &f.t, &f.g), false, &f.t, &f.g, false);
        p.cancel();
        assert!(!p.is_active() && p.ghosts().is_empty() && p.commit_target().is_none());
    }

    #[test]
    fn items_go_sequentially_and_audio_only_targets_audio() {
        let f = fixture();
        let mut p = DropPreview::new();
        begin(&mut p, vec![DropItem::with_streams("a", FD * 10, false, true), DropItem::new("b", FD * 5)]);
        update(&mut p, point_on(f.v1, 0, &f.t, &f.g), false, &f.t, &f.g, false);
        assert_eq!(p.ghosts().iter().map(|g| g.track).collect::<Vec<_>>(), vec![f.a1, f.v1]);
        assert_eq!(p.ghosts()[1].range.start, FD * 10);
    }

    #[test]
    fn audio_mirrors_upper_video_track_and_missing_one_is_a_ghost_on_a_new_track() {
        let mk_t = |kind, targeted| {
            let mut t = track(kind, vec![]);
            t.is_targeted = targeted;
            t
        };
        let (v1, v2, v3) = (mk_t(TrackKind::Video, true), mk_t(TrackKind::Video, false), mk_t(TrackKind::Video, false));
        let (a1, a2) = (mk_t(TrackKind::Audio, true), mk_t(TrackKind::Audio, false));
        let ids = (v2.id, v3.id, a2.id);
        let t = timeline(vec![v1, v2, v3, a1, a2]);
        let g = TimelineGeometry::with_points_per_frame(FD, 10.0);
        let mut p = DropPreview::new();
        begin(&mut p, vec![DropItem::with_streams("m", FD * 24, true, true)]);
        update(&mut p, point_on(ids.0, 10, &t, &g), false, &t, &g, false);
        assert_eq!(p.ghosts().iter().map(|g| g.track).collect::<Vec<_>>(), vec![ids.0, ids.2]);
        update(&mut p, point_on(ids.1, 10, &t, &g), false, &t, &g, false);
        assert!(
            p.ghosts().len() == 2
                && p.ghosts()[1].new_track_ordinal == Some(2)
                && p.ghosts()[1].kind == TrackKind::Audio
        );
        assert_eq!(p.commit_target().and_then(|c| c.track), Some(ids.1));
    }

    #[test]
    fn audio_only_drop_on_audio_track_stays_there() {
        let f = fixture();
        let mut p = DropPreview::new();
        begin(&mut p, vec![DropItem::with_streams("a", FD * 10, false, true)]);
        update(&mut p, point_on(f.a1, 0, &f.t, &f.g), false, &f.t, &f.g, false);
        assert_eq!(p.ghosts().iter().map(|g| g.track).collect::<Vec<_>>(), vec![f.a1]);
        assert_eq!(p.commit_target().and_then(|c| c.track), Some(f.a1));
    }

    /// Audio-only drag toggle over an audio track: the ghost shows only audio, on that track, and the commit keeps it.
    #[test]
    fn audio_only_streams_follow_the_pointed_audio_track() {
        let mut f = fixture();
        let a2 = track(TrackKind::Audio, vec![]);
        let a2id = a2.id;
        f.t.tracks.push(a2);
        let mut p = DropPreview::new();
        p.begin(vec![DropItem::with_streams("m", FD * 24, true, true)], true, SourceStreams::AudioOnly);
        update(&mut p, point_on(a2id, 10, &f.t, &f.g), false, &f.t, &f.g, false);
        assert_eq!(p.ghosts().iter().map(|g| g.track).collect::<Vec<_>>(), vec![a2id]);
        assert_eq!(p.commit_target().and_then(|c| c.track), Some(a2id));
    }

    #[test]
    fn video_only_streams_draw_no_audio_ghost() {
        let f = fixture();
        let mut p = DropPreview::new();
        p.begin(vec![DropItem::with_streams("m", FD * 24, true, true)], true, SourceStreams::VideoOnly);
        update(&mut p, point_on(f.v1, 10, &f.t, &f.g), false, &f.t, &f.g, false);
        assert_eq!(p.ghosts().iter().map(|g| g.track).collect::<Vec<_>>(), vec![f.v1]);
    }

    /// A drop that would land on a locked track is refused on release: no ghost (and so no copy cursor) over it.
    #[test]
    fn locked_target_shows_no_ghost() {
        let mut f = fixture();
        f.t.tracks[1].is_locked = true; // A1, where the linked audio would go
        let mut p = DropPreview::new();
        begin(&mut p, vec![DropItem::with_streams("m", FD * 24, true, true)]);
        update(&mut p, point_on(f.v1, 10, &f.t, &f.g), false, &f.t, &f.g, false);
        assert!(p.ghosts().is_empty() && p.commit_target().is_none());
    }
}
