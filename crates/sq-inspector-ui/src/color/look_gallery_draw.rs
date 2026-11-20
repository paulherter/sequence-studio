// Swift: Draw/LookGalleryDraw.swift
//! The look gallery on the shared toolkit: a heading per group, then 92 x 74 tiles: the sample words in the look's style,
//! still at rest, moving (entrance, loop, exit, lit words) while the pointer is over a tile. The motion is
//! `CaptionStyleLooks::pose` / `lit_word`, the maths playback uses. A click hands the look to the host (`picked`); the host
//! decides where it lands (caption track or text clip).
//! known limit: the sample is drawn with the UI face of the glyph atlas at the look's size and colors (fill, outline as four
//! offset copies, one shadow copy, the box), not with the look's own font: the atlas has one face. Use the text renderer
//! once the shell has a tile image slot.
//! Coordinates: points, y down, (0, 0) = the gallery's top-left.

use sq_core_time::Time;
use sq_draw::theme::{radius, type_size};
use sq_draw::{Canvas, Color, DrawTheme, TextAlign};
use sq_text::caption_karaoke::CaptionKaraoke;
use sq_text::caption_presets::CaptionPresetLibrary;
use sq_text::caption_style_looks::{CaptionStyleLook, CaptionStyleLooks, LookGroup};
use sq_text::text_style::RGBAColor;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::localization::SQL10n;

pub struct LookGalleryDraw {
    pub width: f64,
    /// The look that matches what is applied now (accent outline); nil when nothing matches.
    pub current_id: Option<String>,
    pub groups: Vec<LookGroup>,
    /// The looks the host picked (Swift `onPick`), oldest first.
    pub picked: Vec<CaptionStyleLook>,
    library: CaptionPresetLibrary,
    looks: Vec<(LookGroup, Vec<CaptionStyleLook>)>,
    hover_id: Option<String>,
    hover_start: f64,
    pressed_id: Option<String>,
}

/// Where the headings and tiles sit at one width.
struct Placed {
    headings: Vec<(LookGroup, f64)>,
    tiles: Vec<(usize, usize, CGRect)>,
    height: f64,
}

