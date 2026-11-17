// Swift: TimelinePanel+Keystones.swift
//! G1 Keystones on the timeline, translated from TimelineView+Keystones: the drop ghost (where and how long a dragged
//! keystone lands on the clip under the pointer) and the bar of the keystone applied last, whose edges stretch it (keys
//! follow live, one undo step on release). The host drives the drop like the media drop: `keystone_hover` per pointer
//! move, `keystone_drop` on release, `keystone_exit` when the drag leaves. The keystone travels as
//! `KeystoneDrag::string`, the Mac pasteboard payload.

use crate::action::TimelineAction;
use crate::panel::{Gesture, TimelinePanel};
use sq_core_edit::timeline_replace::TimelineReplaceExt as _;
use sq_core_effects::keystone::{ClipKeystoneExt as _, Keystone};
use sq_core_model::{Clip, TrackKind};
use sq_core_time::Id;
use sq_draw::Canvas;
use sq_editor_session::TimelineTool;
use sq_timeline_ui::{KeystoneBar, KeystoneEdgeDrag, TrackRow};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{radius, type_size};

/// A bar's rectangle with its clip and track.
struct BarRect {
    rect: CGRect,
    clip: Clip,
    track: Id,
}

impl TimelinePanel {
    // MARK: Drop

    /// The video clip under `p` and its row, when a keystone may land there.
    fn keystone_target(&self, p: CGPoint) -> Option<(Clip, TrackRow)> {
        let row = self.rows().into_iter().find(|r| p.y >= r.y && p.y < r.max_y())?;
        if row.kind != TrackKind::Video {
            return None;
        }
        let track = self.timeline.track(row.track)?;
        if track.is_locked {
            return None;
        }
        let t = self.geometry.unsnapped_time(p.x);
        let c = track.clips().iter().find(|c| c.timeline().start <= t && t < c.timeline().end())?;
        Some((c.clone(), row))
    }

    /// A keystone dragged over the panel at window pixels `x`, `y`: the ghost follows. True when it may land there.
    pub fn keystone_hover(&mut self, k: &Keystone, x: f32, y: f32) -> bool {
        let p = self.point(x, y);
        let ghost = self.keystone_target(p).map(|(c, _)| {
            let local = self.geometry.unsnapped_time(p.x) - c.timeline().start;
            KeystoneBar { clip: c.id, span: k.placement(local, c.timeline().duration), name: k.name.clone() }
        });
        let landed = ghost.is_some();
        self.keystone_ghost = ghost;
        landed
    }

    /// The keystone drag left the panel or was canceled: the ghost goes.
    pub fn keystone_exit(&mut self) {
        self.keystone_ghost = None;
    }

    /// Released over the panel: the keystone lands where the ghost showed (the Mac `onDropKeystone`). Empty when there is
    /// no clip under the pointer.
    pub fn keystone_drop(&mut self, k: &Keystone, x: f32, y: f32) -> Vec<TimelineAction> {
        self.keystone_hover(k, x, y);
        let ghost = self.keystone_ghost.take();
        match ghost {
            Some(g) => vec![TimelineAction::DropKeystone { keystone: Box::new(k.clone()), clip: g.clip, span: g.span }],
            None => Vec::new(),
        }
    }

    // MARK: The bar of the keystone applied last

    /// Shows the bar of a keystone that just landed (or was stretched) on `clip`, as it is now in the session; `None` hides
    /// it. The bar hides by itself once its clip changes by anything but the bar (undo, another edit, deleted).
    pub fn set_keystone_bar(&mut self, bar: Option<KeystoneBar>, clip: Option<Clip>) {
        self.keystone_bar_clip = if bar.is_none() { None } else { clip };
        self.keystone_bar = bar;
    }

    /// `sync`: the bar goes when its clip is no longer what the bar left (the Mac `syncKeystoneBar`).
    pub(crate) fn sync_keystone_bar(&mut self) {
        let Some(bar) = &self.keystone_bar else { return };
        let now = self.timeline.tracks.iter().flat_map(|t| t.clips().iter()).find(|c| c.id == bar.clip);
        if now != self.keystone_bar_clip.as_ref() {
            self.keystone_bar = None;
            self.keystone_bar_clip = None;
        }
    }

    fn bar_rect(&self, bar: &KeystoneBar) -> Option<BarRect> {
        for row in self.rows() {
            if row.kind != TrackKind::Video || row.height < KeystoneBar::MINIMUM_ROW_HEIGHT {
                continue;
            }
            if let Some(c) = self.timeline.track(row.track).and_then(|t| t.clips().iter().find(|c| c.id == bar.clip)) {
                if bar.span.end() > c.timeline().duration {
                    return None; // the clip was trimmed under it
                }
                return Some(BarRect {
                    rect: KeystoneBar::rect(&bar.span, c.timeline().start, &row, &self.geometry),
                    clip: c.clone(),
                    track: row.track,
                });
            }
        }
        None
    }

