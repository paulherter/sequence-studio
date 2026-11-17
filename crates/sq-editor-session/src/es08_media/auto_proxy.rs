// Swift: AutoProxy.swift
//! W9.9 AutoProxy: generates proxies of heavy long-GOP sources in the background (one at a time, background priority)
//! and points the monitors at them (scrubbing; playback too on a weak machine or with the playback setting on). Paused
//! frames and export always read the originals: proxies are only reachable through
//! [`ProjectMediaResolver::proxy_demuxer`], which only the playback engines call. Mode and playback setting live in the
//! app's settings store ([`ProxySettingsStore`]), so the project file is unchanged.
//!
//! The service is a state machine the UI thread drives; the blocking parts run elsewhere:
//! - [`AutoProxyService::sync`] decides which media need a decision and queues [`ProxyDecisionWork`] items
//!   ([`AutoProxyService::take_decision_work`]); a worker runs each ([`ProxyDecisionWork::run`]) and the result goes
//!   back with [`AutoProxyService::decision_finished`].
//! - Transcodes are the queue's: [`AutoProxyService::take_started_jobs`], run them on workers, report each with
//!   [`AutoProxyService::complete_job`].
//! - [`AutoProxyService::tick`] (about every 500 ms while [`AutoProxyService::wants_tick`]) reads queue and cache
//!   updates and the busy signal.
//! - What the monitors must be told ([`ProxyEffect`]) is read with [`AutoProxyService::take_effects`]: the session owns
//!   every engine (the Program engine and the auxiliary ones), so it applies them (Swift held weak engines here).

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc::Receiver;

use sq_core_model::{MediaRef, Timeline, VideoTrackInfo};
use sq_core_time::{Id, IdSource, Time, Timestamp};
use sq_media::sample_index::SampleIndex;
use sq_proxy::auto_proxy::{
    AutoProxyRule, MachineProfile, ProxyDefaults, ProxyDiskGuard, ProxyMode, ProxyPlaybackMode, ProxySettingsStore,
    ProxySizeEstimate,
};
use sq_proxy::model::{ProxyKind, ProxyRecord};
use sq_proxy::proxy_cache::{ProxyCache, ProxyRecordID};
use sq_proxy::proxy_ordering::ProxyOrdering;
use sq_proxy::proxy_policy::{ProxyDecision, ProxyPolicy, SkipReason, SourceSeekProbing};
use sq_proxy::proxy_provider::ProxyProvider;
use sq_proxy::proxy_queue::{
    JobError, ProxyJobID, ProxyJobInfo, ProxyJobPriority, ProxyJobState, ProxyQueue, StartedJob,
};
use sq_runtime::proxy_state::{ProxyEvent, ProxyState};

use crate::{ProjectMediaResolver, ProxyUse, SessionProxyServing};

/// What a proxy decision was made for; a different path, size or modification date starts over, and so does the item's
/// Deinterlace switch (`keeps_fields`: interlaced with Deinterlace off, which gets and uses no proxy).
#[derive(Clone, Debug, PartialEq)]
struct FileState {
    path: String,
    size: i64,
    modified: Option<Timestamp>,
    keeps_fields: bool,
}

impl FileState {
    fn read(path: &str) -> FileState {
        let meta = std::fs::metadata(path).ok();
        FileState {
            path: path.to_string(),
            size: meta.as_ref().and_then(|m| i64::try_from(m.len()).ok()).unwrap_or(0),
            modified: meta
                .and_then(|m| m.modified().ok())
                .and_then(|m| m.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| Timestamp::from_unix_seconds(d.as_secs_f64())),
            keeps_fields: false,
        }
    }
}

#[derive(Clone, Debug)]
struct Tracked {
    file: FileState,
    /// Which decision this entry waits for (a stale answer is dropped).
    ticket: u64,
    /// The one lifecycle (decision, job, ready record, capped, disk refused...): see [`ProxyState`].
    state: ProxyState<ProxyJobID, ProxyRecordID>,
    /// Estimated bytes of this media's queued or running proxy, held against the disk reserve until it is ready.
    reserved_bytes: i64,
    /// No hardware decoder for the source on this machine: its job runs ahead of the others.
    software: bool,
}

