// Swift: TimelinePanel+SpeedCommands.swift
//! Clip menu speed commands that show or hide the speed band, translated from the Mac AppController+Speed.swift (the
//! band is view state, so the panel owns it; the edit itself is the session's).

use crate::panel::TimelinePanel;
use sq_core_time::Id;
use sq_editor_session::{EditorSession, SpeedPresetOutcome};
use sq_uikit::editor_command::EditorCommand;
use std::collections::BTreeSet;

impl TimelinePanel {
    /// Runs `c` when it is a speed band command: `None` = not one of them (the host goes on), `Some("")` = done, else a
    /// status line.
    pub fn run_speed_command(&mut self, c: &EditorCommand, session: &mut EditorSession) -> Option<String> {
        let remappable: BTreeSet<Id> = session.remappable_selection().iter().map(|c| c.id).collect();
        match c {
            EditorCommand::ToggleTimeRemapping => {
                // Show Time Remapping: the band on the selected video clips, or off again
                if remappable.is_empty() {
                    return Some("Select a video clip first.".to_string());
                }
                if remappable.is_subset(&self.speed_band_clips) {
                    self.speed_band_clips = self.speed_band_clips.difference(&remappable).copied().collect();
                } else {
                    self.speed_band_clips.extend(remappable);
                }
                Some(String::new())
            }
            EditorCommand::AddSpeedPoint => {
                if !session.add_speed_point_at_playhead() {
                    return Some(
                        "Select a video clip and put the playhead inside it, off an existing point.".to_string(),
                    );
                }
                self.speed_band_clips.extend(remappable);
                Some(String::new())
            }
            EditorCommand::RemoveTimeRemapping => {
                let ids: BTreeSet<Id> =
                    session.retimable_selection().iter().filter(|c| c.speed_keys.is_some()).map(|c| c.id).collect();
                if !session.remove_time_remapping() {
                    return Some("The selected clips have no time remapping.".to_string());
                }
                for id in ids {
                    self.speed_band_clips.remove(&id);
                }
                Some(String::new())
            }
            EditorCommand::SpeedRampPreset(preset, on_beat) => match session.apply_speed_preset(*preset, *on_beat) {
                SpeedPresetOutcome::NoClip => Some("Select a video clip first.".to_string()),
                SpeedPresetOutcome::NoBeat => {
                    Some("No beat marker inside the clip. Run Markers on Beat on the music first.".to_string())
                }
                SpeedPresetOutcome::Applied { .. } => {
                    self.speed_band_clips.extend(remappable);
                    Some(String::new())
                }
            },
            _ => None,
        }
    }
}
