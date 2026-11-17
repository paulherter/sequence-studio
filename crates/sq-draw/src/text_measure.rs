//! Text widths in points for layout (Swift `TextMeasure`, moved here from SQDrawShell): from the glyph atlas at the device
//! scale, a rough estimate without an atlas.

use crate::canvas::wrap_lines;
use crate::glyph_atlas::GlyphAtlas;

/// Measures text in points. `face`: 0 regular, [`medium`](Self::medium) / [`semibold`](Self::semibold) the atlas faces.
#[derive(Clone, Copy)]
pub struct TextMeasure<'a> {
    /// The atlas the widths come from.
    pub atlas: Option<&'a GlyphAtlas>,
    /// Device pixels per point.
    pub scale: f32,
}

impl<'a> TextMeasure<'a> {
    /// A measure over `atlas` at `scale`.
    pub fn new(atlas: Option<&'a GlyphAtlas>, scale: f32) -> TextMeasure<'a> {
        TextMeasure { atlas, scale }
    }
    /// The Medium face (0 without an atlas).
    pub fn medium(&self) -> usize {
        self.atlas.map_or(0, |a| a.medium_face())
    }
    /// The SemiBold face (0 without an atlas).
    pub fn semibold(&self) -> usize {
        self.atlas.map_or(0, |a| a.semibold_face())
    }

    /// Width of `s` at `size` points.
    pub fn width(&self, s: &str, size: f64, face: usize) -> f64 {
        match self.atlas {
            None => s.chars().count() as f64 * size * 0.55,
            Some(a) => (a.width_of(s, size as f32 * self.scale, face) / self.scale) as f64,
        }
    }

    /// Line height at `size` points, rounded up.
    pub fn line_height(&self, size: f64) -> f64 {
        match self.atlas {
            None => (size * 1.21).ceil(),
            Some(a) => {
                let p = size as f32 * self.scale;
                ((a.ascent(p, 0) + a.descent(p, 0)) / self.scale).ceil() as f64
            }
        }
    }

    /// Lines of greedy word wrap at `width`.
    pub fn lines(&self, s: &str, width: f64, size: f64) -> Vec<String> {
        wrap_lines(s, width, |t| self.width(t, size, 0))
    }

    /// One line of a path with its middle folders cut by an ellipsis ("~/Movies/…/Projects"); any other text loses
    /// its middle characters. See [`crate::middle_fit::fit_path`].
    pub fn truncated_middle(&self, s: &str, width: f64, size: f64) -> String {
        crate::middle_fit::fit_path(s, |t| self.width(t, size, 0) <= width)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::glyph_atlas::tests::atlas;

    #[test]
    fn without_an_atlas_widths_are_estimated() {
        let m = TextMeasure::new(None, 1.0);
        assert_eq!(m.width("abcd", 10.0, 0), 22.0);
        assert_eq!(m.line_height(10.0), 13.0);
        assert_eq!((m.medium(), m.semibold()), (0, 0));
    }

    #[test]
    fn widths_are_points_and_lines_wrap() {
        let a = atlas();
        let m = TextMeasure::new(Some(&a), 2.0);
        let w = m.width("Sequence Studio", 12.0, 0);
        assert!(w > 60.0 && w < 120.0);
        assert!(m.line_height(12.0) >= 12.0);
        let lines = m.lines("Sequence Studio is a video editor for the Mac and Windows", w, 12.0);
        assert!(lines.len() >= 3 && lines.iter().all(|l| m.width(l, 12.0, 0) <= w + 0.5));
        assert!(m.semibold() > 0 && m.medium() > 0);
    }

    #[test]
    fn middle_truncation_keeps_both_ends() {
        let a = atlas();
        let m = TextMeasure::new(Some(&a), 1.0);
        let path = "/Users/anna/Movies/Projects/Very Long Folder Name/final-cut.sqproj";
        let t = m.truncated_middle(path, 160.0, 11.0);
        assert!(t.starts_with("/Users") && t.ends_with(".sqproj") && t.contains('…'));
        assert!(m.width(&t, 11.0, 0) <= 160.0);
        assert_eq!(m.truncated_middle("short", 500.0, 11.0), "short");
    }
}
