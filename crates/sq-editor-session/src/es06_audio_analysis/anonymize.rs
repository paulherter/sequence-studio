// Swift: EditorSession+Anonymize.swift
//! F7.11 Anonymize: covers people of one clip with a Mosaic or a blur limited to tracked Magic masks. The analysis runs
//! in the host; this is the clip choice and the one undo step that writes the result.

use sq_core_edit::timeline_replace::TimelineReplaceExt;
use sq_core_effects::effects_editing::ClipEffectsEditingExt;
use sq_core_masks::anonymize::{AnonymizeCheck, AnonymizeCover};
use sq_core_model::{AnonymizeTarget, Clip, ClipSpeed, EditError, FieldOrder, MagicSelection, PixelAspect, SpeedKeys};
use sq_core_time::{Id, Time, TimeRange};

use super::helpers::timecode;
use crate::EditorSession;

/// What an Anonymize run works on, captured when the command starts (the analysis runs off the main thread; the clip
/// may be edited meanwhile).
// Swift: EditorSession+Anonymize.swift:6
#[derive(Clone, Debug, PartialEq)]
pub struct AnonymizeRequest {
    // Swift: EditorSession+Anonymize.swift:7
    pub timeline: Id,
    // Swift: EditorSession+Anonymize.swift:8
    pub clip: Id,
    // Swift: EditorSession+Anonymize.swift:9
    pub clip_name: String,
    // Swift: EditorSession+Anonymize.swift:10
    pub media: Id,
    // Swift: EditorSession+Anonymize.swift:11
    pub path: String,
    /// Source seconds of the clip's first frame (the lower end of what it shows).
    // Swift: EditorSession+Anonymize.swift:13
    pub first: f64,
    /// Source seconds of the clip's last frame (the upper end of what it shows).
    // Swift: EditorSession+Anonymize.swift:14
    pub last: f64,
    /// Source seconds of the frame the people are picked on (the playhead's, else the clip's first).
    // Swift: EditorSession+Anonymize.swift:16
    pub anchor: f64,
    /// Seconds between two frames of the sequence.
    // Swift: EditorSession+Anonymize.swift:18
    pub frame_gap: f64,
    // Swift: EditorSession+Anonymize.swift:19
    pub picture_width: i64,
    // Swift: EditorSession+Anonymize.swift:20
    pub picture_height: i64,
    /// The media item's `display_pixel_aspect`: the people are found in the picture as it is shown.
    // Swift: EditorSession+Anonymize.swift (the media item's `displayPixelAspect`)
    pub pixel_aspect: PixelAspect,
    /// The media item's `deinterlace_field_order`: frames are analyzed deinterlaced (`None` = as stored).
    // Swift: EditorSession+Anonymize.swift (the media item's `deinterlaceFieldOrder`)
    pub deinterlace: Option<FieldOrder>,
    /// Which source frames the clip showed when the run started: the result is applied only to a clip that still shows them.
    // Swift: EditorSession+Anonymize.swift:22
    pub timing: AnonymizeTiming,
}

/// What decides which source frames a clip shows.
// Swift: EditorSession+Anonymize.swift:26
#[derive(Clone, Debug, PartialEq)]
pub struct AnonymizeTiming {
    // Swift: EditorSession+Anonymize.swift:27
    pub source: TimeRange,
    // Swift: EditorSession+Anonymize.swift:28
    pub speed: ClipSpeed,
    // Swift: EditorSession+Anonymize.swift:29
    pub reversed: bool,
    // Swift: EditorSession+Anonymize.swift:30
    pub speed_keys: Option<SpeedKeys>,
    // Swift: EditorSession+Anonymize.swift:31
    pub hold_frame: Option<Time>,
}

impl AnonymizeTiming {
    // Swift: EditorSession+Anonymize.swift:32
    pub fn new(c: &Clip) -> AnonymizeTiming {
        AnonymizeTiming {
            source: c.source,
            speed: c.speed,
            reversed: c.reversed,
            speed_keys: c.speed_keys.clone(),
            hold_frame: c.hold_frame,
        }
    }
}

/// What `apply_anonymize` did. Anything but `Applied` changed nothing.
// Swift: EditorSession+Anonymize.swift:41
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AnonymizeApplyResult {
    Applied,
    /// The clip is gone, on a locked track or shows other media now.
    ClipGone,
    /// The clip was trimmed, slipped, retimed or reversed during the run: the followed frames are not the ones it shows.
    ClipRetimed,
}

impl AnonymizeApplyResult {
    // Swift: EditorSession+Anonymize.swift:45
    pub fn applied(self) -> bool {
        self == AnonymizeApplyResult::Applied
    }

