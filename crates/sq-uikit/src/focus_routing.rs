//! Port of `SQUIKit/Sources/SQUIKit/FocusRouting.swift`.
//! The `KeyClaiming` protocol sits inside `#if canImport(AppKit)` in Swift and is not ported.

use crate::editor_command::EditorCommand;
use crate::panel_id::PanelID;

/// The five edit verbs that follow the focused panel.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EditVerb {
    SelectAll,
    Copy,
    Cut,
    Paste,
    Delete,
}

impl EditVerb {
    pub const ALL: [EditVerb; 5] =
        [EditVerb::SelectAll, EditVerb::Copy, EditVerb::Cut, EditVerb::Paste, EditVerb::Delete];

    /// The verb a command stands for; `None` for every other command.
    pub fn from_command(command: &EditorCommand) -> Option<EditVerb> {
        match command {
            EditorCommand::SelectAll => Some(EditVerb::SelectAll),
            EditorCommand::Copy => Some(EditVerb::Copy),
            EditorCommand::Cut => Some(EditVerb::Cut),
            EditorCommand::Paste => Some(EditVerb::Paste),
            EditorCommand::Delete | EditorCommand::RippleDelete => Some(EditVerb::Delete),
            _ => None,
        }
    }
}

/// Which panel's selection Cmd+A/C/X/V and Delete act on. Never the timeline unless the timeline (or a monitor) is focused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FocusedEditTarget {
    Timeline,
    EffectControls,
    Project,
    Graphics,
    Captions,
    None,
}

impl FocusedEditTarget {
    pub fn from_panel(panel: Option<PanelID>) -> FocusedEditTarget {
        match panel {
            None | Some(PanelID::Timeline) | Some(PanelID::ProgramMonitor) | Some(PanelID::SourceMonitor) => {
                FocusedEditTarget::Timeline
            }
            Some(PanelID::EffectControls) => FocusedEditTarget::EffectControls,
            Some(PanelID::Project) | Some(PanelID::Library) => FocusedEditTarget::Project,
            Some(PanelID::Graphics) => FocusedEditTarget::Graphics,
            Some(PanelID::Text) => FocusedEditTarget::Captions,
            Some(_) => FocusedEditTarget::None,
        }
    }

    /// False = the menu item is disabled and the key does nothing.
    pub fn handles(&self, verb: EditVerb) -> bool {
        match self {
            FocusedEditTarget::Timeline => true,
            // Cmd+A on keyframes: not built yet, so disabled rather than the timeline
            FocusedEditTarget::EffectControls => verb != EditVerb::SelectAll,
            // paste: media from the pasteboard (PasteMedia)
            FocusedEditTarget::Project => verb == EditVerb::Delete || verb == EditVerb::Paste,
            FocusedEditTarget::Graphics => verb == EditVerb::Delete || verb == EditVerb::SelectAll,
            FocusedEditTarget::Captions => verb == EditVerb::Delete,
            FocusedEditTarget::None => false,
        }
    }
}

/// Where Insert / Overwrite (and Place on Top) take their clip from. One rule for the key and for the menu item, so the
/// item is never grayed out while the key works.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlaceSource {
    /// The clip loaded in the Source monitor, with its In / Out.
    SourceMonitor,
    /// The media selected in the Project panel.
    ProjectMedia,
    /// The sequences selected in the Project panel (nested as one clip).
    ProjectSequences,
    Nothing,
}

impl PlaceSource {
    /// The Source monitor wins unless the Project panel has focus; then the Project selection, media before sequences.
    /// Without a Source clip the Project selection is used whatever has focus.
    pub fn resolve(
        source_loaded: bool,
        focus: Option<PanelID>,
        selected_media: i64,
        selected_sequences: i64,
    ) -> PlaceSource {
        if source_loaded && focus != Some(PanelID::Project) {
            return PlaceSource::SourceMonitor;
        }
        if selected_media > 0 {
            return PlaceSource::ProjectMedia;
        }
        if selected_sequences > 0 {
            return PlaceSource::ProjectSequences;
        }
        if source_loaded { PlaceSource::SourceMonitor } else { PlaceSource::Nothing }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_clip_wins_outside_the_project_panel() {
        assert_eq!(PlaceSource::resolve(true, Some(PanelID::ProgramMonitor), 2, 0), PlaceSource::SourceMonitor);
        assert_eq!(PlaceSource::resolve(true, None, 0, 0), PlaceSource::SourceMonitor);
    }

    #[test]
    fn project_focus_uses_its_selection() {
        assert_eq!(PlaceSource::resolve(true, Some(PanelID::Project), 1, 0), PlaceSource::ProjectMedia);
        assert_eq!(PlaceSource::resolve(true, Some(PanelID::Project), 0, 1), PlaceSource::ProjectSequences);
    }

    /// The menu used to look only at selected media: Insert was grayed out with a Source clip loaded and nothing selected,
    /// and with only a sequence selected, while the key worked.
    #[test]
    fn menu_state_matches_the_key() {
        assert_eq!(PlaceSource::resolve(false, Some(PanelID::Timeline), 0, 1), PlaceSource::ProjectSequences);
        assert_eq!(PlaceSource::resolve(false, Some(PanelID::Timeline), 0, 0), PlaceSource::Nothing);
        assert_eq!(PlaceSource::resolve(true, Some(PanelID::Project), 0, 0), PlaceSource::SourceMonitor);
    }

    #[test]
    fn edit_verbs_follow_the_focused_panel() {
        assert_eq!(EditVerb::from_command(&EditorCommand::RippleDelete), Some(EditVerb::Delete));
        assert_eq!(EditVerb::from_command(&EditorCommand::PlayPause), None);
        let t = FocusedEditTarget::from_panel(None);
        assert!(EditVerb::ALL.iter().all(|v| t.handles(*v)));
        let ec = FocusedEditTarget::from_panel(Some(PanelID::EffectControls));
        assert!(!ec.handles(EditVerb::SelectAll) && ec.handles(EditVerb::Copy));
        let p = FocusedEditTarget::from_panel(Some(PanelID::Library));
        assert!(p.handles(EditVerb::Paste) && !p.handles(EditVerb::Copy));
        assert_eq!(FocusedEditTarget::from_panel(Some(PanelID::Scopes)), FocusedEditTarget::None);
        assert!(!FocusedEditTarget::None.handles(EditVerb::Delete));
    }
}