    /// A press on a bar edge with the Selection tool starts the stretch. True when it took the press.
    pub(crate) fn keystone_down(&mut self, p: CGPoint) -> bool {
        if self.tool_state().timeline_tool() != TimelineTool::Selection {
            return false;
        }
        let Some(bar) = self.keystone_bar.clone() else { return false };
        let Some(r) = self.bar_rect(&bar) else { return false };
        if self.timeline.track(r.track).is_none_or(|t| t.is_locked) {
            return false;
        }
        let Some(edge) = KeystoneBar::edge(p, &r.rect) else { return false };
        self.gesture = Some(Gesture::Keystone(Box::new(KeystoneEdgeDrag {
            current: bar.span.clone(),
            bar,
            edge,
            original: r.clip,
        })));
        true
    }

    /// The pointer is over a bar edge (the host shows the left-right resize cursor).
    pub fn keystone_edge_hovered(&self, x: f32, y: f32) -> bool {
        let p = self.point(x, y);
        if self.tool_state().timeline_tool() != TimelineTool::Selection {
            return false;
        }
        let Some(bar) = &self.keystone_bar else { return false };
        let Some(r) = self.bar_rect(bar) else { return false };
        KeystoneBar::edge(p, &r.rect).is_some()
    }

    pub(crate) fn keystone_dragged(&mut self, d0: &KeystoneEdgeDrag, p: CGPoint) {
        let mut d = d0.clone();
        let fd = self.timeline.format.frame_duration;
        let local = self.geometry.unsnapped_time(p.x) - d.original.timeline().start;
        let span = KeystoneBar::dragged(&d.bar.span, d.edge, local.snapped(fd), d.original.timeline().duration, fd);
        if span == d.current {
            return;
        }
        d.current = span.clone();
        let mut c = d.original.clone();
        c.restretch_keystone(&d.bar.span, &span);
        let bar = KeystoneBar { clip: d.bar.clip, span, name: d.bar.name.clone() };
        self.gesture = Some(Gesture::Keystone(Box::new(d)));
        let mut t = self.timeline.clone();
        if t.replace_clip(c).is_ok() {
            self.timeline = t;
        }
        self.keystone_bar = Some(bar);
    }

    /// Release: the preview goes back to the committed timeline and the session commits the stretch (one undo step).
    pub(crate) fn keystone_up(&mut self, d: &KeystoneEdgeDrag, p: CGPoint) -> Vec<TimelineAction> {
        self.keystone_dragged(d, p);
        let Some(Gesture::Keystone(last)) = &self.gesture else { return Vec::new() };
        let last = (**last).clone();
        let committed = self.committed.clone();
        self.set_timeline(committed);
        if last.current == last.bar.span {
            self.keystone_bar = Some(last.bar);
            return Vec::new();
        }
        vec![TimelineAction::RestretchKeystone {
            clip: last.bar.clip,
            from: last.bar.span,
            to: last.current,
            name: last.bar.name,
        }]
    }

    // MARK: Drawing

    pub(crate) fn draw_keystone_overlay(&self, cv: &mut Canvas, rows: &[TrackRow]) {
        if let Some(bar) = &self.keystone_bar
            && let Some(r) = self.bar_rect(bar)
        {
            self.draw_keystone_bar(cv, r.rect, &bar.name, false);
        }
        let Some(g) = &self.keystone_ghost else { return };
        let Some(row) = rows
            .iter()
            .find(|r| self.timeline.track(r.track).is_some_and(|t| t.clips().iter().any(|c| c.id == g.clip)))
        else {
            return;
        };
        let Some(c) = self.timeline.track(row.track).and_then(|t| t.clips().iter().find(|c| c.id == g.clip)) else {
            return;
        };
        let (x0, x1) = (self.geometry.x(c.timeline().start), self.geometry.x(c.timeline().end()));
        cv.stroke_rounded(
            sq_uikit::controls_grid::CGRect::new(x0, row.y, x1 - x0, row.height - 1.0).inset_by(1.0, 1.0),
            0.0,
            1.0,
            self.theme.accent(),
        );
        let mut r = KeystoneBar::rect(&g.span, c.timeline().start, row, &self.geometry);
        if row.height < KeystoneBar::MINIMUM_ROW_HEIGHT {
            r = CGRect::new(r.min_x(), row.y + 1.0, r.width, row.height - 3.0);
        }
        self.draw_keystone_bar(cv, r, &g.name, true);
    }

    fn draw_keystone_bar(&self, cv: &mut Canvas, r: CGRect, name: &str, ghost: bool) {
        let rad = f64::from(radius::SMALL);
        cv.fill_rounded(r, rad, self.skin().accent_tint());
        cv.stroke_rounded(r, rad, 1.0, self.theme.accent());
        if !ghost && r.width > 10.0 {
            for x in [r.min_x() + 2.0, r.max_x() - 4.0] {
                // edge grips
                cv.fill_rounded(CGRect::new(x, r.min_y() + 2.0, 2.0, r.height - 4.0), 1.0, self.theme.on_clip());
            }
        }
        if r.width <= 30.0 {
            return;
        }
        cv.save_gstate();
        let text = CGRect::new(r.min_x() + 7.0, r.min_y(), r.width - 14.0, r.height);
        cv.clip_to(text);
        cv.draw_text_in(
            name,
            text,
            f64::from(type_size::CAPTION),
            self.theme.on_clip(),
            sq_draw::TextAlign::Left,
            0.0,
            0,
        );
        cv.restore_gstate();
    }
}
