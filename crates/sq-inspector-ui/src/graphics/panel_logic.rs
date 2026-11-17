// Swift: GraphicsPanelLogic.swift
//! The Graphics panel's rules the panel views share: which layers count as lines, which layers the item rows edit.

use sq_core_model::{Clip, GeneratorRef, GraphicsContent, GraphicsLayer, ShapeKind};
use sq_text::text_generator::TextGenerator;

/// Kind tag for the structure key (a kind change rebuilds the Shape rows).
pub fn kind_tag(l: &GraphicsLayer) -> String {
    match &l.content {
        GraphicsContent::Shape { kind } => format!("{kind:?}").to_lowercase(),
        GraphicsContent::Path { closed, .. } => if *closed { "closedPath" } else { "path" }.to_string(),
        GraphicsContent::Text { .. } => "text".to_string(),
    }
}

/// The selected items Controls > Graphic edits (Corners, Fill, Outline): two or more shape and path items, none of them
/// text. One picked item shows as its own clip, so its Shape section carries these values already.
pub fn item_row_layers(layers: &[GraphicsLayer]) -> Vec<GraphicsLayer> {
    if layers.len() > 1 && layers.iter().all(|l| !l.is_text()) { layers.to_vec() } else { Vec::new() }
}

/// Corners only when every row item is a rectangle.
pub fn all_rectangles(layers: &[GraphicsLayer]) -> bool {
    layers.iter().all(|l| matches!(l.content, GraphicsContent::Shape { kind: ShapeKind::Rectangle }))
}

/// Lines, arrows and open paths have a length and no fill.
pub fn is_line_like(l: &GraphicsLayer) -> bool {
    match &l.content {
        GraphicsContent::Shape { kind } => *kind == ShapeKind::Line || *kind == ShapeKind::Arrow,
        GraphicsContent::Path { closed, .. } => !closed,
        GraphicsContent::Text { .. } => false,
    }
}

/// What the Graphics panel shows when the selection is not a Graphic (Swift `GraphicsEmptyState`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GraphicsEmptyState {
    /// A text or shape clip: its look is edited in Controls.
    EditedInControls,
    /// Anything else (nothing, several clips, footage): a hint and New Graphics Clip.
    NoGraphic,
}

impl GraphicsEmptyState {
    /// `None` for a graphics clip (the panel shows its layers).
    pub fn resolve(clip: Option<&Clip>) -> Option<GraphicsEmptyState> {
        let Some(c) = clip else { return Some(Self::NoGraphic) };
        if c.is_graphics() {
            return None;
        }
        let k = c.generator.as_ref().map(|g| g.kind.as_str());
        Some(if k == Some(TextGenerator::KIND) || k == Some(GeneratorRef::SHAPE) {
            Self::EditedInControls
        } else {
            Self::NoGraphic
        })
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::EditedInControls => "Edited in Controls",
            Self::NoGraphic => "No graphics clip selected",
        }
    }

    pub fn hint(self) -> &'static str {
        match self {
            Self::EditedInControls => {
                "This text or shape clip is edited in Controls. Make it a graphic to add more layers."
            }
            Self::NoGraphic => "Press T and click the picture, or make a new one.",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::GeneratorRef;
    use sq_core_time::{Id, Vec2};

    fn shape(kind: ShapeKind) -> GraphicsLayer {
        GraphicsLayer::new(Id::fixed(1), "s", GraphicsContent::Shape { kind })
    }

    fn path(closed: bool) -> GraphicsLayer {
        GraphicsLayer::new(Id::fixed(2), "p", GraphicsContent::Path { points: vec![Vec2::ZERO], closed })
    }

    #[test]
    fn kind_tags_distinguish_what_rebuilds_the_rows() {
        assert_eq!(kind_tag(&shape(ShapeKind::Rectangle)), "rectangle");
        assert_eq!(kind_tag(&shape(ShapeKind::Arrow)), "arrow");
        assert_eq!(kind_tag(&path(true)), "closedPath");
        assert_eq!(kind_tag(&path(false)), "path");
    }

    #[test]
    fn item_rows_need_two_or_more_non_text_items() {
        let a = shape(ShapeKind::Rectangle);
        assert!(item_row_layers(std::slice::from_ref(&a)).is_empty());
        assert_eq!(item_row_layers(&[a.clone(), path(true)]).len(), 2);
        let text = GraphicsLayer::text(Id::fixed(3), GeneratorRef::graphics_clip(), "t");
        assert!(item_row_layers(&[a, text]).is_empty());
    }

    #[test]
    fn rectangles_and_lines() {
        assert!(all_rectangles(&[shape(ShapeKind::Rectangle), shape(ShapeKind::Rectangle)]));
        assert!(!all_rectangles(&[shape(ShapeKind::Rectangle), shape(ShapeKind::Ellipse)]));
        assert!(is_line_like(&shape(ShapeKind::Line)) && is_line_like(&path(false)));
        assert!(!is_line_like(&shape(ShapeKind::Ellipse)) && !is_line_like(&path(true)));
    }
}
