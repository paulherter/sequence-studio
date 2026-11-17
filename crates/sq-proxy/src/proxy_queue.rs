// Swift: ProxyQueue.swift (the actor is a plain state machine, PORTING section 9: see NOTES.md "ProxyQueue")
//! Sequential (or N-way) proxy generation with dedupe.

use crate::model::{ProxyKind, ProxyRecord, SourceFingerprint};
use crate::proxy_cache::{ProxyCache, ProxyRecordID};
use crate::proxy_transcoding::{CancelToken, ProxyTranscodeError, ProxyTranscoding};
use serde::{Deserialize, Serialize};
use sq_core_time::{Id, IdSource, Timestamp};
use std::collections::BTreeSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, Sender};

/// Identity of a job.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct ProxyJobID {
    /// The unique value.
    pub raw: Id,
}

/// Where a job is.
#[derive(Clone, Debug, PartialEq)]
pub enum ProxyJobState {
    /// Waiting for a free slot.
    Queued,
    /// Handed out by `take_started`, not completed yet.
    Running,
    /// Finished; the proxy is in the cache.
    Done(ProxyRecord),
    /// Failed with this message.
    Failed(String),
    /// Canceled.
    Cancelled,
}

impl ProxyJobState {
    /// Done, failed or canceled.
    pub fn is_terminal(&self) -> bool {
        !matches!(self, ProxyJobState::Queued | ProxyJobState::Running)
    }
}

/// Scheduling priority of a job: decides start order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub enum ProxyJobPriority {
    /// Automatic generation after import.
    Background = 0,
    /// Explicitly requested by the user.
    Utility = 1,
    /// The user waits for it.
    UserInitiated = 2,
}

/// What the queue knows about a job.
#[derive(Clone, Debug, PartialEq)]
pub struct ProxyJobInfo {
    /// Identity.
    pub id: ProxyJobID,
    /// The source file.
    pub source: PathBuf,
    /// Which proxy.
    pub kind: ProxyKind,
    /// Start order class.
    pub priority: ProxyJobPriority,
    /// Where it is.
    pub state: ProxyJobState,
    /// 0...1
    pub progress: f64,
}

impl ProxyJobInfo {
    /// The proxy was made.
    pub fn is_done(&self) -> bool {
        matches!(self.state, ProxyJobState::Done(_))
    }
}

/// Reads a source's identity.
pub type Fingerprinter = Box<dyn Fn(&Path) -> io::Result<SourceFingerprint> + Send + Sync>;

struct Job {
    info: ProxyJobInfo,
    fingerprint: SourceFingerprint,
    cancel: CancelToken,
    cancel_requested: bool,
    /// Start order within a priority: lower first (ties FIFO).
    rank: i64,
}

/// A job the queue marked running: the driver executes it (`run`) and reports back with `ProxyQueue::complete`.
pub struct StartedJob {
    /// The job.
    pub id: ProxyJobID,
    /// The source file.
    pub source: PathBuf,
    /// Which proxy.
    pub kind: ProxyKind,
    /// The source's identity.
    pub fingerprint: SourceFingerprint,
    /// Set when the job is canceled; the transcoder polls it.
    pub cancel: CancelToken,
    cache: Arc<ProxyCache>,
}

/// Why a job did not produce a proxy.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum JobError {
    /// Stopped by the cancel token.
    Cancelled,
    /// Transcoder or cache failed with this message.
    Failed(String),
}

impl StartedJob {
    /// Transcodes into the cache's partial file and commits it: the body of the Swift `run`. `progress` gets 0...1;
    /// the driver forwards it to `ProxyQueue::set_progress`. No partial file stays behind on an error.
    pub fn run(
        &self,
        transcoder: &dyn ProxyTranscoding,
        progress: &mut dyn FnMut(f64),
        now: Timestamp,
    ) -> Result<ProxyRecord, JobError> {
        let partial = self.cache.partial_url(&self.fingerprint, self.kind);
        fs::remove_file(&partial).ok();
        let result = self.transcode_and_commit(transcoder, &partial, progress, now);
        if result.is_err() {
            fs::remove_file(&partial).ok();
        }
        result
    }

