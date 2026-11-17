// Swift: EditorSession+DisguiseVoice.swift
//! Disguise Voice: the selected audio clips are cut at the range's edges, the parts inside get the effect, and captions
//! are made for exactly that range from a transcript.

use std::collections::BTreeSet;

use sq_core_audio::audio_effects::AudioDisguiseValues;
use sq_core_audio::{TimelineCaptionEditsExt as _, TimelineCaptionsExt as _};
use sq_core_edit::timeline_disguise_voice::{DisguiseVoiceFailure, TimelineDisguiseVoiceExt as _};
use sq_core_model::{CaptionItem, CaptionWord, EditError};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use sq_transcribe::caption_preset::CaptionPreset;
use sq_transcribe::caption_segmenter::CaptionSegmenter;
use sq_transcribe::transcript::Transcript;
use sq_uikit::editor_command::EditorCommand;

use super::helpers::timecode;
use crate::EditorSession;

/// Captions for a disguised range: only the transcript words that sound inside it, never anything outside.
// Swift: EditorSession+DisguiseVoice.swift:7
pub enum DisguiseVoiceCaptions {}

impl DisguiseVoiceCaptions {
    /// `transcript` holds sequence-time words. Words reaching into `range` are clamped to it, segmented with `preset`,
    /// and the captions are put on frames. `range` must lie on frames; every item ends up inside it.
    // Swift: EditorSession+DisguiseVoice.swift:10
    pub fn items(
        transcript: &Transcript,
        preset: &CaptionPreset,
        range: TimeRange,
        frame_duration: Time,
        ids: &mut dyn IdSource,
    ) -> Vec<CaptionItem> {
        let words: Vec<_> = transcript
            .words
            .iter()
            .filter_map(|w| {
                let hit = w.range.intersection(&range).filter(|h| !h.is_empty())?;
                let mut out = w.clone();
                out.range = hit;
                Some(out)
            })
            .collect();
        if words.is_empty() {
            return Vec::new();
        }
        let part = Transcript::new(&transcript.language, words);
        let captions = CaptionSegmenter::apply_timing(&CaptionSegmenter::segment(&part, preset), preset);
        // Timing rules (minimum duration, closed gaps) may push a caption past the range: cut it back.
        let items: Vec<CaptionItem> = captions
            .iter()
            .filter_map(|c| {
                let r = c.range.intersection(&range).filter(|r| !r.is_empty())?;
                Some(CaptionItem {
                    id: ids.next_id(),
                    lines: c.lines.clone(),
                    range: r,
                    style_ref: c.style_ref.clone(),
                    animation_ref: c.animation_ref.clone(),
                    style_overridden: false,
                    words: c
                        .words
                        .iter()
                        .map(|w| CaptionWord {
                            text: w.text.clone(),
                            range: Self::relative(w.range, r),
                            confidence: w.confidence,
                        })
                        .collect(),
                    position: None,
                })
            })
            .collect();
        crate::CaptionMapping::snapped(&items, frame_duration)
            .into_iter()
            .filter_map(|it| {
                if it.range.start >= range.end() {
                    return None;
                }
                if it.range.end() <= range.end() {
                    return Some(it);
                }
                let mut out = it.clone();
                out.range = TimeRange::from_end(it.range.start, range.end());
                let whole = TimeRange::from_end(Time::ZERO, out.range.duration);
                out.words = it
                    .words
                    .iter()
                    .map(|w| CaptionWord {
                        text: w.text.clone(),
                        range: Self::relative(w.range, whole),
                        confidence: w.confidence,
                    })
                    .collect();
                Some(out)
            })
            .collect()
    }

    /// `r` clamped to `outer`, counted from `outer.start`.
    fn relative(r: TimeRange, outer: TimeRange) -> TimeRange {
        let a = r.start.max(outer.start).min(outer.end());
        let b = r.end().max(a).min(outer.end());
        TimeRange::from_end(a - outer.start, b - outer.start)
    }
}

/// What Disguise Voice did.
// Swift: EditorSession+DisguiseVoice.swift:46
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DisguiseVoiceOutcome {
    /// The disguised range in sequence time.
    // Swift: EditorSession+DisguiseVoice.swift:48
    pub range: TimeRange,
    /// Clip parts that carry the effect now.
    // Swift: EditorSession+DisguiseVoice.swift:50
    pub clips: i64,
    /// Captions created for the range (0 without a transcript, or when no word sounds inside it).
    // Swift: EditorSession+DisguiseVoice.swift:52
    pub captions: i64,
    /// The caption track is locked: the voice was disguised, captions were left alone.
    // Swift: EditorSession+DisguiseVoice.swift:54
    pub caption_track_locked: bool,
}

