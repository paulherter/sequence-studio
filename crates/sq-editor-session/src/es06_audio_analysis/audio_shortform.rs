// Swift: EditorSession+AudioShortform.swift
//! Audio short-form tools: pure range helpers, the Audio Gain and Tag commands, Bake Live Duck to Keys, Match Loudness,
//! Remove Silences with its proposed-cut review, scene-change proposals, track mix and Sequence Volume.
//!
//! Swift's `async` loudness measurement and scene detection take the slow work as a closure (`measure`, `detect`): the
//! caller runs the session method on the thread that owns the session and the closure blocks on a worker.

use std::collections::{BTreeMap, BTreeSet};

use sq_core_audio::audio_gain::{AudioGain, AudioGainMode};
use sq_core_audio::audio_role::{TimelineRoleExt, TrackRoleExt};
use sq_core_audio::ducking::DuckingClipExt;
use sq_core_audio::live_ducking::{DefaultsStore, DialogueSilenceProvider, LiveDucking};
use sq_core_audio::silence_removal::SilenceRemoval;
use sq_core_edit::clip_levels::ClipLevels;
use sq_core_edit::proposed_cuts::{ProposedCutKind, TimelineProposedCutsExt};
use sq_core_edit::timeline_replace::TimelineReplaceExt;
use sq_core_model::{AnimatedProperty, AudioTag, Clip, EditError, Timeline, Track, TrackKind, TrackPan};
use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange};
use sq_playback::audio::WaveformSilences;

use super::audio_edits::MeasureLoudness;

/// A one-track sequence and the range to measure (see `EditorSession::loudness_job`).
#[derive(Clone, Debug)]
pub struct LoudnessJob {
    /// The clips as heard from their source.
    pub timeline: Timeline,
    /// From zero to the last clip's end.
    pub range: TimeRange,
}

/// One run of Match Loudness: the clips that get the gain, the role's target and what to measure.
#[derive(Clone, Debug)]
pub struct MatchLoudnessRun {
    /// The selected clips of the run.
    pub selected_ids: Vec<Id>,
    /// LUFS the run should reach.
    pub target: f64,
    /// `None` when the run has nothing to measure.
    pub job: Option<LoudnessJob>,
}
use crate::EditorSession;

/// Pure helpers for the audio short-form tools (testable without a session).
// Swift: EditorSession+AudioShortform.swift:9
pub enum AudioShortform {}

impl AudioShortform {
    /// Where dialogue is heard on `clip`: its timeline range minus the pauses.
    // Swift: EditorSession+AudioShortform.swift:11
    pub fn active_ranges(clip: TimeRange, silences: &[TimeRange]) -> Vec<TimeRange> {
        LiveDucking::active_ranges(&clip, silences)
    }

    /// Sorted, with overlapping or touching ranges joined.
    // Swift: EditorSession+AudioShortform.swift:16
    pub fn merged(ranges: &[TimeRange]) -> Vec<TimeRange> {
        let mut out: Vec<TimeRange> = Vec::new();
        let mut sorted = ranges.to_vec();
        sorted.sort_by_key(|r| r.start);
        for r in sorted.into_iter().filter(|r| !r.is_empty()) {
            match out.last_mut() {
                Some(last) if r.start <= last.end() => {
                    *last = TimeRange::new(last.start, last.end().max(r.end()) - last.start);
                }
                _ => out.push(r),
            }
        }
        out
    }

    /// Pauses of `clip` in timeline time, as heard: the source level goes through the clip's time mapping (reverse,
    /// speed, ramps), Audio Gain, the volume line and the track fader before it is compared with the threshold.
    /// `source_peak` is the linear peak of the media in a source range.
    // Swift: EditorSession+AudioShortform.swift:28
    pub fn silences(
        clip: &Clip,
        track_volume_db: f64,
        threshold_db: f64,
        minimum_length: Time,
        source_peak: impl FnMut(TimeRange) -> f32,
    ) -> Vec<TimeRange> {
        let (levels, window) = ClipLevels::audible(clip, track_volume_db, source_peak);
        sq_audiofx::silence_detector::SilenceDetector::silences(&levels, window, threshold_db, minimum_length)
            .into_iter()
            .map(|s| TimeRange::new(clip.start + s.start, s.duration))
            .collect()
    }

    /// Same, reading the peaks from a decoded waveform.
    // Swift: EditorSession+AudioShortform.swift:36
    pub fn silences_in(
        clip: &Clip,
        data: &sq_media::waveform_data::WaveformData,
        track_volume_db: f64,
        threshold_db: f64,
        minimum_length: Time,
    ) -> Vec<TimeRange> {
        WaveformSilences::pauses(clip, data, track_volume_db, threshold_db, minimum_length)
    }

    /// Pauses of several overlapping or touching clips together: a range is silent only where EVERY clip covering it is
    /// silent (the others are still heard there). Where clips do not overlap this is the plain union of their pauses.
    /// Gaps between clips are not pauses.
    // Swift: EditorSession+AudioShortform.swift:44
    pub fn combined_silences(clips: &[(TimeRange, Vec<TimeRange>)]) -> Vec<TimeRange> {
        let coverage = Self::merged(&clips.iter().map(|c| c.0).collect::<Vec<_>>());
        let active = Self::merged(&clips.iter().flat_map(|(r, s)| Self::active_ranges(*r, s)).collect::<Vec<_>>());
        Self::subtract(&active, &coverage)
    }

