// Swift: ShellAudioTools.swift
//! The audio tools of the Clip menu that read decoded waveforms: Bake Live Duck to Keys (Auto Duck), Remove Silences and
//! Sync Audio to Reference. Translated from the Mac AppController+AudioGain (`requestAutoDuck`, `bakeLiveDuckToKeys`,
//! `requestRemoveSilences`, `silences(of:)`) and AppController+SyncAudio; the waveforms come from the host's cache through
//! [`ShellServices::waveform`] (Windows: FFmpeg peaks, Mac: `TimelineWaveforms`).

use crate::shell_dialog::ShellDialog;
use crate::shell_flow_env::SettingsDefaults;
use crate::shell_flows::ShellRoot;
use crate::shell_form::{NumberField, Row, ShellForm};
use crate::shell_host::{FlowReply, ShellEvent, ShellHost};
use sq_core_audio::audio_drift_fit::{AudioDriftFit, AudioSyncMethod};
use sq_core_audio::ducking::Ducking;
use sq_core_audio::live_ducking::{DialogueSilenceProvider, LiveDucking};
use sq_core_model::{Clip, MediaRef};
use sq_core_time::{Id, Time, TimeRange};
use sq_editor_session::{AudioShortform, EditorSession, SilenceSettings};
use sq_media::source_timecode::SourceTimecode;
use sq_media::waveform_data::WaveformData;
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

/// The detection the live duck uses (`WaveformSilences`, SQPlayback): -35 dB, at least 0.6 s.
pub(crate) const SILENCE_THRESHOLD_DB: f64 = -35.0;

/// The shortest pause the live duck hears.
fn duck_minimum_pause() -> Time {
    Time::new(3, 5)
}

/// Dialogue pauses for the bake from the waveforms read before it (`WaveformSilences.forExport` without SQPlayback): a clip
/// whose media has no waveform is unknown, so it ducks whole (fail safe, as on the Mac).
pub(crate) struct ShellDialoguePauses {
    pub waveforms: BTreeMap<Id, Arc<WaveformData>>,
}

impl DialogueSilenceProvider for ShellDialoguePauses {
    fn silences(&self, clip: &Clip, track_volume_db: f64) -> Option<Vec<TimeRange>> {
        self.waveforms
            .get(&clip.media)
            .map(|w| AudioShortform::silences_in(clip, w, track_volume_db, SILENCE_THRESHOLD_DB, duck_minimum_pause()))
    }
}

/// What Sync Audio reads from one file.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ShellSyncFacts {
    /// The start timecode, when the file carries one.
    pub start_timecode: Option<Time>,
    /// The loudness envelope of the sound.
    pub envelope: Vec<f32>,
    /// File creation time in seconds since 1970.
    pub capture_date: Option<f64>,
}

impl ShellSyncFacts {
    /// The Mac `syncFit`: both files with a start timecode, the timecode difference; otherwise the sound fit; when the sound
    /// does not match, the capture dates (to the second).
    pub fn fit(reference: &ShellSyncFacts, other: &ShellSyncFacts) -> Option<AudioDriftFit> {
        if let (Some(a), Some(b)) = (reference.start_timecode, other.start_timecode) {
            return Some(AudioDriftFit::timecode(a, b));
        }
        if !reference.envelope.is_empty()
            && !other.envelope.is_empty()
            && let Some(fit) =
                AudioDriftFit::fit(&reference.envelope, &other.envelope, WaveformData::ENVELOPE_RATE as i64, 8, None)
        {
            return Some(fit);
        }
        let (a, b) = (reference.capture_date?, other.capture_date?);
        // Whole-second capture dates (file creation time), no sub-second placement and no camera metadata date: the same
        // as Swift `ShellAudioTools`.
        let s = |d: f64| Time::new(d.round() as i64, 1);
        Some(AudioDriftFit::capture_date(s(a), s(b)))
    }
}

/// The Remove Silences form: the Mac `SilenceFieldsController` rows (Level, Min. Length, Keep Each Side, preview, hint).
pub(crate) struct ShellSilenceForm;

