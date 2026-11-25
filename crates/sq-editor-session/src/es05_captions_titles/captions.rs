//! Caption edits of the Captions panel, the timeline and the Program monitor; caption tracks and positions; the pure
//! helpers that map transcripts onto the timeline and find captions under a monitor click.

use std::collections::BTreeSet;

use sq_core_audio::{CaptionItemExt, CaptionTidy, CaptionTidyOptions, TimelineCaptionsExt};
use sq_core_model::{
    CaptionItem, CaptionPosition, CaptionTrack, CaptionVertical, CaptionWord, Clip, SequenceFormat, Timeline,
};
use sq_core_time::keyframes_model::Vec2;
use sq_core_time::{Id, IdSource, Time, TimeRange};
use sq_text::caption_layout::CaptionLayout;
use sq_text::caption_presets::CaptionPresetLibrary;
use sq_text::text_layout::{TextLayout, TextRect};
use sq_text::text_style::{TextBox, TextStyle};
use sq_transcribe::caption_segmenter::Caption;
use sq_transcribe::subtitle_reader::{Format, SubtitleReader};
use sq_uikit::keyframe_graph_geometry::{Point, Rect};

use crate::{Change, EditorSession};
use sq_core_audio::TimelineCaptionEditsExt as TimelineCaptionEdits;

/// Auto language for transcription: after a run in the chosen language, the text itself tells whether another supported
/// language was spoken. One retry in that language; a wrong guess never loops (the host retries once per run).
pub enum CaptionLanguageGuess {}

impl CaptionLanguageGuess {
    /// Fewer letters than this say too little about the language.
    pub const MINIMUM_LETTERS: usize = 24;
    /// Recognizer confidence needed before a re-run is worth its time.
    pub const MINIMUM_CONFIDENCE: f64 = 0.85;

    /// The supported locale to transcribe again in, or `None` when `text` is too short, too unsure, already in the
    /// language of `used`, or in a language `supported` has no locale for. Of several regions the system language's
    /// region wins (`preferred`). `detect` is the app's language recognizer: the language code and its confidence.
    // Swift: CaptionLanguageGuess.swift:14
    pub fn retry_language(
        text: &str,
        used: &str,
        supported: &[String],
        preferred: &[String],
        detect: &dyn Fn(&str) -> Option<(String, f64)>,
    ) -> Option<String> {
        if text.chars().filter(|c| c.is_alphabetic()).count() < Self::MINIMUM_LETTERS {
            return None;
        }
        let (code, p) = detect(text)?;
        if p < Self::MINIMUM_CONFIDENCE {
            return None;
        }
        fn base(id: &str) -> String {
            id.chars().take_while(|c| *c != '-' && *c != '_').collect::<String>().to_lowercase()
        }
        if base(used) == code {
            return None;
        }
        let matches: Vec<&String> = supported.iter().filter(|s| base(s) == code).collect();
        for id in preferred {
            if let Some(m) = matches.iter().find(|m| m.eq_ignore_ascii_case(id)) {
                return Some((*m).clone());
            }
        }
        matches.first().map(|m| (*m).clone())
    }
}

/// Maps captions produced from a transcript (source time of the clip's media) onto the timeline.
pub enum CaptionMapping {}

