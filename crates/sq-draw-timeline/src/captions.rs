// Swift: CaptionSearchControl.swift
//! Find and replace on the caption track, the Mac `CaptionSearchPopup` translated onto the canvas: find field with the
//! match count and previous / next / close, replace field with Replace and Replace All, Match Case. Stays open while
//! the timeline is used (closes on Esc or the close button). All logic is `CaptionSearchModel`; the panel turns the
//! answers into timeline actions. Coordinates are window points.
//!
//! Not ported here: `TimelinePanel+Captions`, `+CaptionWords` and `+CaptionSearch` (the panel glue that shows the card
//! under the first caption row and turns `Answer`s into `TimelineAction`s) need the panel struct; see
//! `PANEL-FIELDS-DT3-4.md`. `CaptionSearchControl::origin_for` is the pure placement math of `showCaptionSearch`.
//!
//! A click inside an open field selects all instead of placing the caret: matches Swift (`CaptionSearchControl`, no atlas at
//! event time).

use sq_core_audio::caption_words::CaptionTextMatch;
use sq_core_model::Timeline;
use sq_core_time::Time;
use sq_draw::{
    Alignment, Canvas, CheckState, Color, DrawTheme, InputKey, InputModifiers, InspectorDraw, InspectorTokens,
    TextAlign, TextFieldControl, UiCx,
};
use sq_timeline_ui::CaptionSearchModel;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::{radius, spacing, type_size};
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuLayout;

/// What the panel does after an event.
#[derive(Clone, Debug, PartialEq)]
pub enum CaptionSearchAnswer {
    /// Return, Next, Previous or Replace went to this match: select it, seek, scroll to it.
    Show(CaptionTextMatch),
    /// Typing found this match: select it only.
    Highlight(CaptionTextMatch),
    /// A replace produced this timeline (one undo step with this name).
    Replace(Box<Timeline>, String),
    Close,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Part {
    Find,
    Replace,
    Previous,
    Next,
    Close,
    ReplaceOne,
    ReplaceAll,
    MatchCase,
}

pub struct CaptionSearchControl {
    model: CaptionSearchModel,
    /// Top left of the card (window points).
    pub origin: CGPoint,
    find_field: TextFieldControl,
    replace_field: TextFieldControl,
    /// "N replaced", shown in place of the match count until the next action in the popup.
    notice: Option<String>,
    /// False until the current match was gone to: the first Return or Next goes to it, later ones step on.
    visited: bool,
    hovered: Option<Part>,
    pressed: Option<Part>,
}

impl Default for CaptionSearchControl {
    fn default() -> Self {
        Self::new(CaptionSearchModel::new(None))
    }
}

impl CaptionSearchControl {
    pub const WIDTH: f64 = 356.0;
    const LINE: f64 = 22.0;
    const ICON: f64 = 22.0;
    const COUNT_WIDTH: f64 = 64.0;

    fn pad() -> f64 {
        f64::from(spacing::MD)
    }

    fn gap() -> f64 {
        f64::from(spacing::SM)
    }

    pub fn height() -> f64 {
        Self::pad() + Self::LINE + Self::gap() + Self::LINE + Self::gap() + Self::LINE + Self::pad()
    }

    pub fn new(model: CaptionSearchModel) -> Self {
        let mut find_field = TextFieldControl::new("");
        let mut replace_field = TextFieldControl::new("");
        find_field.alignment = Alignment::Left;
        replace_field.alignment = Alignment::Left;
        find_field.font_size = f64::from(type_size::BODY);
        replace_field.font_size = find_field.font_size;
        find_field.placeholder = "Find in captions".to_string();
        replace_field.placeholder = "Replace with".to_string();
        CaptionSearchControl {
            model,
            origin: CGPoint { x: 0.0, y: 0.0 },
            find_field,
            replace_field,
            notice: None,
            visited: false,
            hovered: None,
            pressed: None,
        }
    }

    pub fn model(&self) -> &CaptionSearchModel {
        &self.model
    }

    pub fn frame(&self) -> CGRect {
        CGRect::new(self.origin.x, self.origin.y, Self::WIDTH, Self::height())
    }

