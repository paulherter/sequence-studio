// Swift: ProjectThumbnails.swift
//! Thumbnails of Project items: poster frames, hover-scrub frames and clip frames, cached in memory. The scheduling is a
//! plain state machine: requests go in, [`ProjectThumbnails::take_jobs`] hands out the decodes that may start now (at
//! most `WorkLimits.poster_decodes` at once, items on screen first), the host runs each on a worker through its
//! [`ThumbnailSource`] and returns the pictures with [`ProjectThumbnails::finish`]. Swift's `done` closures become
//! [`ProjectThumbnails::take_arrived`] (the media whose picture settled) plus the `version`.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use sq_core_edit::import_scheduling::VisibleFirstQueue;
use sq_core_model::{MediaKind, MediaRef, PixelAspect};
use sq_core_project::work_limits::WorkLimits;
use sq_core_time::{Id, Time};
use sq_uikit::waveform_drawing::MemoryPressure;

/// A finished picture (Swift `NSImage`): RGBA8 rows, top down.
#[derive(Clone, Debug, PartialEq)]
pub struct Thumbnail {
    pub width: usize,
    pub height: usize,
    pub rgba: Arc<Vec<u8>>,
}

impl Thumbnail {
    /// Bytes the picture holds (its cache cost).
    pub fn cost(&self) -> usize {
        self.rgba.len()
    }
}

/// One decode the host runs off the UI thread. Hand the pictures back with [`ProjectThumbnails::finish`], in the order
/// of `ThumbnailJob::times`.
#[derive(Clone, Debug, PartialEq)]
pub enum ThumbnailJob {
    /// The poster of a video or still image (a still is decoded as stored, square, then drawn in `aspect`).
    Poster { media: Id, path: String, is_still: bool, at: Time, height: i64, aspect: Option<PixelAspect> },
    /// The poster and one clip frame in one decoder call (two pictures, poster first).
    PosterAndFrame {
        media: Id,
        path: String,
        poster_at: Time,
        frame_at: Time,
        frame_key: String,
        height: i64,
        aspect: Option<PixelAspect>,
    },
    /// One clip frame.
    Frame { media: Id, path: String, at: Time, key: String, height: i64, aspect: Option<PixelAspect> },
    /// A hover-scrub frame (interactive lane); only the newest `serial` is delivered.
    Scrub { media: Id, path: String, at: Time, height: i64, aspect: Option<PixelAspect>, serial: u64 },
}

/// Decodes the pictures of a job (platform code: thumbnail generator, image decoder). Blocking; called on a worker.
pub trait ThumbnailSource: Send + Sync {
    /// One entry per picture the job asks for (`None` = could not be made).
    fn run(&self, job: &ThumbnailJob) -> Vec<Option<Thumbnail>>;
}

/// A cache bounded by entry count and total cost; the oldest insert goes first (Swift `NSCache` with limits).
struct CostCache<K: Ord + Clone, V> {
    map: BTreeMap<K, (V, usize, u64)>,
    count_limit: usize,
    cost_limit: usize,
    total: usize,
    clock: u64,
}

impl<K: Ord + Clone, V> CostCache<K, V> {
    fn new(count_limit: usize, cost_limit: usize) -> CostCache<K, V> {
        CostCache { map: BTreeMap::new(), count_limit, cost_limit, total: 0, clock: 0 }
    }

    fn get(&self, k: &K) -> Option<&V> {
        self.map.get(k).map(|e| &e.0)
    }

    fn remove(&mut self, k: &K) {
        if let Some((_, cost, _)) = self.map.remove(k) {
            self.total -= cost;
        }
    }

    fn clear(&mut self) {
        self.map.clear();
        self.total = 0;
    }

    fn set_cost_limit(&mut self, limit: usize) {
        self.cost_limit = limit;
        self.evict(None);
    }

    fn insert(&mut self, k: K, v: V, cost: usize) {
        self.remove(&k);
        self.clock += 1;
        self.total += cost;
        self.map.insert(k.clone(), (v, cost, self.clock));
        self.evict(Some(&k));
    }