impl CaptionMapping {
    /// Maps source time onto the timeline through the clip's speed and direction and keeps only what lies inside the
    /// clip's source range (cut at its ends). With `frame_duration` the ranges are put on the frame grid.
    // Swift: CaptionMapping.swift:11
    pub fn items(
        captions: &[Caption],
        clip: &Clip,
        frame_duration: Option<Time>,
        ids: &mut dyn IdSource,
    ) -> Vec<CaptionItem> {
        let items: Vec<CaptionItem> = captions
            .iter()
            .filter_map(|c| {
                let s = c.range.intersection(&clip.source).filter(|s| !s.is_empty())?;
                let a = clip.timeline_time_for_source(s.start, Time::ZERO);
                let b = clip.timeline_time_for_source(s.end(), Time::ZERO);
                let r = TimeRange::from_end(a.min(b), a.max(b)); // reversed or remapped: either order
                if r.is_empty() {
                    return None;
                }
                Some(CaptionItem {
                    id: ids.next_id(),
                    lines: c.lines.clone(),
                    range: r,
                    style_ref: c.style_ref.clone(),
                    animation_ref: c.animation_ref.clone(),
                    style_overridden: false,
                    words: Self::timeline_words(&c.words, r, clip),
                    position: None,
                })
            })
            .collect();
        match frame_duration {
            Some(fd) => Self::snapped(&items, fd),
            None => items,
        }
    }

    /// The spoken words of a caption on the timeline (karaoke): source times through the clip's speed, clamped into the
    /// caption's range. A reversed clip has no usable word order, so its captions spread their words instead.
    fn timeline_words(words: &[CaptionWord], r: TimeRange, clip: &Clip) -> Vec<CaptionWord> {
        if clip.reversed {
            return Vec::new();
        }
        words
            .iter()
            .map(|w| {
                let a = clip.timeline_time_for_source(w.range.start, Time::ZERO).max(r.start).min(r.end());
                let b = clip.timeline_time_for_source(w.range.end(), Time::ZERO).max(a).min(r.end());
                // relative to the caption
                CaptionWord {
                    text: w.text.clone(),
                    range: TimeRange::from_end(a - r.start, b - r.start),
                    confidence: w.confidence,
                }
            })
            .collect()
    }

    /// Nearest frame for both ends; a caption that collapses gets one frame when the next one leaves room, else it goes.
    // Swift: CaptionMapping.swift:38
    pub fn snapped(items: &[CaptionItem], fd: Time) -> Vec<CaptionItem> {
        let mut sorted = items.to_vec();
        sorted.sort_by_key(|i| i.range.start);
        let mut out: Vec<CaptionItem> = Vec::new();
        for (i, it) in sorted.iter().enumerate() {
            let mut s = it.range.start.snapped(fd);
            let mut e = it.range.end().snapped(fd);
            if let Some(last) = out.last()
                && s < last.range.end()
            {
                s = last.range.end();
            }
            if e <= s {
                let next = sorted.get(i + 1).map(|n| n.range.start.snapped(fd));
                if next.is_some_and(|n| n < s + fd) {
                    continue;
                }
                e = s + fd;
            }
            let mut c = it.clone();
            c.shift_word_origin(s - it.range.start); // word times are relative to the start
            c.range = TimeRange::from_end(s, e);
            out.push(c);
        }
        out
    }

    /// All clips that play the same media: the captions of each clip's part, in time order, never overlapping.
    // Swift: CaptionMapping.swift:62
    pub fn items_for_clips(
        captions: &[Caption],
        clips: &[Clip],
        frame_duration: Option<Time>,
        ids: &mut dyn IdSource,
    ) -> Vec<CaptionItem> {
        let mut sorted: Vec<&Clip> = clips.iter().collect();
        sorted.sort_by_key(|c| c.start);
        let mut out: Vec<CaptionItem> = Vec::new();
        for clip in sorted {
            for item in Self::items(captions, clip, frame_duration, ids) {
                if !out.iter().any(|o| o.range.overlaps(&item.range)) {
                    out.push(item);
                }
            }
        }
        out.sort_by_key(|i| i.range.start);
        out
    }
}

/// The edit box of a caption: sequence px from the canvas center, y down.
#[derive(Clone, Debug, PartialEq)]
pub struct CaptionEditBox {
    pub centre: Vec2,
    pub box_: TextBox,
}