    fn transcode_and_commit(
        &self,
        transcoder: &dyn ProxyTranscoding,
        partial: &Path,
        progress: &mut dyn FnMut(f64),
        now: Timestamp,
    ) -> Result<ProxyRecord, JobError> {
        let out = transcoder.transcode(&self.source, self.kind, partial, None, progress, &self.cancel).map_err(
            |e| match e {
                ProxyTranscodeError::Cancelled => JobError::Cancelled,
                other => JobError::Failed(other.to_string()),
            },
        )?;
        if self.cancel.is_cancelled() {
            return Err(JobError::Cancelled);
        }
        let record = ProxyRecord::new(
            self.fingerprint.clone(),
            self.kind,
            ProxyCache::file_name(&self.fingerprint, self.kind),
            out.dimensions,
            now,
            out.source_duration,
        );
        self.cache.commit(partial, &record).map_err(|e| JobError::Failed(e.to_string()))?;
        Ok(record)
    }
}

/// Sequential (or N-way) proxy generation with dedupe. Completed proxies are registered in the `ProxyCache`.
pub struct ProxyQueue {
    cache: Arc<ProxyCache>,
    fingerprinter: Fingerprinter,
    concurrency: usize,
    /// Jobs in enqueue order.
    jobs: Vec<Job>,
    started: Vec<StartedJob>,
    listeners: Vec<(Option<ProxyJobID>, Sender<ProxyJobInfo>)>,
    held: bool,
}

impl ProxyQueue {
    /// Rank of a job nobody ranked: starts after all ranked ones.
    pub const UNRANKED: i64 = i64::MAX;

    /// A queue that fingerprints with `SourceFingerprint::compute`.
    pub fn new(cache: Arc<ProxyCache>, concurrency: usize) -> ProxyQueue {
        Self::with_fingerprinter(cache, concurrency, Box::new(SourceFingerprint::compute))
    }

    /// A queue with its own fingerprinter.
    pub fn with_fingerprinter(cache: Arc<ProxyCache>, concurrency: usize, fingerprinter: Fingerprinter) -> ProxyQueue {
        ProxyQueue {
            cache,
            fingerprinter,
            concurrency: concurrency.max(1),
            jobs: Vec::new(),
            started: Vec::new(),
            listeners: Vec::new(),
            held: false,
        }
    }

    /// How many jobs run at once.
    pub fn concurrency(&self) -> usize {
        self.concurrency
    }

    /// Held (thermal pressure, Low Power Mode): no queued job starts; a running one finishes.
    pub fn is_held(&self) -> bool {
        self.held
    }

    /// Releasing starts the next jobs.
    pub fn set_held(&mut self, held: bool) {
        if held == self.held {
            return;
        }
        self.held = held;
        if !held {
            self.start_next();
        }
    }

    /// Jobs marked running since the last call: the driver runs each one and calls `complete`.
    pub fn take_started(&mut self) -> Vec<StartedJob> {
        std::mem::take(&mut self.started)
    }

    /// Call once at launch: removes stale partials (no job can be running yet) and enforces the cache cap.
    pub fn start(&mut self) {
        // Partials of jobs that already started (enqueue before start()) are kept.
        let running: BTreeSet<PathBuf> = self
            .jobs
            .iter()
            .filter(|j| j.info.state == ProxyJobState::Running)
            .map(|j| self.cache.partial_url(&j.fingerprint, j.info.kind))
            .collect();
        self.cache.purge_partials(&running);
        self.cache.enforce_cap(&BTreeSet::new());
        self.start_next();
    }

    fn position(&self, id: ProxyJobID) -> Option<usize> {
        self.jobs.iter().position(|j| j.info.id == id)
    }

