// Swift: ProjectMediaResolver.swift
//! The project's media resolver over `sq_media::MediaOpener`: path and info of every media item, offline checks, the
//! opened demuxers (cached, reopened when the path changes), proxies for the monitors, preview render cache files, still
//! images and audio sources. Safe from any thread (one lock around plain data; opens run outside it).

use std::any::Any;
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use sq_core_model::{MediaInfo, MediaRef, VideoTrackInfo};
use sq_core_time::Id;
use sq_export::core::traits::AudioSource;
use sq_media::demuxing::Demuxing;
use sq_media::media_error::MediaError;
use sq_media::media_opener::MediaOpener;

use crate::SessionMediaResolving;

/// Why a media lookup failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MediaResolveError {
    /// The project has no media item with this ID.
    UnknownMedia(Id),
    /// Nothing is at the stored path (the clip shows the offline placeholder).
    Offline { media: Id, path: String },
    /// The file could not be opened as video.
    Unreadable(Id),
    /// The file has no usable audio track.
    NoAudio(Id),
}

impl fmt::Display for MediaResolveError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MediaResolveError::UnknownMedia(_) => f.write_str("unknown media"),
            MediaResolveError::Offline { path, .. } => {
                write!(f, "offline: {}", sq_os::paths::display_form(sq_os::Platform::current(), path))
            }
            MediaResolveError::Unreadable(_) => f.write_str("unreadable media"),
            MediaResolveError::NoAudio(_) => f.write_str("no audio track"),
        }
    }
}

impl std::error::Error for MediaResolveError {}

/// Opens a media file's demuxer (Swift `DemuxerFactory`, async there; blocking here, called off the UI thread).
// Swift: ProjectMediaResolver.swift:27
pub type DemuxerFactory = Arc<dyn Fn(&Path) -> Result<Arc<dyn Demuxing>, MediaError> + Send + Sync>;
/// Opens a media file's audio at a sample rate (Swift `AudioFactory`).
// Swift: ProjectMediaResolver.swift:28
pub type AudioFactory = Arc<dyn Fn(&Path, i64) -> Result<Box<dyn AudioSource>, String> + Send + Sync>;
/// Where a media's ready proxy is: (media id, source path) -> proxy file, `None` = none.
// Swift: ProjectMediaResolver.swift:54
pub type ProxyUrlLookup = Arc<dyn Fn(Id, &str) -> Option<PathBuf> + Send + Sync>;
/// An opened audio source shared by its readers.
pub type SharedAudio = Arc<Mutex<Box<dyn AudioSource>>>;
/// Decodes a still image file (up to 8192 px) to pixels; `None` = unreadable.
pub type StillLoader = Arc<dyn Fn(&Path) -> Option<StillFrame> + Send + Sync>;

/// The decoded picture of a still-image item.
#[derive(Clone, Debug)]
pub struct StillFrame {
    /// Track facts of the picture (the real file size, not the capped buffer's).
    pub info: VideoTrackInfo,
    /// RGBA8 rows, top down.
    pub rgba: Arc<Vec<u8>>,
}

/// The collaborators of a resolver. `opener` is the platform's decoder opener; the rest are optional seams.
pub struct ResolverDeps {
    pub opener: Arc<dyn MediaOpener>,
    pub audio: Option<AudioFactory>,
    pub still_loader: Option<StillLoader>,
    pub file_exists: Arc<dyn Fn(&str) -> bool + Send + Sync>,
    /// Decoded stills are kept up to this many bytes; the oldest go first.
    pub still_cache_bytes: usize,
}

impl ResolverDeps {
    /// Real file system, no audio or still loader, 512 MB of stills.
    pub fn new(opener: Arc<dyn MediaOpener>) -> ResolverDeps {
        ResolverDeps {
            opener,
            audio: None,
            still_loader: None,
            file_exists: Arc::new(|p| Path::new(p).exists()),
            still_cache_bytes: 512 * 1024 * 1024,
        }
    }
}

