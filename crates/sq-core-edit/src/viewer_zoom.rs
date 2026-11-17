// Swift: ViewerZoom.swift
//! Viewer zoom modes. Portable so the Windows monitor places its picture with the same math as the Mac presenter.

/// A width and height in pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Size {
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

/// A rectangle in pixels, origin top-left.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    /// Left edge.
    pub x: f64,
    /// Top edge.
    pub y: f64,
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

/// `Fit`: aspect-fitted. `Percent(p)`: p/100 drawable px per texture px, centered. `View`: free zoom and pan,
/// `scale` = drawable px per texture px, `center_x/y` = the texture offset (from its center) shown at the drawable center.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ViewerZoom {
    /// Aspect-fitted.
    Fit,
    /// p/100 drawable px per texture px.
    Percent(i64),
    /// Free zoom and pan.
    View {
        /// Drawable px per texture px.
        scale: f64,
        /// Texture offset shown at the drawable center, horizontal.
        center_x: f64,
        /// Texture offset shown at the drawable center, vertical.
        center_y: f64,
    },
}

impl ViewerZoom {
    /// True for `Fit`.
    pub fn is_fit(&self) -> bool {
        matches!(self, ViewerZoom::Fit)
    }

    /// Destination rectangle in drawable pixels (origin top-left). Fit scales to the drawable (up or down)
    /// preserving aspect; `Percent(p)` is p/100 drawable px per texture px. Centered, origin snapped to whole pixels.
    pub fn destination_rect(&self, texture: Size, drawable: Size) -> Rect {
        if texture.width <= 0.0 || texture.height <= 0.0 || drawable.width <= 0.0 || drawable.height <= 0.0 {
            return Rect::default();
        }
        let (scale, cx, cy) = match *self {
            ViewerZoom::Fit => ((drawable.width / texture.width).min(drawable.height / texture.height), 0.0, 0.0),
            ViewerZoom::Percent(p) => (p.max(1) as f64 / 100.0, 0.0, 0.0),
            ViewerZoom::View { scale, center_x, center_y } => (scale.max(0.001), center_x, center_y),
        };
        let (w, h) = (texture.width * scale, texture.height * scale);
        Rect {
            x: ((drawable.width - w) / 2.0 - cx * scale).round(),
            y: ((drawable.height - h) / 2.0 - cy * scale).round(),
            width: w,
            height: h,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEX: Size = Size { width: 1920.0, height: 1080.0 };
    const fn size(width: f64, height: f64) -> Size {
        Size { width, height }
    }
    const fn rect(x: f64, y: f64, width: f64, height: f64) -> Rect {
        Rect { x, y, width, height }
    }

    #[test]
    fn fit_scales_to_the_drawable_and_centers() {
        assert_eq!(ViewerZoom::Fit.destination_rect(TEX, size(960.0, 1000.0)), rect(0.0, 230.0, 960.0, 540.0));
    }

    #[test]
    fn percent_is_drawable_pixels_per_texture_pixel() {
        assert_eq!(ViewerZoom::Percent(50).destination_rect(TEX, size(1000.0, 600.0)), rect(20.0, 30.0, 960.0, 540.0));
    }

    #[test]
    fn view_pans_by_the_center_offset() {
        let z = ViewerZoom::View { scale: 1.0, center_x: 100.0, center_y: -50.0 };
        assert_eq!(z.destination_rect(TEX, size(1920.0, 1080.0)), rect(-100.0, 50.0, 1920.0, 1080.0));
    }

    #[test]
    fn empty_sizes_give_zero() {
        assert_eq!(ViewerZoom::Fit.destination_rect(Size::default(), size(10.0, 10.0)), Rect::default());
    }
}
