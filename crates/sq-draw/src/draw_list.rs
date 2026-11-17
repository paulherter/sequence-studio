//! Colors, rectangles and the frame's quad list (Swift `DrawColor`, `DrawRect`, `DrawQuad`, `DrawList`).

/// A straight-alpha sRGB color, components 0...1 (blended in sRGB code values, as the renderers do).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Color {
    /// Red.
    pub r: f32,
    /// Green.
    pub g: f32,
    /// Blue.
    pub b: f32,
    /// Alpha.
    pub a: f32,
}

impl Color {
    /// White.
    pub const WHITE: Color = Color::rgb(1.0, 1.0, 1.0);
    /// Black.
    pub const BLACK: Color = Color::rgb(0.0, 0.0, 0.0);
    /// Fully transparent black.
    pub const CLEAR: Color = Color::new(0.0, 0.0, 0.0, 0.0);

    /// A color from components.
    pub const fn new(r: f32, g: f32, b: f32, a: f32) -> Color {
        Color { r, g, b, a }
    }

    /// An opaque color.
    pub const fn rgb(r: f32, g: f32, b: f32) -> Color {
        Color::new(r, g, b, 1.0)
    }

    /// 0xRRGGBB with `alpha`.
    pub fn hex(hex: u32, alpha: f32) -> Color {
        let c = |shift: u32| ((hex >> shift) & 0xFF) as f32 / 255.0;
        Color::new(c(16), c(8), c(0), alpha)
    }

    /// The same color with alpha `a`.
    pub fn with_alpha(self, a: f32) -> Color {
        Color { a, ..self }
    }

    /// The straight-alpha blend of `self` toward `to` by `t` (0 = self, 1 = `to`): the middle of a state fade.
    pub fn mix(self, to: Color, t: f32) -> Color {
        let m = |a: f32, b: f32| a + (b - a) * t;
        Color { r: m(self.r, to.r), g: m(self.g, to.g), b: m(self.b, to.b), a: m(self.a, to.a) }
    }

    /// This color mixed toward white by `f` (the clip edge `Theme.lift`).
    pub fn lifted(self, f: f32) -> Color {
        Color::new(self.r + (1.0 - self.r) * f, self.g + (1.0 - self.g) * f, self.b + (1.0 - self.b) * f, self.a)
    }

    /// 0xRRGGBB, rounded; alpha is dropped.
    pub fn rgb_hex(self) -> u32 {
        let byte = |v: f32| (v.clamp(0.0, 1.0) * 255.0).round() as u32;
        byte(self.r) << 16 | byte(self.g) << 8 | byte(self.b)
    }
}

/// A rectangle in pixels, y down.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    /// Left.
    pub x: f32,
    /// Top.
    pub y: f32,
    /// Width.
    pub w: f32,
    /// Height.
    pub h: f32,
}

impl Rect {
    /// The empty rect at the origin.
    pub const ZERO: Rect = Rect::new(0.0, 0.0, 0.0, 0.0);