/// What the in-place editor of the Program monitor needs to sit over a caption.
#[derive(Clone, Debug, PartialEq)]
pub struct CaptionEditTarget {
    /// The caption's id.
    pub clip: Id,
    /// Box center in sequence px (the stand-in target's position).
    pub centre: Vec2,
    pub box_: TextBox,
    /// The style the caption is drawn with (aligned by the caption position).
    pub style: TextStyle,
}

/// Captions in the Program monitor: where a caption's text sits and which caption a double-click hits.
pub enum CaptionMonitorHit {}

impl CaptionMonitorHit {
    /// Hit slop around the text (sequence px).
    // Swift: CaptionMonitorHit.swift:12
    pub const SLOP: f64 = 12.0;

    /// The edit box of a caption (what the in-place editor covers).
    // Swift: CaptionMonitorHit.swift:15
    pub fn edit_box(canvas: &SequenceFormat, position: CaptionPosition) -> CaptionEditBox {
        let (w, h) = (canvas.layout_format().width as f64, canvas.height as f64);
        let c = CaptionLayout::box_centre(w, h, &position, CaptionLayout::BOTTOM_MARGIN);
        CaptionEditBox { centre: Vec2::new(c.0, c.1), box_: CaptionLayout::box_(w, h, CaptionLayout::WIDTH_FRACTION) }
    }

    /// The caption box as a stand-in target plus the style the caption is drawn with.
    // Swift: CaptionMonitorHit.swift:22
    pub fn edit_target(
        item: &CaptionItem,
        canvas: &SequenceFormat,
        library: &CaptionPresetLibrary,
    ) -> CaptionEditTarget {
        let position = item.position.unwrap_or(library.position);
        let CaptionEditBox { centre, box_ } = Self::edit_box(canvas, position);
        let mut style = library.style(Some(item.style_ref.as_str()).filter(|r| !r.is_empty()));
        CaptionLayout::align(&mut style, &position);
        CaptionEditTarget { clip: item.id, centre, box_, style }
    }

    /// The drawn text block of a caption, sequence px from the canvas center.
    // Swift: CaptionMonitorHit.swift:36
    pub fn text_rect(item: &CaptionItem, canvas: &SequenceFormat, library: &CaptionPresetLibrary) -> Rect {
        let style = library.style(Some(item.style_ref.as_str()).filter(|r| !r.is_empty()));
        let position = item.position.unwrap_or(library.position);
        let (w, h) = (canvas.layout_format().width as f64, canvas.height as f64);
        let t = CaptionLayout::template(
            &item.lines.join("\n"),
            &style,
            w,
            h,
            CaptionLayout::WIDTH_FRACTION,
            None,
            &position,
        );
        let CaptionEditBox { centre, box_ } = Self::edit_box(canvas, position);
        let (left, top) = (centre.x - box_.width / 2.0, centre.y - box_.height / 2.0);
        let layout = TextLayout::layout(&t.text, &t.style, Some(box_.width), Some(box_.height));
        let mut r: Option<TextRect> = None;
        for l in &layout.lines {
            r = Some(r.map_or(l.rect(), |u| u.union(&l.rect())));
        }
        if let Some(bg) = &layout.background_rect {
            r = Some(r.map_or(*bg, |u| u.union(bg)));
        }
        let Some(r) = r else {
            let line_h = style.size * 1.25;
            let y = match position.vertical {
                CaptionVertical::Top => top,
                CaptionVertical::Middle => centre.y - line_h / 2.0,
                CaptionVertical::Bottom => top + box_.height - line_h,
            };
            return Rect { x: centre.x - 120.0, y, width: 240.0, height: line_h };
        };
        Rect { x: left + r.x, y: top + r.y, width: r.width, height: r.height }
    }