    /// Queues a proxy of the whole file (no partial ranges: the cache key is (fingerprint, kind)). Returns the
    /// existing job if the same (fingerprint, kind) is queued, running (not being canceled) or already cached. Fails if
    /// the source cannot be fingerprinted.
    pub fn enqueue(
        &mut self,
        source: &Path,
        kind: ProxyKind,
        priority: ProxyJobPriority,
        rank: i64,
        ids: &mut dyn IdSource,
        now: Timestamp,
    ) -> io::Result<ProxyJobID> {
        let fp = (self.fingerprinter)(source)?;
        let existing = self.jobs.iter().find(|j| {
            if j.fingerprint != fp || j.info.kind != kind {
                return false;
            }
            match &j.info.state {
                ProxyJobState::Queued => true,
                ProxyJobState::Running => !j.cancel_requested,
                ProxyJobState::Done(r) => self.cache.current_lookup(&r.fingerprint, r.kind, now).is_some(),
                _ => false,
            }
        });
        if let Some(j) = existing {
            return Ok(j.info.id);
        }
        let id = ProxyJobID { raw: ids.next_id() };
        let mut info = ProxyJobInfo {
            id,
            source: source.to_path_buf(),
            kind,
            priority,
            state: ProxyJobState::Queued,
            progress: 0.0,
        };
        // A record of an older transcoder counts as missing: the new file replaces it.
        if let Some(rec) = self.cache.current_lookup(&fp, kind, now) {
            info.state = ProxyJobState::Done(rec);
            info.progress = 1.0;
            self.jobs.push(Job {
                info,
                fingerprint: fp,
                cancel: CancelToken::new(),
                cancel_requested: false,
                rank: Self::UNRANKED,
            });
            self.publish(id);
            return Ok(id);
        }
        self.jobs.push(Job { info, fingerprint: fp, cancel: CancelToken::new(), cancel_requested: false, rank });
        self.publish(id);
        self.start_next();
        Ok(id)
    }

    /// Changes the start order of a queued job (the timeline changed); no effect on a running one.
    pub fn set_rank(&mut self, id: ProxyJobID, rank: i64) {
        if let Some(i) = self.position(id) {
            self.jobs[i].rank = rank;
        }
    }

    /// What the queue knows about `id`.
    pub fn info(&self, id: ProxyJobID) -> Option<&ProxyJobInfo> {
        self.position(id).map(|i| &self.jobs[i].info)
    }

    /// Every job in enqueue order.
    pub fn all_jobs(&self) -> Vec<ProxyJobInfo> {
        self.jobs.iter().map(|j| j.info.clone()).collect()
    }

    /// Mean progress of all jobs except canceled and failed ones (0 if none).
    pub fn overall_progress(&self) -> f64 {
        let infos: Vec<&ProxyJobInfo> = self
            .jobs
            .iter()
            .map(|j| &j.info)
            .filter(|i| !matches!(i.state, ProxyJobState::Cancelled | ProxyJobState::Failed(_)))
            .collect();
        if infos.is_empty() {
            return 0.0;
        }
        infos.iter().fold(0.0, |a, i| a + i.progress) / infos.len() as f64
    }

    /// Cancels a queued job at once; a running one is told to stop and ends with `complete`.
    pub fn cancel(&mut self, id: ProxyJobID) {
        let Some(i) = self.position(id) else { return };
        match self.jobs[i].info.state {
            ProxyJobState::Queued => {
                self.jobs[i].info.state = ProxyJobState::Cancelled;
                self.publish(id);
            }
            ProxyJobState::Running => {
                self.jobs[i].cancel_requested = true;
                self.jobs[i].cancel.cancel();
            }
            _ => {}
        }
    }

    /// Cancels every job.
    pub fn cancel_all(&mut self) {
        let ids: Vec<ProxyJobID> = self.jobs.iter().map(|j| j.info.id).collect();
        for id in ids {
            self.cancel(id);
        }
    }

    /// Updates for one job (current state first); the channel closes when the job reaches a terminal state.
    pub fn updates_for(&mut self, id: ProxyJobID) -> Receiver<ProxyJobInfo> {
        let (tx, rx) = mpsc::channel();
        let Some(info) = self.info(id).cloned() else { return rx };
        let terminal = info.state.is_terminal();
        tx.send(info).ok();
        if !terminal {
            self.listeners.push((Some(id), tx));
        }
        rx
    }