    /// A rect from origin and size.
    pub const fn new(x: f32, y: f32, w: f32, h: f32) -> Rect {
        Rect { x, y, w, h }
    }
    /// Right edge.
    pub fn max_x(&self) -> f32 {
        self.x + self.w
    }
    /// Bottom edge.
    pub fn max_y(&self) -> f32 {
        self.y + self.h
    }
    /// Horizontal center.
    pub fn mid_x(&self) -> f32 {
        self.x + self.w / 2.0
    }
    /// Vertical center.
    pub fn mid_y(&self) -> f32 {
        self.y + self.h / 2.0
    }
    /// Whether the point lies inside (right and bottom edges excluded).
    pub fn contains(&self, px: f32, py: f32) -> bool {
        px >= self.x && py >= self.y && px < self.x + self.w && py < self.y + self.h
    }
    /// Shrunk by `d` on every side (grown when negative); never negative in size.
    pub fn inset(&self, d: f32) -> Rect {
        Rect::new(self.x + d, self.y + d, (self.w - 2.0 * d).max(0.0), (self.h - 2.0 * d).max(0.0))
    }
    /// The overlap with `o` (zero size when apart).
    pub fn intersection(&self, o: Rect) -> Rect {
        let (x0, y0) = (self.x.max(o.x), self.y.max(o.y));
        let (x1, y1) = (self.max_x().min(o.max_x()), self.max_y().min(o.max_y()));
        Rect::new(x0, y0, (x1 - x0).max(0.0), (y1 - y0).max(0.0))
    }
    /// Splits off the top `v` (returned) and keeps the rest.
    pub fn slice_top(&mut self, v: f32) -> Rect {
        let t = Rect::new(self.x, self.y, self.w, v.min(self.h));
        self.y += t.h;
        self.h -= t.h;
        t
    }
    /// Splits off the bottom `v` (returned) and keeps the rest.
    pub fn slice_bottom(&mut self, v: f32) -> Rect {
        let t = Rect::new(self.x, self.max_y() - v.min(self.h), self.w, v.min(self.h));
        self.h -= t.h;
        t
    }
    /// Splits off the left `v` (returned) and keeps the rest.
    pub fn slice_left(&mut self, v: f32) -> Rect {
        let t = Rect::new(self.x, self.y, v.min(self.w), self.h);
        self.x += t.w;
        self.w -= t.w;
        t
    }
}

/// What a quad draws; the discriminant is the `kind` float the shader reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QuadKind {
    /// Rounded rect, filled or inside-stroked.
    Shape = 0,
    /// Glyph coverage from the atlas.
    Glyph = 1,
    /// The video picture (black in the oracle).
    Video = 2,
    /// Play-style triangle.
    Triangle = 3,
    /// Anti-aliased line with round caps.
    Segment = 4,
    /// An image slot, sampled bilinear.
    Image = 5,
}

/// One GPU instance: every primitive is a quad. `repr` on the GPU: 80 bytes, see [`DrawQuad::write_bytes`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DrawQuad {
    /// Where it draws.
    pub rect: Rect,
    /// Glyph: atlas texel origin (u0, v0). Video, image: normalized source rect. Segment: end points. Triangle: u0 = 1 points left.
    pub uv: [f32; 4],
    /// Straight-alpha color (tint for images).
    pub color: Color,
    /// Corner radius.
    pub radius: f32,
    /// 0 = filled; otherwise the width of an inside stroke (a segment's line width).
    pub stroke: f32,
    /// The primitive.
    pub kind: QuadKind,
    /// Image quads: the image slot (0...5).
    pub slot: f32,
    /// Clip as (x0, y0, x1, y1).
    pub clip: [f32; 4],
}

impl DrawQuad {
    /// Bytes of one instance in the GPU buffer.
    pub const SIZE: usize = 80;

    fn new(rect: Rect, uv: [f32; 4], color: Color, radius: f32, stroke: f32, kind: QuadKind, clip: Rect) -> DrawQuad {
        DrawQuad {
            rect,
            uv,
            color,
            radius,
            stroke,
            kind,
            slot: 0.0,
            clip: [clip.x, clip.y, clip.max_x(), clip.max_y()],
        }
    }

    /// Appends the 80-byte little-endian instance (rect, uv, color, radius, stroke, kind, slot, clip).
    pub fn write_bytes(&self, out: &mut Vec<u8>) {
        let r = &self.rect;
        let c = &self.color;
        let floats = [
            r.x,
            r.y,
            r.w,
            r.h,
            self.uv[0],
            self.uv[1],
            self.uv[2],
            self.uv[3],
            c.r,
            c.g,
            c.b,
            c.a,
            self.radius,
            self.stroke,
            self.kind as u8 as f32,
            self.slot,
            self.clip[0],
            self.clip[1],
            self.clip[2],
            self.clip[3],
        ];
        for f in floats {
            out.extend_from_slice(&f.to_le_bytes());
        }
    }
}

/// The frame's quads in painter's order, with a clip stack. Views fill it, a renderer draws it.
#[derive(Clone, Debug)]
pub struct DrawList {
    quads: Vec<DrawQuad>,
    width: f32,
    height: f32,
    clips: Vec<Rect>,
}