impl DisguiseVoiceOutcome {
    /// The status line: what was disguised (clip parts, range as timecodes), what happened to the captions, and the one
    /// honest sentence about what the effect is. `has_transcript` = a current transcript was at hand.
    // Swift: EditorSession+DisguiseVoice.swift:58
    pub fn status_text(&self, frame_duration: Time, has_transcript: bool) -> String {
        let fd = frame_duration;
        let span = format!("{} to {}", timecode(self.range.start, fd), timecode(self.range.end(), fd));
        let what = if self.clips == 1 {
            format!("Disguise Voice on {} clip, {span}.", self.clips)
        } else {
            format!("Disguise Voice on {} clips, {span}.", self.clips)
        };
        let text = if self.caption_track_locked {
            "No captions: the caption track is locked.".to_string()
        } else if self.captions > 0 {
            if self.captions == 1 {
                format!("{} caption created.", self.captions)
            } else {
                format!("{} captions created.", self.captions)
            }
        } else if !has_transcript {
            "Captions need a current transcript: transcribe in the Text panel, then run Disguise Voice again."
                .to_string()
        } else {
            "The transcript has no words in this range, so no captions were created.".to_string()
        };
        [what, text, AudioDisguiseValues::HINT.to_string()].join(" ")
    }
}

impl EditorSession {
    /// What Disguise Voice acts on: In to Out when it reaches every selected audio clip (an In/Out left over from other
    /// work must not decide), else the span of the selected audio clips. Widened to whole frames (start down, end up), so
    /// no part of a frame keeps the original voice. `None` when no audio clip is selected.
    // Swift: EditorSession+DisguiseVoice.swift:78
    pub fn disguise_voice_range(&self) -> Option<TimeRange> {
        let t = self.active_timeline()?;
        let clips = self.selected_audio_clips();
        let first = clips.first()?;
        let fd = t.frame_duration();
        let on_frames = |r: TimeRange| {
            let out = TimeRange::from_end(
                if fd > Time::ZERO { fd * r.start.frame_index(fd) } else { r.start },
                r.end().ceiled(fd),
            );
            (!out.is_empty()).then_some(out)
        };
        if let Some(io) = t.in_out
            && clips.iter().all(|c| c.timeline().overlaps(&io))
            && let Some(r) = on_frames(io)
        {
            return Some(r);
        }
        let span = clips.iter().fold(first.timeline(), |a, c| {
            TimeRange::from_end(a.start.min(c.timeline().start), a.end().max(c.timeline().end()))
        });
        on_frames(span)
    }

    /// Disguise Voice: the selected audio clips are cut at the range's edges, the parts inside get the Disguise Voice
    /// effect, and captions are made for exactly that range from `transcript` (sequence-time words), all in one undo
    /// step. Without a transcript only the effect is applied; this never starts a transcription. Existing captions that
    /// overlap a new one are replaced, the others stay. A locked caption track never stops the disguise: the captions are
    /// skipped and the outcome says so. `None` when nothing changed (`last_error` says why if it was refused).
    // Swift: EditorSession+DisguiseVoice.swift:97
    pub fn disguise_voice(
        &mut self,
        transcript: Option<&Transcript>,
        preset: Option<&CaptionPreset>,
        voice: i64,
    ) -> Option<DisguiseVoiceOutcome> {
        let t = self.active_timeline()?;
        let range = self.disguise_voice_range()?;
        let clips: BTreeSet<Id> = self.selected_audio_clips().iter().map(|c| c.id).collect();
        let fd = t.frame_duration();
        // `replace_captions` without a track writes to the first one.
        let target = self.current_caption_track().map(|c| c.id);
        let locked =
            target.and_then(|id| t.caption_track(id)).or_else(|| t.caption_tracks.first()).is_some_and(|c| c.is_locked);
        let standard = CaptionPreset::standard();
        let items = match (locked, transcript) {
            (false, Some(tr)) => {
                self.with_ids(|_, ids| DisguiseVoiceCaptions::items(tr, preset.unwrap_or(&standard), range, fd, ids))
            }
            _ => Vec::new(),
        };
        let mut parts = 0;
        let mut linked_locked = None;
        let done = self.attempt_ids("Disguise Voice", |t, ids| {
            parts = match t.disguise_voice(range, &clips, voice, ids) {
                Ok(p) => p.len() as i64,
                Err(DisguiseVoiceFailure::Edit(e)) => return Err(e),
                Err(DisguiseVoiceFailure::Linked(e)) => {
                    linked_locked = Some(e);
                    return Err(EditError::TrackLocked);
                }
            };
            if items.is_empty() {
                return Ok(());
            }
            let existing: Vec<CaptionItem> =
                target.and_then(|id| t.caption_track(id)).map(|c| c.items().to_vec()).unwrap_or_default();
            let kept = existing.into_iter().filter(|e| !items.iter().any(|i| i.range.overlaps(&e.range)));
            let all: Vec<CaptionItem> = kept.chain(items.iter().cloned()).collect();
            t.replace_captions(all, target, ids).map(|_| ())
        });
        if let Some(e) = linked_locked {
            self.set_error(e.to_string());
        }
        done.then_some(DisguiseVoiceOutcome {
            range,
            clips: parts,
            captions: items.len() as i64,
            caption_track_locked: locked,
        })
    }
}

