// Swift: TimelinePanel+KeyLanes.swift, TimelinePanel+MixRow.swift, TimelinePanel+SilencePreview.swift
//! The small lane overlays that need no panel state beyond what the caller passes in: the key lane of a selected clip
//! (drawn from a source Effect Controls installs), the Mix row in the header column and the Remove Silences preview.
//!
//! Not ported here (they read and write the panel struct, see `PANEL-FIELDS-DT3-4.md`): `TimelinePanel+ItemLanes` (520
//! lines of lane state, drags and drawing) and the press handler `keyLaneDown` of `+KeyLanes`.

use sq_core_model::Clip;
use sq_core_time::{Time, TimeRange};
use sq_draw::{Canvas, Color, DrawTheme, TextAlign};
use sq_timeline_ui::{TimelineGeometry, TrackRow};
use sq_uikit::appearance_palette::PaletteColor;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{spacing, type_size};

/// A palette color as a draw color (`TimelineSkin.color`).
pub(crate) fn palette_color(c: PaletteColor) -> Color {
    Color::new((c.r / 255.0) as f32, (c.g / 255.0) as f32, (c.b / 255.0) as f32, c.a as f32)
}

/// A key glyph of a lane.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct KeyLaneGlyph {
    pub center: CGPoint,
    pub selected: bool,
}

/// The key lane of one selected clip as the Effect Controls side computes it (`KeyLanes` in SQInspectorUI): the strip at
/// the bottom of the clip body and one glyph per key time of the section selected there.
#[derive(Clone, Debug, PartialEq)]
pub struct TimelineKeyLane {
    pub lane: CGRect,
    pub glyphs: Vec<KeyLaneGlyph>,
    pub glyph_size: f64,
}

/// The Mac view's `keyLaneDrawer` / `keyLaneHitTester` hooks: the lane belongs to Effect Controls (its selected section,
/// its key summary, its picked keys), so the Inspector side installs it and the timeline only draws and reports presses.
pub trait TimelineKeyLaneSource {
    /// The lane of `clip` drawn at `clip_rect` (`None` = none: no section, not selected, a low row, no keys).
    fn key_lane(
        &self,
        clip: &Clip,
        clip_rect: CGRect,
        visible: CGRect,
        selected: bool,
        geometry: &TimelineGeometry,
    ) -> Option<TimelineKeyLane>;
    /// Timeline time of the key glyph under `p` on the lane of a selected `clip` (`None` = none).
    fn key_lane_hit(&self, clip: &Clip, clip_rect: CGRect, p: CGPoint, geometry: &TimelineGeometry) -> Option<Time>;
}

/// Where and for which clip a key lane is drawn.
pub struct KeyLaneDraw<'a> {
    pub geometry: &'a TimelineGeometry,
    pub clip: &'a Clip,
    pub rect: CGRect,
    pub visible: CGRect,
    pub selected: bool,
}

/// `TimelinePanel.drawKeyLane`: the strip under the visible part and the diamonds, picked keys in the accent.
pub fn draw_key_lane(cv: &mut Canvas, theme: &DrawTheme, source: &dyn TimelineKeyLaneSource, d: &KeyLaneDraw) {
    let KeyLaneDraw { geometry, clip, rect, visible, selected } = *d;
    if rect.max_x() < visible.min_x() || rect.min_x() > visible.max_x() {
        return;
    }
    let Some(k) = source.key_lane(clip, rect, visible, selected, geometry) else { return };
    if k.glyphs.is_empty() {
        return;
    }
    let strip = CGRect::new(visible.min_x(), k.lane.min_y(), visible.width, k.lane.height);
    let (x0, x1) = (k.lane.min_x().max(strip.min_x()), k.lane.max_x().min(strip.max_x()));
    let (y0, y1) = (k.lane.min_y().max(strip.min_y()), k.lane.max_y().min(strip.max_y()));
    if x1 <= x0 || y1 <= y0 {
        return;
    }
    cv.fill(CGRect::new(x0, y0, x1 - x0, y1 - y0), theme.lane().with_alpha(theme.lane().a * 0.55));
    let h = k.glyph_size / 2.0;
    for g in &k.glyphs {
        let p = g.center;
        let diamond = [
            CGPoint { x: p.x, y: p.y - h },
            CGPoint { x: p.x + h, y: p.y },
            CGPoint { x: p.x, y: p.y + h },
            CGPoint { x: p.x - h, y: p.y },
        ];
        cv.fill_polygon(&diamond, if g.selected { theme.accent() } else { palette_color(theme.palette.keyframe) });
    }
}

/// The header column's Mix row (AppKit `TimelineView.drawMixHeader`): "Mix" with "0.0 dB" on the right, right after the
/// last track row. Like the AppKit row it has no model behind it yet (the master gain reads 0.0 dB).
pub struct MixRow;

