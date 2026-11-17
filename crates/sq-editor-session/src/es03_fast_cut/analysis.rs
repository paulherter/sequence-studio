//! Commands that run an analysis or a planner over the active sequence: jump cut, Check Cuts, Fit Music to Length,
//! Markers on Beat, Dynamic Zoom, filler words, Punch In and Punch In Cuts. One undo step each.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use sq_analysis::beat_detector::BeatSettings;
use sq_analysis::beat_grid::BeatGrid;
use sq_analysis::music_fit::{MusicFit, Settings as MusicFitSettings, Version as MusicFitVersion};
use sq_core_audio::filler_words::{FillerScan, FillerWords};
use sq_core_edit::cut_check::{
    CaptionBounds, CutCheck, CutCheckPlatform, CutCheckTimelineExt, CutFinding, CutFindingKind, EditStats, NormRect,
};
use sq_core_edit::jump_cut::{JumpCut, TimelineJumpCutExt};
use sq_core_edit::proposed_cuts::ProposedCutKind;
use sq_core_edit::punch_in::{PunchIn, PunchInTimelineExt};
use sq_core_edit::punch_in_cuts::{PunchInCutsOptions, TimelinePunchInCutsExt};
use sq_core_edit::timeline_beat_markers::TimelineBeatMarkersExt;
use sq_core_effects::dynamic_zoom::{DynamicZoom, ZoomEase, ZoomRect};
use sq_core_effects::transition::{NewTransition, TimelineTransitions};
use sq_core_model::{
    CaptionItem, Clip, EditError, FadeMarks, SequenceFormat, TrackKind, TransitionAlignment, TransitionKind,
};
use sq_core_time::{Id, Time, TimeRange, Vec2};
use sq_library::library_folder_store::SettingsStore;
use sq_media::channel_mapped_source::ANALYSIS_SAMPLE_RATE;
use sq_runtime::UiRef;

use super::clip_in;
use crate::{EditorSession, SessionRoot};

// MARK: Jump cut

/// UserDefaults key of the jump cut overlap (decimal text in the settings store).
pub const JUMP_CUT_OVERLAP_KEY: &str = "sq.jumpCut.overlapFrames";

impl EditorSession {
    /// Overlap in frames: `sq.jumpCut.overlapFrames` when set, else 0.3 s of the active sequence.
    // Swift: EditorSession+JumpCut.swift:7
    pub fn jump_cut_overlap_frames(&self, settings: &dyn SettingsStore) -> i64 {
        let stored = settings
            .data(JUMP_CUT_OVERLAP_KEY)
            .and_then(|b| String::from_utf8(b).ok())
            .and_then(|s| s.trim().parse::<i64>().ok())
            .filter(|n| *n >= 0);
        stored.unwrap_or_else(|| {
            JumpCut::default_overlap_frames(
                self.active_timeline().map_or(Time::new(1, 30), |t| t.format.frame_duration),
            )
        })
    }

    /// Cuts at the playhead (edit target rule) and moves the rest to the alternate track. The moved halves become the
    /// selection, so the next press cuts the same take again and sends it back. Returns whether anything changed.
    // Swift: EditorSession+JumpCut.swift:14
    pub fn jump_cut_alternate(&mut self, overlap_frames: Option<i64>, settings: &dyn SettingsStore) -> bool {
        if self.active_timeline().is_none() {
            return false;
        }
        let (at, sel) = (self.playhead, self.selection.clone());
        let n = overlap_frames.unwrap_or_else(|| self.jump_cut_overlap_frames(settings));
        let mut moved: Vec<Id> = Vec::new();
        if !self.attempt_keyed_ids("Jump Cut", None, |t, src| {
            moved = t.jump_cut_alternate(at, &sel, n, src)?;
            Ok(())
        }) {
            return false;
        }
        self.select(moved.into_iter().collect(), BTreeSet::new());
        true
    }

    /// Status-line text when a jump cut at the playhead cannot run, `None` when it can.
    // Swift: EditorSession+JumpCut.swift:25
    pub fn jump_cut_refusal(&self) -> Option<String> {
        let Some(t) = self.active_timeline() else { return Some("No sequence open.".to_string()) };
        if !t.jump_cut_candidates(self.playhead, &self.selection).is_empty() {
            return None;
        }
        if t.is_jump_cut(self.playhead, &self.selection) {
            return Some("Already jump cut at the playhead. Move the playhead first.".to_string());
        }
        Some("No clip under the playhead to jump cut.".to_string())
    }

