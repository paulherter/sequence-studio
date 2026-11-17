// Swift: LiveDucking.swift (the settings observer is not ported: it is a NotificationCenter wrapper)
//! Live music ducking (N8): the music tracks follow the dialogue tracks while mixing, so a dialogue edit (trim, move,
//! delete, mute) changes the duck immediately and nothing goes stale. Evaluated by the one mix path (playback and
//! export). Which tracks: clips with role Music are ducked, audible clips with role Dialogue are what ducks them (role =
//! clip tag, else track role, `Timeline::role_of`, audit C18). Needs no stored field; amount and on/off come from a user
//! setting (`sq.audio.liveDuckingDB`, 0 = off). `Ducking` (the baked volume keys) stays as the optional bake.

use crate::audio_role::TrackRoleExt;
use crate::ducking::DuckingClipExt;
use sq_core_model::{AudioTag, Clip, DuckTiming, Project, ProjectLiveDucking, Timeline, Track, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::BTreeSet;

/// User settings (Swift `UserDefaults`), injected: the app provides the real store.
pub trait DefaultsStore {
    /// The stored number; `None` when the key is not set.
    fn number(&self, key: &str) -> Option<f64>;
    /// Stores a number.
    fn set_number(&mut self, key: &str, value: f64);
    /// Removes a key.
    fn remove(&mut self, key: &str);
}

/// Live ducking: amount and timing.
#[derive(Clone, Debug, PartialEq)]
pub struct LiveDucking {
    /// Depth of the duck in dB.
    pub amount_db: f64,
    /// Timing of the duck (lookahead, attack, hold, recovery, minimum pause). `DuckTiming::classic()` = the original
    /// symmetric fade.
    pub timing: DuckTiming,
}

/// One breakpoint of the duck curve: linear gain (1 = untouched) at a timeline time.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CurvePoint {
    /// Timeline time.
    pub time: Time,
    /// Linear gain.
    pub gain: f32,
}

/// N8b: pauses inside dialogue clips, so the live duck releases there. Implementations read analyzed media; they are
/// called from the mix thread and must never block on decoding: `None` = not known yet (the whole clip then ducks).
pub trait DialogueSilenceProvider {
    /// Pauses of `clip` in timeline time as heard through a track fader of `track_volume_db`, or `None` when not known yet.
    fn silences(&self, clip: &Clip, track_volume_db: f64) -> Option<Vec<TimeRange>>;
}

impl LiveDucking {
    /// The user-defaults key of the amount.
    pub const DEFAULTS_KEY: &'static str = "sq.audio.liveDuckingDB";
    /// Amounts offered in Preferences (dB).
    pub const AMOUNT_CHOICES: [f64; 6] = [6.0, 9.0, 12.0, 15.0, 18.0, 24.0];

    /// Classic timing with a symmetric `fade` (Swift `init(amountDB:fade:)`).
    pub fn new(amount_db: f64, fade: Time) -> LiveDucking {
        LiveDucking { amount_db, timing: DuckTimingExt::classic_with_fade(fade) }
    }

    /// With explicit timing, clamped (Swift `init(amountDB:timing:)`).
    pub fn with_timing(amount_db: f64, timing: DuckTiming) -> LiveDucking {
        LiveDucking { amount_db, timing: timing.clamped() }
    }

    /// The ramp down into the duck (the original single "fade"; recovery is `timing.recovery`).
    pub fn fade(&self) -> Time {
        self.timing.attack()
    }

    /// The ramp back up after the duck.
    pub fn recovery(&self) -> Time {
        self.timing.recovery()
    }

    /// No ducking.
    pub fn is_off(&self) -> bool {
        self.amount_db <= 0.0
    }

    /// Linear gain at full duck.
    pub fn floor_gain(&self) -> f32 {
        self.factor()
    }

    pub(crate) fn factor(&self) -> f32 {
        10.0_f64.powf(-self.amount_db / 20.0) as f32
    }

    /// The setting (0 or missing = off).
    pub fn current(defaults: &dyn DefaultsStore) -> Option<LiveDucking> {
        let db = defaults.number(Self::DEFAULTS_KEY).unwrap_or(0.0);
        (db > 0.0).then(|| LiveDucking::with_timing(db.min(40.0), DuckTiming::stored(defaults)))
    }

    /// Stores the setting; `None`, 0, negative or non-finite removes it (off). Amounts above 40 dB are clamped.
    pub fn set_amount(db: Option<f64>, defaults: &mut dyn DefaultsStore) {
        match db {
            Some(db) if db.is_finite() && db > 0.0 => defaults.set_number(Self::DEFAULTS_KEY, db.min(40.0)),
            _ => defaults.remove(Self::DEFAULTS_KEY),
        }
    }

    /// The live ducking a project plays and exports with: its own stored setting when it has one (N8b), else Preferences.
    pub fn resolved(project: Option<&ProjectLiveDucking>, defaults: &dyn DefaultsStore) -> Option<LiveDucking> {
        match project {
            Some(p) => p.live_ducking(),
            None => Self::current(defaults),
        }
    }

    /// Whether live ducking acts on `clip`, a top-level clip sitting on `track`: an audio track not excluded from live
    /// ducking (N8b), the clip's role (clip tag, else track role; audit C18) is Music, and it carries no keys of an
    /// earlier Auto Duck / bake (`duck_key_ids`) unless the track's own role is Music. Old projects sound as before: a
    /// Music-tagged clip off a Music track was keyed and never live-ducked, and stays so; keys on a Music-role track
    /// still duck twice (`clips_ducking_twice` warns).
    pub fn ducks(clip: &Clip, track: &Track) -> bool {
        track.kind == TrackKind::Audio
            && !track.is_excluded_from_live_ducking()
            && track.role_of(clip) == Some(AudioTag::Music)
            && (clip.duck_key_ids.is_empty() || track.audio_role == Some(AudioTag::Music))
    }

    /// The clips live ducking acts on (`ducks`), for the UI and checks; the mix decides per segment.
    pub fn ducked_clip_ids(t: &Timeline) -> BTreeSet<Id> {
        let mut out = BTreeSet::new();
        for tr in t.tracks.iter().filter(|tr| tr.kind == TrackKind::Audio) {
            out.extend(tr.clips().iter().filter(|c| Self::ducks(c, tr)).map(|c| c.id));
        }
        out
    }

