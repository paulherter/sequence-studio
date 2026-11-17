//! "Aa" in a text style, for the style tiles of the Text panel, the Graphics panel and the Captions Style tab.

use sq_draw::{Canvas, Color};
use sq_text::text_style::{RGBAColor, TextStyle};
use sq_uikit::controls_grid::{CGPoint, CGRect};

/// "Aa" in the style's own font, color, outline, shadow and box, centered in `r` (a tile's picture).
pub(crate) fn draw_style_sample(c: &mut Canvas, style: &TextStyle, r: CGRect) {
    let col = |x: &RGBAColor| Color::new(x.red as f32, x.green as f32, x.blue as f32, x.alpha as f32);
    let fs = 17.0;
    let face = c.face_family(&style.font_name, style.weight, style.italic);
    let k = fs / style.size.max(1.0);
    let text = "Aa";
    let size = c.size_of(text, fs, face);
    let at = CGPoint::new(r.mid_x() - size.width / 2.0, r.mid_y() - size.height / 2.0);
    if let Some(bg) = &style.background {
        let (pw, ph) = (bg.padding.horizontal * k, bg.padding.vertical * k);
        let b = CGRect::new(at.x - pw, at.y - ph, size.width + 2.0 * pw, size.height + 2.0 * ph);
        c.fill_rounded(b, (bg.corner_radius * k).min(b.height / 2.0), col(&bg.color));
    }
    if let Some(sh) = &style.shadow {
        let to = CGPoint::new(at.x + sh.offset_x * k, at.y + sh.offset_y * k);
        c.draw_text(text, to, fs, col(&sh.color), f64::INFINITY, face);
    }
    if let Some(st) = style.stroke.as_ref().filter(|st| st.width > 0.0) {
        let d = (st.width * k).clamp(0.75, 2.0);
        for (dx, dy) in [(-d, 0.0), (d, 0.0), (0.0, -d), (0.0, d)] {
            c.draw_text(text, CGPoint::new(at.x + dx, at.y + dy), fs, col(&st.color), f64::INFINITY, face);
        }
    }
    c.draw_text(text, at, fs, col(&style.color), f64::INFINITY, face);
}