    /// `ranges` (sorted, disjoint) minus `cut` (sorted, disjoint).
    // Swift: EditorSession+AudioShortform.swift:51
    pub fn subtract(cut: &[TimeRange], ranges: &[TimeRange]) -> Vec<TimeRange> {
        let mut out = Vec::new();
        for r in ranges {
            let mut cursor = r.start;
            for c in cut.iter().filter(|c| c.end() > r.start && c.start < r.end()) {
                if c.start > cursor {
                    out.push(TimeRange::new(cursor, c.start - cursor));
                }
                cursor = cursor.max(c.end());
            }
            if r.end() > cursor {
                out.push(TimeRange::new(cursor, r.end() - cursor));
            }
        }
        out
    }

    /// Audio tracks that are heard: not muted, and only the solo ones when any audio track is solo.
    // Swift: EditorSession+AudioShortform.swift:67
    pub fn audible_tracks(t: &Timeline) -> Vec<&Track> {
        let audio: Vec<&Track> = t.tracks.iter().filter(|tr| tr.kind == TrackKind::Audio && !tr.is_muted).collect();
        if audio.iter().any(|tr| tr.is_solo) { audio.into_iter().filter(|tr| tr.is_solo).collect() } else { audio }
    }
}

/// Check mark and label of a Tag menu item: every selected clip has this role; `inherited` = none carries its own tag
/// (the role comes from the track).
// Swift: EditorSession+AudioShortform.swift:516
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AudioTagMenuState {
    // Swift: EditorSession+AudioShortform.swift:517
    pub checked: bool,
    // Swift: EditorSession+AudioShortform.swift:518
    pub inherited: bool,
    /// False for a checked item whose removal would not remove the role (it would stay or turn into another one).
    // Swift: EditorSession+AudioShortform.swift:520
    pub enabled: bool,
}

impl AudioTagMenuState {
    // Swift: EditorSession+AudioShortform.swift:521
    pub fn new(checked: bool, inherited: bool, enabled: bool) -> AudioTagMenuState {
        AudioTagMenuState { checked, inherited, enabled }
    }

    // Swift: EditorSession+AudioShortform.swift:524
    pub fn title(&self, tag: AudioTag) -> String {
        if self.inherited { format!("{} (inherits track role)", tag.title()) } else { tag.title().to_string() }
    }
}

/// What a bake did: `keys_added` new keys; `changed` also when only stale keys went (the dialogue left the clip).
// Swift: EditorSession+AudioShortform.swift:201
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DuckBakeResult {
    // Swift: EditorSession+AudioShortform.swift:202
    pub keys_added: usize,
    // Swift: EditorSession+AudioShortform.swift:203
    pub changed: bool,
}

/// The inputs of a duck bake, shared by the bake itself and the "would it change anything" check.
struct DuckBake<'a> {
    live: Option<LiveDucking>,
    silences: Option<&'a dyn DialogueSilenceProvider>,
    dialogue: Vec<TimeRange>,
    targets: Vec<Id>,
    amount_db: f64,
    fade: Time,
}

impl DuckBake<'_> {
    fn run(&self, t: &mut Timeline, ids: &mut dyn IdSource) -> Result<DuckBakeResult, EditError> {
        let mut out = DuckBakeResult::default();
        // No dialogue at all: nothing to bake, and earlier keys are not wiped as a side effect.
        if self.dialogue.is_empty() {
            return Ok(out);
        }
        // Clips the live bake keys below: never keyed here as well.
        let live_clips = if self.live.is_none() { BTreeSet::new() } else { LiveDucking::bake_target_ids(t) };
        if let Some(d) = &self.live {
            let n = d.bake(t, self.silences, ids);
            out.keys_added += n;
            if n > 0 {
                out.changed = true;
            }
        }
        let amount = self.live.as_ref().map_or(self.amount_db, |d| d.amount_db);
        let attack = self.live.as_ref().map_or(self.fade, LiveDucking::fade);
        let recovery = self.live.as_ref().map(LiveDucking::recovery);
        for id in self.targets.iter().filter(|id| !live_clips.contains(id)) {
            let Some(mut c) = t.tracks.iter().find_map(|tr| tr.clip(*id)).cloned() else { continue };
            let had_keys = !c.duck_key_ids.is_empty();
            let n = c.apply_ducking(&self.dialogue, amount, attack, recovery, ids);
            out.keys_added += n;
            if n > 0 || had_keys {
                out.changed = true;
            }
            t.replace_clip(c)?;
        }
        Ok(out)
    }
}

fn signed_db(v: f64) -> String {
    let r = (v * 10.0).round() / 10.0;
    let a = r.abs();
    let body = if r == r.round() { format!("{}", a as i64) } else { format!("{a:.1}") };
    format!(
        "{}{body}",
        if r < 0.0 {
            "-"
        } else if r > 0.0 {
            "+"
        } else {
            ""
        }
    )
}

