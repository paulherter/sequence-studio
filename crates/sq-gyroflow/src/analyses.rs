//! The driver of `SQAnalysis/GyroflowEngine.swift` without the Metal parts: one analysis per (file, options) running on a
//! background thread (open, smooth), the last `capacity` kept (the newest finished one of each file always stays, so
//! playback keeps showing it while a slider drag smooths new options), the state the Analyze row shows, cancel and retry.

use crate::file::{GyroError, GyroFile};
use parking_lot::Mutex;
use sq_core_masks::stabilize_effect::GyroflowOptions;
use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// Where the engine is with one clip file and one set of options.
#[derive(Clone, Debug, PartialEq)]
pub enum GyroState {
    Idle,
    /// 0 = reading the gyro data, 0.6 = smoothing it (the steps Swift reports).
    Analysing(f64),
    Ready,
    Failed(String),
}

/// A file and one set of options (floats by their bits: equal options are equal keys).
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct AnalysisKey {
    pub path: String,
    options: [u64; 7],
}

impl AnalysisKey {
    /// The options as bits (a cache key part).
    pub fn options_bits(&self) -> [u64; 7] {
        self.options
    }

    pub fn new(path: &str, o: &GyroflowOptions) -> AnalysisKey {
        let options = [
            o.smoothness.to_bits(),
            o.zoom_limit.to_bits(),
            u64::from(o.rolling_shutter),
            o.horizon_lock.to_bits(),
            o.field_of_view.to_bits(),
            o.lens_correction.to_bits(),
            o.sync_offset_ms.to_bits(),
        ];
        AnalysisKey { path: path.to_string(), options }
    }
}

/// What opens and smooths a clip (`GyroFile` in the app; a fake in tests).
pub trait GyroBackend: Send + Sync + 'static {
    type Handle: Send + Sync + 'static;
    /// Opens `path` (or copies `donor`, a finished analysis of the same file, without reading the file again) and
    /// smooths it with `options`.
    fn analyze(
        &self,
        path: &Path,
        options: &GyroflowOptions,
        donor: Option<&Self::Handle>,
        progress: &dyn Fn(f64),
    ) -> Result<Self::Handle, GyroError>;
}

/// The app's backend: gyroflow-core.
pub struct GyroflowBackend;

impl GyroBackend for GyroflowBackend {
    type Handle = GyroFile;

    fn analyze(
        &self,
        path: &Path,
        options: &GyroflowOptions,
        donor: Option<&GyroFile>,
        progress: &dyn Fn(f64),
    ) -> Result<GyroFile, GyroError> {
        let file = match donor {
            Some(d) => d.fork()?,
            None => GyroFile::open(path)?,
        };
        progress(0.6);
        file.set_options(*options);
        file.recompute()?;
        Ok(file)
    }
}

struct Entry<H> {
    state: Mutex<GyroState>,
    handle: Mutex<Option<Arc<H>>>,
    cancelled: AtomicBool,
    /// Counts up per started analysis (Analyze Again, a new key, a restart after eviction): a waiter keyed by it
    /// notices that the thing it waited for was replaced.
    generation: u64,
}

/// An analysis waiting for a worker.
struct Job<H> {
    key: AnalysisKey,
    options: GyroflowOptions,
    entry: Arc<Entry<H>>,
}

/// How many analyses run at once (each one reads a whole clip's gyro data and smooths it).
pub const WORKERS: usize = 2;

struct Inner<H> {
    /// Analyses not started yet, next first (timeline order, `prioritize` moves one to the front).
    queue: VecDeque<Job<H>>,
    /// Worker threads alive.
    workers: usize,
    next_generation: u64,
    /// The project's stabilized clip count: the cache keeps at least this many keys (`expect_keys`).
    expected: usize,
    entries: HashMap<AnalysisKey, Arc<Entry<H>>>,
    /// Least recently used first.
    order: Vec<AnalysisKey>,
    /// The newest finished analysis of each file (never evicted by the capacity).
    last_ready: HashMap<String, AnalysisKey>,
    /// Keys the user canceled: playback does not start them again until `prepare`.
    held: Vec<AnalysisKey>,
}

type Observer = Arc<dyn Fn() + Send + Sync>;

