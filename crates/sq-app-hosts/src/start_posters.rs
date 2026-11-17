// Swift: SharedUIController.swift (`shell.startPoster`), `StartPosterLoader`
//! The pictures of the start screen's cards: the frame of a project's poster media at its poster time. The start screen
//! asks for a (path, seconds) while it draws; the answer is the frame once it is in the thumbnail atlas, `None` before
//! that, so the card keeps its empty look. The decode runs on the worker pool through a [`ThumbnailSource`], never on the
//! calling (UI) thread; each finished picture waits as an upload for the renderer, and the wake redraws the window.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;
use std::sync::Arc;

use sq_app_shell::{ATLAS_SLOT, ImageUpload};
use sq_core_model::{MediaFingerprint, MediaRef};
use sq_core_time::{Id, Time};
use sq_draw_shell::ProjectPoster;
use sq_editor_session::ThumbnailSource;
use sq_runtime::WorkerPool;

use crate::poster_pump::{PosterPump, SharedAtlas};
use crate::project_services::FfmpegPosters;

/// Pixel height of a card picture (the Continue card is the largest, drawn about 180 pt tall).
const HEIGHT: i64 = 360;

/// The start screen's poster cache.
pub struct StartPosters {
    pump: PosterPump,
    /// A stable media id per file, so a repeated ask hits the cache.
    ids: BTreeMap<String, MediaRef>,
    /// What the start screen asked for since it was last hidden: all of it is pumped together, so the cards protect
    /// each other's cells (one pump per card made every ask see only itself as wanted).
    asked: BTreeMap<String, (MediaRef, Time)>,
}

/// Shared between the shell's hook and the app root, which collects the uploads.
pub type SharedStartPosters = Rc<RefCell<StartPosters>>;

impl StartPosters {
    /// FFmpeg frames on two workers, packed into `atlas`.
    pub fn new(atlas: SharedAtlas) -> StartPosters {
        StartPosters::with_services(Arc::new(FfmpegPosters), Arc::new(WorkerPool::threads(2)), atlas)
    }

    /// Like [`StartPosters::new`] with the source and the pool given (tests).
    pub fn with_services(source: Arc<dyn ThumbnailSource>, pool: Arc<WorkerPool>, atlas: SharedAtlas) -> StartPosters {
        StartPosters { pump: PosterPump::new(source, pool, atlas), ids: BTreeMap::new(), asked: BTreeMap::new() }
    }

    /// Runs `wake` after every decode.
    pub fn set_wake(&mut self, wake: Arc<dyn Fn() + Send + Sync>) {
        self.pump.set_wake(wake);
    }

    /// Asks for the frame of `path` at `seconds`: queues the decode on the first ask and returns the picture once it is
    /// placed (the poster frame stands in while the exact frame is on its way).
    pub fn poster(&mut self, path: &str, seconds: f64) -> Option<ProjectPoster> {
        let next = self.ids.len() as u128 + 1;
        let media = self
            .ids
            .entry(path.to_string())
            .or_insert_with(|| MediaRef::new(Id::from_u128(next), path, path, MediaFingerprint::new(0)))
            .clone();
        let at = Time::new((seconds.max(0.0) * 1000.0).round() as i64, 1000);
        self.asked.insert(path.to_string(), (media.clone(), at));
        self.pump.pump_frames(self.asked.values().map(|(m, at)| (m, Some(*at))), HEIGHT);
        let placed = self.pump.placed_frame(media.id, Some(at))?;
        let [u0, v0, u1, v1] = placed.uv();
        Some(ProjectPoster { slot: ATLAS_SLOT, u0, v0, u1, v1, pixel_size: placed.size() })
    }

    /// The start screen is not shown: its cells go back to the atlas for the panels that are (the cache keeps the
    /// pictures, so showing it again costs no decode).
    pub fn release(&mut self) {
        if !self.asked.is_empty() {
            self.asked.clear();
            self.pump.release_all();
        }
    }