    /// Updates for every job.
    pub fn updates(&mut self) -> Receiver<ProxyJobInfo> {
        let (tx, rx) = mpsc::channel();
        self.listeners.push((None, tx));
        rx
    }

    fn publish(&mut self, id: ProxyJobID) {
        let Some(info) = self.info(id).cloned() else { return };
        let terminal = info.state.is_terminal();
        self.listeners.retain(|(job, tx)| {
            if job.is_some() && *job != Some(id) {
                return true;
            }
            tx.send(info.clone()).is_ok() && !(*job == Some(id) && terminal)
        });
    }

    fn start_next(&mut self) {
        if self.held {
            return;
        }
        let mut running = self.jobs.iter().filter(|j| j.info.state == ProxyJobState::Running).count();
        // Higher priority first, then lower rank; stable within both (FIFO).
        let mut candidates: Vec<usize> = (0..self.jobs.len()).collect();
        candidates.sort_by(|&a, &b| {
            let (ja, jb) = (&self.jobs[a], &self.jobs[b]);
            jb.info.priority.cmp(&ja.info.priority).then(ja.rank.cmp(&jb.rank))
        });
        for i in candidates {
            if running >= self.concurrency {
                break;
            }
            if self.jobs[i].info.state != ProxyJobState::Queued {
                continue;
            }
            let j = &mut self.jobs[i];
            j.info.state = ProxyJobState::Running;
            let started = StartedJob {
                id: j.info.id,
                source: j.info.source.clone(),
                kind: j.info.kind,
                fingerprint: j.fingerprint.clone(),
                cancel: j.cancel.clone(),
                cache: Arc::clone(&self.cache),
            };
            let id = j.info.id;
            self.started.push(started);
            self.publish(id);
            running += 1;
        }
    }

    /// Progress of a running job (never goes back).
    pub fn set_progress(&mut self, id: ProxyJobID, p: f64) {
        let Some(i) = self.position(id) else { return };
        let j = &mut self.jobs[i];
        if j.info.state != ProxyJobState::Running {
            return;
        }
        j.info.progress = p.max(j.info.progress).min(1.0);
        self.publish(id);
    }

    /// The end of a started job: records the outcome, enforces the cache cap and starts the next jobs.
    pub fn complete(&mut self, id: ProxyJobID, result: Result<ProxyRecord, JobError>) {
        let Some(i) = self.position(id) else { return };
        let j = &mut self.jobs[i];
        match result {
            Ok(rec) => {
                j.info.state = ProxyJobState::Done(rec.clone());
                j.info.progress = 1.0;
                // Removals are reported through `ProxyCache::removed_records`; records in use are protected.
                self.cache.enforce_cap(&BTreeSet::from([ProxyRecordID::new(&rec)]));
            }
            Err(e) => {
                j.info.state = match e {
                    JobError::Failed(m) if !j.cancel_requested => ProxyJobState::Failed(m),
                    _ => ProxyJobState::Cancelled,
                };
            }
        }
        self.publish(id);
        self.start_next();
    }

