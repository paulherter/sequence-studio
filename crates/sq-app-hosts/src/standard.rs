//! The app root as the application builds it: every host over its real model; the stored defaults are `prefs.json`, the
//! Library folders are watched by polling, and thumbnails come from FFmpeg frames.

use crate::analysis_links::analysis_services::AnalysisServices;
use crate::analysis_links::anonymize_runner::{AnonymizeRunner, system_sources as system_anonymize_sources};
use crate::analysis_links::picture_sampler::PictureSampler;
use crate::persist::{FileDefaults, FileView};
use crate::{
    AnalysisLinks, AppRoot, EffectsHost, Eyedropper, FfmpegStabilizationAnalyzer, GraphicsHost, InspectorHost,
    LibraryHost, MagicFlow, MagicRunner, MatteTint, MonitorHost, MonitorPicture, ShellHost, SourceMonitorHost,
    StabilizationStore, StabilizeRunner, SystemSources, TextHost, TimelineHooks, TimelinePanelHost,
};
use sq_analysis::frame_matte_store::FrameMatteStore;
use sq_audiofx::presets::PresetLibrary;
use sq_core_project::cache_disk_policy::CacheDiskPolicy;
use sq_core_time::{IdSource, Time, Timestamp};
use sq_draw::DrawTheme;
use sq_draw::monitor::monitor_modes::MonitorMode;
use sq_draw_library::effects::effects_draw_panel::EffectsDrawPanel;
use sq_draw_library::library::library_draw_panel::LibraryDrawPanel;
use sq_draw_library::library::library_panel_model::{LibraryPanelDeps, LibraryPanelModel};
use sq_draw_monitor::meter_panel::MeterPanel;
use sq_draw_monitor::monitor_panel::MonitorPanel;
use sq_draw_monitor::monitor_panel_model::MonitorPanelModel;
use sq_draw_shell::ShellHost as DrawShell;
use sq_editor_session::{ProgramEngine, RecentProjects, UpdateCheck};
use sq_inspector_ui::audio_masks::track_audio_draw::TrackAudioDraw;
use sq_inspector_ui::audio_masks::track_audio_inspector_model::TrackAudioInspectorModel;
use sq_library::folder_scanner::FolderScanner;
use sq_library::folder_watching::NotifyFolderWatcher;
use sq_library::library_index::LibraryIndex;
use sq_library::preset_store::PresetStore;
use sq_library::preview_requests::{PreviewCache, PreviewCoordinator};
use sq_runtime::Clock;
use sq_uikit::command_map::CommandMap;
use std::cell::RefCell;
use std::path::Path;
use std::rc::Rc;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

/// The renderer image slot the Mask Tint is drawn from (0 atlas, 2-3 scopes, 5 Source monitor).
const MASK_TINT_SLOT: usize = 4;

/// The recent projects, one JSON file beside the other app state.
const RECENTS_FILE: &str = "recents.json";

/// The one pool for blocking shell work (Match Loudness, Collect Files, imports, angle sync) of this process.
pub fn app_worker_pool() -> Arc<sq_runtime::WorkerPool> {
    static POOL: std::sync::OnceLock<Arc<sq_runtime::WorkerPool>> = std::sync::OnceLock::new();
    Arc::clone(POOL.get_or_init(|| {
        let n = std::thread::available_parallelism().map_or(2, |n| n.get()).clamp(2, 4);
        Arc::new(sq_runtime::WorkerPool::threads(n))
    }))
}

fn wall_clock() -> Timestamp {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0);
    Timestamp::from_unix_seconds(secs)
}

/// A Library panel whose presets and preview cache live under `root`.
#[cfg(test)]
pub(crate) fn library_panel(root: &Path) -> Option<LibraryDrawPanel> {
    library_panel_with(root, FileDefaults::shared(root))
}

