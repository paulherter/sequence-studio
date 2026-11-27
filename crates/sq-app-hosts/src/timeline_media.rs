//! What the timeline draws on its clips besides their frames: the poster tile of video clips, the waveform of audio
//! and the offline state. Decodes run on worker pools; the host redraws through `wake` when one finishes.
//! The posters share the thumbnail atlas ([`SharedAtlas`]); their uploads leave through [`TimelineMedia::take_uploads`].

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::rc::Rc;
use std::sync::Arc;

use sq_app_shell::{ATLAS_SLOT, ImageUpload};
use sq_core_model::{AudioChannelMap, MediaRef};
use sq_core_time::{Id, Time};
use sq_draw_timeline::{TimelineMediaSource, TimelinePicture};
use sq_editor_session::{Thumbnail, ThumbnailJob, ThumbnailSource};
use sq_media::peak_pyramid::PeakPyramid;
use sq_media::waveform_data::WaveformData;
use sq_media_ffmpeg::decode::FFmpegAudioSource;
use sq_runtime::{Inbox, WorkerPool};

use crate::poster_pump::{Placed, PosterPump, SharedAtlas};
use crate::project_services::FfmpegPosters;

/// Poster height in pixels: the atlas cell height the Swift timeline uses.
const POSTER_HEIGHT: i64 = 90;
/// Poster decodes in parallel: a big camera file takes about a second, and every clip of the sequence waits for its tile.
const POSTER_THREADS: usize = 3;
/// Frame decodes of clip tiles running at once.
const FRAME_JOBS: usize = 2;
/// Clip-tile frames kept in the atlas; when more are drawn the cell of the least recently drawn one is reused.
const MAX_FRAME_TILES: usize = 120;
/// Tile times are rounded to this many per second: neighbors within a quarter second share a picture.
const TILE_STEP: Time = Time::new(1, 4);
/// The mixer rate the waveform is decoded at.
const WAVEFORM_RATE: i32 = 48_000;
/// Frames read per chunk while building peaks.
const CHUNK: usize = 1 << 16;

/// Builds the peaks of the file at a path (blocking, runs on a worker).
type MakeWaveform = Arc<dyn Fn(&str, Option<&AudioChannelMap>) -> Option<WaveformData> + Send + Sync>;

fn ffmpeg_waveform(path: &str, map: Option<&AudioChannelMap>) -> Option<WaveformData> {
    let cache = disk_cache();
    let base = WaveformData::DEFAULT_BASE_BUCKET_SIZE;
    // The map is part of the key: what a clip plays is its own entry, the file's own mix the plain one.
    let channels = map.map(|m| (m.left(), m.right()));
    if let Some(hit) = cache.as_ref().and_then(|c| c.load_mapped(Path::new(path), base, channels)) {
        return Some(hit);
    }
    let source = FFmpegAudioSource::open_mapped(Path::new(path), WAVEFORM_RATE, map).ok()?;
    let rate = usize::try_from(WAVEFORM_RATE).ok()?;
    let built = PeakPyramid::waveform_from(&*source, rate, base, CHUNK, || false).ok().flatten()?;
    if let Some(c) = &cache {
        c.store_mapped(&built, Path::new(path), base, channels);
    }
    Some(built)
}

/// The waveform disk cache in the app's cache folder (`<caches>/Sequence Studio/Waveforms`, Swift parity).
fn disk_cache() -> Option<sq_media::waveform_disk_cache::WaveformDiskCache> {
    sq_media::waveform_disk_cache::WaveformDiskCache::shared_at(
        sq_editor_session::AppSettings::default_cache_folder().join("Waveforms"),
    )
}

