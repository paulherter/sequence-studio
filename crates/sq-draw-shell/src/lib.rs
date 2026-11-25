//! The shell of the shared draw UI (Swift `SQDrawShell`, first part): the menu bar and its menus, dialogs, the key route
//! and the [`ShellHost`] that owns them. Design: docs/rust/session-ui-design.md section 4 (task SH1).

mod error_screen;
mod keys;
mod library_imports;
mod menu_bar;
mod menu_controller;
mod menu_list_view;
mod pending_steps;
mod project_list_view;
mod shared_command_coverage;
mod shell_about;
mod shell_app_menu;
pub use shell_app_menu::{AppMenuOutcome, AppMenuRequest, AppMenuRow};
mod shell_access;
mod shell_analysis;
mod shell_angles_sync;
mod shell_anonymize;
mod shell_app_icon;
mod shell_audio_flows;
mod shell_audio_tools;
mod shell_background_offers;
mod shell_captions;
mod shell_card_browser;
mod shell_card_import;
mod shell_check_cuts;
mod shell_clip_dialogs;
mod shell_collect;
mod shell_outside_media;
pub use shell_outside_media::OutsideMediaState;
mod shell_commands;
mod shell_defaults;
mod shell_dialog;
mod shell_dialog_samples;
mod shell_dock;
mod shell_dock_shell;
mod shell_edit_api;
mod shell_export;
mod shell_export_content;
mod shell_export_items;
mod shell_export_preview;
mod shell_export_queue_menu;
mod shell_export_queue_popover;
mod shell_export_sheet;
mod shell_file_picker;
mod shell_find;
mod shell_floating;
mod shell_flow_env;
mod shell_flows;
mod shell_focused_edit;
mod shell_form;
mod shell_form_pictures;
mod shell_format;
mod shell_full_screen;
mod shell_help;
mod shell_host;
mod shell_import;
mod shell_import_report_content;
mod shell_interchange;
mod shell_key_route;
mod shell_library_import;
mod shell_live;
mod shell_locate;
mod shell_log;
mod shell_loudness;
mod shell_marker_dialog;
mod shell_mascot;
mod shell_mascot_stage;
mod shell_menu_actions;
mod shell_menu_bar;
mod shell_menu_cache;
mod shell_modal_keys;
mod shell_new_project;
mod shell_paste_media;
mod shell_paste_settings;
mod shell_platform_text;
mod shell_preferences;
mod shell_punch_in;
mod shell_quick_apply;
mod shell_quick_apply_commands;
mod shell_reconnect;
mod shell_recovery;
mod shell_relink;
mod shell_sequence_dialogs;
mod shell_sequence_match;
mod shell_settings;
mod shell_shortcuts;
mod shell_shortcuts_draw;
mod shell_start;
mod shell_start_draw;
mod shell_start_windows;
mod shell_templates;
mod shell_text_input;
mod shell_timeline_ops;
mod shell_trim;
mod shell_update;
mod shell_view_commands;
mod shell_welcome;
mod shell_whats_new;

