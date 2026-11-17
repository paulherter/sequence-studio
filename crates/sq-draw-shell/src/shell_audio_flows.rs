// Swift: ShellAudioFlows.swift
//! The audio commands of the Clip and Sequence menus that the Mac AppController runs in `AppController+AudioGain`,
//! `+Voiceover`, `+VoiceRecording` and `+Speed`: Voice Chain, Markers on Beat / Downbeats, the proposed-cut commands and
//! their review sheet, Fit Music to Length, Voiceover from Text and Record Voice-Over. Same session calls and messages;
//! the dialogs are shell dialogs. Remove Filler Words and Disguise Voice need the Text panel's transcript and live in
//! `CaptionsHost` (registered through the command handlers hook).
//!
//! Mapping: Swift's `ShellVoiceoverBackend` (the platform's text-to-speech engine) is [`crate::ShellServices::voices`] and
//! `render_voiceover`; the microphone is [`crate::ShellServices::voice_recorder`].

use crate::shell_dialog::{DialogForm, FormValue, ShellDialog};
use crate::shell_flow_env::{ShellTool, ShellVoiceoverError};
use crate::shell_flows::ShellRoot;
use crate::shell_form::{NumberField, Row, ShellForm};
use crate::shell_host::{ShellCx, ShellEvent, ShellFlow, ShellHost};
use crate::shell_platform_text::ShellPlatformText;
use sq_core_audio::voiceover::Voiceover;
use sq_core_edit::proposed_cuts::{ProposedCut, TimelineProposedCutsExt};
use sq_core_edit::voice_chain_readout::{VoiceChainReadout, VoiceChainStatus};
use sq_core_time::{Id, Time};
use sq_editor_session::{EditorSession, VoiceRecorderState, VoiceRecordingStep, VoiceRecordingTake};
use sq_runtime::UiRef;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use std::cell::Cell;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

/// Settings keys of Voiceover from Text.
pub(crate) const VOICEOVER_VOICE_KEY: &str = "sq.voiceover.voice";
/// See [`VOICEOVER_VOICE_KEY`].
pub(crate) const VOICEOVER_RATE_KEY: &str = "sq.voiceover.rate";

fn seconds(t: Time) -> f64 {
    t.value() as f64 / t.timescale() as f64
}

impl ShellHost {
    // MARK: Command table

    /// Runs the audio command `c` when this file owns it; false otherwise.
    pub(crate) fn perform_audio_flow_command(&mut self, cx: &mut ShellCx, c: EditorCommand) -> bool {
        use EditorCommand as C;
        let tool = match c {
            C::VoiceChain => {
                self.voice_chain(cx.session);
                return true;
            }
            C::AddBeatMarkers => ShellTool::MarkersOnBeat { downbeats_only: false },
            C::AddMarkersOnDownbeats => ShellTool::MarkersOnBeat { downbeats_only: true },
            C::ReviewProposedCuts
            | C::AcceptProposedCuts
            | C::RejectProposedCuts
            | C::AcceptProposedCutAtPlayhead
            | C::RejectProposedCutAtPlayhead => ShellTool::ProposedCuts(c),
            C::FitMusicToLength => ShellTool::FitMusic,
            C::Voiceover => ShellTool::VoiceoverFromText,
            C::RecordVoiceOver => {
                self.record_voice_over(cx.session);
                return true;
            }
            _ => return false,
        };
        self.start_flow(ShellFlow::Tool(tool));
        true
    }

    // MARK: Voice chain

    /// Voice chain on or off for the tracks of the selected audio clips; says the loudness once it is on.
    fn voice_chain(&mut self, session: &mut EditorSession) {
        let was_active = session.voice_chain_active();
        if !session.toggle_voice_chain() {
            self.flash("Select an audio clip first.");
            return;
        }
        self.flash(if was_active {
            "Voice chain removed."
        } else {
            "Voice chain on: EQ, compressor, noise reduction."
        });
        if !was_active {
            self.start_flow(ShellFlow::Tool(ShellTool::VoiceChainReadout));
        }
    }