struct State {
    refs: BTreeMap<Id, MediaRef>,
    demuxers: BTreeMap<Id, Arc<dyn Demuxing>>,
    /// Whether the decoder that opened each media decodes in hardware.
    hardware: BTreeMap<Id, bool>,
    audio: BTreeMap<Id, SharedAudio>,
    /// Media without a usable audio track (or whose audio failed): not retried.
    no_audio: BTreeSet<Id>,
    sample_rate: i64,
    /// Decoded stills (path they were read from), decoded once, oldest first in `still_order`.
    stills: BTreeMap<Id, (String, StillFrame)>,
    still_order: Vec<Id>,
    /// Opened proxies, with the proxy file they were opened from.
    proxies: BTreeMap<Id, (PathBuf, Arc<dyn Demuxing>)>,
    /// Bumped by `drop_proxies`: an open that began before must not store its (old file's) demuxer.
    proxy_epochs: BTreeMap<Id, i64>,
    render_cache_files: BTreeMap<Id, PathBuf>,
    render_cache_demuxers: BTreeMap<Id, Arc<dyn Demuxing>>,
    proxy_lookup: Option<ProxyUrlLookup>,
    project_folder: Option<PathBuf>,
}

/// Resolves a `Clip.media` id to a demuxer / audio source from the project's media refs (`MediaRef.path`). Opened
/// demuxers are cached; [`SessionMediaResolving::prepare`] opens them ahead of time in the background, and a lookup that
/// finds nothing cached opens the file itself and blocks until it is loaded (never on the UI thread: the engine calls
/// from decode threads). A missing file is `Offline`, never a crash. It is also the engine's [`MediaOpener`].
// shortcut: no "one open in flight per media" sharing between `prepare` and a lookup that race; the second open is
// discarded when the first is cached. Upgrade when a real file shows two simultaneous opens costing noticeable time.
pub struct ProjectMediaResolver {
    opener: Arc<dyn MediaOpener>,
    audio_factory: Option<AudioFactory>,
    still_loader: Option<StillLoader>,
    file_exists: Arc<dyn Fn(&str) -> bool + Send + Sync>,
    still_budget: usize,
    state: Mutex<State>,
    color_resolver: Mutex<Option<Arc<dyn Any + Send + Sync>>>,
    gyro_warper: Mutex<Option<Arc<dyn Any + Send + Sync>>>,
    on_color_changed: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

impl ProjectMediaResolver {
    /// A resolver with the given collaborators.
    // Swift: ProjectMediaResolver.swift:92
    pub fn new(deps: ResolverDeps) -> ProjectMediaResolver {
        ProjectMediaResolver {
            opener: deps.opener,
            audio_factory: deps.audio,
            still_loader: deps.still_loader,
            file_exists: deps.file_exists,
            still_budget: deps.still_cache_bytes,
            state: Mutex::new(State {
                refs: BTreeMap::new(),
                demuxers: BTreeMap::new(),
                hardware: BTreeMap::new(),
                audio: BTreeMap::new(),
                no_audio: BTreeSet::new(),
                sample_rate: 48_000,
                stills: BTreeMap::new(),
                still_order: Vec::new(),
                proxies: BTreeMap::new(),
                proxy_epochs: BTreeMap::new(),
                render_cache_files: BTreeMap::new(),
                render_cache_demuxers: BTreeMap::new(),
                proxy_lookup: None,
                project_folder: None,
            }),
            color_resolver: Mutex::new(None),
            gyro_warper: Mutex::new(None),
            on_color_changed: Mutex::new(None),
        }
    }

    fn with<R>(&self, f: impl FnOnce(&mut State) -> R) -> R {
        use sq_playback::engine::frame_trace::{Sub, sub_add, sub_add_duration, sub_start, trace_on};
        if !trace_on() {
            return f(&mut lock(&self.state));
        }
        // The layers phase of a composite books how long it waited for this mutex; any other thread books how long it held
        // it, to name who blocks the render thread.
        let waiting = sub_start();
        let mut guard = lock(&self.state);
        sub_add(Sub::MediaLock, waiting);
        if waiting.is_some() {
            return f(&mut guard);
        }
        let held = std::time::Instant::now();
        let out = f(&mut guard);
        drop(guard);
        sub_add_duration(Sub::MediaHeldElsewhere, held.elapsed());
        out
    }

    /// Per-layer color pipelines for playback and export (the render crate's `LayerColorResolver`, held type-erased
    /// because this crate does not depend on `sq-render`). Set by the app that builds it from this resolver's infos.
    // Swift: ProjectMediaResolver.swift:73
    pub fn color_resolver(&self) -> Option<Arc<dyn Any + Send + Sync>> {
        lock(&self.color_resolver).clone()
    }