/// The second line under a menu item, for commands whose name alone would promise too much.
// Swift: EditorSession+DisguiseVoice.swift:121
pub fn editor_command_menu_help(command: EditorCommand) -> Option<&'static str> {
    match command {
        EditorCommand::DisguiseVoice => Some(AudioDisguiseValues::HINT),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::SequentialIds;
    use sq_transcribe::transcript::TranscriptWord;

    fn t(ms: i64) -> Time {
        Time::new(ms, 1000)
    }

    fn word(ids: &mut SequentialIds, text: &str, a: i64, b: i64) -> TranscriptWord {
        TranscriptWord::new(ids.next_id(), text, TimeRange::from_end(t(a), t(b)))
    }

    #[test]
    fn only_words_inside_the_range_get_captions_and_every_item_ends_inside() {
        let mut ids = SequentialIds::default();
        let words = vec![
            word(&mut ids, "before", 0, 400),
            word(&mut ids, "inside", 1000, 1500),
            word(&mut ids, "again", 1600, 2100),
            word(&mut ids, "after", 4000, 4400),
        ];
        let tr = Transcript::new("en-US", words);
        let range = TimeRange::from_end(t(900), t(2000));
        let items = DisguiseVoiceCaptions::items(&tr, &CaptionPreset::standard(), range, Time::new(1, 25), &mut ids);
        assert!(!items.is_empty());
        for it in &items {
            assert!(it.range.start >= range.start && it.range.end() <= range.end(), "{:?}", it.range);
            assert!(!it.lines.join(" ").contains("before") && !it.lines.join(" ").contains("after"));
        }
        let none = DisguiseVoiceCaptions::items(
            &tr,
            &CaptionPreset::standard(),
            TimeRange::from_end(t(2500), t(3500)),
            Time::new(1, 25),
            &mut ids,
        );
        assert!(none.is_empty());
    }

    #[test]
    fn status_text_says_what_happened_to_the_captions() {
        let o = DisguiseVoiceOutcome {
            range: TimeRange::from_end(t(0), t(2000)),
            clips: 1,
            captions: 0,
            caption_track_locked: false,
        };
        let fd = Time::new(1, 25);
        assert!(o.status_text(fd, false).contains("Captions need a current transcript"));
        assert!(o.status_text(fd, true).contains("no words in this range"));
        let o2 = DisguiseVoiceOutcome { captions: 2, clips: 3, ..o };
        let s = o2.status_text(fd, true);
        assert!(
            s.starts_with("Disguise Voice on 3 clips, 00:00:00:00 to 00:00:02:00.")
                && s.contains("2 captions created.")
        );
        let o3 = DisguiseVoiceOutcome { caption_track_locked: true, ..o };
        assert!(o3.status_text(fd, true).contains("caption track is locked"));
        assert!(s.ends_with(AudioDisguiseValues::HINT));
    }

    #[test]
    fn only_disguise_voice_has_menu_help() {
        assert_eq!(editor_command_menu_help(EditorCommand::DisguiseVoice), Some(AudioDisguiseValues::HINT));
        assert_eq!(editor_command_menu_help(EditorCommand::Undo), None);
    }
}