    pub fn count_text(&self) -> String {
        self.notice.clone().unwrap_or_else(|| self.model.count_label())
    }

    pub fn is_editing(&self) -> bool {
        self.find_field.is_editing() || self.replace_field.is_editing()
    }

    /// True while a press on one of the card's parts is held.
    pub fn is_pressed(&self) -> bool {
        self.pressed.is_some()
    }

    /// Where the card opens (`TimelinePanel.showCaptionSearch`): under the first caption row (`row_y`, `row_height`) at the
    /// content's left edge + 12, above the row when it would leave `window`, kept 6 pt inside it.
    pub fn origin_for(
        panel_origin: CGPoint,
        row_y: f64,
        row_height: f64,
        ruler_height: f64,
        panel_height: f64,
        content_origin_x: f64,
        window: (f64, f64),
    ) -> CGPoint {
        let y = row_y.max(ruler_height).min((panel_height - row_height).max(0.0));
        let mut p = CGPoint {
            x: panel_origin.x + content_origin_x + f64::from(spacing::MD),
            y: panel_origin.y + y + row_height + 4.0,
        };
        let margin = 6.0;
        if p.y + Self::height() > window.1 - margin {
            p.y = panel_origin.y + y - 4.0 - Self::height();
        }
        p.x = margin.max(p.x.min(window.0 - margin - Self::WIDTH));
        p.y = margin.max(p.y.min(window.1 - margin - Self::height()));
        p
    }

    // MARK: Layout (the Mac `build`)

    pub(crate) fn rect(&self, p: Part) -> CGRect {
        let o = self.origin;
        let (w, pad, h, gap) = (Self::WIDTH, Self::pad(), Self::LINE, Self::gap());
        let y1 = o.y + pad;
        let y2 = y1 + h + gap;
        let y3 = y2 + h + gap;
        let xs = f64::from(spacing::XS);
        let icon_step = Self::ICON + xs;
        let right = o.x + w - pad - 3.0 * icon_step - (gap - xs);
        let (all_w, one_w) = (84.0, 68.0);
        match p {
            Part::Close => CGRect::new(o.x + w - pad - Self::ICON, y1, Self::ICON, h),
            Part::Next => CGRect::new(o.x + w - pad - icon_step - Self::ICON, y1, Self::ICON, h),
            Part::Previous => CGRect::new(o.x + w - pad - 2.0 * icon_step - Self::ICON, y1, Self::ICON, h),
            Part::Find => CGRect::new(o.x + pad, y1, right - Self::COUNT_WIDTH - gap - o.x - pad, h),
            Part::ReplaceAll => CGRect::new(o.x + w - pad - all_w, y2, all_w, h),
            Part::ReplaceOne => CGRect::new(o.x + w - pad - all_w - gap - one_w, y2, one_w, h),
            Part::Replace => CGRect::new(o.x + pad, y2, w - 2.0 * pad - all_w - one_w - 2.0 * gap, h),
            Part::MatchCase => CGRect::new(o.x + pad, y3, 160.0, h),
        }
    }

    fn count_frame(&self) -> CGRect {
        let f = self.rect(Part::Find);
        CGRect::new(f.max_x() + Self::gap(), f.min_y(), Self::COUNT_WIDTH, Self::LINE)
    }

    fn part_at(&self, p: CGPoint) -> Option<Part> {
        [
            Part::Find,
            Part::Replace,
            Part::Previous,
            Part::Next,
            Part::Close,
            Part::ReplaceOne,
            Part::ReplaceAll,
            Part::MatchCase,
        ]
        .into_iter()
        .find(|part| self.rect(*part).contains(p))
    }

    fn enabled(&self, p: Part) -> bool {
        let has = !self.model.matches().is_empty();
        match p {
            Part::Previous | Part::Next => has,
            Part::ReplaceOne => self.model.can_replace(),
            Part::ReplaceAll => has && self.model.find != self.model.replacement,
            _ => true,
        }
    }

    // MARK: Opening