    /// Installs the color resolver and what to call when its LUTs and pipelines must be rebuilt (a media path or the
    /// project folder changed).
    pub fn set_color_resolver(
        &self,
        resolver: Option<Arc<dyn Any + Send + Sync>>,
        invalidate: Option<Arc<dyn Fn() + Send + Sync>>,
    ) {
        *lock(&self.color_resolver) = resolver;
        *lock(&self.on_color_changed) = invalidate;
    }

    /// The Gyroflow stabilizer frames for playback and export (type-erased like [`ProjectMediaResolver::color_resolver`]).
    // Swift: ProjectMediaResolver.swift:75
    pub fn gyro_warper(&self) -> Option<Arc<dyn Any + Send + Sync>> {
        lock(&self.gyro_warper).clone()
    }

    /// Installs the gyro warper.
    pub fn set_gyro_warper(&self, warper: Option<Arc<dyn Any + Send + Sync>>) {
        *lock(&self.gyro_warper) = warper;
    }

    fn color_changed(&self) {
        let f = lock(&self.on_color_changed).clone();
        if let Some(f) = f {
            f();
        }
    }

    /// Opens the demuxer of a file: the one the import probe just built when it is still handed over, else a fresh open.
    // Swift: ProjectMediaResolver.swift:76
    pub fn open_demuxer(
        opener: &dyn MediaOpener,
        path: &Path,
        media: Id,
        now: sq_core_time::Timestamp,
    ) -> Result<Arc<dyn Demuxing>, MediaError> {
        if let Some(probed) = sq_media::demuxer_handoff::DemuxerHandoff::take(path, now) {
            return Ok(probed);
        }
        Ok(opener.open(path, media)?.demuxer)
    }

    /// Opens a file's audio at `sample_rate` through the injected factory.
    // Swift: ProjectMediaResolver.swift:83
    // Swift decodes with AVFoundation. Here the app injects `ResolverDeps::audio` (FFmpeg); without it every file
    // reports "no audio".
    pub fn open_audio(&self, path: &Path, sample_rate: i64) -> Result<Box<dyn AudioSource>, String> {
        match &self.audio_factory {
            Some(f) => f(path, sample_rate),
            None => Err("no audio decoder".to_string()),
        }
    }

    /// The folder a project-relative LUT path (`Files/Library/x.cube`) is read from; `None` for a loose project file.
    // Swift: ProjectMediaResolver.swift:127
    pub fn set_project_folder(&self, folder: Option<PathBuf>) {
        let changed = self.with(|s| {
            if s.project_folder == folder {
                return false;
            }
            s.project_folder = folder;
            true
        });
        if changed {
            self.color_changed();
        }
    }

    /// The project folder last set.
    pub fn project_folder(&self) -> Option<PathBuf> {
        self.with(|s| s.project_folder.clone())
    }

    /// The stored path of a media.
    // Swift: ProjectMediaResolver.swift:132
    pub fn path(&self, id: Id) -> Option<String> {
        self.with(|s| s.refs.get(&id).map(|r| r.path.clone()))
    }

    /// The probe info of a media.
    // Swift: ProjectMediaResolver.swift:134
    pub fn info(&self, id: Id) -> Option<MediaInfo> {
        self.with(|s| s.refs.get(&id).and_then(|r| r.info.clone()))
    }

