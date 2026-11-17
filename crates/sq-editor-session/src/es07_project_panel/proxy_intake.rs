//! Proxies at import and open where the Apple-only auto-proxy service is not built (Swift `ProxyIntake`): the session
//! hands over the project's media after every change (`SessionProxyServing::sync`). Each new or changed video file (path,
//! size, modification date) is probed once off the UI thread, warmed in the provider (so lookups find its ready proxy)
//! and, when `AutoProxyRule` asks for one, queued at background priority in timeline-first order (`ProxyOrdering`).
//! Removed files cancel their queued job. Mode `sq.proxy.mode` (per project, else the app setting); Off queues nothing.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use sq_core_model::{MediaRef, Timeline, VideoTrackInfo};
use sq_core_time::{Id, IdSource, Timestamp};
use sq_media::sample_index::SampleIndex;
use sq_proxy::auto_proxy::{AutoProxyRule, MachineProfile, ProxyDefaults, ProxyMode, ProxySettingsStore};
use sq_proxy::proxy_ordering::ProxyOrdering;
use sq_proxy::proxy_policy::{ProxyDecision, ProxyPolicy, SourceSeekInfo};
use sq_proxy::proxy_provider::ProxyProvider;
use sq_proxy::proxy_queue::{ProxyJobID, ProxyJobPriority, ProxyQueue};
use sq_runtime::{JoinHandle, WorkerPool, is_cancelled, sleep, spawn_local};

use crate::SessionProxyServing;

/// What the platform probe learns about one source file (demuxer index, track facts, decoder).
// Swift: ProxyIntake.swift:7
#[derive(Clone, Debug)]
pub struct ProxySourceProbe {
    // Swift: ProxyIntake.swift:8
    pub seek: SourceSeekInfo,
    // Swift: ProxyIntake.swift:9
    pub video: Option<VideoTrackInfo>,
    /// The GPU decodes the source (a long-GOP but light source still gets a proxy when it does not).
    // Swift: ProxyIntake.swift:11
    pub hardware_decode: bool,
    /// The proxy's frames can be the original's (`ProxyIntake::proxy_can_match` on the source index).
    // Swift: ProxyIntake.swift:13
    pub can_match: bool,
}

impl ProxySourceProbe {
    // Swift: ProxyIntake.swift:14
    pub fn new(seek: SourceSeekInfo, video: Option<VideoTrackInfo>, hardware_decode: bool, can_match: bool) -> Self {
        ProxySourceProbe { seek, video, hardware_decode, can_match }
    }
}

/// Probes one file off the UI thread (Swift `Probe`).
// Swift: ProxyIntake.swift:27
pub type ProxyProbe = Arc<dyn Fn(&Path) -> Option<ProxySourceProbe> + Send + Sync>;
/// The machine's profile for a source (`hardware_decode`).
pub type MachineFn = Arc<dyn Fn(bool) -> MachineProfile + Send + Sync>;

#[derive(Clone, Debug, PartialEq, Eq)]
struct FileKey {
    size: i64,
    modified: Option<SystemTime>,
}

fn key_of(path: &str) -> FileKey {
    match std::fs::metadata(path) {
        Ok(m) => FileKey { size: i64::try_from(m.len()).unwrap_or(-1), modified: m.modified().ok() },
        Err(_) => FileKey { size: -1, modified: None },
    }
}

#[derive(Default)]
struct State {
    project_id: Option<Id>,
    /// The Auto rule's answer per path.
    decisions: BTreeMap<String, ProxyDecision>,
    seen: BTreeMap<String, FileKey>,
    jobs: BTreeMap<String, ProxyJobID>,
    tasks: BTreeMap<String, (u64, JoinHandle<()>)>,
    /// Bumped after a file was warmed or its proxy job ended (the monitors redraw).
    changes: u64,
    next_token: u64,
}

/// Collaborators of the intake that tasks need after the probe.
struct Services {
    provider: Arc<ProxyProvider>,
    queue: Rc<RefCell<ProxyQueue>>,
    ids: Rc<RefCell<Box<dyn IdSource>>>,
    clock: Rc<dyn Fn() -> Timestamp>,
}