    /// The status line for a measured voice chain.
    pub(crate) fn voice_chain_text(r: &VoiceChainReadout) -> String {
        let lufs = format!("{:.1}", r.lufs);
        let target = format!("{}", r.target_lufs);
        let off = format!("{:.1}", r.delta_lu().abs());
        match r.status() {
            VoiceChainStatus::OnTarget => {
                SQL10n::format("Voice chain on. Loudness %@ LUFS, on the %@ LUFS target.", &[&lufs, &target])
            }
            VoiceChainStatus::Quiet => SQL10n::format(
                "Voice chain on. Loudness %@ LUFS, %@ LU under the %@ LUFS target (Match Loudness fixes it).",
                &[&lufs, &off, &target],
            ),
            VoiceChainStatus::Loud => SQL10n::format(
                "Voice chain on. Loudness %@ LUFS, %@ LU over the %@ LUFS target (Match Loudness fixes it).",
                &[&lufs, &off, &target],
            ),
        }
    }

    // MARK: Markers on Beat

    /// Decodes and tracks the beat of the selected audio clips (else the Music clips), then writes the "Beat" markers as one
    /// undo step.
    pub async fn markers_on_beat<R: ShellRoot + ?Sized>(h: UiRef<R>, downbeats_only: bool) {
        let Some(Some(media)) = h.with(|r| {
            let p = r.shell_parts();
            if p.session.beat_analysis_targets().is_empty() {
                p.shell.flash("Select an audio clip or tag one as Music first (Clip > Audio Options).");
                return None;
            }
            p.shell.flash("Finding the beat...");
            Some(p.session.project().media.iter().map(|m| (m.id, PathBuf::from(&m.path))).collect::<BTreeMap<_, _>>())
        }) else {
            return;
        };
        let grids = EditorSession::beat_grids(h.clone(), |clip| media.get(&clip.media).cloned()).await;
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let n = p.session.add_markers_on_beat(&grids, downbeats_only) as i64;
            if n == 0 {
                p.shell.flash("No beat found.");
                return;
            }
            let (one, other) = if downbeats_only {
                ("Added %@ downbeat marker.", "Added %@ downbeat markers.")
            } else {
                ("Added %@ beat marker.", "Added %@ beat markers.")
            };
            p.shell.flash_plural(n, one, other);
        });
    }

    // MARK: Proposed cuts

    /// One of the proposed-cut commands.
    pub async fn proposed_cuts<R: ShellRoot + ?Sized>(h: UiRef<R>, command: EditorCommand) {
        use EditorCommand as C;
        let Some(review) = h.with(|r| {
            let p = r.shell_parts();
            let ok = match command {
                C::ReviewProposedCuts => {
                    let cuts = p.session.active_timeline().map(|t| t.proposed_cuts()).unwrap_or_default();
                    if cuts.is_empty() {
                        p.shell.flash("No proposed cuts.");
                        return None;
                    }
                    return Some(cuts);
                }
                C::AcceptProposedCuts => p.session.accept_proposed_cuts(None, true),
                C::RejectProposedCuts => p.session.reject_proposed_cuts(None),
                C::AcceptProposedCutAtPlayhead => p
                    .session
                    .proposed_cut_at_playhead()
                    .is_some_and(|id| p.session.accept_proposed_cuts(Some(&BTreeSet::from([id])), true)),
                _ => p
                    .session
                    .proposed_cut_at_playhead()
                    .is_some_and(|id| p.session.reject_proposed_cuts(Some(&BTreeSet::from([id])))),
            };
            if !ok {
                p.shell.flash("No proposed cuts.");
            }
            None
        }) else {
            return;
        };
        if let Some(cuts) = review {
            Self::review_proposed_cuts(h, cuts).await;
        }
    }

    /// The form of the review sheet: one check row per cut (all on) and the summary line under them.
    pub(crate) fn review_form(cuts: &[ProposedCut]) -> ShellForm {
        let mut rows: Vec<Row> =
            cuts.iter().enumerate().map(|(i, c)| Row::check(&format!("cut{i}"), &c.row_title(), true)).collect();
        rows.push(Row::Text(" ".to_string()));
        let mut form = ShellForm::new(rows);
        let cuts = cuts.to_vec();
        let again = move |form: &mut ShellForm| {
            let on: Vec<&ProposedCut> = cuts
                .iter()
                .enumerate()
                .filter(|(i, _)| form.bool(&format!("cut{i}")).unwrap_or(true))
                .map(|(_, c)| c)
                .collect();
            let removed = on.iter().fold(Time::ZERO, |a, c| a + c.range.duration);
            form.set_note(cuts.len(), &ProposedCut::review_summary(cuts.len(), on.len(), removed), false, true, false);
        };
        again(&mut form);
        form.on_change = Some(Box::new(move |form, _, _| again(form)));
        form
    }

    /// The ids checked in [`ShellHost::review_form`].
    pub(crate) fn checked_cuts(form: &dyn DialogForm, cuts: &[ProposedCut]) -> BTreeSet<Id> {
        cuts.iter()
            .enumerate()
            .filter(|(i, _)| form.bool(&format!("cut{i}")).unwrap_or(true))
            .map(|(_, c)| c.id)
            .collect()
    }

    /// Remove Silences' review step: Remove Checked cuts the checked ones and drops the rest, Reject All drops every
    /// proposal, Cancel leaves the markers as they are.
    async fn review_proposed_cuts<R: ShellRoot + ?Sized>(h: UiRef<R>, cuts: Vec<ProposedCut>) {
        let mut d = ShellDialog::new(
            "Review Silences",
            "Uncheck the pauses you want to keep. Checked ones are cut and the gaps closed.",
        );
        d.form = Some(Box::new(Self::review_form(&cuts)));
        d.add_button("Remove Checked", SQDialogRole::Default, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        d.add_button("Reject All", SQDialogRole::Normal, true);
        let answer = Self::ask(&h, d).await;
        let _ = h.with(|r| {
            let p = r.shell_parts();
            match answer {
                Some(SQDialogResponse::FIRST) => {
                    if let Some(form) = p.shell.take_answered_form() {
                        p.session.review_proposed_cuts(&Self::checked_cuts(&*form, &cuts), true);
                    }
                }
                Some(SQDialogResponse::THIRD) => {
                    p.session.reject_proposed_cuts(None);
                }
                _ => {}
            }
        });
    }

    // MARK: Fit Music to Length

    /// Finds the beat of the selected music clip and offers up to three versions; picking one applies it.
    pub async fn fit_music<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some((clip, target, path))) = h.with(|r| {
            let p = r.shell_parts();
            let Some(clip) = p.session.music_fit_clip() else {
                p.shell.flash("Select one music clip at normal speed first.");
                return None;
            };
            let Some(target) = p.session.music_fit_target(&clip) else {
                p.shell.flash("Mark In and Out, or place the clip before the sequence end.");
                return None;
            };
            let media = p.session.project().media(clip.media)?;
            let path = PathBuf::from(&media.path);
            p.shell.flash("Finding the beat...");
            Some((clip, target, path))
        }) else {
            return;
        };
        let Some(grid) = EditorSession::analyze_beats(path).await else {
            let _ = h.with(|r| r.shell_parts().shell.flash("No beat found."));
            return;
        };
        let Some(Some((d, versions))) = h.with(|r| {
            let p = r.shell_parts();
            let versions = p.session.music_fit_versions(&grid, Some(target));
            if versions.is_empty() {
                p.shell.flash("The clip already has that length, or too few bars to fit.");
                return None;
            }
            let mut d = ShellDialog::new(
                "Fit Music to Length",
                &SQL10n::format(
                    "%@ to %@ s. Joins sit on bar lines with a short crossfade.",
                    &[&clip.name, &format!("{:.1}", seconds(target))],
                ),
            );
            let titles: Vec<String> =
                versions.iter().enumerate().map(|(i, v)| EditorSession::music_fit_row_title(v, i)).collect();
            let mut form = ShellForm::new(vec![Row::Radio { id: "version".into(), options: titles, selected: 0 }]);
            form.a11y_labels.insert("version".to_string(), "Choice".to_string());
            d.form = Some(Box::new(form));
            d.add_button("Fit", SQDialogRole::Default, false);
            d.add_button("Cancel", SQDialogRole::Cancel, false);
            Some((d, versions))
        }) else {
            return;
        };
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(form) = p.shell.take_answered_form() else { return };
            let Some(v) = form.index("version").and_then(|i| usize::try_from(i).ok()).and_then(|i| versions.get(i))
            else {
                return;
            };
            if p.session.apply_music_fit(v, Some(clip.id)) {
                p.shell.flash("Music fitted to length.");
            } else if let Some(e) = p.session.last_error().map(str::to_string) {
                p.shell.flash(&e);
            }
        });
    }

    // MARK: Voiceover from Text

    /// The sheet asks for text, voice and speed; the voice is made on this computer into a file, imported like any media and
    /// placed at the playhead on a free audio track.
    pub async fn voiceover_from_text<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some((d, voices))) = h.with(|r| {
            let p = r.shell_parts();
            if p.session.active_timeline().is_none() {
                p.shell.flash("Open a sequence first.");
                return None;
            }
            let Some(voices) = p.shell.flow_env.services.voices() else {
                p.shell.flash(ShellPlatformText::not_available());
                return None;
            };
            let rate0 =
                p.shell.setting_number(VOICEOVER_RATE_KEY).map_or(Voiceover::DEFAULT_RATE, Voiceover::clamped_rate);
            let remembered = p.shell.setting_string(VOICEOVER_VOICE_KEY);
            let mut d = ShellDialog::new(
                "Voiceover from Text",
                "The voice is made on this computer and added as an audio clip at the playhead.",
            );
            let mut form = ShellForm::new(vec![
                Row::TextBox { id: "text".into(), value: String::new(), height: 80.0 },
                Row::Popup {
                    id: "voice".into(),
                    label: "Voice".into(),
                    options: voices.iter().map(|v| v.1.clone()).collect(),
                    selected: voices.iter().position(|v| Some(&v.0) == remembered.as_ref()).unwrap_or(0) as i64,
                },
                Row::SliderNumber {
                    label: "Speed".into(),
                    field: NumberField {
                        id: "speed".into(),
                        value: Voiceover::speed_factor(rate0),
                        range: 0.5..=2.0,
                        step: 0.05,
                        decimals: 2,
                        unit: "x".into(),
                        default_value: Some(1.0),
                    },
                },
                Row::Text(" ".to_string()),
            ]);
            let has_voices = !voices.is_empty();
            let again = move |form: &mut ShellForm| {
                let rate = Voiceover::rate_for_speed_factor(form.number("speed").unwrap_or(1.0));
                let hint = Voiceover::hint_text(&form.text("text").unwrap_or_default(), rate, has_voices);
                form.set_note(3, &hint, false, false, false);
            };
            // The dialog's `button_enabled` cannot see the form, so the reaction keeps the answer.
            let ready = Rc::new(Cell::new(false));
            let flag = Rc::clone(&ready);
            again(&mut form);
            form.on_change = Some(Box::new(move |form, id, value| {
                if let ("text", FormValue::Text(t)) = (id, value) {
                    flag.set(has_voices && !Voiceover::cleaned(t).is_empty());
                }
                again(form);
            }));
            d.form = Some(Box::new(form));
            d.add_button("Insert at Playhead", SQDialogRole::Default, false);
            d.add_button("Cancel", SQDialogRole::Cancel, false);
            d.button_enabled = Some(Box::new(move |i| i != 0 || ready.get()));
            Some((d, voices))
        }) else {
            return;
        };
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let Some(Some((text, voice_id, speed))) = h.with(|r| {
            let p = r.shell_parts();
            let mut form = p.shell.take_answered_form()?;
            form.commit_editing();
            let text = Voiceover::cleaned(&form.text("text").unwrap_or_default());
            let voice = usize::try_from(form.index("voice")?).ok().and_then(|v| voices.get(v))?;
            if text.is_empty() {
                return None;
            }
            let speed = Voiceover::rate_for_speed_factor(form.number("speed").unwrap_or(1.0));
            p.shell.store_setting_string(VOICEOVER_VOICE_KEY, &voice.0);
            p.shell.store_setting_number(VOICEOVER_RATE_KEY, Voiceover::clamped_rate(speed));
            Some((text, voice.0.clone(), speed))
        }) else {
            return;
        };
        Self::insert_voiceover(h, text, voice_id, speed).await;
    }

    async fn insert_voiceover<R: ShellRoot + ?Sized>(h: UiRef<R>, text: String, voice_id: String, rate: f64) {
        let Some(Some((start, folder, url, file, ask))) = h.with(|r| {
            let p = r.shell_parts();
            let start = p.session.playhead();
            let folder = p.shell.flow_env.services.voiceover_folder();
            let mut taken: BTreeSet<String> = p
                .session
                .project()
                .media
                .iter()
                .filter_map(|m| std::path::Path::new(&m.path).file_name().map(|n| n.to_string_lossy().into_owned()))
                .collect();
            if let Ok(dir) = std::fs::read_dir(&folder) {
                taken.extend(dir.flatten().map(|e| e.file_name().to_string_lossy().into_owned()));
            }
            let file = Voiceover::file_name(&text, &taken);
            let url = folder.join(&file);
            p.shell.flash("Making the voiceover…");
            // shortcut: the folder is created here; Swift's renderer created it.
            let _ = std::fs::create_dir_all(&folder);
            let ask = p.shell.flow_env.services.render_voiceover(&text, &voice_id, rate, &url)?;
            Some((start, folder, url, file, ask))
        }) else {
            return;
        };
        let _ = folder;
        let length = match ask.await {
            Ok(l) => l,
            Err(e) => {
                let _ = h.with(|r| {
                    r.shell_parts().shell.flash(if e == ShellVoiceoverError::NoAudio {
                        "This voice made no sound. Pick another voice."
                    } else {
                        "Could not make the voiceover."
                    });
                });
                return;
            }
        };
        let imported = Self::import_generated(h.clone(), &url).await;
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let Some(id) = imported else {
                p.shell.flash("Could not import the voiceover.");
                return;
            };
            if p.session.place_voiceover(id, &Voiceover::clip_name_from_file(&file), length, Some(start)).is_some() {
                p.shell.flash("Voiceover added on a Dialogue track.");
            }
        });
    }

    // MARK: Record Voice-Over

    /// Record Voice-Over: the status line shows the running time. The take is imported like any media and placed at the
    /// playhead where recording began, on a free Dialogue track.
    fn record_voice_over(&mut self, session: &mut EditorSession) {
        let Some(state) = self.flow_env.services.voice_recorder_state() else {
            self.flash(ShellPlatformText::not_available());
            return;
        };
        if session.active_timeline().is_none() && state == VoiceRecorderState::Idle {
            self.flash("Open a sequence first.");
            return;
        }
        if state == VoiceRecorderState::Recording {
            let Some(stopped) = self.flow_env.services.stop_voice_take(session) else {
                self.flash(ShellPlatformText::not_available());
                return;
            };
            match stopped {
                Ok(take) => {
                    self.start_flow(ShellFlow::Tool(ShellTool::FinishVoiceRecording(take)));
                }
                Err(step) => self.voice_step_done(step),
            }
            return;
        }
        let folder = self.flow_env.services.voiceover_folder();
        // shortcut: the folder is created here; the Mac recorder created it itself.
        let _ = std::fs::create_dir_all(&folder);
        let Some(step) = self.flow_env.services.toggle_voice_recording(session, &folder) else {
            self.flash(ShellPlatformText::not_available());
            return;
        };
        match step {
            // The countdown runs on the recorder's own clock; the tracker shows it and starts the picture when it ends.
            VoiceRecordingStep::Started { play } => {
                self.start_flow(ShellFlow::Tool(ShellTool::TrackVoiceRecording { play }));
            }
            other => self.voice_step_done(other),
        }
    }

    /// What the status line and the flash say once a press of Record Voice-Over ended without a running take.
    fn voice_step_done(&mut self, step: VoiceRecordingStep) {
        self.emit(ShellEvent::Job(None));
        match step {
            VoiceRecordingStep::Started { .. } | VoiceRecordingStep::Canceled => {}
            VoiceRecordingStep::Placed(_) => self.flash("Voice-over added on a Dialogue track."),
            VoiceRecordingStep::Denied => self.flash(
                "The microphone is off for Sequence Studio. Turn it on in System Settings > Privacy & Security > Microphone.",
            ),
            VoiceRecordingStep::Failed(why) => self.flash(&why),
        }
    }

    /// The take of a stopped voice-over: checked, imported like any media and placed where recording began.
    pub(crate) async fn finish_voice_recording<R: ShellRoot + ?Sized>(h: UiRef<R>, take: VoiceRecordingTake) {
        let short = h.with(|r| r.shell_parts().session.reject_short_take(&take)).flatten();
        if let Some(step) = short {
            let _ = h.with(|r| r.shell_parts().shell.voice_step_done(step));
            return;
        }
        let media = Self::import_generated(h.clone(), &take.url).await;
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let step = match media {
                Some(id) => p.session.place_voice_take(&take, id),
                None => p.session.import_failed(),
            };
            p.shell.voice_step_done(step);
        });
    }

    /// Imports a file the app made itself (a voiceover, a take) like any media and answers its media id.
    pub(crate) async fn import_generated<R: ShellRoot + ?Sized>(h: UiRef<R>, url: &std::path::Path) -> Option<Id> {
        Self::import_media(h.clone(), vec![url.to_path_buf()], true).await;
        h.with(|r| r.panel_parts().0.media_id_for_imported(url)).flatten()
    }

    /// Shows the countdown and then the running time on the job line until recording ends; plays the sequence along
    /// from the moment recording runs (Swift starts it after the countdown).
    pub(crate) async fn track_voice_recording_time<R: ShellRoot + ?Sized>(h: UiRef<R>, play: bool) {
        let mut played = false;
        let mut recording_since = None;
        loop {
            let Some(state) = h.with(|r| {
                let p = r.shell_parts();
                let state = p.shell.flow_env.services.voice_recorder_state();
                let line = match state {
                    Some(VoiceRecorderState::RequestingAccess) => {
                        Some(SQL10n::string("Voice-over: waiting for the microphone…"))
                    }
                    Some(VoiceRecorderState::Countdown) => {
                        let n = p.shell.flow_env.services.voice_countdown_left().unwrap_or(1);
                        Some(SQL10n::format("Voice-over starts in %@… (press again to cancel)", &[&n.to_string()]))
                    }
                    Some(VoiceRecorderState::Recording) => {
                        let now = p.shell.clock.now();
                        if !played {
                            played = true;
                            if play {
                                p.session.play_pause();
                            }
                            recording_since = Some(now);
                        }
                        let s = (now - recording_since.unwrap_or(now).min(now)).as_secs();
                        Some(SQL10n::format(
                            "Recording voice-over %@ (press again to stop)",
                            &[&format!("{}:{:02}", s / 60, s % 60)],
                        ))
                    }
                    _ => None,
                };
                if line.is_some() {
                    p.shell.emit(ShellEvent::Job(line));
                }
                state
            }) else {
                return;
            };
            if !matches!(
                state,
                Some(
                    VoiceRecorderState::RequestingAccess
                        | VoiceRecorderState::Countdown
                        | VoiceRecorderState::Recording
                )
            ) {
                // Idle again: stopped, canceled or the microphone failed to open. A stop shows its own line.
                let _ = h.with(|r| {
                    let p = r.shell_parts();
                    if p.shell.flow_env.services.voice_take_failure().is_some() {
                        p.shell.emit(ShellEvent::Job(None));
                        p.shell.flash("Could not start the microphone.");
                    } else if !played {
                        p.shell.emit(ShellEvent::Job(None));
                    }
                });
                return;
            }
            if sq_runtime::sleep(Duration::from_millis(250)).await.is_err() {
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_edit::proposed_cuts::ProposedCutKind;
    use sq_core_time::TimeRange;

    fn cut(n: u64, start: i64, length: i64) -> ProposedCut {
        ProposedCut {
            id: Id::fixed(n),
            range: TimeRange::new(Time::new(start, 1), Time::new(length, 1)),
            kind: ProposedCutKind::Silence,
        }
    }

    #[test]
    fn the_review_form_counts_the_checked_cuts() {
        let cuts = [cut(1, 12, 2), cut(2, 30, 3)];
        let mut form = ShellHost::review_form(&cuts);
        assert!(matches!(&form.rows()[2], Row::Text(t) if t == "2 of 2 checked, 5.0 s will be removed."));
        assert_eq!(ShellHost::checked_cuts(&form, &cuts), BTreeSet::from([Id::fixed(1), Id::fixed(2)]));
        form.set("cut1", FormValue::Bool(false));
        assert_eq!(ShellHost::checked_cuts(&form, &cuts), BTreeSet::from([Id::fixed(1)]));
    }

    #[test]
    fn the_voice_chain_line_says_how_far_off_the_loudness_is() {
        let line = |lufs| ShellHost::voice_chain_text(&VoiceChainReadout { lufs, target_lufs: -14.0 });
        assert_eq!(line(-14.4), "Voice chain on. Loudness -14.4 LUFS, on the -14 LUFS target.");
        assert_eq!(
            line(-20.0),
            "Voice chain on. Loudness -20.0 LUFS, 6.0 LU under the -14 LUFS target (Match Loudness fixes it)."
        );
        assert_eq!(
            line(-10.0),
            "Voice chain on. Loudness -10.0 LUFS, 4.0 LU over the -14 LUFS target (Match Loudness fixes it)."
        );
    }
}
