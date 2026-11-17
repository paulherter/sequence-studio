// Swift: TimelinePanel+Bands.swift
//! The volume and opacity rubber bands, translated from TimelineView+VolumeLine.swift and +OpacityLine.swift: the same
//! targets and hit rules; `onVolumeEdit` / `onOpacityEdit` and the host's `TimelineLineGesture` become `ReplaceClip`
//! (the first change opens the undo step, later ones continue it) and one `EndGesture` when the drag ends.

use crate::action::TimelineAction;
use crate::geom::RectExt as _;
use crate::panel::{Gesture, TimelinePanel};
use sq_core_edit::timeline_replace::TimelineReplaceExt as _;
use sq_core_model::fades_curve::{DefaultFadeCurve, FadeCurve};
use sq_core_model::{Clip, TrackKind};
use sq_core_time::{Id, Time};
use sq_editor_session::{LineKeyProperty, LineKeyRef, TimelineTool};
use sq_timeline_ui::{
    FadeDrag, FadeHandle, OpacityHit, OpacityLine, OpacityLineGesture, TimelineGeometry, TimelineHit, TransitionLayout,
    VolumeHit, VolumeLine, VolumeLineGesture,
};
use sq_uikit::controls_grid::{CGPoint, CGRect};

/// What a band drag edits.
#[derive(Clone)]
pub(crate) enum BandKind {
    Volume(VolumeLineGesture),
    Opacity(OpacityLineGesture),
    Fade { handle: FadeHandle, original: Clip, start_x: f64, start_length: Time, rect: CGRect },
}

/// One rubber band drag: translated from `VolumeDrag`, `FadeDrag` and `OpacityDrag` of the Mac view.
#[derive(Clone)]
pub(crate) struct BandDrag {
    pub kind: BandKind,
    pub last: Clip,
    /// The clip before the drag: Esc puts it back.
    pub original: Clip,
    /// The undo name the Mac host's `TimelineLineGesture` gives the step ("Volume" also covers the fade handles).
    pub name: String,
}

/// A target of a band press: the clip, its track and the drawn rectangle.
pub(crate) struct BandTarget {
    pub clip: Clip,
    pub track: Id,
    pub rect: CGRect,
}

impl TimelinePanel {
    /// Clip, track and drawn rectangle under `p` on an audio row tall enough for the volume line (`volumeTarget`).
    pub(crate) fn volume_target(&self, p: CGPoint) -> Option<BandTarget> {
        self.band_target(p, TrackKind::Audio, VolumeLine::is_available)
    }

    /// The same for the opacity line: the line must be shown there and the speed band must not be (`opacityTarget`).
    pub(crate) fn opacity_target(&self, p: CGPoint) -> Option<BandTarget> {
        let t = self.band_target(p, TrackKind::Video, OpacityLine::is_available)?;
        let row = self.rows().into_iter().find(|r| r.track == t.track)?;
        if !OpacityLine::is_visible(&t.clip, self.selection.contains(&t.clip.id), row.height)
            || self.speed_band_clips.contains(&t.clip.id)
        {
            return None;
        }
        Some(t)
    }

    fn band_target(&self, p: CGPoint, kind: TrackKind, available: impl Fn(f64) -> bool) -> Option<BandTarget> {
        if self.tool_state().timeline_tool() != TimelineTool::Selection || p.x < TimelineGeometry::CONTENT_ORIGIN_X {
            return None;
        }
        let rows = self.rows();
        let row = rows.iter().find(|r| p.y >= r.y && p.y < r.max_y())?;
        if row.kind != kind || !available(row.height) {
            return None;
        }
        let track = self.timeline.track(row.track)?;
        if track.is_locked {
            return None;
        }
        // A key sits on the clip edge half outside: look a few points beyond the clip as well.
        let clip = track.clips().iter().find(|c| {
            self.geometry.x(c.timeline().start) - 6.0 <= p.x && p.x < self.geometry.x(c.timeline().end()) + 6.0
        })?;
        let (x0, x1) = (self.geometry.x(clip.timeline().start), self.geometry.x(clip.timeline().end()));
        Some(BandTarget { clip: clip.clone(), track: track.id, rect: CGRect::new(x0, row.y, x1 - x0, row.height) })
    }