    /// The pictures the renderer has to upload since the last call.
    pub fn take_uploads(&mut self) -> Vec<ImageUpload> {
        self.pump.take_uploads()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_editor_session::{Thumbnail, ThumbnailJob};
    use std::sync::Mutex;

    /// Gray pictures; records the thread each decode ran on.
    struct Gray(Mutex<Vec<std::thread::ThreadId>>);

    impl ThumbnailSource for Gray {
        fn run(&self, job: &ThumbnailJob) -> Vec<Option<Thumbnail>> {
            self.0.lock().unwrap().push(std::thread::current().id());
            let shot = || Some(Thumbnail { width: 4, height: 2, rgba: Arc::new(vec![50; 4 * 2 * 4]) });
            match job {
                ThumbnailJob::PosterAndFrame { .. } => vec![shot(), shot()],
                _ => vec![shot()],
            }
        }
    }

    #[test]
    fn the_frame_arrives_after_the_pool_ran_and_the_ask_never_decodes_inline() {
        let pool = Arc::new(WorkerPool::manual());
        let source = Arc::new(Gray(Mutex::new(Vec::new())));
        let mut posters =
            StartPosters::with_services(Arc::clone(&source) as _, Arc::clone(&pool), SharedAtlas::default());
        assert_eq!(posters.poster("/a/clip.mov", 1.5), None, "nothing decoded yet: the empty look stays");
        assert!(source.0.lock().unwrap().is_empty(), "the ask did not decode on the calling thread");
        while pool.step() {}
        let p = posters.poster("/a/clip.mov", 1.5).expect("the picture");
        assert_eq!(p.slot, ATLAS_SLOT);
        assert_eq!((p.pixel_size.width, p.pixel_size.height), (4.0, 2.0));
        assert_eq!(posters.take_uploads().len(), 1, "the frame goes to the renderer; its poster needs no cell");
        assert_eq!(posters.poster("/b/other.mov", 0.0), None, "another file starts its own decode");
    }

    #[test]
    fn a_worker_thread_decodes_not_the_caller() {
        let pool = Arc::new(WorkerPool::threads(1));
        let source = Arc::new(Gray(Mutex::new(Vec::new())));
        let mut posters = StartPosters::with_services(Arc::clone(&source) as _, pool, SharedAtlas::default());
        posters.poster("/a/clip.mov", 0.0);
        for _ in 0..200 {
            if !source.0.lock().unwrap().is_empty() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let ran = source.0.lock().unwrap().clone();
        assert!(!ran.is_empty() && ran.iter().all(|t| *t != std::thread::current().id()));
    }

    /// Posters of one fixed size.
    struct Sized(usize, usize);

    impl ThumbnailSource for Sized {
        fn run(&self, job: &ThumbnailJob) -> Vec<Option<Thumbnail>> {
            let shot =
                || Some(Thumbnail { width: self.0, height: self.1, rgba: Arc::new(vec![9; self.0 * self.1 * 4]) });
            match job {
                ThumbnailJob::PosterAndFrame { .. } => vec![shot(), shot()],
                _ => vec![shot()],
            }
        }
    }

    /// The Windows VM showed no poster in the Project panel: twelve start cards held poster AND frame cells of the
    /// shared atlas for good (24 cells of 640 x 360, the atlas holds 15), and the panel found no cell left.
    #[test]
    fn the_start_screen_leaves_room_in_the_atlas_for_the_project_panel() {
        let atlas = SharedAtlas::default();
        let pool = Arc::new(WorkerPool::manual());
        let mut cards =
            StartPosters::with_services(Arc::new(Sized(640, 360)), Arc::clone(&pool), SharedAtlas::clone(&atlas));
        let paths: Vec<String> = (0..15).map(|n| format!("C:\\Users\\x\\p{n}.mp4")).collect();
        let ask = |cards: &mut StartPosters| paths.iter().filter(|p| cards.poster(p, 0.0).is_some()).count();
        for _ in 0..20 {
            ask(&mut cards);
            while pool.step() {}
        }
        assert_eq!(ask(&mut cards), 15, "every card has its frame (the poster needs no cell of its own)");
        assert_eq!(ask(&mut cards), 15, "and keeps it: no card pushes another out");
        // The Project panel's pump on the same atlas: posters 400 x 300 do not fit the strip below the cards.
        let mut panel = PosterPump::new(Arc::new(Sized(400, 300)), Arc::clone(&pool), SharedAtlas::clone(&atlas));
        let m = MediaRef::new(Id::from_u128(77), "clip", "C:\\clip.mp4", MediaFingerprint::new(1));
        panel.pump([&m], 300);
        while pool.step() {}
        panel.pump([&m], 300);
        assert!(panel.placed(m.id).is_none(), "the atlas is full while the start screen shows");
        // The editor opens: the start screen is hidden and hands its cells back.
        cards.release();
        panel.pump([&m], 300);
        assert!(panel.placed(m.id).is_some(), "the panel's poster gets a released cell");
        assert!(ask(&mut cards) >= 14, "the start screen shows again from the cache (one cell went to the panel)");
        assert_eq!(pool.pending(), 0);
    }
}