/// The timeline's [`TimelineMediaSource`]: `pump` each frame, then the panel reads through the trait.
pub struct TimelineMedia {
    posters: RefCell<PosterPump>,
    make_waveform: MakeWaveform,
    pool: Arc<WorkerPool>,
    done: RefCell<Inbox<(Id, Option<WaveformData>)>>,
    waveforms: RefCell<BTreeMap<Id, Arc<WaveformData>>>,
    /// Media whose waveform was asked for (once each, also when it fails).
    asked: RefCell<BTreeSet<Id>>,
    /// The channel map each media's waveform was last asked for with.
    asked_maps: RefCell<BTreeMap<Id, Option<AudioChannelMap>>>,
    offline: RefCell<BTreeSet<Id>>,
    seen: RefCell<BTreeSet<Id>>,
    /// The file each media item was last pumped with: a relink (same id, other path) drops what was made from the old one.
    paths: RefCell<BTreeMap<Id, String>>,
    revision: Cell<u64>,
    frames: RefCell<FrameTiles>,
}

/// The decoded frames of clip tiles: asked for while drawing, started and packed on the next `pump`.
struct FrameTiles {
    source: Arc<dyn ThumbnailSource>,
    pool: Arc<WorkerPool>,
    atlas: SharedAtlas,
    done: Inbox<((Id, Time), Option<Thumbnail>)>,
    paths: BTreeMap<Id, (String, Option<sq_core_model::PixelAspect>)>,
    placed: BTreeMap<(Id, Time), Placed>,
    /// Draw stamp per placed tile (higher = drawn more recently); the smallest is evicted first.
    used: BTreeMap<(Id, Time), u64>,
    stamp: u64,
    /// Tile frames kept at once.
    max_tiles: usize,
    wanted: BTreeSet<(Id, Time)>,
    asked: BTreeSet<(Id, Time)>,
    running: usize,
    uploads: Vec<ImageUpload>,
}

impl TimelineMedia {
    /// Decodes with FFmpeg and packs posters into `atlas`.
    pub fn new(atlas: SharedAtlas) -> TimelineMedia {
        TimelineMedia::with_sources(
            Arc::new(FfmpegPosters),
            Arc::new(ffmpeg_waveform),
            Arc::new(crate::project_services::poster_pool(POSTER_THREADS)),
            Arc::new(WorkerPool::threads(1)),
            atlas,
        )
        .with_frame_pool(Arc::new(crate::project_services::poster_pool(FRAME_JOBS)))
    }

    fn with_frame_pool(self, pool: Arc<WorkerPool>) -> TimelineMedia {
        self.frames.borrow_mut().pool = pool;
        self
    }

    fn with_sources(
        thumbs: Arc<dyn ThumbnailSource>,
        make_waveform: MakeWaveform,
        poster_pool: Arc<WorkerPool>,
        pool: Arc<WorkerPool>,
        atlas: SharedAtlas,
    ) -> TimelineMedia {
        let frames = FrameTiles {
            source: Arc::clone(&thumbs),
            pool: Arc::clone(&poster_pool),
            atlas: Rc::clone(&atlas),
            done: Inbox::new(|| {}),
            paths: BTreeMap::new(),
            placed: BTreeMap::new(),
            wanted: BTreeSet::new(),
            asked: BTreeSet::new(),
            used: BTreeMap::new(),
            stamp: 0,
            max_tiles: MAX_FRAME_TILES,
            running: 0,
            uploads: Vec::new(),
        };
        TimelineMedia {
            frames: RefCell::new(frames),
            posters: RefCell::new(PosterPump::new(thumbs, poster_pool, atlas)),
            make_waveform,
            pool,
            done: RefCell::new(Inbox::new(|| {})),
            waveforms: RefCell::default(),
            asked: RefCell::default(),
            asked_maps: RefCell::default(),
            offline: RefCell::default(),
            seen: RefCell::default(),
            paths: RefCell::default(),
            revision: Cell::new(0),
        }
    }

    /// Runs `wake` on the finishing thread after every decode (call right after construction: results in flight are lost).
    pub fn set_wake(&self, wake: Arc<dyn Fn() + Send + Sync>) {
        self.posters.borrow_mut().set_wake(Arc::clone(&wake));
        self.frames.borrow_mut().done = Inbox::new({
            let wake = Arc::clone(&wake);
            move || wake()
        });
        *self.done.borrow_mut() = Inbox::new(move || wake());
    }