    /// The clips a bake keys: Music-role audio clips on audio tracks still in live ducking, including ones keyed by an
    /// earlier run (their keys are replaced). A superset of `ducked_clip_ids` without generators.
    pub fn bake_target_ids(t: &Timeline) -> BTreeSet<Id> {
        let mut out = BTreeSet::new();
        for tr in t.tracks.iter().filter(|tr| tr.kind == TrackKind::Audio && !tr.is_excluded_from_live_ducking()) {
            for c in tr.clips() {
                if c.kind == TrackKind::Audio && !c.is_generator() && tr.role_of(c) == Some(AudioTag::Music) {
                    out.insert(c.id);
                }
            }
        }
        out
    }

    /// Where dialogue is heard: enabled, non-generator clips with role Dialogue (clip tag, else track role) on audible
    /// audio tracks (not muted, not excluded from live ducking; solo respected), merged. `window` limits the work to
    /// clips near it (pass the block range widened by two fades). `silences` (N8b): pauses inside a clip release the duck
    /// there (as the baked Auto Duck does); a clip without silence data yet ducks over its whole length.
    pub fn dialogue_ranges(
        t: &Timeline,
        window: Option<&TimeRange>,
        silences: Option<&dyn DialogueSilenceProvider>,
    ) -> Vec<TimeRange> {
        Self::dialogue_ranges_pauses(t, window, |c, track| silences.and_then(|s| s.silences(c, track.volume_db)))
    }

    /// Same, with the pauses from a closure (`None` or empty = the whole clip).
    pub fn dialogue_ranges_pauses(
        t: &Timeline,
        window: Option<&TimeRange>,
        pauses: impl Fn(&Clip, &Track) -> Option<Vec<TimeRange>>,
    ) -> Vec<TimeRange> {
        let mut out: Vec<TimeRange> = Vec::new();
        let solo = t.tracks.iter().any(|tr| tr.kind == TrackKind::Audio && !tr.is_muted && tr.is_solo);
        for track in &t.tracks {
            if track.kind != TrackKind::Audio
                || track.is_muted
                || (solo && !track.is_solo)
                || track.is_excluded_from_live_ducking()
            {
                continue;
            }
            let role = track.audio_role;
            for clip in
                track.clips().iter().filter(|c| c.audio_tag.or(role) == Some(AudioTag::Dialogue) && c.is_enabled)
            {
                let r = clip.timeline();
                if let Some(w) = window
                    && (r.end() < w.start || r.start > w.end())
                {
                    continue;
                }
                if clip.is_generator() {
                    continue;
                }
                match pauses(clip, track) {
                    Some(s) if !s.is_empty() => out.extend(Self::active_ranges(&r, &s)),
                    _ => out.push(r),
                }
            }
        }
        if out.is_empty() {
            return out;
        }
        let mut merged: Vec<TimeRange> = Vec::new();
        out.sort_by_key(|r| r.start);
        for r in out.into_iter().filter(|r| !r.is_empty()) {
            match merged.last_mut() {
                Some(last) if r.start <= last.end() => {
                    *last = TimeRange::new(last.start, last.end().max(r.end()) - last.start);
                }
                _ => merged.push(r),
            }
        }
        merged
    }

    /// Media of the clips that duck the music (export and bake analyze these before mixing, N8b).
    pub fn dialogue_media(t: &Timeline) -> BTreeSet<Id> {
        let mut out = BTreeSet::new();
        let solo = t.tracks.iter().any(|tr| tr.kind == TrackKind::Audio && !tr.is_muted && tr.is_solo);
        for track in &t.tracks {
            if track.kind == TrackKind::Audio
                && !track.is_muted
                && (!solo || track.is_solo)
                && !track.is_excluded_from_live_ducking()
            {
                for c in track.clips() {
                    if c.is_enabled && !c.is_generator() && track.role_of(c) == Some(AudioTag::Dialogue) {
                        out.insert(c.media);
                    }
                }
            }
        }
        out
    }

    /// Where dialogue is heard on `clip`: its range minus the pauses (sorted output; pauses may overlap or stick out).
    pub fn active_ranges(clip: &TimeRange, silences: &[TimeRange]) -> Vec<TimeRange> {
        let mut out = Vec::new();
        let mut cursor = clip.start;
        let mut sorted = silences.to_vec();
        sorted.sort_by_key(|s| s.start);
        for s in sorted {
            let (a, b) = (s.start.max(clip.start), s.end().min(clip.end()));
            if b <= a {
                continue;
            }
            if a > cursor {
                out.push(TimeRange::new(cursor, a - cursor));
            }
            cursor = cursor.max(b);
        }
        if clip.end() > cursor {
            out.push(TimeRange::new(cursor, clip.end() - cursor));
        }
        out
    }

    /// The dialogue ranges as the duck sees them: each starts `lookahead` earlier and ends `hold` later; ranges whose gap
    /// is at most the minimum pause become one. Returned unchanged for the classic timing.
    pub fn expanded(&self, ranges: &[TimeRange]) -> Vec<TimeRange> {
        let tm = &self.timing;
        if !(tm.lookahead_ms > 0.0 || tm.hold_ms > 0.0 || tm.min_pause_ms > 0.0) {
            return ranges.to_vec();
        }
        let (look, hold, pause) = (tm.lookahead(), tm.hold(), tm.min_pause());
        let mut sorted = ranges.to_vec();
        sorted.sort_by_key(|r| r.start);
        let mut out: Vec<TimeRange> = Vec::new();
        for r in sorted {
            let e = TimeRange::from_end(r.start - look, r.end() + hold);
            match out.last_mut() {
                Some(last) if e.start - last.end() <= pause => {
                    *last = TimeRange::from_end(last.start, last.end().max(e.end()));
                }
                _ => out.push(e),
            }
        }
        out
    }

    /// Linear gain at `time`: full ducking inside a range, linear ramps (attack before, recovery after) on both sides,
    /// ranges closer than attack + recovery hold the duck in between (same rule as the baked keys).
    pub fn gain(&self, time: Time, ranges: &[TimeRange]) -> f32 {
        if self.is_off() {
            return 1.0;
        }
        self.raw_gain(time, &self.expanded(ranges))
    }

    pub(crate) fn raw_gain(&self, time: Time, ranges: &[TimeRange]) -> f32 {
        let f = self.factor();
        let (attack, recovery) = (self.timing.attack(), self.timing.recovery());
        let secs = |t: Time| t.value() as f64 / t.timescale() as f64;
        let (attack_d, recovery_d) = (secs(attack), secs(recovery));
        let mut best: f32 = 1.0;
        for (i, r) in ranges.iter().enumerate() {
            if i + 1 < ranges.len()
                && ranges[i + 1].start - r.end() <= recovery + attack
                && time >= r.end()
                && time <= ranges[i + 1].start
            {
                return f;
            }
            if time >= r.start && time <= r.end() {
                return f;
            }
            let g = if time < r.start {
                let d = r.start - time;
                if d >= attack {
                    continue;
                }
                f + (1.0 - f) * (secs(d) / attack_d) as f32
            } else {
                let d = time - r.end();
                if d >= recovery {
                    continue;
                }
                f + (1.0 - f) * (secs(d) / recovery_d) as f32
            };
            best = best.min(g);
        }
        best
    }