    /// Replaces the known media. Cached sources of items whose path changed (relink) or that are gone are dropped; a
    /// sample-rate change drops all audio.
    // Swift: ProjectMediaResolver.swift:138
    pub fn update(&self, media: &[MediaRef], sample_rate: Option<i64>) {
        let path_changed = self.with(|s| {
            let new: BTreeMap<Id, &MediaRef> = media.iter().map(|m| (m.id, m)).collect();
            let known: BTreeSet<Id> = s.refs.keys().chain(s.demuxers.keys()).copied().collect();
            for id in known {
                if new.get(&id).is_none_or(|n| Some(&n.path) != s.refs.get(&id).map(|r| &r.path)) {
                    s.demuxers.remove(&id);
                    s.hardware.remove(&id);
                    s.audio.remove(&id);
                    s.no_audio.remove(&id);
                    s.stills.remove(&id);
                    s.still_order.retain(|x| *x != id);
                    s.proxies.remove(&id);
                }
            }
            let path_changed = new.iter().any(|(id, r)| s.refs.get(id).is_some_and(|old| old.path != r.path));
            // Other audio channels chosen for an item: its audio source is opened again, the picture stays.
            for (id, r) in &new {
                let Some(old) = s.refs.get(id) else { continue };
                let channel_map =
                    |m: &MediaRef| m.info.as_ref().and_then(|i| i.audio.as_ref()).map(|a| a.channel_map.clone());
                if channel_map(old) != channel_map(r) {
                    s.audio.remove(id);
                    s.no_audio.remove(id);
                }
            }
            s.refs = new.into_iter().map(|(k, v)| (k, v.clone())).collect();
            if let Some(rate) = sample_rate.filter(|r| *r != s.sample_rate) {
                s.sample_rate = rate;
                s.audio.clear();
                s.no_audio.clear();
            }
            path_changed
        });
        if path_changed {
            self.color_changed();
        }
    }

    /// The files of these items changed on disk (overwritten, gone, back): every cached source is dropped, so the next
    /// use opens the file as it is now. Proxies stay; the engine's `media_changed` decides about them.
    // Swift: ProjectMediaResolver.swift:162
    pub fn invalidate(&self, ids: &BTreeSet<Id>) {
        if ids.is_empty() {
            return;
        }
        self.with(|s| {
            for id in ids {
                s.demuxers.remove(id);
                s.hardware.remove(id);
                s.audio.remove(id);
                s.no_audio.remove(id);
                s.stills.remove(id);
                s.still_order.retain(|x| x != id);
                s.proxies.remove(id);
                *s.proxy_epochs.entry(*id).or_default() += 1;
            }
        });
    }

    /// Sample rate audio sources are opened with (the active sequence's).
    // Swift: ProjectMediaResolver.swift:174
    pub fn sample_rate(&self) -> i64 {
        self.with(|s| s.sample_rate)
    }

    /// Whether the file is not at its path (an unknown media counts as offline).
    // Swift: ProjectMediaResolver.swift:175
    pub fn is_offline(&self, id: Id) -> bool {
        match self.path(id) {
            Some(p) => !(self.file_exists)(&p),
            None => true,
        }
    }

    fn ref_of(&self, id: Id) -> Option<MediaRef> {
        self.with(|s| s.refs.get(&id).cloned())
    }

    /// Caches a finished open only if the media still has the path it was opened for.
    fn finish_video(&self, id: Id, path: &str, result: Option<Arc<dyn Demuxing>>) -> Option<Arc<dyn Demuxing>> {
        self.with(|s| {
            if s.refs.get(&id).map(|r| r.path.as_str()) != Some(path) {
                return None;
            }
            if let Some(cached) = s.demuxers.get(&id) {
                return Some(Arc::clone(cached));
            }
            let d = result?;
            s.demuxers.insert(id, Arc::clone(&d));
            Some(d)
        })
    }

    fn cached_video(&self, id: Id) -> Option<Arc<dyn Demuxing>> {
        self.with(|s| s.demuxers.get(&id).cloned())
    }

    fn open_video(&self, id: Id, path: &str) -> Option<Arc<dyn Demuxing>> {
        let opened = self.opener.open(Path::new(path), id).ok()?;
        let hardware = opened.decoder.is_hardware();
        self.with(|s| {
            if s.refs.get(&id).map(|r| r.path.as_str()) == Some(path) {
                s.hardware.insert(id, hardware);
            }
        });
        Some(opened.demuxer)
    }

    /// Whether the decoder that opened this media works in hardware (`None` until it was opened). A media without
    /// hardware decode gets its proxy ahead of the others.
    pub fn decodes_in_hardware(&self, media: Id) -> Option<bool> {
        self.with(|s| s.hardware.get(&media).copied())
    }

    /// Loads the demuxer and audio source of each item (concurrently, four at a time) into the cache. Offline or
    /// unreadable items are skipped; a later lookup reports why. Returns the ids that are ready for video. Blocking.
    // Swift: ProjectMediaResolver.swift:239
    pub fn prepare(&self, ids: &[Id]) -> BTreeSet<Id> {
        let mut ready = BTreeSet::new();
        for chunk in ids.chunks(4) {
            std::thread::scope(|scope| {
                let jobs: Vec<_> = chunk.iter().map(|id| scope.spawn(move || (*id, self.prepare_one(*id)))).collect();
                for j in jobs {
                    if let Ok((id, true)) = j.join() {
                        ready.insert(id);
                    }
                }
            });
        }
        ready
    }