impl Tracked {
    fn new(file: FileState, ticket: u64) -> Tracked {
        Tracked { file, ticket, state: ProxyState::NotNeeded, reserved_bytes: 0, software: false }
    }
}

/// What the monitors must be told after a sync or a proxy change.
#[derive(Clone, Debug, PartialEq)]
pub enum ProxyEffect {
    /// Every engine uses proxies like this (scrubbing always; playback on a weak machine or by setting).
    UseChanged(ProxyUse),
    /// The proxies of these media changed or went away: engines drop frames and decoders, the resolver reopens them.
    ProxiesChanged(BTreeSet<Id>),
}

/// The disk reading of the cache volume.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DiskSpace {
    pub free: Option<i64>,
    pub total: Option<i64>,
}

/// Free and total bytes of the proxy cache's volume (`ProxyDiskGuard`); injected by tests.
pub type DiskSpaceReader = Arc<dyn Fn(&Path) -> DiskSpace + Send + Sync>;

/// What a worker found out about one media.
#[derive(Clone, Debug, PartialEq)]
pub enum ProxyOutcome {
    /// No proxy is made (probe failed, light source, edit list, mode off...).
    Skipped,
    /// A proxy of the current file is in the cache already.
    Ready { record: Option<ProxyRecordID> },
    /// A job is needed.
    NeedsJob { kind: ProxyKind, software: bool, estimate: i64, disk: DiskSpace },
}

/// The blocking half of a decision, for a worker: probe the source, apply the rule, open the original, warm the
/// fingerprint, look in the cache, read the disk.
pub struct ProxyDecisionWork {
    pub media: Id,
    ticket: u64,
    file: FileState,
    video: Option<VideoTrackInfo>,
    duration: Time,
    mode: ProxyMode,
    machine: MachineProfile,
    prober: Arc<dyn SourceSeekProbing>,
    resolver: Arc<ProjectMediaResolver>,
    provider: Arc<ProxyProvider>,
    disk_space: DiskSpaceReader,
    cache_dir: PathBuf,
    disk_hint: Option<DiskSpace>,
    now: Timestamp,
}

impl ProxyDecisionWork {
    /// Runs the decision (blocking; file reads).
    pub fn run(&self) -> ProxyOutcome {
        let path = Path::new(&self.file.path);
        let Ok(seek) = self.prober.probe(path) else { return ProxyOutcome::Skipped };
        let policy = ProxyPolicy::default();
        let video = self.video.as_ref();
        let mut decision = AutoProxyRule::decide(&seek, video, self.mode, &self.machine, false, &policy);
        let mut software = false;
        if decision == ProxyDecision::Skip(SkipReason::LightSource) {
            // Long-GOP but light: still worth a proxy when this machine decodes it in software.
            if self.resolver.opened_demuxer(self.media).is_none() {
                return ProxyOutcome::Skipped;
            }
            software = self.resolver.decodes_in_hardware(self.media) == Some(false);
            if software {
                decision = AutoProxyRule::decide(&seek, video, self.mode, &self.machine, true, &policy);
            }
        }
        let ProxyDecision::NeedsProxy(kind) = decision else { return ProxyOutcome::Skipped };
        let Some(original) = self.resolver.opened_demuxer(self.media) else { return ProxyOutcome::Skipped };
        if !AutoProxyService::<NoDefaults>::proxy_can_match(original.index()) {
            return ProxyOutcome::Skipped;
        }
        // Fingerprint of the current file, for the stat-only lookup.
        self.provider.warm(path);
        if let Some(hit) = self.provider.cached_lookup(path, &ProxyProvider::SCRUB_PREFERENCE, self.now) {
            return ProxyOutcome::Ready { record: hit.record };
        }
        let estimate = ProxySizeEstimate::bytes(
            kind,
            video.map_or(0, |v| v.width),
            video.map_or(0, |v| v.height),
            video.map_or(Time::new(1, 30), |v| v.nominal_frame_duration),
            self.duration,
        );
        let disk = self.disk_hint.unwrap_or_else(|| (self.disk_space)(&self.cache_dir));
        ProxyOutcome::NeedsJob { kind, software, estimate, disk }
    }
}

/// A [`ProxyDefaults`] that stores nothing, only to name the service's associated functions.
struct NoDefaults;