    /// How far outside the dialogue ranges the duck reaches (window padding for callers that fetch ranges near a block).
    pub fn reach(&self) -> Time {
        let tm = &self.timing;
        tm.lookahead() + tm.hold() + tm.attack() + tm.recovery() + tm.min_pause()
    }

    /// N8b: the duck as a polyline over `window` (what the timeline draws on a Music track): the gain at the window edges
    /// and at every ramp corner inside it; linear in between, exactly `gain`. Empty when ducking is off.
    pub fn curve(&self, ranges: &[TimeRange], window: &TimeRange) -> Vec<CurvePoint> {
        if self.is_off() || window.is_empty() {
            return Vec::new();
        }
        let ranges = self.expanded(ranges);
        let mut times = vec![window.start, window.end()];
        for r in &ranges {
            for t in [r.start - self.timing.attack(), r.start, r.end(), r.end() + self.timing.recovery()] {
                if t > window.start && t < window.end() {
                    times.push(t);
                }
            }
        }
        times.sort();
        let mut out: Vec<CurvePoint> = Vec::new();
        for t in times {
            if out.last().map(|p| p.time) != Some(t) {
                out.push(CurvePoint { time: t, gain: self.raw_gain(t, &ranges) });
            }
        }
        out
    }

    /// N8b bake: writes the live duck curve as volume keys (`apply_ducking`, same ranges, amount, fade and merge rule) on
    /// every bake target (`bake_target_ids`: Music-role clips on tracks still in live ducking), then excludes every
    /// Music-ROLE track still in live ducking (as before C18, also empty ones). Other tracks are never excluded (a
    /// Dialogue track must keep ducking): their keyed Music clips leave live ducking through their keys (`ducks`).
    /// Without dialogue nothing changes. Returns the number of keys added. `silences`: the same pause data live playback
    /// uses, so the bake matches what was heard.
    pub fn bake(
        &self,
        t: &mut Timeline,
        silences: Option<&dyn DialogueSilenceProvider>,
        ids: &mut dyn IdSource,
    ) -> usize {
        if self.is_off() {
            return 0;
        }
        let ranges = Self::dialogue_ranges(t, None, silences);
        if ranges.is_empty() {
            return 0;
        }
        let bake_ranges = self.expanded(&ranges);
        let targets = Self::bake_target_ids(t);
        let mut added = 0;
        for i in 0..t.tracks.len() {
            if t.tracks[i].kind != TrackKind::Audio || t.tracks[i].is_excluded_from_live_ducking() {
                continue;
            }
            let clips: Vec<Clip> = t.tracks[i].clips().iter().filter(|c| targets.contains(&c.id)).cloned().collect();
            for mut c in clips {
                let n = c.apply_ducking(
                    &bake_ranges,
                    self.amount_db,
                    self.timing.attack(),
                    Some(self.timing.recovery()),
                    ids,
                );
                t.tracks[i].replace(c); // same id, place and length: cannot fail
                added += n;
            }
            if t.tracks[i].audio_role == Some(AudioTag::Music) {
                t.tracks[i].set_excluded_from_live_ducking(true);
            }
        }
        added
    }

    /// Clips that would duck twice: they carry keys of an earlier Auto Duck / bake (`duck_key_ids`) and live ducking still
    /// ducks them. Live ducking must be on for this to matter, so the caller only asks while it is. Nothing is rewritten
    /// on load.
    pub fn clips_ducking_twice(t: &Timeline) -> Vec<Id> {
        let ducked = Self::ducked_clip_ids(t);
        t.tracks
            .iter()
            .flat_map(|tr| tr.clips())
            .filter(|c| ducked.contains(&c.id) && !c.duck_key_ids.is_empty())
            .map(|c| c.id)
            .collect()
    }

    /// Removes those keys again (the clip's own volume line stays), leaving live ducking as the only duck. Returns the
    /// clips fixed.
    pub fn remove_keys_ducking_twice(t: &mut Timeline) -> usize {
        let ids = Self::clips_ducking_twice(t);
        for id in &ids {
            let found = t.tracks.iter().position(|tr| tr.clips().iter().any(|c| c.id == *id));
            let Some(ti) = found else { continue };
            let Some(mut c) = t.tracks[ti].clip(*id).cloned() else { continue };
            c.remove_duck_keys(); // drops exactly the generated keys, adds none
            t.tracks[ti].replace(c);
        }
        ids.len()
    }

    /// Per-frame gains of `[start_frame, start_frame + out.len())` into `out`.
    pub fn fill(&self, out: &mut [f32], start_frame: i64, rate: i64, ranges: &[TimeRange]) {
        if self.is_off() || ranges.is_empty() {
            out.fill(1.0);
            return;
        }
        let ranges = self.expanded(ranges);
        for (i, o) in out.iter_mut().enumerate() {
            *o = self.raw_gain(Time::new(start_frame + i as i64, rate), &ranges);
        }
    }
}

/// `extension ProjectLiveDucking` (the type is in the model).
pub trait ProjectLiveDuckingExt: Sized {
    /// Swift `init(isOn:amountDB:timing:)`: classic timing is stored as `None`.
    fn with(is_on: bool, amount_db: f64, timing: Option<DuckTiming>) -> Self;
    /// What the mix uses: `None` when off.
    fn live_ducking(&self) -> Option<LiveDucking>;
}

impl ProjectLiveDuckingExt for ProjectLiveDucking {
    fn with(is_on: bool, amount_db: f64, timing: Option<DuckTiming>) -> Self {
        ProjectLiveDucking { is_on, amount_db, timing: timing.filter(|t| *t != DuckTiming::classic()) }
    }

    fn live_ducking(&self) -> Option<LiveDucking> {
        if !self.is_on || !self.amount_db.is_finite() || self.amount_db <= 0.0 {
            return None;
        }
        let timing = self.timing.clone().unwrap_or_else(DuckTiming::classic);
        Some(LiveDucking::with_timing(self.amount_db.clamp(1.0, 40.0), timing))
    }
}

/// `extension Project`.
pub trait ProjectLiveDuckingSettingsExt {
    /// A stored project ducking setting or a track excluded from live ducking (gates ProjectFile v43).
    fn contains_live_ducking_settings(&self) -> bool;
}