    fn prepare_one(&self, id: Id) -> bool {
        let Some(r) = self.ref_of(id).filter(|r| (self.file_exists)(&r.path)) else { return false };
        if r.info.as_ref().is_some_and(|i| i.is_still) {
            return matches!(self.still_frame(id), Ok(Some(_)));
        }
        let ready =
            self.cached_video(id).is_some() || self.finish_video(id, &r.path, self.open_video(id, &r.path)).is_some();
        let skip_audio = self.with(|s| s.audio.contains_key(&id) || s.no_audio.contains(&id));
        if !skip_audio {
            let _ = self.audio(id);
        }
        ready
    }

    /// The file of a media (not for stills or offline items).
    // Swift: ProjectMediaResolver.swift:264
    pub fn file_url(&self, media: Id) -> Option<PathBuf> {
        let r = self.ref_of(media)?;
        (r.info.as_ref().is_none_or(|i| !i.is_still) && (self.file_exists)(&r.path)).then(|| PathBuf::from(r.path))
    }

    /// Preview render cache: the fake media id of a cached segment is served from this file. Registered when the
    /// segment is rendered; the file is opened on the first lookup (a decode thread).
    // Swift: ProjectMediaResolver.swift:272
    pub fn set_render_cache_file(&self, media: Id, url: PathBuf) {
        self.with(|s| {
            if s.render_cache_files.get(&media) != Some(&url) {
                s.render_cache_demuxers.remove(&media);
            }
            s.render_cache_files.insert(media, url);
        });
    }

    /// Forgets a registered render cache file.
    // Swift: ProjectMediaResolver.swift:278
    pub fn remove_render_cache_file(&self, media: Id) {
        self.with(|s| {
            s.render_cache_files.remove(&media);
            s.render_cache_demuxers.remove(&media);
        });
    }

    /// The demuxer of a media (or of a registered render cache file); opens the file when nothing is cached. Blocking.
    // Swift: ProjectMediaResolver.swift:282
    pub fn demuxer(&self, media: Id) -> Result<Arc<dyn Demuxing>, MediaResolveError> {
        if let Some(url) = self.with(|s| s.render_cache_files.get(&media).cloned()) {
            if let Some(d) = self.with(|s| s.render_cache_demuxers.get(&media).cloned()) {
                return Ok(d);
            }
            if !url.exists() {
                return Err(MediaResolveError::Offline { media, path: url.to_string_lossy().into_owned() });
            }
            let d = self.opener.open(&url, media).map_err(|_| MediaResolveError::Unreadable(media))?.demuxer;
            return Ok(self.with(|s| {
                if s.render_cache_files.get(&media) != Some(&url) {
                    return d;
                }
                Arc::clone(s.render_cache_demuxers.entry(media).or_insert(d))
            }));
        }
        for _ in 0..3 {
            let r = self.ref_of(media).ok_or(MediaResolveError::UnknownMedia(media))?;
            if !(self.file_exists)(&r.path) {
                return Err(MediaResolveError::Offline { media, path: r.path });
            }
            if let Some(d) = self.cached_video(media) {
                return Ok(d);
            }
            let opened = self.open_video(media, &r.path);
            if let Some(d) = self.finish_video(media, &r.path, opened) {
                return Ok(d);
            }
            if self.path(media).as_deref() == Some(r.path.as_str()) {
                return Err(MediaResolveError::Unreadable(media));
            }
        }
        Err(MediaResolveError::Unreadable(media))
    }

    /// The original's demuxer, opened without failing (shared with `prepare` and the engine's lookups). `None` when
    /// offline, unknown or unreadable. Blocking.
    // Swift: ProjectMediaResolver.swift:311
    pub fn opened_demuxer(&self, media: Id) -> Option<Arc<dyn Demuxing>> {
        let r = self.ref_of(media).filter(|r| (self.file_exists)(&r.path))?;
        if let Some(d) = self.cached_video(media) {
            return Some(d);
        }
        self.finish_video(media, &r.path, self.open_video(media, &r.path))
    }