    /// Runs started jobs one after another on the calling thread until none is left. The simple driver for tests and
    /// single-threaded callers; a worker pool calls `take_started`, `StartedJob::run` and `complete` itself.
    pub fn run_until_idle(&mut self, transcoder: &dyn ProxyTranscoding, now: Timestamp) {
        loop {
            let started = self.take_started();
            if started.is_empty() {
                return;
            }
            for job in started {
                let mut last = 0.0;
                let result = job.run(transcoder, &mut |p| last = p, now);
                self.set_progress(job.id, last);
                self.complete(job.id, result);
            }
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::model::ProxyDimensions;
    use crate::model::test_support::*;
    use sq_core_time::{SequentialIds, Time, TimeRange};
    use std::collections::BTreeSet;
    use std::sync::Mutex;

    /// Fake transcoder: writes "proxy", fails for names in `failing`, records the order it was called in.
    #[derive(Default)]
    pub struct FakeTranscoder {
        pub failing: Mutex<BTreeSet<String>>,
        pub started: Mutex<Vec<String>>,
    }

    impl FakeTranscoder {
        pub fn started(&self) -> Vec<String> {
            self.started.lock().unwrap().clone()
        }
    }

    impl ProxyTranscoding for FakeTranscoder {
        fn transcode(
            &self,
            source: &Path,
            _kind: ProxyKind,
            destination: &Path,
            _time_range: Option<TimeRange>,
            progress: &mut dyn FnMut(f64),
            cancel: &CancelToken,
        ) -> Result<crate::proxy_transcoding::TranscodeOutput, ProxyTranscodeError> {
            let name = source.file_name().unwrap().to_string_lossy().into_owned();
            self.started.lock().unwrap().push(name.clone());
            progress(0.5);
            if cancel.is_cancelled() {
                return Err(ProxyTranscodeError::Cancelled);
            }
            if self.failing.lock().unwrap().contains(&name) {
                return Err(ProxyTranscodeError::ReaderFailed("fake".into()));
            }
            fs::write(destination, b"proxy").map_err(|e| ProxyTranscodeError::WriterFailed(e.to_string()))?;
            progress(1.0);
            Ok(crate::proxy_transcoding::TranscodeOutput {
                dimensions: ProxyDimensions { width: 960, height: 540 },
                source_duration: Time::new(10, 1),
            })
        }
    }

    fn now() -> Timestamp {
        Timestamp::from_unix_seconds(100.0)
    }

    pub struct Fixture {
        pub _dir: TempDir,
        pub cache: Arc<ProxyCache>,
        pub queue: ProxyQueue,
        pub t: FakeTranscoder,
        pub urls: Vec<PathBuf>,
        pub ids: SequentialIds,
    }

    pub fn setup(limit: usize, files: &[&str]) -> Fixture {
        let dir = TempDir::new();
        let urls: Vec<PathBuf> = files
            .iter()
            .enumerate()
            .map(|(i, f)| {
                let u = dir.join(f);
                write_file(&u, 1000, i as u8 + 1);
                u
            })
            .collect();
        let cache = Arc::new(ProxyCache::new(dir.join("cache")));
        let queue = ProxyQueue::new(Arc::clone(&cache), limit);
        Fixture { _dir: dir, cache, queue, t: FakeTranscoder::default(), urls, ids: SequentialIds::default() }
    }

    impl Fixture {
        pub fn enqueue(&mut self, i: usize, kind: ProxyKind) -> ProxyJobID {
            self.enqueue_with(i, kind, ProxyJobPriority::Utility, ProxyQueue::UNRANKED)
        }

        pub fn enqueue_with(&mut self, i: usize, kind: ProxyKind, priority: ProxyJobPriority, rank: i64) -> ProxyJobID {
            self.queue.enqueue(&self.urls[i], kind, priority, rank, &mut self.ids, now()).unwrap()
        }

        pub fn state(&self, id: ProxyJobID) -> ProxyJobState {
            self.queue.info(id).unwrap().state.clone()
        }
    }

    const FILES: [&str; 3] = ["a.mov", "b.mov", "c.mov"];

    /// A cached proxy of an older transcoder (possibly woven) does not count as done: the job runs and replaces it.
    #[test]
    fn an_outdated_cached_proxy_is_made_again() {
        let mut f = setup(1, &FILES);
        let fp = SourceFingerprint::compute(&f.urls[0]).unwrap();
        let mut old = ProxyRecord::new(
            fp.clone(),
            ProxyKind::ProxyHalf,
            ProxyCache::file_name(&fp, ProxyKind::ProxyHalf),
            ProxyDimensions { width: 960, height: 540 },
            now(),
            Time::new(10, 1),
        );
        old.build = 0;
        let partial = f.cache.partial_url(&fp, ProxyKind::ProxyHalf);
        fs::write(&partial, b"old").unwrap();
        f.cache.commit(&partial, &old).unwrap();
        f.enqueue(0, ProxyKind::ProxyHalf);
        f.queue.run_until_idle(&f.t, now());
        assert!(f.cache.current_lookup(&fp, ProxyKind::ProxyHalf, now()).is_some());
        let made = f.cache.lookup(&fp, ProxyKind::ProxyHalf, now()).unwrap();
        assert_eq!(fs::read(f.cache.file_url(&made)).unwrap(), b"proxy");
    }

    #[test]
    fn runs_one_at_a_time_and_registers_in_cache() {
        let mut f = setup(1, &FILES);
        let j1 = f.enqueue(0, ProxyKind::ProxyHalf);
        let j2 = f.enqueue(1, ProxyKind::ProxyHalf);
        assert_eq!(f.state(j1), ProxyJobState::Running);
        assert_eq!(f.state(j2), ProxyJobState::Queued);
        let first = f.queue.take_started();
        assert_eq!(first.len(), 1);
        let result = first[0].run(&f.t, &mut |_| {}, now());
        f.queue.complete(j1, result);
        assert_eq!(f.state(j2), ProxyJobState::Running);
        f.queue.run_until_idle(&f.t, now());
        assert!(f.queue.info(j2).unwrap().is_done());
        let fp = SourceFingerprint::compute(&f.urls[0]).unwrap();
        let rec = f.cache.lookup(&fp, ProxyKind::ProxyHalf, now()).unwrap();
        assert_eq!(rec.dimensions, ProxyDimensions { width: 960, height: 540 });
        assert_eq!(f.queue.info(j1).unwrap().progress, 1.0);
    }

    #[test]
    fn overall_progress_excludes_failed_jobs() {
        let mut f = setup(2, &FILES[..2]);
        f.t.failing.lock().unwrap().insert("a.mov".into());
        let j1 = f.enqueue(0, ProxyKind::ProxyHalf);
        let j2 = f.enqueue(1, ProxyKind::ProxyHalf);
        f.queue.run_until_idle(&f.t, now());
        assert!(matches!(f.state(j1), ProxyJobState::Failed(_)));
        assert!(f.queue.info(j2).unwrap().is_done());
        assert_eq!(f.queue.overall_progress(), 1.0);
    }

    #[test]
    fn concurrency_limit_two() {
        let mut f = setup(2, &FILES);
        for i in 0..3 {
            f.enqueue(i, ProxyKind::ProxyQuarter);
        }
        let first = f.queue.take_started();
        assert_eq!(first.len(), 2);
        assert_eq!(f.queue.all_jobs().iter().filter(|j| j.state == ProxyJobState::Running).count(), 2);
        for job in first {
            let r = job.run(&f.t, &mut |_| {}, now());
            f.queue.complete(job.id, r);
        }
        f.queue.run_until_idle(&f.t, now());
        assert!(f.queue.all_jobs().iter().all(|j| j.is_done()));
    }

    #[test]
    fn dedupe_queued_running_and_cached() {
        let mut f = setup(1, &FILES);
        let j1 = f.enqueue(0, ProxyKind::ProxyHalf);
        assert_eq!(f.enqueue(0, ProxyKind::ProxyHalf), j1);
        assert_ne!(f.enqueue(0, ProxyKind::Optimized), j1);
        f.queue.run_until_idle(&f.t, now());
        assert!(f.queue.info(j1).unwrap().is_done());
        assert_eq!(f.enqueue(0, ProxyKind::ProxyHalf), j1);
        assert_eq!(f.t.started().iter().filter(|n| *n == "a.mov").count(), 2);
    }

    /// Enqueue must not dedupe to a running job whose cancel was already requested.
    #[test]
    fn enqueue_after_cancel_request_starts_fresh_job() {
        let mut f = setup(1, &FILES);
        let j1 = f.enqueue(0, ProxyKind::ProxyHalf);
        assert_eq!(f.state(j1), ProxyJobState::Running);
        f.queue.cancel(j1);
        let j2 = f.enqueue(0, ProxyKind::ProxyHalf);
        assert_ne!(j2, j1);
        f.queue.run_until_idle(&f.t, now());
        assert_eq!(f.state(j1), ProxyJobState::Cancelled);
        assert!(f.queue.info(j2).unwrap().is_done());
    }

    /// A job that already runs before start() keeps its partial; unrelated partials are purged.
    #[test]
    fn start_does_not_purge_partial_of_running_job() {
        let mut f = setup(1, &FILES);
        let j1 = f.enqueue(0, ProxyKind::ProxyHalf);
        assert_eq!(f.state(j1), ProxyJobState::Running);
        let fp = SourceFingerprint::compute(&f.urls[0]).unwrap();
        let mine = f.cache.partial_url(&fp, ProxyKind::ProxyHalf);
        let stray = f.cache.directory().join("stray.mov.partial");
        fs::write(&mine, b"x").unwrap();
        fs::write(&stray, b"x").unwrap();
        f.queue.start();
        assert!(mine.exists());
        assert!(!stray.exists());
    }

    #[test]
    fn cached_without_job_returns_done_job() {
        let mut f = setup(1, &FILES);
        let fp = SourceFingerprint::compute(&f.urls[0]).unwrap();
        let r = ProxyRecord::new(
            fp.clone(),
            ProxyKind::ProxyHalf,
            ProxyCache::file_name(&fp, ProxyKind::ProxyHalf),
            ProxyDimensions { width: 2, height: 2 },
            now(),
            Time::new(1, 1),
        );
        let p = f.cache.partial_url(&fp, ProxyKind::ProxyHalf);
        fs::write(&p, b"x").unwrap();
        f.cache.commit(&p, &r).unwrap();
        let j = f.enqueue(0, ProxyKind::ProxyHalf);
        assert!(f.queue.info(j).unwrap().is_done());
    }

    #[test]
    fn failure_and_cancel() {
        let mut f = setup(1, &FILES);
        f.t.failing.lock().unwrap().insert("a.mov".into());
        let (ja, jb, jc) = (
            f.enqueue(0, ProxyKind::ProxyHalf),
            f.enqueue(1, ProxyKind::ProxyHalf),
            f.enqueue(2, ProxyKind::ProxyHalf),
        );
        let a = f.queue.take_started().remove(0);
        let r = a.run(&f.t, &mut |_| {}, now());
        f.queue.complete(ja, r);
        assert!(matches!(f.state(ja), ProxyJobState::Failed(_)));
        // b is running now: cancel it, c queued: cancel it
        assert_eq!(f.state(jb), ProxyJobState::Running);
        f.queue.cancel(jb);
        f.queue.cancel(jc);
        f.queue.run_until_idle(&f.t, now());
        assert_eq!(f.state(jb), ProxyJobState::Cancelled);
        assert_eq!(f.state(jc), ProxyJobState::Cancelled);
        let fp = SourceFingerprint::compute(&f.urls[1]).unwrap();
        assert!(f.cache.lookup(&fp, ProxyKind::ProxyHalf, now()).is_none());
        assert!(!f.cache.partial_url(&fp, ProxyKind::ProxyHalf).exists());
        // failed jobs can be retried
        f.t.failing.lock().unwrap().clear();
        assert_ne!(f.enqueue(0, ProxyKind::ProxyHalf), ja);
    }

    #[test]
    fn cancel_all() {
        let mut f = setup(1, &FILES);
        for i in 0..3 {
            f.enqueue(i, ProxyKind::ProxyHalf);
        }
        f.queue.cancel_all();
        f.queue.run_until_idle(&f.t, now());
        assert!(f.queue.all_jobs().iter().all(|j| j.state == ProxyJobState::Cancelled));
    }

    #[test]
    fn job_stream_reports_progress_and_ends() {
        let mut f = setup(1, &FILES);
        let j = f.enqueue(0, ProxyKind::ProxyHalf);
        let rx = f.queue.updates_for(j);
        f.queue.run_until_idle(&f.t, now());
        let all: Vec<ProxyJobInfo> = rx.iter().collect();
        assert!(all.last().is_some_and(|i| i.is_done()));
    }

    #[test]
    fn queue_enforces_cap_after_job_and_at_start() {
        let mut f = setup(1, &FILES[..2]);
        f.cache.update_settings(|s| s.cache_cap_bytes = 7).unwrap(); // fake proxy is 5 bytes: only one fits
        f.enqueue(0, ProxyKind::ProxyHalf);
        f.queue.run_until_idle(&f.t, now());
        f.enqueue(1, ProxyKind::ProxyHalf);
        f.queue.run_until_idle(&f.t, now());
        assert_eq!(f.cache.all_records().len(), 1);
        let fp = SourceFingerprint::compute(&f.urls[1]).unwrap();
        assert!(f.cache.lookup(&fp, ProxyKind::ProxyHalf, now()).is_some());
        // launch: lowering the cap to 0 then start() evicts
        f.cache.update_settings(|s| s.cache_cap_bytes = 0).unwrap();
        f.queue.start();
        assert!(f.cache.all_records().is_empty());
    }

    #[test]
    fn higher_priority_starts_first() {
        let mut f = setup(2, &["run.mov", "bg.mov", "user.mov"]);
        // run.mov takes the first slot at once; of the other two the user's job takes the second.
        f.queue.set_held(true);
        f.enqueue_with(0, ProxyKind::ProxyHalf, ProxyJobPriority::Utility, ProxyQueue::UNRANKED);
        f.enqueue_with(1, ProxyKind::ProxyHalf, ProxyJobPriority::Background, ProxyQueue::UNRANKED);
        f.enqueue_with(2, ProxyKind::ProxyHalf, ProxyJobPriority::UserInitiated, ProxyQueue::UNRANKED);
        f.queue.set_held(false);
        let names: Vec<String> = f
            .queue
            .take_started()
            .iter()
            .map(|j| j.source.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["user.mov", "run.mov"]);
    }

    #[test]
    fn held_queue_starts_nothing_until_released() {
        let mut f = setup(1, &FILES[..2]);
        let j1 = f.enqueue(0, ProxyKind::ProxyHalf);
        assert_eq!(f.state(j1), ProxyJobState::Running);
        f.queue.set_held(true);
        assert!(f.queue.is_held());
        let j2 = f.enqueue(1, ProxyKind::ProxyHalf);
        let a = f.queue.take_started().remove(0); // the running job finishes while held
        let r = a.run(&f.t, &mut |_| {}, now());
        f.queue.complete(j1, r);
        assert!(f.queue.info(j1).unwrap().is_done());
        assert_eq!(f.state(j2), ProxyJobState::Queued); // ...but the next one does not start
        assert!(f.queue.take_started().is_empty());
        f.queue.set_held(false);
        assert_eq!(f.state(j2), ProxyJobState::Running);
        f.queue.run_until_idle(&f.t, now());
        assert!(f.queue.info(j2).unwrap().is_done());
    }

    /// Within one priority the lower rank starts first (timeline-first ordering); `set_rank` reorders queued jobs.
    #[test]
    fn lower_rank_starts_first_and_set_rank_reorders() {
        let mut f = setup(1, &FILES);
        f.queue.set_held(true);
        f.enqueue_with(0, ProxyKind::ProxyHalf, ProxyJobPriority::Utility, 2);
        f.enqueue_with(1, ProxyKind::ProxyHalf, ProxyJobPriority::Utility, 1);
        let jc = f.enqueue_with(2, ProxyKind::ProxyHalf, ProxyJobPriority::Utility, 3);
        f.queue.set_rank(jc, 0);
        f.queue.set_held(false);
        f.queue.run_until_idle(&f.t, now());
        assert_eq!(f.t.started(), vec!["c.mov", "b.mov", "a.mov"]);
    }
}