    /// Asks for what the project's media needs and takes in what finished.
    /// Memory pressure from the shared registry: the poster caches shrink.
    pub fn apply_memory_pressure(&self, level: sq_uikit::waveform_drawing::MemoryPressure) {
        self.posters.borrow_mut().apply_memory_pressure(level);
    }

    pub fn pump<'a>(&self, media: impl IntoIterator<Item = &'a MediaRef> + Clone) {
        let mut changed = false;
        for m in media.clone() {
            if self.paths.borrow_mut().insert(m.id, m.path.clone()).is_some_and(|old| old != m.path) {
                self.forget(m.id);
                changed = true;
            }
            if self.seen.borrow_mut().insert(m.id) && !Path::new(&m.path).exists() {
                self.offline.borrow_mut().insert(m.id);
                changed = true;
            }
            // Unprobed media is tried too: a file without sound fails fast.
            let has_audio = m.info.as_ref().is_none_or(|i| i.audio.is_some());
            // Asked once per media and channel map: choosing other Audio Channels draws the new waveform.
            let map = m.info.as_ref().and_then(|i| i.audio.as_ref()).and_then(|a| a.channel_map.clone());
            let new = self.asked_maps.borrow().get(&m.id) != Some(&map);
            if has_audio && !self.offline.borrow().contains(&m.id) && new {
                self.asked_maps.borrow_mut().insert(m.id, map.clone());
                self.asked.borrow_mut().insert(m.id);
                let (id, path, make, tx) =
                    (m.id, m.path.clone(), Arc::clone(&self.make_waveform), self.done.borrow().sender());
                self.pool.execute(move || tx.send((id, make(&path, map.as_ref()))));
            }
        }
        changed |= self.frames.borrow_mut().pump(media.clone());
        let offline = self.offline.borrow();
        let wanted = media.into_iter().filter(|m| !offline.contains(&m.id));
        let mut posters = self.posters.borrow_mut();
        changed |= !posters.pump(wanted, POSTER_HEIGHT).is_empty();
        changed |= !posters.take_evicted().is_empty();
        for (id, data) in self.done.borrow_mut().drain() {
            if let Some(data) = data {
                let data = Arc::new(data);
                // The live duck and the export mix read the same waveform for the dialogue pauses.
                crate::export_audio::app_silences().set_waveform(Some(Arc::clone(&data)), id);
                self.waveforms.borrow_mut().insert(id, data);
                changed = true;
            }
        }
        if changed {
            self.revision.set(self.revision.get() + 1);
        }
    }

    /// The files of `ids` came back or went away: their offline mark, waveform and frames are judged again by the next
    /// pump (the mark is otherwise set once per path).
    pub fn files_changed(&self, ids: &std::collections::BTreeSet<Id>) {
        for id in ids {
            self.forget(*id);
        }
        if !ids.is_empty() {
            self.revision.set(self.revision.get() + 1);
        }
    }

    /// Drops the waveform, the offline mark and the clip frames made from the old file of `id`; the next pump asks again.
    fn forget(&self, id: Id) {
        self.seen.borrow_mut().remove(&id);
        self.offline.borrow_mut().remove(&id);
        self.asked.borrow_mut().remove(&id);
        self.asked_maps.borrow_mut().remove(&id);
        self.waveforms.borrow_mut().remove(&id);
        self.frames.borrow_mut().forget(id);
    }

    /// The poster pictures to copy into the atlas slot since the last call.
    pub fn take_uploads(&self) -> Vec<ImageUpload> {
        let mut uploads = self.posters.borrow_mut().take_uploads();
        uploads.extend(std::mem::take(&mut self.frames.borrow_mut().uploads));
        uploads
    }
}

impl TimelineMediaSource for TimelineMedia {
    fn waveform(&self, media: Id) -> Option<Arc<WaveformData>> {
        self.waveforms.borrow().get(&media).map(Arc::clone)
    }