    /// Forgets the opened proxies of these media: the proxy file was replaced or removed, so the next `proxy_demuxer`
    /// opens it again, even under the same file name.
    // Swift: ProjectMediaResolver.swift:320
    pub fn drop_proxies(&self, ids: &BTreeSet<Id>) {
        self.with(|s| {
            for id in ids {
                s.proxies.remove(id);
                *s.proxy_epochs.entry(*id).or_default() += 1;
            }
        });
    }

    /// Installs (or with `None` removes) the proxy lookup; opened proxies are dropped.
    // Swift: ProjectMediaResolver.swift:325
    pub fn set_proxy_lookup(&self, lookup: Option<ProxyUrlLookup>) {
        self.with(|s| {
            s.proxy_lookup = lookup;
            s.proxies.clear();
        });
    }

    /// The installed proxy lookup (`None` when none).
    // Swift: ProjectMediaResolver.swift:332
    pub fn current_proxy_lookup(&self) -> Option<ProxyUrlLookup> {
        self.with(|s| s.proxy_lookup.clone())
    }

    /// The media's ready proxy, for the monitors only (scrub and optionally playback). Export and every other reader use
    /// [`ProjectMediaResolver::demuxer`], which always opens the original. `None` when there is no ready proxy or it
    /// cannot be opened. Blocking.
    // Swift: ProjectMediaResolver.swift:336
    pub fn proxy_demuxer(&self, media: Id) -> Option<Arc<dyn Demuxing>> {
        let r = self.ref_of(media).filter(|r| r.info.as_ref().is_none_or(|i| !i.is_still))?;
        let lookup = self.current_proxy_lookup()?;
        let url = lookup(media, &r.path)?;
        let (cached, epoch) =
            self.with(|s| (s.proxies.get(&media).cloned(), s.proxy_epochs.get(&media).copied().unwrap_or(0)));
        if let Some((u, d)) = cached
            && u == url
        {
            return Some(d);
        }
        let d = self.opener.open(&url, media).ok()?.demuxer;
        self.with(|s| {
            if s.refs.get(&media).map(|x| &x.path) != Some(&r.path)
                || s.proxy_epochs.get(&media).copied().unwrap_or(0) != epoch
            {
                return None;
            }
            if let Some((u, c)) = s.proxies.get(&media)
                && *u == url
            {
                return Some(Arc::clone(c));
            }
            s.proxies.insert(media, (url, Arc::clone(&d)));
            Some(d)
        })
    }

    /// The decoded picture of a still-image item (once per path). `None` = not a still.
    // Swift: ProjectMediaResolver.swift:353
    pub fn still_frame(&self, media: Id) -> Result<Option<StillFrame>, MediaResolveError> {
        let Some(r) = self.ref_of(media).filter(|r| r.info.as_ref().is_some_and(|i| i.is_still)) else {
            return Ok(None);
        };
        if !(self.file_exists)(&r.path) {
            return Err(MediaResolveError::Offline { media, path: r.path });
        }
        if let Some((p, f)) = self.with(|s| s.stills.get(&media).cloned())
            && p == r.path
        {
            return Ok(Some(f));
        }
        let loader = self.still_loader.as_ref().ok_or(MediaResolveError::Unreadable(media))?;
        let mut frame = loader(Path::new(&r.path)).ok_or(MediaResolveError::Unreadable(media))?;
        // The picture counts with its real size (the buffer is capped), so Scale 1 is one file pixel.
        if let Some(v) = r.info.as_ref().and_then(|i| i.video.as_ref()) {
            frame.info.width = v.width;
            frame.info.height = v.height;
        }
        let budget = self.still_budget;
        Ok(Some(self.with(|s| {
            if s.refs.get(&media).map(|x| &x.path) != Some(&r.path) {
                return frame;
            }
            if let Some((p, f)) = s.stills.get(&media)
                && *p == r.path
            {
                return f.clone();
            }
            s.stills.insert(media, (r.path.clone(), frame.clone()));
            s.still_order.retain(|x| *x != media);
            s.still_order.push(media);
            let mut total: usize = s.stills.values().map(|(_, f)| f.rgba.len()).sum();
            // The one just decoded always stays.
            while total > budget && s.still_order.len() > 1 {
                let old = s.still_order.remove(0);
                if let Some((_, f)) = s.stills.remove(&old) {
                    total -= f.rgba.len();
                }
            }
            frame
        })))
    }

