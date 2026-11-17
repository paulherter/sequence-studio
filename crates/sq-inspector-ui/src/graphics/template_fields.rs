// Swift: TemplateFieldsLogic.swift
//! The template fields a graphics clip would make (`TitleTemplate.capture` + the style slots of
//! `EditorSession.titleTemplateFromSelection`), as display rows for the Graphics panel.

use sq_core_model::{Clip, GraphicsContent};
use sq_text::text_generator::TextGenerator;
use sq_uikit::localization::SQL10n;

#[derive(Clone, Debug, PartialEq)]
pub struct TemplateField {
    pub title: String,
    pub value: String,
}

pub fn fields(clip: &Clip) -> Vec<TemplateField> {
    let Some(doc) = clip.graphics().filter(|_| clip.is_graphics()) else { return Vec::new() };
    let mut out: Vec<TemplateField> = Vec::new();
    let mut first = None;
    for l in &doc.layers {
        let GraphicsContent::Text { generator } = &l.content else { continue };
        let t = TextGenerator::decode(generator).ok().map(|d| d.0);
        if first.is_none() {
            first = t.clone();
        }
        out.push(TemplateField {
            title: SQL10n::format("Text %@", &[&(out.len() + 1).to_string()]),
            value: t.map(|t| t.text).unwrap_or_default(),
        });
    }
    let Some(t) = first else { return out };
    out.push(TemplateField { title: "Color".into(), value: "First text".into() });
    out.push(TemplateField { title: "Font".into(), value: t.style.font_name.clone() });
    out.push(TemplateField { title: "Size".into(), value: (t.style.size.round() as i64).to_string() });
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{GeneratorRef, GraphicsDocument, GraphicsLayer, ShapeKind, TrackKind};
    use sq_core_time::{Id, Time, TimeRange};
    use sq_text::text_style::{FontWeight, RGBAColor, TextStyle};
    use sq_text::text_template::TextTemplate;

    fn text_layer(n: u64, s: &str) -> GraphicsLayer {
        let style = TextStyle::new("Helvetica-Bold", 90.0, FontWeight::Regular, RGBAColor::WHITE);
        let r = TextGenerator::make_ref(&TextTemplate::new(s, s, style), None).unwrap_or_else(|e| panic!("{e}"));
        GraphicsLayer::text(Id::fixed(n), r, s)
    }

    fn clip(layers: Vec<GraphicsLayer>) -> Clip {
        let mut c = Clip::new(
            Id::fixed(1),
            "c",
            Id::fixed(2),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(5, 1)),
            Time::ZERO,
        );
        c.generator = Some(GeneratorRef::graphics_clip());
        c.set_graphics(Some(GraphicsDocument { layers, groups: Vec::new() }));
        c
    }

    #[test]
    fn panel_lists_the_fields() {
        let box_ = GraphicsLayer::new(
            Id::fixed(5),
            "Box",
            sq_core_model::GraphicsContent::Shape { kind: ShapeKind::Rectangle },
        );
        let f = fields(&clip(vec![text_layer(3, "Title"), box_, text_layer(4, "Sub")]));
        assert_eq!(
            f.iter().map(|x| x.title.as_str()).collect::<Vec<_>>(),
            ["Text 1", "Text 2", "Color", "Font", "Size"]
        );
        assert_eq!(f[0].value, "Title");
        assert_eq!(f[3].value, "Helvetica-Bold");
        assert_eq!(f[4].value, "90");
    }

    #[test]
    fn a_clip_without_a_graphic_has_no_fields() {
        let mut c = clip(Vec::new());
        c.generator = None;
        assert!(fields(&c).is_empty());
    }
}
