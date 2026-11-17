// Swift: GraphicsEditor+Monitor.swift (`textEditTarget`, `textLayerHit`)
//! What the Program monitor's text work needs from the Graphics editor: the box the on-canvas field sits on, and the text
//! layer under a point over every Graphic at the playhead.

use sq_core_graphics::graphics_editing::{GraphicsLayerGeometryExt, GraphicsRect, GraphicsTextMeasure};
use sq_core_model::{ClipTransform, GraphicsContent};
use sq_core_time::{Id, KeyframeTrack, Vec2};
use sq_editor_session::{EditorSession, OverlayTarget};
use sq_text::text_generator::TextGenerator;
use sq_uikit::keyframe_graph_geometry::Size;

use crate::graphics::editor::GraphicsEditor;

pub use crate::graphics::editor::TextLayerHit;

impl GraphicsEditor {
    /// The box the on-canvas field sits on for text layer `id` of the selected Graphic (sequence px).
    pub fn text_edit_target(&self, session: &EditorSession, id: Id) -> Option<OverlayTarget> {
        let clip = self.clip(session)?;
        let doc = self.shown_document(session)?;
        let layer = doc.layer(id).filter(|l| matches!(l.content, GraphicsContent::Text { .. }))?;
        let map = self.mapping(session)?;
        // An empty text measures nothing: the field keeps the layer's anchor with a one-line box instead of vanishing.
        let real = self.text_measure(session);
        let measure = move |r: &sq_core_model::GeneratorRef,
                            t: sq_core_model::graphics_item_range::GraphicsTextTime| {
            if let Some(m) = real(r, t).filter(|m| m.width() > 0.0 && m.height() > 0.0) {
                return Some(m);
            }
            let line = TextGenerator::decode(r).map_or(48.0, |d| d.0.style.size);
            Some(GraphicsRect { min_x: -1.0, min_y: -line * 0.6, max_x: 1.0, max_y: line * 0.6 })
        };
        let m: GraphicsTextMeasure = &measure;
        let t = self.local_time(session);
        let r = layer.content_rect(t, Some(m))?;
        let cs = layer.corners(t, Some(m)).filter(|c| c.len() == 4)?;
        if r.width() <= 0.0 || r.height() <= 0.0 {
            return None;
        }
        let s: Vec<Vec2> = cs.iter().map(|c| map.sequence_offset_from_canvas(*c)).collect();
        let centre = Vec2::new((s[0].x + s[2].x) / 2.0, (s[0].y + s[2].y) / 2.0);
        let (e1, e2) = (s[1] - s[0], s[3] - s[0]);
        let transform = ClipTransform {
            position: centre,
            scale: Vec2::new(e1.x.hypot(e1.y) / r.width(), e2.x.hypot(e2.y) / r.height()),
            rotation: e1.y.atan2(e1.x).to_degrees(),
            ..ClipTransform::IDENTITY
        };
        Some(OverlayTarget::new(
            clip.id,
            Size::new(r.width(), r.height()),
            true,
            transform,
            Vec2::new(0.0, 0.0),
            KeyframeTrack::default(),
        ))
    }
}