/// See the module docs. Lives on the UI thread; its probe tasks run on the UI executor and use the worker pool.
// Swift: ProxyIntake.swift:26
pub struct ProxyIntake<D: ProxyDefaults> {
    provider: Arc<ProxyProvider>,
    queue: Rc<RefCell<ProxyQueue>>,
    settings: ProxySettingsStore<D>,
    probe: ProxyProbe,
    machine: MachineFn,
    pool: Arc<WorkerPool>,
    ids: Rc<RefCell<Box<dyn IdSource>>>,
    clock: Rc<dyn Fn() -> Timestamp>,
    /// Off: files are probed and warmed but nothing is queued (headless checks time their own generation).
    automatic: bool,
    state: Rc<RefCell<State>>,
    /// The last `sync`, looked at again after `retarget`.
    last_media: Vec<MediaRef>,
    last_timeline: Option<Timeline>,
}

impl<D: ProxyDefaults> ProxyIntake<D> {
    // Swift: ProxyIntake.swift:51
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        provider: Arc<ProxyProvider>,
        queue: Rc<RefCell<ProxyQueue>>,
        settings: ProxySettingsStore<D>,
        automatic: bool,
        machine: MachineFn,
        probe: ProxyProbe,
        pool: Arc<WorkerPool>,
        ids: Box<dyn IdSource>,
        clock: Rc<dyn Fn() -> Timestamp>,
    ) -> ProxyIntake<D> {
        ProxyIntake {
            provider,
            queue,
            settings,
            probe,
            machine,
            pool,
            ids: Rc::new(RefCell::new(ids)),
            clock,
            automatic,
            state: Rc::new(RefCell::new(State::default())),
            last_media: Vec::new(),
            last_timeline: None,
        }
    }

    /// Off: files are probed and warmed but nothing is queued.
    // Swift: ProxyIntake.swift:36
    pub fn automatic(&self) -> bool {
        self.automatic
    }

    pub fn set_automatic(&mut self, on: bool) {
        self.automatic = on;
    }

    /// Bumped after a file was warmed or its proxy job ended (Swift `onChange`): the monitors redraw when it moves.
    // Swift: ProxyIntake.swift:38
    pub fn changes(&self) -> u64 {
        self.state.borrow().changes
    }

    /// A proxy can only be used when its frames are the original's: no hidden (edit-list, zero-duration) samples, which a
    /// transcode never carries.
    // Swift: ProxyIntake.swift:60
    pub fn proxy_can_match(index: &SampleIndex) -> bool {
        !index.entries().is_empty() && !index.entries().iter().any(|e| e.duration <= sq_core_time::Time::ZERO)
    }

    /// Paths with a probe or a proxy job still running.
    // Swift: ProxyIntake.swift:65
    pub fn pending(&self) -> BTreeSet<String> {
        self.state.borrow().tasks.keys().cloned().collect()
    }

    /// The Auto rule's answer per path.
    pub fn decisions(&self) -> BTreeMap<String, ProxyDecision> {
        self.state.borrow().decisions.clone()
    }

    /// Waits until every probe and queued job started so far has ended (tests, headless checks).
    // Swift: ProxyIntake.swift:68
    pub async fn settle(&self) {
        loop {
            let next = {
                let s = self.state.borrow();
                let first = s.tasks.keys().next().cloned();
                first.and_then(|k| s.tasks.get(&k).map(|(token, _)| (k, *token)))
            };
            let Some((path, token)) = next else { return };
            while self.state.borrow().tasks.get(&path).is_some_and(|(t, _)| *t == token) {
                if sleep(Duration::from_millis(5)).await.is_err() {
                    return;
                }
            }
        }
    }

    // Swift: ProxyIntake.swift:71
    pub fn sync_media(&mut self, media: &[MediaRef], project_id: Option<Id>, active_timeline: Option<&Timeline>) {
        self.state.borrow_mut().project_id = project_id;
        self.last_media = media.to_vec();
        self.last_timeline = active_timeline.cloned();
        let mode = self.settings.mode(project_id);
        let wanted: Vec<&MediaRef> =
            media.iter().filter(|m| m.info.as_ref().is_none_or(|i| !i.is_still && i.video.is_some())).collect();
        let paths: BTreeSet<&str> = wanted.iter().map(|m| m.path.as_str()).collect();
        {
            let mut s = self.state.borrow_mut();
            let gone: Vec<String> = s.jobs.keys().filter(|p| !paths.contains(p.as_str())).cloned().collect();
            for path in gone {
                if let Some(job) = s.jobs.remove(&path) {
                    self.queue.borrow_mut().cancel(job);
                }
            }
            let gone: Vec<String> = s.seen.keys().filter(|p| !paths.contains(p.as_str())).cloned().collect();
            for path in gone {
                s.seen.remove(&path);
                if let Some((_, task)) = s.tasks.remove(&path) {
                    task.cancel();
                }
            }
        }
        let first_use = ProxyOrdering::first_use(active_timeline);
        let ids: Vec<Id> = wanted.iter().map(|m| m.id).collect();
        let by_id: BTreeMap<Id, &MediaRef> = wanted.iter().rev().map(|m| (m.id, *m)).collect();
        for id in ProxyOrdering::sorted(&ids, &first_use) {
            let Some(r) = by_id.get(&id) else { continue };
            let key = key_of(&r.path);
            {
                let mut s = self.state.borrow_mut();
                if s.seen.get(&r.path) == Some(&key) {
                    continue;
                }
                s.seen.insert(r.path.clone(), key);
                if let Some((_, task)) = s.tasks.remove(&r.path) {
                    task.cancel();
                }
                if let Some(old) = s.jobs.remove(&r.path) {
                    self.queue.borrow_mut().cancel(old);
                }
            }
            self.start(&r.path, mode);
        }
    }

    fn start(&mut self, path: &str, mode: ProxyMode) {
        let token = {
            let mut s = self.state.borrow_mut();
            s.next_token += 1;
            s.next_token
        };
        let services = Services {
            provider: Arc::clone(&self.provider),
            queue: Rc::clone(&self.queue),
            ids: Rc::clone(&self.ids),
            clock: Rc::clone(&self.clock),
        };
        let (probe, machine, pool) = (Arc::clone(&self.probe), Arc::clone(&self.machine), Arc::clone(&self.pool));
        let (state, automatic, path_owned) = (Rc::clone(&self.state), self.automatic, path.to_string());
        let handle = spawn_local({
            let state = Rc::clone(&state);
            let path = path_owned.clone();
            async move {
                // Runs when the task ends or is canceled (Swift `defer`).
                let _end = TaskEnd { state: Rc::clone(&state), path: path.clone(), token };
                run_task(&state, &services, &probe, &machine, &pool, &path, mode, automatic).await;
            }
        });
        state.borrow_mut().tasks.insert(path_owned, (token, handle));
    }

    /// Preferences > Cache Folder moved: proxies come from `provider` and are made by `queue` from now on. Every probe and
    /// job of the old pair is canceled (the old queue is left held, its files stay), and the media of the last sync is
    /// probed, warmed and queued again against the new folder.
    // Swift: ProxyIntake.swift:123
    pub fn retarget(&mut self, provider: Arc<ProxyProvider>, queue: Rc<RefCell<ProxyQueue>>) {
        if Arc::ptr_eq(&provider, &self.provider) {
            return;
        }
        {
            let mut s = self.state.borrow_mut();
            for (_, t) in s.tasks.values() {
                t.cancel();
            }
            s.tasks.clear();
            s.jobs.clear();
            s.seen.clear();
        }
        {
            let mut old = self.queue.borrow_mut();
            old.set_held(true);
            old.cancel_all();
        }
        self.provider = provider;
        self.queue = queue;
        let (media, timeline) = (self.last_media.clone(), self.last_timeline.clone());
        let project = self.state.borrow().project_id;
        self.sync_media(&media, project, timeline.as_ref());
        self.state.borrow_mut().changes += 1;
    }
}