    /// The topmost caption (visible tracks) under `time` whose text block contains `p`.
    // Swift: CaptionMonitorHit.swift:63
    pub fn caption(p: Vec2, timeline: &Timeline, time: Time, library: &CaptionPresetLibrary) -> Option<Id> {
        // Draw order reversed (topmost first): the drawn captions, then the blank ones, which draw nothing and so only
        // count where no drawn caption covers the point.
        let shown = timeline.caption_slots_at(time);
        let mut items: Vec<CaptionItem> = shown.iter().rev().map(|s| s.item.clone()).collect();
        for a in timeline.captions_at(time).iter().rev() {
            if a.item.is_blank() && !shown.iter().any(|s| s.track == a.track) {
                items.push(a.item.clone());
            }
        }
        items.iter().find_map(|item| {
            let r = Self::text_rect(item, &timeline.format, library).inset_by(-Self::SLOP, -Self::SLOP);
            r.contains(Point { x: p.x, y: p.y }).then_some(item.id)
        })
    }
}

impl EditorSession {
    /// Where a caption is drawn: its own position, else the project's kit position.
    // Swift: EditorSession+CaptionPosition.swift:7
    pub fn effective_caption_position(&self, item: &CaptionItem) -> CaptionPosition {
        item.position.unwrap_or_else(|| self.caption_position())
    }

    /// Gives the captions their own position. `continues_gesture` merges a drag or an offset stepper into one undo step.
    // Swift: EditorSession+CaptionPosition.swift:10
    pub fn set_caption_item_position(
        &mut self,
        ids: &BTreeSet<Id>,
        p: CaptionPosition,
        continues_gesture: bool,
    ) -> bool {
        if !continues_gesture {
            self.gesture_counter += 1;
        }
        let key = format!("captionPos:{}", self.gesture_counter);
        let ids = ids.clone();
        self.attempt_keyed_ids("Move Caption", Some(&key), |t, _| t.set_caption_item_position(&ids, Some(p)))
    }

    /// Hands the captions back to the kit position ("Reset to kit position"). One undo step.
    // Swift: EditorSession+CaptionPosition.swift:17
    pub fn reset_caption_positions(&mut self, ids: &BTreeSet<Id>) -> bool {
        let own: BTreeSet<Id> = self
            .caption_items()
            .into_iter()
            .filter(|c| ids.contains(&c.id) && c.position.is_some())
            .map(|c| c.id)
            .collect();
        if own.is_empty() {
            return false;
        }
        self.gesture_counter += 1;
        self.attempt_keyed_ids("Reset Caption Position", None, |t, _| t.set_caption_item_position(&own, None))
    }

    /// Every caption of the sequence (for "Reset" with the scope on all captions).
    // Swift: EditorSession+CaptionPosition.swift:26
    pub fn all_caption_ids(&self) -> BTreeSet<Id> {
        self.caption_items().into_iter().map(|c| c.id).collect()
    }

    /// The track the Look tab edits: the track of the first selected caption, else the focused track, else the first one.
    // Swift: EditorSession+CaptionTracks.swift:8
    pub fn current_caption_track(&self) -> Option<&CaptionTrack> {
        let tl = self.active_timeline()?;
        for id in &self.caption_selection {
            if let Some(t) = tl.caption_track_id_containing(*id).and_then(|tid| tl.caption_track(tid)) {
                return Some(t);
            }
        }
        if let Some(t) = self.caption_track_focus.and_then(|f| tl.caption_track(f)) {
            return Some(t);
        }
        tl.caption_tracks.first()
    }

    /// Picks the caption track the Look tab (scope All Captions) edits and new captions go to.
    // Swift: EditorSession+CaptionTracks.swift:18
    pub fn focus_caption_track(&mut self, id: Option<Id>) {
        if self.caption_track_focus == id {
            return;
        }
        self.caption_track_focus = id;
        self.notify(Change::SELECTION);
    }

