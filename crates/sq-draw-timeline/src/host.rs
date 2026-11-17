// Swift: TimelineHost.swift
//! An editor or dialog the timeline opens but does not own: the Inspector, the monitors, the Library and the shell's
//! dialogs provide them. Every hook is optional; a missing one turns into a status line, so a host can grow its
//! editors one at a time.

use sq_core_edit::timeline_trim_mode::TrimPoint;
use sq_core_model::Timeline;
use sq_core_time::Id;
use sq_timeline_ui::{CaptionWordRef, SlipTwoUp};
use sq_uikit::controls_grid::CGPoint;
use sq_uikit::editor_command::EditorCommand;
use std::collections::BTreeSet;

/// An editor or dialog the timeline asks its host to open.
#[derive(Clone, Debug, PartialEq)]
pub enum TimelineEditorRequest {
    /// The duration dialog of a transition.
    EditTransitionDuration(Id),
    /// Save a transition as a preset.
    SaveTransitionPreset(Id),
    /// Trim mode at an edit.
    TrimMode { point: TrimPoint, pointer_before: bool },
    /// The text editing of a text clip.
    TextClip(Id),
    /// The tone settings.
    ToneClip(Id),
    /// The Graphic's layers.
    GraphicLayers(Id),
    /// The Source monitor.
    Source { media: Id },
    /// A marker editor.
    Marker(Id),
    /// A clip marker editor.
    ClipMarker { clip: Id, marker: Id },
    /// The Text panel for a caption.
    CaptionText(Id),
    /// The inline field over one caption word; the Text panel opens when no host has it.
    CaptionWord(CaptionWordRef),
    /// Find and replace in the caption tracks.
    CaptionFindReplace,
    /// Reveal media in the Project panel.
    RevealInProject { media: Id },
    /// A track's mix.
    TrackMix(Id),
    /// The sequence volume.
    SequenceVolume,
    /// Save the clip as a preset.
    SaveClipPreset,
    /// New color matte.
    NewColorMatte,
    /// Save a title block.
    SaveTitleBlock,
    /// Save a template.
    SaveTemplate,
    /// Create an angles clip.
    CreateAnglesClip,
    /// The curve editor of a speed transition, at panel point `at`.
    SpeedCurve { clip: Id, segment: usize, at: CGPoint },
    /// Picks the keys at `time` of the section Effect Controls shows.
    KeyLaneKey { clip: Id, time: sq_core_time::Time, extend: bool },
}

impl TimelineEditorRequest {
    /// The status line when no host provides the editor.
    pub fn unavailable(&self) -> String {
        let name = match self {
            Self::EditTransitionDuration(_) => "Transition duration dialog",
            Self::SaveTransitionPreset(_) | Self::SaveClipPreset => "Saving presets",
            Self::TrimMode { .. } => "Trim mode",
            Self::TextClip(_) => "Text editing",
            Self::ToneClip(_) => "Tone settings",
            Self::GraphicLayers(_) => "Graphic layers",
            Self::Source { .. } => "Source monitor",
            Self::Marker(_) => "Marker editing",
            Self::ClipMarker { .. } => "Clip marker editing",
            Self::CaptionText(_) => "Caption text editing",
            Self::CaptionWord(_) => "Caption word editing",
            Self::CaptionFindReplace => "Find and Replace in Captions",
            Self::RevealInProject { .. } => "Reveal in Project",
            Self::TrackMix(_) => "Track mix",
            Self::SequenceVolume => "Sequence volume",
            Self::NewColorMatte => "New Color Matte",
            Self::SaveTitleBlock => "Saving title blocks",
            Self::SaveTemplate => "Saving templates",
            Self::CreateAnglesClip => "Create Angles Clip",
            Self::SpeedCurve { .. } => "Speed transition curve",
            Self::KeyLaneKey { .. } => "Picking lane keys",
        };
        format!("{name} is not available here yet")
    }
}

/// A one-line text prompt (Rename Track, Rename Clip, Combine).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TimelinePrompt {
    /// Dialog title.
    pub title: String,
    /// Message under the title.
    pub message: String,
    /// The field's start text.
    pub text: String,
    /// The field's placeholder.
    pub placeholder: String,
}

impl TimelinePrompt {
    /// A prompt without message and placeholder (the Swift defaults).
    pub fn new(title: &str, text: &str) -> TimelinePrompt {
        TimelinePrompt {
            title: title.to_string(),
            message: String::new(),
            text: text.to_string(),
            placeholder: String::new(),
        }
    }
}

/// Host hook: a menu command.
pub type CommandHook = Box<dyn FnMut(EditorCommand)>;
/// Host hook: opens an editor, false = the host has none for it.
pub type OpenHook = Box<dyn FnMut(&TimelineEditorRequest) -> bool>;
/// Host hook: a one-field text prompt; the callback gets the text.
pub type PromptHook = Box<dyn FnMut(TimelinePrompt, Box<dyn FnOnce(String)>)>;
/// Host hook: a status line.
pub type StatusHook = Box<dyn FnMut(&str)>;
/// Host hook: the Slip two-up for the Program monitor.
pub type SlipTwoUpHook = Box<dyn FnMut(Option<&SlipTwoUp>, &Timeline)>;
/// Host hook: items picked in a clip's item lanes.
pub type ItemSelectionHook = Box<dyn FnMut(Id, &BTreeSet<Id>)>;

/// What the host gives the timeline: the menu commands, the other panels' editors and a text prompt.
#[derive(Default)]
pub struct TimelineHost {
    /// A menu command through the host's command route.
    pub command: Option<CommandHook>,
    /// Opens an editor; false = the host has none for it.
    pub open: Option<OpenHook>,
    /// A one-field text prompt; the callback gets the text, never called on Cancel.
    pub prompt: Option<PromptHook>,
    /// A line for the status bar.
    pub status: Option<StatusHook>,
    /// The Slip two-up for the Program monitor (`None` = hide); unset = the monitor does not show one.
    pub slip_two_up: Option<SlipTwoUpHook>,
    /// Items picked in a clip's item lanes: the monitor and Controls select the same items.
    pub item_selection: Option<ItemSelectionHook>,
    /// Flows that await a dialog (the format question of a drop); the app host forwards them as `AppEvent::Flow`.
    pub flows: Vec<sq_draw_shell::ShellFlow>,
}

impl TimelineHost {
    /// A host with no hooks.
    pub fn new() -> TimelineHost {
        TimelineHost::default()
    }

    /// Runs a command through the host's route, or reports that there is none.
    pub fn run(&mut self, c: EditorCommand) {
        if let Some(command) = &mut self.command {
            command(c);
        } else if let Some(status) = &mut self.status {
            status("This command is not available here yet");
        }
    }

    /// Opens `r` or reports that it is missing; returns the status line (`None` when it opened).
    pub fn request(&mut self, r: &TimelineEditorRequest) -> Option<String> {
        if self.open.as_mut().is_some_and(|open| open(r)) {
            return None;
        }
        let message = r.unavailable();
        if let Some(status) = &mut self.status {
            status(&message);
        }
        Some(message)
    }

    /// Asks for a line of text, then runs `done` with it (nothing on Cancel; the `missing` status without a prompt).
    pub fn ask(&mut self, p: TimelinePrompt, missing: &str, done: Box<dyn FnOnce(String)>) {
        match &mut self.prompt {
            Some(prompt) => prompt(p, done),
            None => {
                if let Some(status) = &mut self.status {
                    status(missing);
                }
            }
        }
    }
}