/// The analyses of one session.
pub struct GyroAnalyses<B: GyroBackend> {
    backend: Arc<B>,
    capacity: usize,
    inner: Arc<Mutex<Inner<B::Handle>>>,
    observers: Arc<Mutex<Vec<Observer>>>,
}

impl<B: GyroBackend> GyroAnalyses<B> {
    /// Four analyses kept, as the Mac engine.
    pub fn new(backend: B) -> GyroAnalyses<B> {
        GyroAnalyses::with_capacity(backend, 4)
    }

    pub fn with_capacity(backend: B, capacity: usize) -> GyroAnalyses<B> {
        GyroAnalyses {
            backend: Arc::new(backend),
            capacity: capacity.max(1),
            inner: Arc::new(Mutex::new(Inner {
                queue: VecDeque::new(),
                workers: 0,
                next_generation: 0,
                expected: 0,
                entries: HashMap::new(),
                order: Vec::new(),
                last_ready: HashMap::new(),
                held: Vec::new(),
            })),
            observers: Arc::new(Mutex::new(Vec::new())),
        }
    }

    /// Called after every change of a state (start, end): the Analyze row and the monitor redraw.
    pub fn add_observer(&self, f: Arc<dyn Fn() + Send + Sync>) {
        self.observers.lock().push(f);
    }

    pub fn state(&self, path: &str, options: &GyroflowOptions) -> GyroState {
        let key = AnalysisKey::new(path, options);
        let entry = self.inner.lock().entries.get(&key).cloned();
        entry.map_or(GyroState::Idle, |e| e.state.lock().clone())
    }

    /// Starts the analysis; a failed one is tried again (Analyze Again).
    pub fn prepare(&self, path: &str, options: &GyroflowOptions) {
        let key = AnalysisKey::new(path, options);
        {
            let mut i = self.inner.lock();
            i.held.retain(|k| *k != key);
            if i.entries.get(&key).is_some_and(|e| matches!(*e.state.lock(), GyroState::Failed(_))) {
                i.entries.remove(&key);
                i.order.retain(|k| *k != key);
            }
        }
        let _ = self.touch(&key, options, true);
    }

    /// The smoothed clip for these options, once ready. Playback asks every frame: a new key starts its analysis (unless
    /// the user canceled it) and refreshes its place in the LRU order.
    pub fn get(&self, path: &str, options: &GyroflowOptions) -> Option<Arc<B::Handle>> {
        let key = AnalysisKey::new(path, options);
        let entry = self.touch(&key, options, false)?;
        entry.handle.lock().clone()
    }

    /// Like `get`, but while the key's own analysis is not ready the newest finished smoothing of the same file is returned
    /// (playback keeps the last good picture until the new options are ready).
    pub fn get_or_stale(&self, path: &str, options: &GyroflowOptions) -> Option<Arc<B::Handle>> {
        if let Some(h) = self.get(path, options) {
            return Some(h);
        }
        let i = self.inner.lock();
        let key = i.last_ready.get(path)?;
        i.entries.get(key)?.handle.lock().clone()
    }

    /// Export: starts the analysis (also one canceled before) and waits until it is done. `None` = it failed.
    /// shortcut: polls every 10 ms; upgrade with a condvar when the wait shows in profiles.
    pub fn wait_ready(&self, path: &str, options: &GyroflowOptions) -> Option<Arc<B::Handle>> {
        self.prepare_if_idle(path, options);
        loop {
            match self.state(path, options) {
                GyroState::Ready => return self.get(path, options),
                GyroState::Failed(_) => return None,
                GyroState::Idle | GyroState::Analysing(_) => std::thread::sleep(std::time::Duration::from_millis(10)),
            }
        }
    }

    /// Playback: starts the analysis when new and waits at most `limit` for it. `Ready` also when a stale smoothing of the file
    /// can stand in or the user canceled the analysis (their choice: the clip stays as it is); `Analysing` = still running.
    /// shortcut: polls every 5 ms like `wait_ready`.
    pub fn ready_within(&self, path: &str, options: &GyroflowOptions, limit: std::time::Duration) -> GyroState {
        let end = std::time::Instant::now() + limit;
        loop {
            if self.get_or_stale(path, options).is_some() {
                return GyroState::Ready;
            }
            match self.state(path, options) {
                s @ (GyroState::Failed(_) | GyroState::Ready) => return s,
                // Idle after the ask above = the user canceled this analysis (their choice: the clip stays as it is).
                GyroState::Idle if self.is_held(path, options) => return GyroState::Ready,
                GyroState::Idle => {
                    self.prepare(path, options);
                    return GyroState::Analysing(0.0);
                }
                s @ GyroState::Analysing(_) if std::time::Instant::now() >= end => return s,
                GyroState::Analysing(_) => std::thread::sleep(std::time::Duration::from_millis(5)),
            }
        }
    }