    /// Adds an empty caption track ("Captions N") and focuses it; new captions go there.
    // Swift: EditorSession+CaptionTracks.swift:25
    pub fn add_caption_track(&mut self) -> Option<Id> {
        let mut made = None;
        if !self.attempt_keyed_ids("Add Caption Track", None, |t, ids| {
            made = Some(t.add_caption_track(ids));
            Ok(())
        }) {
            return None;
        }
        let made = made?;
        self.caption_track_focus = Some(made);
        self.notify(Change::SELECTION);
        Some(made)
    }

    /// True when any selected caption deviates from its track look (style, animation or position).
    // Swift: EditorSession+CaptionTracks.swift:35
    pub fn selected_captions_have_overrides(&self) -> bool {
        let ids = &self.caption_selection;
        self.caption_items().iter().any(|c| ids.contains(&c.id) && (c.style_overridden || c.position.is_some()))
    }

    /// "Reset to Track Look": the selected captions follow their track again (style, animation, position).
    // Swift: EditorSession+CaptionTracks.swift:41
    pub fn reset_selected_captions_to_track_look(&mut self) -> bool {
        let Some(tl) = self.active_timeline_id else { return false };
        if self.caption_selection.is_empty() {
            return false;
        }
        let ids = self.caption_selection.clone();
        let before = self.history.current().clone();
        let r = self.perform_ids("Reset to Track Look", None, |p, _| {
            p.edit(tl, |t| t.reset_caption_items_to_track_look(&ids))?;
            super::caption_style_tab::CaptionStyleEdit::prune_own_looks(p);
            Ok(())
        });
        if let Err(e) = r {
            self.set_error(EditorSession::message_for(&e));
            return false;
        }
        *self.history.current() != before
    }

    /// Caption items of the active timeline in time order.
    // Swift: EditorSession+Captions.swift:10
    pub fn caption_items(&self) -> Vec<CaptionItem> {
        let mut items: Vec<CaptionItem> = self
            .active_timeline()
            .map(|t| t.caption_tracks.iter().flat_map(|c| c.items().iter().cloned()).collect())
            .unwrap_or_default();
        items.sort_by_key(|i| i.range.start);
        items
    }

    // Swift: EditorSession+Captions.swift:13
    pub fn caption_item(&self, id: Id) -> Option<CaptionItem> {
        self.caption_items().into_iter().find(|c| c.id == id)
    }

    /// Text of one caption; line breaks in `text` become lines. `continues_gesture` merges typing into one step.
    // Swift: EditorSession+Captions.swift:17
    pub fn set_caption_text(&mut self, id: Id, text: &str, continues_gesture: bool) -> bool {
        if !continues_gesture {
            self.gesture_counter += 1;
        }
        let lines: Vec<String> = text.split('\n').map(str::to_string).collect();
        let key = format!("caption:{id}:{}", self.gesture_counter);
        self.attempt_keyed_ids("Edit Caption", Some(&key), |t, _| t.set_caption_text(id, lines))
    }

    /// Moves one caption so it starts at `start`, keeping its length (the Captions list's timecode field). The neighbors and
    /// zero clamp it, like a drag on the track.
    pub fn move_caption(&mut self, id: Id, start: Time) -> bool {
        self.attempt("Move Caption", None, |t| t.move_caption(id, start).map(|_| ()))
    }

    /// Splits the caption under `time` (default: the playhead) in two there.
    // Swift: EditorSession+Captions.swift:25
    pub fn split_caption(&mut self, time: Option<Time>) -> bool {
        let t = time.unwrap_or(self.playhead).snapped(self.es5_frame_duration());
        let Some(item) = self.active_timeline().and_then(|tl| tl.captions_at(t).into_iter().next()).map(|a| a.item)
        else {
            self.set_error("There is no caption at the playhead.");
            return false;
        };
        if t <= item.range.start {
            self.set_error("Move the playhead inside the caption.");
            return false;
        }
        let mut second = None;
        let ok = self.attempt_keyed_ids("Split Caption", None, |tl, ids| {
            second = Some(tl.split_caption(item.id, t, ids)?.1);
            Ok(())
        });
        if let (true, Some(second)) = (ok, second) {
            self.select(BTreeSet::new(), BTreeSet::from([second]));
        }
        ok
    }