pub use error_screen::{
    ErrorAction, ErrorKey, ErrorPart, ErrorPrimary, ErrorScreen, ErrorView, LogOpen, WINDOW_H as ERROR_SCREEN_H,
    WINDOW_W as ERROR_SCREEN_W,
};
pub use keys::{AltTap, ShellKeys, ShellWindowTitle};
pub use library_imports::{MogrtOutcome, MogrtRead, PresetOutcome};
pub use menu_bar::{MenuBar, MenuRefresh};
pub use menu_controller::MenuController;
pub use menu_list_view::{MenuFont, MenuListView};
pub use project_list_view::{
    ColumnFrame, DragPhase, HealthPart, HoverScrubState, ListRow, MoveTarget, ProjectListCx, ProjectListEvent,
    ProjectListSettings, ProjectListView, ProjectPoster, StripTools, ViewMode,
};
pub use shared_command_coverage::{Route, SharedCommandCoverage};
pub use shell_about::{AboutPage, ShellAboutContent};
pub use shell_access::{DialogFacts, StartSpot};
pub use shell_app_icon::ShellAppIcon;
pub use shell_audio_tools::ShellSyncFacts;
pub use shell_background_offers::ShellRelinkOffer;
pub use shell_captions::{ShellCaptionStyle, ShellCreateCaptionsChoice};
pub use shell_card_browser::{CardLayout, ShellCardBrowser};
pub use shell_card_import::card_summary;
pub use shell_clip_dialogs::{ShellAudioGain, ShellSpeedDuration, SpeedState};
pub use shell_commands::{ShellCommands, ShellPanelFacts};
pub use shell_defaults::ShellDefaults;
pub use shell_dialog::{
    DialogForm, FooterSummary, FormField, FormValue, PopupRequest, ShellDialog, ShellDialogContent, Tone,
};
pub use shell_dock::{Divider, DockEvent, DropAction, DropTarget, Group, ShellDock, TabAction};
pub use shell_edit_api::{EditApiState, ShellEditApi};
pub use shell_export::{ExportHost, ExportKind, ExportSubmit, FramePixels, MagicFrameCounter, ShellExport};
pub use shell_export_content::ShellExportSheet;
pub use shell_export_queue_menu::ExportQueueJob;
pub use shell_export_queue_popover::{BackgroundJob, ExportQueuePopover, QueueJob, QueuePopoverEvent};
pub use shell_export_sheet::EXPORT_PREVIEW_SLOT;
pub use shell_file_picker::{ShellFilePicker, answered};
pub use shell_floating::{FloatingHit, FloatingWindow, ShellFloating};
pub use shell_flow_env::{
    AnonymizeEvent, FlowEnv, LoudnessMeasurer, MediaProbe, NoServices, ShellServices, ShellTool, ShellVoiceoverError,
    WaveformLookup,
};
pub use shell_flows::{ShellParts, ShellRoot};
pub use shell_form::{
    Bar, Chip, GridCell, Link, ListLine, NumberField, PopupStyle, Row as FormRow, ShapeCard, ShellForm, Sidebar,
    Status, StatusTone,
};
pub use shell_format::{ChangeFormatAnswer, ShellChangeFormat};
pub use shell_host::{
    NoHooks, SettingValue, ShellCx, ShellEvent, ShellFlow, ShellHooks, ShellHost, StartSettings, WindowOp,
};
pub use shell_import::ShellImportKind;
pub use shell_import_report_content::{ReportRow, ReportTone, ShellImportReportContent};
pub use shell_log::set_log_sink;
pub use shell_loudness::LoudnessState;
pub use shell_mascot::{ShellMascot, neutral_mark};
pub use shell_mascot_stage::ShellMascotStage;
pub use shell_menu_bar::{
    AutosaveVersionRow, PerformAction, PixelAspectRow, PixelAspectRows, ShellAction, ShellMenu, ShellMenuBar,
    ShellMenuState, ValidateCommand, absolute_time,
};
pub use shell_new_project::{ShellNewProject, ShellNewProjectAnswer};
pub use shell_platform_text::ShellPlatformText;
pub use shell_preferences::{
    Extras as PreferencesExtras, Page as PreferencesPage, PreferencesHost, ShellLibraryFolder, ShellPreferences,
};
pub use shell_quick_apply::{QuickApplyEvent, QuickApplyPopup};
pub use shell_settings::{BytesView, MemoryDefaults, NumbersView, SharedDefaults, SharedView};
pub use shell_shortcuts::{ShellShortcutsEditor, ShortcutsFlow, TemplateChoice};
pub use shell_start::{
    LocalCalendar, START_BAR_EDGE, ShellStartScreen, StartAction, StartEnv, StartHit, StartSort, StartTab,
};
pub use shell_start_windows::{ShellStartWindows, StartWindowState, StartWindowStep};
pub use shell_text_input::{ShellTextInput, TextOutput};

#[cfg(test)]
mod test_support;
#[cfg(test)]
mod tests;
#[cfg(test)]
mod tests_b;
#[cfg(test)]
mod tests_d;
#[cfg(test)]
mod tests_e;
#[cfg(test)]
mod tests_menu_context;