    // Swift: EditorSession+JumpCut.swift:31
    pub fn jump_cut_enabled(&self) -> bool {
        self.active_timeline().is_some_and(|t| !t.jump_cut_candidates(self.playhead, &self.selection).is_empty())
    }
}

// MARK: Check Cuts

/// What Check Cuts found, for the stats sheet.
// Swift: EditorSession+CutCheck.swift:6
#[derive(Clone, Debug, PartialEq)]
pub struct CutCheckReport {
    // Swift: EditorSession+CutCheck.swift:7
    pub findings: Vec<CutFinding>,
    // Swift: EditorSession+CutCheck.swift:8
    pub stats: EditStats,
    // Swift: EditorSession+CutCheck.swift:9
    pub platform: CutCheckPlatform,
}

impl CutCheckReport {
    // Swift: EditorSession+CutCheck.swift:10
    pub fn count(&self, k: CutFindingKind) -> usize {
        self.findings.iter().filter(|f| f.kind == k).count()
    }

    /// The two note lines of the Check Cuts sheet: shots and average, then the findings that exist.
    // Swift: EditorSession+CutCheck.swift:13
    pub fn board_summary(&self) -> String {
        let s = &self.stats;
        let first = format!("{} shots \u{00B7} average shot {:.1} s", s.shot_count, s.average_shot_seconds);
        let n = |k: CutFindingKind, one: &str, many: &str| {
            let c = self.count(k);
            (c != 0).then(|| format!("{c} {}", if c == 1 { one } else { many }))
        };
        let parts: Vec<String> = [
            n(CutFindingKind::JumpCut, "jump cut", "jump cuts"),
            n(CutFindingKind::Gap, "gap", "gaps"),
            n(
                CutFindingKind::CaptionOutsideSafeZone,
                "caption outside the safe zone",
                "captions outside the safe zone",
            ),
            n(CutFindingKind::AudioPop, "audio pop", "audio pops"),
        ]
        .into_iter()
        .flatten()
        .collect();
        let second = if parts.is_empty() { "No findings".to_string() } else { parts.join(" \u{00B7} ") };
        format!("{first}\n{second}")
    }

    /// Plain-text summary (the sheet draws the histogram itself).
    // Swift: EditorSession+CutCheck.swift:26
    pub fn summary(&self) -> String {
        let mut lines: Vec<String> =
            CutFindingKind::ALL.iter().map(|k| format!("{}: {}", k.title(), self.count(*k))).collect();
        let s = &self.stats;
        lines.push(String::new());
        lines.push(format!("{} shots, {} cuts, {:.1} cuts per minute", s.shot_count, s.cuts, s.cuts_per_minute));
        lines.push(format!(
            "Shot length: average {:.1} s, shortest {:.1} s, longest {:.1} s",
            s.average_shot_seconds, s.shortest_shot_seconds, s.longest_shot_seconds
        ));
        lines.join("\n")
    }
}

impl EditorSession {
    /// A caption's drawn box as a fraction of the frame (origin top-left).
    // Swift: EditorSession+CutCheck.swift:39
    pub fn caption_box(item: &CaptionItem, canvas: &SequenceFormat) -> NormRect {
        let f = canvas.layout_format(); // display canvas: the rect is in display px
        let r =
            crate::CaptionMonitorHit::text_rect(item, &f, &sq_text::caption_presets::CaptionPresetLibrary::built_in());
        let (w, h) = (f.width as f64, f.height as f64);
        NormRect { x: (r.x + w / 2.0) / w, y: (r.y + h / 2.0) / h, width: r.width / w, height: r.height / h }
    }

    /// Runs the analysis against `platform`'s safe zone (mapped into the frame, so landscape sequences are checked too)
    /// and replaces the markers of the last run (one undo step; re-runs from the sheet's platform picker coalesce into
    /// it). `caption_bounds` gives a caption's drawn box (`caption_box`); `None` skips the caption check. `None` result
    /// without an active sequence.
    // Swift: EditorSession+CutCheck.swift:49
    pub fn run_cut_check(
        &mut self,
        platform: CutCheckPlatform,
        caption_bounds: Option<&CaptionBounds>,
    ) -> Option<CutCheckReport> {
        let t = self.active_timeline()?;
        let f = &t.format;
        let aspect = if f.height > 0 { f.display_width() as f64 / f.height as f64 } else { 9.0 / 16.0 };
        let findings = CutCheck::analyze(t, Some(platform), aspect, caption_bounds);
        let stats = CutCheck::stats(t);
        self.attempt_keyed_ids("Check Cuts", Some("cutcheck"), |t, src| {
            t.apply_cut_check(&findings, src);
            Ok(())
        });
        Some(CutCheckReport { findings, stats, platform })
    }
}

