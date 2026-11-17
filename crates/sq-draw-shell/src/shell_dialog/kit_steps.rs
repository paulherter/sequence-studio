//! The kit's welcome body (`dialogs.html` `welcome()`): Pip winking beside the title, then one card of steps, each an icon
//! tile, a title and a sentence with key chips.

use super::{ShellDialog, k};
use crate::shell_mascot::ShellMascot;
use sq_draw::{Canvas, DrawTheme, TextAlign, TextMeasure};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmascot_model::SQMascotAnim;

/// A piece of a step's sentence.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum KeySeg {
    /// Plain words.
    Text(String),
    /// A key chip.
    Key(String),
}

/// One step of the welcome card.
#[derive(Clone, Debug, PartialEq)]
pub struct KitStep {
    /// The tile icon.
    pub icon: SQIcon,
    /// The bold head.
    pub title: String,
    /// The sentence, with key chips.
    pub detail: Vec<KeySeg>,
}

/// A placed word or chip: (text, is a key chip, x from the text column, width).
type Tok = (String, bool, f64, f64);

/// Where the steps landed, relative to the card.
#[derive(Clone, Debug, Default)]
pub(super) struct StepsLayout {
    /// Header text start below `text_top`, so title and sentence are centered against Pip.
    pub text_off: f64,
    /// Height of the header band (Pip 56 less its margins, or the text).
    pub head: f64,
    /// Row tops and heights inside the list card, and each row's wrapped lines.
    rows: Vec<(f64, f64, Vec<Vec<Tok>>)>,
    pub list_h: f64,
    /// Height of the visible list card: `list_h`, less when the window is too short and the list scrolls.
    pub view_h: f64,
}

pub(super) const HEAD_TOP: f64 = 22.0;
pub(super) const TITLE_FONT: f64 = 15.0;
pub(super) const TITLE_LINE: f64 = 20.0;
const PIP: f64 = 56.0;
const ROW_PAD: f64 = 10.0;
/// Vertical row padding: kit rows are 50 pt with one detail line, 66 pt with two.
const ROW_VPAD: f64 = 9.0;
const TILE: f64 = 28.0;
const STEP_TITLE_LINE: f64 = 15.0;
const DETAIL_FONT: f64 = 11.5;
const DETAIL_LINE: f64 = 16.0;
const CHIP_FONT: f64 = 10.5;
const CHIP_H: f64 = 16.0;
const CHIP_PAD: f64 = 5.0;
const CHIP_MARGIN: f64 = 1.0;
/// Pip's text column starts 56 + 14 right of the header's 22 inset, i.e. 72 right of the card pad.
pub(super) const TEXT_X: f64 = 72.0;
/// Space between the header and the list card (6 + 14).
pub(super) const LIST_GAP: f64 = 20.0;

impl ShellDialog {
    /// The wheel over a welcome list that does not fit: moves it by `dy` points (positive = further down), clamped.
    pub(super) fn scroll_steps(&mut self, dy: f64) {
        let travel = (self.steps_layout.list_h - self.steps_layout.view_h).max(0.0);
        self.steps_scroll = (self.steps_scroll + dy).clamp(0.0, travel);
    }

