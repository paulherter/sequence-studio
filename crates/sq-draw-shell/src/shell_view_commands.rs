// Swift: ShellViewCommands.swift
//! View toggles and one-click commands that need only the session, the engine and the Project list: the Mac
//! AppController+SourceFlow / +AudioGain / +Captions rows. Quick Export (`ExportCoordinator.quickExport`) and File > Import
//! Project (`runImportProjectPanel`) need the export models and the project model and are not ported yet (PORTING-NOTES.md).
//!
//! The Project list rows (list and icon view, Hover Scrub, thumbnail size) belong to the host's list: `ShellHooks::on_command`
//! is asked before this file, so they return false here.

use crate::shell_host::{SettingValue, ShellCx, ShellHost};
use crate::shell_platform_text::ShellPlatformText;
use sq_core_edit::interface_scale;
use sq_core_model::BinItemRef;
use sq_editor_session::{AppSettings, AppSettingsKey};
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::localization::SQL10n;
use sq_uikit::panel_id::PanelID;
use std::collections::HashSet;

impl ShellHost {
    /// `sq.showCaptionsInMonitor`, the Mac key (AppController+Captions).
    pub const CAPTIONS_IN_MONITOR_KEY: &'static str = "sq.showCaptionsInMonitor";

    /// The saved View > Show Captions in Program Monitor choice goes back into the engine at launch
    /// (`restoreCaptionsInMonitor`).
    pub fn restore_captions_in_monitor(&self, session: &mut sq_editor_session::EditorSession) {
        if let Some(v) = self.settings.borrow().integer(Self::CAPTIONS_IN_MONITOR_KEY) {
            session.engine_mut().set_shows_captions(v != 0);
        }
    }

    /// True when `c` is one of these (run or refused with a status line).
    pub fn perform_view_command(&mut self, cx: &mut ShellCx, c: EditorCommand) -> bool {
        use EditorCommand as C;
        match c {
            C::ToggleAudioScrubbing => {
                let on = !cx.session.engine().audio_scrubbing();
                cx.session.engine_mut().set_audio_scrubbing(on);
                // An engine without audio scrubbing (the trait default) ignores the switch.
                if cx.session.engine().audio_scrubbing() != on {
                    self.flash(ShellPlatformText::not_available());
                } else {
                    self.store_setting(AppSettingsKey::AUDIO_SCRUBBING, SettingValue::Flag(on));
                    self.flash(if on { "Audio scrubbing on" } else { "Audio scrubbing off" });
                }
            }
            C::ToggleCaptionsInMonitor => {
                let on = !cx.session.engine().shows_captions();
                cx.session.engine_mut().set_shows_captions(on);
                if cx.session.engine().shows_captions() != on {
                    self.flash(ShellPlatformText::not_available());
                } else {
                    self.store_setting(Self::CAPTIONS_IN_MONITOR_KEY, SettingValue::Flag(on));
                    self.flash(if on {
                        "Captions shown in the Program view"
                    } else {
                        "Captions hidden in the Program view"
                    });
                }
            }
            C::ToggleSelectionFollowsPlayhead => {
                let on = !cx.session.selection_follows_playhead();
                cx.session.set_selection_follows_playhead(on);
                self.store_setting(AppSettingsKey::SELECTION_FOLLOWS, SettingValue::Flag(on));
                self.flash(if on { "Selection follows playhead on" } else { "Selection follows playhead off" });
            }
            C::UiScaleLarger | C::UiScaleSmaller | C::UiScaleReset => {
                let stored = self.setting_string(interface_scale::DEFAULTS_KEY).and_then(|s| s.trim().parse().ok());
                let now = interface_scale::load(stored);
                let next = if c == C::UiScaleReset {
                    1.0
                } else {
                    interface_scale::stepped(now, if c == C::UiScaleLarger { 1 } else { -1 })
                };
                if next != now {
                    // The Setting event is the Swift notification (`InterfaceScale.didChange`) and `onSettingsChanged`.
                    self.store_setting(
                        interface_scale::DEFAULTS_KEY,
                        SettingValue::Text(interface_scale::store(next).to_string()),
                    );
                }
                self.flash_raw(SQL10n::format("Interface size %@ %", &[&((next * 100.0).round() as i64).to_string()]));
            }
            // The Project list lives in the host (`ProjectListView::run_view_command`), which flashes and steps the size.
            C::ProjectListView
            | C::ProjectIconView
            | C::ToggleHoverScrub
            | C::ProjectThumbnailSmaller
            | C::ProjectThumbnailLarger => return false,
            C::PlayInToOutRoll | C::PlayAround => {
                let st = AppSettings::load(&*self.settings.borrow());
                if c == C::PlayInToOutRoll {
                    cx.session.play_in_to_out(st.preroll(), st.postroll());
                } else {
                    cx.session.play_around(st.preroll(), st.postroll());
                }
            }
            C::NewBin => {
                self.dock.show(PanelID::Project);
                self.focus = self.dock.focused().or(self.focus);
                return false;
            }
            C::ReplaceClipFromProject => {
                // Clip > Replace Clip from Project (the Mac `replaceClipFromProject`): same edit as Option-drop.
                // One clip, or a linked pair (Linked Selection selects both): the video clip, its partner follows.
                let Some(clip) = cx.session.single_selected_clip().map(|c| c.id) else {
                    self.flash("Select one clip in the timeline to replace.");
                    return true;
                };
                let media: Vec<_> = self
                    .project_selection
                    .iter()
                    .filter_map(|r| if let BinItemRef::Media(id) = r { Some(*id) } else { None })
                    .collect();
                let seqs: Vec<_> = self
                    .project_selection
                    .iter()
                    .filter_map(|r| if let BinItemRef::Sequence(id) = r { Some(*id) } else { None })
                    .collect();
                let ok = if !media.is_empty() {
                    cx.session.replace_media_with_first_of(clip, &media, None)
                } else if seqs.len() == 1 {
                    cx.session.replace_with_sequence(clip, seqs[0])
                } else {
                    self.flash("Select one item in the Project panel to replace with.");
                    return true;
                };
                if let Some(e) = cx.session.last_error().map(str::to_string).filter(|_| !ok || media.len() > 1) {
                    self.flash_raw(e);
                }
            }
            _ => return false,
        }
        true
    }

    /// The check marks of the toggles above. The Project list's marks come from `ShellHooks::menu_checks`.
    pub(crate) fn view_checks(&self, session: &sq_editor_session::EditorSession) -> HashSet<EditorCommand> {
        let mut s = HashSet::new();
        if session.engine().audio_scrubbing() {
            s.insert(EditorCommand::ToggleAudioScrubbing);
        }
        if session.engine().shows_captions() {
            s.insert(EditorCommand::ToggleCaptionsInMonitor);
        }
        if session.selection_follows_playhead() {
            s.insert(EditorCommand::ToggleSelectionFollowsPlayhead);
        }
        s
    }
}