    /// Drops the oldest entries until the limits hold; the entry just inserted always stays.
    fn evict(&mut self, keep: Option<&K>) {
        while self.map.len() > self.count_limit || self.total > self.cost_limit {
            let oldest =
                self.map.iter().filter(|(k, _)| Some(*k) != keep).min_by_key(|(_, e)| e.2).map(|(k, _)| k.clone());
            match oldest {
                Some(k) => self.remove(&k),
                None => break,
            }
        }
    }
}

/// A poster job waiting in the queue.
struct WaitingPoster {
    media: MediaRef,
    height: i64,
    /// The clip frame that is decoded together with the poster.
    frame: Option<(Time, String)>,
}

/// Thumbnails of Project items (Swift `ProjectThumbnails`).
pub struct ProjectThumbnails {
    limits: WorkLimits,
    posters: CostCache<Id, Thumbnail>,
    frames: CostCache<String, Thumbnail>,
    /// Items the bin shows right now: kept under critical memory pressure.
    visible: BTreeSet<Id>,
    failed: BTreeSet<Id>,
    /// Height (pixels) each cached poster was made at: a larger thumbnail size asks for a sharper one.
    poster_heights: BTreeMap<Id, i64>,
    pending: BTreeSet<Id>,
    /// The pixel aspect each media item is shown with its pictures were last asked with.
    shapes: BTreeMap<Id, PixelAspect>,
    /// The file each media item's pictures were made from: a relink (same id, other path) makes them again.
    paths: BTreeMap<Id, String>,
    poster_queue: VisibleFirstQueue<Id>,
    waiting_posters: BTreeMap<Id, WaitingPoster>,
    running_posters: i64,
    pending_frames: BTreeSet<String>,
    failed_frames: BTreeSet<String>,
    scrub_serial: u64,
    scrub_result: Option<(Id, Thumbnail)>,
    jobs: Vec<ThumbnailJob>,
    arrived: Vec<Id>,
    version: u64,
}

impl ProjectThumbnails {
    /// Cache sizes from `limits` (halved on 8 GB Macs).
    // Swift: ProjectThumbnails.swift:18
    pub fn new(limits: &WorkLimits) -> ProjectThumbnails {
        let bytes = |n: i64| usize::try_from(n).unwrap_or(0);
        ProjectThumbnails {
            limits: *limits,
            posters: CostCache::new(400, bytes(limits.poster_cache_bytes)),
            frames: CostCache::new(200, bytes(limits.clip_frame_cache_bytes)),
            visible: BTreeSet::new(),
            failed: BTreeSet::new(),
            poster_heights: BTreeMap::new(),
            pending: BTreeSet::new(),
            shapes: BTreeMap::new(),
            paths: BTreeMap::new(),
            poster_queue: VisibleFirstQueue::new(),
            waiting_posters: BTreeMap::new(),
            running_posters: 0,
            pending_frames: BTreeSet::new(),
            failed_frames: BTreeSet::new(),
            scrub_serial: 0,
            scrub_result: None,
            jobs: Vec::new(),
            arrived: Vec::new(),
            version: 0,
        }
    }

    /// Changes whenever a picture arrived or was dropped; views key their caches on it.
    pub fn version(&self) -> u64 {
        self.version
    }

    /// Posters made so far that are still cached (approx.: the cache may have evicted some on its own).
    // Swift: ProjectThumbnails.swift:36
    pub fn poster_count(&self) -> usize {
        self.poster_heights.len()
    }

    /// Memory pressure: the byte caps drop to the level's budget; warning also drops every clip frame, critical every
    /// poster the bin does not show. Normal restores the caps (dropped items are requested again on draw).
    pub fn apply_memory_pressure(&mut self, level: MemoryPressure) {
        let cap = |full: i64| usize::try_from(level.budget(full)).unwrap_or(0);
        self.posters.set_cost_limit(cap(self.limits.poster_cache_bytes));
        self.frames.set_cost_limit(cap(self.limits.clip_frame_cache_bytes));
        if level == MemoryPressure::Normal {
            return;
        }
        self.frames.clear();
        if level != MemoryPressure::Critical {
            return;
        }
        let drop: Vec<Id> = self.poster_heights.keys().filter(|id| !self.visible.contains(id)).copied().collect();
        for id in drop {
            self.posters.remove(&id);
            self.poster_heights.remove(&id);
        }
        self.version += 1;
    }