impl EditorSession {
    /// Selected audio clips (video clips are ignored, also when linked): what the `[` / `]` keys and the tags act on.
    // Swift: EditorSession+AudioShortform.swift:75
    pub fn selected_audio_clips(&self) -> Vec<Clip> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        t.tracks
            .iter()
            .flat_map(|tr| tr.clips().iter())
            .filter(|c| self.selection.contains(&c.id) && c.kind == TrackKind::Audio && !c.is_generator())
            .cloned()
            .collect()
    }

    /// `[` / `]`: Audio Gain of the selected audio clips changes by `db`, one undo step. Never goes below the gain floor.
    // Swift: EditorSession+AudioShortform.swift:81
    pub fn nudge_audio_gain(&mut self, db: f64) -> bool {
        let clips = self.selected_audio_clips();
        if clips.is_empty() {
            return false;
        }
        let gains: BTreeMap<Id, f64> = clips
            .iter()
            .filter_map(|c| AudioGain::apply(AudioGainMode::Adjust(db), c.audio_gain_db, None).map(|g| (c.id, g)))
            .collect();
        self.set_audio_gain(&gains)
    }

    /// `nudge_audio_gain` plus the words for the status line ("Gain +1 dB (now +3 dB)"; several clips with different
    /// gains say "Gain +1 dB on 3 clips"). `None` = nothing selected or nothing changed.
    // Swift: EditorSession+AudioShortform.swift:93
    pub fn nudge_audio_gain_report(&mut self, db: f64) -> Option<String> {
        let selected = self.selected_audio_clips();
        if selected.is_empty() {
            return None;
        }
        let before: BTreeMap<Id, f64> = selected.iter().map(|c| (c.id, c.audio_gain_db)).collect();
        if !self.nudge_audio_gain(db) {
            return Some("Gain at limit".to_string()); // every selected clip is already at the floor / ceiling
        }
        let after = self.selected_audio_clips();
        // The step actually applied: the largest move among the clips (a clip near the limit moves less than asked).
        let moves: Vec<f64> =
            after.iter().filter_map(|c| before.get(&c.id).map(|b| c.audio_gain_db - b)).filter(|m| *m != 0.0).collect();
        let moved = moves.iter().copied().fold(None, |best: Option<f64>, m| match best {
            Some(b) if b.abs() >= m.abs() => Some(b),
            _ => Some(m),
        });
        let moved = moved.unwrap_or(db);
        let now: BTreeSet<u64> = after.iter().map(|c| c.audio_gain_db.to_bits()).collect();
        let delta = format!("Gain {} dB", signed_db(moved));
        if now.len() == 1
            && let Some(g) = after.first().map(|c| c.audio_gain_db)
        {
            return Some(format!("{delta} (now {} dB)", signed_db(g)));
        }
        Some(format!("{delta} on {} clips", after.len()))
    }

    /// Tags the selected audio clips; choosing the tag they all have already removes it. Tag, track role and the clip's
    /// own tag are one system (audit C18): when the selection holds every clip of an audio track, the Tag is that
    /// track's role (its clips inherit it and lose their own tag); clips of tracks only partly selected get their own tag.
    // Swift: EditorSession+AudioShortform.swift:117
    pub fn toggle_audio_tag(&mut self, tag: AudioTag) -> bool {
        let clips = self.selected_audio_clips();
        let Some(tl) = self.active_timeline().cloned() else { return false };
        if clips.is_empty() {
            return false;
        }
        let ids: BTreeSet<Id> = clips.iter().map(|c| c.id).collect();
        let whole = Self::whole_tracks(&ids, &tl);
        let remove = clips.iter().all(|c| tl.role_of(c) == Some(tag));
        if remove && !Self::removal_clears_role(tag, &clips, &whole, &tl) {
            return false;
        }
        let name = if remove { "Remove Tag".to_string() } else { format!("Tag as {}", tag.title()) };
        self.attempt_ids(&name, |t, _| {
            for i in 0..t.tracks.len() {
                let tid = t.tracks[i].id;
                if whole.contains(&tid) {
                    if remove {
                        if t.tracks[i].audio_role == Some(tag) {
                            t.tracks[i].audio_role = None;
                        }
                    } else {
                        t.tracks[i].audio_role = Some(tag);
                    }
                }
                let mine: Vec<Clip> = t.tracks[i].clips().iter().filter(|c| ids.contains(&c.id)).cloned().collect();
                for mut c in mine {
                    if whole.contains(&tid) {
                        if !remove || c.audio_tag == Some(tag) {
                            c.audio_tag = None;
                        }
                    } else {
                        c.audio_tag = if remove { None } else { Some(tag) };
                    }
                    t.replace_clip(c)?;
                }
            }
            Ok(())
        })
    }

    /// Removing `tag` from clips that all have it must leave them without any role: no clip may end up with another one
    /// (its track's role showing through), and none may keep `tag` (an inherited role has no own tag to clear, and
    /// there is no "no role" tag to give a clip on a partly selected track).
    pub(crate) fn removal_clears_role(tag: AudioTag, clips: &[Clip], whole: &BTreeSet<Id>, tl: &Timeline) -> bool {
        for c in clips {
            let Some(tr) = tl.tracks.iter().find(|tr| tr.clips().iter().any(|x| x.id == c.id)) else { continue };
            let is_whole = whole.contains(&tr.id);
            let track_role = if is_whole && tr.audio_role == Some(tag) { None } else { tr.audio_role };
            let own = if c.audio_tag == Some(tag) { None } else { c.audio_tag };
            if own.or(track_role).is_some() {
                return false;
            }
        }
        true
    }

    /// What the Clip > Audio Options > Dialogue / Music / SFX items show for the selection.
    // Swift: EditorSession+AudioShortform.swift:156
    pub fn audio_tag_menu_state(&self, tag: AudioTag) -> AudioTagMenuState {
        let clips = self.selected_audio_clips();
        let none = AudioTagMenuState::new(false, false, true);
        let Some(tl) = self.active_timeline() else { return none };
        if clips.is_empty() || !clips.iter().all(|c| tl.role_of(c) == Some(tag)) {
            return none;
        }
        let whole = Self::whole_tracks(&clips.iter().map(|c| c.id).collect(), tl);
        AudioTagMenuState::new(
            true,
            clips.iter().all(|c| c.audio_tag.is_none()),
            Self::removal_clears_role(tag, &clips, &whole, tl),
        )
    }

    /// Audio tracks whose every clip is in `ids` (an empty or locked track is never whole).
    pub(crate) fn whole_tracks(ids: &BTreeSet<Id>, t: &Timeline) -> BTreeSet<Id> {
        t.tracks
            .iter()
            .filter(|tr| {
                tr.kind == TrackKind::Audio
                    && !tr.is_locked
                    && !tr.clips().is_empty()
                    && tr.clips().iter().all(|c| ids.contains(&c.id))
            })
            .map(|tr| tr.id)
            .collect()
    }

    /// Music clips Auto Duck works on: the selected ones with role Music (clip tag, else track role; audit C18), else
    /// every Music clip of the sequence.
    // Swift: EditorSession+AudioShortform.swift:173
    pub fn music_duck_targets(&self) -> Vec<Clip> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        let music: Vec<Clip> = t
            .tracks
            .iter()
            .filter(|tr| tr.kind == TrackKind::Audio)
            .flat_map(|tr| {
                tr.clips().iter().filter(move |c| c.kind == TrackKind::Audio && tr.role_of(c) == Some(AudioTag::Music))
            })
            .cloned()
            .collect();
        let chosen: Vec<Clip> = music.iter().filter(|c| self.selection.contains(&c.id)).cloned().collect();
        if chosen.is_empty() { music } else { chosen }
    }

    /// Dialogue activity on the timeline: `LiveDucking::dialogue_ranges` minus the pauses `silences` gives per clip.
    // Swift: EditorSession+AudioShortform.swift:182
    pub fn dialogue_ranges(&self, silences: &dyn Fn(&Clip) -> Vec<TimeRange>) -> Vec<TimeRange> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        LiveDucking::dialogue_ranges_pauses(t, None, |c, _| Some(silences(c)))
    }

    fn duck_bake<'a>(
        &self,
        live: Option<LiveDucking>,
        defaults: &dyn DefaultsStore,
        silences: Option<&'a dyn DialogueSilenceProvider>,
        clip_silences: &dyn Fn(&Clip) -> Vec<TimeRange>,
        amount_db: f64,
        fade: Time,
    ) -> DuckBake<'a> {
        let live = live.or_else(|| self.effective_live_ducking(defaults)).filter(|d| !d.is_off());
        let dialogue = match (&live, self.active_timeline()) {
            (Some(d), Some(t)) => d.expanded(&LiveDucking::dialogue_ranges(t, None, silences)),
            _ => self.dialogue_ranges(clip_silences),
        };
        let targets = self.music_duck_targets().iter().map(|c| c.id).collect();
        DuckBake { live, silences, dialogue, targets, amount_db, fade }
    }

    /// Bake Live Duck to Keys (was Auto Duck Music), one undo step. Returns the number of keys written (0 = no dialogue
    /// or no music, and no undo step). With live ducking on (`live`, default the project's effective setting) the keys
    /// are the ones live ducking would produce and the Music-role tracks leave live ducking in the same step; with it
    /// off it is the old Auto Duck on `music_duck_targets`, `amount_db` / `fade`.
    // Swift: EditorSession+AudioShortform.swift:193
    pub fn bake_live_duck_to_keys(
        &mut self,
        live: Option<LiveDucking>,
        defaults: &dyn DefaultsStore,
        silences: Option<&dyn DialogueSilenceProvider>,
        clip_silences: &dyn Fn(&Clip) -> Vec<TimeRange>,
        amount_db: f64,
        fade: Time,
    ) -> usize {
        self.bake_duck(live, defaults, silences, clip_silences, amount_db, fade).keys_added
    }

    /// `bake_live_duck_to_keys` with the full result, the one bake behind the Clip menu and the Live Ducking dialog.
    /// Without any dialogue nothing is touched; with dialogue, keys of clips it no longer reaches are replaced and
    /// reported as `changed`.
    // Swift: EditorSession+AudioShortform.swift:209
    pub fn bake_duck(
        &mut self,
        live: Option<LiveDucking>,
        defaults: &dyn DefaultsStore,
        silences: Option<&dyn DialogueSilenceProvider>,
        clip_silences: &dyn Fn(&Clip) -> Vec<TimeRange>,
        amount_db: f64,
        fade: Time,
    ) -> DuckBakeResult {
        let run = self.duck_bake(live, defaults, silences, clip_silences, amount_db, fade);
        let Some(mut probe) = self.active_timeline().cloned() else { return DuckBakeResult::default() };
        match run.run(&mut probe, &mut SequentialIds::default()) {
            Ok(first) if first.changed => {}
            _ => return DuckBakeResult::default(),
        }
        let mut result = DuckBakeResult::default();
        self.attempt_ids("Bake Live Duck to Keys", |t, ids| {
            result = run.run(t, ids)?;
            Ok(())
        });
        result
    }

    /// Music clips that carry duck keys from an earlier bake which a new bake with the same inputs would change: the
    /// dialogue was edited since (stale), or a key was moved or changed by hand. Never changes the sequence.
    // Swift: EditorSession+AudioShortform.swift:223
    pub fn clips_with_changed_duck_keys(
        &self,
        live: Option<LiveDucking>,
        defaults: &dyn DefaultsStore,
        silences: Option<&dyn DialogueSilenceProvider>,
        clip_silences: &dyn Fn(&Clip) -> Vec<TimeRange>,
        amount_db: f64,
        fade: Time,
    ) -> Vec<Id> {
        let Some(before) = self.active_timeline() else { return Vec::new() };
        let run = self.duck_bake(live, defaults, silences, clip_silences, amount_db, fade);
        let mut after = before.clone();
        if run.run(&mut after, &mut SequentialIds::default()).is_err() {
            return Vec::new();
        }
        fn duck(c: &Clip) -> Vec<(Time, u64)> {
            let mut keys: Vec<(Time, u64)> = c
                .animation
                .volume
                .track
                .keys
                .iter()
                .filter(|k| c.duck_key_ids.contains(&k.id))
                .map(|k| (k.time, k.value.to_bits()))
                .collect();
            keys.sort();
            keys
        }
        let now: BTreeMap<Id, &Clip> = after.tracks.iter().flat_map(|t| t.clips().iter()).map(|c| (c.id, c)).collect();
        before
            .tracks
            .iter()
            .flat_map(|t| t.clips().iter())
            .filter(|c| !c.duck_key_ids.is_empty())
            .filter_map(|c| {
                let n = now.get(&c.id)?;
                (duck(c) != duck(n)).then_some(c.id)
            })
            .collect()
    }

    /// Whether Bake Live Duck to Keys has something to work on: Music clips (clip tag, else track role).
    // Swift: EditorSession+AudioShortform.swift:280
    pub fn can_bake_live_duck(&self) -> bool {
        !self.music_duck_targets().is_empty()
    }

    /// Clips of the active sequence that live ducking and old Auto Duck keys would duck twice (empty while live ducking
    /// is off).
    // Swift: EditorSession+AudioShortform.swift:283
    pub fn clips_ducking_twice(&self, defaults: &dyn DefaultsStore) -> Vec<Id> {
        if self.effective_live_ducking(defaults).is_none() {
            return Vec::new();
        }
        self.active_timeline().map_or_else(Vec::new, LiveDucking::clips_ducking_twice)
    }

    /// Removes the old Auto Duck keys from those clips so live ducking is the only duck, one undo step. Returns the
    /// clips fixed.
    // Swift: EditorSession+AudioShortform.swift:289
    pub fn remove_keys_ducking_twice(&mut self, defaults: &dyn DefaultsStore) -> usize {
        if self.clips_ducking_twice(defaults).is_empty() {
            return 0;
        }
        let mut n = 0;
        self.attempt_ids("Remove Duck Keys", |t, _| {
            n = LiveDucking::remove_keys_ducking_twice(t);
            Ok(())
        });
        n
    }

    // MARK: Match loudness

    /// Integrated loudness of the clip's audio as heard from its source (no gain, no volume line), `None` for silence.
    /// `measure` renders the given one-track sequence over the range and returns its integrated LUFS.
    // Swift: EditorSession+AudioShortform.swift:300
    pub fn measure_loudness(&self, clip: &Clip, measure: MeasureLoudness<'_>) -> Option<f64> {
        self.measure_loudness_of_run(std::slice::from_ref(clip), measure)
    }

    /// Integrated loudness of a run of clips of one track heard as one piece (gaps stay silent, so they do not count):
    /// cut dialogue measures as a whole instead of per piece. Same source rules as `measure_loudness`.
    // Swift: EditorSession+AudioShortform.swift:304
    pub fn measure_loudness_of_run(&self, run: &[Clip], measure: MeasureLoudness<'_>) -> Option<f64> {
        let job = self.loudness_job(run)?;
        measure(&job.timeline, job.range).filter(|l| l.is_finite())
    }

    /// The one-track sequence whose loudness is the run's (no gain, no volume line, no tag). Built on the session
    /// thread so a worker can measure it later without the session.
    // Swift: EditorSession+AudioShortform.swift:304
    pub fn loudness_job(&self, run: &[Clip]) -> Option<LoudnessJob> {
        let format = self.active_timeline()?.format.clone();
        let origin = run.iter().map(|c| c.start).min()?;
        let mut ids = SequentialIds::default();
        let mut track = Track::new(ids.next_id(), TrackKind::Audio);
        let mut end = Time::ZERO;
        for clip in run {
            let mut c = clip.clone();
            c.start = clip.start - origin;
            c.link = None;
            c.audio_gain_db = 0.0;
            c.animation.volume = AnimatedProperty::new(1.0);
            c.audio_tag = None;
            c.duck_key_ids = Vec::new();
            end = end.max(c.timeline().end());
            let _ = track.overwrite(c, &mut ids);
        }
        let timeline = Timeline::new(ids.next_id(), "", format, vec![track]);
        Some(LoudnessJob { timeline, range: TimeRange::from_end(Time::ZERO, end) })
    }

    /// Match Loudness on the selected audio clips: Audio Gain is set so each reaches its role's target (clip tag, else
    /// track role, else Dialogue; Dialogue -14 LUFS, Music and SFX 6 dB lower). Returns the number of clips changed;
    /// silent clips stay as they are.
    // Swift: EditorSession+AudioShortform.swift:325
    pub fn match_loudness(&mut self, measure: MeasureLoudness<'_>) -> usize {
        let plan = self.match_loudness_plan();
        let measured: Vec<Option<f64>> = plan
            .iter()
            .map(|r| r.job.as_ref().and_then(|j| measure(&j.timeline, j.range)).filter(|l| l.is_finite()))
            .collect();
        self.apply_match_loudness(&plan, &measured)
    }

    /// The runs Match Loudness measures (roles are read now, before the slow part).
    pub fn match_loudness_plan(&self) -> Vec<MatchLoudnessRun> {
        let clips = self.selected_audio_clips();
        let Some(t) = self.active_timeline() else { return Vec::new() };
        // Adjacent same-role clips of a track are measured as one run and get one gain (cut dialogue stays even).
        let selected: BTreeSet<Id> = clips.iter().map(|c| c.id).collect();
        AudioGain::loudness_runs(&selected, t, AudioGain::RUN_GAP)
            .iter()
            .map(|run| MatchLoudnessRun {
                selected_ids: run.iter().filter(|c| selected.contains(&c.id)).map(|c| c.id).collect(),
                target: AudioGain::target_lufs_for_clip(&run[0], t),
                job: self.loudness_job(run),
            })
            .collect()
    }

    /// Sets the gains for `plan` from its measured loudness (`measured[i]` belongs to `plan[i]`). Returns the clips changed.
    pub fn apply_match_loudness(&mut self, plan: &[MatchLoudnessRun], measured: &[Option<f64>]) -> usize {
        let mut gains: BTreeMap<Id, f64> = BTreeMap::new();
        for (run, lufs) in plan.iter().zip(measured) {
            if let Some(g) = AudioGain::match_loudness(*lufs, run.target) {
                for id in &run.selected_ids {
                    gains.insert(*id, g);
                }
            }
        }
        if self.set_audio_gain(&gains) { gains.len() } else { 0 }
    }

    // MARK: Remove silences

    /// Frame-aligned cuts for the clips' pauses (timeline time). Only audible clips count (enabled, on an unmuted
    /// track, solo respected); where selected clips overlap, a range is a pause only if all of them are silent there.
    // Swift: EditorSession+AudioShortform.swift:347
    pub fn silence_cuts(
        &self,
        clips: &[Clip],
        silences: &dyn Fn(&Clip) -> Vec<TimeRange>,
        padding: Time,
    ) -> Vec<TimeRange> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        let heard: BTreeSet<Id> = AudioShortform::audible_tracks(t)
            .into_iter()
            .flat_map(|tr| tr.clips().iter())
            .filter(|c| c.is_enabled)
            .map(|c| c.id)
            .collect();
        let parts: Vec<(TimeRange, Vec<TimeRange>)> =
            clips.iter().filter(|c| heard.contains(&c.id)).map(|c| (c.timeline(), silences(c))).collect();
        SilenceRemoval::cuts(&AudioShortform::combined_silences(&parts), padding, t.frame_duration())
    }

    /// Ripple-deletes the cuts through the sequence (`remove_silences`): the tracks of `clips` and their linked
    /// partners plus every sync-locked track, so nothing slips out of sync. One undo step, all or nothing.
    // Swift: EditorSession+AudioShortform.swift:356
    pub fn remove_silences(&mut self, cuts: &[TimeRange], clips: &[Clip], crossfade: bool) -> bool {
        let Some(fd) = self.active_timeline().map(Timeline::frame_duration) else { return false };
        if cuts.is_empty() {
            return false;
        }
        let ids: BTreeSet<Id> = clips.iter().map(|c| c.id).collect();
        let fade = if crossfade { fd } else { Time::ZERO };
        self.attempt_ripple_ids("Remove Silences", |t, ids_src| {
            t.remove_silences(cuts, &ids, fade, ids_src).map(|_| ())
        })
    }

    // MARK: Proposed cuts (review step of Remove Silences)

    /// Puts `cuts` on the timeline as "proposed cut" markers (replacing earlier proposals of that kind). One undo step.
    // Swift: EditorSession+AudioShortform.swift:366
    pub fn propose_cuts(&mut self, cuts: &[TimeRange], kind: ProposedCutKind) -> bool {
        self.attempt_ids("Propose Cuts", |t, ids| {
            t.propose_cuts(cuts, kind, ids);
            Ok(())
        })
    }

    /// Puts scene changes (timeline times) on the timeline as point proposals; accepting razors the clips there.
    // Swift: EditorSession+AudioShortform.swift:372
    pub fn propose_scene_cuts(&mut self, times: &[Time]) -> bool {
        self.attempt_ids("Find Scene Changes", |t, ids| {
            t.propose_scene_cuts(times, ids);
            Ok(())
        })
    }

    /// Scene-change analysis of `clips` (video clips only; `detect` gets a clip and returns media-time changes). The
    /// changes strictly inside each clip's source range are mapped to the timeline and proposed as razor cuts. The
    /// proposal is one undo step; accepting it is another. Returns the number of proposed cuts, `None` when canceled or
    /// failed.
    // Swift: EditorSession+AudioShortform.swift:381
    pub fn find_scene_changes(
        &mut self,
        clips: &[Clip],
        detect: &mut dyn FnMut(&Clip) -> Result<Vec<Time>, String>,
        is_canceled: &dyn Fn() -> bool,
    ) -> Option<usize> {
        let fd = self.active_timeline()?.frame_duration();
        let mut found: Vec<Time> = Vec::new();
        for c in clips.iter().filter(|c| c.kind == TrackKind::Video && !c.is_generator()) {
            match detect(c) {
                Ok(times) => {
                    if is_canceled() {
                        return None;
                    }
                    found.extend(Self::scene_times(c, &times, fd));
                }
                Err(e) => {
                    self.set_error(e);
                    return None;
                }
            }
        }
        let unique: Vec<Time> = found.into_iter().collect::<BTreeSet<_>>().into_iter().collect();
        if self.propose_scene_cuts(&unique) {
            Some(unique.len())
        } else if unique.is_empty() {
            Some(0)
        } else {
            None
        }
    }

    /// Clips Find Scene Changes looks at: the selected (else playhead) video clips that come from a file.
    // Swift: EditorSession+AudioShortform.swift:396
    pub fn scene_change_targets(&self) -> Vec<Clip> {
        self.command_clips(Some(TrackKind::Video)).into_iter().filter(|c| !c.is_generator()).collect()
    }

    /// Timeline times of the media-time changes that fall strictly inside `clip`, on the frame grid.
    // Swift: EditorSession+AudioShortform.swift:399
    pub fn scene_times(clip: &Clip, media_times: &[Time], frame_duration: Time) -> Vec<Time> {
        media_times
            .iter()
            .filter(|t| **t > clip.source.start && **t < clip.source.end())
            .map(|t| clip.timeline_time_for_source(*t, frame_duration).snapped(frame_duration))
            .filter(|t| *t > clip.start && *t < clip.timeline().end())
            .collect()
    }

    /// The clips cut by accepting proposals: the selected audio clips, else every audible audio clip.
    fn removal_clips(&self, t: &Timeline) -> BTreeSet<Id> {
        let mut clips: BTreeSet<Id> = self.selected_audio_clips().iter().map(|c| c.id).collect();
        if clips.is_empty() {
            clips = AudioShortform::audible_tracks(t)
                .into_iter()
                .flat_map(|tr| tr.clips().iter())
                .filter(|c| c.kind == TrackKind::Audio && !c.is_generator())
                .map(|c| c.id)
                .collect();
        }
        clips
    }

    /// Scene points cut the selected clips (any kind), else every clip.
    fn scene_clips(&self, t: &Timeline) -> BTreeSet<Id> {
        let all: BTreeSet<Id> = t.tracks.iter().flat_map(|tr| tr.clips().iter().map(|c| c.id)).collect();
        let selected: BTreeSet<Id> = self.selection.intersection(&all).copied().collect();
        if selected.is_empty() { all } else { selected }
    }

    /// Accepts the proposals in `ids` (`None` = all): ripple cuts through the sequence, one undo step, all or nothing.
    /// Cuts the tracks of the selected audio clips, or of every audible audio clip when none is selected.
    // Swift: EditorSession+AudioShortform.swift:407
    pub fn accept_proposed_cuts(&mut self, ids: Option<&BTreeSet<Id>>, crossfade: bool) -> bool {
        let Some(t) = self.active_timeline().cloned() else { return false };
        let proposals = t.proposed_cuts();
        if proposals.is_empty() {
            return false;
        }
        let fade = if crossfade { t.frame_duration() } else { Time::ZERO };
        let chosen: Vec<_> = proposals.iter().filter(|p| ids.is_none_or(|s| s.contains(&p.id))).collect();
        if chosen.is_empty() {
            return false;
        }
        let has_scenes = chosen.iter().any(|p| p.kind == ProposedCutKind::Scene);
        let has_removals = chosen.iter().any(|p| p.kind != ProposedCutKind::Scene);
        let clips = self.removal_clips(&t);
        if has_removals && clips.is_empty() {
            return false;
        }
        let scene_clips = self.scene_clips(&t);
        if has_scenes && !has_removals {
            return self.attempt_ids("Cut at Scene Changes", |tl, ids_src| {
                tl.accept_proposed_cuts(ids, &BTreeSet::new(), Some(&scene_clips), fade, ids_src).map(|_| ())
            });
        }
        let name = if chosen.iter().all(|p| p.kind == ProposedCutKind::Filler) {
            "Remove Filler Words"
        } else {
            "Remove Silences"
        };
        self.attempt_ripple_ids(name, |tl, ids_src| {
            tl.accept_proposed_cuts(ids, &clips, Some(&scene_clips), fade, ids_src).map(|_| ())
        })
    }

    /// Result of the review list: cuts the proposals in `accepted` and rejects every other one, as one undo step.
    /// Nothing accepted: the same as rejecting all.
    // Swift: EditorSession+AudioShortform.swift:432
    pub fn review_proposed_cuts(&mut self, accepted: &BTreeSet<Id>, crossfade: bool) -> bool {
        let Some(t) = self.active_timeline().cloned() else { return false };
        let proposals = t.proposed_cuts();
        if proposals.is_empty() {
            return false;
        }
        let all: BTreeSet<Id> = proposals.iter().map(|p| p.id).collect();
        let keep: BTreeSet<Id> = accepted.intersection(&all).copied().collect();
        if keep.is_empty() {
            return self.reject_proposed_cuts(None);
        }
        let chosen: Vec<_> = proposals.iter().filter(|p| keep.contains(&p.id)).collect();
        let has_removals = chosen.iter().any(|p| p.kind != ProposedCutKind::Scene);
        let clips = self.removal_clips(&t);
        if has_removals && clips.is_empty() {
            return false;
        }
        let scene_clips = self.scene_clips(&t);
        let fade = if crossfade { t.frame_duration() } else { Time::ZERO };
        let drop: Vec<Id> = all.difference(&keep).copied().collect();
        let name = if chosen.iter().all(|p| p.kind == ProposedCutKind::Filler) {
            "Remove Filler Words"
        } else if has_removals {
            "Remove Silences"
        } else {
            "Cut at Scene Changes"
        };
        self.attempt_ripple_ids(name, |tl, ids_src| {
            for id in &drop {
                tl.reject_proposed_cut(*id);
            }
            let around = if has_removals { clips.clone() } else { BTreeSet::new() };
            tl.accept_proposed_cuts(Some(&keep), &around, Some(&scene_clips), fade, ids_src).map(|_| ())
        })
    }

    // Swift: EditorSession+AudioShortform.swift:456
    pub fn reject_proposed_cuts(&mut self, ids: Option<&BTreeSet<Id>>) -> bool {
        if self.active_timeline().is_none_or(|t| t.proposed_cuts().is_empty()) {
            return false;
        }
        self.attempt_ids("Reject Proposed Cuts", |tl, _| {
            match ids {
                Some(set) => set.iter().for_each(|id| tl.reject_proposed_cut(*id)),
                None => tl.reject_all_proposed_cuts(),
            }
            Ok(())
        })
    }

    /// The proposal under the playhead, else the next one after it, else the last one before it.
    // Swift: EditorSession+AudioShortform.swift:466
    pub fn proposed_cut_at_playhead(&self) -> Option<Id> {
        let ps = self.active_timeline()?.proposed_cuts();
        let p = self.playhead;
        if let Some(under) = ps.iter().find(|x| x.range.start <= p && p < x.range.end()) {
            return Some(under.id);
        }
        ps.iter().find(|x| x.range.start > p).or(ps.last()).map(|x| x.id)
    }

    // MARK: Track mix and Sequence Volume

    /// Track fader (dB, clamped to the fader range) and pan (-1...1) of an audio track, one undo step. Playback,
    /// scrubbing and export read the same fields.
    // Swift: EditorSession+AudioShortform.swift:476
    pub fn set_track_mix(&mut self, id: Id, volume_db: f64, pan: f64) -> bool {
        self.attempt_ids("Track Volume and Pan", |t, _| {
            let Some(i) = t.tracks.iter().position(|tr| tr.id == id) else { return Ok(()) };
            if t.tracks[i].kind != TrackKind::Audio {
                return Ok(());
            }
            // NaN reads as unity / center: it would poison the mix and make the project unsavable.
            t.tracks[i].volume_db = if volume_db.is_nan() {
                0.0
            } else {
                volume_db.clamp(TrackPan::MIN_VOLUME_DB, TrackPan::MAX_VOLUME_DB)
            };
            t.tracks[i].pan = if pan.is_nan() { 0.0 } else { pan.clamp(-1.0, 1.0) };
            Ok(())
        })
    }

    /// Sequence Volume of the active sequence (dB, clamped to the fader range), one undo step; false when unchanged.
    /// Applied after every track and before the delivery limiter, in playback, scrubbing and export alike.
    // Swift: EditorSession+AudioShortform.swift:488
    pub fn set_sequence_volume(&mut self, db: f64) -> bool {
        let Some(mut probe) = self.active_timeline().cloned() else { return false };
        let was = probe.master_volume_db();
        probe.set_master_volume_db(db);
        if probe.master_volume_db() == was {
            return false;
        }
        self.attempt_ids("Sequence Volume", |t, _| {
            t.set_master_volume_db(db);
            Ok(())
        })
    }

    /// Sequence Volume as the level dialog applies it (v86, keyable). `animate`: the level becomes a key at the
    /// playhead (same fader range, replaces a key at that time). Not `animate` on a keyed sequence: the keys go and
    /// `db` is the constant level. One undo step; false when nothing changed.
    // Swift: EditorSession+AudioShortform.swift:500
    pub fn set_sequence_volume_animated(&mut self, db: f64, animate: bool) -> bool {
        let Some(current) = self.active_timeline() else { return false };
        if !animate {
            if !current.is_master_volume_keyed() {
                return self.set_sequence_volume(db);
            }
            return self.attempt_ids("Sequence Volume", |t, _| {
                t.clear_master_volume_keys(db);
                Ok(())
            });
        }
        let at = self.playhead;
        let clamped = if db.is_nan() { 0.0 } else { db.clamp(TrackPan::MIN_VOLUME_DB, TrackPan::MAX_VOLUME_DB) };
        if current.master_volume_keys().keys.iter().any(|k| k.time == at && k.value == clamped) {
            return false;
        }
        self.attempt_ids("Sequence Volume Keyframe", |t, ids| {
            t.set_master_volume_key(at, db, ids);
            Ok(())
        })
    }
}
