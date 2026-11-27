// Swift: SQAppShell/Library/LibraryHost.swift (run, onApplyPreset, applyTextTemplate)
//! The Library panel as an app host: delegates to [`LibraryPanelHost`], then turns the panel's and the model's events
//! into session calls (preset apply, built-in graphics) and status lines; the rest waits in [`LibraryHost::take_deferred`].

use crate::poster_pump::{PosterPump, SharedAtlas};
use crate::preset_stills::{BUDGET, StillCache, graphic_still, preset_still};
use crate::preview_video::ffmpeg_pictures;
use crate::project_services::FfmpegPosters;
use sq_app_shell::{AppEvent, AppHost, HostCx, ImageUpload};
use sq_core_effects::effect_preset::ApplyMode;
use sq_core_model::{MediaFingerprint, MediaRef};
use sq_core_time::{Id, Time};
use sq_draw::{A11y, Canvas, DrawTheme, InputEvent};
use sq_draw_library::library::library_draw_panel::LibraryPicture;
use sq_draw_library::library::library_draw_panel::{LibraryDrawPanel, LibraryPanelEvent, LibraryRequest};
use sq_draw_library::library::library_panel_host::LibraryPanelHost;
use sq_draw_library::library::library_panel_logic::LibraryPresetCell;
use sq_draw_library::library::library_panel_model::LibraryModelEvent;
use sq_draw_library::library::text_templates::TextTemplateEntry;
use sq_editor_session::{Change, EditorSession};
use sq_library::library_item_kind::LibraryItemKind;
use sq_library::watched_folder::LibraryEntryID;
use sq_uikit::controls_grid::CGRect;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;

/// What the host could not do alone (dialogs, menus, the timeline panel, the template catalog).
#[derive(Clone, Debug)]
pub enum LibraryDeferred {
    /// A request that needs a dialog, a file chooser or the timeline.
    Request(LibraryRequest),
    /// A panel menu, a drag or a model hook the app root handles.
    Panel(LibraryPanelEvent),
    /// A model hook (folders changed, title block, workspaces).
    Model(LibraryModelEvent),
}

/// The Library panel in a dock slot.
pub struct LibraryHost {
    inner: LibraryPanelHost,
    /// The remembered preset apply mode (`PresetApplyModeSetting.load`).
    apply_mode: Box<dyn Fn() -> ApplyMode>,
    deferred: Vec<LibraryDeferred>,
    stills: StillCache,
    posters: Option<PosterPump>,
    /// Poster pictures by file, read by the panel host's picture source.
    media: Rc<RefCell<HashMap<LibraryEntryID, LibraryPicture>>>,
    /// The pump's id of each file (its media id) and back.
    media_ids: HashMap<LibraryEntryID, Id>,
    media_files: HashMap<Id, LibraryEntryID>,
    /// The picture of a previewed video.
    live: live_preview::LivePreview,
    /// The sequence played at the last sync.
    sequence_playing: bool,
    /// Set by the preview player just before it plays: the Program monitor gives way at the next event or frame.
    will_play: Rc<Cell<bool>>,
}

/// Makes the still of one preset cell when its turn comes.
type MakeStill = Box<dyn FnOnce() -> Option<Vec<u8>>>;

/// Height in pixels of the poster frames the grid tiles show.
const POSTER_HEIGHT: i64 = 160;

impl LibraryHost {
    /// A host around `panel`; `apply_mode` reads the remembered default for a double-click apply.
    pub fn new(panel: LibraryDrawPanel, apply_mode: Box<dyn Fn() -> ApplyMode>) -> LibraryHost {
        let media: Rc<RefCell<HashMap<LibraryEntryID, LibraryPicture>>> = Rc::default();
        let mut inner = LibraryPanelHost::new(panel);
        let shown = Rc::clone(&media);
        inner.picture = Some(Box::new(move |item, _| shown.borrow().get(&item.id()).copied()));
        let will_play = Rc::new(Cell::new(false));
        let starting = Rc::clone(&will_play);
        inner.panel.model.preview.on_will_play = Some(Box::new(move || starting.set(true)));
        LibraryHost {
            inner,
            apply_mode,
            deferred: Vec::new(),
            stills: StillCache::default(),
            posters: None,
            media,
            media_ids: HashMap::new(),
            media_files: HashMap::new(),
            live: live_preview::LivePreview::new(ffmpeg_pictures()),
            sequence_playing: false,
            will_play,
        }
    }