/// [`library_panel`] over the stored defaults the whole window shares (tile size, view mode, whoosh, watched folders).
pub(crate) fn library_panel_with(root: &Path, defaults: Rc<RefCell<FileDefaults>>) -> Option<LibraryDrawPanel> {
    let store = PresetStore::open_in_support(root, false, wall_clock()).ok()?;
    let cache = PreviewCache::in_caches_directory(
        &root.join("caches"),
        PreviewCache::DEFAULT_BYTE_CAP,
        CacheDiskPolicy::unchecked(),
    );
    let provider = crate::preview_provider::MediaPreviewProvider::with_cache(cache.root.clone());
    let coordinator = PreviewCoordinator::new(cache);
    let ids: Box<dyn IdSource> = Box::new(crate::speech::RandomIds);
    let mut model = LibraryPanelModel::new(LibraryPanelDeps {
        index: LibraryIndex::new(FolderScanner::default(), Box::new(NotifyFolderWatcher::default())),
        preset_store: store,
        coordinator,
        provider: Box::new(provider),
        favorites_url: root.join("favorites.json"),
        ids,
        clock: Box::new(wall_clock),
        whoosh_defaults: Box::new(FileView(Rc::clone(&defaults))),
    });
    model.preview.set_sound(Box::new(crate::preview_sound::FfmpegSound::new()));
    // The folders watched in an earlier run come back (Swift `LibraryDrawServices.start`) before the index starts.
    let mut view = FileView(Rc::clone(&defaults));
    let mut watched = sq_library::library_folder_store::LibraryFolderStore::load(&mut view);
    if watched.is_empty() {
        // The first start after the Swift app: its folders come over once (read-only).
        if let Some(old) = crate::legacy_library::swift_defaults_file() {
            watched = crate::legacy_library::import_swift_folders(&mut view, &old);
        }
    }
    if !watched.is_empty() {
        model.restore_folders(watched);
    }
    model.start();
    Some(LibraryDrawPanel::new(model, Box::new(FileView(Rc::clone(&defaults))), Box::new(FileView(defaults))))
}

/// The editing window: Program monitor, Library, timeline, inspector and the shell, state kept under `support`.
/// `None` when the preset store cannot be opened there.
pub fn standard_root(support: &Path, clock: Arc<dyn Clock>, theme: DrawTheme) -> Option<AppRoot> {
    standard_root_with_picture(support, clock, theme, MonitorPicture::default())
}

/// [`standard_root`] with the Program monitor showing the frames put into `picture`.
pub fn standard_root_with_picture(
    support: &Path,
    clock: Arc<dyn Clock>,
    theme: DrawTheme,
    picture: MonitorPicture,
) -> Option<AppRoot> {
    build_root(support, clock, theme, picture, None)
}

/// [`standard_root_with_picture`] plus the Source monitor playing on `engine`, whose frames land in `source_picture`.
pub fn standard_root_with_source(
    support: &Path,
    clock: Arc<dyn Clock>,
    theme: DrawTheme,
    picture: MonitorPicture,
    engine: Box<dyn ProgramEngine>,
    source_picture: MonitorPicture,
) -> Option<AppRoot> {
    let source = SourceMonitorHost::new(engine, source_picture, Box::new(crate::speech::RandomIds));
    build_root(support, clock, theme, picture, Some(source))
}