    /// Wraps the steps into the list card of width `width - 2 * PAD`; fills `steps_layout`.
    pub(super) fn layout_steps(&mut self, width: f64, text_h: f64, tm: &TextMeasure) {
        let list_w = width - 2.0 * k::PAD;
        let avail = list_w - 2.0 * ROW_PAD - TILE - 12.0 - 2.0; // tile, gap, row insets
        let space = tm.width(" ", DETAIL_FONT, 0);
        let mut rows = Vec::new();
        let mut y = 0.0;
        for s in &self.kit_steps {
            let mut lines: Vec<Vec<Tok>> = vec![Vec::new()];
            let mut x = 0.0;
            let mut gap = false;
            let put = |text: &str, key: bool, w: f64, gap: bool, lines: &mut Vec<Vec<Tok>>, x: &mut f64| {
                let sp = if gap && *x > 0.0 { space } else { 0.0 };
                if *x > 0.0 && *x + sp + w > avail {
                    lines.push(Vec::new());
                    *x = 0.0;
                }
                let sp = if gap && *x > 0.0 { space } else { 0.0 };
                if let Some(line) = lines.last_mut() {
                    line.push((text.to_string(), key, *x + sp, w));
                }
                *x += sp + w;
            };
            for seg in &s.detail {
                match seg {
                    KeySeg::Key(k) => {
                        gap = true; // always a space before a chip, also after "(" or a full stop
                        let w = tm.width(k, CHIP_FONT, 0).ceil() + 2.0 * CHIP_PAD + 2.0 * CHIP_MARGIN;
                        put(k, true, w, gap, &mut lines, &mut x);
                        gap = true; // and after it, except before a comma or full stop (see below)
                    }
                    KeySeg::Text(t) => {
                        if gap && SQL10n::string(t).starts_with([',', '.', ';', ':']) {
                            gap = false;
                        }
                        for (i, word) in SQL10n::string(t).split(' ').enumerate() {
                            if i > 0 {
                                gap = true;
                            }
                            if word.is_empty() {
                                continue;
                            }
                            let w = tm.width(word, DETAIL_FONT, 0).ceil();
                            put(word, false, w, gap, &mut lines, &mut x);
                            gap = false;
                        }
                    }
                }
            }
            let h = 2.0 * ROW_VPAD + TILE.max(STEP_TITLE_LINE + 1.0 + DETAIL_LINE * lines.len() as f64);
            rows.push((y, h, lines));
            y += h;
        }
        let head = text_h.max(PIP - 12.0);
        self.steps_layout = StepsLayout { text_off: (head - text_h) / 2.0, head, rows, list_h: y, view_h: y };
    }

