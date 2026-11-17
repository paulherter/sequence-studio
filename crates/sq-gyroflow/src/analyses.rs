//! The driver of `SQAnalysis/GyroflowEngine.swift` without the Metal parts: one analysis per (file, options) running on a
//! background thread (open, smooth), the last `capacity` kept (the newest finished one of each file always stays, so
//! playback keeps showing it while a slider drag smooths new options), the state the Analyze row shows, cancel and retry.

use crate::file::{GyroError, GyroFile};
use parking_lot::Mutex;
use sq_core_masks::stabilize_effect::GyroflowOptions;
use std::collections::HashMap;
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
}

struct Inner<H> {
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

    /// The entry of `key`, started when new. `explicit`: also a canceled key starts again.
    fn touch(&self, key: &AnalysisKey, options: &GyroflowOptions, explicit: bool) -> Option<Arc<Entry<B::Handle>>> {
        let (entry, donor) = {
            let mut i = self.inner.lock();
            if !explicit && i.held.contains(key) {
                return None;
            }
            i.order.retain(|k| k != key);
            i.order.push(key.clone());
            if let Some(e) = i.entries.get(key) {
                return Some(Arc::clone(e));
            }
            let entry = Arc::new(Entry {
                state: Mutex::new(GyroState::Analysing(0.0)),
                handle: Mutex::new(None),
                cancelled: AtomicBool::new(false),
            });
            // A finished analysis of the same file lends its file data: the new options smooth a copy.
            let donor = i
                .entries
                .iter()
                .find(|(k, e)| k.path == key.path && e.handle.lock().is_some())
                .and_then(|(_, e)| e.handle.lock().clone());
            i.entries.insert(key.clone(), Arc::clone(&entry));
            let keep = i.last_ready.get(&key.path).cloned();
            while i.order.len() > self.capacity {
                let Some(at) = i.order.iter().position(|k| Some(k) != keep.as_ref() && k != key) else { break };
                let old = i.order.remove(at);
                i.entries.remove(&old);
            }
            (entry, donor)
        };
        let (backend, inner, observers) =
            (Arc::clone(&self.backend), Arc::clone(&self.inner), Arc::clone(&self.observers));
        let (path, options, key) = (key.path.clone(), *options, key.clone());
        let job = Arc::clone(&entry);
        let notify = move || {
            let list: Vec<_> = observers.lock().clone();
            for f in list {
                f();
            }
        };
        notify();
        std::thread::spawn(move || {
            let step = |p: f64| {
                if !job.cancelled.load(Ordering::Acquire) {
                    *job.state.lock() = GyroState::Analysing(p);
                    notify();
                }
            };
            let result = backend.analyze(Path::new(&path), &options, donor.as_deref(), &step);
            if job.cancelled.load(Ordering::Acquire) {
                return;
            }
            match result {
                Ok(h) => {
                    *job.handle.lock() = Some(Arc::new(h));
                    *job.state.lock() = GyroState::Ready;
                    inner.lock().last_ready.insert(key.path.clone(), key);
                }
                Err(e) => *job.state.lock() = GyroState::Failed(e.0),
            }
            notify();
        });
        Some(entry)
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

    fn wait(a: &GyroAnalyses<Arc<Fake>>, path: &str, o: &GyroflowOptions) -> GyroState {
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
        let _ = tx.send(());
        assert!(a.get("/a.mp4", &opts(50.0)).is_none());
        assert_eq!(a.state("/a.mp4", &opts(50.0)), GyroState::Idle, "playback's ask does not start a canceled key");
        a.prepare("/a.mp4", &opts(50.0));
        assert!(matches!(a.state("/a.mp4", &opts(50.0)), GyroState::Analysing(_)), "Analyze starts it again");
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
}
