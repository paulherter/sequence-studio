//! Enabled state of menu rows per context, written from Swift's `ShellCommands.enabled` and `ShellHost.menuEnabled`
//! (ShellHost.swift:340-380, ShellCommands.swift:49-146): an empty untitled project, and typing in a text field.

use crate::shell_commands::ShellPanelFacts;
use crate::shell_host::NoHooks;
use crate::test_support::{session, shell};
use sq_uikit::editor_command::EditorCommand as C;

#[test]
fn an_empty_untitled_project_enables_only_what_needs_no_clip() {
    let (s, h) = (session(), shell());
    let on = |c: C| h.menu_enabled(&s, &NoHooks, c);
    // Needs a sequence: an untitled project has one.
    for c in [C::AddVideoTrack, C::AddAudioTrack, C::SequenceSettings, C::ExportEDL, C::Voiceover, C::RemoveFillerWords]
    {
        assert!(on(c), "{c:?} should be enabled");
    }
    // Needs a file, a selection, an In/Out range, media or something on the clipboard.
    for c in [
        C::Undo,
        C::Redo,
        C::CloseProject,
        C::Revert,
        C::EnableClip,
        C::Duplicate,
        C::Group,
        C::Ungroup,
        C::Lift,
        C::Extract,
        C::GoToIn,
        C::Bleep,
        C::Paste,
        C::PasteInsert,
        C::Insert,
        C::Overwrite,
        C::MakeSubclip,
        C::Link,
        C::AudioGain,
        C::AudioGainUp,
        C::ReverseClip,
        C::Delete,
        C::SpeedDuration,
        C::ReplaceClipFromSource,
    ] {
        assert!(!on(c), "{c:?} should be disabled");
    }
}

#[test]
fn typing_in_a_text_field_keeps_the_text_verbs_and_blocks_the_panel_keys() {
    let (s, mut h) = (session(), shell());
    h.panels = ShellPanelFacts { text_editing: true, ..ShellPanelFacts::default() };
    let on = |c: C| h.menu_enabled(&s, &NoHooks, c);
    for c in [C::Cut, C::Copy, C::Paste, C::Delete, C::SelectAll, C::Undo, C::Redo] {
        assert!(on(c), "{c:?} edits the text");
    }
    for c in [C::Find, C::SetPosterFrame, C::ClearPosterFrame, C::ToggleHoverScrub] {
        assert!(!on(c), "{c:?} must not fire while typing");
    }
}