    /// Shows the card (or, already shown, puts the caret back into the find field with its text selected).
    pub fn focus_find(&mut self, timeline: &Timeline, playhead: Time) {
        let _ = self.replace_field.commit();
        let _ = self.find_field.commit();
        self.find_field.mouse_down(None, 1);
        let _ = self.refresh(timeline, playhead, false);
    }

    /// The timeline changed under the popup (an edit, undo): search again, keep the place. A "N replaced" notice stays.
    pub fn resync(&mut self, timeline: &Timeline, playhead: Time) {
        self.model.refresh(timeline, playhead);
    }

    pub(crate) fn find_text(&self) -> String {
        self.find_field.editor().map_or_else(|| self.find_field.text.clone(), |e| e.string().to_string())
    }

    fn replace_text(&self) -> String {
        self.replace_field.editor().map_or_else(|| self.replace_field.text.clone(), |e| e.string().to_string())
    }

    /// Takes the fields into the model and searches. `highlight`: the search text changed, so the match is marked.
    fn refresh(&mut self, timeline: &Timeline, playhead: Time, highlight: bool) -> Vec<CaptionSearchAnswer> {
        self.model.find = self.find_text();
        self.model.replacement = self.replace_text();
        self.model.refresh(timeline, playhead);
        if !highlight {
            return Vec::new();
        }
        self.notice = None;
        self.visited = false;
        self.model.current_match().cloned().map(CaptionSearchAnswer::Highlight).into_iter().collect()
    }

    // MARK: Actions

    fn step(&mut self, forward: bool) -> Vec<CaptionSearchAnswer> {
        self.notice = None;
        if self.visited || !forward {
            self.model.step(forward);
        }
        self.visited = true;
        self.model.current_match().cloned().map(CaptionSearchAnswer::Show).into_iter().collect()
    }

    fn replace_one(&mut self, timeline: &Timeline) -> Vec<CaptionSearchAnswer> {
        self.notice = None;
        self.model.replacement = self.replace_text();
        let Some(out) = self.model.replacing_current(timeline) else { return Vec::new() };
        self.visited = true;
        let mut answers = vec![CaptionSearchAnswer::Replace(Box::new(out), "Replace in Caption".to_string())];
        answers.extend(self.model.current_match().cloned().map(CaptionSearchAnswer::Show));
        answers
    }

    fn replace_all(&mut self, timeline: &Timeline) -> Vec<CaptionSearchAnswer> {
        self.model.replacement = self.replace_text();
        let Some((out, count)) = self.model.replacing_all(timeline) else {
            self.notice = None;
            return Vec::new();
        };
        self.notice = Some(if count == 1 { "1 replaced".to_string() } else { format!("{count} replaced") });
        vec![CaptionSearchAnswer::Replace(Box::new(out), "Replace All in Captions".to_string())]
    }

    // MARK: Events

    /// A press. `None` when it landed outside the card (the card stays open, its fields commit).
    pub fn mouse_down(&mut self, p: CGPoint) -> Option<Vec<CaptionSearchAnswer>> {
        if !self.frame().contains(p) {
            let _ = self.find_field.commit();
            let _ = self.replace_field.commit();
            return None;
        }
        let Some(part) = self.part_at(p).filter(|part| self.enabled(*part)) else { return Some(Vec::new()) };
        self.pressed = Some(part);
        match part {
            Part::Find => {
                let _ = self.replace_field.commit();
                if !self.find_field.is_editing() {
                    self.find_field.mouse_down(None, 1);
                }
            }
            Part::Replace => {
                let _ = self.find_field.commit();
                if !self.replace_field.is_editing() {
                    self.replace_field.mouse_down(None, 1);
                }
            }
            _ => {}
        }
        Some(Vec::new())
    }

    pub fn mouse_up(&mut self, p: CGPoint, timeline: &Timeline, playhead: Time) -> Vec<CaptionSearchAnswer> {
        let Some(part) = self.pressed.take() else { return Vec::new() };
        if !self.rect(part).contains(p) || !self.enabled(part) {
            return Vec::new();
        }
        match part {
            Part::Previous => self.step(false),
            Part::Next => self.step(true),
            Part::Close => vec![CaptionSearchAnswer::Close],
            Part::ReplaceOne => self.replace_one(timeline),
            Part::ReplaceAll => self.replace_all(timeline),
            Part::MatchCase => {
                self.model.case_sensitive = !self.model.case_sensitive;
                self.refresh(timeline, playhead, true)
            }
            Part::Find | Part::Replace => Vec::new(),
        }
    }

