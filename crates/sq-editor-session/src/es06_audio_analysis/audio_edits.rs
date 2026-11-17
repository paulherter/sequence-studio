// Swift: EditorSession+AudioGain.swift
//! Small audio commands of the session: Audio Gain, track roles, Voice Chain, Voice-Over placement and Add Subject Mask.

use std::collections::{BTreeMap, BTreeSet};

use sq_audiofx::presets::TrackAudioPreset;
use sq_core_audio::audio_gain::AudioGain;
use sq_core_audio::voiceover::{VoiceoverPlacement, VoiceoverTimelineExt};
use sq_core_edit::timeline_replace::TimelineReplaceExt;
use sq_core_edit::voice_chain_readout::VoiceChainReadout;
use sq_core_masks::masks::ClipMasksExt;
use sq_core_masks::subject_mask_editing::SubjectMaskTimelineExt;
use sq_core_model::{AudioTag, Clip, ClipMask, Timeline, TrackKind};
use sq_core_time::{Id, Time, TimeRange};

use super::audio_shortform::LoudnessJob;
use crate::EditorSession;

/// Measures the integrated loudness (LUFS) of the one-track sequence over `range`; `None` for silence or a failure.
/// The app implements it with its timeline audio source and loudness measurement.
pub type MeasureLoudness<'a> = &'a mut dyn FnMut(&Timeline, TimeRange) -> Option<f64>;

impl EditorSession {
    /// Clips Audio Gain works on: the selected audio clips, plus the linked audio of selected video clips.
    // Swift: EditorSession+AudioGain.swift:7
    pub fn audio_gain_targets(&self) -> Vec<Clip> {
        let Some(tl) = self.active_timeline() else { return Vec::new() };
        let all = || tl.tracks.iter().flat_map(|t| t.clips().iter());
        let links: BTreeSet<Id> = all().filter(|c| self.selection.contains(&c.id)).filter_map(|c| c.link).collect();
        all()
            .filter(|c| c.kind == TrackKind::Audio && !c.is_generator())
            .filter(|c| self.selection.contains(&c.id) || c.link.is_some_and(|l| links.contains(&l)))
            .cloned()
            .collect()
    }

    /// Sets the Audio Gain (dB) of the given clips as one undo step.
    // Swift: EditorSession+AudioGain.swift:20
    pub fn set_audio_gain(&mut self, gains: &BTreeMap<Id, f64>) -> bool {
        if gains.is_empty() {
            return false;
        }
        self.attempt_ids("Audio Gain", |t, _| {
            for (id, db) in gains {
                let Some(mut c) = t.tracks.iter().find_map(|tr| tr.clip(*id)).cloned() else { continue };
                c.audio_gain_db = db.clamp(AudioGain::MIN_GAIN_DB, AudioGain::MAX_GAIN_DB);
                t.replace_clip(c)?;
            }
            Ok(())
        })
    }

    /// Sets (or clears) an audio track's role (Dialogue / Music / SFX), one undo step. Playback and export give a track
    /// without an explicit preset its role's voiced preset; an explicit chain the user edited or picked is kept.
    // Swift: EditorSession+AudioRole.swift:7
    pub fn set_track_audio_role(&mut self, id: Id, role: Option<AudioTag>) -> bool {
        let ok = self.active_timeline().and_then(|t| t.tracks.iter().find(|tr| tr.id == id)).is_some_and(|tr| {
            // The same role again is an edit while a preset replaced its chain: it takes the voiced preset back.
            tr.kind == TrackKind::Audio && (tr.audio_role != role || (role.is_some() && tr.audio_preset.is_some()))
        });
        if !ok {
            return false;
        }
        self.attempt_ids("Track Role", |t, _| {
            if let Some(i) = t.tracks.iter().position(|tr| tr.id == id) {
                let old = t.tracks[i].audio_role;
                // A chain the user typed or picked stays when another role comes (an unreadable one too): only an untouched
                // chain, or the same role picked again, goes back to the role's voiced preset, in the same undo step.
                let kept = role != old
                    && t.tracks[i].audio_preset.as_ref().is_some_and(|v| {
                        serde_json::from_value::<TrackAudioPreset>(v.clone())
                            .ok()
                            .is_none_or(|p| !p.same_chain(&TrackAudioPreset::starting_chain(old)))
                    });
                t.tracks[i].audio_role = role;
                if !kept {
                    t.tracks[i].audio_preset = None;
                }
            }
            Ok(())
        })
    }