/// Removes a finished or canceled task from the table and tells the monitors to redraw.
struct TaskEnd {
    state: Rc<RefCell<State>>,
    path: String,
    token: u64,
}

impl Drop for TaskEnd {
    fn drop(&mut self) {
        if let Ok(mut s) = self.state.try_borrow_mut() {
            if s.tasks.get(&self.path).is_some_and(|(t, _)| *t == self.token) {
                s.tasks.remove(&self.path);
            }
            s.changes += 1;
        }
    }
}

/// The body of one probe task: probe, decide, warm and, when asked for, queue and wait for the proxy job.
#[allow(clippy::too_many_arguments)]
async fn run_task(
    state: &Rc<RefCell<State>>,
    services: &Services,
    probe: &ProxyProbe,
    machine: &MachineFn,
    pool: &Arc<WorkerPool>,
    path: &str,
    mode: ProxyMode,
    automatic: bool,
) {
    let url = PathBuf::from(path);
    let probe = Arc::clone(probe);
    let probe_url = url.clone();
    let Ok(Some(p)) = pool.run(move |_| probe(&probe_url)).await else { return };
    if is_cancelled() {
        return;
    }
    let decision = AutoProxyRule::decide(
        &p.seek,
        p.video.as_ref(),
        mode,
        &machine(p.hardware_decode),
        !p.hardware_decode,
        &ProxyPolicy::default(),
    );
    state.borrow_mut().decisions.insert(path.to_string(), decision);
    let provider = Arc::clone(&services.provider);
    let warm_url = url.clone();
    let _ = pool.run(move |_| provider.warm(&warm_url)).await;
    let ProxyDecision::NeedsProxy(kind) = decision else { return };
    if is_cancelled() || !automatic || !p.can_match {
        return;
    }
    if services.provider.cached_lookup(&url, &[kind], (services.clock)()).is_some() {
        return;
    }
    let id = {
        let mut ids = services.ids.borrow_mut();
        match services.queue.borrow_mut().enqueue(
            &url,
            kind,
            ProxyJobPriority::Background,
            ProxyQueue::UNRANKED,
            &mut **ids,
            (services.clock)(),
        ) {
            Ok(id) => id,
            Err(_) => return,
        }
    };
    if is_cancelled() {
        services.queue.borrow_mut().cancel(id); // retargeted while it was queued
        return;
    }
    state.borrow_mut().jobs.insert(path.to_string(), id);
    // shortcut: polls the queue every 100 ms for the job's end (Swift awaits the update stream); upgrade with a waker on
    // `ProxyQueue::updates_for` when the queue gets an async-friendly channel.
    while !services.queue.borrow().info(id).is_none_or(|i| i.state.is_terminal()) {
        if sleep(Duration::from_millis(100)).await.is_err() {
            return;
        }
    }
    {
        let mut s = state.borrow_mut();
        if s.jobs.get(path) == Some(&id) {
            s.jobs.remove(path);
        }
    }
    let provider = Arc::clone(&services.provider);
    let _ = pool.run(move |_| provider.warm(&url)).await;
}