impl ProxyDefaults for NoDefaults {
    fn string(&self, _key: &str) -> Option<String> {
        None
    }
    fn bool(&self, _key: &str) -> bool {
        false
    }
    fn set_string(&mut self, _key: &str, _value: &str) {}
    fn set_bool(&mut self, _key: &str, _value: bool) {}
    fn remove(&mut self, _key: &str) {}
}

/// The collaborators of the service besides the cache and the settings.
pub struct AutoProxyDeps {
    pub resolver: Arc<ProjectMediaResolver>,
    pub prober: Arc<dyn SourceSeekProbing>,
    pub machine: MachineProfile,
    /// Transcodes at once (`WorkLimits.proxy_transcodes`).
    pub concurrency: usize,
    /// True while a monitor plays or an export runs.
    pub is_busy: Box<dyn Fn() -> bool>,
    /// How long the machine must be idle before held jobs resume, in seconds.
    pub busy_resume: f64,
    pub disk_space: DiskSpaceReader,
    pub clock: Box<dyn Fn() -> Timestamp>,
    pub ids: Box<dyn IdSource>,
}

/// W9.9 AutoProxy (Swift `AutoProxyService`).
pub struct AutoProxyService<D: ProxyDefaults> {
    // Swift: AutoProxy.swift:17
    pub cache: Arc<ProxyCache>,
    // Swift: AutoProxy.swift:18
    pub queue: ProxyQueue,
    // Swift: AutoProxy.swift:19
    pub provider: Arc<ProxyProvider>,
    // Swift: AutoProxy.swift:20
    pub settings: ProxySettingsStore<D>,
    // Swift: AutoProxy.swift:21
    pub machine: MachineProfile,
    resolver: Arc<ProjectMediaResolver>,
    prober: Arc<dyn SourceSeekProbing>,
    disk_space: DiskSpaceReader,
    is_busy: Box<dyn Fn() -> bool>,
    busy_resume: f64,
    clock: Box<dyn Fn() -> Timestamp>,
    ids: Box<dyn IdSource>,
    busy_held: bool,
    idle_since: Option<Timestamp>,
    /// Queue start order per media (timeline-first, `ProxyOrdering`).
    ranks: BTreeMap<Id, i64>,
    tracked: BTreeMap<Id, Tracked>,
    next_ticket: u64,
    disk_sample: Option<(Timestamp, DiskSpace)>,
    last_media: Vec<MediaRef>,
    last_project: Option<Id>,
    last_timeline: Option<Timeline>,
    mode: ProxyMode,
    /// The playback setting last applied (with `mode`), to tell a real settings change from any other write.
    applied_playback: ProxyPlaybackMode,
    is_held: bool,
    queue_held: bool,
    work: Vec<ProxyDecisionWork>,
    effects: Vec<ProxyEffect>,
    updates: Receiver<ProxyJobInfo>,
    removals: Receiver<ProxyRecord>,
}

impl<D: ProxyDefaults> AutoProxyService<D> {
    /// The app's service: the proxy cache sits in `directory`; the machine, the settings and the transcode limit are the
    /// caller's (Swift defaults: `MachineProfile.current`, `ProxySettingsStore()`, `WorkLimits.current`).
    // Swift: AutoProxy.swift:119
    pub fn make(directory: PathBuf, settings: ProxySettingsStore<D>, deps: AutoProxyDeps) -> AutoProxyService<D> {
        AutoProxyService::new(Arc::new(ProxyCache::new(directory)), settings, deps)
    }

    /// Seconds a disk reading is reused.
    const DISK_SAMPLE_TTL: f64 = 5.0;