// MARK: Fit Music to Length

impl EditorSession {
    /// "Version 1: 30.0 s, exact, cut 2 bars" for a row of the Fit Music dialog.
    // Swift: EditorSession+MusicFit.swift:9
    pub fn music_fit_row_title(v: &MusicFitVersion, index: usize) -> String {
        let seconds = |t: Time| t.value() as f64 / t.timescale() as f64;
        let err = seconds(v.length_error);
        let fit = if err.abs() < 0.05 {
            "exact".to_string()
        } else {
            format!("{}{:.1} s", if err > 0.0 { "+" } else { "-" }, err.abs())
        };
        let bars = if v.jump_bars == 1 { "1 bar".to_string() } else { format!("{} bars", v.jump_bars) };
        format!(
            "Version {}: {:.1} s, {}, {} {}",
            index + 1,
            seconds(v.length),
            fit,
            if v.removes_audio { "cut" } else { "loop" },
            bars
        )
    }

    /// The one selected audio clip Fit Music works on: media audio at normal speed (retimed clips are refused).
    // Swift: EditorSession+MusicFit.swift:18
    pub fn music_fit_clip(&self) -> Option<Clip> {
        let mut c = self.selected_audio_clips();
        if c.len() != 1 {
            return None;
        }
        let clip = c.remove(0);
        (clip.speed.is_normal() && clip.speed_keys.is_none() && !clip.reversed && clip.sequence.is_none())
            .then_some(clip)
    }

    // Swift: EditorSession+MusicFit.swift:24
    pub fn can_fit_music(&self) -> bool {
        self.music_fit_clip().is_some()
    }

    /// Wanted clip length: the In/Out range when one is marked, else from the clip start to the sequence end.
    // The clip keeps its start; a range In that differs from it is not applied (Swift does the same).
    // Swift: EditorSession+MusicFit.swift:29
    pub fn music_fit_target(&self, clip: &Clip) -> Option<Time> {
        let t = self.active_timeline()?;
        if let Some(r) = t.in_out.filter(|r| r.duration > Time::ZERO) {
            return Some(r.duration);
        }
        let end = t.tracks.iter().map(|tr| tr.end()).max().unwrap_or(Time::ZERO);
        let len = end - clip.start;
        (len > Time::ZERO).then_some(len)
    }

    /// Up to three versions for the selected clip. `grid` is in media time; it is cut to the part the clip plays.
    // Swift: EditorSession+MusicFit.swift:38
    pub fn music_fit_versions(&self, grid: &BeatGrid, target: Option<Time>) -> Vec<MusicFitVersion> {
        let Some(clip) = self.music_fit_clip() else { return Vec::new() };
        let Some(want) = target.or_else(|| self.music_fit_target(&clip)) else { return Vec::new() };
        let window = clip.source;
        let idx: Vec<usize> = (0..grid.beats.len()).filter(|&i| window.contains(grid.beats[i])).collect();
        if idx.len() < 2 {
            return Vec::new();
        }
        let beats: Vec<Time> = idx.iter().map(|&i| grid.beats[i] - window.start).collect();
        let down: Vec<usize> =
            grid.downbeat_beat_indices.iter().filter_map(|d| idx.iter().position(|i| i == d)).collect();
        if down.len() < 2 {
            return Vec::new();
        }
        let local = BeatGrid { beats, downbeat_beat_indices: down, beats_per_bar: grid.beats_per_bar, bpm: grid.bpm };
        MusicFit::propose(&local, window.duration, want, &MusicFitSettings::default())
    }

