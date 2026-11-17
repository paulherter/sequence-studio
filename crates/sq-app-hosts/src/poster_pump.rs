//! Poster frames for the panels that show media: the decodes run on the worker pool through a [`ThumbnailSource`], each
//! finished picture is packed into the shared thumbnail atlas (one renderer image slot, [`ATLAS_SLOT`]) and waits as an
//! [`ImageUpload`] for the window or the headless shot to copy into the slot.
//! A full atlas gives the cell of the least recently used poster to the newcomer (see [`PosterPump::touch`]); the
//! evicted ids are reported by [`PosterPump::take_evicted`] so the panel stops drawing them.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;
use std::sync::Arc;

use sq_app_shell::{ATLAS_SIZE, ATLAS_SLOT, ImageUpload};
use sq_core_model::MediaRef;
use sq_core_project::work_limits::MachineResources;
use sq_core_time::{Id, Time};
use sq_draw::RgbaImage;
use sq_editor_session::{ProjectThumbnails, Thumbnail, ThumbnailJob, ThumbnailSource};
use sq_runtime::{Inbox, WorkerPool};
use sq_uikit::controls_grid::CGSize;

/// Free space of the atlas, handed out in rows (shelves) from the top.
#[derive(Debug, Default)]
pub struct ThumbAtlas {
    x: usize,
    y: usize,
    shelf: usize,
    /// Cells given back by [`ThumbAtlas::release`]: reused before new shelf space is cut.
    free: Vec<Placed>,
}

/// The atlas two panels pack their pictures into.
pub type SharedAtlas = Rc<RefCell<ThumbAtlas>>;

impl ThumbAtlas {
    /// Reserves a `w` x `h` cell (one pixel apart from its neighbors); `None` when the atlas is full.
    pub fn place(&mut self, w: usize, h: usize) -> Option<(usize, usize)> {
        self.acquire(w, h).map(|c| (c.x, c.y))
    }

    /// Gives a cell back (a panel stopped showing its picture); the next [`ThumbAtlas::acquire`] may reuse it.
    pub fn release(&mut self, cell: Placed) {
        if !self.free.contains(&cell) {
            self.free.push(cell);
        }
    }

    /// Like [`ThumbAtlas::place`], but the answer is the whole cell: a released one that is larger than asked keeps its
    /// size, so giving it back later loses no area. Shortcut: cells are never split or merged; upgrade when the
    /// atlas fragments (several sizes in play for long sessions).
    pub fn acquire(&mut self, w: usize, h: usize) -> Option<Placed> {
        let best = self
            .free
            .iter()
            .enumerate()
            .filter(|(_, c)| c.w >= w && c.h >= h)
            .min_by_key(|(_, c)| c.w * c.h)
            .map(|(i, _)| i);
        if let Some(i) = best {
            return Some(self.free.swap_remove(i));
        }
        if w == 0 || h == 0 || w > ATLAS_SIZE {
            return None;
        }
        if self.x + w > ATLAS_SIZE {
            self.y += self.shelf + 1;
            (self.x, self.shelf) = (0, 0);
        }
        if self.y + h > ATLAS_SIZE {
            return None;
        }
        let at = (self.x, self.y);
        self.x += w + 1;
        self.shelf = self.shelf.max(h);
        Some(Placed { x: at.0, y: at.1, w, h })
    }
}

/// A picture in the atlas.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Placed {
    /// Left edge in atlas pixels.
    pub x: usize,
    /// Top edge in atlas pixels.
    pub y: usize,
    /// Width in pixels.
    pub w: usize,
    /// Height in pixels.
    pub h: usize,
}

impl Placed {
    /// The part `[u0, v0, u1, v1]` of the atlas slot.
    pub fn uv(&self) -> [f32; 4] {
        let s = ATLAS_SIZE as f32;
        [self.x as f32 / s, self.y as f32 / s, (self.x + self.w) as f32 / s, (self.y + self.h) as f32 / s]
    }

    /// The picture's size in pixels.
    pub fn size(&self) -> CGSize {
        CGSize::new(self.w as f64, self.h as f64)
    }
}

/// What a cell of the atlas holds: a media item's poster, or its frame at a media time (a cut's first frame).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Key {
    Poster(Id),
    Frame(Id, Time),
}

