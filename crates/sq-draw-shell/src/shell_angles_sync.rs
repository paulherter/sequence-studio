// Swift: ShellAnglesSync.swift
//! Create Angles Clip: where each angle's file time 0 lies on the common clock for the sync the sheet chose. Translated from
//! the Mac `AnglesOrigins` (AppController+Angles): Timecode reads the start timecodes (the host's reader first, then
//! `SourceTimecode`, as Sync Audio does), Audio matches the sound envelopes of the host's waveform cache through
//! `AnglesAudioSync`. The edit itself is `EditorSession::create_angles_clip`.

use crate::shell_flows::ShellRoot;
use crate::shell_host::{ShellEvent, ShellHost};
use sq_core_audio::AnglesAudioSync;
use sq_core_audio::angles_audio_sync::SyncOutcome;
use sq_core_time::{Id, Time};
use sq_editor_session::{AngleCandidate, AngleSyncMode};
use sq_media::waveform_data::WaveformData;
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use std::collections::BTreeMap;

/// `origins` `None`: keep the timeline positions. Empty: line up by In point. An angle without an entry: its In point at the
/// start. `note`: what could not be lined up, for the status line.
pub type AnglesOrigins = (Option<BTreeMap<Id, Time>>, Option<String>);

impl ShellHost {
    /// Create Angles Clip after the sheet (Swift `requestAnglesClip`): Timecode and Audio read the files first ("Lining up
    /// the angles…" in the status line), then the clip is made; the status line says what was lined up and how it went.
    pub async fn create_angles<R: ShellRoot + ?Sized>(
        h: UiRef<R>,
        clips: Vec<Id>,
        name: String,
        sync: AngleSyncMode,
        sound: usize,
        follows: bool,
    ) {
        let Some(angles) = h.with(|r| {
            let p = r.shell_parts();
            if matches!(sync, AngleSyncMode::Timecode | AngleSyncMode::Audio) {
                p.shell.emit(ShellEvent::Status(SQL10n::string("Lining up the angles…")));
            }
            p.session.angle_candidates_clips(&clips)
        }) else {
            return;
        };
        let (origins, note) = Self::angles_origins(h.clone(), sync, &angles).await;
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let made = p.session.create_angles_clip(&clips, Some(&name), origins.as_ref(), sound, follows);
            let done = SQL10n::string("Angles clip created: cut it and press 1 to 9 on a piece.");
            let line = match made {
                None => p
                    .session
                    .last_error()
                    .map_or_else(|| SQL10n::string("Could not create the Angles clip."), str::to_string),
                Some(_) => note.map_or_else(|| done.clone(), |n| format!("{n} {done}")),
            };
            p.shell.emit(ShellEvent::Status(line));
        });
    }

    /// The origins for the sync the Create Angles sheet chose.
    pub async fn angles_origins<R: ShellRoot + ?Sized>(
        h: UiRef<R>,
        sync: AngleSyncMode,
        angles: &[AngleCandidate],
    ) -> AnglesOrigins {
        match sync {
            AngleSyncMode::TimelinePositions => (None, None),
            AngleSyncMode::InPoints => (Some(BTreeMap::new()), None),
            AngleSyncMode::Timecode => {
                let mut origins = BTreeMap::new();
                let mut missing = 0;
                for a in angles {
                    let Some(media) = a
                        .media
                        .and_then(|id| h.with(|r| r.shell_parts().session.project().media(id).cloned()).flatten())
                    else {
                        missing += 1;
                        continue;
                    };
                    let Some(t) = Self::sync_facts(&h, &media, None).await.start_timecode else {
                        missing += 1;
                        continue;
                    };
                    origins.insert(media.id, t);
                }
                // An angle without timecode gets no origin: its In point goes to the start (`AnglesOffsets.starts`).
                if origins.len() < 2 {
                    return (Some(BTreeMap::new()), Some(SQL10n::string("No timecode found: lined up by In point.")));
                }
                let note = (missing > 0)
                    .then(|| SQL10n::format("%@ without timecode: lined up by In point.", &[&missing.to_string()]));
                (Some(origins), note)
            }
            AngleSyncMode::Audio => {
                let mut ids: Vec<Id> = Vec::new();
                for a in angles.iter().filter(|a| a.has_audio) {
                    if let Some(id) = a.media
                        && !ids.contains(&id)
                    {
                        ids.push(id);
                    }
                }
                let shapes = Self::waveforms(&h, &ids, 10).await;
                let mut envelopes: Vec<(Id, Vec<f32>)> = Vec::new();
                let mut unread = 0;
                for id in &ids {
                    match shapes.get(id).map(|w| w.envelope(WaveformData::ENVELOPE_RATE)).filter(|e| !e.is_empty()) {
                        Some(e) => envelopes.push((*id, e)),
                        None => unread += 1,
                    }
                }
                if envelopes.len() < 2 {
                    return (
                        Some(BTreeMap::new()),
                        Some(SQL10n::string("The sound could not be read: lined up by In point.")),
                    );
                }
                let pool = h.with(|r| r.shell_parts().shell.flow_env.services.worker_pool()).flatten();
                let rate = WaveformData::ENVELOPE_RATE as i64;
                let report = match pool {
                    Some(pool) => {
                        let env = envelopes.clone();
                        match pool.run(move |_| AnglesAudioSync::report(&env, rate)).await {
                            Ok(r) => r,
                            Err(_) => return (Some(BTreeMap::new()), None),
                        }
                    }
                    // shortcut: no worker pool, the correlation runs on the UI thread; upgrade when the app provides one.
                    None => AnglesAudioSync::report(&envelopes, rate),
                };
                let mut names: BTreeMap<Id, &str> = BTreeMap::new();
                for a in angles {
                    if let Some(id) = a.media {
                        names.entry(id).or_insert(a.name.as_str());
                    }
                }
                let failed: Vec<(&str, Option<f64>)> = report
                    .failed
                    .iter()
                    .map(|id| {
                        let name = names.get(id).copied().unwrap_or("Angle");
                        match report.outcomes.get(id) {
                            Some(SyncOutcome::NotSynced { confidence }) => (name, *confidence),
                            _ => (name, None),
                        }
                    })
                    .collect();
                let synced: Vec<f64> = report
                    .outcomes
                    .values()
                    .filter_map(|o| if let SyncOutcome::Synced { confidence } = o { Some(*confidence) } else { None })
                    .collect();
                let silent = angles.iter().filter(|a| !a.has_audio).count();
                let note = AnglesAudioSync::note(&failed, &synced, silent, unread);
                (Some(report.origins.into_iter().collect()), note)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::Rig;
    use sq_core_color::ColorMatteColor;
    use sq_core_model::TrackKind;
    use std::collections::BTreeSet;

    fn two_angles(rig: &Rig) -> Vec<Id> {
        rig.with(|r| {
            let s = &mut r.session;
            let two = Time::new(2, 1);
            let a = s.add_color_matte(ColorMatteColor::DEFAULT, "A", Some(Time::ZERO), None, two).expect("a");
            s.add_track(TrackKind::Video);
            let track = s.active_timeline().and_then(|t| t.tracks.last().map(|t| t.id)).expect("track");
            let b = s.add_color_matte(ColorMatteColor::DEFAULT, "B", Some(Time::ZERO), Some(track), two).expect("b");
            s.select(BTreeSet::from([a, b]), BTreeSet::new());
            vec![a, b]
        })
    }

    fn statuses(rig: &Rig) -> Vec<String> {
        rig.with(|r| r.shell.take_events())
            .into_iter()
            .filter_map(|e| if let ShellEvent::Status(s) = e { Some(s) } else { None })
            .collect()
    }

    #[test]
    fn timeline_positions_make_the_clip_and_say_so() {
        let rig = Rig::new();
        let clips = two_angles(&rig);
        let flow =
            ShellHost::create_angles(rig.handle(), clips, "Talk".into(), AngleSyncMode::TimelinePositions, 0, false);
        rig.rt.ex.spawn_local(flow);
        rig.rt.run_until_stalled();
        assert_eq!(statuses(&rig), ["Angles clip created: cut it and press 1 to 9 on a piece."]);
        assert_eq!(rig.with(|r| r.session.undo_name().map(str::to_string)), Some("Create Angles Clip".to_string()));
    }

    #[test]
    fn timecode_without_a_start_timecode_lines_up_by_in_point_and_says_so() {
        let rig = Rig::new();
        let clips = two_angles(&rig);
        let flow = ShellHost::create_angles(rig.handle(), clips, "Talk".into(), AngleSyncMode::Timecode, 0, false);
        rig.rt.ex.spawn_local(flow);
        rig.rt.run_until_stalled();
        let lines = statuses(&rig);
        assert_eq!(lines.first().map(String::as_str), Some("Lining up the angles…"));
        let last = lines.last().cloned().unwrap_or_default();
        assert!(last.starts_with("No timecode found: lined up by In point."), "{lines:?}");
        assert!(last.ends_with("Angles clip created: cut it and press 1 to 9 on a piece."), "{last}");
    }

    #[test]
    fn fewer_than_two_angles_say_why() {
        let rig = Rig::new();
        let flow = ShellHost::create_angles(rig.handle(), Vec::new(), "Talk".into(), AngleSyncMode::InPoints, 0, false);
        rig.rt.ex.spawn_local(flow);
        rig.rt.run_until_stalled();
        assert_eq!(statuses(&rig), ["An Angles clip needs at least two clips."]);
    }
}