    /// A tile with a time shows the frame of that time (rounded to [`TILE_STEP`]) once it is decoded, the poster until
    /// then; `None` is the poster itself.
    fn picture(&self, media: Id, at: Option<Time>) -> Option<TimelinePicture> {
        let tile = at.and_then(|at| self.frames.borrow_mut().tile(media, at));
        let placed = tile.or_else(|| self.posters.borrow().placed(media))?;
        Some(TimelinePicture {
            slot: ATLAS_SLOT,
            source: placed.uv(),
            pixel_width: placed.w as f64,
            pixel_height: placed.h as f64,
        })
    }

    fn is_offline(&self, media: Id) -> bool {
        self.offline.borrow().contains(&media)
    }

    fn draw_revision(&self) -> Option<u64> {
        Some(self.revision.get())
    }
}

impl FrameTiles {
    /// The cell of the frame at `at` of `media`; asks for it when it is not there yet.
    fn tile(&mut self, media: Id, at: Time) -> Option<Placed> {
        let key = (media, at.snapped(TILE_STEP));
        if let Some(p) = self.placed.get(&key) {
            self.stamp += 1;
            self.used.insert(key, self.stamp);
            return Some(*p);
        }
        if !self.asked.contains(&key) {
            self.wanted.insert(key);
        }
        None
    }

    /// A cell for a `w` x `h` frame: free atlas space while fewer than `max_tiles` are placed, else the cell of the
    /// least recently drawn tile that fits (that tile shows the poster again and may be asked for again).
    fn cell_for(&mut self, w: usize, h: usize) -> Option<(usize, usize)> {
        if self.placed.len() < self.max_tiles
            && let Some(at) = self.atlas.borrow_mut().place(w, h)
        {
            return Some(at);
        }
        let victim = self
            .placed
            .iter()
            .filter(|(_, p)| p.w >= w && p.h >= h)
            .min_by_key(|(k, _)| self.used.get(k).copied().unwrap_or(0))
            .map(|(k, _)| *k)?;
        let cell = self.placed.remove(&victim)?;
        self.used.remove(&victim);
        self.asked.remove(&victim);
        Some((cell.x, cell.y))
    }

    /// Forgets the tiles of `id` (its file changed): they are asked for again by the next draw.
    fn forget(&mut self, id: Id) {
        self.placed.retain(|k, _| k.0 != id);
        self.used.retain(|k, _| k.0 != id);
        self.asked.retain(|k| k.0 != id);
        self.wanted.retain(|k| k.0 != id);
    }