impl LookGalleryDraw {
    // shortcut: the Mac `Theme.Spacing.sm` (6) at UI scale 1; upgrade when SQUIKit's tokens move into a portable file.
    const PAD: f64 = 6.0;
    const GAP: f64 = 6.0;
    const SWATCH: CGSize = CGSize { width: 92.0, height: 74.0 };
    const HEADING_HEIGHT: f64 = 18.0;
    const WORDS: [&'static str; 3] = ["Say", "it", "loud"];

    pub fn new(library: CaptionPresetLibrary, groups: Vec<LookGroup>) -> LookGalleryDraw {
        let looks = groups
            .iter()
            .map(|g| (*g, CaptionStyleLooks::looks_in(*g).into_iter().cloned().collect::<Vec<_>>()))
            .collect();
        LookGalleryDraw {
            width: 300.0,
            current_id: None,
            groups,
            picked: Vec::new(),
            library,
            looks,
            hover_id: None,
            hover_start: 0.0,
            pressed_id: None,
        }
    }

    /// The built-in library and every group.
    pub fn built_in() -> LookGalleryDraw {
        LookGalleryDraw::new(CaptionPresetLibrary::built_in(), LookGroup::ALL.to_vec())
    }

    pub fn hover_id(&self) -> Option<&str> {
        self.hover_id.as_deref()
    }

    // MARK: Layout (CaptionStyleLookGalleryView.place)

    fn columns(w: f64) -> usize {
        (((w - 2.0 * Self::PAD + Self::GAP) / (Self::SWATCH.width + Self::GAP)) as i64).max(1) as usize
    }

    /// The height the grid needs at `width`.
    pub fn height_for_width(&self, w: f64) -> f64 {
        self.place(w).height
    }

    pub fn height(&self) -> f64 {
        self.height_for_width(self.width)
    }

    fn place(&self, w: f64) -> Placed {
        let cols = Self::columns(w);
        let sw = Self::SWATCH;
        let (pad, gap) = (Self::PAD, Self::GAP);
        let mut y = pad;
        let mut headings = Vec::new();
        let mut tiles = Vec::new();
        for (gi, (g, mine)) in self.looks.iter().enumerate() {
            headings.push((*g, y));
            y += Self::HEADING_HEIGHT;
            for i in 0..mine.len() {
                tiles.push((
                    gi,
                    i,
                    CGRect::new(
                        pad + (i % cols) as f64 * (sw.width + gap),
                        y + (i / cols) as f64 * (sw.height + gap),
                        sw.width,
                        sw.height,
                    ),
                ));
            }
            y += mine.len().div_ceil(cols) as f64 * (sw.height + gap) + 4.0;
        }
        Placed { headings, tiles, height: y + pad }
    }

    fn look_at(&self, p: CGPoint) -> Option<&CaptionStyleLook> {
        self.place(self.width).tiles.iter().find(|t| t.2.contains(p)).map(|t| &self.looks[t.0].1[t.1])
    }

    /// The tile frame of the look with this id.
    pub fn frame_of(&self, id: &str) -> Option<CGRect> {
        self.place(self.width).tiles.iter().find(|t| self.looks[t.0].1[t.1].id == id).map(|t| t.2)
    }

    /// The still frame (`LookSwatchView.restTime`): settled after an entrance, mid-cycle in a loop, before an exit, one word lit.
    pub fn rest_time(group: LookGroup) -> Time {
        match group {
            LookGroup::WordLight => Time::new(1, 1),
            LookGroup::Entrance | LookGroup::Collection => Time::new(3, 2),
            LookGroup::Motion => Time::new(1, 4),
            LookGroup::Exit => Time::ZERO,
        }
    }

    /// The preview time of `look`: its rest frame, or the looping preview window while it is hovered.
    fn time_of(&self, look: &CaptionStyleLook, now: f64) -> Time {
        if self.hover_id.as_deref() != Some(look.id.as_str()) {
            return Self::rest_time(look.group);
        }
        let window = CaptionStyleLooks::PREVIEW_DURATION;
        let ms = ((now - self.hover_start).max(0.0) * 1000.0) as i64;
        Time::new(ms % (window.value() * 1000 / window.timescale()).max(1), 1000)
    }

    // MARK: Drawing

    pub fn draw(&self, c: &mut Canvas, t: &DrawTheme, now: f64) {
        let laid = self.place(self.width);
        for (g, y) in &laid.headings {
            c.draw_text_in(
                &SQL10n::string(g.title()),
                CGRect::new(Self::PAD, *y, (self.width - 2.0 * Self::PAD).max(0.0), Self::HEADING_HEIGHT - 2.0),
                f64::from(type_size::BODY),
                t.label2(),
                TextAlign::Left,
                0.0,
                0,
            );
        }
        for (gi, i, r) in &laid.tiles {
            self.draw_tile(c, t, &self.looks[*gi].1[*i], *r, now);
        }
    }

    fn draw_tile(&self, c: &mut Canvas, t: &DrawTheme, look: &CaptionStyleLook, r: CGRect, now: f64) {
        let current = self.current_id.as_deref() == Some(look.id.as_str());
        let rad = f64::from(radius::CONTROL);
        let tile = CGRect::new(r.min_x(), r.min_y(), r.width, r.height - 16.0).inset_by(1.0, 1.0);
        let hovered = self.hover_id.as_deref() == Some(look.id.as_str());
        c.fill_rounded(tile, rad, if hovered { t.monitor_backdrop() } else { t.content() });
        c.save_gstate();
        c.clip_to(tile);
        self.draw_sample(c, look, tile, now);
        c.restore_gstate();
        c.stroke_rounded(tile, rad, if current { 2.0 } else { 1.0 }, if current { t.label() } else { t.separator() });
        let title = SQL10n::string(&look.title);
        let title = c.truncated_name(&title, f64::from(type_size::CAPTION), 0, r.width + 8.0).shown;
        c.draw_text_in(
            &title,
            CGRect::new(r.min_x() - 4.0, r.max_y() - 15.0, r.width + 8.0, 14.0),
            f64::from(type_size::CAPTION),
            if current { t.label() } else { t.label2() },
            TextAlign::Center,
            0.0,
            0,
        );
    }

    /// `LookSwatchView.drawSample`: the words at 17 pt (sequence pixels to tile points), posed and lit at the tile's time.
    fn draw_sample(&self, c: &mut Canvas, look: &CaptionStyleLook, tile: CGRect, now: f64) {
        let style = self.library.style(Some(look.style_ref.as_str()));
        let k = 17.0 / style.size.max(1.0);
        let at = self.time_of(look, now);
        let pose = CaptionStyleLooks::pose(look, &self.library, at);
        let lit = look.karaoke.as_ref().and_then(|_| CaptionStyleLooks::lit_word(Self::WORDS.len(), at));
        let alpha = pose.opacity.clamp(0.0, 1.0) as f32;
        if !(alpha > 0.001 && pose.scale > 0.01) {
            return;
        }
        let fs = 17.0 * pose.scale;
        let color =
            |col: &RGBAColor| Color::new(col.red as f32, col.green as f32, col.blue as f32, col.alpha as f32 * alpha);

        // The look's own font (bundled families; others draw in the UI face).
        let face = c.face_family(&style.font_name, style.weight, style.italic);
        let space = c.size_of(" ", fs, face).width;
        let widths: Vec<f64> = Self::WORDS.iter().map(|w| c.size_of(w, fs, face).width).collect();
        let text_w = widths.iter().sum::<f64>() + space * (Self::WORDS.len() - 1) as f64;
        let line_h = c.size_of("Say", fs, face).height.max(fs);
        let cx = tile.mid_x() + pose.offset_x * k;
        let cy = tile.mid_y() + pose.offset_y * k;
        let s = pose.scale;
        if let Some(bg) = &style.background {
            let pw = bg.padding.horizontal * k * s;
            let ph = bg.padding.vertical * k * s;
            let b = CGRect::new(cx - text_w / 2.0 - pw, cy - line_h / 2.0 - ph, text_w + 2.0 * pw, line_h + 2.0 * ph);
            c.fill_rounded(b, (bg.corner_radius * k * s).min(b.height / 2.0), color(&bg.color));
        }
        let words = |c: &mut Canvas, dx: f64, dy: f64, ink: &dyn Fn(usize) -> Color| {
            let mut x = cx - text_w / 2.0 + dx;
            for (i, w) in Self::WORDS.iter().enumerate() {
                c.draw_text(w, CGPoint::new(x, cy - line_h / 2.0 + dy), fs, ink(i), f64::INFINITY, face);
                x += widths[i] + space;
            }
        };
        if let Some(sh) = &style.shadow {
            let ink = color(&sh.color);
            words(c, sh.offset_x * k * s, sh.offset_y * k * s, &|_| ink);
        }
        if let Some(st) = style.stroke.as_ref().filter(|st| st.width > 0.0) {
            let d = ((st.width * k).min(3.0) * s).max(0.75);
            let ink = color(&st.color);
            for (dx, dy) in [(-d, 0.0), (d, 0.0), (0.0, -d), (0.0, d)] {
                words(c, dx, dy, &|_| ink);
            }
        }
        let base = color(&style.color);
        let karaoke = look.karaoke.as_ref().map(|ks| (ks.keep_spoken, color(&CaptionKaraoke::color(ks))));
        words(c, 0.0, 0.0, &|i| {
            if let (Some((keep, lit_color)), Some(l)) = (karaoke, lit)
                && if keep { i <= l } else { i == l }
            {
                return lit_color;
            }
            base
        });
    }

    // MARK: Pointer

    /// Hover starts a tile's preview from its first frame (`LookSwatchView.mouseEntered`).
    pub fn mouse_moved(&mut self, p: Option<CGPoint>, now: f64) {
        let id = p.and_then(|p| self.look_at(p)).map(|l| l.id.clone());
        if id == self.hover_id {
            return;
        }
        self.hover_id = id;
        self.hover_start = now;
    }

    pub fn mouse_down(&mut self, p: CGPoint) {
        self.pressed_id = self.look_at(p).map(|l| l.id.clone());
    }

    /// A release over the pressed tile picks its look.
    pub fn mouse_up(&mut self, p: CGPoint) {
        let pressed = self.pressed_id.take();
        let Some(id) = pressed else { return };
        if let Some(l) = self.look_at(p).filter(|l| l.id == id).cloned() {
            self.picked.push(l);
        }
    }

    /// True while a tile is previewing (the host redraws at display rate); no animation runs otherwise.
    pub fn tick(&self) -> bool {
        self.hover_id.is_some()
    }

    pub fn help(&self, p: CGPoint) -> Option<String> {
        self.look_at(p).map(|l| SQL10n::string(&l.title))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_grid_fills_columns_and_groups_stack() {
        let g = LookGalleryDraw::built_in();
        let cols = LookGalleryDraw::columns(300.0);
        assert_eq!(cols, 3);
        let laid = g.place(300.0);
        assert_eq!(laid.headings.len(), LookGroup::ALL.len());
        assert!(laid.headings.windows(2).all(|w| w[1].1 > w[0].1));
        let first = laid.tiles.first().map(|t| t.2);
        assert_eq!(first.map(|r| (r.x, r.width, r.height)), Some((6.0, 92.0, 74.0)));
        assert!(laid.height > laid.headings.last().map_or(0.0, |h| h.1));
        assert_eq!(g.height_for_width(300.0), laid.height);
        // A narrow gallery still has one column.
        assert_eq!(LookGalleryDraw::columns(10.0), 1);
    }

    #[test]
    fn rest_frames_per_group() {
        assert_eq!(LookGalleryDraw::rest_time(LookGroup::WordLight), Time::new(1, 1));
        assert_eq!(LookGalleryDraw::rest_time(LookGroup::Collection), Time::new(3, 2));
        assert_eq!(LookGalleryDraw::rest_time(LookGroup::Motion), Time::new(1, 4));
        assert_eq!(LookGalleryDraw::rest_time(LookGroup::Exit), Time::ZERO);
    }

    #[test]
    fn hover_starts_the_preview_and_a_release_over_the_pressed_tile_picks() {
        let mut g = LookGalleryDraw::built_in();
        let laid = g.place(300.0);
        let (gi, i, r) = laid.tiles[0];
        let id = g.looks[gi].1[i].id.clone();
        let inside = CGPoint::new(r.mid_x(), r.mid_y());
        assert!(!g.tick());
        g.mouse_moved(Some(inside), 10.0);
        assert!(g.tick());
        assert_eq!(g.hover_id(), Some(id.as_str()));
        // The preview loops inside its window and starts at zero.
        let look = g.looks[gi].1[i].clone();
        assert_eq!(g.time_of(&look, 10.0), Time::ZERO);
        let window_ms =
            CaptionStyleLooks::PREVIEW_DURATION.value() * 1000 / CaptionStyleLooks::PREVIEW_DURATION.timescale();
        assert_eq!(g.time_of(&look, 10.0 + (window_ms as f64 + 500.0) / 1000.0), Time::new(500, 1000));
        g.mouse_down(inside);
        g.mouse_up(CGPoint::new(-5.0, -5.0));
        assert!(g.picked.is_empty());
        g.mouse_down(inside);
        g.mouse_up(inside);
        assert_eq!(g.picked.len(), 1);
        assert_eq!(g.picked[0].id, id);
        g.mouse_moved(None, 11.0);
        assert!(!g.tick());
        assert_eq!(g.help(inside), Some(SQL10n::string(&look.title)));
    }
}