    /// Clip and volume key under `p`, for the "Delete Keyframe" menu.
    pub fn volume_key(&self, p: CGPoint) -> Option<(Id, Id)> {
        let t = self.volume_target(p)?;
        match VolumeLine::hit(&t.clip, &t.rect, p, &self.geometry)? {
            VolumeHit::Key(id) => Some((t.clip.id, id)),
            VolumeHit::Line(_) => None,
        }
    }

    /// Clip, handle and current curve of the fade handle under `p`, for the curve menu (curve `None`: no fade yet).
    pub fn fade_handle_hit(&self, p: CGPoint) -> Option<(Id, FadeHandle, Option<FadeCurve>)> {
        let t = self.volume_target(p)?;
        let h = VolumeLine::fade_handle(&t.clip, &t.rect, p, &self.hidden_fade_handles(&t.clip))?;
        let curve = if h == FadeHandle::Head { t.clip.audio_fade_in_curve() } else { t.clip.audio_fade_out_curve() };
        Some((t.clip.id, h, curve))
    }

    /// An audio transition on an edge replaces the fade handle there.
    pub(crate) fn hidden_fade_handles(&self, clip: &Clip) -> Vec<FadeHandle> {
        let mut h = Vec::new();
        if self.timeline.has_audio_transition(clip.id, true) {
            h.push(FadeHandle::Head);
        }
        if self.timeline.has_audio_transition(clip.id, false) {
            h.push(FadeHandle::Tail);
        }
        h
    }

    /// The shape a new audio fade gets (`DefaultFadeCurve.current()`: the stored setting, linear when missing).
    fn default_fade_curve(&self) -> FadeCurve {
        let raw = self
            .height_store
            .as_ref()
            .and_then(|s| s.borrow().data(DefaultFadeCurve::DEFAULTS_KEY))
            .and_then(|b| String::from_utf8(b).ok());
        DefaultFadeCurve::from_stored(raw.as_deref())
    }

    // MARK: Press

    /// Fade handles first, then the volume line, then the opacity line (`beginVolumeDrag`, `beginOpacityDrag`).
    /// `None`: the press is not on a band.
    pub(crate) fn band_down(&mut self, p: CGPoint, command: bool, shift: bool) -> Option<Vec<TimelineAction>> {
        if let Some(t) = self.volume_target(p)
            && t.rect.has(CGPoint { x: p.x, y: t.rect.mid_y() })
            && let Some(h) = VolumeLine::fade_handle(&t.clip, &t.rect, p, &self.hidden_fade_handles(&t.clip))
        {
            let len = if h == FadeHandle::Head { t.clip.audio_fade_in() } else { t.clip.audio_fade_out() };
            return Some(self.begin_band(
                BandKind::Fade { handle: h, original: t.clip.clone(), start_x: p.x, start_length: len, rect: t.rect },
                &t.clip,
                "Volume",
                None,
            ));
        }
        if let Some(t) = self.volume_target(p)
            && let Some(hit) = VolumeLine::hit(&t.clip, &t.rect, p, &self.geometry)
            && self.takes_band(matches!(hit, VolumeHit::Key(_)), p, t.rect, command)
        {
            let mut ids = self.fresh_ids();
            let g = VolumeLineGesture::new(&t.clip, hit, p, t.rect, self.geometry.clone(), command, &mut ids);
            let key = match hit {
                VolumeHit::Key(id) => Some((LineKeyRef::new(t.clip.id, LineKeyProperty::Volume, id), shift)),
                VolumeHit::Line(_) => None,
            };
            return Some(self.begin_band(BandKind::Volume(g), &t.clip, "Volume", key));
        }
        // A transition box sits on the clip edge and wins over the opacity line underneath it.
        if TransitionLayout::hit_test(p, &self.timeline, &self.geometry, TimelineGeometry::MAX_TRIM_HANDLE_WIDTH)
            .is_none()
            && let Some(t) = self.opacity_target(p)
            && let Some(hit) = OpacityLine::hit(&t.clip, &t.rect, p, &self.geometry)
        {
            // A plain 100 % line only answers Cmd-click: a drag near the top of the picture must still move the clip.
            let opacity = &t.clip.animation.opacity;
            let plain = !opacity.is_animated() && opacity.value == 1.0;
            if (command || !plain) && self.takes_band(matches!(hit, OpacityHit::Key(_)), p, t.rect, command) {
                let mut ids = self.fresh_ids();
                let g = OpacityLineGesture::new(&t.clip, hit, p, t.rect, self.geometry.clone(), command, &mut ids);
                let key = match hit {
                    OpacityHit::Key(id) => Some((LineKeyRef::new(t.clip.id, LineKeyProperty::Opacity, id), shift)),
                    OpacityHit::Line(_) => None,
                };
                return Some(self.begin_band(BandKind::Opacity(g), &t.clip, "Opacity", key));
            }
        }
        None
    }