    /// Replaces the clip by the version's pieces (the first keeps the clip ID) and puts a crossfade on every join.
    /// Refused (error message, no undo step) when the longer result would run into the next clip on the track.
    // Swift: EditorSession+MusicFit.swift:52
    pub fn apply_music_fit(&mut self, version: &MusicFitVersion, clip_id: Option<Id>) -> bool {
        let found = clip_id.and_then(|id| self.active_timeline().and_then(|t| clip_in(t, id)).cloned());
        let Some(clip) = found.or_else(|| self.music_fit_clip()) else { return false };
        if version.segments.is_empty() {
            return false;
        }
        let base = clip.source.start;
        // A join at the very start leaves an empty first segment: it is not a piece.
        let segments: Vec<_> = version.segments.iter().filter(|s| s.source.duration > Time::ZERO).collect();
        if segments.is_empty() {
            return false;
        }
        self.attempt_keyed_ids("Fit Music to Length", None, |t, src| {
            let ti = t
                .tracks
                .iter()
                .position(|tr| tr.clips().iter().any(|c| c.id == clip.id))
                .ok_or(EditError::ClipNotFound)?;
            let new_end = clip.start + version.length;
            if t.tracks[ti]
                .clips()
                .iter()
                .any(|c| c.id != clip.id && c.start < new_end && c.timeline().end() > clip.start)
            {
                return Err(EditError::Collision);
            }
            let mut pieces: Vec<Clip> = Vec::new();
            for (i, seg) in segments.iter().enumerate() {
                let mut p = clip.clone();
                if i > 0 {
                    p.id = src.next_id();
                    p.link = None;
                }
                p.source = TimeRange::from_end(base + seg.source.start, base + seg.source.end());
                p.start = clip.start + seg.output_start;
                if i > 0 {
                    p.audio_fades = FadeMarks::default();
                    p.duck_key_ids = Vec::new();
                }
                pieces.push(p);
            }
            let last_id = pieces[pieces.len() - 1].id;
            for tr in &mut t.tracks[ti].transitions {
                if tr.outgoing == Some(clip.id) {
                    tr.outgoing = Some(last_id);
                }
            }
            t.tracks[ti].remove(clip.id);
            for p in &pieces {
                t.tracks[ti].overwrite(p.clone(), src)?;
            }
            let track_id = t.tracks[ti].id;
            for w in pieces.windows(2) {
                // A join without handles keeps the plain cut: the audio is the same either way.
                let join = NewTransition {
                    kind: TransitionKind::ConstantPower,
                    track: track_id,
                    outgoing: Some(w[0].id),
                    incoming: Some(w[1].id),
                    duration: version.crossfade,
                    alignment: TransitionAlignment::Center,
                    custom_before: Time::ZERO,
                };
                let _ = t.add_transition(&join, src);
            }
            Ok(())
        })
    }
}

// MARK: Markers on Beat

/// Timeline times of the grid's beats (or only its downbeats) that `clip` actually plays: a beat is a source time, it is
/// mapped through the clip's speed, reverse and ramps, and dropped when the clip's source range does not hold it.
// Swift: EditorSession+BeatGrid.swift:11
pub fn beat_times_of(clip: &Clip, grid: &BeatGrid, downbeats_only: bool) -> Vec<Time> {
    let source = if downbeats_only { grid.downbeats() } else { grid.beats.clone() };
    let mut out: Vec<Time> = source
        .into_iter()
        .filter(|b| clip.source.contains(*b))
        .map(|b| clip.timeline_time_for_source(b, Time::ZERO))
        .filter(|t| clip.timeline().contains(*t))
        .collect();
    out.sort();
    out
}

/// The decode and tracker of `analyze_beats` on the calling thread: mono at the analysis rate (left and right averaged,
/// as `MonoAudioDecoder.mono` does), then the spectral beat tracker.
// Swift: EditorSession+BeatGrid.swift:29
fn analyze_beats_blocking(url: &Path) -> Option<BeatGrid> {
    let rate = ANALYSIS_SAMPLE_RATE;
    let pcm = sq_media_ffmpeg::shim::decode_audio(url, i32::try_from(rate).ok()?, 2).ok()?;
    let mono: Vec<f32> = pcm.samples.as_chunks::<2>().0.iter().map(|f| (f[0] + f[1]) * 0.5).collect();
    sq_analysis::beat_detector::analyze(&mono, rate, &BeatSettings::default())
}