    /// The cached poster.
    // Swift: ProjectThumbnails.swift:65
    pub fn cached_poster(&self, id: Id) -> Option<&Thumbnail> {
        self.posters.get(&id)
    }

    /// Sees `media` as the project has it now. A changed pixel aspect drops the item's poster (also one still loading: its
    /// result is discarded) so the next request makes it again; clip frames are keyed by the shape.
    fn note(&mut self, media: &MediaRef) {
        let id = media.id;
        let now = media.info.as_ref().and_then(|i| i.video.as_ref()).map(|v| v.display_pixel_aspect());
        let relinked = self.paths.insert(id, media.path.clone()).is_some_and(|old| old != media.path);
        if self.shapes.get(&id).copied() == now && !relinked {
            return;
        }
        match now {
            Some(a) => self.shapes.insert(id, a),
            None => self.shapes.remove(&id),
        };
        self.posters.remove(&id);
        self.poster_heights.remove(&id);
        self.failed.remove(&id);
        if self.pending.remove(&id) {
            self.drop_waiting(id);
        }
    }

    /// Takes a poster job out of the queue (with the clip frame it carries, which is then asked for again).
    fn drop_waiting(&mut self, id: Id) {
        self.poster_queue.remove(&id);
        if let Some(WaitingPoster { frame: Some((_, key)), .. }) = self.waiting_posters.remove(&id) {
            self.pending_frames.remove(&key);
        }
    }

    /// The cached poster of `media` in the shape the project gives it now; `None` while it has to be made (again).
    // Swift: ProjectThumbnails.swift:89
    pub fn poster(&mut self, media: &MediaRef) -> Option<&Thumbnail> {
        self.note(media);
        self.posters.get(&media.id)
    }

    /// The picture of `id` is gone from where it was shown (its atlas cell went to another poster): the next request makes
    /// it again. Unlike [`ProjectThumbnails::forget`] a decode in flight and a failure stay as they are.
    pub fn drop_picture(&mut self, id: Id) {
        self.posters.remove(&id);
        self.poster_heights.remove(&id);
        self.version += 1;
    }

    /// Forgets everything about a media (its file changed or it left the project).
    // Swift: ProjectThumbnails.swift:90
    pub fn forget(&mut self, id: Id) {
        self.posters.remove(&id);
        self.poster_heights.remove(&id);
        self.failed.remove(&id);
        self.pending.remove(&id);
        self.shapes.remove(&id);
        self.drop_waiting(id);
        self.version += 1;
    }

    fn poster_is_sharp(&self, id: Id, height: i64) -> bool {
        self.posters.get(&id).is_some() && self.poster_heights.get(&id).is_some_and(|have| have * 4 >= height * 3)
    }

    /// Asks for the poster; the picture arrives through [`ProjectThumbnails::take_arrived`]. A cached poster is kept
    /// unless the wanted height is clearly larger than the one it was made at. Requests wait in a visible-first queue:
    /// at most `WorkLimits.poster_decodes` load at once, items on screen first, then the rest oldest first.
    // Swift: ProjectThumbnails.swift:102
    pub fn request_poster(&mut self, media: &MediaRef, height: i64) {
        let id = media.id;
        self.note(media);
        if self.poster_is_sharp(id, height) || self.failed.contains(&id) || !self.pending.insert(id) {
            return;
        }
        if media.kind() == MediaKind::Audio {
            // No picture: settled at once, no decode slot.
            self.pending.remove(&id);
            self.failed.insert(id);
            self.arrived.push(id);
            self.version += 1;
            return;
        }
        self.waiting_posters.insert(id, WaitingPoster { media: media.clone(), height, frame: None });
        self.poster_queue.enqueue(id);
        self.pump_posters();
    }