impl MixRow {
    pub const HEIGHT: f64 = 22.0;
    pub const LEVEL_TEXT: &'static str = "0.0 dB";

    /// The row in panel points, `None` while it would leave the track area (under the ruler or into the zoom bar).
    pub fn rect(rows: &[TrackRow], caption_height: f64, track_area_height: f64) -> Option<CGRect> {
        let top = rows.last().map_or(TimelineGeometry::RULER_HEIGHT + caption_height, TrackRow::bottom);
        let r = CGRect::new(TimelineGeometry::TOOL_COLUMN_WIDTH, top, TimelineGeometry::HEADER_WIDTH, Self::HEIGHT);
        (r.min_y() >= TimelineGeometry::RULER_HEIGHT && r.max_y() <= track_area_height).then_some(r)
    }

    /// Design v9 `.th` without a chip: panel fill, 1 pt row line, separator, name, level in caption size. `chip` is the
    /// header chip rect of a row this tall (it only places the name), `button_gap` the header's gap.
    pub fn draw(cv: &mut Canvas, theme: &DrawTheme, r: CGRect, chip: CGRect, button_gap: f64) {
        cv.fill(r, theme.panel());
        cv.fill(CGRect::new(r.min_x(), r.max_y() - 1.0, r.width, 1.0), theme.track_row_line());
        cv.fill(CGRect::new(r.max_x() - 1.0, r.min_y(), 1.0, r.height), theme.separator());
        let level = CGRect::new(r.min_x(), r.min_y(), r.width - 1.0, r.height);
        let sm = f64::from(spacing::SM);
        let level_w = cv.draw_text_in(
            Self::LEVEL_TEXT,
            level,
            f64::from(type_size::CAPTION),
            theme.label3(),
            TextAlign::Right,
            sm,
            0,
        );
        let name_x = chip.max_x() + button_gap;
        let name_w = r.max_x() - sm - level_w - button_gap - name_x;
        if name_w <= 12.0 {
            return;
        }
        cv.draw_text(
            "Mix",
            CGPoint { x: name_x, y: (r.min_y() + (r.height - 14.0) / 2.0).round() },
            f64::from(type_size::BODY),
            theme.label2(),
            name_w,
            0,
        );
    }
}

/// Remove Silences preview (the Mac TimelineView+SilencePreview): every range the open dialog would cut is shaded red
/// across all lanes, with a solid edge at both ends, so the cuts can be judged against the waveforms before anything changes.
pub struct SilencePreview;

impl SilencePreview {
    /// `Theme.TimelineSkin.silenceFill` / `silenceEdge`.
    pub const FILL_ALPHA: f32 = 0.28;
    pub const EDGE_ALPHA: f32 = 0.9;