impl Drop for PosterPump {
    fn drop(&mut self) {
        let mut atlas = self.atlas.borrow_mut();
        for (_, cell) in std::mem::take(&mut self.reserved) {
            atlas.release(cell);
        }
    }
}

/// Requests poster frames, runs them on the pool and packs the results.
pub struct PosterPump {
    thumbs: ProjectThumbnails,
    source: Arc<dyn ThumbnailSource>,
    pool: Arc<WorkerPool>,
    done: Inbox<(ThumbnailJob, Vec<Option<Thumbnail>>)>,
    atlas: SharedAtlas,
    reserved: BTreeMap<Key, Placed>,
    placed: BTreeMap<Key, Placed>,
    /// Use stamp per placed picture; the smallest is evicted first.
    used: BTreeMap<Key, u64>,
    /// The frames the panel asked for in the last pump.
    wanted_frames: Vec<(Id, Time)>,
    /// The media the panel asked for in the last pump: their cells are never given away (two posters on screen would
    /// push each other out), and a stale one that loses its cell is decoded again when it is wanted again.
    wanted: std::collections::BTreeSet<Id>,
    stamp: u64,
    evicted: Vec<Id>,
    uploads: Vec<ImageUpload>,
}

impl PosterPump {
    /// Memory pressure: the poster and clip frame caps drop (`ProjectThumbnails::apply_memory_pressure`).
    pub fn apply_memory_pressure(&mut self, level: sq_uikit::waveform_drawing::MemoryPressure) {
        self.thumbs.apply_memory_pressure(level);
    }

    /// A pump that decodes with `source` on `pool` and packs into `atlas`.
    pub fn new(source: Arc<dyn ThumbnailSource>, pool: Arc<WorkerPool>, atlas: SharedAtlas) -> PosterPump {
        PosterPump {
            thumbs: ProjectThumbnails::new(&MachineResources::new(16 << 30, 8, false).limits()),
            source,
            pool,
            done: Inbox::new(|| {}),
            atlas,
            reserved: BTreeMap::new(),
            placed: BTreeMap::new(),
            used: BTreeMap::new(),
            wanted_frames: Vec::new(),
            wanted: std::collections::BTreeSet::new(),
            stamp: 0,
            evicted: Vec::new(),
            uploads: Vec::new(),
        }
    }

    /// Runs `wake` on the finishing thread after every decode, so the window redraws without waiting for input
    /// (call right after construction: pictures in flight are lost).
    pub fn set_wake(&mut self, wake: Arc<dyn Fn() + Send + Sync>) {
        self.done = Inbox::new(move || wake());
    }

    /// Marks the posters of `ids` as in use, so they are the last to be evicted.
    pub fn touch(&mut self, ids: impl IntoIterator<Item = Id>) {
        for id in ids {
            let key = Key::Poster(id);
            if self.placed.contains_key(&key) {
                self.stamp += 1;
                self.used.insert(key, self.stamp);
            }
        }
    }

    /// The ids whose cell went to another poster since the last call.
    pub fn take_evicted(&mut self) -> Vec<Id> {
        std::mem::take(&mut self.evicted)
    }

    /// A cell for a `w` x `h` poster: free space first, else the cell of the least recently used poster that fits.
    fn cell_for(&mut self, w: usize, h: usize) -> Option<Placed> {
        if let Some(cell) = self.atlas.borrow_mut().acquire(w, h) {
            return Some(cell);
        }
        let victim = self
            .reserved
            .iter()
            .filter(|(k, r)| r.w >= w && r.h >= h && !self.is_wanted(**k))
            .min_by_key(|(id, _)| self.used.get(id).copied().unwrap_or(0))
            .map(|(id, _)| *id)?;
        self.placed.remove(&victim);
        self.used.remove(&victim);
        if let Key::Poster(id) = victim {
            self.evicted.push(id);
            // The cache must not keep a picture nobody can show: the next request decodes it again.
            self.thumbs.drop_picture(id);
        }
        self.reserved.remove(&victim)
    }

    /// Whether the last pump asked for the picture of `key`: such a cell is never given away.
    fn is_wanted(&self, key: Key) -> bool {
        match key {
            Key::Poster(id) => self.wanted.contains(&id),
            Key::Frame(id, at) => self.wanted_frames.contains(&(id, at)),
        }
    }