impl DrawList {
    /// Image slots a renderer keeps: 0 timeline thumbnails, 1 Slip two-up, 2-3 scopes, 4 Text template tiles, 5 Source picture.
    pub const IMAGE_SLOTS: usize = 6;

    /// An empty list for a `width x height` canvas.
    pub fn new(width: f32, height: f32) -> DrawList {
        DrawList { quads: Vec::new(), width, height, clips: vec![Rect::new(0.0, 0.0, width, height)] }
    }

    fn with_quads(width: f32, height: f32, quads: Vec<DrawQuad>) -> DrawList {
        DrawList { quads, ..DrawList::new(width, height) }
    }

    /// The quads, painter's order.
    pub fn quads(&self) -> &[DrawQuad] {
        &self.quads
    }
    /// Canvas width in pixels.
    pub fn width(&self) -> f32 {
        self.width
    }
    /// Canvas height in pixels.
    pub fn height(&self) -> f32 {
        self.height
    }

    /// Grows the canvas to at least `w x h` (floating panels draw right of the window, in the same list). Call with no clip
    /// pushed; quads already in the list keep their clips.
    pub fn extend_canvas(&mut self, w: f32, h: f32) {
        self.width = self.width.max(w);
        self.height = self.height.max(h);
        self.clips = vec![Rect::new(0.0, 0.0, self.width, self.height)];
    }

    /// The part of the list inside `r` as a list of its own, `r.w x r.h` pixels with `r`'s corner at the origin. Quads
    /// outside are dropped, clips are cut to `r`, segment end points move with it.
    pub fn region(&self, r: Rect) -> DrawList {
        let bounds = Rect::new(0.0, 0.0, r.w, r.h);
        let mut out = Vec::with_capacity(self.quads.len());
        for q in &self.quads {
            let c = Rect::new(q.clip[0] - r.x, q.clip[1] - r.y, q.clip[2] - q.clip[0], q.clip[3] - q.clip[1])
                .intersection(bounds);
            if c.w <= 0.0 || c.h <= 0.0 {
                continue;
            }
            let mut q = *q;
            q.rect.x -= r.x;
            q.rect.y -= r.y;
            if q.rect.x >= c.max_x() || q.rect.y >= c.max_y() || q.rect.max_x() <= c.x || q.rect.max_y() <= c.y {
                continue;
            }
            if q.kind == QuadKind::Segment {
                q.uv = [q.uv[0] - r.x, q.uv[1] - r.y, q.uv[2] - r.x, q.uv[3] - r.y];
            }
            q.clip = [c.x, c.y, c.max_x(), c.max_y()];
            out.push(q);
        }
        DrawList::with_quads(r.w, r.h, out)
    }

    /// Adds quads built earlier (a layer cache replays them). They carry their own clips.
    pub fn append(&mut self, more: &[DrawQuad]) {
        self.quads.extend_from_slice(more);
    }
    /// Fades and scales the quads from `start` on (an opening popover): alpha times `alpha`, geometry scaled by `scale`
    /// about `origin` (device px). Quads that cover the whole canvas (a dialog's scrim) only fade.
    pub fn transform_from(&mut self, start: usize, alpha: f32, scale: f32, origin: (f32, f32)) {
        let (w, h) = (self.width, self.height);
        let (ox, oy) = origin;
        for q in self.quads.iter_mut().skip(start) {
            q.color.a *= alpha;
            if (scale - 1.0).abs() < 1e-6 || (q.rect.w >= w && q.rect.h >= h) {
                continue;
            }
            q.rect = Rect::new(
                ox + (q.rect.x - ox) * scale,
                oy + (q.rect.y - oy) * scale,
                q.rect.w * scale,
                q.rect.h * scale,
            );
            q.radius *= scale;
            q.stroke *= scale;
            if q.kind == QuadKind::Segment {
                q.uv = [
                    ox + (q.uv[0] - ox) * scale,
                    oy + (q.uv[1] - oy) * scale,
                    ox + (q.uv[2] - ox) * scale,
                    oy + (q.uv[3] - oy) * scale,
                ];
            }
            let c = q.clip;
            q.clip = [
                ox + (c[0] - ox) * scale,
                oy + (c[1] - oy) * scale,
                ox + (c[2] - ox) * scale,
                oy + (c[3] - oy) * scale,
            ];
        }
    }
    /// The quads from index `start` on (what one drawing step added).
    pub fn quads_from(&self, start: usize) -> &[DrawQuad] {
        &self.quads[start.min(self.quads.len())..]
    }