    /// A service over `cache`; the proxy lookup of the resolver points at the cache (stat only: a source whose size or
    /// date changed has no proxy until its new fingerprint is computed).
    // Swift: AutoProxy.swift:80
    pub fn new(cache: Arc<ProxyCache>, settings: ProxySettingsStore<D>, deps: AutoProxyDeps) -> AutoProxyService<D> {
        let provider = Arc::new(ProxyProvider::new(Arc::clone(&cache)));
        let lookup_provider = Arc::clone(&provider);
        let clock_now = (deps.clock)();
        let _ = clock_now;
        deps.resolver.set_proxy_lookup(Some(Arc::new(move |_media, path| {
            lookup_provider
                .cached_lookup(
                    Path::new(path),
                    &ProxyProvider::SCRUB_PREFERENCE,
                    Timestamp::from_unix_seconds(now_unix()),
                )
                .map(|l| l.url)
        })));
        let mut queue = ProxyQueue::new(Arc::clone(&cache), deps.concurrency);
        queue.start(); // stale partials, cache cap
        let updates = queue.updates();
        let removals = cache.removed_records();
        AutoProxyService {
            cache,
            queue,
            provider,
            settings,
            machine: deps.machine,
            resolver: deps.resolver,
            prober: deps.prober,
            disk_space: deps.disk_space,
            is_busy: deps.is_busy,
            busy_resume: deps.busy_resume,
            clock: deps.clock,
            ids: deps.ids,
            busy_held: false,
            idle_since: None,
            ranks: BTreeMap::new(),
            tracked: BTreeMap::new(),
            next_ticket: 0,
            disk_sample: None,
            last_media: Vec::new(),
            last_project: None,
            last_timeline: None,
            mode: ProxyMode::Auto,
            applied_playback: ProxyPlaybackMode::Auto,
            is_held: false,
            queue_held: false,
            work: Vec::new(),
            effects: Vec::new(),
            updates,
            removals,
        }
    }

    /// The mode last applied.
    pub fn mode(&self) -> ProxyMode {
        self.mode
    }

    /// Thermal pressure or Low Power Mode: no new proxy job starts (a running one finishes).
    // Swift: AutoProxy.swift:112
    pub fn set_held(&mut self, held: bool) {
        if held == self.is_held {
            return;
        }
        self.is_held = held;
        self.apply_hold();
    }

    /// Whether thermal pressure or Low Power Mode hold the queue.
    pub fn is_held(&self) -> bool {
        self.is_held
    }

    /// Settings > Media > Cache Size: sets the proxy cache cap and evicts least-recently-used proxies down to it at once.
    /// Proxies in use by a monitor are never evicted (the cap may then stay exceeded). Returns the evicted records.
    // Swift: AutoProxy.swift:126
    pub fn apply_cache_cap(&mut self, bytes: i64) -> Vec<ProxyRecord> {
        let capped = bytes.max(0);
        if self.cache.settings().cache_cap_bytes != capped {
            let _ = self.cache.update_settings(|s| s.cache_cap_bytes = capped);
        }
        let removed = self.cache.enforce_cap(&BTreeSet::new());
        self.refresh();
        removed
    }

    /// Settings > Media > Delete Cache: removes every proxy that no monitor is using, returns the bytes freed.
    // Swift: AutoProxy.swift:136
    pub fn clear_cache(&mut self) -> i64 {
        let before = self.cache.total_size();
        self.cache.evict(0, &BTreeSet::new());
        before - self.cache.total_size()
    }

    /// The queue is held for thermal pressure / Low Power Mode, or while a monitor plays or an export runs.
    fn apply_hold(&mut self) {
        let hold = self.is_held || self.busy_held;
        if hold == self.queue_held {
            return;
        }
        self.queue_held = hold;
        self.queue.set_held(hold);
    }

    /// True while jobs wait for playback or export to end (tests, debug HUD).
    // Swift: AutoProxy.swift:154
    pub fn is_busy_held(&self) -> bool {
        self.busy_held
    }

    /// One reading of the busy signal: busy holds at once; idle releases after `busy_resume` without interruption. A
    /// running transcode always finishes (same rule as the thermal hold).
    pub(crate) fn poll_busy(&mut self) {
        if (self.is_busy)() {
            self.idle_since = None;
            if !self.busy_held {
                self.busy_held = true;
                self.apply_hold();
            }
        } else if self.busy_held {
            let now = (self.clock)();
            let since = *self.idle_since.get_or_insert(now);
            if now.unix_seconds() - since.unix_seconds() >= self.busy_resume {
                self.busy_held = false;
                self.idle_since = None;
                self.apply_hold();
            }
        }
    }

    /// Any tracked media still has a live decision or a queued/running job: a playback or export that starts now must
    /// still be seen (probe, warm and enqueue happen before `job` is set).
    pub(crate) fn needs_busy_polling(&self) -> bool {
        self.tracked.values().any(|t| t.state.is_active())
    }