impl EditorSession {
    /// Clips Markers on Beat analyzes: the selected audio clips, else the Music clips.
    // Swift: EditorSession+BeatGrid.swift:22
    pub fn beat_analysis_targets(&self) -> Vec<Clip> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        let chosen: Vec<Clip> = t
            .tracks
            .iter()
            .flat_map(|tr| tr.clips())
            .filter(|c| self.selection.contains(&c.id) && c.kind == TrackKind::Audio)
            .cloned()
            .collect();
        if chosen.is_empty() { self.music_duck_targets() } else { chosen }
    }

    /// Decodes the file and runs the beat tracker on a worker thread. `None`: no audio, too short or no pulse.
    // Swift: EditorSession+BeatGrid.swift:29
    pub async fn analyze_beats(url: PathBuf) -> Option<BeatGrid> {
        let (tx, mut rx) = sq_runtime::channel::unbounded();
        std::thread::spawn(move || tx.send(analyze_beats_blocking(&url)));
        rx.next().await.flatten()
    }

    /// Analyzes every `beat_analysis_targets` clip (one decode per media file). `url` gives a clip's media file.
    // Swift: EditorSession+BeatGrid.swift:41
    pub async fn beat_grids<R: SessionRoot + ?Sized>(
        h: UiRef<R>,
        url: impl Fn(&Clip) -> Option<PathBuf>,
    ) -> BTreeMap<Id, BeatGrid> {
        let Some(clips) = h.with(|r| r.session().beat_analysis_targets()) else { return BTreeMap::new() };
        let mut by_media: BTreeMap<Id, Option<BeatGrid>> = BTreeMap::new();
        let mut out = BTreeMap::new();
        for c in &clips {
            let grid = match by_media.get(&c.media) {
                Some(g) => g.clone(),
                None => {
                    let g = match url(c) {
                        Some(u) => Self::analyze_beats(u).await,
                        None => None,
                    };
                    by_media.insert(c.media, g.clone());
                    g
                }
            };
            if let Some(g) = grid {
                out.insert(c.id, g);
            }
        }
        out
    }

    /// Markers on Beat, one undo step: replaces the beat markers inside each analyzed clip's range. Returns the number
    /// of markers (0 with no clip in `grids`, and then no undo step).
    // Swift: EditorSession+BeatGrid.swift:57
    pub fn add_markers_on_beat(&mut self, grids: &BTreeMap<Id, BeatGrid>, downbeats_only: bool) -> usize {
        let found: Vec<(TimeRange, Vec<Time>)> = self
            .beat_analysis_targets()
            .iter()
            .filter_map(|c| grids.get(&c.id).map(|g| (c.timeline(), beat_times_of(c, g, downbeats_only))))
            .collect();
        if found.is_empty() {
            return 0;
        }
        let name = if downbeats_only { "Markers on Downbeats" } else { "Markers on Beat" };
        let mut total = 0;
        self.attempt_keyed_ids(name, None, |t, src| {
            total = 0;
            for (range, times) in &found {
                total += t.replace_beat_markers(*range, times, src);
            }
            Ok(())
        });
        total
    }
}

// MARK: Dynamic Zoom

impl EditorSession {
    /// The window a one-click Dynamic Zoom ends on (1.25 = 125 %).
    // Swift: EditorSession+DynamicZoom.swift:10
    pub const DYNAMIC_ZOOM_AMOUNT: f64 = 1.25;

    /// Dynamic Zoom (Ken Burns) on the selected clips (else the one under the playhead): media video clips with a known
    /// picture size on unlocked tracks. Zoom In goes from the whole picture to a centered window, Zoom Out the other way.
    // Swift: EditorSession+DynamicZoom.swift:13
    pub fn apply_dynamic_zoom(&mut self, zoom_in: bool, zoom: f64, ease: ZoomEase) -> bool {
        let targets = self.reframe_targets();
        if targets.is_empty() {
            return false;
        }
        let (near, far) = (ZoomRect::FULL, ZoomRect::centred(zoom, Vec2 { x: 0.5, y: 0.5 }));
        let (a, b) = if zoom_in { (near, far) } else { (far, near) };
        let sizes: BTreeMap<Id, Vec2> = targets
            .iter()
            .filter_map(|c| self.project().picture_size(c).map(|(w, h)| (c.id, Vec2 { x: w as f64, y: h as f64 })))
            .collect();
        self.attempt_keyed_ids("Dynamic Zoom", None, |t, src| {
            let mut changed = 0;
            for ti in 0..t.tracks.len() {
                if t.tracks[ti].is_locked {
                    continue;
                }
                for c in t.tracks[ti].clips().to_vec() {
                    let Some(size) = sizes.get(&c.id) else { continue };
                    let mut n = c.clone();
                    if !DynamicZoom::apply(&mut n, &a, &b, *size, ease, src) {
                        continue;
                    }
                    if n != c {
                        t.tracks[ti].replace(n);
                        changed += 1;
                    }
                }
            }
            if changed == 0 {
                return Err(EditError::EmptyClip);
            }
            Ok(())
        })
    }