    /// The innermost clip.
    pub fn clip(&self) -> Rect {
        self.clips.last().copied().unwrap_or(Rect::ZERO)
    }
    /// Intersects the clip with `r` until [`pop_clip`](Self::pop_clip).
    pub fn push_clip(&mut self, r: Rect) {
        let c = self.clip().intersection(r);
        self.clips.push(c);
    }
    /// Drops the innermost pushed clip.
    pub fn pop_clip(&mut self) {
        if self.clips.len() > 1 {
            self.clips.pop();
        }
    }

    fn push(&mut self, rect: Rect, uv: [f32; 4], color: Color, radius: f32, stroke: f32, kind: QuadKind) {
        let clip = self.clip();
        self.quads.push(DrawQuad::new(rect, uv, color, radius, stroke, kind, clip));
    }

    /// A filled (rounded) rect.
    pub fn fill(&mut self, r: Rect, c: Color, radius: f32) {
        if r.w > 0.0 && r.h > 0.0 && c.a > 0.0 {
            self.push(r, [0.0; 4], c, radius, 0.0, QuadKind::Shape);
        }
    }
    /// An inside stroke of `width` along the (rounded) rect.
    pub fn stroke(&mut self, r: Rect, c: Color, width: f32, radius: f32) {
        if r.w > 0.0 && r.h > 0.0 && c.a > 0.0 && width > 0.0 {
            self.push(r, [0.0; 4], c, radius, width, QuadKind::Shape);
        }
    }
    /// A triangle filling `r`, pointing right (the play icon) or left.
    pub fn triangle(&mut self, r: Rect, c: Color, pointing_left: bool) {
        self.push(r, [if pointing_left { 1.0 } else { 0.0 }, 0.0, 0.0, 0.0], c, 0.0, 0.0, QuadKind::Triangle);
    }
    /// A straight line, `width` thick with round caps. The quad covers the bounds plus the half width.
    pub fn segment(&mut self, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, c: Color) {
        if width <= 0.0 || c.a <= 0.0 {
            return;
        }
        let pad = width / 2.0 + 1.0;
        let r = Rect::new(x0.min(x1) - pad, y0.min(y1) - pad, (x1 - x0).abs() + 2.0 * pad, (y1 - y0).abs() + 2.0 * pad);
        self.push(r, [x0, y0, x1, y1], c, 0.0, width, QuadKind::Segment);
    }
    /// The video picture into `r`, from the normalized source rect.
    pub fn video(&mut self, r: Rect, source: [f32; 4]) {
        self.push(r, source, Color::WHITE, 0.0, 0.0, QuadKind::Video);
    }
    /// Image slot `slot` into `r` from the normalized `source` rect, bilinear; `tint` multiplies color and alpha.
    pub fn image(&mut self, r: Rect, slot: usize, source: [f32; 4], tint: Color) {
        if r.w <= 0.0 || r.h <= 0.0 || slot >= Self::IMAGE_SLOTS {
            return;
        }
        self.push(r, source, tint, 0.0, 0.0, QuadKind::Image);
        if let Some(q) = self.quads.last_mut() {
            q.slot = slot as f32;
        }
    }
    pub(crate) fn glyph(&mut self, r: Rect, atlas_x: u32, atlas_y: u32, c: Color) {
        self.push(r, [atlas_x as f32, atlas_y as f32, 0.0, 0.0], c, 0.0, 0.0, QuadKind::Glyph);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn extended() -> DrawList {
        let mut l = DrawList::new(100.0, 50.0);
        l.extend_canvas(300.0, 80.0);
        l
    }

    /// Swift `DrawListRegionTests`.
    #[test]
    fn extended_canvas_keeps_quads_right_of_the_old_edge() {
        let mut l = extended();
        l.fill(Rect::new(150.0, 10.0, 40.0, 20.0), Color::WHITE, 0.0);
        assert_eq!((l.width(), l.height()), (300.0, 80.0));
        assert_eq!(l.quads().len(), 1);
        assert_eq!(l.quads()[0].clip[2], 300.0);
    }

    #[test]
    fn region_moves_quads_to_its_origin_and_drops_outsiders() {
        let mut l = extended();
        l.fill(Rect::new(10.0, 5.0, 20.0, 10.0), Color::WHITE, 0.0);
        l.fill(Rect::new(150.0, 10.0, 40.0, 20.0), Color::WHITE, 0.0);
        let r = l.region(Rect::new(120.0, 0.0, 100.0, 60.0));
        assert_eq!((r.width(), r.height()), (100.0, 60.0));
        assert_eq!(r.quads().len(), 1);
        assert_eq!((r.quads()[0].rect.x, r.quads()[0].rect.y), (30.0, 10.0));
        assert_eq!((r.quads()[0].clip[0], r.quads()[0].clip[2]), (0.0, 100.0));
    }

    #[test]
    fn region_cuts_clips_and_moves_segment_ends() {
        let mut l = extended();
        l.push_clip(Rect::new(130.0, 0.0, 50.0, 40.0));
        l.fill(Rect::new(100.0, 0.0, 200.0, 40.0), Color::WHITE, 0.0);
        l.segment(140.0, 10.0, 170.0, 20.0, 2.0, Color::WHITE);
        let r = l.region(Rect::new(120.0, 0.0, 100.0, 60.0));
        assert_eq!(r.quads().len(), 2);
        assert_eq!((r.quads()[0].clip[0], r.quads()[0].clip[2]), (10.0, 60.0));
        let u = r.quads()[1].uv;
        assert_eq!((u[0], u[2], u[1]), (20.0, 50.0, 10.0));
    }

    #[test]
    fn quad_is_80_bytes_with_kind_and_slot() {
        let mut l = DrawList::new(10.0, 10.0);
        l.image(Rect::new(0.0, 0.0, 4.0, 4.0), 3, [0.0, 0.0, 1.0, 1.0], Color::WHITE);
        let mut b = Vec::new();
        l.quads()[0].write_bytes(&mut b);
        assert_eq!(b.len(), DrawQuad::SIZE);
        assert_eq!(f32::from_le_bytes([b[56], b[57], b[58], b[59]]), 5.0);
        assert_eq!(f32::from_le_bytes([b[60], b[61], b[62], b[63]]), 3.0);
    }

    #[test]
    fn empty_and_invisible_draws_add_nothing() {
        let mut l = DrawList::new(10.0, 10.0);
        l.fill(Rect::new(0.0, 0.0, 0.0, 5.0), Color::WHITE, 0.0);
        l.fill(Rect::new(0.0, 0.0, 5.0, 5.0), Color::CLEAR, 0.0);
        l.stroke(Rect::new(0.0, 0.0, 5.0, 5.0), Color::WHITE, 0.0, 0.0);
        l.image(Rect::new(0.0, 0.0, 5.0, 5.0), 6, [0.0; 4], Color::WHITE);
        assert!(l.quads().is_empty());
    }

    #[test]
    fn clip_stack_intersects_and_pops() {
        let mut l = DrawList::new(100.0, 100.0);
        l.push_clip(Rect::new(10.0, 10.0, 50.0, 50.0));
        l.push_clip(Rect::new(30.0, 0.0, 100.0, 100.0));
        assert_eq!(l.clip(), Rect::new(30.0, 10.0, 30.0, 50.0));
        l.pop_clip();
        l.pop_clip();
        l.pop_clip();
        assert_eq!(l.clip(), Rect::new(0.0, 0.0, 100.0, 100.0));
    }
}