    /// Merges the selected captions (two or more on one track).
    // Swift: EditorSession+Captions.swift:37
    pub fn merge_selected_captions(&mut self) -> bool {
        if self.caption_selection.len() < 2 {
            self.set_error("Select two or more captions to merge.");
            return false;
        }
        let ids = self.caption_selection.clone();
        let mut merged = None;
        let ok = self.attempt_keyed_ids("Merge Captions", None, |t, _| {
            merged = Some(t.merge_captions(&ids)?);
            Ok(())
        });
        if let (true, Some(m)) = (ok, merged) {
            self.select(BTreeSet::new(), BTreeSet::from([m]));
        }
        ok
    }

    // Swift: EditorSession+Captions.swift:45
    pub fn delete_selected_captions(&mut self) -> bool {
        if self.caption_selection.is_empty() {
            return false;
        }
        let ids = self.caption_selection.clone();
        let ok = self.attempt_keyed_ids("Delete Captions", None, |t, _| {
            for id in &ids {
                t.delete_caption(*id)?;
            }
            Ok(())
        });
        if ok {
            self.select(self.selection.clone(), BTreeSet::new());
        }
        ok
    }

    /// New empty caption at the playhead (up to 3 s, cut short by the next one); it is selected so it can be typed into.
    // Swift: EditorSession+Captions.swift:56
    pub fn add_caption_at_playhead(&mut self) -> Option<Id> {
        let fd = self.active_timeline()?.frame_duration();
        let t = self.playhead.snapped(fd);
        let track = self.current_caption_track().map(|c| c.id);
        let mut made = None;
        let ok = self.attempt_keyed_ids("Add Caption", None, |tl, ids| {
            made = Some(tl.add_caption(t, Time::new(3, 1).snapped(fd), track, ids)?);
            Ok(())
        });
        if let (true, Some(m)) = (ok, made) {
            self.select(BTreeSet::new(), BTreeSet::from([m]));
        }
        if ok { made } else { None }
    }

    /// Search and replace over all captions; returns the number of replacements (`None`: refused).
    // Swift: EditorSession+Captions.swift:68
    pub fn replace_caption_text(&mut self, find: &str, with: &str, case_sensitive: bool) -> Option<i64> {
        let mut n = None;
        self.attempt_keyed_ids("Replace Caption Text", None, |t, _| {
            n = Some(t.replace_caption_text(find, with, case_sensitive, None)?);
            Ok(())
        });
        n.map(|n| n as i64) // None when the edit threw (every caption track locked)
    }

    /// Caption style (and optionally animation) of every caption on every caption track.
    // Swift: EditorSession+Captions.swift:76
    pub fn set_caption_style(&mut self, style_ref: &str, animation_ref: Option<&str>) -> bool {
        let ids: Vec<Id> = match self.active_timeline() {
            Some(tl) if !tl.caption_tracks.is_empty() => tl.caption_tracks.iter().map(|t| t.id).collect(),
            _ => return false,
        };
        self.attempt_keyed_ids("Caption Style", None, |t, _| {
            for id in &ids {
                t.set_caption_style(style_ref, animation_ref, *id, false)?;
            }
            Ok(())
        })
    }

    /// Adds `items` to the current caption track as one undo step; existing captions that overlap an item go first.
    // Swift: EditorSession+Captions.swift:87
    pub fn add_captions(&mut self, items: Vec<CaptionItem>) -> bool {
        self.add_captions_named(items, "Create Captions")
    }

