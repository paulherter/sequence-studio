// Swift: TimelineDrop.swift, TimelinePanel+Drop.swift
//! Media dragged in from the Project panel: the ghost clips, the ghost "new track" strips, the snap line and the insert
//! arrow, translated from TimelineView's dragging and `drawDropPreview` with the same `DropPreview`. The host drives it
//! (its drag source knows the items): `drop_hover` per pointer move, `drop_commit` on release, `drop_exit` when it
//! leaves.

use crate::action::TimelineAction;
use crate::geom::RectExt as _;
use crate::panel::TimelinePanel;
use crate::skin::TimelineSkin;
use sq_core_edit::nesting_place::NestingPlaceExt as _;
use sq_core_edit::timeline_source_edit::SourceStreams;
use sq_core_model::{LabelColor, Project, TrackKind};
use sq_core_time::{Id, Time};
use sq_draw::Canvas;
use sq_editor_session::EditorSession;
use sq_timeline_ui::{
    DropContext, DropItem, EffectDropRules, TimelineGeometry, TrackRow, TransitionDropTarget,
    TransitionLayerDropTarget, TransitionLayerLayout, TransitionLayout,
};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{radius, type_size};
use std::path::PathBuf;

/// What a drag onto the timeline carries (Project list media and sequences, files from the system file manager).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TimelineDropSource {
    /// Media of the Project panel.
    Media(Vec<Id>),
    /// Sequences of the Project panel.
    Sequences(Vec<Id>),
    /// Files from the system file manager.
    Files(Vec<PathBuf>),
}