    /// The poster and the clip frame at `frame_at` of `media` (Color page Clips list). When both have to be made they
    /// wait as ONE job in the poster queue and decode in one call: two frames of one file that way cost 0.70-0.85 of two
    /// calls. Otherwise each goes its own way. Each picture that arrives is reported.
    // Swift: ProjectThumbnails.swift:122
    pub fn request_poster_and_frame(&mut self, media: &MediaRef, frame_at: Option<Time>, height: i64) {
        let id = media.id;
        self.note(media);
        let plain = media.kind() == MediaKind::Audio
            || media.kind() == MediaKind::Image
            || media.info.as_ref().is_some_and(|i| i.is_still);
        let Some(t) = frame_at.filter(|_| !plain) else {
            self.request_poster(media, height);
            if let Some(t) = frame_at {
                self.request_frame(media, t, height);
            }
            return;
        };
        let key = self.shaped_key(id, t, height);
        let poster_wanted =
            !self.poster_is_sharp(id, height) && !self.failed.contains(&id) && !self.pending.contains(&id);
        let frame_wanted = self.frames.get(&key).is_none()
            && !self.failed_frames.contains(&key)
            && !self.pending_frames.contains(&key);
        if !(poster_wanted && frame_wanted) {
            self.request_poster(media, height);
            self.request_frame(media, t, height);
            return;
        }
        self.pending.insert(id);
        self.pending_frames.insert(key.clone());
        self.waiting_posters.insert(id, WaitingPoster { media: media.clone(), height, frame: Some((t, key)) });
        self.poster_queue.enqueue(id);
        self.pump_posters();
    }

    /// Media on screen now, top-left first: their posters load before any other waiting one.
    // Swift: ProjectThumbnails.swift:146
    pub fn set_visible(&mut self, ids: &[Id]) {
        self.visible = ids.iter().copied().collect();
        self.poster_queue.set_visible(ids.to_vec());
    }

    fn pump_posters(&mut self) {
        while self.running_posters < self.limits.poster_decodes {
            let Some(id) = self.poster_queue.pop_next() else { return };
            let Some(job) = self.waiting_posters.remove(&id) else { continue };
            self.running_posters += 1;
            let m = &job.media;
            let video = m.info.as_ref().and_then(|i| i.video.as_ref());
            let fd = video.map_or(Time::new(1, 30), |v| v.nominal_frame_duration);
            let total = m.info.as_ref().map(|i| i.duration).or(m.duration).unwrap_or(Time::ZERO);
            let at = m.poster_time.unwrap_or_else(|| crate::HoverScrub::poster(total, fd));
            let aspect = video.map(|v| v.display_pixel_aspect());
            self.jobs.push(match job.frame {
                Some((frame_at, frame_key)) => ThumbnailJob::PosterAndFrame {
                    media: id,
                    path: m.path.clone(),
                    poster_at: at,
                    frame_at,
                    frame_key,
                    height: job.height,
                    aspect,
                },
                None => ThumbnailJob::Poster {
                    media: id,
                    path: m.path.clone(),
                    is_still: m.info.as_ref().is_some_and(|i| i.is_still) || m.kind() == MediaKind::Image,
                    at,
                    height: job.height,
                    aspect,
                },
            });
        }
    }

    /// The decodes that may start now.
    pub fn take_jobs(&mut self) -> Vec<ThumbnailJob> {
        std::mem::take(&mut self.jobs)
    }

    /// The media whose picture settled (arrived or failed) since the last call: the views redraw them.
    pub fn take_arrived(&mut self) -> Vec<Id> {
        std::mem::take(&mut self.arrived)
    }

    /// Hover scrub: the frame at `time`; only the newest request is delivered ([`ProjectThumbnails::take_scrub`]).
    // Swift: ProjectThumbnails.swift:233
    pub fn scrub(&mut self, media: &MediaRef, time: Time, height: i64) {
        self.note(media);
        self.scrub_serial += 1;
        self.scrub_result = None;
        self.jobs.push(ThumbnailJob::Scrub {
            media: media.id,
            path: media.path.clone(),
            at: time,
            height,
            aspect: media.info.as_ref().and_then(|i| i.video.as_ref()).map(|v| v.display_pixel_aspect()),
            serial: self.scrub_serial,
        });
    }