    fn is_held(&self, path: &str, options: &GyroflowOptions) -> bool {
        self.inner.lock().held.contains(&AnalysisKey::new(path, options))
    }

    fn prepare_if_idle(&self, path: &str, options: &GyroflowOptions) {
        if self.state(path, options) == GyroState::Idle {
            self.prepare(path, options);
        }
    }

    /// Stops the analysis of this file and options: its state is `Idle` at once and a result that still arrives is
    /// dropped. A finished analysis is left alone.
    pub fn cancel(&self, path: &str, options: &GyroflowOptions) {
        let key = AnalysisKey::new(path, options);
        let dropped = {
            let mut i = self.inner.lock();
            let running = i.entries.get(&key).is_some_and(|e| matches!(*e.state.lock(), GyroState::Analysing(_)));
            if !running {
                return;
            }
            i.order.retain(|k| *k != key);
            i.held.push(key.clone());
            i.entries.remove(&key)
        };
        if let Some(e) = dropped {
            e.cancelled.store(true, Ordering::Release);
        }
        self.notify();
    }

    /// Number of analyses held.
    pub fn len(&self) -> usize {
        self.inner.lock().entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn notify(&self) {
        let observers: Vec<_> = self.observers.lock().clone();
        for f in observers {
            f();
        }
    }

    /// The entry of `key`, queued when new. `explicit`: also a canceled key starts again.
    fn touch(&self, key: &AnalysisKey, options: &GyroflowOptions, explicit: bool) -> Option<Arc<Entry<B::Handle>>> {
        let entry = {
            let mut i = self.inner.lock();
            if !explicit && i.held.contains(key) {
                return None;
            }
            i.order.retain(|k| k != key);
            i.order.push(key.clone());
            if let Some(e) = i.entries.get(key) {
                return Some(Arc::clone(e));
            }
            i.next_generation += 1;
            let entry = Arc::new(Entry {
                state: Mutex::new(GyroState::Analysing(0.0)),
                handle: Mutex::new(None),
                cancelled: AtomicBool::new(false),
                generation: i.next_generation,
            });
            i.entries.insert(key.clone(), Arc::clone(&entry));
            i.queue.push_back(Job { key: key.clone(), options: *options, entry: Arc::clone(&entry) });
            // Over capacity: only a finished analysis that is neither the newest of its file nor this key goes (an
            // unfinished one is needed, a canceled running one would be started again by the next frame).
            let keep = i.last_ready.get(&key.path).cloned();
            let capacity = self.capacity.max(i.expected);
            while i.order.len() > capacity {
                let at = i.order.iter().position(|k| {
                    Some(k) != keep.as_ref()
                        && k != key
                        && i.entries.get(k).is_none_or(|e| !matches!(*e.state.lock(), GyroState::Analysing(_)))
                });
                let Some(at) = at else { break };
                let old = i.order.remove(at);
                if let Some(e) = i.entries.remove(&old) {
                    e.cancelled.store(true, Ordering::Release);
                }
            }
            entry
        };
        self.notify();
        self.spawn_workers();
        Some(entry)
    }

    /// The cache keeps at least `n` keys: the project's stabilized clips all stay (no eviction storm with many clips).
    pub fn expect_keys(&self, n: usize) {
        self.inner.lock().expected = n;
    }

    /// Moves the analysis of this clip to the front of the queue (it is needed soon: the playhead is near); starts it when new.
    pub fn prioritize(&self, path: &str, options: &GyroflowOptions) {
        let key = AnalysisKey::new(path, options);
        if self.touch(&key, options, false).is_none() {
            return;
        }
        let mut i = self.inner.lock();
        if let Some(at) = i.queue.iter().position(|j| j.key == key)
            && let Some(job) = i.queue.remove(at)
        {
            i.queue.push_front(job);
        }
    }

    /// The generation of this key's current entry (0 = none): changes when the analysis is replaced (Analyze Again, restart).
    pub fn generation(&self, path: &str, options: &GyroflowOptions) -> u64 {
        let key = AnalysisKey::new(path, options);
        self.inner.lock().entries.get(&key).map_or(0, |e| e.generation)
    }

    /// Starts worker threads for the queued analyses, at most `WORKERS` alive.
    fn spawn_workers(&self) {
        let missing = {
            let mut i = self.inner.lock();
            let n = i.queue.len().min(WORKERS.saturating_sub(i.workers));
            i.workers += n;
            n
        };
        for _ in 0..missing {
            let (backend, inner, observers) =
                (Arc::clone(&self.backend), Arc::clone(&self.inner), Arc::clone(&self.observers));
            std::thread::spawn(move || worker(backend.as_ref(), &inner, &observers));
        }
    }
}

fn notify_all(observers: &Mutex<Vec<Observer>>) {
    let list: Vec<_> = observers.lock().clone();
    for f in list {
        f();
    }
}

/// One worker: takes queued analyses in order until none is left.
fn worker<B: GyroBackend>(backend: &B, inner: &Mutex<Inner<B::Handle>>, observers: &Mutex<Vec<Observer>>) {
    loop {
        let (job, donor) = {
            let mut i = inner.lock();
            let Some(job) =
                std::iter::from_fn(|| i.queue.pop_front()).find(|j| !j.entry.cancelled.load(Ordering::Acquire))
            else {
                i.workers -= 1;
                return;
            };
            // A finished analysis of the same file lends its file data: the new options smooth a copy.
            let donor = i
                .entries
                .iter()
                .find(|(k, e)| k.path == job.key.path && e.handle.lock().is_some())
                .and_then(|(_, e)| e.handle.lock().clone());
            (job, donor)
        };
        let entry = Arc::clone(&job.entry);
        let step = |p: f64| {
            if !entry.cancelled.load(Ordering::Acquire) {
                *entry.state.lock() = GyroState::Analysing(p);
                notify_all(observers);
            }
        };
        // A panic in the backend fails this entry (the warning reads "Stabilizer: <file>: analysis crashed") and the worker
        // goes on with the queue, so its slot is never lost.
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            backend.analyze(Path::new(&job.key.path), &job.options, donor.as_deref(), &step)
        }))
        .unwrap_or_else(|_| Err(GyroError("analysis crashed".into())));
        if entry.cancelled.load(Ordering::Acquire) {
            continue;
        }
        match result {
            Ok(h) => {
                *entry.handle.lock() = Some(Arc::new(h));
                *entry.state.lock() = GyroState::Ready;
                inner.lock().last_ready.insert(job.key.path.clone(), job.key);
            }
            Err(e) => *entry.state.lock() = GyroState::Failed(e.0),
        }
        notify_all(observers);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    /// Smooths for as long as the test lets it; counts opens and forks.
    struct Fake {
        gate: Mutex<Option<mpsc::Receiver<()>>>,
        opened: AtomicUsize,
        forked: AtomicUsize,
        fail: bool,
    }

    impl GyroBackend for Arc<Fake> {
        type Handle = String;
        fn analyze(
            &self,
            path: &Path,
            o: &GyroflowOptions,
            donor: Option<&String>,
            progress: &dyn Fn(f64),
        ) -> Result<String, GyroError> {
            progress(0.6);
            if let Some(rx) = self.gate.lock().as_ref() {
                let _ = rx.recv_timeout(Duration::from_millis(300));
            }
            if self.fail {
                return Err(GyroError("No gyro data in this file.".into()));
            }
            if donor.is_some() {
                self.forked.fetch_add(1, Ordering::SeqCst);
            } else {
                self.opened.fetch_add(1, Ordering::SeqCst);
            }
            Ok(format!("{}@{}", path.display(), o.smoothness))
        }
    }

    fn fake(fail: bool) -> Arc<Fake> {
        Arc::new(Fake { gate: Mutex::new(None), opened: AtomicUsize::new(0), forked: AtomicUsize::new(0), fail })
    }

    fn opts(smoothness: f64) -> GyroflowOptions {
        GyroflowOptions { smoothness, ..GyroflowOptions::default() }
    }

    fn wait<B: GyroBackend>(a: &GyroAnalyses<B>, path: &str, o: &GyroflowOptions) -> GyroState {
        let end = Instant::now() + Duration::from_secs(5);
        loop {
            let s = a.state(path, o);
            if !matches!(s, GyroState::Analysing(_)) || Instant::now() > end {
                return s;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    #[test]
    fn ready_within_waits_for_a_running_analysis_and_reports_failure() {
        let a = GyroAnalyses::new(fake(false));
        assert_eq!(a.ready_within("/a.mp4", &opts(50.0), Duration::from_secs(5)), GyroState::Ready);
        assert!(a.get("/a.mp4", &opts(50.0)).is_some(), "the data is there when the first frame is composed");
        let bad = GyroAnalyses::new(fake(true));
        assert!(matches!(bad.ready_within("/b.mp4", &opts(50.0), Duration::from_secs(5)), GyroState::Failed(_)));
        // A slow analysis past the limit stays Analysing (the caller decides what to show).
        let (tx, rx) = mpsc::channel();
        let slow = Arc::new(Fake {
            gate: Mutex::new(Some(rx)),
            opened: AtomicUsize::new(0),
            forked: AtomicUsize::new(0),
            fail: false,
        });
        let s = GyroAnalyses::new(slow);
        assert!(matches!(s.ready_within("/c.mp4", &opts(50.0), Duration::from_millis(10)), GyroState::Analysing(_)));
        drop(tx);
    }

    #[test]
    fn an_analysis_runs_in_the_background_then_serves_its_handle() {
        let a = GyroAnalyses::new(fake(false));
        assert_eq!(a.state("/a.mp4", &opts(50.0)), GyroState::Idle);
        let _ = a.get("/a.mp4", &opts(50.0)); // playback's first ask starts it
        assert_eq!(wait(&a, "/a.mp4", &opts(50.0)), GyroState::Ready);
        assert_eq!(a.get("/a.mp4", &opts(50.0)).as_deref().map(String::as_str), Some("/a.mp4@50"));
    }

    #[test]
    fn a_failed_analysis_shows_its_reason_and_runs_again_on_prepare() {
        let a = GyroAnalyses::new(fake(true));
        a.prepare("/a.mp4", &opts(50.0));
        assert_eq!(wait(&a, "/a.mp4", &opts(50.0)), GyroState::Failed("No gyro data in this file.".into()));
        a.prepare("/a.mp4", &opts(50.0));
        assert!(matches!(a.state("/a.mp4", &opts(50.0)), GyroState::Analysing(_)), "Analyze Again");
    }

    #[test]
    fn new_options_of_a_file_smooth_a_copy_of_the_finished_analysis() {
        let f = fake(false);
        let a = GyroAnalyses::new(Arc::clone(&f));
        a.prepare("/a.mp4", &opts(50.0));
        assert_eq!(wait(&a, "/a.mp4", &opts(50.0)), GyroState::Ready);
        a.prepare("/a.mp4", &opts(80.0));
        assert_eq!(wait(&a, "/a.mp4", &opts(80.0)), GyroState::Ready);
        assert_eq!((f.opened.load(Ordering::SeqCst), f.forked.load(Ordering::SeqCst)), (1, 1), "the file is read once");
    }

    #[test]
    fn the_least_recently_used_analysis_goes_and_the_newest_of_a_file_stays() {
        let a = GyroAnalyses::with_capacity(fake(false), 2);
        for name in ["/a.mp4", "/b.mp4"] {
            a.prepare(name, &opts(50.0));
            assert_eq!(wait(&a, name, &opts(50.0)), GyroState::Ready);
        }
        a.prepare("/c.mp4", &opts(50.0));
        assert_eq!(wait(&a, "/c.mp4", &opts(50.0)), GyroState::Ready);
        assert_eq!(a.len(), 2);
        assert_eq!(a.state("/a.mp4", &opts(50.0)), GyroState::Idle, "the oldest was dropped");
        assert_eq!(a.state("/b.mp4", &opts(50.0)), GyroState::Ready);
    }

    #[test]
    fn the_state_shows_the_step_the_backend_reached() {
        let f = fake(false);
        let (tx, rx) = mpsc::channel();
        *f.gate.lock() = Some(rx);
        let a = GyroAnalyses::new(Arc::clone(&f));
        a.prepare("/a.mp4", &opts(50.0));
        let end = Instant::now() + Duration::from_secs(5);
        while a.state("/a.mp4", &opts(50.0)) != GyroState::Analysing(0.6) {
            assert!(Instant::now() < end, "the share never reached the smoothing step");
            std::thread::sleep(Duration::from_millis(2));
        }
        let _ = tx.send(());
        assert_eq!(wait(&a, "/a.mp4", &opts(50.0)), GyroState::Ready);
    }

    #[test]
    fn cancel_makes_it_idle_at_once_and_playback_does_not_restart_it() {
        let f = fake(false);
        let (tx, rx) = mpsc::channel();
        *f.gate.lock() = Some(rx);
        let a = GyroAnalyses::new(Arc::clone(&f));
        a.prepare("/a.mp4", &opts(50.0));
        assert!(matches!(a.state("/a.mp4", &opts(50.0)), GyroState::Analysing(_)));
        a.cancel("/a.mp4", &opts(50.0));
        assert_eq!(a.state("/a.mp4", &opts(50.0)), GyroState::Idle);
        assert!(a.get("/a.mp4", &opts(50.0)).is_none());
        assert_eq!(a.state("/a.mp4", &opts(50.0)), GyroState::Idle, "playback's ask does not start a canceled key");
        a.prepare("/a.mp4", &opts(50.0));
        assert!(matches!(a.state("/a.mp4", &opts(50.0)), GyroState::Analysing(_)), "Analyze starts it again");
        let _ = tx.send(()); // only now: a send before could end the new analysis before the assert
    }

    #[test]
    fn observers_hear_the_start_the_smoothing_step_and_the_end() {
        let a = GyroAnalyses::new(fake(false));
        let n = Arc::new(AtomicUsize::new(0));
        let c = Arc::clone(&n);
        a.add_observer(Arc::new(move || {
            c.fetch_add(1, Ordering::SeqCst);
        }));
        a.prepare("/a.mp4", &opts(50.0));
        assert_eq!(wait(&a, "/a.mp4", &opts(50.0)), GyroState::Ready);
        std::thread::sleep(Duration::from_millis(20));
        assert_eq!(n.load(Ordering::SeqCst), 3);
    }

    /// Counts how many analyses run at once and how often each file is analysed; each takes `hold`.
    struct Counting {
        running: AtomicUsize,
        most: AtomicUsize,
        calls: Mutex<Vec<String>>,
        hold: Duration,
        fail_first: bool,
    }

    impl GyroBackend for Arc<Counting> {
        type Handle = String;
        fn analyze(
            &self,
            path: &Path,
            _: &GyroflowOptions,
            _: Option<&String>,
            _: &dyn Fn(f64),
        ) -> Result<String, GyroError> {
            let now = self.running.fetch_add(1, Ordering::SeqCst) + 1;
            self.most.fetch_max(now, Ordering::SeqCst);
            let first = {
                let mut c = self.calls.lock();
                c.push(path.display().to_string());
                c.len() == 1
            };
            std::thread::sleep(self.hold);
            self.running.fetch_sub(1, Ordering::SeqCst);
            if self.fail_first && first {
                return Err(GyroError("no gyro".into()));
            }
            Ok(path.display().to_string())
        }
    }

    fn counting(hold_ms: u64, fail_first: bool) -> Arc<Counting> {
        Arc::new(Counting {
            running: AtomicUsize::new(0),
            most: AtomicUsize::new(0),
            calls: Mutex::new(Vec::new()),
            hold: Duration::from_millis(hold_ms),
            fail_first,
        })
    }

    #[test]
    fn six_stabilized_clips_run_two_at_a_time_and_none_is_started_twice() {
        let c = counting(30, false);
        let a = GyroAnalyses::new(Arc::clone(&c)); // capacity 4 < 6 clips
        a.expect_keys(6);
        let names: Vec<String> = (0..6).map(|n| format!("/c{n}.mp4")).collect();
        for n in &names {
            a.prepare(n, &opts(50.0));
        }
        for n in &names {
            assert_eq!(wait(&a, n, &opts(50.0)), GyroState::Ready);
        }
        // Playback asks every frame: nothing is analysed again.
        for n in &names {
            assert!(a.get(n, &opts(50.0)).is_some());
        }
        std::thread::sleep(Duration::from_millis(60));
        assert!(c.most.load(Ordering::SeqCst) <= WORKERS, "at most {WORKERS} analyses run at once");
        assert_eq!(c.calls.lock().len(), 6, "each clip was analysed once");
        assert_eq!(a.len(), 6);
    }

    #[test]
    fn unfinished_analyses_are_never_evicted_and_the_front_of_the_queue_is_the_prioritized_clip() {
        let c = counting(40, false);
        let a = GyroAnalyses::with_capacity(Arc::clone(&c), 2);
        let names: Vec<String> = (0..6).map(|n| format!("/c{n}.mp4")).collect();
        for n in &names {
            a.prepare(n, &opts(50.0));
        }
        assert_eq!(a.len(), 6, "queued and running analyses stay over the capacity");
        a.prioritize("/c5.mp4", &opts(50.0)); // the playhead is near the last clip
        for n in &names {
            assert_eq!(wait(&a, n, &opts(50.0)), GyroState::Ready);
        }
        let calls = c.calls.lock().clone();
        assert_eq!(calls.len(), 6, "none restarted");
        let at = calls.iter().position(|c| c == "/c5.mp4");
        assert!(at <= Some(2), "at most the two already running go before the prioritized clip: {calls:?}");
    }

    #[test]
    fn analyze_again_after_a_failure_is_a_new_generation_and_ready_within_waits_again() {
        let c = counting(10, true);
        let a = GyroAnalyses::new(Arc::clone(&c));
        let o = opts(50.0);
        assert!(matches!(a.ready_within("/a.mp4", &o, Duration::from_secs(5)), GyroState::Failed(_)));
        let failed_generation = a.generation("/a.mp4", &o);
        a.prepare("/a.mp4", &o); // Analyze Again
        assert_ne!(a.generation("/a.mp4", &o), failed_generation);
        assert!(matches!(a.state("/a.mp4", &o), GyroState::Analysing(_)));
        assert_eq!(a.ready_within("/a.mp4", &o, Duration::from_secs(5)), GyroState::Ready);
    }

    #[test]
    fn an_unknown_idle_key_starts_and_counts_as_loading_but_a_canceled_one_stays_as_it_is() {
        let a = GyroAnalyses::new(fake(false));
        assert!(matches!(a.state("/a.mp4", &opts(50.0)), GyroState::Idle));
        // `ready_within` with no time: the first ask starts the analysis and reports it as running (never Ready).
        let s = a.ready_within("/a.mp4", &opts(50.0), Duration::ZERO);
        assert!(matches!(s, GyroState::Analysing(_) | GyroState::Ready), "{s:?}");
        let f = fake(false);
        let (tx, rx) = mpsc::channel();
        *f.gate.lock() = Some(rx);
        let b = GyroAnalyses::new(Arc::clone(&f));
        b.prepare("/b.mp4", &opts(50.0));
        b.cancel("/b.mp4", &opts(50.0));
        assert_eq!(b.ready_within("/b.mp4", &opts(50.0), Duration::ZERO), GyroState::Ready, "the user's choice");
        drop(tx);
    }

    struct Panicky;
    impl GyroBackend for Panicky {
        type Handle = String;
        fn analyze(
            &self,
            path: &Path,
            _: &GyroflowOptions,
            _: Option<&String>,
            _: &dyn Fn(f64),
        ) -> Result<String, GyroError> {
            assert!(!path.to_string_lossy().contains("bad"), "backend crash");
            Ok("fine".into())
        }
    }

    #[test]
    fn a_panicking_backend_fails_its_entry_and_keeps_the_worker_slots() {
        let a = GyroAnalyses::new(Panicky);
        // More crashes than workers: a leaked slot would leave the later ones Analysing forever.
        for n in 0..4 {
            a.prepare(&format!("/bad{n}.mp4"), &opts(50.0));
        }
        a.prepare("/good.mp4", &opts(50.0));
        for n in 0..4 {
            assert_eq!(wait(&a, &format!("/bad{n}.mp4"), &opts(50.0)), GyroState::Failed("analysis crashed".into()));
        }
        assert_eq!(wait(&a, "/good.mp4", &opts(50.0)), GyroState::Ready);
    }
}