    /// Gives every cell back to the atlas (the panel is not shown): what is wanted again is packed again from the
    /// cache by the next pump, without a new decode.
    pub fn release_all(&mut self) {
        let mut atlas = self.atlas.borrow_mut();
        for (_, cell) in std::mem::take(&mut self.reserved) {
            atlas.release(cell);
        }
        drop(atlas);
        self.evicted.extend(self.placed.keys().filter_map(|k| if let Key::Poster(id) = k { Some(*id) } else { None }));
        self.placed.clear();
        self.used.clear();
        self.uploads.clear();
    }

    /// Packs into `atlas` from now on (a fresh pump only: pictures placed earlier stay in the old one).
    pub fn set_atlas(&mut self, atlas: SharedAtlas) {
        self.atlas = atlas;
    }

    /// Requests the posters of `media` (`height` pixels tall), starts the decodes that may run and takes in what
    /// finished; returns the ids that got a new picture.
    pub fn pump<'a>(&mut self, media: impl IntoIterator<Item = &'a MediaRef>, height: i64) -> Vec<Id> {
        self.pump_frames(media.into_iter().map(|m| (m, None)), height)
    }

    /// [`PosterPump::pump`] where each item may also ask for the frame at a media time (the Color page's Sources tiles
    /// show the frame their first cut is about); the posters come along and stand in until the frame arrived.
    pub fn pump_frames<'a>(
        &mut self,
        items: impl IntoIterator<Item = (&'a MediaRef, Option<Time>)>,
        height: i64,
    ) -> Vec<Id> {
        self.wanted_frames.clear();
        self.wanted.clear();
        for (m, at) in items {
            self.wanted.insert(m.id);
            self.thumbs.request_poster_and_frame(m, at, height);
            if let Some(at) = at {
                self.wanted_frames.push((m.id, at));
            }
        }
        for (job, images) in self.done.drain() {
            self.thumbs.finish(&job, images);
        }
        for job in self.thumbs.take_jobs() {
            let (source, tx) = (Arc::clone(&self.source), self.done.sender());
            self.pool.execute(move || {
                let images = source.run(&job);
                tx.send((job, images));
            });
        }
        // The frames first: a tile whose frame is in the cache needs no cell for its poster (the start screen's twelve
        // cards would not fit the atlas twice).
        for (id, at) in self.wanted_frames.clone() {
            let key = Key::Frame(id, at);
            if self.placed.contains_key(&key) {
                continue;
            }
            if let Some(thumbnail) = self.thumbs.cached_frame(id, at, height).cloned() {
                self.place(key, &thumbnail);
            }
        }
        let framed = |pump: &PosterPump, id: Id| {
            pump.wanted_frames.iter().any(|(m, at)| *m == id && pump.thumbs.cached_frame(id, *at, height).is_some())
        };
        let mut arrived = Vec::new();
        for id in self.thumbs.take_arrived() {
            let Some(thumbnail) = self.thumbs.cached_poster(id).cloned() else { continue };
            if !framed(self, id) {
                self.place(Key::Poster(id), &thumbnail);
            }
            arrived.push(id);
        }
        // A poster that arrived while the atlas had no room is placed as soon as a stale cell is free.
        let unplaced: Vec<Id> = self
            .wanted
            .iter()
            .copied()
            .filter(|id| !self.placed.contains_key(&Key::Poster(*id)) && !framed(self, *id))
            .collect();
        for id in unplaced {
            if let Some(thumbnail) = self.thumbs.cached_poster(id).cloned() {
                self.place(Key::Poster(id), &thumbnail);
            }
        }
        arrived
    }

    /// Puts `thumbnail` into the cell reserved for `key` (a new one when it does not fit) and queues its upload.
    fn place(&mut self, key: Key, thumbnail: &Thumbnail) {
        let (w, h) = (thumbnail.width, thumbnail.height);
        let fits = self.reserved.get(&key).filter(|r| r.w >= w && r.h >= h).copied();
        let Some(cell) = fits.or_else(|| {
            let cell = self.cell_for(w, h)?;
            // A cell that was too small for the new picture goes back to the atlas.
            if let Some(old) = self.reserved.insert(key, cell) {
                self.atlas.borrow_mut().release(old);
            }
            Some(cell)
        }) else {
            return;
        };
        let placed = Placed { w, h, ..cell };
        self.placed.insert(key, placed);
        self.stamp += 1;
        self.used.insert(key, self.stamp);
        let image = RgbaImage { width: w, height: h, pixels: thumbnail.rgba.to_vec() };
        self.uploads.push(ImageUpload { slot: ATLAS_SLOT, at: Some((placed.x, placed.y)), image });
    }

    /// Where the frame of `id` at media time `at` sits, once it arrived; the poster's place until then (`None` when
    /// neither is in the atlas).
    pub fn placed_frame(&self, id: Id, at: Option<Time>) -> Option<Placed> {
        at.and_then(|at| self.placed.get(&Key::Frame(id, at)).copied()).or_else(|| self.placed(id))
    }

    /// Where the poster of `id` sits in the atlas, once it arrived.
    pub fn placed(&self, id: Id) -> Option<Placed> {
        self.placed.get(&Key::Poster(id)).copied()
    }

    /// The pictures to copy into the atlas slot since the last call.
    pub fn take_uploads(&mut self) -> Vec<ImageUpload> {
        std::mem::take(&mut self.uploads)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cells_fill_a_shelf_then_start_the_next_one() {
        let mut atlas = ThumbAtlas::default();
        assert_eq!(atlas.place(1000, 100), Some((0, 0)));
        assert_eq!(atlas.place(1000, 50), Some((1001, 0)));
        assert_eq!(atlas.place(100, 50), Some((0, 101)), "the next row starts below the tallest cell");
        assert_eq!(atlas.place(ATLAS_SIZE + 1, 1), None);
        assert_eq!(atlas.place(10, ATLAS_SIZE), None, "a full atlas leaves the poster out");
    }

    struct NoSource;

    impl ThumbnailSource for NoSource {
        fn run(&self, _: &ThumbnailJob) -> Vec<Option<Thumbnail>> {
            Vec::new()
        }
    }

    #[test]
    fn a_full_atlas_evicts_the_least_recently_used_poster() {
        let atlas = SharedAtlas::default();
        assert!(atlas.borrow_mut().place(ATLAS_SIZE, ATLAS_SIZE - 1).is_some(), "fill the atlas");
        let mut pump = PosterPump::new(Arc::new(NoSource), Arc::new(WorkerPool::manual()), atlas);
        let (a, b) = (Id::from_u128(1), Id::from_u128(2));
        for (id, x) in [(Key::Poster(a), 0), (Key::Poster(b), 11)] {
            let cell = Placed { x, y: 0, w: 10, h: 10 };
            pump.reserved.insert(id, cell);
            pump.placed.insert(id, cell);
            pump.stamp += 1;
            pump.used.insert(id, pump.stamp);
        }
        pump.touch([a]);
        assert_eq!(pump.cell_for(11, 10), None, "a poster larger than every cell is left out");
        assert_eq!(pump.cell_for(8, 8), Some(Placed { x: 11, y: 0, w: 10, h: 10 }), "b was used least");
        assert_eq!(pump.take_evicted(), vec![b]);
        assert_eq!(pump.placed(b), None);
        assert!(pump.placed(a).is_some(), "the touched poster stays");
    }

    /// An evicted poster is decoded again when it is wanted again (it used to stay cached and never come back), and a
    /// poster that is wanted now never loses its cell to another wanted one.
    #[test]
    fn an_evicted_poster_comes_back_and_wanted_ones_keep_their_cells() {
        let atlas = SharedAtlas::default();
        // Room for exactly two 4 x 2 cells.
        atlas.borrow_mut().place(ATLAS_SIZE, ATLAS_SIZE - 3).expect("fill");
        atlas.borrow_mut().place(ATLAS_SIZE - 10, 2).expect("fill the row");
        let pool = Arc::new(WorkerPool::manual());
        let mut pump = PosterPump::new(Arc::new(Shades), Arc::clone(&pool), atlas);
        let m = |n: u128| {
            MediaRef::new(Id::from_u128(n), "c", &format!("/x/{n}.mov"), sq_core_model::MediaFingerprint::new(1))
        };
        let (a, b, c) = (m(1), m(2), m(3));
        let run = |pump: &mut PosterPump, list: &[&MediaRef]| {
            pump.pump(list.iter().copied(), 2);
            while pool.step() {}
            pump.pump(list.iter().copied(), 2);
        };
        run(&mut pump, &[&a, &b]);
        assert!(pump.placed(a.id).is_some() && pump.placed(b.id).is_some());
        run(&mut pump, &[&a, &b, &c]);
        assert!(pump.placed(a.id).is_some() && pump.placed(b.id).is_some(), "wanted posters keep their cells");
        assert!(pump.placed(c.id).is_none(), "the third has no room while all three are wanted");
        run(&mut pump, &[&c]);
        assert!(pump.placed(c.id).is_some(), "stale posters give way");
        let gone = if pump.placed(a.id).is_none() { a.id } else { b.id };
        assert_eq!(pump.take_evicted(), vec![gone]);
        let gone_ref = if gone == a.id { &a } else { &b };
        pump.pump([gone_ref], 2);
        assert_eq!(pool.pending(), 1, "the evicted poster is decoded again");
    }

    /// A source that paints every picture one gray level: the poster 10, the frame at second `n` 100 + n.
    struct Shades;

    impl ThumbnailSource for Shades {
        fn run(&self, job: &ThumbnailJob) -> Vec<Option<Thumbnail>> {
            let shot = |level: u8| Some(Thumbnail { width: 4, height: 2, rgba: Arc::new(vec![level; 4 * 2 * 4]) });
            match job {
                ThumbnailJob::PosterAndFrame { frame_at, .. } => vec![shot(10), shot(100 + frame_at.value() as u8)],
                ThumbnailJob::Poster { .. } => vec![shot(10)],
                ThumbnailJob::Frame { at, .. } => vec![shot(100 + at.value() as u8)],
                ThumbnailJob::Scrub { .. } => Vec::new(),
            }
        }
    }

    #[test]
    fn a_tile_shows_the_frame_of_its_cut_and_the_poster_until_it_arrives() {
        let pool = Arc::new(WorkerPool::manual());
        let mut pump = PosterPump::new(Arc::new(Shades), Arc::clone(&pool), SharedAtlas::default());
        let media = MediaRef::new(Id::from_u128(7), "clip", "/x/clip.mov", sq_core_model::MediaFingerprint::new(1));
        let at = Time::new(5, 1);
        assert!(pump.pump_frames([(&media, Some(at))], 2).is_empty());
        assert_eq!(pump.placed_frame(media.id, Some(at)), None, "nothing decoded yet");
        while pool.step() {}
        pump.pump_frames([(&media, Some(at))], 2);
        let frame = pump.placed_frame(media.id, Some(at)).expect("the frame");
        assert_eq!(pump.placed(media.id), None, "the poster takes no cell of its own once the frame is there");
        let shades: Vec<u8> = pump.take_uploads().iter().map(|u| u.image.pixels[0]).collect();
        assert_eq!(shades, [105], "only the frame was uploaded: {shades:?}");
        assert_eq!(frame.size(), CGSize::new(4.0, 2.0));
    }

    #[test]
    fn a_placed_picture_names_its_part_of_the_slot() {
        let p = Placed { x: ATLAS_SIZE / 2, y: 0, w: ATLAS_SIZE / 4, h: ATLAS_SIZE / 2 };
        assert_eq!(p.uv(), [0.5, 0.0, 0.75, 0.5]);
    }

    #[test]
    fn a_released_cell_is_reused_and_a_dropped_pump_frees_its_cells() {
        let atlas = SharedAtlas::default();
        let a = atlas.borrow_mut().acquire(100, 50).expect("a");
        atlas.borrow_mut().release(a);
        assert_eq!(atlas.borrow_mut().acquire(90, 40), Some(a), "a smaller picture takes the released cell whole");
        let pool = Arc::new(WorkerPool::manual());
        let m = MediaRef::new(Id::from_u128(5), "c", "/x/5.mov", sq_core_model::MediaFingerprint::new(1));
        let mut pump = PosterPump::new(Arc::new(Shades), Arc::clone(&pool), SharedAtlas::clone(&atlas));
        pump.pump([&m], 2);
        while pool.step() {}
        pump.pump([&m], 2);
        let cell = pump.placed(m.id).expect("placed");
        drop(pump);
        let again = atlas.borrow_mut().acquire(4, 2).expect("room");
        assert_eq!((again.x, again.y), (cell.x, cell.y), "the dropped pump's cell is free again");
    }
}
