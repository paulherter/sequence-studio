// Swift: Draw/ColorSourcesDraw.swift
//! The pure layout of the Color page's Clips strip, and the strip as shared-toolkit draw code: one tile per source file of
//! the active sequence in one row, the graded source with the yellow ring; click grades every use, right-click opens the
//! grade menu, the arrow keys step through the sources. Scrolls sideways.
//! Tile pictures come from the host's `thumbnail` (image slots), the frame of the first cut (`frame_time`), aspect-filled;
//! a plain fill until it is decoded.

use super::color_grade_controller::{ColorGradeController, ColorMenuCommand};
use super::color_grade_target::ColorSourceListItem;
use super::color_page_models::{ColorPageFormat, ColorUses};
use sq_core_model::{Project, Timeline};
use sq_core_time::{Id, Time};
use sq_draw::theme::{radius, type_size};
use sq_draw::{Canvas, DrawTheme, InputKey, InputModifiers, TextAlign};
use sq_editor_session::{ColorClipboard, EditorSession};
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqmenu_model::SQMenuItem;

/// The pure layout of the Color page's Clips strip.
pub struct ColorSourcesLayout;

impl ColorSourcesLayout {
    /// Strip padding and the gap between tiles (design source: 14 / 14).
    pub const PAD: f64 = 14.0;
    /// Thumbnail to name, and name to the uses line.
    pub const LINE_GAP: f64 = 5.0;
    pub const RING: f64 = 2.0;

    /// The sources a tile stands for: picture sources only.
    pub fn tiles(timeline: Option<&Timeline>, project: &Project) -> Vec<ColorSourceListItem> {
        ColorSourceListItem::items(timeline, Some(project)).into_iter().filter(|i| !i.is_adjustment).collect()
    }

    /// Thumbnail size in the shape of the sequence: 104 x 184 for portrait, 184 x 104 for landscape, 144 square.
    pub fn thumb_size(f: ColorPageFormat) -> CGSize {
        match f {
            ColorPageFormat::Portrait => CGSize::new(104.0, 184.0),
            ColorPageFormat::Landscape => CGSize::new(184.0, 104.0),
            ColorPageFormat::Square => CGSize::new(144.0, 144.0),
        }
    }

    /// What the empty state says (nil = there are tiles).
    pub fn empty_state(has_sequence: bool, item_count: usize) -> Option<(&'static str, &'static str)> {
        if !has_sequence {
            return Some(("No sequence open", "Open a sequence to grade its clips."));
        }
        if item_count == 0 {
            return Some(("No video clips", "Add clips to the sequence to grade them."));
        }
        None
    }

    /// The tile an arrow key moves to: the next/previous one, none beyond the ends; from no tile the first/last.
    pub fn stepped_index(from: Option<usize>, count: usize, forward: bool) -> Option<usize> {
        if count == 0 {
            return None;
        }
        let Some(from) = from else { return Some(if forward { 0 } else { count - 1 }) };
        let next = if forward { from as i64 + 1 } else { from as i64 - 1 };
        Some(next.clamp(0, count as i64 - 1) as usize)
    }

    /// The media time a tile shows: the middle of the source range its first cut uses (the frame the cut is about,
    /// not the media's poster). nil when the tile has no cut.
    pub fn frame_time(item: &ColorSourceListItem, timeline: Option<&Timeline>) -> Option<Time> {
        let id = item.clips.first()?;
        let c = timeline?.tracks.iter().flat_map(|t| t.clips()).find(|c| c.id == *id)?;
        if c.source.duration <= Time::ZERO {
            return None;
        }
        let d = c.source.duration;
        let mid = c.source.start + Time::new(d.value(), d.timescale() * 2);
        Some(mid.min(c.source.start.max(c.source.end() - Time::new(1, 1000))))
    }

    /// The tile of the source being graded: the one holding `picked` (none while the whole sequence is graded).
    pub fn highlighted(items: &[ColorSourceListItem], whole_sequence: bool, picked: Option<Id>) -> Option<usize> {
        if whole_sequence {
            return None;
        }
        let picked = picked?;
        items.iter().position(|i| i.clips.contains(&picked))
    }