    /// Trimming wins at the clip edges unless Cmd is held (keys inside the edge zone, the line in a trim zone).
    fn takes_band(&self, is_key: bool, p: CGPoint, rect: CGRect, command: bool) -> bool {
        if command {
            return true;
        }
        if is_key {
            return !VolumeLine::edge_wins(p, &rect);
        }
        if let TimelineHit::Clip(_, zone) = self.geometry.hit_test(p, &self.timeline)
            && zone != sq_timeline_ui::ClipZone::Body
        {
            return false;
        }
        true
    }

    fn begin_band(
        &mut self,
        kind: BandKind,
        clip: &Clip,
        name: &str,
        key: Option<(LineKeyRef, bool)>,
    ) -> Vec<TimelineAction> {
        let mut out = Vec::new();
        if self.line_step_open {
            out.push(TimelineAction::EndGesture);
            self.line_step_open = false; // a lost release: close its step first
        }
        if self.selection != std::collections::BTreeSet::from([clip.id]) {
            self.selection = std::collections::BTreeSet::from([clip.id]);
            self.interaction.set_selection(std::collections::BTreeSet::from([clip.id]));
            out.push(TimelineAction::Select {
                clips: std::collections::BTreeSet::from([clip.id]),
                captions: std::collections::BTreeSet::new(),
            });
        }
        if let Some((key, extend)) = key {
            out.push(TimelineAction::LineKeyClick { key: Some(key), extend });
        }
        self.gesture = Some(Gesture::Band(Box::new(BandDrag {
            kind,
            last: clip.clone(),
            original: clip.clone(),
            name: name.to_string(),
        })));
        out
    }

    // MARK: Drag and release

    pub(crate) fn band_dragged(&mut self, d: BandDrag, p: CGPoint) -> Vec<TimelineAction> {
        let mut d = d;
        let c = match &mut d.kind {
            BandKind::Volume(g) => g.update(p),
            BandKind::Opacity(g) => g.update(p),
            BandKind::Fade { handle, original, start_x, start_length, rect } => {
                let fd = self.timeline.format.frame_duration;
                let curve = self.default_fade_curve();
                let mut ids = self.fresh_ids();
                VolumeLine::clip_dragging(
                    original,
                    &FadeDrag { handle: *handle, start_length: *start_length, dx: p.x - *start_x },
                    rect,
                    fd,
                    curve,
                    &mut ids,
                )
            }
        };
        if c == d.last {
            self.gesture = Some(Gesture::Band(Box::new(d)));
            return Vec::new();
        }
        let base = Box::new(std::mem::replace(&mut d.last, c.clone()));
        let name = d.name.clone();
        self.gesture = Some(Gesture::Band(Box::new(d)));
        let _ = self.timeline.replace_clip(c.clone()); // the preview; the session applies the same clip
        let continues = self.line_step_open;
        self.line_step_open = true;
        vec![TimelineAction::ReplaceClip { clip: Box::new(c), base, undo_name: name, continues }]
    }

    /// Esc during a band drag: the clip goes back to what it was before the drag, which drops the drag's undo step (the
    /// session's coalesced step returns to its start). The panel's preview reverts in `cancel_gesture`.
    pub(crate) fn cancel_band_drag(&mut self) -> Vec<TimelineAction> {
        let Some(Gesture::Band(d)) = &self.gesture else { return Vec::new() };
        if !self.line_step_open {
            return Vec::new();
        }
        let (original, base, name) = (d.original.clone(), d.last.clone(), d.name.clone());
        self.line_step_open = false;
        vec![
            TimelineAction::ReplaceClip {
                clip: Box::new(original),
                base: Box::new(base),
                undo_name: name,
                continues: true,
            },
            TimelineAction::EndGesture,
        ]
    }

    pub(crate) fn band_up(&mut self, d: BandDrag, p: CGPoint) -> Vec<TimelineAction> {
        let mut out = self.band_dragged(d, p);
        if self.line_step_open {
            out.push(TimelineAction::EndGesture);
            self.line_step_open = false;
        }
        out
    }
}