    /// The media's audio source (opened once per path and rate, shared). Blocking.
    // Swift: ProjectMediaResolver.swift:375
    pub fn audio(&self, media: Id) -> Result<SharedAudio, MediaResolveError> {
        for _ in 0..3 {
            let (r, none, rate) =
                self.with(|s| (s.refs.get(&media).cloned(), s.no_audio.contains(&media), s.sample_rate));
            let r = r.ok_or(MediaResolveError::UnknownMedia(media))?;
            if !(self.file_exists)(&r.path) {
                return Err(MediaResolveError::Offline { media, path: r.path });
            }
            if let Some(a) = self.with(|s| s.audio.get(&media).cloned()) {
                return Ok(a);
            }
            if none {
                return Err(MediaResolveError::NoAudio(media));
            }
            let opened = self.open_audio(Path::new(&r.path), rate).ok();
            let done = self.with(|s| {
                let same = s.refs.get(&media).map(|x| &x.path) == Some(&r.path) && s.sample_rate == rate;
                if !same {
                    return None;
                }
                if let Some(c) = s.audio.get(&media) {
                    return Some(Ok(Arc::clone(c)));
                }
                match opened {
                    Some(a) => {
                        let shared: SharedAudio = Arc::new(Mutex::new(a));
                        s.audio.insert(media, Arc::clone(&shared));
                        Some(Ok(shared))
                    }
                    None => {
                        s.no_audio.insert(media);
                        Some(Err(MediaResolveError::NoAudio(media)))
                    }
                }
            });
            if let Some(result) = done {
                return result;
            }
        }
        Err(MediaResolveError::NoAudio(media))
    }
}

impl SessionMediaResolving for ProjectMediaResolver {
    fn set_project_folder(&self, folder: Option<PathBuf>) {
        ProjectMediaResolver::set_project_folder(self, folder);
    }
    fn info(&self, id: Id) -> Option<MediaInfo> {
        ProjectMediaResolver::info(self, id)
    }
    fn update(&self, media: &[MediaRef], sample_rate: Option<i64>) {
        ProjectMediaResolver::update(self, media, sample_rate);
    }
    fn invalidate(&self, ids: &BTreeSet<Id>) {
        ProjectMediaResolver::invalidate(self, ids);
    }
    fn prepare(&self, ids: &[Id]) -> BTreeSet<Id> {
        ProjectMediaResolver::prepare(self, ids)
    }
    fn file_path(&self, id: Id) -> Option<PathBuf> {
        self.file_url(id)
    }
}

/// The engine opens through the resolver: the media's stored path decides, an offline or unknown media fails instead of
/// reaching the decoder.
impl MediaOpener for ProjectMediaResolver {
    fn open(&self, path: &Path, media: Id) -> Result<sq_media::media_opener::OpenedMedia, MediaError> {
        if !(self.file_exists)(&path.to_string_lossy()) {
            return Err(MediaError::Unreadable);
        }
        self.opener.open(path, media)
    }

