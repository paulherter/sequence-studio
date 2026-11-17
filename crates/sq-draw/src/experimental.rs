//! The orange flask that marks a feature nobody has tested widely yet (design rule "Experimental mark"): a flask icon
//! alone (9 to 11 px, next to a name) or the pill "flask Experimental" (16 high, 10 pt semibold, radius 3).
//! One helper for every panel; the color is the `exp_text` token, the fill and the edge are its alpha steps.
//! The dismissable notice box sits at the top of a feature's area; once closed it never comes back (stored).
//! `Feature` is the one list of experimental features; add a feature there and its marks appear.

use crate::{Canvas, DrawTheme, TextAlign};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::redesign_tokens::color as tk;
use sq_uikit::sqicon::SQIcon;
use std::collections::BTreeSet;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

/// The pill's word.
pub const LABEL: &str = "Experimental";
/// The pill's height.
pub const PILL_HEIGHT: f64 = 16.0;
/// The icon alone next to a name.
pub const ICON_SIZE: f64 = 11.0;
const PILL_ICON: f64 = 11.0;
const PILL_PAD_LEFT: f64 = 5.0;
const PILL_PAD_RIGHT: f64 = 6.0;
const PILL_GAP: f64 = 4.0;
const PILL_RADIUS: f64 = 3.0;
const PILL_FONT: f64 = 10.0;

/// The one list of experimental features (Gyroflow is not on it).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Feature {
    ProGrading,
    MagicMask,
    Stabilize,
}

impl Feature {
    /// Every experimental feature.
    pub const ALL: [Feature; 3] = [Feature::ProGrading, Feature::MagicMask, Feature::Stabilize];

    /// The name used in tooltips and the notice.
    pub fn name(self) -> &'static str {
        match self {
            Feature::ProGrading => "Pro grading",
            Feature::MagicMask => "Magic Mask",
            Feature::Stabilize => "Stabilize",
        }
    }

    /// The stored key of the closed notice.
    pub fn key(self) -> &'static str {
        match self {
            Feature::ProGrading => "proGrading",
            Feature::MagicMask => "magicMask",
            Feature::Stabilize => "stabilize",
        }
    }

    /// What the notice says after "Experimental."
    pub fn notice(self) -> &'static str {
        match self {
            Feature::ProGrading => {
                "Pro grading is still being built and can change between versions. Your Simple grade stays as it is."
            }
            Feature::MagicMask => {
                "Magic Mask is still being tested. It can slip on fast motion, hair and thin edges. Check the result."
            }
            Feature::Stabilize => {
                "The Standard method is still being tested. Gyroflow uses the camera's motion data and is the reliable choice when it's there."
            }
        }
    }

    /// The feature an effect kind belongs to (the stored kind strings), if it is experimental.
    pub fn for_effect_kind(kind: &str) -> Option<Feature> {
        match kind {
            "colorGraph" => Some(Feature::ProGrading),
            "stabilize" => Some(Feature::Stabilize),
            _ => None,
        }
    }

    /// The tooltip of a marked element.
    pub fn tooltip(self) -> String {
        tooltip(self.name())
    }
}

/// UserDefaults key of the "Show experimental labels" switch (absent = on).
pub const LABELS_KEY: &str = "sq.experimental.labels";
/// UserDefaults key of the closed notices.
pub const CLOSED_KEY: &str = "sq.experimental.closedNotices";

/// What the user chose: the switch and the notices already closed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Prefs {
    pub labels: bool,
    closed: BTreeSet<Feature>,
}

impl Default for Prefs {
    fn default() -> Prefs {
        Prefs { labels: true, closed: BTreeSet::new() }
    }
}

impl Prefs {
    /// The stored choice.
    pub fn load(d: &dyn sq_uikit::appearance_palette::UiDefaults) -> Prefs {
        let closed = d
            .string_array(CLOSED_KEY)
            .unwrap_or_default()
            .iter()
            .filter_map(|k| Feature::ALL.into_iter().find(|f| f.key() == k))
            .collect();
        Prefs { labels: d.string(LABELS_KEY).is_none_or(|s| s != "0"), closed }
    }