    /// Whether the host should call [`AutoProxyService::tick`] (about every 500 ms).
    pub fn wants_tick(&self) -> bool {
        self.needs_busy_polling() || self.busy_held
    }

    /// One poll: the busy signal, then the queue's and the cache's news.
    pub fn tick(&mut self) {
        self.poll_busy();
        while let Ok(info) = self.updates.try_recv() {
            self.job_updated(&info);
        }
        while let Ok(record) = self.removals.try_recv() {
            self.removed(&record);
        }
    }

    /// Media ids with a ready proxy (tests, debug HUD).
    // Swift: AutoProxy.swift:191
    pub fn ready_media(&self) -> BTreeSet<Id> {
        self.tracked.iter().filter(|(_, t)| t.state.is_ready()).map(|(id, _)| *id).collect()
    }

    /// Media with a proxy job queued or running.
    // Swift: AutoProxy.swift:193
    pub fn pending_media(&self) -> BTreeSet<Id> {
        self.tracked.iter().filter(|(_, t)| t.state.job().is_some()).map(|(id, _)| *id).collect()
    }

    /// Media not generated because of the disk reserve (until `refresh()`).
    // Swift: AutoProxy.swift:195
    pub fn disk_refused_media(&self) -> BTreeSet<Id> {
        self.tracked.iter().filter(|(_, t)| t.state == ProxyState::DiskRefused).map(|(id, _)| *id).collect()
    }

    /// Bytes held against the disk reserve by queued and running proxies.
    pub(crate) fn reserved_disk_bytes(&self) -> i64 {
        self.tracked.values().filter(|t| !t.state.is_ready()).map(|t| t.reserved_bytes).sum()
    }

    /// The project last synced.
    // Swift: AutoProxy.swift:225
    pub fn project_id(&self) -> Option<Id> {
        self.last_project
    }

    /// Called with the project's media after every change (and on open). New or changed video sources are decided and,
    /// when the rule says so, queued; removed ones are canceled; a changed source drops its old proxy at once.
    // Swift: AutoProxy.swift:229
    pub fn sync(&mut self, media: &[MediaRef], project_id: Option<Id>, active_timeline: Option<&Timeline>) {
        self.last_media = media.to_vec();
        self.last_project = project_id;
        self.last_timeline = active_timeline.cloned();
        self.mode = self.settings.mode(project_id);
        self.applied_playback = self.settings.playback();
        let use_ = if self.mode == ProxyMode::Off {
            ProxyUse::OFF
        } else {
            ProxyUse {
                scrubbing: true,
                playback: AutoProxyRule::uses_proxies_for_playback(self.applied_playback, &self.machine),
            }
        };
        self.effects.push(ProxyEffect::UseChanged(use_));
        let mut invalid: BTreeSet<Id> = BTreeSet::new();
        let wanted: Vec<&MediaRef> = if self.mode == ProxyMode::Off {
            Vec::new()
        } else {
            media.iter().filter(|m| m.info.as_ref().is_none_or(|i| !i.is_still && i.video.is_some())).collect()
        };
        let keep: BTreeSet<Id> = wanted.iter().map(|m| m.id).collect();
        let gone: Vec<Id> = self.tracked.keys().filter(|id| !keep.contains(id)).copied().collect();
        for id in gone {
            if let Some(t) = self.tracked.get(&id).cloned() {
                self.stop(id, &t);
                if t.state.is_ready() {
                    invalid.insert(id);
                }
            }
        }
        // Timeline-first: media the active timeline uses (earliest position first), then bin-only media.
        let wanted_ids: Vec<Id> = wanted.iter().map(|m| m.id).collect();
        let ordered = ProxyOrdering::sorted(&wanted_ids, &ProxyOrdering::first_use(active_timeline));
        self.ranks = ordered.iter().enumerate().map(|(i, id)| (*id, i as i64)).collect();
        let count = i64::try_from(self.ranks.len()).unwrap_or(i64::MAX);
        for (id, t) in &self.tracked {
            if let (Some(job), Some(r)) = (t.state.job(), self.ranks.get(id)) {
                self.queue.set_rank(job, AutoProxyRule::rank(*r, t.software, count));
            }
        }
        let by_id: BTreeMap<Id, &MediaRef> = wanted.iter().map(|m| (m.id, *m)).collect();
        for r in ordered.iter().filter_map(|id| by_id.get(id).copied()) {
            let mut file = FileState::read(&r.path);
            if let Some(v) = r.info.as_ref().and_then(|i| i.video.as_ref()) {
                file.keeps_fields = v.is_interlaced() && v.deinterlace_off;
            }
            if let Some(t) = self.tracked.get(&r.id).cloned() {
                if t.file == file {
                    continue;
                }
                self.stop(r.id, &t);
                if t.state.is_ready() {
                    invalid.insert(r.id);
                }
            }
            if file.size <= 0 {
                continue; // offline: decided when it comes back (next sync)
            }
            self.next_ticket += 1;
            self.tracked.insert(r.id, Tracked::new(file.clone(), self.next_ticket));
            self.start(r, file);
        }
        if !invalid.is_empty() {
            self.notify(invalid);
        }
    }

