//! Magic Mask in three plain steps: click what you want to cut out, follow it through the clip, check the result.
//! The pure part (which step is current, which are done, the strip's cells, the row's geometry) and its drawing. The
//! buttons are ordinary row widgets placed by `Geometry`. The mask carries the experimental mark and its notice.

use sq_draw::experimental::{self, ExperimentalMark, Feature};
use sq_draw::{Canvas, DrawTheme, TextAlign};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::redesign_tokens::color as tk;

/// Lines of the notice under an effect's header, the height of its row and the box inside it.
pub fn notice_row_height() -> f64 {
    experimental::notice_height(NOTICE_LINES) + 8.0
}

/// The notice box of an effect row of `width` and its X (same geometry as the one over the Magic steps).
pub fn notice_box(width: f64) -> (CGRect, CGRect) {
    let r = CGRect::new(PAD, 4.0, (width - 2.0 * PAD).max(0.0), experimental::notice_height(NOTICE_LINES));
    let x = sq_draw::close_x::hit_rect(experimental::notice_close(r));
    (r, x)
}

/// The strip's cell count.
pub const CELLS: usize = 60;
/// Lines the notice reserves (the layout does not know the width).
const NOTICE_LINES: usize = 3;
const PAD: f64 = 14.0;
const BADGE: f64 = 20.0;
const TEXT_X: f64 = PAD + BADGE + 12.0;
const STEP_HEIGHTS: [f64; 3] = [70.0, 116.0, 74.0];
const LINE: f64 = 16.0;
const FONT: f64 = 11.0;

/// The three steps.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    Pick,
    Follow,
    Check,
}

/// One cell of the result strip.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cell {
    /// Tracked and holding well (green).
    Holds,
    /// Tracked but might slip here (orange).
    Slip,
    /// Not followed yet (faint).
    Untracked,
}

/// What the steps show; fractions are of the clip (0..1).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Progress {
    /// Something is picked in the picture.
    pub picked: bool,
    /// Following is running.
    pub tracking: bool,
    /// The stretch that is followed.
    pub tracked: Option<(f64, f64)>,
    /// Stretches that might slip.
    pub weak: Vec<(f64, f64)>,
}

impl Progress {
    /// The step the user is on.
    pub fn current(&self) -> Step {
        if !self.picked {
            Step::Pick
        } else if self.tracking || self.tracked.is_none() {
            Step::Follow
        } else {
            Step::Check
        }
    }

    /// A finished step shows a check mark; the last one is the result and never "done".
    pub fn is_done(&self, s: Step) -> bool {
        match s {
            Step::Pick => self.picked,
            Step::Follow => self.tracked.is_some() && !self.tracking,
            Step::Check => false,
        }
    }

    /// The strip: weak stretches orange, followed stretches green, the rest faint.
    pub fn cells(&self) -> Vec<Cell> {
        let inside = |r: &(f64, f64), m: f64| m >= r.0 && m <= r.1;
        (0..CELLS)
            .map(|i| {
                let m = (i as f64 + 0.5) / CELLS as f64;
                if self.weak.iter().any(|r| inside(r, m)) {
                    Cell::Slip
                } else if self.tracked.as_ref().is_some_and(|r| inside(r, m)) {
                    Cell::Holds
                } else {
                    Cell::Untracked
                }
            })
            .collect()
    }
}

/// The row's height; the notice adds its box while it is open.
pub fn height(notice_open: bool) -> f64 {
    STEP_HEIGHTS.iter().sum::<f64>() + if notice_open { notice_block_height() } else { 0.0 }
}

fn notice_block_height() -> f64 {
    experimental::notice_height(NOTICE_LINES) + 8.0
}

/// Where everything sits, relative to the row's top left.
#[derive(Clone, Debug, PartialEq)]
pub struct Geometry {
    pub notice: Option<CGRect>,
    pub close: Option<CGRect>,
    pub badges: [CGRect; 3],
    pub titles: [CGRect; 3],
    pub pick_text: CGRect,
    pub follow: CGRect,
    pub back: CGRect,
    pub status: CGRect,
    pub strip: CGRect,
    pub legend: CGRect,
    pub show: CGRect,
}