    /// The newest hover-scrub frame, once.
    pub fn take_scrub(&mut self) -> Option<(Id, Thumbnail)> {
        self.scrub_result.take()
    }

    fn store_frame(&mut self, key: String, image: Option<Thumbnail>) {
        match image {
            Some(img) => {
                let cost = img.cost();
                self.frames.insert(key, img, cost);
            }
            None => {
                if self.failed_frames.len() > 2000 {
                    self.failed_frames.clear();
                }
                self.failed_frames.insert(key);
            }
        }
    }

    fn store_poster(&mut self, id: Id, height: i64, image: Option<Thumbnail>) {
        match image {
            Some(img) => {
                self.poster_heights.insert(id, height);
                let cost = img.cost();
                self.posters.insert(id, img, cost);
            }
            None => {
                if self.failed.len() > 2000 {
                    self.failed.clear();
                }
                self.failed.insert(id);
            }
        }
    }

    /// Takes the pictures of a finished job (one entry per picture, `None` = failed).
    pub fn finish(&mut self, job: &ThumbnailJob, images: Vec<Option<Thumbnail>>) {
        let mut images = images.into_iter();
        match job {
            ThumbnailJob::Poster { media, aspect, height, .. } => {
                self.running_posters -= 1;
                if self.shapes.get(media).copied() == *aspect {
                    self.pending.remove(media);
                    self.store_poster(*media, *height, images.next().flatten());
                    self.arrived.push(*media);
                }
                self.pump_posters();
            }
            ThumbnailJob::PosterAndFrame { media, aspect, height, frame_key, .. } => {
                self.running_posters -= 1;
                self.pending_frames.remove(frame_key);
                let (poster, frame) = (images.next().flatten(), images.next().flatten());
                self.store_frame(frame_key.clone(), frame);
                // The pixel aspect changed meanwhile: a new load is on its way.
                if self.shapes.get(media).copied() == *aspect {
                    self.pending.remove(media);
                    self.store_poster(*media, *height, poster);
                }
                self.arrived.push(*media);
                self.pump_posters();
            }
            ThumbnailJob::Frame { media, key, .. } => {
                self.pending_frames.remove(key);
                self.store_frame(key.clone(), images.next().flatten());
                self.arrived.push(*media);
            }
            ThumbnailJob::Scrub { media, serial, .. } => {
                if *serial == self.scrub_serial
                    && let Some(img) = images.next().flatten()
                {
                    self.scrub_result = Some((*media, img));
                }
            }
        }
        self.version += 1;
    }

    /// Frames of single clips are keyed by media + time + height.
    fn frame_key(media: Id, t: Time, height: i64) -> String {
        format!("{media}|{}/{}|{height}", t.value(), t.timescale())
    }

    /// Cache key of a clip frame in the shape `media` is shown with now (the plain key for the file's own shape).
    fn shaped_key(&self, media: Id, t: Time, height: i64) -> String {
        let k = Self::frame_key(media, t, height);
        let k = match self.paths.get(&media) {
            Some(p) => format!("{k}|{p}"),
            None => k,
        };
        match self.shapes.get(&media) {
            Some(a) => format!("{k}|{a:?}"),
            None => k,
        }
    }

    /// The cached clip frame.
    // Swift: ProjectThumbnails.swift:261
    pub fn cached_frame(&self, media: Id, t: Time, height: i64) -> Option<&Thumbnail> {
        self.frames.get(&self.shaped_key(media, t, height))
    }