impl ProjectLiveDuckingSettingsExt for Project {
    fn contains_live_ducking_settings(&self) -> bool {
        self.live_ducking.is_some()
            || self.timelines.iter().any(|t| t.tracks.iter().any(|tr| tr.is_excluded_from_live_ducking()))
    }
}

/// `DuckTiming` logic (the type is in the model). `classic` is what every project did before these controls existed: a
/// 300 ms fade each way, nothing else, so old projects sound the same. `resolve` = the Resolve manual's Ducker defaults
/// (lookahead 15 ms, rise 10 ms, hold 150 ms, recovery 750 ms; docs/research/AUDIO-EFFECTS.md). Mapping of "rise" to our
/// attack ramp is our reading of the manual (unsourced).
pub trait DuckTimingExt: Sized {
    /// Preferences keys (user defaults), next to `LiveDucking::DEFAULTS_KEY`.
    const LOOKAHEAD_KEY: &'static str = "sq.audio.liveDuckingLookaheadMs";
    /// Attack key.
    const ATTACK_KEY: &'static str = "sq.audio.liveDuckingAttackMs";
    /// Hold key.
    const HOLD_KEY: &'static str = "sq.audio.liveDuckingHoldMs";
    /// Recovery key.
    const RECOVERY_KEY: &'static str = "sq.audio.liveDuckingRecoveryMs";
    /// Minimum pause key.
    const MIN_PAUSE_KEY: &'static str = "sq.audio.liveDuckingMinPauseMs";

    /// `lookaheadMs: 0, attackMs: 300, holdMs: 0, recoveryMs: 300, minPauseMs: 0`.
    fn classic() -> Self;
    /// The Resolve Ducker defaults.
    fn resolve() -> Self;
    /// Ours (unsourced): bridges short breaths so speech does not pump the music.
    fn speech() -> Self;
    /// Swift `classic(fade:)`: attack and recovery from a symmetric fade.
    fn classic_with_fade(fade: Time) -> Self;
    /// Every value finite and inside its range.
    fn clamped(&self) -> Self;
    /// Converts back from milliseconds without losing a frame: a value that is a whole number of frames at a common frame
    /// rate becomes exactly that fraction (1/30, 1001/30000), anything else keeps microsecond precision.
    fn time_from_ms(ms: f64) -> Time;
    /// Lookahead as time.
    fn lookahead(&self) -> Time;
    /// Attack as time.
    fn attack(&self) -> Time;
    /// Hold as time.
    fn hold(&self) -> Time;
    /// Recovery as time.
    fn recovery(&self) -> Time;
    /// Minimum pause as time.
    fn min_pause(&self) -> Time;
    /// The stored preference; a missing key keeps the classic value.
    fn stored(d: &dyn DefaultsStore) -> Self;
    /// Stores the preference (classic removes the keys).
    fn store(t: &Self, d: &mut dyn DefaultsStore);
}

impl DuckTimingExt for DuckTiming {
    fn classic() -> Self {
        DuckTiming { lookahead_ms: 0.0, attack_ms: 300.0, hold_ms: 0.0, recovery_ms: 300.0, min_pause_ms: 0.0 }
    }

    fn resolve() -> Self {
        DuckTiming { lookahead_ms: 15.0, attack_ms: 10.0, hold_ms: 150.0, recovery_ms: 750.0, min_pause_ms: 0.0 }
    }

    fn speech() -> Self {
        DuckTiming { lookahead_ms: 30.0, attack_ms: 80.0, hold_ms: 250.0, recovery_ms: 900.0, min_pause_ms: 400.0 }
    }

    fn classic_with_fade(fade: Time) -> Self {
        let ms = fade.value() as f64 * 1000.0 / fade.timescale() as f64;
        DuckTiming { lookahead_ms: 0.0, attack_ms: ms, hold_ms: 0.0, recovery_ms: ms, min_pause_ms: 0.0 }.clamped()
    }

    fn clamped(&self) -> Self {
        let c = |v: f64, hi: f64| if v.is_finite() { v.max(0.0).min(hi) } else { 0.0 };
        DuckTiming {
            lookahead_ms: c(self.lookahead_ms, 500.0),
            attack_ms: c(self.attack_ms, 2000.0),
            hold_ms: c(self.hold_ms, 2000.0),
            recovery_ms: c(self.recovery_ms, 5000.0),
            min_pause_ms: c(self.min_pause_ms, 2000.0),
        }
    }

    fn time_from_ms(ms: f64) -> Time {
        let sec = ms / 1000.0;
        if sec.is_finite() && sec.abs() < 1_000_000.0 {
            for d in [1000_i64, 24, 25, 30, 50, 60, 120, 24_000, 30_000, 60_000] {
                let n = (sec * d as f64).round();
                if (sec * d as f64 - n).abs() < 1e-6 {
                    return Time::new(n as i64, d);
                }
            }
        }
        Time::new((ms * 1000.0).round() as i64, 1_000_000)
    }

    fn lookahead(&self) -> Time {
        Self::time_from_ms(self.lookahead_ms)
    }

    fn attack(&self) -> Time {
        Self::time_from_ms(self.attack_ms)
    }

    fn hold(&self) -> Time {
        Self::time_from_ms(self.hold_ms)
    }

    fn recovery(&self) -> Time {
        Self::time_from_ms(self.recovery_ms)
    }

    fn min_pause(&self) -> Time {
        Self::time_from_ms(self.min_pause_ms)
    }

    fn stored(d: &dyn DefaultsStore) -> Self {
        let v = |k: &str, def: f64| d.number(k).unwrap_or(def);
        DuckTiming {
            lookahead_ms: v(Self::LOOKAHEAD_KEY, 0.0),
            attack_ms: v(Self::ATTACK_KEY, 300.0),
            hold_ms: v(Self::HOLD_KEY, 0.0),
            recovery_ms: v(Self::RECOVERY_KEY, 300.0),
            min_pause_ms: v(Self::MIN_PAUSE_KEY, 0.0),
        }
        .clamped()
    }