    fn open_proxy(
        &self,
        file: &Path,
        media: Id,
        original: &sq_media::media_opener::OpenedMedia,
    ) -> Result<sq_media::media_opener::OpenedMedia, MediaError> {
        if !(self.file_exists)(&file.to_string_lossy()) {
            return Err(MediaError::Unreadable);
        }
        self.opener.open_proxy(file, media, original)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::MediaFingerprint;
    use sq_media::media_opener::OpenedMedia;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct CountingOpener(AtomicUsize);

    impl MediaOpener for CountingOpener {
        fn open(&self, _path: &Path, _media: Id) -> Result<OpenedMedia, MediaError> {
            self.0.fetch_add(1, Ordering::SeqCst);
            Err(MediaError::Unreadable)
        }
    }

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    fn resolver(exists: bool) -> (ProjectMediaResolver, Arc<CountingOpener>) {
        let opener = Arc::new(CountingOpener(AtomicUsize::new(0)));
        let mut deps = ResolverDeps::new(Arc::clone(&opener) as Arc<dyn MediaOpener>);
        deps.file_exists = Arc::new(move |_| exists);
        (ProjectMediaResolver::new(deps), opener)
    }

    fn media(n: u128, path: &str) -> MediaRef {
        MediaRef::new(id(n), "a.mov", path, MediaFingerprint::new(1))
    }

    #[test]
    fn unknown_media_is_reported() {
        let (r, _) = resolver(true);
        assert_eq!(r.demuxer(id(1)).err(), Some(MediaResolveError::UnknownMedia(id(1))));
        assert!(r.is_offline(id(1)));
    }

    #[test]
    fn offline_file_is_offline_not_unreadable() {
        let (r, opener) = resolver(false);
        r.update(&[media(1, "/gone/a.mov")], None);
        assert_eq!(
            r.demuxer(id(1)).err(),
            Some(MediaResolveError::Offline { media: id(1), path: "/gone/a.mov".into() })
        );
        assert!(r.is_offline(id(1)));
        assert_eq!(opener.0.load(Ordering::SeqCst), 0);
        assert!(r.prepare(&[id(1)]).is_empty());
        assert_eq!(r.file_url(id(1)), None);
    }

    #[test]
    fn unreadable_file_opens_three_times_at_most() {
        let (r, opener) = resolver(true);
        r.update(&[media(1, "/x/a.mov")], None);
        assert_eq!(r.demuxer(id(1)).err(), Some(MediaResolveError::Unreadable(id(1))));
        assert_eq!(opener.0.load(Ordering::SeqCst), 1);
        assert!(r.prepare(&[id(1)]).is_empty());
        assert_eq!(r.audio(id(1)).err(), Some(MediaResolveError::NoAudio(id(1))));
        assert_eq!(r.audio(id(1)).err(), Some(MediaResolveError::NoAudio(id(1))));
    }

    #[test]
    fn path_and_info_follow_update() {
        let (r, _) = resolver(true);
        r.update(&[media(1, "/x/a.mov")], Some(44_100));
        assert_eq!(r.path(id(1)).as_deref(), Some("/x/a.mov"));
        assert_eq!(r.sample_rate(), 44_100);
        assert_eq!(r.file_url(id(1)), Some(PathBuf::from("/x/a.mov")));
        r.update(&[], None);
        assert_eq!(r.path(id(1)), None);
    }

    #[test]
    fn render_cache_file_is_served_by_its_fake_id() {
        let (r, opener) = resolver(false);
        let fake = id(9);
        r.set_render_cache_file(fake, PathBuf::from("/cache/x.mov"));
        assert_eq!(
            r.demuxer(fake).err(),
            Some(MediaResolveError::Offline { media: fake, path: "/cache/x.mov".into() })
        );
        r.remove_render_cache_file(fake);
        assert_eq!(r.demuxer(fake).err(), Some(MediaResolveError::UnknownMedia(fake)));
        assert_eq!(opener.0.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn proxy_lookup_can_be_reset_without_growing() {
        let (r, _) = resolver(true);
        assert!(r.current_proxy_lookup().is_none());
        for _ in 0..1000 {
            let previous = r.current_proxy_lookup();
            r.set_proxy_lookup(Some(Arc::new(move |m, p| match &previous {
                Some(f) => f(m, p),
                None => None,
            })));
        }
        // Each wrapper calls the previous one: nothing in the resolver may wrap again on its own.
        r.set_proxy_lookup(Some(Arc::new(|_, _| Some(PathBuf::from("/p.mov")))));
        let got = r.current_proxy_lookup().and_then(|f| f(id(1), "/x"));
        assert_eq!(got, Some(PathBuf::from("/p.mov")));
        assert!(r.proxy_demuxer(id(1)).is_none());
    }

    #[test]
    fn color_hook_runs_when_a_path_changes() {
        let (r, _) = resolver(true);
        let hits = Arc::new(AtomicUsize::new(0));
        let h = Arc::clone(&hits);
        r.set_color_resolver(
            None,
            Some(Arc::new(move || {
                h.fetch_add(1, Ordering::SeqCst);
            })),
        );
        r.update(&[media(1, "/x/a.mov")], None);
        assert_eq!(hits.load(Ordering::SeqCst), 0);
        r.update(&[media(1, "/y/a.mov")], None);
        assert_eq!(hits.load(Ordering::SeqCst), 1);
        r.set_project_folder(Some(PathBuf::from("/p")));
        r.set_project_folder(Some(PathBuf::from("/p")));
        assert_eq!(hits.load(Ordering::SeqCst), 2);
    }
}