    /// The menu of a tile: copy / paste of the grade, "Link All Cuts" for a source used more than once. Picked rows queue
    /// a [`ColorMenuCommand`] in the controller's `menu_sink`.
    pub fn menu(
        item: Option<&ColorSourceListItem>,
        controller: &ColorGradeController,
        session: &EditorSession,
        clipboard: &ColorClipboard,
    ) -> Vec<SQMenuItem> {
        let row = |title: &str, c: ColorMenuCommand| -> SQMenuItem {
            let sink = controller.menu_sink.clone();
            let mut i = SQMenuItem::new(title);
            i.action = Some(std::rc::Rc::new(move || sink.push(c.clone())));
            i
        };
        let mut copy = row("Copy Grade", ColorMenuCommand::CopyGrade);
        copy.shortcut = sq_uikit::key_binding_text::KeyBindingText::command_hint_here('c');
        let mut paste = row("Paste Grade", ColorMenuCommand::PasteGrade { on_top: false });
        paste.shortcut = sq_uikit::key_binding_text::KeyBindingText::command_hint_here('v');
        paste.is_enabled = controller.can_paste_grade(session, clipboard);
        let mut entries = vec![copy, paste];
        if let Some(item) = item.filter(|i| i.clips.len() > 1) {
            entries.push(SQMenuItem::separator());
            entries.push(row("Link All Cuts", ColorMenuCommand::LinkAllUses(item.clone())));
        }
        entries
    }
}

/// A source's picture: image slot, normalized part of the slot and its pixel size.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SourceThumbnail {
    pub slot: usize,
    pub source: [f32; 4],
    pub pixel_size: CGSize,
}

/// The menu a pointer press asks the host to show (Swift `onMenu`).
#[derive(Clone, Debug)]
pub struct SourcesMenuRequest {
    pub items: Vec<SQMenuItem>,
    pub anchor: CGRect,
}

/// The Clips strip of the Color page as shared-toolkit draw code.
pub struct ColorSourcesDraw {
    pub size: CGSize,
    scroll_x: f64,
    hovered: Option<usize>,
    /// Menus the strip asked for, oldest first (Swift `onMenu`).
    pub menus: Vec<SourcesMenuRequest>,
}

impl Default for ColorSourcesDraw {
    fn default() -> Self {
        ColorSourcesDraw { size: CGSize::new(600.0, 200.0), scroll_x: 0.0, hovered: None, menus: Vec::new() }
    }
}

impl ColorSourcesDraw {
    pub fn new() -> ColorSourcesDraw {
        ColorSourcesDraw::default()
    }

    pub fn scroll_x(&self) -> f64 {
        self.scroll_x
    }

    pub fn hovered(&self) -> Option<usize> {
        self.hovered
    }

    fn items(session: &EditorSession) -> Vec<ColorSourceListItem> {
        ColorSourcesLayout::tiles(session.active_timeline(), session.project())
    }

    fn highlighted(controller: &ColorGradeController, items: &[ColorSourceListItem]) -> Option<usize> {
        ColorSourcesLayout::highlighted(items, controller.is_whole_sequence(), controller.target().pick())
    }

    fn line_height() -> f64 {
        f64::from(type_size::BODY) + 4.0
    }

    pub fn tile_size(&self, controller: &ColorGradeController) -> CGSize {
        let t = ColorSourcesLayout::thumb_size(controller.format());
        CGSize::new(t.width, t.height + 2.0 * (ColorSourcesLayout::LINE_GAP + Self::line_height()))
    }

    /// Tile `i` in panel coordinates (the scroll applied).
    pub fn tile_rect(&self, controller: &ColorGradeController, i: usize) -> CGRect {
        let p = ColorSourcesLayout::PAD;
        let s = self.tile_size(controller);
        CGRect::new(p + i as f64 * (s.width + p) - self.scroll_x, p, s.width, s.height)
    }

    pub fn content_width(&self, controller: &ColorGradeController, count: usize) -> f64 {
        let n = count as f64;
        let p = ColorSourcesLayout::PAD;
        2.0 * p + n * self.tile_size(controller).width + (n - 1.0).max(0.0) * p
    }

    fn tile_index(&self, controller: &ColorGradeController, count: usize, p: CGPoint) -> Option<usize> {
        (0..count).find(|i| self.tile_rect(controller, *i).contains(p))
    }