    /// `add_captions` with its own undo name (the Edit API says "Agent: Add Captions").
    pub fn add_captions_named(&mut self, items: Vec<CaptionItem>, undo_name: &str) -> bool {
        if items.is_empty() {
            return false;
        }
        let target = self.current_caption_track().map(|t| t.id);
        self.attempt_keyed_ids(undo_name, None, |t, ids| {
            let existing: Vec<CaptionItem> =
                target.and_then(|id| t.caption_track(id)).map(|c| c.items().to_vec()).unwrap_or_default();
            let kept = existing.into_iter().filter(|e| !items.iter().any(|i| i.range.overlaps(&e.range)));
            let all: Vec<CaptionItem> = kept.chain(items.iter().cloned()).collect();
            t.replace_captions(all, target, ids)?;
            Ok(())
        })
    }

    /// Imports an `.srt`, `.vtt` or `.ass` file onto the caption track (cue times are sequence times), one undo step.
    /// Returns the number of captions added, or `None` with `last_error` set.
    // Swift: EditorSession+Captions.swift:100
    pub fn import_srt(&mut self, data: &[u8], format: Format) -> Option<usize> {
        let label = match format {
            Format::Srt => "SRT",
            Format::Vtt => "WebVTT",
            Format::Ass => "ASS",
        };
        let parsed = SubtitleReader::parse(data, format, "und", "default", "none", self.ids.as_mut());
        let doc = match parsed {
            Ok(d) => d,
            Err(e) => {
                self.set_error(format!("Could not read the {label} file: {e}"));
                return None;
            }
        };
        let items: Vec<CaptionItem> = doc
            .captions
            .into_iter()
            .map(|c| CaptionItem {
                id: self.ids.next_id(),
                lines: c.lines,
                range: c.range,
                style_ref: c.style_ref,
                animation_ref: c.animation_ref,
                style_overridden: false,
                words: Vec::new(),
                position: None,
            })
            .collect();
        if items.is_empty() {
            self.set_error(format!("The {label} file has no captions."));
            return None;
        }
        let n = items.len();
        if self.add_captions(items) { Some(n) } else { None }
    }

    /// One-click fast-captions pass on the current caption track. One undo step. Returns the number of captions after
    /// the pass (`None`: nothing to do or refused, `last_error` explains).
    // Swift: EditorSession+Captions.swift:119
    pub fn tidy_captions(&mut self, options: &CaptionTidyOptions) -> Option<usize> {
        let Some(fd) = self.active_timeline().map(Timeline::frame_duration) else {
            self.set_error("There are no captions to tidy.");
            return None;
        };
        let Some(track) = self.current_caption_track().cloned() else {
            self.set_error("There are no captions to tidy.");
            return None;
        };
        if track.is_locked {
            self.set_error("Unlock the caption track first.");
            return None;
        }
        let tidy = CaptionTidy::tidy(track.items(), options, fd, self.ids.as_mut());
        if tidy.is_empty() {
            self.set_error("There are no captions to tidy.");
            return None;
        }
        if tidy.as_slice() == track.items() {
            return Some(tidy.len());
        }
        let n = tidy.len();
        let id = track.id;
        let ok =
            self.attempt_keyed_ids("Tidy Captions", None, |t, ids| t.replace_captions(tidy, Some(id), ids).map(|_| ()));
        if ok { Some(n) } else { None }
    }
}

/// Why a translation did not happen (Swift `CaptionTranslator.Failure`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CaptionTranslateFailure {
    // Swift: EditorSession+CaptionTranslate.swift:11
    pub error_description: String,
}

impl std::fmt::Display for CaptionTranslateFailure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.error_description)
    }
}

impl std::error::Error for CaptionTranslateFailure {}

/// The on-device translation service the app provides (Swift `CaptionTranslator`, Apple's Translation framework on
/// the Mac). Languages are BCP-47 codes. The app implements this next to `SessionRoot`.
pub trait CaptionTranslateAsks {
    /// Languages the system can translate into, as BCP-47 codes with English names, sorted by name.
    // Swift: EditorSession+CaptionTranslate.swift:15
    fn supported_targets(&mut self) -> sq_runtime::ModalAsk<Vec<(String, String)>>;