    /// Sets (or clears, `None` = the role's preset) the audio chain tweaks of an audio track (compressor, EQ, gate, noise
    /// reduction, warmth). They are saved with the project, undoable, and run in playback and export alike. A drag passes
    /// `continues_gesture` after its first call so it is one undo step.
    pub fn set_track_audio_preset(
        &mut self,
        id: Id,
        preset: Option<&TrackAudioPreset>,
        continues_gesture: bool,
    ) -> bool {
        let value = preset.and_then(|p| serde_json::to_value(p).ok());
        let ok = self
            .active_timeline()
            .and_then(|t| t.tracks.iter().find(|tr| tr.id == id))
            .is_some_and(|tr| tr.kind == TrackKind::Audio && tr.audio_preset != value);
        if !ok {
            return false;
        }
        let key = self.gesture_key("track-audio", id, continues_gesture);
        self.with_ids(|s, _| {
            s.attempt("Track Audio", Some(&key), |t| {
                if let Some(i) = t.tracks.iter().position(|tr| tr.id == id) {
                    t.tracks[i].audio_preset = value;
                }
                Ok(())
            })
        })
    }

    /// Sets (or clears, `None`) the integrated loudness target an audio track's Loudness row chose, one undo step.
    /// `None` goes back to the role's default.
    pub fn set_track_loudness_target(&mut self, id: Id, lufs: Option<f64>) -> bool {
        let ok = self
            .active_timeline()
            .and_then(|t| t.tracks.iter().find(|tr| tr.id == id))
            .is_some_and(|tr| tr.kind == TrackKind::Audio && tr.loudness_target_lufs != lufs);
        if !ok {
            return false;
        }
        self.attempt_ids("Track Loudness", |t, _| {
            if let Some(i) = t.tracks.iter().position(|tr| tr.id == id) {
                t.tracks[i].loudness_target_lufs = lufs;
            }
            Ok(())
        })
    }