    /// Writes what differs from the factory state.
    pub fn save(&self, d: &mut dyn sq_uikit::appearance_palette::UiDefaults) {
        d.set_string(LABELS_KEY, if self.labels { "1" } else { "0" });
        let keys: Vec<String> = self.closed.iter().map(|f| f.key().to_string()).collect();
        d.set_string_array(CLOSED_KEY, &keys);
    }

    /// The icon and the pill show only while the switch is on.
    pub fn shows_mark(&self) -> bool {
        self.labels
    }

    /// The notice shows until its X was pressed once, whatever the switch says.
    pub fn shows_notice(&self, f: Feature) -> bool {
        !self.closed.contains(&f)
    }

    /// The X: this notice never comes back.
    pub fn close_notice(&mut self, f: Feature) {
        self.closed.insert(f);
    }
}

static PREFS: Mutex<Prefs> = Mutex::new(Prefs { labels: true, closed: BTreeSet::new() });

/// The live choice every draw site reads.
pub fn prefs() -> Prefs {
    PREFS.lock().map(|p| p.clone()).unwrap_or_default()
}

/// Replaces the live choice (at start and when Settings change).
pub fn set_prefs(p: Prefs) {
    if let Ok(mut g) = PREFS.lock() {
        *g = p;
    }
}

static CHANGED: AtomicBool = AtomicBool::new(false);

/// Closes a notice for good; the app's store writes it on its next pass (`take_changed`).
pub fn close_notice(f: Feature) {
    let mut p = prefs();
    p.close_notice(f);
    set_prefs(p);
    CHANGED.store(true, Ordering::Relaxed);
}

/// True once after a notice was closed: the caller then saves `prefs()`.
pub fn take_changed() -> bool {
    CHANGED.swap(false, Ordering::Relaxed)
}

/// The bold amber first word of every notice.
pub const LEAD: &str = "Experimental.";

/// The notice box: radius 4, padding 10 / 12, 11 pt text, an X on the right.
pub const NOTICE_PAD_X: f64 = 12.0;
const NOTICE_PAD_Y: f64 = 10.0;
const NOTICE_FONT: f64 = 11.0;
const NOTICE_LINE: f64 = 16.0;
/// Kit `ExperimentalMark/Notice`: padding 10 top / 30 right / 12 left, a 14 pt flask and a 10 pt gap before the text.
const NOTICE_PAD_RIGHT: f64 = 30.0;
const NOTICE_FLASK: f64 = 14.0;
const NOTICE_GAP: f64 = 10.0;
/// The X sits 4 pt from the box's top and right edge.
const NOTICE_CLOSE_INSET: f64 = 4.0;

/// The width the notice's text wraps at in a box `box_width` wide.
pub fn notice_text_width(box_width: f64) -> f64 {
    (box_width - NOTICE_PAD_X - NOTICE_FLASK - NOTICE_GAP - NOTICE_PAD_RIGHT).max(0.0)
}

/// The notice's X frame (the kit's 20 pt `Close`) in the box `r`; hit-test `close_x::hit_rect` of it.
pub fn notice_close(r: CGRect) -> CGRect {
    let s = crate::close_x::NOTICE_BUTTON;
    CGRect::new(r.max_x() - NOTICE_CLOSE_INSET - s, r.min_y() + NOTICE_CLOSE_INSET, s, s)
}

/// The notice's height at `width` for `lines` text lines.
pub fn notice_height(lines: usize) -> f64 {
    2.0 * NOTICE_PAD_Y + lines.max(1) as f64 * NOTICE_LINE
}

/// Which form of the mark to draw.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExperimentalMark {
    /// The flask alone.
    Icon,
    /// The flask and the word, on a tinted pill.
    Pill,
}

/// The mark's size for a label that measures `label_width` points.
pub fn mark_size(mark: ExperimentalMark, label_width: f64) -> (f64, f64) {
    match mark {
        ExperimentalMark::Icon => (ICON_SIZE, ICON_SIZE),
        ExperimentalMark::Pill => {
            (PILL_PAD_LEFT + PILL_ICON + PILL_GAP + label_width.ceil() + PILL_PAD_RIGHT, PILL_HEIGHT)
        }
    }
}

/// Every marked element says so in its tooltip: "Pro grading · experimental".
pub fn tooltip(name: &str) -> String {
    format!("{name} \u{b7} experimental")
}