    pub fn draw(
        &mut self,
        c: &mut Canvas,
        t: &DrawTheme,
        controller: &ColorGradeController,
        session: &EditorSession,
        thumbnail: &dyn Fn(Id, Option<Time>) -> Option<SourceThumbnail>,
    ) {
        let fs = f64::from(type_size::BODY);
        let bounds = CGRect::new(0.0, 0.0, self.size.width, self.size.height);
        c.fill(bounds, t.content());
        let list = Self::items(session);
        if let Some(e) = ColorSourcesLayout::empty_state(session.active_timeline().is_some(), list.len()) {
            c.draw_text_in(
                &SQL10n::string(e.0),
                CGRect::new(0.0, bounds.mid_y() - 18.0, bounds.width, 18.0),
                f64::from(type_size::TITLE),
                t.label2(),
                TextAlign::Center,
                0.0,
                c.semibold(),
            );
            c.draw_text_in(
                &SQL10n::string(e.1),
                CGRect::new(0.0, bounds.mid_y() + 2.0, bounds.width, 16.0),
                fs,
                t.label3(),
                TextAlign::Center,
                0.0,
                0,
            );
            return;
        }
        self.clamp_scroll(controller, list.len());
        let ts = ColorSourcesLayout::thumb_size(controller.format());
        let gap = ColorSourcesLayout::LINE_GAP;
        let lh = Self::line_height();
        let ring = Self::highlighted(controller, &list);
        let rad = f64::from(radius::CONTROL);
        c.save_gstate();
        c.clip_to(bounds);
        for (i, item) in list.iter().enumerate() {
            let r = self.tile_rect(controller, i);
            if !(r.max_x() >= -4.0 && r.min_x() <= bounds.max_x() + 4.0) {
                continue;
            }
            let thumb = CGRect::new(r.min_x(), r.min_y(), ts.width, ts.height);
            c.fill_rounded(thumb, rad, if Some(i) == self.hovered { t.fill_hover() } else { t.fill() });
            if let Some(p) = thumbnail(item.media, ColorSourcesLayout::frame_time(item, session.active_timeline())) {
                // The Mac tile draws the image aspect-filled: centered, the longer side cut.
                let src = sq_draw::fill_source(p.source, p.pixel_size, thumb);
                c.draw_image_slot(p.slot, thumb, src, sq_draw::Color::rgb(1.0, 1.0, 1.0));
                c.round_picture_corners(thumb, rad, t.content());
            }
            if Some(i) == ring {
                let w = ColorSourcesLayout::RING;
                c.stroke_rounded(thumb.inset_by(-w / 2.0, -w / 2.0), rad + w / 2.0, w, t.yellow());
            }
            c.draw_text(&item.name, CGPoint::new(r.min_x(), thumb.max_y() + gap), fs, t.label(), r.width, 0);
            let line = SQL10n::string(&ColorUses::tile_line(item.clips.len() as i64, &item.grade_text));
            c.draw_text(&line, CGPoint::new(r.min_x(), thumb.max_y() + 2.0 * gap + lh), fs, t.label3(), r.width, 0);
        }
        c.restore_gstate();
    }

    fn clamp_scroll(&mut self, controller: &ColorGradeController, count: usize) {
        let max = (self.content_width(controller, count) - self.size.width).max(0.0);
        self.scroll_x = self.scroll_x.clamp(0.0, max);
    }

    pub fn mouse_moved(&mut self, controller: &ColorGradeController, session: &EditorSession, p: Option<CGPoint>) {
        let n = Self::items(session).len();
        self.hovered = p.and_then(|p| self.tile_index(controller, n, p));
    }

    /// The tip under the pointer: the tile's whole name (names are cut at the tile width).
    pub fn help(&self, controller: &ColorGradeController, session: &EditorSession, p: CGPoint) -> Option<String> {
        let items = Self::items(session);
        self.tile_index(controller, items.len(), p).map(|i| items[i].name.clone())
    }

    /// A click grades every use of the tile's source; secondary opens the grade menu.
    pub fn mouse_down(
        &mut self,
        controller: &mut ColorGradeController,
        session: &mut EditorSession,
        clipboard: &ColorClipboard,
        p: CGPoint,
        modifiers: InputModifiers,
    ) {
        let list = Self::items(session);
        let Some(i) = self.tile_index(controller, list.len(), p) else { return };
        controller.pick_source(session, &list[i]);
        if modifiers.contains(InputModifiers::SECONDARY) {
            let items = ColorSourcesLayout::menu(Some(&list[i]), controller, session, clipboard);
            self.menus.push(SourcesMenuRequest { items, anchor: CGRect::new(p.x, p.y, 1.0, 1.0) });
        }
    }

    pub fn scroll(&mut self, controller: &ColorGradeController, session: &EditorSession, dx: f64, dy: f64) {
        self.scroll_x += if dx.abs() > dy.abs() { -dx } else { -dy };
        self.clamp_scroll(controller, Self::items(session).len());
    }

