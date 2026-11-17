// Swift: TimelinePanel+CaptionSearch.swift
//! Find and replace on the caption tracks (`TimelineView.showCaptionSearch` / `makeCaptionSearch`): Edit > Find with the
//! timeline focused opens `CaptionSearchControl` under the first caption row, at the content's left edge + 12. The host
//! draws it over the cards (`draw_caption_search`) and sends it events first (`handle_caption_search`).

use crate::action::TimelineAction;
use crate::captions::{CaptionSearchAnswer, CaptionSearchControl};
use crate::panel::TimelinePanel;
use sq_draw::{Canvas, InputEvent, UiCx};
use sq_timeline_ui::{CaptionWordRef, TimelineGeometry};
use sq_uikit::controls_grid::{CGPoint, CGSize};

impl TimelinePanel {
    pub fn is_caption_search_shown(&self) -> bool {
        self.caption_search.is_some()
    }

    /// Opens the card (shown: focuses its find field). False when the timeline has no captions: the caller keeps its own
    /// Find. `window` (points) keeps the card on screen like the Mac popover's screen clamp (6 pt margin).
    pub fn show_caption_search(&mut self, window: CGSize) -> bool {
        if !self.timeline.caption_tracks.iter().any(|t| !t.items().is_empty()) {
            return false;
        }
        let Some(row) = self.geometry.caption_rows(&self.timeline).into_iter().next() else { return false };
        let _ = self.finish_word_field(true, 0);
        let mut s = self.caption_search.take().unwrap_or_default();
        let k = f64::from(self.scale.max(0.01));
        let o = CGPoint { x: f64::from(self.frame.x) / k, y: f64::from(self.frame.y) / k };
        s.origin = CaptionSearchControl::origin_for(
            o,
            row.y,
            row.height,
            TimelineGeometry::RULER_HEIGHT,
            self.size.height,
            TimelineGeometry::CONTENT_ORIGIN_X,
            (window.width, window.height),
        );
        s.focus_find(&self.timeline, self.playhead);
        self.caption_search = Some(s);
        true
    }

    /// An event for the card (window pixels, the host's scale). `None` when it does not take it: the press landed outside
    /// (the card stays open) or a key came while neither field is open.
    pub fn handle_caption_search(&mut self, e: &InputEvent, ui: &mut UiCx) -> Option<Vec<TimelineAction>> {
        let mut s = self.caption_search.take()?;
        let k = f64::from(self.scale.max(0.01));
        let pt = |x: f32, y: f32| CGPoint { x: f64::from(x) / k, y: f64::from(y) / k };
        let answers: Option<Vec<CaptionSearchAnswer>> = match *e {
            InputEvent::MouseDown { x, y, .. } => s.mouse_down(pt(x, y)),
            InputEvent::MouseUp { x, y } => {
                if !s.is_pressed() {
                    self.caption_search = Some(s);
                    return None;
                }
                Some(s.mouse_up(pt(x, y), &self.timeline, self.playhead))
            }
            InputEvent::MouseDragged { .. } => s.is_pressed().then(Vec::new),
            InputEvent::MouseMoved { x, y } => {
                s.mouse_moved(pt(x, y));
                let inside = s.frame().contains(pt(x, y));
                self.caption_search = Some(s);
                return inside.then(Vec::new);
            }
            InputEvent::KeyDown { key, modifiers } => s.key(key, modifiers, &self.timeline, self.playhead, ui),
            InputEvent::Scroll { x, y, .. } => s.frame().contains(pt(x, y)).then(Vec::new),
        };
        self.caption_search = Some(s);
        let answers = answers?;
        let mut out: Vec<TimelineAction> = Vec::new();
        for a in answers {
            match a {
                CaptionSearchAnswer::Close => self.caption_search = None,
                CaptionSearchAnswer::Highlight(m) => {
                    out.extend(self.select_word(Some(CaptionWordRef::new(m.caption, *m.words.start()))));
                }
                CaptionSearchAnswer::Show(m) => {
                    out.extend(self.select_word(Some(CaptionWordRef::new(m.caption, *m.words.start()))));
                    out.push(TimelineAction::Seek(m.time));
                    self.reveal_time(m.time);
                }
                CaptionSearchAnswer::Replace(t, name) => {
                    let captions = self.caption_selection.clone();
                    out.extend(self.apply_caption_edit(*t, &name, captions, None));
                }
            }
        }
        Some(out)
    }

    /// The card over everything the panel draws (window points).
    pub fn draw_caption_search(&self, c: &mut Canvas, cx: &mut UiCx) {
        if let Some(s) = &self.caption_search {
            s.draw(c, &self.theme, cx);
        }
    }
}