    /// What the Dynamic Zoom editor shows for `clip`: its stage's windows, else the one-click default (whole picture to
    /// 125 %) as a starting point. `None` for clips Dynamic Zoom does not work on.
    // Swift: EditorSession+DynamicZoom.swift:41
    pub fn dynamic_zoom_windows(&self, clip: &Clip) -> Option<DynamicZoomWindows> {
        let (w, h) = self.project().picture_size(clip)?;
        if clip.is_generator() || clip.sequence.is_some() || clip.is_still || clip.hold_frame.is_some() {
            return None;
        }
        let pic = Vec2 { x: w as f64, y: h as f64 };
        let (start, end, ease) = DynamicZoom::windows(clip, pic).unwrap_or((
            ZoomRect::FULL,
            ZoomRect::centred(Self::DYNAMIC_ZOOM_AMOUNT, Vec2 { x: 0.5, y: 0.5 }),
            ZoomEase::EaseInOut,
        ));
        Some(DynamicZoomWindows { start, end, ease })
    }

    /// Writes `start` / `end` into the clip's Dynamic Zoom stage as a live edit: `continues_gesture` joins the running
    /// drag into one undo step. The monitor shows the new zoom at once.
    // Swift: EditorSession+DynamicZoom.swift:50
    pub fn set_dynamic_zoom_windows(
        &mut self,
        id: Id,
        start: &ZoomRect,
        end: &ZoomRect,
        ease: ZoomEase,
        continues_gesture: bool,
    ) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let Some(c) = clip_in(t, id).cloned() else { return false };
        let Some((w, h)) = self.project().picture_size(&c) else { return false };
        let shown = self.displayed_clip(&c);
        let mut n = shown.clone();
        let pic = Vec2 { x: w as f64, y: h as f64 };
        let applied = self.with_ids(|_, ids| DynamicZoom::apply(&mut n, start, end, pic, ease, ids));
        if !applied || n == shown {
            return false;
        }
        self.replace_displayed_clip(n, "Dynamic Zoom", continues_gesture);
        true
    }
}

/// The two windows and the ease the Dynamic Zoom editor shows (Swift tuple `(start:end:ease:)`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct DynamicZoomWindows {
    pub start: ZoomRect,
    pub end: ZoomRect,
    pub ease: ZoomEase,
}

// MARK: Filler words

impl EditorSession {
    /// Filler words ("um", "uh", "äh"...) among the timed caption words of the active sequence, as ripple cuts. Reads
    /// the transcript data the captions carry; nothing is changed.
    // Swift: EditorSession+FillerWords.swift:7
    pub fn filler_scan(&self, language: &str) -> FillerScan {
        self.active_timeline().map(|t| FillerWords::scan(t, language)).unwrap_or_default()
    }

    /// Remove Filler Words, step one: marks every filler as a proposed cut (replacing earlier filler proposals; one undo
    /// step). Returns the scan (its count is the preview number).
    // Swift: EditorSession+FillerWords.swift:14
    pub fn propose_filler_word_cuts(&mut self, language: &str) -> FillerScan {
        let scan = self.filler_scan(language);
        if scan.cuts.is_empty() {
            return scan;
        }
        self.propose_cuts(&scan.cuts, ProposedCutKind::Filler);
        scan
    }
}

// MARK: Punch In