    /// The arrow keys step through the sources and grade the one reached (and scroll it into view).
    pub fn key(
        &mut self,
        controller: &mut ColorGradeController,
        session: &mut EditorSession,
        k: InputKey,
        _modifiers: InputModifiers,
    ) -> bool {
        let forward = match k {
            InputKey::Right | InputKey::Down => true,
            InputKey::Left | InputKey::Up => false,
            _ => return false,
        };
        let list = Self::items(session);
        let current = Self::highlighted(controller, &list);
        let Some(i) = ColorSourcesLayout::stepped_index(current, list.len(), forward) else { return true };
        controller.pick_source(session, &list[i]);
        let r = self.tile_rect(controller, i);
        let p = ColorSourcesLayout::PAD;
        if r.min_x() < p {
            self.scroll_x += r.min_x() - p;
        } else if r.max_x() > self.size.width - p {
            self.scroll_x += r.max_x() - self.size.width + p;
        }
        self.clamp_scroll(controller, list.len());
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thumbnails_follow_the_sequence_shape() {
        assert_eq!(ColorSourcesLayout::thumb_size(ColorPageFormat::Landscape), CGSize::new(184.0, 104.0));
        assert_eq!(ColorSourcesLayout::thumb_size(ColorPageFormat::Portrait), CGSize::new(104.0, 184.0));
        assert_eq!(ColorSourcesLayout::thumb_size(ColorPageFormat::Square), CGSize::new(144.0, 144.0));
    }

    #[test]
    fn empty_states() {
        assert_eq!(ColorSourcesLayout::empty_state(false, 0).map(|e| e.0), Some("No sequence open"));
        assert_eq!(ColorSourcesLayout::empty_state(true, 0).map(|e| e.0), Some("No video clips"));
        assert_eq!(ColorSourcesLayout::empty_state(true, 2), None);
    }

    #[test]
    fn arrows_stop_at_the_ends_and_start_at_the_first_or_last() {
        assert_eq!(ColorSourcesLayout::stepped_index(None, 3, true), Some(0));
        assert_eq!(ColorSourcesLayout::stepped_index(None, 3, false), Some(2));
        assert_eq!(ColorSourcesLayout::stepped_index(Some(2), 3, true), Some(2));
        assert_eq!(ColorSourcesLayout::stepped_index(Some(0), 3, false), Some(0));
        assert_eq!(ColorSourcesLayout::stepped_index(Some(1), 3, true), Some(2));
        assert_eq!(ColorSourcesLayout::stepped_index(Some(1), 0, true), None);
    }

    #[test]
    fn the_ring_marks_the_tile_holding_the_picked_clip() {
        let item = |ids: &[u128]| ColorSourceListItem {
            media: Id::from_u128(100),
            name: String::new(),
            clips: ids.iter().map(|n| Id::from_u128(*n)).collect(),
            graded: false,
            is_adjustment: false,
            grade_text: String::new(),
        };
        let items = vec![item(&[1, 2]), item(&[3])];
        assert_eq!(ColorSourcesLayout::highlighted(&items, false, Some(Id::from_u128(3))), Some(1));
        assert_eq!(ColorSourcesLayout::highlighted(&items, true, Some(Id::from_u128(3))), None);
        assert_eq!(ColorSourcesLayout::highlighted(&items, false, None), None);
    }
}

/// The Swift `fillSourceCutsTheLongerSide` test of ColorGradeDrawTests, on the shared `sq_draw::fill_source`.
#[cfg(test)]
mod ported_tests {
    use sq_draw::fill_source;
    use sq_uikit::controls_grid::{CGRect, CGSize};

    #[test]
    fn fill_source_cuts_the_longer_side() {
        let tile = |w: f64, h: f64| CGRect::new(0.0, 0.0, w, h);
        let wide = fill_source([0.0, 0.0, 1.0, 1.0], CGSize::new(200.0, 100.0), tile(100.0, 100.0));
        assert_eq!(wide, [0.25, 0.0, 0.75, 1.0]);
        let tall = fill_source([0.0, 0.0, 1.0, 1.0], CGSize::new(100.0, 200.0), tile(100.0, 100.0));
        assert_eq!(tall, [0.0, 0.25, 1.0, 0.75]);
        let same = fill_source([0.1, 0.2, 0.3, 0.4], CGSize::new(16.0, 9.0), tile(160.0, 90.0));
        assert_eq!(same, [0.1, 0.2, 0.3, 0.4]);
    }
}