    /// What the user reads when nothing was written.
    // Swift: EditorSession+Anonymize.swift:49
    pub fn message(self) -> &'static str {
        match self {
            AnonymizeApplyResult::Applied => "",
            AnonymizeApplyResult::ClipGone => {
                "Anonymize: the clip was removed or locked meanwhile. Nothing was changed."
            }
            AnonymizeApplyResult::ClipRetimed => {
                "The clip was trimmed, slipped or retimed while Anonymize was following the people, so the result does not fit the frames it shows now. Nothing was changed. Run Anonymize again."
            }
        }
    }
}

/// One line of the list for a manual check after Anonymize.
// Swift: EditorSession+Anonymize.swift:59
#[derive(Clone, Debug, PartialEq)]
pub struct AnonymizeCheckLine {
    /// Sequence time of the first frame.
    // Swift: EditorSession+Anonymize.swift:61
    pub time: Time,
    // Swift: EditorSession+Anonymize.swift:62
    pub text: String,
    /// The person may be outside the cover here: listed first, never cut from the list.
    // Swift: EditorSession+Anonymize.swift:64
    pub critical: bool,
}

impl AnonymizeCheckLine {
    // Swift: EditorSession+Anonymize.swift:65
    pub fn new(time: Time, text: &str, critical: bool) -> AnonymizeCheckLine {
        AnonymizeCheckLine { time, text: text.to_string(), critical }
    }

    /// The lines a list of at most `limit` uncritical lines shows: every critical line, first, then the others in time
    /// order up to `limit`; `more` = how many uncritical lines are left out.
    // Swift: EditorSession+Anonymize.swift:70
    pub fn shown(lines: &[AnonymizeCheckLine], limit: usize) -> (Vec<AnonymizeCheckLine>, usize) {
        let mut critical: Vec<_> = lines.iter().filter(|l| l.critical).cloned().collect();
        let mut rest: Vec<_> = lines.iter().filter(|l| !l.critical).cloned().collect();
        critical.sort_by_key(|l| l.time);
        rest.sort_by_key(|l| l.time);
        let more = rest.len().saturating_sub(limit);
        rest.truncate(limit);
        critical.extend(rest);
        (critical, more)
    }
}

impl EditorSession {
    /// The clip Anonymize works on: of the command clips with media video (selection, else under the playhead) the one
    /// under the playhead, else the first.
    // Swift: EditorSession+Anonymize.swift:82
    pub fn anonymize_target(&self) -> Option<Clip> {
        let c = self.reframe_targets();
        c.iter().find(|c| c.timeline().contains(self.playhead)).or_else(|| c.first()).cloned()
    }

    // Swift: EditorSession+Anonymize.swift:86
    pub fn anonymize_request(&self) -> Option<AnonymizeRequest> {
        let t = self.active_timeline()?;
        let c = self.anonymize_target()?;
        let m = self.project().media(c.media)?;
        let (width, height) = self.project().picture_size(&c)?;
        let seconds = |local: Time| {
            let s = c.source_instant(local);
            s.value() as f64 / s.timescale().max(1) as f64
        };
        let fd = t.frame_duration();
        let last_local = (c.duration() - fd).max(Time::ZERO);
        let (a, b) = (seconds(Time::ZERO), seconds(last_local));
        let (mut lo, mut hi) = (a.min(b), a.max(b));
        // A speed ramp can run backward in the middle of the clip: the earliest and latest source frame it shows are
        // then not its edge frames, so every frame is asked.
        if c.speed_keys.is_some() && fd > Time::ZERO {
            let mut local = Time::ZERO;
            while local <= last_local {
                let v = seconds(local);
                lo = lo.min(v);
                hi = hi.max(v);
                local += fd;
            }
        }
        let at =
            if c.timeline().contains(self.playhead) { seconds(self.playhead - c.start) } else { seconds(Time::ZERO) };
        Some(AnonymizeRequest {
            timeline: t.id,
            clip: c.id,
            clip_name: c.name.clone(),
            media: m.id,
            path: m.path.clone(),
            first: lo,
            last: hi,
            anchor: at.max(lo).min(hi),
            frame_gap: fd.value() as f64 / fd.timescale().max(1) as f64,
            picture_width: width,
            picture_height: height,
            pixel_aspect: m
                .info
                .as_ref()
                .and_then(|i| i.video.as_ref())
                .map_or(PixelAspect::square(), |v| v.display_pixel_aspect()),
            deinterlace: m.info.as_ref().and_then(|i| i.video.as_ref()).and_then(|v| v.deinterlace_field_order()),
            timing: AnonymizeTiming::new(&c),
        })
    }

