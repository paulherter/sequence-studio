// Swift: EffectControlsModel+TextAlign.swift
//! Arrange: moves the selected text clip so its laid-out text lines up with a frame edge or center.

use sq_editor_session::{EditorSession, OverlayTarget};
use sq_text::text_align_to_frame::{FrameAlignment, TextAlignToFrame};
use sq_text::text_generator::TextGenerator;
use sq_text::text_layout::TextLayout;

use crate::ec::effect_controls_model::core::EffectControlsModel;

impl EffectControlsModel {
    /// Arrange: moves the selected text clip so its laid-out text lines up with a frame edge or center, one undo step
    /// through Transform (the host's `alignSelectedText`). Nothing happens when the shown clip is not that text clip or
    /// the text would not move.
    pub fn align_text(&mut self, a: FrameAlignment, session: &mut EditorSession) {
        let Some(clip) = session.displayed_selected_clip() else { return };
        let Some(r) = clip.generator.clone() else { return };
        if r.kind != TextGenerator::KIND {
            return;
        }
        let Ok((template, _)) = TextGenerator::decode(&r) else { return };
        let Some(tl) = session.display_timeline() else { return };
        if self.clip.as_ref().map(|c| c.id) != Some(clip.id) {
            return;
        }
        let Some(o) =
            OverlayTarget::make(&clip, session.project(), &tl, session.playhead(), session.active_variant_id())
        else {
            return;
        };
        let layout = TextLayout::layout(
            &template.text,
            &template.style,
            template.box_.as_ref().map(|b| b.width),
            template.box_.as_ref().map(|b| b.height),
        );
        if layout.lines.is_empty() {
            return;
        }
        let base = o.base_transform;
        let mut moved = base;
        let display = o.display_transform();
        moved.position = TextAlignToFrame::position(
            a,
            &layout,
            base.position,
            display.scale,
            display.rotation,
            tl.format.display_width() as f64,
            tl.format.height as f64,
        );
        if moved.position == base.position {
            return;
        }
        session.stop_playback();
        self.begin_gesture();
        self.set_transform(&moved, &base);
        self.end_gesture();
    }
}
