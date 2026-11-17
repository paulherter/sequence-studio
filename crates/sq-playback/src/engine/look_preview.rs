// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: SQPlayback/LookPreview.swift
//! A display-only override of how text is drawn in the Program monitor while the pointer rests on a Look tile. It never
//! touches the timeline, the project or the export: the engine only swaps what it asks the raster provider to draw.

use sq_core_model::anchored_animation::KeyframeTemplate;
use sq_core_model::{GeneratorRef, KaraokeStyle};
use sq_core_time::Id;
use sq_text::caption_presets::CaptionPresetLibrary;
use sq_text::text_style::TextStyle;

/// What the monitor shows instead of the stored text.
#[derive(Clone, Debug, PartialEq)]
pub enum LookPreview {
    /// The text `layer` inside `container` drawn from `to` instead of `from`. A text clip is its own layer
    /// (`container == layer`); a graphic text item is a layer of the graphics clip `container`.
    Text { container: Id, layer: Id, from: GeneratorRef, to: GeneratorRef },
    /// Every caption drawn in `style`; `animation` and `karaoke` replace the captions' own when set.
    Captions { style: Box<TextStyle>, animation: Option<Box<KeyframeTemplate>>, karaoke: Option<Box<KaraokeStyle>> },
}

impl LookPreview {
    /// The ref to draw for `reference` of the text `layer` in `container`.
    pub fn text<'a>(
        preview: Option<&'a LookPreview>,
        reference: &'a GeneratorRef,
        container: Id,
        layer: Id,
    ) -> &'a GeneratorRef {
        match preview {
            Some(LookPreview::Text { container: c, layer: l, from, to })
                if *c == container && *l == layer && from == reference =>
            {
                to
            }
            _ => reference,
        }
    }

    /// `base` with every style (and animation) id resolving to the preview's.
    pub fn caption_library(&self, base: &CaptionPresetLibrary) -> Option<CaptionPresetLibrary> {
        let LookPreview::Captions { style, animation, .. } = self else { return None };
        let mut lib = base.clone();
        lib.styles = base.styles.keys().map(|k| (k.clone(), (**style).clone())).collect();
        if let Some(a) = animation {
            lib.animations = base.animations.keys().map(|k| (k.clone(), (**a).clone())).collect();
        }
        Some(lib)
    }

    /// The highlight of a caption track: the preview's when it has one.
    pub fn karaoke<'a>(&'a self, own: Option<&'a KaraokeStyle>) -> Option<&'a KaraokeStyle> {
        match self {
            LookPreview::Captions { karaoke: Some(k), .. } => Some(&**k),
            _ => own,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gen_ref(payload: &str) -> GeneratorRef {
        GeneratorRef { kind: "text".to_string(), payload: payload.as_bytes().to_vec(), payload_version: 1 }
    }

    #[test]
    fn text_swaps_only_the_matching_layer() {
        let (c, l) = (Id::fixed(1), Id::fixed(2));
        let p = LookPreview::Text { container: c, layer: l, from: gen_ref("a"), to: gen_ref("b") };
        assert_eq!(LookPreview::text(Some(&p), &gen_ref("a"), c, l), &gen_ref("b"));
        assert_eq!(LookPreview::text(Some(&p), &gen_ref("a"), c, Id::fixed(3)), &gen_ref("a"));
        assert_eq!(LookPreview::text(Some(&p), &gen_ref("x"), c, l), &gen_ref("x"));
        assert_eq!(LookPreview::text(None, &gen_ref("a"), c, l), &gen_ref("a"));
    }

    #[test]
    fn caption_library_points_every_id_at_the_preview_style() {
        let base = CaptionPresetLibrary::built_in();
        let mut style = base.style(None);
        style.size += 11.0;
        let p = LookPreview::Captions { style: Box::new(style.clone()), animation: None, karaoke: None };
        let lib = p.caption_library(&base).unwrap_or_else(|| base.clone());
        assert!(lib.styles.values().all(|s| *s == style));
        assert_eq!(lib.animations, base.animations);
        assert_eq!(p.karaoke(None), None);
    }
}