impl EditorSession {
    /// Punches the selected (or playhead) video clips in, or out when all already are. Returns whether anything changed.
    // Swift: EditorSession+PunchIn.swift:7
    pub fn toggle_punch_in(&mut self) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let clips = self.command_clips(Some(TrackKind::Video));
        if clips.is_empty() {
            return false;
        }
        let ids: Vec<Id> = clips.iter().map(|c| c.id).collect();
        let out = clips.iter().all(|c| t.is_punched_in(c));
        let name = if out { "Punch Out" } else { "Punch In" };
        self.attempt_keyed_ids(name, None, |tl, _| tl.toggle_punch_in(&ids, PunchIn::DEFAULT_SCALE).map(|_| ()))
    }

    // Swift: EditorSession+PunchIn.swift:16
    pub fn punch_in_enabled(&self) -> bool {
        !self.command_clips(Some(TrackKind::Video)).is_empty()
    }

    /// The shots Punch In Cuts works on: the selected video clips when two or more are selected, else every video clip
    /// of the targeted video track (the first video track when none is targeted).
    fn punch_in_cuts_clips(&self) -> Vec<Clip> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        let selected: Vec<Clip> = t
            .tracks
            .iter()
            .filter(|tr| tr.kind == TrackKind::Video)
            .flat_map(|tr| tr.clips())
            .filter(|c| self.selection.contains(&c.id) && !c.is_generator())
            .cloned()
            .collect();
        if selected.len() >= 2 {
            return selected;
        }
        let videos: Vec<_> = t.tracks.iter().filter(|tr| tr.kind == TrackKind::Video).collect();
        let Some(track) = videos.iter().find(|tr| tr.is_targeted).or(videos.first()) else { return Vec::new() };
        track.clips().iter().filter(|c| c.is_enabled && !c.is_generator()).cloned().collect()
    }

    // Swift: EditorSession+PunchInCuts.swift:16
    pub fn punch_in_cuts_enabled(&self) -> bool {
        self.punch_in_cuts_clips().len() >= 2
    }

    /// Applies the pattern to the shots (one undo step). Returns whether anything changed.
    // Swift: EditorSession+PunchInCuts.swift:20
    pub fn punch_in_cuts(&mut self, options: &PunchInCutsOptions) -> bool {
        let ids: Vec<Id> = self.punch_in_cuts_clips().iter().map(|c| c.id).collect();
        if ids.len() < 2 {
            self.set_error("Select two or more video clips, or target a video track with several shots.");
            return false;
        }
        self.attempt_keyed_ids("Punch In Cuts", None, |t, src| t.punch_in_cuts(&ids, options, src).map(|_| ()))
    }
}

#[cfg(test)]
mod beat_tests {
    use super::*;

    /// A 16-bit stereo WAV: a short click every half second (120 BPM) for `seconds`.
    fn click_wav(seconds: usize) -> Vec<u8> {
        let rate = 22_050usize;
        let mut pcm = Vec::new();
        for i in 0..rate * seconds {
            let in_beat = i % (rate / 2);
            let v =
                if in_beat < 400 { (f64::from(i32::try_from(in_beat).unwrap_or(0)) * 0.9).sin() * 0.9 } else { 0.0 };
            let s = (v * 32_000.0) as i16;
            pcm.extend_from_slice(&s.to_le_bytes());
            pcm.extend_from_slice(&s.to_le_bytes());
        }
        let mut out = Vec::new();
        out.extend_from_slice(b"RIFF");
        out.extend_from_slice(&(36 + pcm.len() as u32).to_le_bytes());
        out.extend_from_slice(b"WAVEfmt ");
        out.extend_from_slice(&16u32.to_le_bytes());
        out.extend_from_slice(&1u16.to_le_bytes());
        out.extend_from_slice(&2u16.to_le_bytes());
        out.extend_from_slice(&(rate as u32).to_le_bytes());
        out.extend_from_slice(&(rate as u32 * 4).to_le_bytes());
        out.extend_from_slice(&4u16.to_le_bytes());
        out.extend_from_slice(&16u16.to_le_bytes());
        out.extend_from_slice(b"data");
        out.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
        out.extend_from_slice(&pcm);
        out
    }

    #[test]
    fn analyze_beats_finds_the_tempo_of_a_decoded_file() {
        let dir = std::env::temp_dir().join(format!("sq-beats-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap_or_default();
        let path = dir.join("clicks.wav");
        std::fs::write(&path, click_wav(12)).unwrap_or_default();
        let grid = analyze_beats_blocking(&path);
        let _ = std::fs::remove_dir_all(&dir);
        let grid = grid.map(|g| (g.bpm, g.beats.len(), g.beats_per_bar));
        let (bpm, beats, per_bar) = grid.unwrap_or((0.0, 0, 0));
        assert!((bpm - 120.0).abs() < 4.0, "bpm {bpm}");
        assert!(beats >= 15, "beats {beats}");
        assert_eq!(per_bar, 4);
    }

    #[test]
    fn analyze_beats_of_a_missing_file_is_none() {
        assert!(analyze_beats_blocking(Path::new("/nonexistent/none.wav")).is_none());
    }
}