impl Geometry {
    pub fn new(width: f64, notice_open: bool) -> Geometry {
        let content_w = (width - TEXT_X - PAD).max(0.0);
        let mut y = 0.0;
        let (mut notice, mut close) = (None, None);
        if notice_open {
            let r = CGRect::new(PAD, 8.0, (width - 2.0 * PAD).max(0.0), experimental::notice_height(NOTICE_LINES));
            close = Some(CGRect::new(r.max_x() - 28.0, r.min_y() + 6.0, 24.0, 24.0));
            notice = Some(r);
            y = notice_block_height();
        }
        let tops = [y, y + STEP_HEIGHTS[0], y + STEP_HEIGHTS[0] + STEP_HEIGHTS[1]];
        let badges = tops.map(|t| CGRect::new(PAD, t + 10.0, BADGE, BADGE));
        let titles = tops.map(|t| CGRect::new(TEXT_X, t + 10.0, content_w, LINE));
        let pick_text = CGRect::new(TEXT_X, tops[0] + 10.0 + LINE + 4.0, content_w, 2.0 * LINE);
        let by = tops[1] + 10.0 + LINE + 6.0;
        // The two buttons stack: "From here back to the start" does not fit next to "Follow to the end".
        let follow = CGRect::new(TEXT_X, by, 176.0_f64.min(content_w), 22.0);
        let back = CGRect::new(TEXT_X, by + 28.0, 196.0_f64.min(content_w), 22.0);
        let status = CGRect::new(TEXT_X, back.max_y() + 8.0, content_w, LINE);
        let strip = CGRect::new(TEXT_X, tops[2] + 10.0 + LINE + 6.0, content_w, 8.0);
        let legend = CGRect::new(TEXT_X, strip.max_y() + 8.0, (content_w - 96.0).max(0.0), LINE);
        let show = CGRect::new(TEXT_X + content_w - 96.0, strip.max_y() + 8.0, 96.0, LINE);
        Geometry { notice, close, badges, titles, pick_text, follow, back, status, strip, legend, show }
    }
}

/// What the drawing needs besides the geometry.
#[derive(Clone, Debug, PartialEq)]
pub struct View {
    pub progress: Progress,
    /// The follow state line ("Takes about 20 seconds ..." or the running status); empty = the default hint.
    pub status: String,
}