    /// Audio tracks the Voice Chain acts on: the tracks of the selected audio clips (and their linked partners).
    // Swift: EditorSession+VoiceChain.swift:6
    pub fn voice_chain_targets(&self) -> Vec<Id> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        let ids: BTreeSet<Id> = self.audio_gain_targets().iter().map(|c| c.id).collect();
        t.tracks
            .iter()
            .filter(|tr| tr.kind == TrackKind::Audio && tr.clips().iter().any(|c| ids.contains(&c.id)))
            .map(|tr| tr.id)
            .collect()
    }

    /// True when every target track already has the Dialogue role (the command then clears it).
    // Swift: EditorSession+VoiceChain.swift:13
    pub fn voice_chain_active(&self) -> bool {
        let Some(t) = self.active_timeline() else { return false };
        let ids: BTreeSet<Id> = self.voice_chain_targets().into_iter().collect();
        !ids.is_empty()
            && t.tracks.iter().filter(|tr| ids.contains(&tr.id)).all(|tr| tr.audio_role == Some(AudioTag::Dialogue))
    }

    /// Loudness readout for the selected audio clips against the Dialogue target (-14 LUFS), `None` when nothing is
    /// measurable.
    /// Same as Swift (EditorSession+VoiceChain.swift:22): measures the clips' source loudness (the same measurement Match
    /// Loudness uses), not the output after the track's voiced preset; upgrade by rendering the role chain offline.
    // Swift: EditorSession+VoiceChain.swift:22
    pub fn voice_chain_readout(&self, measure: MeasureLoudness<'_>) -> Option<VoiceChainReadout> {
        let values: Vec<Option<f64>> =
            self.selected_audio_clips().iter().map(|c| self.measure_loudness(c, &mut *measure)).collect();
        VoiceChainReadout::for_dialogue(&values)
    }

    /// The sequences `voice_chain_readout` measures, one per selected audio clip; feed the results to
    /// `VoiceChainReadout::for_dialogue`.
    pub fn voice_chain_jobs(&self) -> Vec<Option<LoudnessJob>> {
        self.selected_audio_clips().iter().map(|c| self.loudness_job(std::slice::from_ref(c))).collect()
    }

    /// One click: the target tracks get the Dialogue role, whose voiced preset is the existing EQ -> compressor ->
    /// noise reduction chain (shared by playback and export); they also take part in live ducking. Clicking again
    /// clears the role. One undo step; no second preset system.
    // Swift: EditorSession+VoiceChain.swift:31
    pub fn toggle_voice_chain(&mut self) -> bool {
        let ids: BTreeSet<Id> = self.voice_chain_targets().into_iter().collect();
        if ids.is_empty() {
            return false;
        }
        let role = if self.voice_chain_active() { None } else { Some(AudioTag::Dialogue) };
        self.attempt_ids(if role.is_none() { "Remove Voice Chain" } else { "Voice Chain" }, |t, _| {
            for i in 0..t.tracks.len() {
                if ids.contains(&t.tracks[i].id) {
                    t.tracks[i].audio_role = role;
                }
            }
            Ok(())
        })
    }

    /// Places a rendered voiceover (`media` already in the project, `duration` long) at `time` (default the playhead) on
    /// a free audio track with the Dialogue role, as one undo step. The new clip ends up selected. `None` when refused
    /// (`last_error` says why).
    // Swift: EditorSession+Voiceover.swift:7
    pub fn place_voiceover(
        &mut self,
        media: Id,
        name: &str,
        duration: Time,
        time: Option<Time>,
    ) -> Option<VoiceoverPlacement> {
        if self.active_timeline_id.is_none() {
            self.set_error("Open a sequence first.");
            return None;
        }
        let start = time.unwrap_or(self.playhead);
        let mut placed: Option<VoiceoverPlacement> = None;
        if !self.attempt_ids("Insert Voiceover", |t, ids| {
            placed = Some(t.place_voiceover(media, name, duration, start, ids)?);
            Ok(())
        }) {
            return None;
        }
        let placed = placed?;
        self.set_selection_raw([placed.clip].into());
        self.notify(crate::Change::SELECTION);
        Some(placed)
    }

    /// Selected (or playhead) video clips the edit would change: unlocked track, takes a subject mask, has none yet.
    fn subject_mask_targets(&self) -> Vec<Id> {
        let Some(t) = self.active_timeline() else { return Vec::new() };
        let ids: Vec<Id> = self.command_clips(Some(TrackKind::Video)).iter().map(|c| c.id).collect();
        t.subject_mask_targets(&ids)
    }

    // Swift: EditorSession+SubjectMask.swift:12
    pub fn add_subject_mask_enabled(&self) -> bool {
        !self.subject_mask_targets().is_empty()
    }

    /// Adds a Subject mask to each target clip, one undo step "Add Subject Mask". False when nothing changed.
    // Swift: EditorSession+SubjectMask.swift:16
    pub fn add_subject_mask(&mut self) -> bool {
        let ids = self.subject_mask_targets();
        if ids.is_empty() {
            return false;
        }
        self.attempt_ids("Add Subject Mask", |t, new_ids| {
            let mut work = t.clone();
            for id in &ids {
                let Some(mut c) = work.tracks.iter().find_map(|tr| tr.clip(*id)).cloned() else { continue };
                let mut masks = c.masks().to_vec();
                masks.push(ClipMask::make_subject(new_ids.next_id(), "Subject"));
                c.set_masks(masks);
                work.replace_clip(c)?;
            }
            *t = work;
            Ok(())
        })
    }
}