    /// Draws Pip and the list card; the title and note are drawn by the plain card.
    pub(super) fn draw_steps(&self, c: &mut Canvas, t: &DrawTheme) {
        let l = &self.steps_layout;
        let card = self.card;
        let mid = card.min_y() + HEAD_TOP + l.head / 2.0;
        // the kit's `sq-pip-wink.svg`: the whole figure with the raised arm, not just the head
        ShellMascot::draw(SQMascotAnim::Wink, CGRect::new(card.min_x() + 22.0, mid - PIP / 2.0, PIP, PIP), c);
        let list = CGRect::new(
            card.min_x() + k::PAD,
            card.min_y() + HEAD_TOP + l.head + LIST_GAP,
            card.width - 2.0 * k::PAD,
            l.view_h,
        );
        c.fill_rounded(list, 8.0, t.token(sq_uikit::redesign_tokens::color::GROUP));
        let semibold = c.semibold();
        c.save_gstate();
        c.clip_to(list);
        for (n, (top, h, lines)) in l.rows.iter().enumerate() {
            let ry = list.min_y() + top - self.steps_scroll;
            if n + 1 < l.rows.len() {
                c.fill(CGRect::new(list.min_x(), ry + h - 1.0, list.width, 1.0), t.row_line());
            }
            let tile = CGRect::new(list.min_x() + 12.0, ry + ROW_VPAD, TILE, TILE);
            c.fill_rounded(tile, 6.0, t.raised());
            c.stroke_rounded(tile.inset_by(0.5, 0.5), 6.0, 1.0, t.hair());
            c.draw_icon(
                self.kit_steps[n].icon,
                CGPoint::new(tile.mid_x() - 7.5, tile.mid_y() - 7.5),
                15.0,
                t.label2(),
                None,
            );
            let tx = tile.max_x() + 12.0;
            c.draw_text_in(
                &SQL10n::string(&self.kit_steps[n].title),
                CGRect::new(tx, ry + ROW_VPAD, list.max_x() - tx - 12.0, STEP_TITLE_LINE),
                12.0,
                t.label(),
                TextAlign::Left,
                0.0,
                semibold,
            );
            for (li, line) in lines.iter().enumerate() {
                let ly = ry + ROW_VPAD + STEP_TITLE_LINE + 1.0 + li as f64 * DETAIL_LINE;
                for (text, key, x, w) in line {
                    if *key {
                        let chip = CGRect::new(tx + x + CHIP_MARGIN, ly + 1.0, w - 2.0 * CHIP_MARGIN, CHIP_H);
                        c.fill_rounded(chip, 3.0, t.well());
                        // the glyphs sat 1 px low in the chip against the kit render
                        let text_box = CGRect::new(chip.min_x(), chip.min_y() - 1.0, chip.width, chip.height);
                        c.draw_text_in(text, text_box, CHIP_FONT, t.label(), TextAlign::Center, 0.0, 0);
                    } else {
                        c.draw_text_in(
                            text,
                            CGRect::new(tx + x, ly, w + 5.0, DETAIL_LINE),
                            DETAIL_FONT,
                            t.label3(),
                            TextAlign::Left,
                            0.0,
                            0,
                        );
                    }
                }
            }
        }
        c.restore_gstate();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell_host::ShellHost;

    /// Review: the Welcome card was taller than a 640 x 400 window (clipped at the top, buttons on the bottom edge). Now the
    /// card fits inside the window margins, the footer buttons stay in it and the step list scrolls.
    #[test]
    fn the_welcome_card_fits_a_640_by_400_window_and_its_list_scrolls() {
        let tm = crate::tests::measure();
        let mut d = ShellHost::welcome_dialog();
        let window = CGRect::new(0.0, 0.0, 640.0, 400.0);
        d.layout(window, &tm);
        let full = d.steps_layout.list_h;
        let margin = super::super::m::WINDOW_MARGIN;
        assert!(d.card.min_y() >= margin - 0.5 && d.card.max_y() <= window.height - margin + 0.5, "{:?}", d.card);
        assert!(d.steps_layout.view_h < full && d.steps_layout.view_h >= 80.0, "{} of {full}", d.steps_layout.view_h);
        assert!(!d.button_frames.is_empty());
        for f in d.button_frames.values() {
            assert!(f.min_y() >= d.card.min_y() && f.max_y() <= d.card.max_y() - 4.0, "{f:?} in {:?}", d.card);
        }
        // The wheel moves the list, never past its end, and a tall window shows it whole.
        d.scroll_steps(10_000.0);
        assert_eq!(d.steps_scroll, full - d.steps_layout.view_h);
        d.scroll_steps(-10_000.0);
        assert_eq!(d.steps_scroll, 0.0);
        d.layout(CGRect::new(0.0, 0.0, 1100.0, 900.0), &tm);
        assert_eq!(d.steps_layout.view_h, full);
    }

    /// Audit P8: a key chip had no gap to the word before it ("timeline. [K]") or after it ("[Z] steps"), and brackets hugged it.
    #[test]
    fn a_key_chip_always_has_air_on_both_sides() {
        let tm = crate::tests::measure();
        let mut d = ShellHost::welcome_dialog();
        d.layout(CGRect::new(0.0, 0.0, 1100.0, 744.0), &tm);
        let mut chips = 0;
        for (_, _, lines) in &d.steps_layout.rows {
            for line in lines {
                for (i, (text, key, x, _)) in line.iter().enumerate() {
                    if !*key {
                        continue;
                    }
                    chips += 1;
                    if let Some((_, _, px, pw)) = i.checked_sub(1).and_then(|j| line.get(j)) {
                        assert!(x - (px + pw) >= 2.0, "no gap before the chip {text}");
                    }
                    if let Some((next, false, nx, _)) = line.get(i + 1) {
                        let w = tm.width(text, CHIP_FONT, 0).ceil() + 2.0 * CHIP_PAD + 2.0 * CHIP_MARGIN;
                        let attached = next.starts_with([',', '.', ';', ':']);
                        assert!(attached || nx - (x + w) >= 2.0, "no gap after the chip {text} before {next}");
                    }
                }
            }
        }
        assert!(chips >= 6, "the welcome steps carry key chips");
    }
}