    /// Re-reads the settings (mode, playback) and applies them to the last synced media.
    // Swift: AutoProxy.swift:269
    pub fn refresh(&mut self) {
        self.disk_sample = None; // space may have been freed: read the disk again
        self.tracked.retain(|_, t| !matches!(t.state, ProxyState::Capped | ProxyState::DiskRefused));
        let (media, project, timeline) = (self.last_media.clone(), self.last_project, self.last_timeline.clone());
        self.sync(&media, project, timeline.as_ref());
    }

    /// The settings changed (the host debounces about 100 ms): re-applies them when mode or playback really changed.
    pub fn defaults_changed(&mut self) {
        if self.settings.mode(self.last_project) != self.mode || self.settings.playback() != self.applied_playback {
            self.refresh();
        }
    }

    fn stop(&mut self, id: Id, t: &Tracked) {
        self.tracked.remove(&id);
        if let Some(job) = t.state.job() {
            self.release(job);
        }
        if t.state.is_ready() {
            self.update_protected();
        }
    }

    /// Cancels `job` unless another tracked media still waits on it (the queue hands the same job to every media of the
    /// same file and kind).
    fn release(&mut self, job: ProxyJobID) {
        if self.tracked.values().any(|t| t.state.job() == Some(job)) {
            return;
        }
        self.queue.cancel(job);
    }

    /// A proxy can only be used when its frames are the original's: no hidden (edit-list, zero-duration) samples, which a
    /// transcode never carries, so the counts would differ and the monitor would ignore the proxy.
    // Swift: AutoProxy.swift:303
    pub fn proxy_can_match(index: &SampleIndex) -> bool {
        !index.entries().is_empty() && !index.entries().iter().any(|e| e.duration <= Time::ZERO)
    }

    /// The ready proxies fill the cache cap on their own: generating more would only evict proxies in use.
    fn cache_full_of_proxies_in_use(&self) -> bool {
        self.cache.protected_bytes() >= self.cache.settings().cache_cap_bytes
    }

    fn start(&mut self, r: &MediaRef, file: FileState) {
        let video = r.info.as_ref().and_then(|i| i.video.clone());
        let ticket = self.next_ticket;
        let now = (self.clock)();
        let disk_hint = self
            .disk_sample
            .filter(|(at, _)| now.unix_seconds() - at.unix_seconds() < Self::DISK_SAMPLE_TTL)
            .map(|(_, d)| d);
        self.work.push(ProxyDecisionWork {
            media: r.id,
            ticket,
            file,
            video,
            duration: r.info.as_ref().map_or(Time::ZERO, |i| i.duration),
            mode: self.mode,
            machine: self.machine,
            prober: Arc::clone(&self.prober),
            resolver: Arc::clone(&self.resolver),
            provider: Arc::clone(&self.provider),
            disk_space: Arc::clone(&self.disk_space),
            cache_dir: self.cache.directory().to_path_buf(),
            disk_hint,
            now,
        });
        self.apply(r.id, ProxyEvent::DecisionStarted);
        self.poll_busy(); // a job decided while busy is held before it can start
    }

    /// The decisions that wait for a worker.
    pub fn take_decision_work(&mut self) -> Vec<ProxyDecisionWork> {
        std::mem::take(&mut self.work)
    }