    /// The dominant language of `texts` (`None` when it cannot be told).
    // Swift: EditorSession+CaptionTranslate.swift:27
    fn detect_language(&self, texts: &[String]) -> Option<String>;

    /// Translates `texts` (same order). Fails with a readable message when the pair is not installed.
    // Swift: EditorSession+CaptionTranslate.swift:34
    fn translate(
        &mut self,
        texts: Vec<String>,
        from: &str,
        to: &str,
    ) -> sq_runtime::ModalAsk<Result<Vec<String>, CaptionTranslateFailure>>;
}

impl EditorSession {
    /// Translates the current caption track into `target` (BCP-47 code) as a new caption track with the same timings
    /// and look; the source language is detected from the text. One undo step. Returns the new track, or `None` with
    /// `last_error` set.
    // Swift: EditorSession+CaptionTranslate.swift:56
    pub async fn translate_captions<R: crate::SessionRoot + CaptionTranslateAsks + ?Sized>(
        h: sq_runtime::UiRef<R>,
        target: &str,
    ) -> Option<Id> {
        // Everything that reads the session happens inside `with`; nothing is borrowed across an await.
        let prepared = h.with(|r| {
            let s = r.session();
            let Some(track) = s.current_caption_track().filter(|t| !t.items().is_empty()).cloned() else {
                s.set_error("There are no captions to translate.");
                return None;
            };
            let texts: Vec<String> = track.items().iter().map(|i| i.lines.join(" ")).collect();
            let Some(source) = r.detect_language(&texts) else {
                r.session().set_error("Could not tell the language of the captions.");
                return None;
            };
            if base_language(&source) == base_language(target) {
                r.session().set_error("The captions are already in that language.");
                return None;
            }
            let ask = r.translate(texts.clone(), &source, target);
            Some((track, ask, source))
        })??;
        let (track, ask, _source) = prepared;
        let translated = ask.await;
        h.with(|r| {
            let s = r.session();
            match translated {
                Ok(t) => s.apply_translated_captions(&track, &t, target),
                Err(e) => {
                    s.set_error(e.error_description);
                    None
                }
            }
        })?
    }

    /// Adds the translated texts of `track` as a new caption track "<name> (<code>)" with the same timings and look
    /// (one undo step) and focuses it. `None` with `last_error` set when it cannot be done.
    // Swift: EditorSession+CaptionTranslate.swift:68
    pub fn apply_translated_captions(
        &mut self,
        track: &CaptionTrack,
        translated: &[String],
        target: &str,
    ) -> Option<Id> {
        let items = sq_core_edit::caption_translation::CaptionTranslation::translated_items(
            track.items(),
            translated,
            32,
            self.ids.as_mut(),
        )?;
        let name =
            sq_core_edit::caption_translation::CaptionTranslation::track_name(&track.name, base_language(target));
        let mut made = None;
        let ok = self.attempt_keyed_ids("Translate Captions", None, |t, ids| {
            let id = t.add_caption_track(ids);
            let Some(i) = t.caption_tracks.iter().position(|c| c.id == id) else { return Ok(()) };
            t.caption_tracks[i].name = name.clone();
            t.caption_tracks[i].style_ref = track.style_ref.clone();
            t.caption_tracks[i].animation_ref = track.animation_ref.clone();
            t.caption_tracks[i].karaoke = track.karaoke.clone();
            t.replace_captions(items, Some(id), ids)?;
            made = Some(id);
            Ok(())
        });
        if let (true, Some(m)) = (ok, made) {
            self.caption_track_focus = Some(m);
            self.notify(Change::SELECTION);
            Some(m)
        } else {
            None
        }
    }
}

/// The language part of a BCP-47 code ("de-AT" -> "de").
fn base_language(code: &str) -> &str {
    code.split(['-', '_']).next().unwrap_or(code)
}