impl<D: ProxyDefaults> SessionProxyServing for ProxyIntake<D> {
    fn project_id(&self) -> Option<Id> {
        self.state.borrow().project_id
    }

    fn sync(&mut self, media: &[MediaRef], project_id: Option<Id>, active_timeline: Option<&Timeline>) {
        self.sync_media(media, project_id, active_timeline);
    }

    /// The engines look proxies up themselves (the Windows Program engine through its proxy service).
    // Swift: ProxyIntake.swift:142
    fn take_effects(&mut self) -> Vec<crate::ProxyEffect> {
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use serde_json::json;
    use sq_core_model::{MediaFingerprint, MediaInfo};
    use sq_core_time::{SequentialIds, Time};
    use sq_media::sample_index::Entry;
    use sq_proxy::proxy_cache::ProxyCache;
    use sq_runtime::testing::Rt;

    use super::*;

    #[derive(Default)]
    struct MemoryDefaults(BTreeMap<String, String>);

    impl ProxyDefaults for MemoryDefaults {
        fn string(&self, key: &str) -> Option<String> {
            self.0.get(key).cloned()
        }
        fn bool(&self, key: &str) -> bool {
            self.0.get(key).is_some_and(|v| v == "true")
        }
        fn set_string(&mut self, key: &str, value: &str) {
            self.0.insert(key.into(), value.into());
        }
        fn set_bool(&mut self, key: &str, value: bool) {
            self.0.insert(key.into(), value.to_string());
        }
        fn remove(&mut self, key: &str) {
            self.0.remove(key);
        }
    }

    fn video() -> VideoTrackInfo {
        serde_json::from_value(
            json!({"width": 3840, "height": 2160, "codec": "hevc", "bitDepth": 10, "chroma": "4:2:0",
            "nominalFrameDuration": {"value": 1, "timescale": 25}, "isVariableFrameRate": false}),
        )
        .expect("video")
    }

    fn source(dir: &Path, n: u128, name: &str) -> MediaRef {
        let path = dir.join(name);
        std::fs::write(&path, vec![n as u8; 5000]).expect("write source");
        let mut m = MediaRef::new(Id::from_u128(n), name, &path.to_string_lossy(), MediaFingerprint::new(5000));
        m.info = Some(
            serde_json::from_value::<MediaInfo>(json!({"duration": {"value": 100, "timescale": 1}, "video": video()}))
                .expect("info"),
        );
        m
    }

    struct Rig {
        rt: Rt,
        dir: PathBuf,
        intake: ProxyIntake<MemoryDefaults>,
        queue: Rc<RefCell<ProxyQueue>>,
        probed: Arc<std::sync::Mutex<Vec<String>>>,
    }

    fn rig(mode: &str) -> Rig {
        let rt = Rt::manual();
        let dir = std::env::temp_dir().join(format!("sq-es07-intake-{mode}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let cache = Arc::new(ProxyCache::new(dir.join("cache")));
        let queue = Rc::new(RefCell::new(ProxyQueue::new(Arc::clone(&cache), 1)));
        let provider = Arc::new(ProxyProvider::with_interlaced(cache, Box::new(|_| false)));
        let mut defaults = MemoryDefaults::default();
        defaults.set_string(ProxySettingsStore::<MemoryDefaults>::MODE_KEY, mode);
        let probed = Arc::new(std::sync::Mutex::new(Vec::new()));
        let log = Arc::clone(&probed);
        let probe: ProxyProbe = Arc::new(move |p| {
            log.lock().expect("log").push(p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default());
            Some(ProxySourceProbe::new(SourceSeekInfo::new("hvc1", Some(250)), Some(video()), false, true))
        });
        let machine: MachineFn =
            Arc::new(|hw| MachineProfile { memory_bytes: 32 << 30, cores: 16, is_apple_silicon: hw });
        let intake = ProxyIntake::new(
            provider,
            Rc::clone(&queue),
            ProxySettingsStore::new(defaults),
            true,
            machine,
            probe,
            Arc::clone(&rt.pool),
            Box::new(SequentialIds::default()),
            Rc::new(|| Timestamp::from_reference_seconds(0.0)),
        );
        Rig { rt, dir, intake, queue, probed }
    }

    #[test]
    fn proxy_can_match_needs_visible_samples_only() {
        let t = |n| Time::new(n, 25);
        let e = |i: i64, d: i64| Entry { pts: t(i), dts: t(i), duration: t(d), is_sync: i == 0, decode_ordinal: i };
        assert!(ProxyIntake::<MemoryDefaults>::proxy_can_match(&SampleIndex::new(vec![e(0, 1), e(1, 1)])));
        assert!(!ProxyIntake::<MemoryDefaults>::proxy_can_match(&SampleIndex::new(vec![e(0, 0), e(1, 1)])));
        assert!(!ProxyIntake::<MemoryDefaults>::proxy_can_match(&SampleIndex::new(vec![])));
    }

    #[test]
    fn sync_probes_each_file_once_and_queues_heavy_sources() {
        let mut r = rig("auto");
        let media = vec![source(&r.dir, 1, "a.mov"), source(&r.dir, 2, "b.mov")];
        r.intake.sync(&media, None, None);
        r.rt.run_until_stalled();
        assert_eq!(r.probed.lock().expect("log").len(), 2);
        assert_eq!(r.intake.decisions().len(), 2);
        assert!(r.intake.decisions().values().all(ProxyDecision::needs_proxy));
        assert_eq!(r.queue.borrow().all_jobs().len(), 2);
        r.intake.sync(&media, None, None); // unchanged files are not probed again
        r.rt.run_until_stalled();
        assert_eq!(r.probed.lock().expect("log").len(), 2);
        // Removed media cancels its queued job and its task.
        r.intake.sync(&media[..1], None, None);
        r.rt.run_until_stalled();
        assert_eq!(r.intake.pending().len(), 1);
        assert!(r.intake.changes() > 0); // the canceled task ended
        let jobs = r.queue.borrow().all_jobs();
        assert_eq!(jobs.iter().filter(|j| j.state.is_terminal()).count(), 1);
    }

    #[test]
    fn off_mode_probes_but_queues_nothing() {
        let mut r = rig("off");
        r.intake.sync(&[source(&r.dir, 3, "c.mov")], None, None);
        r.rt.run_until_stalled();
        assert_eq!(r.probed.lock().expect("log").len(), 1);
        assert!(r.queue.borrow().all_jobs().is_empty());
        assert!(r.intake.pending().is_empty());
    }
}
