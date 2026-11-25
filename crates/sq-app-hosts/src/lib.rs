//! The panel hosts of the app root: each owns a panel from a panel crate and routes its events (see README).

mod analysis_links;
mod animation_keystones;
mod audio_extraction;
pub mod audio_notice;
#[cfg(test)]
mod catalogue_shots;
mod chrome;
mod color_page_host;
mod color_popover;
mod popover_guard;
pub use color_popover::PickerAids;
mod conform_host;
pub mod desktop_entry;
mod edit_api_host;
mod editor_dialogs;
mod effects_host;
pub mod export_audio;
mod export_host;
mod frame_export;
mod graphics_host;
pub mod gyroflow_host;
mod icc_bt709;
mod inspector_host;
mod legacy_library;
pub use legacy_library::isolate_preferences;
mod library_host;
mod load_watch;
mod marker_list_host;
mod meter_feed;
mod monitor_host;
pub mod my_curves_link;
mod name_dialog;
mod noise_capture;
mod paste_clipboard;
mod persist;
mod picture;
mod poster_pump;
mod preset_stills;
mod preview_provider;
mod preview_sound;
mod preview_video;
mod project_host;
mod project_services;
mod root;
mod session_access;
mod shell_host;
mod source_host;
pub mod speech;
mod standard;
mod start_posters;
#[cfg(test)]
mod test_rig;
mod text_catalog;
mod text_host;
mod timeline_commands;
mod timeline_dialogs;
mod timeline_header_host;
mod timeline_host;
mod timeline_media;
mod tools_panel_host;
mod voice_recorder;
pub use voice_recorder::MicRecorder;

pub use analysis_links::analysis::{AnalysisLinks, AnalysisTurn};
pub use analysis_links::eyedropper::Eyedropper;
pub use analysis_links::ffmpeg_frames::{FfmpegFrameReader, FfmpegTrackFrames};
pub use analysis_links::magic_flow::{FlowRequest, MagicFlow, MagicRunner, RunSources, SystemSources};
pub use analysis_links::magic_job::{
    EdgeTamTracker, MagicTrackJob, TrackFrames, TrackMessage, TrackOutcome, Tracker, add_magic_mask, model_folder,
    run_track,
};
pub use analysis_links::mask_eval::{Disk, run as mask_eval};
pub use analysis_links::matte_tint::MatteTint;
pub use analysis_links::stabilization_analyzer::{
    FfmpegStabilizationAnalyzer, StabilizationJob, StabilizationMessage, StabilizationRequest, analyze_into_store,
};
pub use analysis_links::stabilization_store::StabilizationStore;
pub use analysis_links::stabilize_runner::{MakeAnalyzer, StabilizeRunner};
pub use analysis_links::subject_detection::{PortableAnalysisBackend, onnx_subject_detector};
pub use color_page_host::ColorPageHost;
pub use conform_host::ConformJobs;
pub use effects_host::{EffectsApply, EffectsDeferred, EffectsHost, apply_drop, apply_to_selection, drop_on_clips};
pub use export_host::{ExportSetup, ExportSnapshot, MakeExportSources, MakeStemAudio};
pub use frame_export::{FrameGrab, Grab};
mod template_thumbnail;
pub use graphics_host::GraphicsHost;
pub use inspector_host::{AudioBlockFactory, InspectorHost, route_sections};
pub use library_host::{LibraryDeferred, LibraryHost, route_library};
pub use marker_list_host::MarkerListHost;
pub use monitor_host::{MonitorDeferred, MonitorHost, pick_clip, route_monitor};
pub use paste_clipboard::{ClipboardSource, MediaClipboard};
pub use persist::{
    apply_session_settings, apply_session_settings_from, mark_welcome_seen, store_appearance, store_start_quality,
    stored_settings, use_projects_folder, watch_library_folder,
};
pub use picture::{LinearImage, LinearReader, MonitorPicture};
pub use poster_pump::{PosterPump, SharedAtlas, ThumbAtlas};
pub use project_host::{ProjectDeferred, ProjectHost, route_project};
pub use project_services::{
    FfmpegPosters, FileManager, SystemPlatform, blocked_external_opens, disable_external_open, external_open_allowed,
    reveal_command,
};
pub use root::AppRoot;
pub use shell_host::{ShellDeferred, ShellHost, route_shell};
pub use source_host::{SOURCE_PICTURE_SLOT, SourceMonitorHost};
pub use standard::{standard_root, standard_root_with_picture, standard_root_with_source};
pub use start_posters::{SharedStartPosters, StartPosters};
pub use text_host::TextHost;
pub use timeline_commands::{TimelineHooks, TimelineLink};
pub use timeline_host::{TimelineHostEvent, TimelinePanelHost};