    /// Starts the decodes asked for while drawing and packs what finished; true when a frame arrived.
    fn pump<'a>(&mut self, media: impl IntoIterator<Item = &'a MediaRef>) -> bool {
        for m in media {
            let aspect = m.info.as_ref().and_then(|i| i.video.as_ref()).map(|v| v.display_pixel_aspect());
            // Every frame: only a changed path or aspect (the probe arrived) allocates.
            match self.paths.get_mut(&m.id) {
                Some((path, a)) if *path == m.path => *a = aspect,
                _ => {
                    self.paths.insert(m.id, (m.path.clone(), aspect));
                }
            }
        }
        let mut arrived = false;
        for (key, image) in self.done.drain() {
            self.running = self.running.saturating_sub(1);
            let Some(image) = image else { continue };
            let Some((x, y)) = self.cell_for(image.width, image.height) else { continue };
            let placed = Placed { x, y, w: image.width, h: image.height };
            self.stamp += 1;
            self.used.insert(key, self.stamp);
            let pixels = image.rgba.to_vec();
            let image = sq_draw::RgbaImage { width: placed.w, height: placed.h, pixels };
            self.uploads.push(ImageUpload { slot: ATLAS_SLOT, at: Some((x, y)), image });
            self.placed.insert(key, placed);
            arrived = true;
        }
        // Tiles that were not started now are asked for again by the next draw.
        for key in std::mem::take(&mut self.wanted) {
            if self.running >= FRAME_JOBS {
                break;
            }
            let Some((path, aspect)) = self.paths.get(&key.0).cloned() else { continue };
            self.asked.insert(key);
            self.running += 1;
            let (source, tx) = (Arc::clone(&self.source), self.done.sender());
            let job = ThumbnailJob::Frame {
                media: key.0,
                path,
                at: key.1,
                key: format!("{}@{:?}", key.0.as_u128(), key.1),
                height: POSTER_HEIGHT,
                aspect,
            };
            self.pool.execute(move || {
                let image = source.run(&job).into_iter().next().flatten();
                tx.send((key, image));
            });
        }
        arrived
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::MediaFingerprint;

    struct NoThumbs;
    impl ThumbnailSource for NoThumbs {
        fn run(&self, _: &sq_editor_session::ThumbnailJob) -> Vec<Option<sq_editor_session::Thumbnail>> {
            Vec::new()
        }
    }

    fn media(id: u128, path: &str) -> MediaRef {
        MediaRef::new(Id::from_u128(id), "m", path, MediaFingerprint::new(1))
    }

    #[test]
    fn a_waveform_arrives_after_the_worker_ran_and_a_missing_file_is_offline() {
        let pool = Arc::new(WorkerPool::manual());
        let wave: MakeWaveform = Arc::new(|_, _| Some(WaveformData::new(48_000, 1, 10, 256, vec![vec![0.0, 1.0]])));
        let t = TimelineMedia::with_sources(
            Arc::new(NoThumbs),
            wave,
            Arc::new(WorkerPool::manual()),
            Arc::clone(&pool),
            SharedAtlas::default(),
        );
        let here = std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        let list = [media(1, &here), media(2, "/no/such/file.mov")];
        t.pump(list.iter());
        assert!(t.is_offline(Id::from_u128(2)) && !t.is_offline(Id::from_u128(1)));
        assert!(t.waveform(Id::from_u128(1)).is_none(), "still decoding");
        let before = t.draw_revision();
        while pool.step() {}
        t.pump(list.iter());
        assert!(t.waveform(Id::from_u128(1)).is_some());
        assert!(t.waveform(Id::from_u128(2)).is_none(), "an offline file is not decoded");
        assert_ne!(t.draw_revision(), before, "the clip layer replays");
    }

    #[test]
    fn a_relinked_file_is_no_longer_offline_and_gets_its_waveform() {
        let pool = Arc::new(WorkerPool::manual());
        let wave: MakeWaveform = Arc::new(|_, _| Some(WaveformData::new(48_000, 1, 10, 256, vec![vec![0.0, 1.0]])));
        let t = TimelineMedia::with_sources(
            Arc::new(NoThumbs),
            wave,
            Arc::new(WorkerPool::manual()),
            Arc::clone(&pool),
            SharedAtlas::default(),
        );
        let here = std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        let id = Id::from_u128(2);
        t.pump([media(2, "/no/such/file.mov")].iter());
        assert!(t.is_offline(id));
        let before = t.draw_revision();
        t.pump([media(2, &here)].iter());
        assert!(!t.is_offline(id), "the new file exists");
        assert_ne!(t.draw_revision(), before);
        while pool.step() {}
        t.pump([media(2, &here)].iter());
        assert!(t.waveform(id).is_some());
    }

    struct Tagged;
    impl ThumbnailSource for Tagged {
        fn run(&self, job: &ThumbnailJob) -> Vec<Option<Thumbnail>> {
            // The picture's red value tells which time it was made for (0 = poster).
            let red = match job {
                ThumbnailJob::Frame { at, .. } => (at.value() / at.timescale()) as u8 + 1,
                _ => 0,
            };
            vec![Some(Thumbnail { width: 2, height: 2, rgba: Arc::new([red, 0, 0, 255].repeat(4)) })]
        }
    }

    #[test]
    fn a_tile_shows_the_frame_of_its_own_time_after_the_poster() {
        let (posters, frames) = (Arc::new(WorkerPool::manual()), Arc::new(WorkerPool::manual()));
        let t = TimelineMedia::with_sources(
            Arc::new(Tagged),
            Arc::new(|_, _| None),
            Arc::clone(&posters),
            Arc::new(WorkerPool::manual()),
            SharedAtlas::default(),
        )
        .with_frame_pool(Arc::clone(&frames));
        let here = std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        let list = [media(1, &here)];
        let id = Id::from_u128(1);
        t.pump(list.iter());
        while posters.step() {}
        t.pump(list.iter());
        let poster = t.picture(id, None).expect("poster");
        assert_eq!(t.picture(id, Some(Time::seconds(3))), Some(poster), "poster until the frame is there");
        t.pump(list.iter());
        while frames.step() {}
        t.pump(list.iter());
        let at3 = t.picture(id, Some(Time::seconds(3))).expect("frame");
        assert_ne!(at3.source, poster.source, "its own cell");
        let ups = t.take_uploads();
        let red = |u: &ImageUpload| u.image.pixels[0];
        assert!(ups.iter().any(|u| red(u) == 4), "the frame decoded for 3 s was uploaded");
        t.pump(list.iter());
        assert_ne!(t.picture(id, Some(Time::seconds(8))), Some(at3), "another time is another tile");
    }

    #[test]
    fn a_full_tile_budget_reuses_the_cell_of_the_least_recently_drawn_tile() {
        let (posters, frames) = (Arc::new(WorkerPool::manual()), Arc::new(WorkerPool::manual()));
        let t = TimelineMedia::with_sources(
            Arc::new(Tagged),
            Arc::new(|_, _| None),
            Arc::clone(&posters),
            Arc::new(WorkerPool::manual()),
            SharedAtlas::default(),
        )
        .with_frame_pool(Arc::clone(&frames));
        t.frames.borrow_mut().max_tiles = 2;
        let here = std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
        let list = [media(1, &here)];
        let id = Id::from_u128(1);
        t.pump(list.iter());
        while posters.step() {}
        t.pump(list.iter());
        let poster = t.picture(id, None).expect("poster");
        // Draws the tile at `s` seconds until its frame is there (draw, pump, decode, pump).
        let show = |s: i64| {
            let at = Some(Time::seconds(s));
            t.picture(id, at);
            t.pump(list.iter());
            while frames.step() {}
            t.pump(list.iter());
            t.picture(id, at).expect("picture")
        };
        let (a, b) = (show(3), show(8));
        assert!(a.source != poster.source && b.source != poster.source && a.source != b.source);
        t.picture(id, Some(Time::seconds(3))); // 3 s is drawn again: 8 s is now the least recently drawn
        let c = show(13);
        assert_eq!(c.source, b.source, "13 s took the cell of 8 s");
        assert_eq!(t.picture(id, Some(Time::seconds(3))), Some(a), "the drawn tile stays");
        assert_eq!(t.picture(id, Some(Time::seconds(8))), Some(poster), "the evicted tile shows the poster again");
        let again = show(8);
        assert_ne!(again.source, poster.source);
    }

    #[test]
    fn pumping_a_large_project_every_frame_stays_cheap() {
        let t = TimelineMedia::with_sources(
            Arc::new(NoThumbs),
            Arc::new(|_, _| None),
            Arc::new(WorkerPool::manual()),
            Arc::new(WorkerPool::manual()),
            SharedAtlas::default(),
        );
        let all: Vec<MediaRef> = (1..=1500).map(|i| media(i, &format!("/nonexistent/folder/clip-{i}.mov"))).collect();
        t.pump(all.iter()); // the first pump looks at every file once
        let start = std::time::Instant::now();
        for _ in 0..60 {
            t.pump(all.iter());
        }
        let per_frame = start.elapsed().as_secs_f64() * 1000.0 / 60.0;
        sq_os::errln!("perf host pump 1500 media: {per_frame:.3} ms per frame");
        assert!(per_frame < 16.0, "a steady-state pump must not take a frame");
    }
}