fn build_root(
    support: &Path,
    clock: Arc<dyn Clock>,
    theme: DrawTheme,
    picture: MonitorPicture,
    source: Option<SourceMonitorHost>,
) -> Option<AppRoot> {
    // The monitor model starts at 29.97 fps and follows the active sequence once one is open (`monitor_host.rs`); the preset library is the built-in one.
    let defaults = FileDefaults::shared(support);
    let mut monitor_model = MonitorPanelModel::with_defaults(
        Time::new(1001, 30000),
        MonitorMode::Program,
        Box::new(FileView(Rc::clone(&defaults))),
    );
    monitor_model.wired.new_sequence = true;
    let eyedropper = Eyedropper::default();
    // The picker popovers store their recent colors in the shared defaults and may pick from the monitor picture.
    let picker_aids = crate::PickerAids {
        eyedropper: Some(eyedropper.clone()),
        defaults: Some(Rc::new(RefCell::new(Box::new(FileView(Rc::clone(&defaults)))))),
    };
    let flow = MagicFlow::default();
    let edges = sq_analysis::subject_mask_quality::SubjectEdgesChoice::default();
    let mattes = Arc::new(FrameMatteStore::new(Some(support.join("caches").join("MagicMattes"))));
    let stabilization = StabilizationStore::with_disk(support.join("caches").join("Stabilization"));
    let analysis = AnalysisLinks::new(
        flow.clone(),
        MagicRunner::new(
            Arc::clone(&mattes),
            Box::new(SystemSources { support: support.to_path_buf(), edges: edges.clone() }),
            Box::new(crate::speech::RandomIds),
        ),
        StabilizeRunner::new(
            stabilization.clone(),
            Some(support.join("caches").join("Stabilization")),
            Box::new(|path| Box::new(FfmpegStabilizationAnalyzer::new(path))),
            Arc::new(|| {}),
        ),
    );
    let monitor = MonitorHost::new(MonitorPanel::new(monitor_model, None))
        .with_picture(picture.clone())
        .with_eyedropper(eyedropper.clone())
        .with_magic_flow(flow.clone())
        .with_subject_edges(edges)
        .with_matte_tint(MatteTint::new(Arc::clone(&mattes), MASK_TINT_SLOT));
    let library = LibraryHost::new(
        library_panel_with(support, Rc::clone(&defaults))?,
        Box::new(|| sq_core_effects::effect_preset::ApplyMode::Absolute),
    );
    let inspector = InspectorHost::new(Box::new(|_, role| {
        TrackAudioDraw::new(TrackAudioInspectorModel::new(
            PresetLibrary::default(),
            None,
            role,
            Box::new(crate::speech::RandomIds),
        ))
    }))
    .with_eyedropper(eyedropper.clone())
    .with_picker_aids(picker_aids.clone())
    .with_frame_sampler(PictureSampler::new(picture.clone()))
    .with_magic_flow(flow)
    .with_matte_store(Arc::clone(&mattes))
    .with_stabilization(stabilization)
    .with_gyroflow(crate::gyroflow_host::shared_engine());
    let recents_path = support.join(RECENTS_FILE);
    let recents = std::fs::read(&recents_path)
        .ok()
        .and_then(|b| serde_json::from_slice::<RecentProjects>(&b).ok())
        .unwrap_or_default();
    let (hooks, timeline_link) = TimelineHooks::new(picture.view_choices().clone());
    let hooks = hooks.with_media_clipboard(crate::MediaClipboard::system());
    // Swift `SharedUIController`: the shell starts on the saved key set (the Sequence Studio set unless the user chose
    // another), and that map is the running one for tooltips and menu hints.
    let keymap = sq_uikit::keymap_store::KeymapStore::load(&FileView(Rc::clone(&defaults))).map();
    CommandMap::set_current(keymap.clone());
    let mut shell = ShellHost::new(DrawShell::new(keymap, recents, clock, Box::new(wall_clock)), Some(Box::new(hooks)));
    // Help > Check for Updates: `SQ_UPDATE_URL`, else the stored feed, else the GitHub releases feed (Swift `UpdateCheck.feedURL`).
    shell.shell().update_feed = UpdateCheck::feed_url(&FileView(Rc::clone(&defaults)));
    // The in-app update: installs in place where the platform can, else Download opens the link.
    shell.shell().update_install = sq_platform::app_update::supported();
    shell.shell().update_cache = Some(support.join("caches").join("Updates"));
    // Saved sequence templates: without this folder Save Sequence as Template had nowhere to write (it is made on first save).
    shell.shell().template_folder = Some(sq_editor_session::standard_template_folder(support));
    // Linux AppImage: the Settings row for the menu entry (an entry whose file is gone is refreshed here).
    shell.shell().preferences.app_menu =
        crate::desktop_entry::startup_row(sq_platform::desktop_integration::DesktopEnv::current().as_ref());
    let looks = Arc::new(sq_editor_session::LookStore::new(
        Some(sq_editor_session::LookStore::default_url(&sq_editor_session::LookStore::library_directory(support))),
        Some(sq_editor_session::LookStore::legacy_text_styles_url(&sq_editor_session::LookStore::library_directory(
            support,
        ))),
        None,
        None,
    ));
    // Auto Reframe finds its subjects with the ONNX face / body models over the FFmpeg frames.
    shell.shell().flow_env.services = Box::new(
        AnalysisServices::new(Box::new(crate::PortableAnalysisBackend))
            .with_worker_pool(app_worker_pool())
            .with_looks(Arc::clone(&looks))
            .with_preset_support(support.to_path_buf())
            .with_anonymize(AnonymizeRunner::new(Arc::clone(&mattes), system_anonymize_sources(support.to_path_buf())))
            .with_speech(sq_platform_tts::system_engine())
            .with_voice_recorder(crate::MicRecorder::system(), support.join("Voiceovers"))
            .with_frame_sampler(PictureSampler::new(picture.clone())),
    );
    let workspaces = support.join("workspaces.json");
    let effects = EffectsHost::new(EffectsDrawPanel::new(
        Box::new(FileView(Rc::clone(&defaults))),
        Box::new(crate::speech::RandomIds),
    ));
    // Swift: SharedUIController.swift:296-297 (`connectHostDefaults`, `loadHeightPrefs`): the saved track height preset
    // (Medium rows by default, not stretched) and the per-sequence heights.
    let mut timeline = TimelinePanelHost::new(theme);
    let store = FileView(Rc::clone(&defaults));
    timeline.inner().panel.load_height_prefs(&store);
    timeline.inner().panel.connect_host_defaults(Rc::new(RefCell::new(store)));
    let root = AppRoot::new(monitor, library, timeline, inspector, shell)
        .with_effects(effects)
        .with_graphics(
            GraphicsHost::new()
                .with_eyedropper(eyedropper.clone())
                .with_picker_aids(picker_aids.clone())
                .with_defaults(Box::new(FileView(Rc::clone(&defaults)))),
        )
        .with_text(
            TextHost::new()
                .with_picker_aids(picker_aids)
                .with_transcription(crate::speech::platform_service(), Rc::clone(&defaults))
                .with_looks(Arc::clone(&looks), Rc::clone(&defaults)),
        )
        .with_look_store(looks)
        .with_color_eyedropper(eyedropper)
        .with_color_luts(sq_library::lutlibrary::LUTLibrary::new(support.join("LUTs"), wall_clock()))
        .with_meter(MeterPanel::new(Box::new(FileView(Rc::clone(&defaults)))))
        .with_lists(crate::MarkerListHost::new())
        .with_scope_picture(picture)
        .with_timeline_link(timeline_link)
        .with_storage(workspaces, recents_path)
        .with_prefs_store(support, defaults)
        .with_analysis(analysis);
    Some(match source {
        Some(source) => root.with_source(source),
        None => root,
    })
}