    pub fn mouse_moved(&mut self, p: CGPoint) {
        self.hovered = if self.frame().contains(p) { self.part_at(p) } else { None };
    }

    /// A key. `None` when neither field is open (the timeline takes it).
    pub fn key(
        &mut self,
        k: InputKey,
        m: InputModifiers,
        timeline: &Timeline,
        playhead: Time,
        cx: &mut UiCx,
    ) -> Option<Vec<CaptionSearchAnswer>> {
        let in_find = self.find_field.is_editing();
        if !in_find && !self.replace_field.is_editing() {
            return None;
        }
        match k {
            InputKey::Escape => Some(vec![CaptionSearchAnswer::Close]),
            InputKey::Enter => {
                Some(if in_find { self.step(!m.contains(InputModifiers::SHIFT)) } else { self.replace_one(timeline) })
            }
            // `nextKeyView`: the two fields hand the focus to each other.
            InputKey::Character('\t') => {
                if in_find {
                    let _ = self.find_field.commit();
                    self.replace_field.mouse_down(None, 1);
                } else {
                    let _ = self.replace_field.commit();
                    self.find_field.mouse_down(None, 1);
                }
                Some(Vec::new())
            }
            _ => {
                let before = (self.find_text(), self.replace_text());
                if in_find {
                    let _ = self.find_field.key(k, m, cx);
                } else {
                    let _ = self.replace_field.key(k, m, cx);
                }
                if (self.find_text(), self.replace_text()) == before {
                    return Some(Vec::new());
                }
                Some(self.refresh(timeline, playhead, in_find))
            }
        }
    }

    // MARK: Drawing