    /// Packs the preset stills and the poster frames of files into the root's thumbnail `atlas`; without it the tiles
    /// keep their kind icons. Posters come from FFmpeg on one worker.
    pub fn share_atlas(&mut self, atlas: SharedAtlas) {
        self.live.share_atlas(SharedAtlas::clone(&atlas));
        self.stills.share_atlas(SharedAtlas::clone(&atlas));
        self.posters.get_or_insert_with(|| {
            PosterPump::new(
                Arc::new(FfmpegPosters),
                Arc::new(crate::project_services::poster_pool(1)),
                SharedAtlas::clone(&atlas),
            )
        });
    }

    /// Replaces the poster pump (tests: another source, a manual pool).
    #[cfg(test)]
    pub(crate) fn set_posters(&mut self, pump: PosterPump) {
        self.posters = Some(pump);
    }

    /// Replaces the decoder of the previewed video (tests: frames without a media file).
    #[cfg(test)]
    pub(crate) fn set_preview_pictures(&mut self, open: crate::preview_video::OpenSource) {
        self.live.replace_source(open);
    }

    /// Runs `wake` when a poster decode finishes, so the window redraws without waiting for input.
    pub fn set_wake(&mut self, wake: Arc<dyn Fn() + Send + Sync>) {
        self.live.set_wake(Arc::clone(&wake));
        if let Some(p) = &mut self.posters {
            p.set_wake(wake);
        }
    }

    /// Requests the poster frames of the listed video and image files and takes in what finished.
    fn feed_posters(&mut self) {
        let Some(pump) = &mut self.posters else { return };
        let model = &self.inner.panel.model;
        let items = if model.is_showing_presets() {
            Vec::new()
        } else {
            let sections = model.sections();
            if sections.is_empty() { model.items() } else { sections.into_iter().flat_map(|s| s.items).collect() }
        };
        let mut refs = Vec::new();
        for item in items.iter().filter(|i| matches!(i.entry.kind, LibraryItemKind::Video | LibraryItemKind::Image)) {
            let next = Id::from_u128(self.media_ids.len() as u128 + 1);
            let id = *self.media_ids.entry(item.id()).or_insert(next);
            self.media_files.insert(id, item.id());
            let path = sq_os::paths::stored(&item.url);
            refs.push(MediaRef::new(id, item.entry.name(), &path, MediaFingerprint::new(item.entry.size)));
        }
        pump.touch(refs.iter().map(|m| m.id));
        let arrived = pump.pump(refs.iter(), POSTER_HEIGHT);
        let mut shown = self.media.borrow_mut();
        for id in pump.take_evicted() {
            if let Some(file) = self.media_files.get(&id) {
                shown.remove(file);
            }
        }
        for id in arrived {
            if let (Some(p), Some(file)) = (pump.placed(id), self.media_files.get(&id)) {
                shown.insert(
                    file.clone(),
                    LibraryPicture { slot: sq_app_shell::ATLAS_SLOT, source: p.uv(), size: p.size() },
                );
            }
        }
    }

    /// Makes a few missing stills of the presets the grid lists; true while more wait.
    fn feed_stills(&mut self) -> bool {
        if !self.inner.panel.model.is_showing_presets() {
            return false;
        }
        let mut made = 0;
        let mut left = false;
        let model = &self.inner.panel.model;
        let mut cells: Vec<(String, MakeStill)> = Vec::new();
        for t in model.visible_text_templates() {
            if let Some(g) = t.graphic_preset_id.clone() {
                cells.push((LibraryPresetCell::Template(t).preset_key(), Box::new(move || graphic_still(&g))));
            }
        }
        for p in model.visible_presets() {
            cells.push((LibraryPresetCell::User(p.clone()).preset_key(), Box::new(move || preset_still(&p))));
        }
        for (key, make) in cells {
            if !self.stills.has(&key) {
                if made >= BUDGET {
                    left = true;
                    continue;
                }
                made += 1;
            }
            if let Some(pic) = self.stills.picture(&key, make) {
                self.inner.panel.preset_pictures.insert(key, pic);
            }
        }
        left
    }

    /// The panel host (picture source, panel, model).
    pub fn panel_host(&mut self) -> &mut LibraryPanelHost {
        &mut self.inner
    }

    /// Replaces the source of the remembered apply mode (the stored Settings, once the root has them).
    pub fn set_apply_mode(&mut self, apply_mode: Box<dyn Fn() -> ApplyMode>) {
        self.apply_mode = apply_mode;
    }

    /// What waits for the app root, in the order it happened.
    pub fn take_deferred(&mut self) -> Vec<LibraryDeferred> {
        std::mem::take(&mut self.deferred)
    }