    /// `ranges` must be sorted by start (the dialog lists them in time order); `clip` is the visible lane area.
    pub fn draw(cv: &mut Canvas, theme: &DrawTheme, geometry: &TimelineGeometry, ranges: &[TimeRange], clip: CGRect) {
        if ranges.is_empty() {
            return;
        }
        let red = palette_color(theme.palette.red);
        let (fill, edge) = (red.with_alpha(Self::FILL_ALPHA), red.with_alpha(Self::EDGE_ALPHA));
        for r in ranges {
            let (x0, x1) = (geometry.x(r.start), geometry.x(r.end()));
            if x1 < clip.min_x() {
                continue;
            }
            if x0 > clip.max_x() {
                break;
            }
            cv.fill(CGRect::new(x0, clip.min_y(), (x1 - x0).max(1.0), clip.height), fill);
            cv.fill(CGRect::new(x0, clip.min_y(), 1.0, clip.height), edge);
            cv.fill(CGRect::new((x1 - 1.0).max(x0), clip.min_y(), 1.0, clip.height), edge);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::TrackKind;
    use sq_core_time::Id;
    use std::cell::Cell;

    const FD: Time = Time::new(1, 24);

    fn geometry() -> TimelineGeometry {
        TimelineGeometry::with_points_per_frame(FD, 4.0)
    }

    fn row(y: f64, h: f64, lanes: f64) -> TrackRow {
        TrackRow {
            track: Id::from_u128(1),
            kind: TrackKind::Video,
            label: "V1".to_string(),
            y,
            height: h,
            lane_space: lanes,
        }
    }

    fn clip() -> Clip {
        Clip::new(
            Id::from_u128(5),
            "c",
            Id::from_u128(6),
            TrackKind::Video,
            TimeRange::new(Time::ZERO, FD * 10),
            Time::ZERO,
        )
    }

    struct Lane(Option<TimelineKeyLane>, Cell<u32>);

    impl TimelineKeyLaneSource for Lane {
        fn key_lane(&self, _: &Clip, _: CGRect, _: CGRect, _: bool, _: &TimelineGeometry) -> Option<TimelineKeyLane> {
            self.1.set(self.1.get() + 1);
            self.0.clone()
        }
        fn key_lane_hit(&self, _: &Clip, _: CGRect, _: CGPoint, _: &TimelineGeometry) -> Option<Time> {
            None
        }
    }

    fn canvas() -> Canvas<'static> {
        Canvas::with_size(800.0, 400.0, None, 1.0)
    }

    #[test]
    fn mix_row_follows_the_last_row_including_its_lane_space_and_hides_when_it_does_not_fit() {
        let rows = vec![row(22.0, 40.0, 0.0), row(62.0, 30.0, 18.0)];
        let r = MixRow::rect(&rows, 0.0, 400.0);
        assert_eq!(
            r,
            Some(CGRect::new(TimelineGeometry::TOOL_COLUMN_WIDTH, 110.0, TimelineGeometry::HEADER_WIDTH, 22.0))
        );
        assert_eq!(MixRow::rect(&rows, 0.0, 120.0), None);
        let none = MixRow::rect(&[], 8.0, 400.0);
        assert_eq!(none.map(|r| r.min_y()), Some(TimelineGeometry::RULER_HEIGHT + 8.0));
    }

    #[test]
    fn mix_row_draws_fills_and_text_only_when_the_name_fits() {
        let mut cv = canvas();
        let r = CGRect::new(0.0, 100.0, 156.0, 22.0);
        MixRow::draw(&mut cv, &DrawTheme::default(), r, CGRect::new(6.0, 101.0, 32.0, 20.0), 4.0);
        // Three fills; no atlas, so no glyph quads.
        assert_eq!(cv.list.quads().len(), 3);
    }

    #[test]
    fn silence_preview_shades_each_visible_range_and_stops_past_the_view() {
        let g = geometry();
        let ranges =
            vec![TimeRange::new(Time::ZERO, FD * 5), TimeRange::new(FD * 20, FD * 5), TimeRange::new(FD * 200, FD * 5)];
        let view = CGRect::new(g.x(FD * 10), 30.0, 100.0, 60.0);
        let mut cv = canvas();
        SilencePreview::draw(&mut cv, &DrawTheme::default(), &g, &ranges, view);
        // Range 0 ends before the view, range 1 is in it (fill + 2 edges), range 2 starts past it.
        assert_eq!(cv.list.quads().len(), 3);
        let mut cv = canvas();
        SilencePreview::draw(&mut cv, &DrawTheme::default(), &g, &[], view);
        assert!(cv.list.quads().is_empty());
    }

    #[test]
    fn key_lane_draws_the_strip_and_one_diamond_per_key() {
        let g = geometry();
        let lane = TimelineKeyLane {
            lane: CGRect::new(100.0, 50.0, 200.0, 10.0),
            glyphs: vec![
                KeyLaneGlyph { center: CGPoint { x: 120.0, y: 55.0 }, selected: false },
                KeyLaneGlyph { center: CGPoint { x: 160.0, y: 55.0 }, selected: true },
            ],
            glyph_size: 8.0,
        };
        let src = Lane(Some(lane), Cell::new(0));
        let mut cv = canvas();
        let clip_rect = CGRect::new(100.0, 40.0, 200.0, 30.0);
        {
            let c = clip();
            draw_key_lane(
                &mut cv,
                &DrawTheme::default(),
                &src,
                &KeyLaneDraw {
                    geometry: &g,
                    clip: &c,
                    rect: clip_rect,
                    visible: CGRect::new(0.0, 0.0, 800.0, 400.0),
                    selected: true,
                },
            );
        }
        assert_eq!(src.1.get(), 1);
        assert!(cv.list.quads().len() >= 3);
        // A clip outside the visible part never asks the source.
        let mut cv = canvas();
        {
            let c = clip();
            draw_key_lane(
                &mut cv,
                &DrawTheme::default(),
                &src,
                &KeyLaneDraw {
                    geometry: &g,
                    clip: &c,
                    rect: clip_rect,
                    visible: CGRect::new(500.0, 0.0, 100.0, 400.0),
                    selected: true,
                },
            );
        }
        assert_eq!(src.1.get(), 1);
        assert!(cv.list.quads().is_empty());
        // No glyphs, nothing drawn.
        let empty = Lane(Some(TimelineKeyLane { lane: clip_rect, glyphs: vec![], glyph_size: 8.0 }), Cell::new(0));
        {
            let c = clip();
            draw_key_lane(
                &mut cv,
                &DrawTheme::default(),
                &empty,
                &KeyLaneDraw {
                    geometry: &g,
                    clip: &c,
                    rect: clip_rect,
                    visible: CGRect::new(0.0, 0.0, 800.0, 400.0),
                    selected: false,
                },
            );
        }
        assert!(cv.list.quads().is_empty());
    }
}