impl ShellSilenceForm {
    pub(crate) const PREVIEW_ROW: usize = 3;

    pub(crate) fn rows(s: &SilenceSettings) -> Vec<Row> {
        let clamp = |v: f64, r: &std::ops::RangeInclusive<f64>| v.max(*r.start()).min(*r.end());
        let field =
            |id: &str, value: f64, range: std::ops::RangeInclusive<f64>, step: f64, unit: &str, default: f64| {
                NumberField {
                    id: id.into(),
                    value: clamp(value, &range),
                    range,
                    step,
                    decimals: 0,
                    unit: unit.into(),
                    default_value: Some(default),
                }
            };
        let std = SilenceSettings::STANDARD;
        vec![
            // `NumericSlider` rows as the Mac dialog draws them: slider, accent value, unit column.
            Row::SliderNumber {
                label: "Level".into(),
                field: field("level", s.threshold_db, SilenceSettings::THRESHOLD_RANGE, 1.0, "dB", std.threshold_db),
            },
            Row::SliderNumber {
                label: "Min. Length".into(),
                field: field(
                    "minimum",
                    s.minimum_ms as f64,
                    SilenceSettings::MINIMUM_RANGE,
                    10.0,
                    "ms",
                    std.minimum_ms as f64,
                ),
            },
            Row::SliderNumber {
                label: "Keep Each Side".into(),
                field: field(
                    "padding",
                    s.padding_ms as f64,
                    SilenceSettings::PADDING_RANGE,
                    5.0,
                    "ms",
                    std.padding_ms as f64,
                ),
            },
            Row::Text(String::new()),
            Row::Text(
                "Red ranges on the timeline will be cut. “Mark for Review” leaves them as proposed cuts to accept or reject."
                    .to_string(),
            ),
        ]
    }

    pub(crate) fn settings(f: &dyn crate::shell_dialog::DialogForm) -> SilenceSettings {
        let std = SilenceSettings::STANDARD;
        SilenceSettings::snapped(
            f.number("level").unwrap_or(std.threshold_db),
            f.number("minimum").unwrap_or(std.minimum_ms as f64),
            f.number("padding").unwrap_or(std.padding_ms as f64),
        )
    }
}

/// The pauses found per clip for one threshold and minimum.
type SilenceMemo = (SilenceSettings, BTreeMap<Id, Vec<TimeRange>>);

/// What Remove Silences needs to work out the cuts for any settings without the session: the audible selected clips, their
/// waveforms and faders, and the frame duration.
struct SilenceScan {
    clips: Vec<Clip>,
    heard: BTreeSet<Id>,
    faders: BTreeMap<Id, f64>,
    waves: BTreeMap<Id, Arc<WaveformData>>,
    fd: Time,
    /// The scan is kept per threshold and minimum, so a padding change only recomputes the cuts.
    memo: RefCell<Option<SilenceMemo>>,
}

impl SilenceScan {
    /// Pauses of a clip from its waveform as heard through its track fader.
    fn silences(&self, clip: &Clip, s: &SilenceSettings) -> Vec<TimeRange> {
        let Some(w) = self.waves.get(&clip.media) else { return Vec::new() };
        let fader = self.faders.get(&clip.id).copied().unwrap_or(0.0);
        AudioShortform::silences_in(clip, w, fader, s.threshold_db, s.minimum())
    }

    /// `EditorSession::silence_cuts` over the snapshot.
    fn cuts(&self, s: &SilenceSettings) -> Vec<TimeRange> {
        let key = SilenceSettings::new(s.threshold_db, s.minimum_ms, 0);
        let mut memo = self.memo.borrow_mut();
        if memo.as_ref().map(|m| m.0) != Some(key) {
            let found = self.clips.iter().map(|c| (c.id, self.silences(c, s))).collect();
            *memo = Some((key, found));
        }
        let found = memo.as_ref().map(|m| &m.1);
        let parts: Vec<(TimeRange, Vec<TimeRange>)> = self
            .clips
            .iter()
            .filter(|c| self.heard.contains(&c.id))
            .map(|c| (c.timeline(), found.and_then(|f| f.get(&c.id)).cloned().unwrap_or_default()))
            .collect();
        sq_core_audio::silence_removal::SilenceRemoval::cuts(
            &AudioShortform::combined_silences(&parts),
            s.padding(),
            self.fd,
        )
    }
}