    /// A preview started to play: the Program monitor stops (one player at a time; the Source monitor does the same).
    fn yield_program(&mut self, cx: &mut HostCx) {
        if self.will_play.replace(false) {
            cx.session.stop_playback();
        }
    }

    fn route(&mut self, cx: &mut HostCx) {
        let panel = self.inner.take_events();
        let model = self.inner.panel.model.take_events();
        if panel.is_empty() && model.is_empty() {
            return;
        }
        let entries = self.inner.panel.model.template_entries();
        let mode = (self.apply_mode)();
        let (deferred, status) = route_library(cx.session, &entries, mode, panel, model);
        self.deferred.extend(deferred);
        for line in status {
            cx.emit(AppEvent::Status(line));
        }
    }
}

/// Runs the events that need only the session and returns the rest plus the status lines (Swift `run`, `onApplyPreset`).
pub fn route_library(
    session: &mut EditorSession,
    templates: &[TextTemplateEntry],
    default_mode: ApplyMode,
    panel: Vec<LibraryPanelEvent>,
    model: Vec<LibraryModelEvent>,
) -> (Vec<LibraryDeferred>, Vec<String>) {
    let (mut deferred, mut status) = (Vec::new(), Vec::new());
    for event in panel {
        match event {
            LibraryPanelEvent::Request(LibraryRequest::ApplyTextTemplate(id)) => {
                let Some(entry) = templates.iter().find(|t| t.id == id) else { continue };
                if entry.is_cta {
                    session.add_cta_end_card(None, None);
                } else if let Some(g) = &entry.graphic_preset_id {
                    session.add_graphic_preset(g, None, None);
                } else {
                    if let Some(c) = sq_inspector_ui::text::template_tiles::TextTemplateCatalog::entry(&id) {
                        session.add_text_clip(&c.template, None, None, Time::new(5, 1), None, false);
                    }
                }
            }
            LibraryPanelEvent::Request(LibraryRequest::ApplyAudioStack(id)) => {
                if !session.apply_stack_preset(&id, None) {
                    status.push(session.last_error().unwrap_or("The preset could not be applied.").to_string());
                }
            }
            LibraryPanelEvent::Request(r) => deferred.push(LibraryDeferred::Request(r)),
            other => deferred.push(LibraryDeferred::Panel(other)),
        }
    }
    for event in model {
        match event {
            LibraryModelEvent::ApplyPreset(item, mode) => {
                if !session.apply_preset(&item, None, mode.unwrap_or(default_mode)) {
                    status.push(session.last_error().unwrap_or("The preset could not be applied.").to_string());
                }
            }
            other => deferred.push(LibraryDeferred::Model(other)),
        }
    }
    (deferred, status)
}

impl AppHost for LibraryHost {
    fn sync(&mut self, session: &EditorSession) {
        // The sequence started: the preview gives way (one player at a time, as the Source monitor does).
        let playing = session.is_playing();
        if playing && !self.sequence_playing {
            self.inner.panel.pause_preview();
        }
        self.sequence_playing = playing;
        self.inner.sync(session);
    }

    fn layout(&mut self, frame: CGRect, cx: &mut HostCx) {
        self.inner.layout(frame, cx);
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        self.yield_program(cx);
        self.live.update(&mut self.inner.panel);
        self.feed_posters();
        if self.feed_stills() {
            cx.ui.request_animation();
        }
        self.inner.draw(c, t, cx);
    }

    fn take_image_uploads(&mut self) -> Vec<ImageUpload> {
        let mut uploads = self.stills.take_uploads();
        uploads.extend(self.live.take_upload());
        if let Some(p) = &mut self.posters {
            uploads.extend(p.take_uploads());
        }
        uploads
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let taken = self.inner.handle(e, cx);
        self.route(cx);
        self.yield_program(cx);
        taken
    }

    fn a11y(&self, a: &mut A11y) {
        self.inner.a11y(a);
        self.push_nodes(a);
    }

    fn a11y_action(&mut self, id: accesskit::NodeId, action: sq_app_shell::A11yAction, cx: &mut HostCx) -> bool {
        self.run_action(id, action, cx)
    }

    fn on_change(&mut self, changes: Change, cx: &mut HostCx) {
        self.inner.on_change(changes, cx);
        self.route(cx);
    }
}

mod access;
mod live_preview;

#[cfg(test)]
mod tests;

/// A host over a fresh panel in `root` (tests of the root).
#[cfg(test)]
pub(crate) fn test_host(root: &std::path::Path) -> LibraryHost {
    LibraryHost::new(tests::panel(root), Box::new(|| ApplyMode::Absolute))
}