    fn store(t: &Self, d: &mut dyn DefaultsStore) {
        let t = t.clamped();
        let keys = [Self::LOOKAHEAD_KEY, Self::ATTACK_KEY, Self::HOLD_KEY, Self::RECOVERY_KEY, Self::MIN_PAUSE_KEY];
        if t == Self::classic() {
            for k in keys {
                d.remove(k);
            }
            return;
        }
        let values = [t.lookahead_ms, t.attack_ms, t.hold_ms, t.recovery_ms, t.min_pause_ms];
        for (k, v) in keys.into_iter().zip(values) {
            d.set_number(k, v);
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::audio_role::tests::{clip, timeline, track};
    use crate::ducking::Ducking;
    use sq_core_model::AnimatedProperty;
    use sq_core_time::SequentialIds;
    use std::collections::BTreeMap;

    #[derive(Default)]
    pub(crate) struct MemoryDefaults(BTreeMap<String, f64>);

    impl DefaultsStore for MemoryDefaults {
        fn number(&self, key: &str) -> Option<f64> {
            self.0.get(key).copied()
        }
        fn set_number(&mut self, key: &str, value: f64) {
            self.0.insert(key.to_string(), value);
        }
        fn remove(&mut self, key: &str) {
            self.0.remove(key);
        }
    }

    fn t(a: i64, b: i64) -> Time {
        Time::new(a, b)
    }
    fn sec(a: i64, len: i64) -> TimeRange {
        TimeRange::new(t(a, 1), t(len, 1))
    }
    fn ms(v: i64) -> Time {
        t(v, 1000)
    }
    pub(crate) fn live() -> LiveDucking {
        LiveDucking::new(12.0, t(1, 2))
    }

    /// A dialogue track with `dialogue` clips and a music track with one 100 s clip.
    pub(crate) fn two_track_timeline(dialogue: &[(i64, i64)]) -> Timeline {
        let d = track(1, Some(AudioTag::Dialogue), dialogue.iter().map(|(s, l)| clip(*s, *l, None)).collect());
        let m = track(2, Some(AudioTag::Music), vec![clip(0, 100, None)]);
        timeline(vec![d, m])
    }

    fn abs_diff(a: f32, b: f32) -> f32 {
        (a - b).abs()
    }

    #[test]
    fn dialogue_ranges_come_from_dialogue_role_tracks_only() {
        let tl = two_track_timeline(&[(10, 5), (30, 5)]);
        assert_eq!(LiveDucking::dialogue_ranges(&tl, None, None), vec![sec(10, 5), sec(30, 5)]);
    }

    #[test]
    fn muted_tracks_and_disabled_clips_do_not_duck() {
        let mut tl = two_track_timeline(&[(10, 5)]);
        tl.tracks[0].is_muted = true;
        assert!(LiveDucking::dialogue_ranges(&tl, None, None).is_empty());
        let mut tl = two_track_timeline(&[(10, 5)]);
        let mut c = tl.tracks[0].clips()[0].clone();
        c.is_enabled = false;
        tl.tracks[0].replace(c);
        assert!(LiveDucking::dialogue_ranges(&tl, None, None).is_empty());
    }

    #[test]
    fn gain_is_full_outside_ramps_and_ducked_inside() {
        let r = [sec(10, 5)];
        let f = 10.0_f64.powf(-12.0 / 20.0) as f32;
        let l = live();
        assert_eq!(l.gain(t(5, 1), &r), 1.0);
        assert!(abs_diff(l.gain(t(12, 1), &r), f) < 1e-6);
        let mid = (1.0 + f) / 2.0; // half way through the 0.5 s ramps
        assert!(abs_diff(l.gain(t(39, 4), &r), mid) < 1e-5);
        assert!(abs_diff(l.gain(t(61, 4), &r), mid) < 1e-5);
        assert_eq!(l.gain(t(16, 1), &r), 1.0);
    }

    #[test]
    fn close_ranges_stay_ducked_between() {
        let r = [sec(10, 2), TimeRange::new(t(25, 2), t(2, 1))];
        let f = 10.0_f64.powf(-12.0 / 20.0) as f32;
        assert!(abs_diff(live().gain(t(49, 4), &r), f) < 1e-6);
    }

    #[test]
    fn block_gains_match_point_gains() {
        let r = [sec(1, 1)];
        let mut out = vec![0.0_f32; 480];
        let l = live();
        l.fill(&mut out, 24_000, 48_000, &r);
        for i in [0_usize, 100, 479] {
            assert!(abs_diff(out[i], l.gain(t(24_000 + i as i64, 48_000), &r)) < 1e-6);
        }
    }

    #[test]
    fn zero_amount_is_off() {
        let off = LiveDucking::new(0.0, t(1, 2));
        assert!(off.is_off());
        assert_eq!(off.gain(Time::ZERO, &[sec(0, 1)]), 1.0);
    }

    #[test]
    fn set_amount_writes_and_reads_back() {
        let mut d = MemoryDefaults::default();
        assert_eq!(LiveDucking::current(&d), None);
        LiveDucking::set_amount(Some(9.0), &mut d);
        assert_eq!(LiveDucking::current(&d).map(|l| l.amount_db), Some(9.0));
        LiveDucking::set_amount(None, &mut d);
        assert_eq!(LiveDucking::current(&d), None);
        assert_eq!(d.number(LiveDucking::DEFAULTS_KEY), None);
    }

    #[test]
    fn amount_is_clamped_and_off_for_nonsense() {
        let mut d = MemoryDefaults::default();
        LiveDucking::set_amount(Some(99.0), &mut d);
        assert_eq!(LiveDucking::current(&d).map(|l| l.amount_db), Some(40.0));
        LiveDucking::set_amount(Some(-3.0), &mut d);
        assert_eq!(LiveDucking::current(&d), None);
        LiveDucking::set_amount(Some(f64::NAN), &mut d);
        assert_eq!(LiveDucking::current(&d), None);
        assert!(LiveDucking::AMOUNT_CHOICES.contains(&Ducking::DEFAULT_AMOUNT_DB));
    }

    #[test]
    fn excluded_tracks_take_no_part() {
        let mut tl = two_track_timeline(&[(10, 5)]);
        assert!(!LiveDucking::dialogue_ranges(&tl, None, None).is_empty());
        tl.tracks[0].set_excluded_from_live_ducking(true);
        assert!(LiveDucking::dialogue_ranges(&tl, None, None).is_empty());
        let mut tl = two_track_timeline(&[(10, 5)]);
        assert_eq!(LiveDucking::ducked_clip_ids(&tl), [tl.tracks[1].clips()[0].id].into());
        tl.tracks[1].set_excluded_from_live_ducking(true);
        assert!(LiveDucking::ducked_clip_ids(&tl).is_empty());
    }

    #[test]
    fn project_setting_overrides_preferences() {
        let mut d = MemoryDefaults::default();
        LiveDucking::set_amount(Some(9.0), &mut d);
        let amount = |p: Option<ProjectLiveDucking>, d: &MemoryDefaults| {
            LiveDucking::resolved(p.as_ref(), d).map(|l| l.amount_db)
        };
        assert_eq!(amount(None, &d), Some(9.0));
        assert_eq!(amount(Some(ProjectLiveDucking::with(true, 18.0, None)), &d), Some(18.0));
        assert_eq!(amount(Some(ProjectLiveDucking::with(false, 18.0, None)), &d), None);
        assert_eq!(amount(Some(ProjectLiveDucking::with(true, 99.0, None)), &d), Some(40.0));
        LiveDucking::set_amount(None, &mut d);
        assert_eq!(amount(None, &d), None);
    }

    #[test]
    fn dialogue_media_are_the_heard_dialogue_clips() {
        let mut tl = two_track_timeline(&[(10, 5), (30, 5)]);
        let heard: BTreeSet<Id> = tl.tracks[0].clips().iter().map(|c| c.media).collect();
        assert_eq!(LiveDucking::dialogue_media(&tl), heard);
        let mut off = tl.tracks[0].clips()[1].clone();
        off.is_enabled = false;
        tl.tracks[0].replace(off);
        assert_eq!(LiveDucking::dialogue_media(&tl), [tl.tracks[0].clips()[0].media].into());
        tl.tracks[0].is_muted = true;
        assert!(LiveDucking::dialogue_media(&tl).is_empty());
    }

    // MARK: bake

    #[test]
    fn baked_keys_reproduce_the_live_curve_and_exclude_the_track() {
        let mut tl = two_track_timeline(&[(10, 5), (30, 5)]);
        let ranges = LiveDucking::dialogue_ranges(&tl, None, None);
        let (l, mut ids) = (live(), SequentialIds::default());
        let added = l.bake(&mut tl, None, &mut ids);
        assert!(added > 0);
        assert!(tl.tracks[1].is_excluded_from_live_ducking());
        assert!(!tl.tracks[0].is_excluded_from_live_ducking()); // the dialogue track keeps ducking other music
        assert!(LiveDucking::ducked_clip_ids(&tl).is_empty());
        let c = &tl.tracks[1].clips()[0];
        assert_eq!(c.duck_key_ids.len(), added);
        let probes = [t(5, 1), t(39, 4), t(12, 1), t(61, 4), t(16, 1), t(20, 1), t(119, 4), t(32, 1), t(36, 1)];
        for probe in probes {
            let baked = c.animation.volume.value_at_local(probe - c.start);
            assert!((baked - l.gain(probe, &ranges) as f64).abs() < 1e-5, "at {probe:?}");
        }
    }

    #[test]
    fn bake_keeps_the_clips_own_volume() {
        let mut tl = two_track_timeline(&[(10, 5)]);
        let mut c = tl.tracks[1].clips()[0].clone();
        c.animation.volume = AnimatedProperty::new(0.5);
        tl.tracks[1].replace(c);
        live().bake(&mut tl, None, &mut SequentialIds::default());
        let v = &tl.tracks[1].clips()[0].animation.volume;
        assert!((v.value_at_local(t(5, 1)) - 0.5).abs() < 1e-9);
        assert!((v.value_at_local(t(12, 1)) - 0.5 * 10.0_f64.powf(-12.0 / 20.0)).abs() < 1e-6);
    }

    #[test]
    fn without_dialogue_nothing_is_baked_or_excluded() {
        let mut tl = two_track_timeline(&[]);
        assert_eq!(live().bake(&mut tl, None, &mut SequentialIds::default()), 0);
        assert!(!tl.tracks[1].is_excluded_from_live_ducking());
        assert!(tl.tracks[1].clips()[0].animation.volume.track.is_empty());
    }

    #[test]
    fn excluded_and_non_music_tracks_are_left_alone() {
        let mut tl = two_track_timeline(&[(10, 5)]);
        let other = track(3, Some(AudioTag::Sfx), vec![clip(0, 100, None)]);
        let mut excluded = track(4, Some(AudioTag::Music), vec![clip(0, 100, None)]);
        excluded.set_excluded_from_live_ducking(true);
        tl.tracks.extend([other, excluded]);
        live().bake(&mut tl, None, &mut SequentialIds::default());
        assert!(
            tl.tracks[2].clips()[0].animation.volume.track.is_empty() && !tl.tracks[2].is_excluded_from_live_ducking()
        );
        assert!(tl.tracks[3].clips()[0].animation.volume.track.is_empty());
    }

    // MARK: double duck

    fn timeline_with_old_auto_duck() -> Timeline {
        let mut tl = two_track_timeline(&[(10, 5)]);
        let mut c = tl.tracks[1].clips()[0].clone();
        c.apply_ducking(&[sec(10, 5)], 12.0, Ducking::DEFAULT_FADE, None, &mut SequentialIds::default());
        tl.tracks[1].replace(c);
        tl
    }

    #[test]
    fn old_keys_on_a_live_ducked_track_are_found() {
        let tl = timeline_with_old_auto_duck();
        assert_eq!(LiveDucking::clips_ducking_twice(&tl), vec![tl.tracks[1].clips()[0].id]);
    }

    #[test]
    fn no_double_when_the_track_is_excluded_or_keys_are_absent() {
        let mut tl = timeline_with_old_auto_duck();
        tl.tracks[1].set_excluded_from_live_ducking(true);
        assert!(LiveDucking::clips_ducking_twice(&tl).is_empty());
        assert!(LiveDucking::clips_ducking_twice(&two_track_timeline(&[(10, 5)])).is_empty());
    }

    #[test]
    fn removing_the_keys_restores_the_clean_volume_line() {
        let mut tl = two_track_timeline(&[(10, 5)]);
        let mut c = tl.tracks[1].clips()[0].clone();
        c.animation.volume = AnimatedProperty::new(0.5);
        c.apply_ducking(&[sec(10, 5)], 12.0, Ducking::DEFAULT_FADE, None, &mut SequentialIds::default());
        tl.tracks[1].replace(c);
        assert!(LiveDucking::remove_keys_ducking_twice(&mut tl) > 0);
        let after = &tl.tracks[1].clips()[0];
        assert!(after.duck_key_ids.is_empty() && after.animation.volume.track.keys.is_empty());
        assert!((after.animation.volume.value_at_local(t(12, 1)) - 0.5).abs() < 1e-9);
        assert!(LiveDucking::clips_ducking_twice(&tl).is_empty());
        assert!(!tl.tracks[1].is_excluded_from_live_ducking()); // live ducking keeps ducking: that is the point
    }

    #[test]
    fn rebake_replaces_old_keys_and_never_leaves_both_active() {
        let mut tl = timeline_with_old_auto_duck();
        let l = live();
        assert!(l.bake(&mut tl, None, &mut SequentialIds::default()) > 0);
        assert!(LiveDucking::ducked_clip_ids(&tl).is_empty());
        assert!(LiveDucking::clips_ducking_twice(&tl).is_empty());
        let c = &tl.tracks[1].clips()[0];
        let ranges = LiveDucking::dialogue_ranges(&tl, None, None);
        // only the new bake's keys exist and they equal the live curve
        assert_eq!(c.duck_key_ids.len(), c.animation.volume.track.keys.len());
        for p in [t(5, 1), t(12, 1), t(39, 4), t(16, 1)] {
            assert!((c.animation.volume.value_at_local(p - c.start) - l.gain(p, &ranges) as f64).abs() < 1e-5);
        }
    }

    // MARK: silences

    struct Fixed(BTreeMap<Id, Vec<TimeRange>>);

    impl DialogueSilenceProvider for Fixed {
        fn silences(&self, clip: &Clip, _track_volume_db: f64) -> Option<Vec<TimeRange>> {
            self.0.get(&clip.id).cloned()
        }
    }

    fn pauses_for(tl: &Timeline, p: &[TimeRange]) -> Fixed {
        Fixed([(tl.tracks[0].clips()[0].id, p.to_vec())].into())
    }

    #[test]
    fn pause_splits_the_dialogue_range() {
        let tl = two_track_timeline(&[(10, 10)]);
        let s = pauses_for(&tl, &[sec(13, 3)]);
        assert_eq!(LiveDucking::dialogue_ranges(&tl, None, Some(&s)), vec![sec(10, 3), sec(16, 4)]);
    }

    #[test]
    fn missing_silence_data_ducks_the_whole_clip() {
        let tl = two_track_timeline(&[(10, 10)]);
        assert_eq!(LiveDucking::dialogue_ranges(&tl, None, Some(&Fixed(BTreeMap::new()))), vec![sec(10, 10)]);
    }

    #[test]
    fn overlapping_clip_keeps_the_duck_through_a_pause() {
        let mut tl = two_track_timeline(&[(10, 10)]);
        tl.tracks.push(track(5, Some(AudioTag::Dialogue), vec![clip(12, 6, None)]));
        let s = pauses_for(&tl, &[sec(13, 3)]);
        assert_eq!(LiveDucking::dialogue_ranges(&tl, None, Some(&s)), vec![sec(10, 10)]);
    }

    #[test]
    fn pause_releases_the_music() {
        let tl = two_track_timeline(&[(10, 10)]);
        let s = pauses_for(&tl, &[sec(12, 4)]);
        let ranges = LiveDucking::dialogue_ranges(&tl, None, Some(&s));
        assert_eq!(live().gain(t(14, 1), &ranges), 1.0);
        assert!(live().gain(t(11, 1), &ranges) < 0.3);
    }

    #[test]
    fn active_ranges_subtract_the_pauses() {
        let r = LiveDucking::active_ranges(&sec(0, 10), &[sec(8, 5), sec(-2, 3), sec(4, 1)]);
        assert_eq!(r, vec![sec(1, 3), sec(5, 3)]);
    }

    #[test]
    fn bake_honours_the_pauses_like_live_playback() {
        let mut tl = two_track_timeline(&[(10, 10)]);
        let s = pauses_for(&tl, &[sec(12, 4)]);
        live().bake(&mut tl, Some(&s), &mut SequentialIds::default());
        let music = &tl.tracks[1].clips()[0];
        assert!((music.volume(t(14, 1)) - 1.0).abs() < 1e-9);
        assert!(music.volume(t(11, 1)) < 0.3);
    }

    // MARK: curve

    #[test]
    fn no_dialogue_is_a_flat_line() {
        let p = live().curve(&[], &sec(0, 30));
        assert!(p.len() == 2 && p.iter().all(|x| x.gain == 1.0));
        assert!(p[0].time == Time::ZERO && p[1].time == t(30, 1));
    }

    #[test]
    fn ramps_around_one_range() {
        let l = live();
        let f = l.factor();
        let p = l.curve(&[sec(10, 10)], &sec(0, 30));
        let times: Vec<Time> = p.iter().map(|x| x.time).collect();
        assert_eq!(
            times,
            vec![t(0, 1), t(19, 2), t(10, 1), t(20, 1), t(41, 2), t(30, 1)]
                .into_iter()
                .collect::<std::collections::BTreeSet<_>>()
                .into_iter()
                .collect::<Vec<_>>()
        );
        assert_eq!(p.iter().map(|x| x.gain).collect::<Vec<_>>(), vec![1.0, 1.0, f, f, 1.0, 1.0]);
    }

    #[test]
    fn close_ranges_hold_the_duck_between_in_the_curve() {
        // gap 0.5 s <= two fades: one dip, no release in between
        let l = live();
        let p = l.curve(&[sec(10, 2), TimeRange::new(t(25, 2), t(2, 1))], &sec(0, 30));
        assert!(p.iter().filter(|x| x.time > t(10, 1) && x.time < t(29, 2)).all(|x| x.gain == l.factor()));
    }

    #[test]
    fn window_clips_the_points() {
        let l = live();
        let p = l.curve(&[sec(10, 10)], &sec(12, 4));
        assert!(p.first().map(|x| x.time) == Some(t(12, 1)) && p.last().map(|x| x.time) == Some(t(16, 1)));
        assert!(p.iter().all(|x| x.gain == l.factor()));
    }

    #[test]
    fn off_has_no_curve() {
        assert!(LiveDucking::new(0.0, Ducking::DEFAULT_FADE).curve(&[sec(1, 1)], &sec(0, 5)).is_empty());
    }

    fn d(x: Time) -> f64 {
        x.value() as f64 / x.timescale() as f64
    }

    #[test]
    fn curve_matches_gain_everywhere() {
        let l = live();
        let ranges = [sec(3, 2), sec(9, 4), sec(14, 1)];
        let p = l.curve(&ranges, &sec(0, 20));
        for w in p.windows(2) {
            let (a, b) = (w[0], w[1]);
            let mid = Time::new((((d(a.time) + d(b.time)) / 2.0) * 1000.0).round() as i64, 1000);
            let lerp = a.gain + (b.gain - a.gain) * ((d(mid) - d(a.time)) / (d(b.time) - d(a.time))) as f32;
            assert!(abs_diff(l.gain(mid, &ranges), lerp) < 1e-3);
        }
    }

    // MARK: timing

    #[test]
    fn classic_timing_is_the_old_behaviour() {
        let old = LiveDucking::new(12.0, t(1, 2));
        assert_eq!(
            old.timing,
            DuckTiming { lookahead_ms: 0.0, attack_ms: 500.0, hold_ms: 0.0, recovery_ms: 500.0, min_pause_ms: 0.0 }
        );
        let ranges = [sec(10, 4), sec(15, 2), sec(40, 3)];
        let f = old.factor();
        for k in (0..6000).step_by(7) {
            let time = Time::new(k, 100);
            let g = old.gain(time, &ranges);
            // Reference: the original single-fade rule.
            let mut expect: f32 = 1.0;
            for (i, r) in ranges.iter().enumerate() {
                if i + 1 < ranges.len()
                    && ranges[i + 1].start - r.end() <= old.fade() + old.fade()
                    && time >= r.end()
                    && time <= ranges[i + 1].start
                {
                    expect = f;
                    break;
                }
                let dd = if time < r.start {
                    r.start - time
                } else if time > r.end() {
                    time - r.end()
                } else {
                    Time::ZERO
                };
                let x = if dd == Time::ZERO {
                    f
                } else if dd >= old.fade() {
                    1.0
                } else {
                    f + (1.0 - f) * (dd.value() as f64 / dd.timescale() as f64 / 0.5) as f32
                };
                expect = expect.min(x);
            }
            assert_eq!(g, expect);
        }
    }

    fn timed(amount: f64, look: f64, attack: f64, hold: f64, recovery: f64, pause: f64) -> LiveDucking {
        LiveDucking::with_timing(
            amount,
            DuckTiming {
                lookahead_ms: look,
                attack_ms: attack,
                hold_ms: hold,
                recovery_ms: recovery,
                min_pause_ms: pause,
            },
        )
    }

    #[test]
    fn lookahead_starts_the_duck_earlier() {
        let l = timed(12.0, 100.0, 0.0, 0.0, 0.0, 0.0);
        let r = [sec(10, 2)];
        assert_eq!(l.gain(t(9, 1) + ms(950), &r), l.factor());
        assert_eq!(l.gain(t(9, 1) + ms(850), &r), 1.0);
    }

    #[test]
    fn hold_keeps_the_duck_after_the_dialogue() {
        let l = timed(12.0, 0.0, 0.0, 200.0, 0.0, 0.0);
        let r = [sec(10, 2)];
        assert_eq!(l.gain(t(12, 1) + ms(150), &r), l.factor());
        assert_eq!(l.gain(t(12, 1) + ms(250), &r), 1.0);
    }

    #[test]
    fn attack_and_recovery_are_independent_ramps() {
        let l = timed(20.0, 0.0, 100.0, 0.0, 1000.0, 0.0);
        let r = [sec(10, 2)];
        let f = l.factor();
        // half way down (50 ms before), half way up (500 ms after)
        assert!(abs_diff(l.gain(t(10, 1) - ms(50), &r), f + (1.0 - f) * 0.5) < 1e-5);
        assert!(abs_diff(l.gain(t(12, 1) + ms(500), &r), f + (1.0 - f) * 0.5) < 1e-5);
        assert_eq!(l.gain(t(10, 1) - ms(150), &r), 1.0);
        assert_eq!(l.gain(t(12, 1) + ms(1100), &r), 1.0);
    }

    #[test]
    fn minimum_pause_bridges_short_gaps() {
        let r = [sec(10, 2), TimeRange::new(t(12, 1) + ms(300), t(2, 1))];
        let a = timed(12.0, 0.0, 10.0, 0.0, 10.0, 0.0);
        let b = timed(12.0, 0.0, 10.0, 0.0, 10.0, 400.0);
        let mid = t(12, 1) + ms(150);
        assert_eq!(a.gain(mid, &r), 1.0);
        assert_eq!(b.gain(mid, &r), b.factor());
    }

    #[test]
    fn curve_matches_gain_with_timing() {
        let l = LiveDucking::with_timing(12.0, DuckTiming::resolve());
        let ranges = [sec(10, 2), sec(20, 3)];
        let pts = l.curve(&ranges, &sec(0, 40));
        for w in pts.windows(2) {
            let mid = w[0].time + (w[1].time - w[0].time).halved();
            let lerp = (w[0].gain + w[1].gain) / 2.0;
            assert!(abs_diff(l.gain(mid, &ranges), lerp) < 1e-4);
        }
    }

    #[test]
    fn project_setting_keeps_classic_as_none() {
        let p = ProjectLiveDucking::with(true, 9.0, Some(DuckTiming::resolve()));
        assert_eq!(p.live_ducking().map(|l| l.timing), Some(DuckTiming::resolve()));
        let old: ProjectLiveDucking =
            serde_json::from_str(r#"{"isOn":true,"amountDB":12}"#).unwrap_or_else(|e| panic!("{e}"));
        assert!(old.timing.is_none());
        assert_eq!(old.live_ducking().map(|l| l.timing), Some(DuckTiming::classic()));
        assert!(ProjectLiveDucking::with(true, 12.0, Some(DuckTiming::classic())).timing.is_none());
    }

    #[test]
    fn preferences_store_timing() {
        let mut d = MemoryDefaults::default();
        LiveDucking::set_amount(Some(12.0), &mut d);
        assert_eq!(LiveDucking::current(&d).map(|l| l.timing), Some(DuckTiming::classic()));
        DuckTiming::store(&DuckTiming::resolve(), &mut d);
        assert_eq!(LiveDucking::current(&d).map(|l| l.timing), Some(DuckTiming::resolve()));
        DuckTiming::store(&DuckTiming::classic(), &mut d);
        assert_eq!(d.number(DuckTiming::HOLD_KEY), None);
    }

    #[test]
    fn baked_keys_reproduce_the_timed_curve() {
        let l = timed(12.0, 200.0, 100.0, 500.0, 400.0, 0.0);
        let mut tl = two_track_timeline(&[(10, 5), (30, 5)]);
        let ranges = LiveDucking::dialogue_ranges(&tl, None, None);
        assert!(l.bake(&mut tl, None, &mut SequentialIds::default()) > 0);
        let c = &tl.tracks[1].clips()[0];
        let probes =
            [t(19, 2), t(99, 10), t(10, 1), t(15, 1), t(155, 10), t(16, 1), t(171, 10), t(20, 1), t(36, 1), t(367, 10)];
        for probe in probes {
            let baked = c.animation.volume.value_at_local(probe - c.start);
            assert!((baked - l.gain(probe, &ranges) as f64).abs() < 1e-5, "at {probe:?}");
        }
    }

    #[test]
    fn project_settings_gate_the_file_version() {
        let mut p = Project::new(Id::from_u128(1), "P", vec![], vec![two_track_timeline(&[(10, 5)])]);
        assert!(!p.contains_live_ducking_settings());
        p.live_ducking = Some(ProjectLiveDucking::with(true, 15.0, None));
        assert!(p.contains_live_ducking_settings());
        p.live_ducking = None;
        p.timelines[0].tracks[1].set_excluded_from_live_ducking(true);
        assert!(p.contains_live_ducking_settings());
    }
}