    /// The answer of a worker. Dropped when the media or its file changed meanwhile.
    pub fn decision_finished(&mut self, work: &ProxyDecisionWork, outcome: ProxyOutcome) {
        let (id, file) = (work.media, &work.file);
        if !self.tracked.get(&id).is_some_and(|t| t.ticket == work.ticket && t.file == *file) {
            return;
        }
        match outcome {
            ProxyOutcome::Skipped => self.apply(id, ProxyEvent::Skipped),
            ProxyOutcome::Ready { record } => self.became_ready(id, file, ProxyEvent::FoundReady { record }),
            ProxyOutcome::NeedsJob { kind, software, estimate, disk } => {
                if self.cache_full_of_proxies_in_use() {
                    self.apply(id, ProxyEvent::CapReached);
                    return;
                }
                self.disk_sample = Some(((self.clock)(), disk));
                if !self.reserve_disk(id, estimate, disk) {
                    return;
                }
                if software && let Some(t) = self.tracked.get_mut(&id) {
                    t.software = true;
                }
                let count = i64::try_from(self.ranks.len()).unwrap_or(i64::MAX);
                let rank = AutoProxyRule::rank(self.ranks.get(&id).copied().unwrap_or(i64::MAX), software, count);
                let now = (self.clock)();
                match self.queue.enqueue(
                    Path::new(&file.path),
                    kind,
                    ProxyJobPriority::Background,
                    rank,
                    &mut *self.ids,
                    now,
                ) {
                    Ok(job) => {
                        self.apply(id, ProxyEvent::JobQueued { job });
                        // An existing finished job reports at once through the queue's updates.
                        self.tick();
                    }
                    Err(e) => {
                        self.apply(id, ProxyEvent::JobFailed { reason: format!("{e:?}") });
                        if let Some(t) = self.tracked.get_mut(&id) {
                            t.reserved_bytes = 0;
                        }
                    }
                }
            }
        }
    }

    /// Reserves `estimate` for `id` if the volume keeps its reserve after it and every queued or running proxy.
    /// Synchronous, so two decisions can never both pass on the same free space.
    fn reserve_disk(&mut self, id: Id, estimate: i64, disk: DiskSpace) -> bool {
        let reserved = self.reserved_disk_bytes();
        if !self.tracked.contains_key(&id) {
            return false;
        }
        if !ProxyDiskGuard::allows(estimate + reserved, disk.free, disk.total) {
            self.apply(id, ProxyEvent::DiskFull);
            return false;
        }
        if let Some(t) = self.tracked.get_mut(&id) {
            t.reserved_bytes = estimate;
        }
        true
    }

    /// A job update from the queue: a finished one makes its media ready, a failed or canceled one frees its reserve.
    fn job_updated(&mut self, info: &ProxyJobInfo) {
        let waiting: Vec<(Id, FileState)> = self
            .tracked
            .iter()
            .filter(|(_, t)| t.state.job() == Some(info.id))
            .map(|(id, t)| (*id, t.file.clone()))
            .collect();
        if waiting.is_empty() {
            return;
        }
        if info.is_done() {
            for (id, file) in waiting {
                let path = PathBuf::from(&file.path);
                self.provider.warm(&path);
                let hit = self.provider.cached_lookup(&path, &ProxyProvider::SCRUB_PREFERENCE, (self.clock)());
                self.became_ready(id, &file, ProxyEvent::JobDone { record: hit.and_then(|h| h.record) });
            }
        } else if info.state.is_terminal() {
            // Failed or canceled: the reservation goes (a ready proxy no longer counts anyway).
            for (id, _) in waiting {
                if let Some(t) = self.tracked.get_mut(&id) {
                    t.reserved_bytes = 0;
                }
                match &info.state {
                    ProxyJobState::Failed(reason) => self.apply(id, ProxyEvent::JobFailed { reason: reason.clone() }),
                    _ => self.apply(id, ProxyEvent::Stopped),
                }
            }
        } else if info.state == ProxyJobState::Running {
            for (id, _) in waiting {
                self.apply(id, ProxyEvent::JobProgress { progress: info.progress });
            }
        }
    }