    /// Writes the masks and the cover into the clip as one undo step. Nothing is written when the clip is gone, on a
    /// locked track, shows other media now, or shows other source frames than when the run started.
    // Swift: EditorSession+Anonymize.swift:112
    pub fn apply_anonymize(
        &mut self,
        picks: &[MagicSelection],
        target: AnonymizeTarget,
        cover: AnonymizeCover,
        subject_width: f64,
        r: &AnonymizeRequest,
    ) -> AnonymizeApplyResult {
        let now = self.project().timeline(r.timeline).and_then(|t| {
            t.tracks
                .iter()
                .find(|tr| !tr.is_locked && tr.clips().iter().any(|c| c.id == r.clip && c.media == r.media))
                .and_then(|tr| tr.clip(r.clip))
        });
        let Some(now) = now else { return AnonymizeApplyResult::ClipGone };
        if picks.is_empty() {
            return AnonymizeApplyResult::ClipGone;
        }
        if AnonymizeTiming::new(now) != r.timing {
            return AnonymizeApplyResult::ClipRetimed;
        }
        let mut applied = false;
        let done = self.with_ids(|s, ids| {
            s.try_perform("Anonymize", None, |p| {
                p.edit(r.timeline, |t| {
                    applied = false;
                    let locked: Vec<bool> = t.tracks.iter().map(|tr| tr.is_locked).collect();
                    for (i, is_locked) in locked.into_iter().enumerate() {
                        if is_locked {
                            continue;
                        }
                        let Some(c) = t.tracks[i].clip(r.clip).cloned() else { continue };
                        let mut n = c;
                        n.add_anonymize(picks, target, cover, subject_width, (r.picture_width, r.picture_height), ids);
                        t.replace_clip(n)?;
                        applied = true;
                    }
                    Ok::<(), EditError>(())
                })
            })
        });
        if done.is_err() || !applied { AnonymizeApplyResult::ClipGone } else { AnonymizeApplyResult::Applied }
    }

    /// The check list as sequence times (a range that lies outside the clip now is left out). Ranges where the person
    /// may be outside the cover come first, then by time.
    // Swift: EditorSession+Anonymize.swift:140
    pub fn anonymize_check_lines(&self, checks: &[AnonymizeCheck], r: &AnonymizeRequest) -> Vec<AnonymizeCheckLine> {
        let Some(t) = self.project().timeline(r.timeline) else { return Vec::new() };
        let Some(c) = t.tracks.iter().find_map(|tr| tr.clip(r.clip)) else { return Vec::new() };
        let fd = t.frame_duration();
        let time = |s: f64| c.timeline_time_for_source(Time::new((s * 90_000.0).round() as i64, 90_000), fd);
        let mut out: Vec<AnonymizeCheckLine> = checks
            .iter()
            .filter_map(|k| {
                let (a, b) = (time(k.from), time(k.to));
                let (from, to) = (a.min(b), a.max(b));
                if !(to >= c.start && from < c.start + c.duration()) {
                    return None;
                }
                let tc = timecode(from, fd);
                let range = if to > from { format!("{tc} to {}", timecode(to, fd)) } else { tc };
                Some(AnonymizeCheckLine {
                    time: from.max(c.start),
                    text: format!("{range}  Person {}: {}", k.person + 1, k.reason.text()),
                    critical: k.reason.is_critical(),
                })
            })
            .collect();
        out.sort_by(|a, b| b.critical.cmp(&a.critical).then(a.time.cmp(&b.time)));
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(t: i64, critical: bool) -> AnonymizeCheckLine {
        AnonymizeCheckLine::new(Time::new(t, 1), "x", critical)
    }

    #[test]
    fn shown_lists_critical_first_then_time_order_up_to_the_limit() {
        let lines = [line(5, false), line(3, true), line(1, false), line(2, false), line(1, true)];
        let (shown, more) = AnonymizeCheckLine::shown(&lines, 2);
        let times: Vec<i64> = shown.iter().map(|l| l.time.value()).collect();
        assert_eq!(times, vec![1, 3, 1, 2]);
        assert_eq!(more, 1);
        assert_eq!(AnonymizeCheckLine::shown(&lines, 0).1, 3);
    }

    #[test]
    fn apply_results_speak() {
        assert!(AnonymizeApplyResult::Applied.applied() && AnonymizeApplyResult::Applied.message().is_empty());
        assert!(!AnonymizeApplyResult::ClipGone.applied());
        assert!(AnonymizeApplyResult::ClipRetimed.message().contains("Run Anonymize again"));
    }
}
