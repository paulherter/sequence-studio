// Swift: TimelinePanel+SourcePatch.swift
//! Source patching (MON-30 / TL-44), translated from `TimelineView+SourcePatch` and the `TrackHeaderView` patch chip:
//! while the Source view holds a clip, a column left of the target chips shows where its video ("V") and audio ("A")
//! go for Insert / Overwrite. Click a chip: that stream on / off (Option: this stream only). Drag it onto another track
//! of its kind: patched there (Shift: both streams by the same offset).

use crate::action::TimelineAction;
use crate::geom::RectExt as _;
use crate::header::TrackHeaderLayout;
use crate::panel::{Gesture, TimelinePanel};
use sq_core_edit::timeline_source_patch::{SourcePatchExt as _, TimelineSourcePatchExt as _};
use sq_core_model::TrackKind;
use sq_core_time::Id;
use sq_draw::{Canvas, InputModifiers, TextAlign};
use sq_timeline_ui::TimelineGeometry;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::radius;
use sq_uikit::redesign_tokens::color;

impl TimelinePanel {
    pub(crate) const PATCH_WIDTH: f64 = 16.0;
    pub(crate) const PATCH_GAP: f64 = 4.0;

    /// The patch chip cell of a header row (header-local).
    pub(crate) fn patch_rect(height: f64) -> CGRect {
        let h = TrackHeaderLayout::CHIP_HEIGHT.min((height - 4.0).max(12.0));
        CGRect::new(TrackHeaderLayout::LEFT_PADDING, ((height - h) / 2.0).round(), Self::PATCH_WIDTH, h)
    }

    /// The target chip, moved right of the patch column while it shows.
    pub(crate) fn target_chip_rect(&self, height: f64) -> CGRect {
        let r = TrackHeaderLayout::chip_rect(height);
        if self.source_patch_streams.is_none() {
            r
        } else {
            CGRect::new(r.x + Self::PATCH_WIDTH + Self::PATCH_GAP, r.y, r.width, r.height)
        }
    }

    /// Caption rows move their chip by the same amount as the track headers (`patchColumnOffset`).
    pub(crate) fn patch_column_offset(&self) -> f64 {
        if self.source_patch_streams.is_none() { 0.0 } else { Self::PATCH_WIDTH + Self::PATCH_GAP - 2.0 }
    }

    /// Track a stream's chip sits on: its patched track, shown even while disconnected.
    fn patch_chip_track(&self, kind: TrackKind) -> Option<Id> {
        let mut on = self.timeline.source_patch();
        on.slot_mut(kind).is_connected = true;
        self.timeline.patched_track(&on, kind)
    }

    /// The chip a header row shows; `None` without a source, for a stream the source lacks, or on another track.
    pub(crate) fn patch_chip(&self, track: Id) -> Option<(TrackKind, bool)> {
        let streams = self.source_patch_streams.as_ref()?;
        for kind in [TrackKind::Video, TrackKind::Audio] {
            if streams.contains(&kind) && self.patch_chip_track(kind) == Some(track) {
                return Some((kind, self.timeline.source_patch().slot(kind).is_connected));
            }
        }
        None
    }

    /// The track of `kind` whose header row is under `p`; `None` off the header column or on another kind.
    fn patch_track(&self, kind: TrackKind, p: CGPoint) -> Option<Id> {
        if !(p.x >= TimelineGeometry::TOOL_COLUMN_WIDTH
            && p.x <= TimelineGeometry::CONTENT_ORIGIN_X
            && p.y >= TimelineGeometry::RULER_HEIGHT)
        {
            return None;
        }
        self.rows().iter().find(|r| r.kind == kind && p.y >= r.y && p.y < r.max_y()).map(|r| r.track)
    }

    /// A press on a patch chip (a little larger than drawn, as on the Mac) begins the click or drag.
    pub(crate) fn patch_down(&mut self, p: CGPoint) -> bool {
        if self.source_patch_streams.is_none()
            || !(p.x >= TimelineGeometry::TOOL_COLUMN_WIDTH && p.x < TimelineGeometry::CONTENT_ORIGIN_X)
        {
            return false;
        }
        let rows = self.rows();
        let Some(row) = rows.iter().find(|r| p.y >= r.y && p.y < r.max_y()) else { return false };
        let Some((kind, _)) = self.patch_chip(row.track) else { return false };
        let local = CGPoint { x: p.x - TimelineGeometry::TOOL_COLUMN_WIDTH, y: p.y - row.y };
        if !Self::patch_rect(row.height).inset(-2.0, -3.0).has(local) {
            return false;
        }
        self.gesture = Some(Gesture::Patch { kind, down: p, dragging: false });
        true
    }

    pub(crate) fn patch_dragged(&mut self, kind: TrackKind, down: CGPoint, dragging: bool, p: CGPoint) {
        let now = dragging || (p.x - down.x).hypot(p.y - down.y) >= 3.0;
        self.gesture = Some(Gesture::Patch { kind, down, dragging: now });
        if now {
            self.patch_drop_track = self.patch_track(kind, p);
        }
    }

    pub(crate) fn patch_up(&mut self, kind: TrackKind, dragging: bool, p: CGPoint) -> Vec<TimelineAction> {
        self.patch_drop_track = None;
        if !dragging {
            return vec![TimelineAction::SourcePatchClick {
                kind,
                solo: self.drag_modifiers().contains(InputModifiers::OPTION),
            }];
        }
        let Some(hit) = self.patch_track(kind, p) else { return Vec::new() };
        vec![TimelineAction::SourcePatchMove {
            kind,
            to: hit,
            both: self.drag_modifiers().contains(InputModifiers::SHIFT),
        }]
    }

    /// Connected: light pill, the letter on it. Disconnected: hairline outline, gray letter. Drop target: accent ring.
    pub(crate) fn draw_patch(&self, cv: &mut Canvas, track: Id, height: f64) {
        if self.source_patch_streams.is_none() {
            return;
        }
        let r = Self::patch_rect(height).inset(0.5, 0.5);
        let rad = f64::from(radius::SMALL) + 1.0;
        if self.patch_drop_track == Some(track) {
            // Draft `.tl-patch.drop`: a 1 pt accent ring and a 2.5 pt quiet halo outside the chip.
            cv.stroke_rounded(r.inset(-2.25, -2.25), rad + 2.25, 2.5, self.theme.token(color::ACCENT_ZONE));
            cv.stroke_rounded(r.inset(-0.5, -0.5), rad + 0.5, 1.0, self.theme.accent());
        }
        let Some((kind, connected)) = self.patch_chip(track) else { return };
        if connected {
            // Draft: connected = a light pill like M/S on, never the accent (r8: no blue for on).
            cv.fill_rounded(r, rad, self.theme.token(color::TEXT));
        } else {
            cv.stroke_rounded(r, rad, 1.0, self.theme.token(color::LINE2));
        }
        cv.draw_text_in(
            if kind == TrackKind::Video { "V" } else { "A" },
            r,
            10.0,
            if connected { self.theme.token(color::GROUP) } else { self.theme.label3() },
            TextAlign::Center,
            0.0,
            0,
        );
    }
}