    /// The frame of `media` at `t` (media time). Stills and audio have no per-clip frame (callers keep the poster).
    fn request_frame(&mut self, media: &MediaRef, t: Time, height: i64) {
        if media.kind() == MediaKind::Audio
            || media.kind() == MediaKind::Image
            || media.info.as_ref().is_some_and(|i| i.is_still)
        {
            return;
        }
        self.note(media);
        let key = self.shaped_key(media.id, t, height);
        if self.frames.get(&key).is_some()
            || self.failed_frames.contains(&key)
            || !self.pending_frames.insert(key.clone())
        {
            return;
        }
        let aspect = media.info.as_ref().and_then(|i| i.video.as_ref()).map(|v| v.display_pixel_aspect());
        self.jobs.push(ThumbnailJob::Frame { media: media.id, path: media.path.clone(), at: t, key, height, aspect });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::es08_media::testing;
    use sq_core_model::MediaFingerprint;

    fn limits() -> WorkLimits {
        WorkLimits::new(&sq_core_project::work_limits::MachineResources::new(16 << 30, 8, false))
    }

    fn video_ref(n: u128) -> MediaRef {
        let mut m = MediaRef::new(Id::from_u128(n), "a.mov", "/nowhere/a.mov", MediaFingerprint::new(1));
        let video = testing::video(320, 180);
        m.info = Some(testing::info(Time::new(2, 1), Some(video)));
        m.duration = Some(Time::new(2, 1));
        m
    }

    fn img() -> Thumbnail {
        Thumbnail { width: 2, height: 2, rgba: Arc::new(vec![0; 16]) }
    }

    #[test]
    fn pair_of_an_unreadable_file_settles_both_once() {
        let mut t = ProjectThumbnails::new(&limits());
        let r = video_ref(1);
        t.request_poster_and_frame(&r, Some(Time::new(1, 1)), 60);
        let jobs = t.take_jobs();
        assert_eq!(jobs.len(), 1);
        t.finish(&jobs[0], vec![None, None]);
        assert_eq!(t.take_arrived(), vec![r.id]);
        assert!(t.cached_poster(r.id).is_none() && t.cached_frame(r.id, Time::new(1, 1), 60).is_none());
        t.request_poster_and_frame(&r, Some(Time::new(1, 1)), 60);
        assert!(t.take_jobs().is_empty() && t.take_arrived().is_empty());
    }

    #[test]
    fn poster_waits_for_a_slot_and_visible_items_go_first() {
        let mut limits = limits();
        limits.poster_decodes = 1;
        let mut t = ProjectThumbnails::new(&limits);
        let (a, b, c) = (video_ref(1), video_ref(2), video_ref(3));
        t.request_poster(&a, 60);
        t.request_poster(&b, 60);
        t.request_poster(&c, 60);
        t.set_visible(&[c.id]);
        let first = t.take_jobs();
        assert_eq!(first.len(), 1);
        t.finish(&first[0], vec![Some(img())]);
        let second = t.take_jobs();
        assert!(matches!(&second[0], ThumbnailJob::Poster { media, .. } if *media == c.id));
        assert!(t.cached_poster(a.id).is_some());
    }

    #[test]
    fn a_sharper_poster_is_asked_for_only_when_clearly_larger() {
        let mut t = ProjectThumbnails::new(&limits());
        let r = video_ref(1);
        t.request_poster(&r, 100);
        let job = t.take_jobs().remove(0);
        t.finish(&job, vec![Some(img())]);
        t.request_poster(&r, 120);
        assert!(t.take_jobs().is_empty());
        t.request_poster(&r, 200);
        assert_eq!(t.take_jobs().len(), 1);
    }

    #[test]
    fn audio_settles_without_a_job() {
        let mut t = ProjectThumbnails::new(&limits());
        let mut m = MediaRef::new(Id::from_u128(5), "a.wav", "/x/a.wav", MediaFingerprint::new(1));
        let mut info = testing::info(Time::new(2, 1), None);
        info.audio = Some(sq_core_model::AudioTrackInfo {
            sample_rate: 48_000,
            channels: 2,
            codec: "aac".to_string(),
            channel_map: None,
            first_track_channels: None,
        });
        m.info = Some(info);
        t.request_poster(&m, 60);
        assert!(t.take_jobs().is_empty());
        assert_eq!(t.take_arrived(), vec![m.id]);
    }

    #[test]
    fn a_relinked_file_makes_its_poster_and_frames_again() {
        let mut t = ProjectThumbnails::new(&limits());
        let mut r = video_ref(1);
        let at = Time::new(1, 1);
        t.request_poster_and_frame(&r, Some(at), 60);
        let job = t.take_jobs().remove(0);
        t.finish(&job, vec![Some(img()), Some(img())]);
        assert!(t.poster(&r).is_some() && t.cached_frame(r.id, at, 60).is_some());
        // The same file again: nothing is made twice.
        t.request_poster_and_frame(&r, Some(at), 60);
        assert!(t.take_jobs().is_empty());
        // Relinked (same id, new path): the old pictures are gone and a job for the new file runs.
        r.path = "/elsewhere/clip.mov".to_string();
        assert!(t.poster(&r).is_none() && t.cached_frame(r.id, at, 60).is_none());
        t.request_poster_and_frame(&r, Some(at), 60);
        let jobs = t.take_jobs();
        assert!(
            matches!(&jobs[0], ThumbnailJob::PosterAndFrame { path, .. } if path == "/elsewhere/clip.mov"),
            "{jobs:?}"
        );
    }

    #[test]
    fn a_changed_pixel_aspect_drops_the_poster() {
        let mut t = ProjectThumbnails::new(&limits());
        let mut r = video_ref(1);
        t.request_poster(&r, 60);
        let job = t.take_jobs().remove(0);
        t.finish(&job, vec![Some(img())]);
        assert!(t.poster(&r).is_some());
        if let Some(v) = r.info.as_mut().and_then(|i| i.video.as_mut()) {
            v.pixel_aspect = PixelAspect::new(2, 1).unwrap_or_else(PixelAspect::square);
        }
        assert!(t.poster(&r).is_none());
        assert_eq!(t.poster_count(), 0);
    }

    #[test]
    fn only_the_newest_scrub_frame_is_delivered() {
        let mut t = ProjectThumbnails::new(&limits());
        let r = video_ref(1);
        t.scrub(&r, Time::new(1, 2), 60);
        t.scrub(&r, Time::new(1, 1), 60);
        let jobs = t.take_jobs();
        t.finish(&jobs[1], vec![Some(img())]);
        t.finish(&jobs[0], vec![Some(img())]);
        assert_eq!(t.take_scrub().map(|(id, _)| id), Some(r.id));
        assert!(t.take_scrub().is_none());
    }

    #[test]
    fn memory_pressure_drops_frames_and_posters_not_on_screen() {
        let mut t = ProjectThumbnails::new(&limits());
        let (a, b) = (video_ref(1), video_ref(2));
        for r in [&a, &b] {
            t.request_poster(r, 60);
        }
        for job in t.take_jobs() {
            t.finish(&job, vec![Some(img())]);
        }
        t.set_visible(&[a.id]);
        t.apply_memory_pressure(MemoryPressure::Critical);
        assert!(t.cached_poster(a.id).is_some() && t.cached_poster(b.id).is_none());
    }

    #[test]
    fn cost_cache_keeps_the_newest_within_its_limits() {
        let mut c: CostCache<u8, u8> = CostCache::new(2, 10);
        c.insert(1, 1, 4);
        c.insert(2, 2, 4);
        c.insert(3, 3, 4);
        assert!(c.get(&1).is_none() && c.get(&2).is_some() && c.get(&3).is_some());
        c.insert(4, 4, 50);
        assert!(c.get(&4).is_some() && c.get(&3).is_none());
    }

    #[test]
    fn poster_time_is_a_tenth_in_at_most_two_seconds() {
        assert_eq!(crate::HoverScrub::poster(Time::new(10, 1), Time::new(1, 30)), Time::new(1, 1));
        assert_eq!(crate::HoverScrub::poster(Time::new(100, 1), Time::new(1, 30)), Time::new(2, 1));
        assert_eq!(crate::HoverScrub::poster(Time::ZERO, Time::new(1, 30)), Time::ZERO);
    }
}