/// Draws the whole block in a row of `width` x `height` (the buttons are separate widgets).
pub fn draw(c: &mut Canvas, width: f64, view: &View, t: &DrawTheme) {
    let notice_open = experimental::prefs().shows_notice(Feature::MagicMask);
    let g = Geometry::new(width, notice_open);
    if let Some(r) = g.notice {
        // The X is a widget; its glyph is drawn with the box.
        c.experimental_notice(Feature::MagicMask, r, t);
    }
    let bold = c.semibold();
    let green = t.token(tk::GREEN);
    let warn = t.token(tk::WARNING);
    let steps = [Step::Pick, Step::Follow, Step::Check];
    let titles = ["Click what you want to cut out", "Follow it through the clip", "Check the result"];
    for (i, s) in steps.iter().enumerate() {
        let done = view.progress.is_done(*s);
        let now = view.progress.current() == *s;
        let b = g.badges[i];
        c.fill_ellipse(b, if done { green } else { t.fill() });
        let label = if done { "\u{2713}".to_string() } else { (i + 1).to_string() };
        c.draw_text_in(
            &label,
            b,
            FONT,
            if done {
                t.panel()
            } else if now {
                t.label()
            } else {
                t.label3()
            },
            TextAlign::Center,
            0.0,
            bold,
        );
        c.draw_text_in(
            titles[i],
            g.titles[i],
            12.0,
            if now || done { t.label() } else { t.label2() },
            TextAlign::Left,
            0.0,
            bold,
        );
        if i == 0 {
            // The mark sits behind the first title: the whole feature is experimental.
            let w = c.size_of(titles[0], 12.0, bold).width.ceil();
            let origin = CGPoint::new(g.titles[0].min_x() + w + 6.0, g.titles[0].min_y() + 2.0);
            if origin.x + experimental::ICON_SIZE < g.titles[0].max_x() {
                c.experimental_mark(Feature::MagicMask, origin, ExperimentalMark::Icon, t);
            }
        }
    }
    c.draw_wrapped(
        "In the picture. A blue overlay shows what is picked. Option-click takes something away again.",
        g.pick_text,
        FONT,
        LINE,
        t.label3(),
    );
    let status =
        if view.status.is_empty() { "Starts at the playhead. You can keep working." } else { view.status.as_str() };
    c.draw_text_in(status, g.status, FONT, t.label3(), TextAlign::Left, 0.0, 0);
    // The strip.
    let cells = view.progress.cells();
    let cw = g.strip.width / CELLS as f64;
    for (i, cell) in cells.iter().enumerate() {
        let (col, a) = match cell {
            Cell::Holds => (green, 0.75),
            Cell::Slip => (warn, 0.95),
            Cell::Untracked => (green, 0.15),
        };
        c.fill(
            CGRect::new(g.strip.min_x() + i as f64 * cw, g.strip.min_y(), (cw - 1.0).max(0.5), g.strip.height),
            col.with_alpha(a),
        );
    }
    c.fill_ellipse(CGRect::new(g.legend.min_x(), g.legend.min_y() + 4.0, 8.0, 8.0), green);
    c.draw_text_in(
        "Holds well",
        CGRect::new(g.legend.min_x() + 12.0, g.legend.min_y(), 64.0, LINE),
        FONT,
        t.label3(),
        TextAlign::Left,
        0.0,
        0,
    );
    c.fill_ellipse(CGRect::new(g.legend.min_x() + 82.0, g.legend.min_y() + 4.0, 8.0, 8.0), warn);
    c.draw_text_in(
        "Might slip here",
        CGRect::new(g.legend.min_x() + 94.0, g.legend.min_y(), (g.legend.width - 94.0).max(0.0), LINE),
        FONT,
        t.label3(),
        TextAlign::Left,
        0.0,
        0,
    );
    if !view.progress.weak.is_empty() && !view.progress.tracking {
        c.draw_text_in("Show me where \u{2192}", g.show, FONT, t.accent(), TextAlign::Right, 0.0, 0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn picked() -> Progress {
        Progress { picked: true, ..Progress::default() }
    }

    #[test]
    fn the_current_step_follows_the_work() {
        assert_eq!(Progress::default().current(), Step::Pick);
        assert_eq!(picked().current(), Step::Follow);
        let running = Progress { tracking: true, tracked: Some((0.0, 0.2)), ..picked() };
        assert_eq!(running.current(), Step::Follow);
        let done = Progress { tracked: Some((0.0, 1.0)), ..picked() };
        assert_eq!(done.current(), Step::Check);
    }

    #[test]
    fn finished_steps_get_a_check_but_the_result_never() {
        let p = Progress { tracked: Some((0.0, 1.0)), ..picked() };
        assert!(p.is_done(Step::Pick) && p.is_done(Step::Follow) && !p.is_done(Step::Check));
        assert!(!Progress { tracking: true, ..p.clone() }.is_done(Step::Follow));
    }

    #[test]
    fn the_strip_is_green_where_it_holds_orange_where_it_might_slip_faint_beyond() {
        let p = Progress { tracked: Some((0.0, 0.8)), weak: vec![(0.55, 0.65)], ..picked() };
        let cells = p.cells();
        assert_eq!(cells.len(), CELLS);
        assert_eq!(cells[0], Cell::Holds);
        assert_eq!(cells[34], Cell::Slip);
        assert_eq!(cells[40], Cell::Holds);
        assert_eq!(cells[55], Cell::Untracked);
        assert_eq!(cells.iter().filter(|c| **c == Cell::Slip).count(), 6);
    }

    #[test]
    fn the_notice_adds_its_box_to_the_height_and_closing_takes_it_away() {
        let closed = height(false);
        assert_eq!(closed, 260.0);
        assert_eq!(height(true), closed + experimental::notice_height(3) + 8.0);
        let g = Geometry::new(320.0, true);
        assert!(g.notice.is_some() && g.close.is_some());
        assert!(Geometry::new(320.0, false).notice.is_none());
        assert_eq!(g.badges[0].min_y(), experimental::notice_height(3) + 8.0 + 10.0);
    }

    #[test]
    fn the_steps_stack_without_overlap_and_fit_the_row() {
        let g = Geometry::new(320.0, false);
        assert!(g.badges[0].max_y() < g.badges[1].min_y() && g.badges[1].max_y() < g.badges[2].min_y());
        assert!(g.show.max_y() <= height(false));
        assert!(g.back.max_x() <= 320.0 - PAD);
        assert!(g.follow.max_y() < g.back.min_y() && g.back.max_y() < g.status.min_y());
    }
}