#[cfg(test)]
mod restore_tests {
    use super::*;

    /// A fresh machine has no `Templates` folder: the root still knows where templates go and the first save makes it.
    #[test]
    fn a_fresh_support_folder_takes_the_first_saved_template() {
        let support = crate::test_rig::test_dir("sq-app-hosts-template-folder");
        let mut root =
            standard_root(&support, Arc::new(sq_runtime::FakeClock::new()), DrawTheme::default()).expect("root");
        let folder = root.shell.shell().template_folder.take().expect("the app wires the template folder");
        assert_eq!(folder.path, support.join("Templates"));
        assert!(!folder.path.exists(), "nothing is made before a save");
        let mut ids = sq_core_time::SequentialIds::default();
        let mut template = sq_core_project::project_template::ProjectTemplate::built_in().remove(0);
        template.id = sq_core_project::project_template::ProjectTemplate::user_id(&mut ids);
        template.name = "My Tpl".to_string();
        folder.save(&template).expect("saves into the missing folder");
        assert_eq!(folder.load(&mut ids).iter().filter(|t| t.name == "My Tpl").count(), 1);
        let _ = std::fs::remove_dir_all(&support);
    }

    #[test]
    fn the_watched_library_folders_come_back_at_the_next_start() {
        let root = crate::test_rig::test_dir("sq-app-hosts-restore-folders");
        let watched = root.join("Footage");
        std::fs::create_dir_all(&watched).expect("dir");
        let defaults = FileDefaults::shared(&root);
        let folder = sq_library::watched_folder::WatchedFolder::new(
            sq_core_time::Id::from_u128(77),
            watched.clone(),
            None,
            None,
        );
        sq_library::library_folder_store::LibraryFolderStore::save(&[folder], &mut FileView(Rc::clone(&defaults)));
        let panel = library_panel_with(&root, defaults).expect("panel");
        let urls: Vec<_> = panel.model.folders().iter().map(|f| f.folder.url.clone()).collect();
        assert_eq!(urls, vec![watched]);
        let _ = std::fs::remove_dir_all(&root);
    }
}