    pub fn draw(&self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx) {
        let bounds = self.frame();
        let r = SQMenuLayout::CORNER_RADIUS;
        c.shadow(bounds, r, 10.0, 4.0, Color::new(0.0, 0.0, 0.0, 0.25), true);
        let bg = bounds.inset_by(0.25, 0.25);
        c.fill_rounded(bg, r, t.overlay());
        c.stroke_rounded(bg, r, 0.5, t.ink_fill(0.14));
        self.find_field.draw(c, self.rect(Part::Find), t, false, cx);
        c.draw_text_in(
            &self.count_text(),
            self.count_frame(),
            f64::from(type_size::BODY),
            t.label3(),
            TextAlign::Right,
            0.0,
            0,
        );
        for (part, icon) in
            [(Part::Previous, SQIcon::ChevronUp), (Part::Next, SQIcon::ChevronDown), (Part::Close, SQIcon::Close)]
        {
            let rect = self.rect(part);
            let on = self.enabled(part);
            if on && (self.hovered == Some(part) || self.pressed == Some(part)) {
                let fill = if self.pressed == Some(part) { t.fill_pressed() } else { t.fill_hover() };
                c.fill_rounded(rect, f64::from(radius::SMALL), fill);
            }
            let l2 = t.label2();
            let color = if on { l2 } else { l2.with_alpha(l2.a * InspectorTokens::DISABLED_ALPHA) };
            c.draw_icon(icon, CGPoint { x: rect.mid_x() - 7.0, y: rect.mid_y() - 7.0 }, 14.0, color, None);
        }
        self.replace_field.draw(c, self.rect(Part::Replace), t, false, cx);
        for (part, title) in [(Part::ReplaceOne, "Replace"), (Part::ReplaceAll, "Replace All")] {
            InspectorDraw::button(
                c,
                &SQL10n::string(title),
                self.rect(part),
                self.hovered == Some(part),
                self.pressed == Some(part),
                self.enabled(part),
                false,
                f64::from(InspectorTokens::CAPSULE),
                t,
            );
        }
        let mc = self.rect(Part::MatchCase);
        let boxed = CGRect::new(mc.min_x(), mc.mid_y() - 7.0, 14.0, 14.0);
        InspectorDraw::checkbox(
            c,
            if self.model.case_sensitive { CheckState::On } else { CheckState::Off },
            boxed,
            self.hovered == Some(Part::MatchCase),
            self.pressed == Some(Part::MatchCase),
            true,
            false,
            t,
        );
        c.draw_text_in(
            &SQL10n::string("Match case"),
            CGRect::new(boxed.max_x() + 6.0, mc.min_y(), mc.width - 20.0, mc.height),
            f64::from(type_size::BODY),
            t.label(),
            TextAlign::Left,
            0.0,
            0,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{CaptionItem, CaptionTrack, SequenceFormat};
    use sq_core_time::{Id, TimeRange};

    const FD: Time = Time::new(1, 25);

    /// One caption track: "the cat" at 0, "the dog" at 60 frames.
    fn timeline() -> Timeline {
        let mut track: CaptionTrack = serde_json::from_value(serde_json::json!({"id": Id::from_u128(7).to_string()}))
            .unwrap_or_else(|_| unreachable!());
        track.with_items(|v| {
            for (k, text) in ["the cat", "the dog"].iter().enumerate() {
                v.push(CaptionItem {
                    id: Id::from_u128(100 + k as u128),
                    lines: vec![(*text).to_string()],
                    range: TimeRange::new(FD * (60 * k as i64), FD * 25),
                    style_ref: String::new(),
                    animation_ref: String::new(),
                    style_overridden: false,
                    words: vec![],
                    position: None,
                });
            }
        });
        let mut t = Timeline::new(Id::from_u128(1), "t", SequenceFormat::new(FD), vec![]);
        t.caption_tracks = vec![track];
        t
    }

    fn opened(t: &Timeline) -> CaptionSearchControl {
        let mut c = CaptionSearchControl { origin: CGPoint { x: 100.0, y: 50.0 }, ..CaptionSearchControl::default() };
        c.focus_find(t, Time::ZERO);
        c
    }

    fn type_text(c: &mut CaptionSearchControl, t: &Timeline, text: &str) -> Vec<CaptionSearchAnswer> {
        let mut cx = UiCx::new();
        let mut last = Vec::new();
        for ch in text.chars() {
            cx.typed_text = Some(ch.to_string());
            last = c.key(InputKey::Character(ch), InputModifiers::NONE, t, Time::ZERO, &mut cx).unwrap_or_default();
        }
        last
    }

    fn click(c: &mut CaptionSearchControl, t: &Timeline, part: Part) -> Vec<CaptionSearchAnswer> {
        let r = c.rect(part);
        let p = CGPoint { x: r.mid_x(), y: r.mid_y() };
        c.mouse_down(p);
        c.mouse_up(p, t, Time::ZERO)
    }

    #[test]
    fn height_and_width_follow_the_layout() {
        assert_eq!(CaptionSearchControl::WIDTH, 356.0);
        assert_eq!(CaptionSearchControl::height(), 12.0 + 22.0 + 8.0 + 22.0 + 8.0 + 22.0 + 12.0);
        let c = CaptionSearchControl::default();
        assert_eq!(c.frame(), CGRect::new(0.0, 0.0, 356.0, 106.0));
    }

    #[test]
    fn origin_sits_under_the_row_and_flips_above_at_the_bottom() {
        let o = CaptionSearchControl::origin_for(
            CGPoint { x: 0.0, y: 100.0 },
            40.0,
            24.0,
            24.0,
            300.0,
            156.0,
            (1440.0, 900.0),
        );
        assert_eq!((o.x, o.y), (156.0 + 12.0, 100.0 + 40.0 + 24.0 + 4.0));
        let low = CaptionSearchControl::origin_for(
            CGPoint { x: 0.0, y: 100.0 },
            40.0,
            24.0,
            24.0,
            300.0,
            156.0,
            (1440.0, 200.0),
        );
        assert_eq!(low.y, 100.0 + 40.0 - 4.0 - CaptionSearchControl::height());
        let right = CaptionSearchControl::origin_for(
            CGPoint { x: 0.0, y: 0.0 },
            40.0,
            24.0,
            24.0,
            300.0,
            156.0,
            (300.0, 900.0),
        );
        // Wider than the window: the left margin wins.
        assert_eq!(right.x, 6.0);
    }

    #[test]
    fn typing_highlights_return_steps_and_escape_closes() {
        let t = timeline();
        let mut c = opened(&t);
        assert!(c.is_editing());
        let out = type_text(&mut c, &t, "the");
        assert_eq!(c.count_text(), "1 of 2");
        assert!(matches!(out.as_slice(), [CaptionSearchAnswer::Highlight(m)] if m.caption == Id::from_u128(100)));
        let mut cx = UiCx::new();
        let enter = |c: &mut CaptionSearchControl, cx: &mut UiCx| {
            c.key(InputKey::Enter, InputModifiers::NONE, &t, Time::ZERO, cx)
        };
        // The first Return goes to the current match, the next one steps on.
        assert!(
            matches!(enter(&mut c, &mut cx).as_deref(), Some([CaptionSearchAnswer::Show(m)]) if m.caption == Id::from_u128(100))
        );
        assert!(
            matches!(enter(&mut c, &mut cx).as_deref(), Some([CaptionSearchAnswer::Show(m)]) if m.caption == Id::from_u128(101))
        );
        assert_eq!(c.count_text(), "2 of 2");
        let shift = c.key(InputKey::Enter, InputModifiers::SHIFT, &t, Time::ZERO, &mut cx);
        assert!(matches!(shift.as_deref(), Some([CaptionSearchAnswer::Show(m)]) if m.caption == Id::from_u128(100)));
        assert_eq!(
            c.key(InputKey::Escape, InputModifiers::NONE, &t, Time::ZERO, &mut cx),
            Some(vec![CaptionSearchAnswer::Close])
        );
    }

    #[test]
    fn keys_pass_through_when_no_field_is_open() {
        let t = timeline();
        let mut c = CaptionSearchControl::default();
        assert_eq!(c.key(InputKey::Enter, InputModifiers::NONE, &t, Time::ZERO, &mut UiCx::new()), None);
    }

    #[test]
    fn replace_all_returns_the_changed_timeline_and_a_notice() {
        let t = timeline();
        let mut c = opened(&t);
        type_text(&mut c, &t, "the");
        let mut cx = UiCx::new();
        c.key(InputKey::Character('\t'), InputModifiers::NONE, &t, Time::ZERO, &mut cx);
        type_text(&mut c, &t, "a");
        let out = click(&mut c, &t, Part::ReplaceAll);
        match out.as_slice() {
            [CaptionSearchAnswer::Replace(tl, name)] => {
                assert_eq!(name, "Replace All in Captions");
                let lines: Vec<_> = tl.caption_tracks[0].items().iter().map(|i| i.lines.clone()).collect();
                assert_eq!(lines, vec![vec!["a cat".to_string()], vec!["a dog".to_string()]]);
            }
            other => panic!("unexpected {other:?}"),
        }
        assert_eq!(c.count_text(), "2 replaced");
    }

    #[test]
    fn presses_outside_leave_the_card_open_and_close_closes() {
        let t = timeline();
        let mut c = opened(&t);
        assert_eq!(c.mouse_down(CGPoint { x: 990.0, y: 490.0 }), None);
        assert!(!c.is_editing());
        assert_eq!(click(&mut c, &t, Part::Close), vec![CaptionSearchAnswer::Close]);
    }

    #[test]
    fn match_case_toggles_and_refreshes() {
        let t = timeline();
        let mut c = opened(&t);
        type_text(&mut c, &t, "THE");
        assert_eq!(c.count_text(), "1 of 2");
        click(&mut c, &t, Part::MatchCase);
        assert!(c.model().case_sensitive);
        assert_eq!(c.count_text(), "No matches");
        // Previous / Next are dim without matches.
        assert!(click(&mut c, &t, Part::Next).is_empty());
    }

    #[test]
    fn draws_the_card() {
        let t = timeline();
        let c = opened(&t);
        let mut cv = Canvas::with_size(1440.0, 900.0, None, 1.0);
        c.draw(&mut cv, &DrawTheme::default(), &mut UiCx::new());
        assert!(cv.list.quads().len() > 10);
    }
}