    /// The one place a media's [`ProxyState`] changes.
    fn apply(&mut self, id: Id, event: ProxyEvent<ProxyJobID, ProxyRecordID>) {
        if let Some(t) = self.tracked.get_mut(&id) {
            t.state = std::mem::replace(&mut t.state, ProxyState::NotNeeded).next(event);
        }
    }

    /// The lifecycle state of one media's proxy (project panel column, status line, Preferences).
    pub fn proxy_state(&self, id: Id) -> Option<ProxyState<ProxyJobID, ProxyRecordID>> {
        self.tracked.get(&id).map(|t| t.state.clone())
    }

    /// `event` is `FoundReady` (decision) or `JobDone` (queue).
    fn became_ready(&mut self, id: Id, file: &FileState, event: ProxyEvent<ProxyJobID, ProxyRecordID>) {
        match self.tracked.get(&id) {
            Some(t) if t.file == *file && !t.state.is_ready() => {}
            _ => return,
        }
        self.apply(id, event);
        if !self.tracked.get(&id).is_some_and(|t| t.state.is_ready()) {
            return;
        }
        self.update_protected();
        self.notify(BTreeSet::from([id]));
        if !self.cache_full_of_proxies_in_use() {
            return;
        }
        // Jobs still waiting would only push proxies in use out of the cache: stop them (`refresh()` tries again).
        let waiting: Vec<(Id, Tracked)> =
            self.tracked.iter().filter(|(_, t)| t.state.job().is_some()).map(|(id, t)| (*id, t.clone())).collect();
        for (mid, t) in waiting {
            self.stop(mid, &t);
            let mut kept = Tracked::new(t.file, t.ticket);
            kept.state = ProxyState::Capped;
            self.tracked.insert(mid, kept);
        }
    }

    /// Proxies the monitors use are never evicted.
    fn update_protected(&self) {
        self.cache.set_protected(self.tracked.values().filter_map(|t| t.state.record().cloned()).collect());
    }

    /// A proxy left the cache (evicted, deleted): its media is no longer ready and the engines and the resolver drop it.
    /// It is generated again only by a later sync (no regeneration loop against the cap).
    fn removed(&mut self, record: &ProxyRecord) {
        let rid = ProxyRecordID::new(record);
        let hit: BTreeSet<Id> =
            self.tracked.iter().filter(|(_, t)| t.state.record() == Some(&rid)).map(|(id, _)| *id).collect();
        if hit.is_empty() {
            return;
        }
        for id in &hit {
            self.tracked.remove(id);
        }
        self.update_protected();
        self.notify(hit);
    }

    /// The proxies of these media changed or went away: the resolver reopens them, the engines drop frames and decoders.
    fn notify(&mut self, ids: BTreeSet<Id>) {
        self.resolver.drop_proxies(&ids);
        self.effects.push(ProxyEffect::ProxiesChanged(ids));
    }

    /// What the monitors must be told, in order. The session applies it to every engine it owns.
    pub fn take_effects(&mut self) -> Vec<ProxyEffect> {
        std::mem::take(&mut self.effects)
    }

    /// The transcodes the queue started; run each on a worker ([`StartedJob::run`]) and report with
    /// [`AutoProxyService::complete_job`].
    pub fn take_started_jobs(&mut self) -> Vec<StartedJob> {
        self.queue.take_started()
    }

    /// Progress of a running job (0...1).
    pub fn set_job_progress(&mut self, id: ProxyJobID, progress: f64) {
        self.queue.set_progress(id, progress);
    }

    /// A transcode finished.
    pub fn complete_job(&mut self, id: ProxyJobID, result: Result<ProxyRecord, JobError>) {
        self.queue.complete(id, result);
        self.tick();
    }
}

fn now_unix() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

impl<D: ProxyDefaults> SessionProxyServing for AutoProxyService<D> {
    fn project_id(&self) -> Option<Id> {
        AutoProxyService::project_id(self)
    }
    fn sync(&mut self, media: &[MediaRef], project_id: Option<Id>, active_timeline: Option<&Timeline>) {
        AutoProxyService::sync(self, media, project_id, active_timeline);
    }
    // Swift: AutoProxy.swift:412
    fn take_effects(&mut self) -> Vec<ProxyEffect> {
        AutoProxyService::take_effects(self)
    }
    fn clear_cache(&mut self) -> i64 {
        AutoProxyService::clear_cache(self)
    }
}