/// Extensions of still pictures and of sound-only files, to guess the streams of a file not probed yet.
const STILL: [&str; 15] =
    ["jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "bmp", "gif", "webp", "psd", "exr", "dng", "svg", "pdf"];
const SOUND: [&str; 11] = ["wav", "aif", "aifc", "aiff", "mp3", "m4a", "aac", "flac", "caf", "ogg", "opus"];

/// Length and streams of what is dragged, for the ghost. Files not imported yet get the 5 s placeholder.
pub fn drop_items(source: &TimelineDropSource, session: &EditorSession, streams: SourceStreams) -> Vec<DropItem> {
    let project: &Project = session.project();
    match source {
        TimelineDropSource::Media(ids) => {
            let marks = &project.source_marks;
            ids.iter()
                .filter_map(|id| {
                    let r = project.media(*id)?;
                    let total = r.info.as_ref().map(|i| i.duration).or(r.duration);
                    let d = marks.get(id).and_then(|m| m.range()).map(|r| r.duration).or(total)?;
                    Some(DropItem::with_streams(
                        &r.name,
                        d,
                        (r.info.as_ref().is_none_or(|i| i.video.is_some())) && streams.includes_video(),
                        r.info.as_ref().is_some_and(|i| i.audio.is_some()) && streams.includes_audio(),
                    ))
                })
                .collect()
        }
        TimelineDropSource::Sequences(ids) => {
            let fd = session.active_timeline().map_or(Time::new(1, 30), |t| t.format.frame_duration);
            ids.iter()
                .filter_map(|id| {
                    let t = project.timeline(*id)?;
                    let d = project.nested_length(*id, fd)?;
                    let has_audio = t.tracks.iter().any(|tr| tr.kind == TrackKind::Audio && !tr.clips().is_empty());
                    Some(DropItem::with_streams(&t.name, d, true, has_audio))
                })
                .collect()
        }
        // Not probed yet: guess the streams from the extension (video files carry audio, stills do not).
        TimelineDropSource::Files(paths) => paths
            .iter()
            .map(|u| {
                let e = u.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
                let name = u.file_name().and_then(|n| n.to_str()).unwrap_or("");
                DropItem::with_streams(
                    name,
                    Time::seconds(5),
                    !SOUND.contains(&e.as_str()),
                    !STILL.contains(&e.as_str()),
                )
            })
            .collect(),
    }
}

/// Alt (the Mac Option) held as Project media or a sequence is released over a clip: a Replace edit with the first item.
/// `match_source_time`: Shift with the Source monitor showing that media, its frame lines up with the playhead. Files
/// return false (they are not imported yet).
pub fn drop_replace(
    source: &TimelineDropSource,
    clip: Id,
    match_source_time: Option<Time>,
    session: &mut EditorSession,
) -> bool {
    match source {
        TimelineDropSource::Media(ids) => {
            !ids.is_empty() && session.replace_media_with_first_of(clip, ids, match_source_time)
        }
        TimelineDropSource::Sequences(ids) => ids.first().is_some_and(|id| session.replace_with_sequence(clip, *id)),
        TimelineDropSource::Files(_) => false,
    }
}

/// Where a released Effects panel drag lands, as `effect_drop_hover` last lit it.
#[derive(Clone, Debug, PartialEq)]
pub enum EffectDrop {
    /// On a clip.
    Clip(Id),
    /// On a cut or clip end.
    Transition(TransitionDropTarget),
    /// On an empty video spot: a transition layer.
    Layer(TransitionLayerDropTarget),
}

impl TimelinePanel {
    /// The pointer (window pixels) over the panel during a drag of `items`; Command = insert. `can_create_tracks` for
    /// Project-panel media and sequences (they may land on the ghost strips under the last track).
    pub fn drop_hover(
        &mut self,
        items: Vec<DropItem>,
        x: f32,
        y: f32,
        insert: bool,
        can_create_tracks: bool,
        streams: SourceStreams,
    ) {
        if !self.drop_preview.is_active() {
            let items = if items.is_empty() { vec![DropItem::new("", Time::seconds(5))] } else { items };
            self.drop_preview.begin(items, can_create_tracks, streams);
            self.geometry.reserves_ghost_space = can_create_tracks; // two ghost rows under the last track, only during the drag
        }
        let p = self.point(x, y);
        let ctx = DropContext {
            timeline: &self.timeline,
            geometry: &self.geometry,
            snapping: self.tool_state().snapping,
            playhead: self.playhead,
            beat_level: self.beat_level,
        };
        let mut ids = sq_core_time::SequentialIds::default();
        self.drop_preview.update(sq_uikit::controls_grid::CGPoint { x: p.x, y: p.y }, insert, &ctx, &mut ids);
    }

    /// Whether a media drag is hovering (the ghost and snap line show).
    pub fn drop_hover_active(&self) -> bool {
        self.drop_preview.is_active()
    }

    /// Whether the hovering drop inserts (Command held) instead of overwriting.
    pub fn drop_inserts(&self) -> bool {
        self.drop_preview.insert()
    }

    /// The effect / transition highlight goes (released, left the panel, Esc).
    pub fn effect_drop_exit(&mut self) {
        self.effect_drop_target = None;
        self.transition_drop_target = None;
        self.transition_layer_drop_target = None;
    }

    /// The release of an Effects panel drag: the target the last `effect_drop_hover` lit, which then goes out.
    pub fn effect_drop_take(&mut self) -> Option<EffectDrop> {
        let drop = if let Some(t) = self.transition_drop_target.take() {
            Some(EffectDrop::Transition(t))
        } else if let Some(l) = self.transition_layer_drop_target.take() {
            Some(EffectDrop::Layer(l))
        } else {
            self.effect_drop_target.take().map(EffectDrop::Clip)
        };
        self.effect_drop_exit();
        drop
    }

    /// Left the panel or Esc: the ghost goes, nothing changed.
    pub fn drop_exit(&mut self) {
        self.effect_drop_exit();
        if !self.drop_preview.is_active() {
            return;
        }
        self.drop_preview.cancel();
        self.geometry.reserves_ghost_space = false;
        self.clamp_scroll();
    }

    /// An Effects panel drag at window pixels `x, y` (the Mac `trackedUpdate` for `.effect`): a transition shows its box
    /// on the cut or clip end (else a transition layer on an empty video spot, `layer_duration` long), an effect or
    /// preset lights up the clip under the pointer when it can land there (`EffectDropRules`). True when a release
    /// would land.
    pub fn effect_drop_hover(&mut self, ids: &[String], x: f32, y: f32, layer_duration: Time) -> bool {
        let p = self.point(x, y);
        let (mut clip_target, mut target, mut layer) = (None, None, None);
        if self.frame.contains(x, y) {
            if let Some(kind) = ids.first().and_then(|id| sq_editor_session::EffectDragPayload::transition_kind(id)) {
                target = TransitionLayout::drop_target(p, kind, &self.timeline, &self.geometry);
                if target.is_none() {
                    layer = TransitionLayerLayout::drop_target(
                        p,
                        kind,
                        &self.timeline,
                        &self.geometry,
                        self.playhead,
                        layer_duration,
                    );
                }
            } else {
                clip_target = self.effect_drop_clip(p, ids);
            }
        }
        self.effect_drop_target = clip_target;
        self.transition_drop_target = target;
        self.transition_layer_drop_target = layer;
        self.effect_drop_target.is_some()
            || self.transition_drop_target.is_some()
            || self.transition_layer_drop_target.is_some()
    }

    /// The clip an effect drag would land on at `p`: the one under the pointer, unless its track is locked or none of
    /// the dragged effects fits it.
    fn effect_drop_clip(&self, p: CGPoint, effect_ids: &[String]) -> Option<Id> {
        let sq_timeline_ui::TimelineHit::Clip(id, _) = self.geometry.hit_test(p, &self.timeline) else { return None };
        for track in self.timeline.tracks.iter() {
            let Some(clip) = track.clips().iter().find(|c| c.id == id) else { continue };
            return if EffectDropRules::accepts(effect_ids, clip, track.is_locked) { Some(id) } else { None };
        }
        None
    }

    /// The highlight boxes of the running effect or transition drag (the accent box of `TimelineView.drawDropBox`).
    fn draw_effect_drop_targets(&self, cv: &mut Canvas, rows: &[TrackRow]) {
        let skin = self.skin();
        let accent = self.theme.accent();
        let box_ = |cv: &mut Canvas, r: CGRect| {
            cv.fill(r, skin.accent_tint());
            cv.stroke_rounded(r.inset(1.0, 1.0), 0.0, 2.0, accent);
        };
        if let Some(id) = self.effect_drop_target
            && let Some((row, c)) = rows
                .iter()
                .find_map(|r| self.timeline.track(r.track)?.clips().iter().find(|c| c.id == id).map(|c| (r, c)))
        {
            box_(cv, CGRect::new(self.geometry.x(c.start), row.y, self.geometry.width(c.duration()), row.height - 1.0));
        }
        if let Some(l) = &self.transition_layer_drop_target {
            box_(cv, l.rect);
            crate::bands::draw_cut_marker(cv, &self.theme, self.geometry.x(l.cut), l.rect.min_y(), l.rect.height, true);
        }
        if let Some(t) = &self.transition_drop_target {
            for r in std::iter::once(t.rect).chain(t.tail_rect) {
                box_(cv, r);
            }
        }
    }

    /// The clip under a host point (device pixels), for a Replace drop.
    pub fn clip_id(&self, x: f32, y: f32) -> Option<Id> {
        if !self.frame.contains(x, y) {
            return None;
        }
        match self.geometry.hit_test(self.point(x, y), &self.timeline) {
            sq_timeline_ui::TimelineHit::Clip(id, _) => Some(id),
            _ => None,
        }
    }

    /// Released over the panel: the media lands where the ghost showed (one undo step). Empty when there is no target.
    pub fn drop_commit(&mut self, media: Vec<Id>, x: f32, y: f32, insert: bool) -> Vec<TimelineAction> {
        self.drop_hover(Vec::new(), x, y, insert, true, SourceStreams::Both);
        let out = match self.drop_preview.commit_target() {
            Some(target) => {
                let ghost_kind = self.drop_preview.commit_ghost_kind();
                vec![TimelineAction::DropMedia {
                    ids: media,
                    time: target.time,
                    track: if ghost_kind.is_none() { target.track } else { None },
                    new_track: ghost_kind,
                    insert: target.insert,
                    streams: self.drop_preview.streams(),
                }]
            }
            None => Vec::new(),
        };
        self.drop_exit();
        out
    }

    pub(crate) fn draw_drop_preview(&self, cv: &mut Canvas, rows: &[TrackRow], clip: CGRect) {
        self.draw_effect_drop_targets(cv, rows);
        if !self.drop_preview.is_active() {
            return;
        }
        let skin: TimelineSkin = self.skin();
        let ghost_rows = if self.drop_preview.can_create_tracks() {
            self.geometry.ghost_rows(&self.timeline).to_vec()
        } else {
            Vec::new()
        };
        let small = f64::from(radius::SMALL);
        for gr in &ghost_rows {
            let hot = self.drop_preview.ghost_kind() == Some(gr.kind);
            let r = CGRect::new(
                TimelineGeometry::TOOL_COLUMN_WIDTH + 2.0,
                gr.y + 1.0,
                (clip.max_x() - TimelineGeometry::TOOL_COLUMN_WIDTH - 4.0).max(0.0),
                gr.height - 2.0,
            );
            cv.fill(r, if hot { skin.accent_tint() } else { skin.fill2() });
            let edge = if hot { self.theme.accent() } else { self.theme.label3() };
            cv.stroke_dashed_rounded(r.inset(0.5, 0.5), small, 1.0, 4.0, 3.0, edge);
            let title = if gr.kind == TrackKind::Video {
                "Drop here to add a video track"
            } else {
                "Drop here to add an audio track"
            };
            cv.draw_text(
                title,
                CGPoint { x: TimelineGeometry::CONTENT_ORIGIN_X + 8.0, y: r.mid_y() - 6.0 },
                f64::from(type_size::CAPTION),
                edge,
                f64::INFINITY,
                0,
            );
        }
        for g in self.drop_preview.ghosts() {
            let (row_y, row_h);
            if let (true, Some(gr)) = (g.on_ghost_row, ghost_rows.iter().find(|gr| gr.kind == g.kind)) {
                row_y = gr.y;
                row_h = gr.height;
            } else if let Some(row) = rows.iter().find(|r| r.track == g.track) {
                row_y = row.y;
                row_h = row.height;
            } else if let Some(n) = g.new_track_ordinal {
                let audio: Vec<&TrackRow> = rows.iter().filter(|r| r.kind == TrackKind::Audio).collect(); // an audio track the drop creates: below the last audio row
                let last = audio.last().copied().or(rows.last());
                row_h = last.map_or(40.0, |l| l.height);
                row_y = last.map_or(TimelineGeometry::RULER_HEIGHT, |l| l.max_y())
                    + n.saturating_sub(audio.len()) as f64 * row_h;
            } else {
                continue;
            }
            let r = CGRect::new(
                self.geometry.x(g.range.start),
                row_y,
                self.geometry.width(g.range.duration).max(2.0),
                row_h - 1.0,
            );
            let label = if g.kind == TrackKind::Audio { LabelColor::AUDIO_DEFAULT } else { LabelColor::VIDEO_DEFAULT };
            cv.fill_rounded(r, small, self.theme.clip(label).with_alpha(0.55)); // `clipGhostAlpha`
            cv.stroke_dashed_rounded(r.inset(0.5, 0.5), small, 1.0, 4.0, 3.0, self.theme.accent());
        }
        if let Some(t) = self.drop_preview.snap_time() {
            cv.fill(CGRect::new(self.geometry.x(t).round() - 0.5, clip.min_y(), 1.0, clip.height), skin.snap_line());
        }
        if self.drop_preview.insert()
            && let Some(first) = self.drop_preview.ghosts().first()
            && let Some(row) = rows.iter().find(|r| r.track == first.track)
        {
            let x = self.geometry.x(self.drop_preview.start());
            let cy = row.y + row.height / 2.0; // the ripple arrow at the insert point
            let p = |x: f64, y: f64| CGPoint { x, y };
            cv.fill_polygon(&[p(x, cy - 7.0), p(x + 9.0, cy), p(x, cy + 7.0)], self.theme.accent());
        }
    }
}
