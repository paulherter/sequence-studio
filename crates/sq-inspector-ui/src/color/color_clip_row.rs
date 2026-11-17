// Swift: Color/ColorClipRow.swift
//! The grade state of a clip as the Sources tiles say it ("Simple", "Pro", "No grade", ...).

use super::color_page_models::ColorViewerHeaderContent;
use sq_core_color::ClipGradeExt;
use sq_core_model::{ColorGraph, Timeline};
use sq_core_time::Id;

#[derive(Clone, Debug, PartialEq)]
pub struct ColorClipRow {
    pub id: Id,
    pub media: Id,
    pub name: String,
    /// "Simple", "Pro", "Simple on, Pro kept", "Pro on, Simple kept", "No grade".
    pub grade: String,
    /// 1-based place in the sequence.
    pub index: i64,
}

impl ColorClipRow {
    /// What the second line says about a clip's two grades: which one is active and whether the other is kept.
    pub fn grade_text(has_simple: bool, graph: Option<&ColorGraph>) -> &'static str {
        let Some(graph) = graph else { return if has_simple { "Simple" } else { "No grade" } };
        if graph.is_active {
            return if has_simple { "Pro on, Simple kept" } else { "Pro" };
        }
        if has_simple { "Simple on, Pro kept" } else { "Pro kept, off" }
    }

    /// The picture clips of `timeline` in timeline order.
    pub fn rows(timeline: Option<&Timeline>) -> Vec<ColorClipRow> {
        let Some(timeline) = timeline else { return Vec::new() };
        ColorViewerHeaderContent::clips(timeline)
            .into_iter()
            .enumerate()
            .map(|(i, c)| ColorClipRow {
                id: c.id,
                media: c.media,
                name: c.name.clone(),
                grade: Self::grade_text(!c.color_grade_effects().is_empty(), c.color_graph().as_ref()).to_string(),
                index: i as i64 + 1,
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grade_text_names_the_active_grade_and_the_kept_one() {
        assert_eq!(ColorClipRow::grade_text(false, None), "No grade");
        assert_eq!(ColorClipRow::grade_text(true, None), "Simple");
        let mut g = ColorGraph::new(Vec::new(), None, None, Id::from_u128(1));
        assert_eq!(ColorClipRow::grade_text(false, Some(&g)), "Pro kept, off");
        assert_eq!(ColorClipRow::grade_text(true, Some(&g)), "Simple on, Pro kept");
        g.is_active = true;
        assert_eq!(ColorClipRow::grade_text(false, Some(&g)), "Pro");
        assert_eq!(ColorClipRow::grade_text(true, Some(&g)), "Pro on, Simple kept");
    }

    #[test]
    fn no_timeline_no_rows() {
        assert!(ColorClipRow::rows(None).is_empty());
    }
}