impl ShellHost {
    /// "Music Ducks Twice": Bake Again, Cancel, Remove Keys (main) from left to right.
    pub(crate) fn ducks_twice_dialog() -> ShellDialog {
        let mut d = ShellDialog::new(
            "Music Ducks Twice",
            "Live Ducking is on, and music clips still carry keys from an earlier Auto Duck, so they get quieter twice. Remove the keys and let Live Ducking do it, or bake again.",
        );
        d.add_button("Remove Keys", SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        d.add_button("Bake Again", SQDialogRole::Normal, false);
        d
    }

    /// "Remove Silences": Mark for Review (a plain text button, leftmost), Cancel, Remove (main).
    pub(crate) fn add_silence_buttons(d: &mut ShellDialog) {
        d.add_button("Remove", SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        d.add_button("Mark for Review", SQDialogRole::Normal, false);
        // art.html 30: a plain text button
        d.ghost_buttons.insert(2);
    }

    // MARK: Waveforms

    /// The linear sample peak of a clip's source range (Audio Gain): the host's own answer, else the waveform's.
    pub(crate) fn peak_of(&self, clip: &Clip) -> Option<f64> {
        use sq_core_audio::AudioGainPlan;
        use sq_media::waveform_envelope::AudioGainPlanPeakExt;
        if let Some(p) = self.flow_env.services.clip_peak(clip) {
            return Some(p);
        }
        self.flow_env.services.waveform(clip.media).map(|w| AudioGainPlan::peak(&w, clip.source))
    }

    /// The waveforms of `ids`, waiting for the host to read the missing ones (the Mac awaits `prepareDialogue`). Media that
    /// never arrive (no audio, unreadable) are left out once `timeout_seconds` pass.
    /// shortcut: polls the host cache in 100 ms steps instead of awaiting the build; upgrade when `waveform` gets an async
    /// build-or-wait form on both hosts.
    pub async fn waveforms<R: ShellRoot + ?Sized>(
        h: &UiRef<R>,
        ids: &[Id],
        timeout_seconds: u32,
    ) -> BTreeMap<Id, Arc<WaveformData>> {
        let mut found: BTreeMap<Id, Arc<WaveformData>> = BTreeMap::new();
        let mut waited = 0;
        loop {
            let Some(provided) = h.with(|r| {
                let services = &r.shell_parts().shell.flow_env.services;
                for id in ids {
                    if !found.contains_key(id)
                        && let Some(w) = services.waveform(*id)
                    {
                        found.insert(*id, w);
                    }
                }
                services.has_waveforms()
            }) else {
                return found;
            };
            if found.len() == ids.len() || waited >= timeout_seconds * 10 || !provided {
                return found;
            }
            if sq_runtime::sleep(Duration::from_millis(100)).await.is_err() {
                return found;
            }
            waited += 1;
        }
    }

    // MARK: Bake Live Duck to Keys

    /// Bake Live Duck to Keys. With live ducking on and keys from an earlier Auto Duck on a ducked track, says so first:
    /// remove the old keys (live ducking stays the one duck) or bake again (keys replace the old ones).
    pub async fn auto_duck<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        enum Step {
            Nothing,
            Bake,
            Ask(Box<ShellDialog>),
        }
        let Some(step) = h.with(|r| {
            let p = r.shell_parts();
            if !p.session.can_bake_live_duck() {
                p.shell.flash("Tag a clip as Music first (Clip > Audio Options).");
                return Step::Nothing;
            }
            let defaults = SettingsDefaults(&mut *p.shell.flow_env.settings);
            if p.session.clips_ducking_twice(&defaults).is_empty() {
                return Step::Bake;
            }
            Step::Ask(Box::new(Self::ducks_twice_dialog()))
        }) else {
            return;
        };
        match step {
            Step::Nothing => {}
            Step::Bake => Self::bake_live_duck_to_keys(h, None).await,
            Step::Ask(d) => match Self::ask(&h, *d).await {
                Some(SQDialogResponse::FIRST) => {
                    let _ = h.with(|r| {
                        let p = r.shell_parts();
                        let defaults = SettingsDefaults(&mut *p.shell.flow_env.settings);
                        let n = p.session.remove_keys_ducking_twice(&defaults) as i64;
                        p.shell.emit(ShellEvent::Status(SQL10n::plural(
                            n,
                            "Removed the duck keys from %@ clip. Live Ducking does the rest.",
                            "Removed the duck keys from %@ clips. Live Ducking does the rest.",
                        )));
                    });
                }
                Some(SQDialogResponse::THIRD) => Self::bake_live_duck_to_keys(h, None).await,
                _ => {}
            },
        }
    }

    /// The one bake behind Clip > Bake Live Duck to Keys: the dialogue waveforms first, so the bake hears the pauses as
    /// playback does (dialogue pauses of 0.6 s or more let the music come back up; a clip without a waveform ducks whole).
    pub async fn bake_live_duck_to_keys<R: ShellRoot + ?Sized>(h: UiRef<R>, live: Option<LiveDucking>) {
        let Some(Some(dialogue)) = h.with(|r| {
            let p = r.shell_parts();
            let dialogue: Vec<Id> = LiveDucking::dialogue_media(p.session.active_timeline()?).into_iter().collect();
            if dialogue.iter().any(|id| p.shell.flow_env.services.waveform(*id).is_none()) {
                p.shell.flash("Reading the dialogue…");
            }
            Some(dialogue)
        }) else {
            return;
        };
        let pauses = ShellDialoguePauses { waveforms: Self::waveforms(&h, &dialogue, 10).await };
        // Keys from an earlier bake that no longer match (dialogue edited since, or keys changed by hand) are replaced:
        // say so before they go.
        let Some(changed) = h.with(|r| {
            let p = r.shell_parts();
            let all = Self::clip_waveforms(p.session, &p.shell.flow_env);
            let clip_silences = move |c: &Clip| Self::clip_pauses(&all, c);
            let defaults = SettingsDefaults(&mut *p.shell.flow_env.settings);
            p.session
                .clips_with_changed_duck_keys(
                    live.clone(),
                    &defaults,
                    Some(&pauses),
                    &clip_silences,
                    Ducking::DEFAULT_AMOUNT_DB,
                    Ducking::DEFAULT_FADE,
                )
                .len()
        }) else {
            return;
        };
        if changed > 0 {
            let mut d = ShellDialog::new(
                "Replace Duck Keys?",
                &SQL10n::format(
                    "%@ duck keys that differ from what the dialogue gives now: the dialogue was edited since the last bake, or the keys were changed by hand. Baking again replaces them.",
                    &[&if changed == 1 {
                        SQL10n::string("1 music clip has")
                    } else {
                        SQL10n::format("%@ music clips have", &[&changed.to_string()])
                    }],
                ),
            );
            d.add_button("Bake Again", SQDialogRole::Default, false);
            d.add_button("Cancel", SQDialogRole::Cancel, false);
            if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
                return;
            }
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let all = Self::clip_waveforms(p.session, &p.shell.flow_env);
            let clip_silences = move |c: &Clip| Self::clip_pauses(&all, c);
            let defaults = SettingsDefaults(&mut *p.shell.flow_env.settings);
            let result = p.session.bake_duck(
                live,
                &defaults,
                Some(&pauses),
                &clip_silences,
                Ducking::DEFAULT_AMOUNT_DB,
                Ducking::DEFAULT_FADE,
            );
            p.shell.flash(if result.keys_added > 0 {
                "Duck baked into volume keys."
            } else if result.changed {
                "The dialogue no longer reaches the music: old duck keys removed."
            } else {
                "No dialogue found: tag a clip as Dialogue first."
            });
        });
    }

    /// The waveforms the host has for the media of the active sequence's audio clips, with each clip's track fader: what
    /// the bake's `clipSilences` closure reads.
    fn clip_waveforms(
        session: &EditorSession,
        env: &crate::shell_flow_env::FlowEnv,
    ) -> BTreeMap<Id, (Arc<WaveformData>, f64)> {
        let mut out = BTreeMap::new();
        let Some(t) = session.active_timeline() else { return out };
        for track in &t.tracks {
            for c in track.clips() {
                if let Some(w) = env.services.waveform(c.media) {
                    out.insert(c.id, (w, track.volume_db));
                }
            }
        }
        out
    }

    /// Pauses of a clip with the fixed thresholds of the bake (`silences(of:thresholdDB:minimum:)`); none until its waveform
    /// was read.
    fn clip_pauses(all: &BTreeMap<Id, (Arc<WaveformData>, f64)>, c: &Clip) -> Vec<TimeRange> {
        all.get(&c.id).map_or_else(Vec::new, |(w, fader)| {
            AudioShortform::silences_in(c, w, *fader, SILENCE_THRESHOLD_DB, duck_minimum_pause())
        })
    }

    // MARK: Remove Silences

    /// Remove Silences…: Level, Min. Length and Keep Each Side with a live count of what would be cut; Remove ripple-deletes
    /// the pauses on every sync-locked track (one undo step), Mark for Review leaves them as proposed cuts.
    pub async fn remove_silences<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some((d, scan, clips))) = h.with(|r| {
            let p = r.shell_parts();
            let clips = p.session.selected_audio_clips();
            let Some(first) = clips.first() else {
                p.shell.flash("Select an audio clip first.");
                return None;
            };
            let services = &p.shell.flow_env.services;
            if !clips.iter().all(|c| services.waveform(c.media).is_some()) {
                p.shell.flash("The audio is not analyzed yet. Try again in a moment.");
                return None;
            }
            let t = p.session.active_timeline()?;
            let heard: BTreeSet<Id> = AudioShortform::audible_tracks(t)
                .into_iter()
                .flat_map(|tr| tr.clips().iter())
                .filter(|c| c.is_enabled)
                .map(|c| c.id)
                .collect();
            let faders = t
                .tracks
                .iter()
                .flat_map(|tr| tr.clips().iter().map(move |c| (c.id, tr.volume_db)))
                .collect::<BTreeMap<_, _>>();
            let waves = clips.iter().filter_map(|c| services.waveform(c.media).map(|w| (c.media, w))).collect();
            let scan = Rc::new(SilenceScan {
                clips: clips.clone(),
                heard,
                faders,
                waves,
                fd: t.frame_duration(),
                memo: RefCell::new(None),
            });
            let initial = SilenceSettings::remembered(&*p.shell.flow_env.settings);
            let mut d = ShellDialog::new(
                "Remove Silences",
                "Silences are cut and the gaps closed on every sync-locked track, so picture, music and B-roll stay in sync.",
            );
            // art.html 30: muted, inline after the title
            d.header_subtitle = Some(if clips.len() == 1 { first.name.clone() } else { format!("{} clips", clips.len()) });
            let mut form = ShellForm::new(ShellSilenceForm::rows(&initial));
            // art.html 30
            form.slider_track_width = Some(170.0);
            // art.html 30: 30 above the summary, 24 above the note
            form.extra_gap_before.extend([(ShellSilenceForm::PREVIEW_ROW, 6.0), (ShellSilenceForm::PREVIEW_ROW + 1, 5.0)]);
            let preview = Rc::clone(&p.shell.flow_env.silence_preview);
            let refresh = {
                let scan = Rc::clone(&scan);
                move |form: &mut ShellForm| {
                    let c = scan.cuts(&ShellSilenceForm::settings(&*form));
                    let removed = c.iter().fold(Time::ZERO, |a, r| a + r.duration);
                    form.set_note(
                        ShellSilenceForm::PREVIEW_ROW,
                        &SilenceSettings::preview_text(c.len() as i64, removed),
                        false,
                        true,
                        false,
                    );
                    *preview.borrow_mut() = c;
                }
            };
            refresh(&mut form);
            form.on_change = Some(Box::new(move |form, _, _| refresh(form)));
            d.form = Some(Box::new(form));
            Self::add_silence_buttons(&mut d);
            Some((d, scan, clips))
        }) else {
            return;
        };
        let r = Self::ask(&h, d).await;
        let _ = h.with(|root| {
            let p = root.shell_parts();
            p.shell.flow_env.silence_preview.borrow_mut().clear();
            if r != Some(SQDialogResponse::FIRST) && r != Some(SQDialogResponse::THIRD) {
                return;
            }
            let Some(mut form) = p.shell.take_answered_form() else { return };
            form.commit_editing();
            let s = ShellSilenceForm::settings(&*form);
            s.remember(&mut *p.shell.flow_env.settings);
            let c = scan.cuts(&s);
            if c.is_empty() {
                p.shell.flash("No silences found.");
                return;
            }
            if r == Some(SQDialogResponse::THIRD) {
                if p.session.propose_cuts(&c, sq_core_edit::proposed_cuts::ProposedCutKind::Silence) {
                    p.shell.emit(ShellEvent::Status(SQL10n::plural(
                        c.len() as i64,
                        "%@ proposed cut marked. Clip > Audio Options > Accept All Proposed Cuts, or reject.",
                        "%@ proposed cuts marked. Clip > Audio Options > Accept All Proposed Cuts, or reject.",
                    )));
                }
                return;
            }
            // No crossfade at the joins: Swift's `removeSilences(cuts:from:)` default, and the form has no such setting.
            if p.session.remove_silences(&c, &clips, false) {
                let removed = c.iter().fold(Time::ZERO, |a, r| a + r.duration);
                let line = SilenceSettings::preview_text(c.len() as i64, removed).replace("will be removed", "removed");
                p.shell.flash(&line);
            } else if let Some(e) = p.session.last_error() {
                let e = e.to_string();
                p.shell.flash(&e);
            }
        });
    }

    // MARK: Sync Audio to Reference

    /// Sync Audio to Reference: start timecodes when both files carry one, else the sound envelopes, else the capture dates;
    /// each target moves (and retimes for drift) to the reference in its own undo step (the Mac `requestSyncAudio`).
    pub async fn sync_audio<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some((reference, targets, plan_reference))) = h.with(|r| {
            let p = r.shell_parts();
            let Some(plan) = p.session.sync_audio_plan() else {
                p.shell.present_message(
                    "Sync Audio to Reference",
                    "Select at least two clips. The clip that starts first is the reference; the others are lined up to it.",
                    None,
                );
                return None;
            };
            let media = |id: Id| -> Option<MediaRef> {
                let c = p.session.active_timeline()?.tracks.iter().flat_map(|t| t.clips().iter()).find(|c| c.id == id)?;
                p.session.project().media(c.media).cloned()
            };
            let Some(reference) = media(plan.reference) else {
                p.shell.present_message("Sync Audio to Reference", "The reference clip has no media file.", None);
                return None;
            };
            let targets: Vec<(Id, MediaRef)> = plan.targets.iter().filter_map(|id| media(*id).map(|m| (*id, m))).collect();
            p.shell.emit(ShellEvent::Status(SQL10n::string("Lining up the audio…")));
            Some((reference, targets, plan.reference))
        }) else {
            return;
        };
        let mut ids: BTreeSet<Id> = targets.iter().map(|t| t.1.id).collect();
        ids.insert(reference.id);
        let ids: Vec<Id> = ids.into_iter().collect();
        let shapes = Self::waveforms(&h, &ids, 10).await;
        let ref_facts = Self::sync_facts(&h, &reference, shapes.get(&reference.id).map(|w| &**w)).await;
        let mut fits: Vec<(Id, Option<AudioDriftFit>)> = Vec::new();
        for (id, media) in &targets {
            let other = Self::sync_facts(&h, media, shapes.get(&media.id).map(|w| &**w)).await;
            let pool = h.with(|r| r.shell_parts().shell.flow_env.services.worker_pool()).flatten();
            let fit = match pool {
                Some(pool) => {
                    let reference = ref_facts.clone();
                    pool.run(move |_| ShellSyncFacts::fit(&reference, &other)).await.ok().flatten()
                }
                // shortcut: no worker pool, the fit runs on the UI thread; upgrade when the app provides one.
                None => ShellSyncFacts::fit(&ref_facts, &other),
            };
            fits.push((*id, fit));
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            Self::finish_sync_audio(p.shell, p.session, plan_reference, &fits);
        });
    }

    /// The edit API's half of Sync Audio: the same facts and fit as the menu command (start timecodes, else the sound
    /// envelopes, else capture dates), without changing the timeline. The caller applies it with `EditorSession::sync_audio`.
    pub async fn api_sync_fit<R: ShellRoot + ?Sized>(
        h: UiRef<R>,
        clip: Id,
        to: Id,
        reply: FlowReply<Result<AudioDriftFit, String>>,
    ) {
        reply.send(Self::api_sync_fit_inner(&h, clip, to).await);
    }

    async fn api_sync_fit_inner<R: ShellRoot + ?Sized>(
        h: &UiRef<R>,
        clip: Id,
        to: Id,
    ) -> Result<AudioDriftFit, String> {
        let Some(found) = h.with(|r| {
            let p = r.shell_parts();
            let media = |id: Id| -> Option<MediaRef> {
                let c =
                    p.session.active_timeline()?.tracks.iter().flat_map(|t| t.clips().iter()).find(|c| c.id == id)?;
                p.session.project().media(c.media).cloned()
            };
            (media(to), media(clip))
        }) else {
            return Err("the app is closing".into());
        };
        let (Some(reference), Some(other)) = found else {
            return Err("both clips must be media clips of the open sequence".into());
        };
        let shapes = Self::waveforms(h, &[reference.id, other.id], 10).await;
        let ref_facts = Self::sync_facts(h, &reference, shapes.get(&reference.id).map(|w| &**w)).await;
        let other_facts = Self::sync_facts(h, &other, shapes.get(&other.id).map(|w| &**w)).await;
        let pool = h.with(|r| r.shell_parts().shell.flow_env.services.worker_pool()).flatten();
        let fit = match pool {
            Some(pool) => pool.run(move |_| ShellSyncFacts::fit(&ref_facts, &other_facts)).await.ok().flatten(),
            // shortcut: no worker pool, the fit runs on the UI thread; upgrade when the app provides one.
            None => ShellSyncFacts::fit(&ref_facts, &other_facts),
        };
        fit.ok_or_else(|| {
            "the recordings could not be matched: no shared sound and no timecode or capture date".to_string()
        })
    }

    /// The start timecode comes from the host's reader first (the Mac: AVFoundation), else from the portable one
    /// (SQMedia `SourceTimecode`: QuickTime/MP4 tmcd, Sony XAVC rtmd, BWF bext), so Windows syncs by timecode too.
    pub(crate) async fn sync_facts<R: ShellRoot + ?Sized>(
        h: &UiRef<R>,
        m: &MediaRef,
        waveform: Option<&WaveformData>,
    ) -> ShellSyncFacts {
        let path = Path::new(&m.path).to_path_buf();
        let created = std::fs::metadata(&path)
            .and_then(|md| md.created())
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs_f64());
        let host = h.with(|r| r.shell_parts().shell.flow_env.services.start_timecode(m)).flatten();
        let mut tc = match host {
            Some(ask) => ask.await,
            None => None,
        };
        if tc.is_none() {
            // shortcut: reads the container on the UI thread (a few KB at the file head and the moov atom).
            tc = SourceTimecode::read(&path).ok().flatten().map(|t| t.origin);
        }
        ShellSyncFacts {
            start_timecode: tc,
            envelope: waveform.map(|w| w.envelope(WaveformData::ENVELOPE_RATE)).unwrap_or_default(),
            capture_date: created,
        }
    }

    fn finish_sync_audio(
        shell: &mut ShellHost,
        session: &mut EditorSession,
        reference: Id,
        fits: &[(Id, Option<AudioDriftFit>)],
    ) {
        let (mut done, mut unmatched, mut by_date) = (0, 0, 0);
        let mut failure: Option<String> = None;
        for (id, fit) in fits {
            let Some(fit) = fit else {
                unmatched += 1;
                continue;
            };
            if session.sync_audio(*id, reference, fit, true) {
                done += 1;
                if fit.method == AudioSyncMethod::CaptureDate {
                    by_date += 1;
                }
            } else if failure.is_none() {
                failure = session.last_error().map(str::to_string);
            }
        }
        if let Some(failure) = failure {
            shell.present_message("Sync Audio to Reference", &failure, None);
        } else if done == 0 {
            shell.present_message(
                "Sync Audio to Reference",
                "The recordings could not be matched: no shared sound and no timecode or capture date.",
                None,
            );
        } else {
            let mut tail = if unmatched > 0 {
                format!(" {}", SQL10n::format("%@ could not be matched.", &[&unmatched.to_string()]))
            } else {
                String::new()
            };
            if let Some(w) = EditorSession::capture_date_warning(by_date) {
                tail.push(' ');
                tail.push_str(&w);
            }
            let line = SQL10n::plural(done, "Synced %@ clip to the reference.", "Synced %@ clips to the reference.");
            shell.emit(ShellEvent::Status(line + &tail));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts(tc: Option<i64>, date: Option<f64>) -> ShellSyncFacts {
        ShellSyncFacts { start_timecode: tc.map(|s| Time::new(s, 1)), envelope: Vec::new(), capture_date: date }
    }

    #[test]
    fn sync_prefers_timecode_then_sound_then_capture_date() {
        let fit = ShellSyncFacts::fit(&facts(Some(100), None), &facts(Some(112), Some(5.0)));
        assert!(fit.is_some_and(|f| f.method == AudioSyncMethod::Timecode && f.offset == Time::new(12, 1)));
        let by_date = ShellSyncFacts::fit(&facts(None, Some(1000.4)), &facts(None, Some(1003.6)));
        assert!(by_date.is_some_and(|f| f.method == AudioSyncMethod::CaptureDate && f.offset == Time::new(4, 1)));
        assert_eq!(ShellSyncFacts::fit(&facts(None, None), &facts(Some(1), Some(1.0))), None);
    }

    #[test]
    fn the_silence_form_reads_back_snapped_settings() {
        let form = ShellForm::new(ShellSilenceForm::rows(&SilenceSettings::new(-34.6, 372, 64)));
        assert_eq!(ShellSilenceForm::settings(&form), SilenceSettings::new(-35.0, 350, 60));
        let clamped = ShellForm::new(ShellSilenceForm::rows(&SilenceSettings::new(-90.0, 50_000, -5)));
        assert_eq!(ShellSilenceForm::settings(&clamped), SilenceSettings::new(-60.0, 2000, 0));
    }

    #[test]
    fn the_scan_cuts_nothing_without_pauses() {
        let scan = SilenceScan {
            clips: Vec::new(),
            heard: BTreeSet::new(),
            faders: BTreeMap::new(),
            waves: BTreeMap::new(),
            fd: Time::new(1, 25),
            memo: RefCell::new(None),
        };
        assert!(scan.cuts(&SilenceSettings::STANDARD).is_empty());
    }
}