impl Canvas<'_> {
    /// The mark of `feature`, or nothing while "Show experimental labels" is off.
    pub fn experimental_mark(
        &mut self,
        f: Feature,
        origin: CGPoint,
        mark: ExperimentalMark,
        t: &DrawTheme,
    ) -> Option<CGRect> {
        let _ = f;
        prefs().shows_mark().then(|| self.experimental_badge(origin, mark, t))
    }

    /// The notice box of `feature` in `r` (its height is `notice_height`); returns the X's rect, or nothing when closed.
    pub fn experimental_notice(&mut self, f: Feature, r: CGRect, t: &DrawTheme) -> Option<CGRect> {
        if !prefs().shows_notice(f) {
            return None;
        }
        let ink = t.token(tk::EXP_TEXT);
        self.fill_rounded(r, 4.0, ink.with_alpha(0.10));
        self.stroke_rounded(r.inset_by(0.5, 0.5), 4.0, 1.0, ink.with_alpha(0.22));
        let x = notice_close(r);
        let state = crate::close_x::CloseXState::default();
        self.close_x_sized(x, crate::close_x::NOTICE_BUTTON, crate::close_x::NOTICE_GLYPH, state, t);
        self.draw_icon(
            SQIcon::Flask,
            CGPoint::new(r.min_x() + NOTICE_PAD_X, r.min_y() + NOTICE_PAD_Y + 1.0),
            NOTICE_FLASK,
            ink,
            None,
        );
        let tx = r.min_x() + NOTICE_PAD_X + NOTICE_FLASK + NOTICE_GAP;
        let rest = f.notice();
        let lines = self.wrap(&format!("{LEAD} {rest}"), notice_text_width(r.width), NOTICE_FONT);
        let room = ((r.height - 2.0 * NOTICE_PAD_Y) / NOTICE_LINE).floor().max(1.0) as usize;
        for (i, line) in lines.iter().take(room).enumerate() {
            let y = r.min_y() + NOTICE_PAD_Y + i as f64 * NOTICE_LINE;
            match (i, line.strip_prefix(LEAD)) {
                // The bold amber lead, then the muted rest of the first line.
                (0, Some(tail)) => {
                    let semibold = self.semibold();
                    let w = self.draw_text(LEAD, CGPoint::new(tx, y), NOTICE_FONT, ink, f64::INFINITY, semibold);
                    self.draw_text(
                        tail.trim_start(),
                        CGPoint::new(tx + w + 3.0, y),
                        NOTICE_FONT,
                        t.label2(),
                        f64::INFINITY,
                        0,
                    );
                }
                _ => {
                    self.draw_text(line, CGPoint::new(tx, y), NOTICE_FONT, t.label2(), f64::INFINITY, 0);
                }
            }
        }
        Some(x)
    }

    /// Draws the experimental mark with its top left at `origin`; returns the rect it took.
    pub fn experimental_badge(&mut self, origin: CGPoint, mark: ExperimentalMark, t: &DrawTheme) -> CGRect {
        let ink = t.token(tk::EXP_TEXT);
        match mark {
            ExperimentalMark::Icon => {
                self.draw_icon(SQIcon::Flask, origin, ICON_SIZE, ink, None);
                CGRect::new(origin.x, origin.y, ICON_SIZE, ICON_SIZE)
            }
            ExperimentalMark::Pill => {
                let face = self.semibold();
                let label_w = self.size_of(LABEL, PILL_FONT, face).width;
                let (w, h) = mark_size(mark, label_w);
                let r = CGRect::new(origin.x, origin.y, w, h);
                self.fill_rounded(r, PILL_RADIUS, ink.with_alpha(0.14));
                self.stroke_rounded(r.inset_by(0.5, 0.5), PILL_RADIUS, 1.0, ink.with_alpha(0.22));
                let icon_y = r.mid_y() - PILL_ICON / 2.0;
                self.draw_icon(SQIcon::Flask, CGPoint::new(r.min_x() + PILL_PAD_LEFT, icon_y), PILL_ICON, ink, None);
                let tx = r.min_x() + PILL_PAD_LEFT + PILL_ICON + PILL_GAP;
                let tr = CGRect::new(tx, r.min_y(), label_w.ceil(), h);
                self.draw_text_in(LABEL, tr, PILL_FONT, ink, TextAlign::Left, 0.0, face);
                r
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_notice_text_leaves_room_for_the_flask_and_the_x_like_the_kit() {
        // Kit: padding 12 left, flask 14 + gap 10, 30 right.
        assert_eq!(notice_text_width(360.0), 360.0 - 12.0 - 14.0 - 10.0 - 30.0);
        let x = notice_close(CGRect::new(10.0, 50.0, 360.0, 60.0));
        assert_eq!((x.width, x.height, x.min_x(), x.min_y()), (20.0, 20.0, 10.0 + 360.0 - 24.0, 54.0));
    }

    #[test]
    fn the_icon_is_eleven_square() {
        assert_eq!(mark_size(ExperimentalMark::Icon, 60.0), (11.0, 11.0));
    }

    #[test]
    fn the_pill_is_sixteen_high_and_wraps_icon_and_word() {
        let (w, h) = mark_size(ExperimentalMark::Pill, 58.2);
        assert_eq!(h, 16.0);
        assert_eq!(w, 5.0 + 11.0 + 4.0 + 59.0 + 6.0);
    }

    #[derive(Default)]
    struct Mem(std::collections::HashMap<String, String>, std::collections::HashMap<String, Vec<String>>);
    impl sq_uikit::appearance_palette::UiDefaults for Mem {
        fn string(&self, k: &str) -> Option<String> {
            self.0.get(k).cloned()
        }
        fn integer(&self, _: &str) -> Option<i64> {
            None
        }
        fn string_array(&self, k: &str) -> Option<Vec<String>> {
            self.1.get(k).cloned()
        }
        fn data(&self, _: &str) -> Option<Vec<u8>> {
            None
        }
        fn set_string(&mut self, k: &str, v: &str) {
            self.0.insert(k.into(), v.into());
        }
        fn set_integer(&mut self, _: &str, _: i64) {}
        fn set_string_array(&mut self, k: &str, v: &[String]) {
            self.1.insert(k.into(), v.to_vec());
        }
        fn set_data(&mut self, _: &str, _: &[u8]) {}
        fn remove(&mut self, k: &str) {
            self.0.remove(k);
        }
    }

    #[test]
    fn the_list_has_the_three_features_and_no_gyroflow() {
        let names: Vec<_> = Feature::ALL.iter().map(|f| f.name()).collect();
        assert_eq!(names, ["Pro grading", "Magic Mask", "Stabilize"]);
        assert_eq!(Feature::MagicMask.tooltip(), "Magic Mask \u{b7} experimental");
    }

    #[test]
    fn effect_kinds_map_to_features() {
        assert_eq!(Feature::for_effect_kind("stabilize"), Some(Feature::Stabilize));
        assert_eq!(Feature::for_effect_kind("colorGraph"), Some(Feature::ProGrading));
        assert_eq!(Feature::for_effect_kind("gyroflow"), None);
    }

    #[test]
    fn a_closed_notice_never_comes_back_after_a_restart() {
        let mut d = Mem::default();
        let mut p = Prefs::load(&d);
        assert!(p.shows_notice(Feature::MagicMask));
        p.close_notice(Feature::MagicMask);
        p.save(&mut d);
        let again = Prefs::load(&d);
        assert!(!again.shows_notice(Feature::MagicMask));
        assert!(again.shows_notice(Feature::Stabilize), "only that feature's notice is gone");
        assert!(again.shows_mark(), "the small mark stays");
    }

    #[test]
    fn the_label_switch_hides_the_marks_and_survives_a_restart() {
        let mut d = Mem::default();
        assert!(Prefs::load(&d).shows_mark(), "on by default");
        let p = Prefs { labels: false, ..Prefs::default() };
        p.save(&mut d);
        let q = Prefs::load(&d);
        assert!(!q.shows_mark());
        assert!(q.shows_notice(Feature::ProGrading), "an open notice stays once, whatever the switch says");
    }

    #[test]
    fn the_tooltip_says_experimental() {
        assert_eq!(tooltip("Pro grading"), "Pro grading \u{b7} experimental");
    }
}
