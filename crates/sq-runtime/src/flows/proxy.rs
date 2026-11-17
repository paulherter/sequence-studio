//! Port of the scheduling core of `AutoProxyService` (Packages/SQEditorSession/.../AutoProxy.swift): settings debounce
//! (:275-283), busy polling (:156-188), the cancelable decision task with `Task.isCancelled` guards (:310-371),
//! `stop/release` (:286-300), plus a minimal `ProxyQueue` actor with held state and a progress stream.
use super::Log;
use crate::channel::{Receiver, Sender, unbounded};
use crate::proxy_state::{ProxyEvent, ProxyState};
use crate::{Clock, JoinHandle, WorkerPool, is_cancelled, sleep, spawn_cooperative, spawn_local, yield_now};
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::{Rc, Weak};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::task::{Context, Poll, Waker};
use std::time::Duration;

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

// ---------- test doubles ----------

/// UI-side gate (`GatedProber`): `wait()` suspends until `open()`.
#[derive(Clone, Default)]
pub struct Gate(Rc<RefCell<(bool, Vec<Waker>)>>);
impl Gate {
    pub fn closed() -> Self {
        Gate::default()
    }
    pub fn open(&self) {
        let ws = {
            let mut g = self.0.borrow_mut();
            g.0 = true;
            std::mem::take(&mut g.1)
        };
        ws.into_iter().for_each(|w| w.wake());
    }
    pub fn wait(&self) -> impl std::future::Future<Output = ()> + '_ {
        std::future::poll_fn(move |cx: &mut Context<'_>| {
            let mut g = self.0.borrow_mut();
            if g.0 {
                Poll::Ready(())
            } else {
                g.1.push(cx.waker().clone());
                Poll::Pending
            }
        })
    }
}
/// Worker-side blocking gate (`transcoder.open()`); `notify_all` on cancel so a blocked transcode can stop.
#[derive(Default)]
pub struct Transcoder {
    open: Mutex<bool>,
    cv: Condvar,
}
impl Transcoder {
    pub fn opened() -> Arc<Self> {
        let t = Arc::new(Transcoder::default());
        t.open();
        t
    }
    pub fn closed() -> Arc<Self> {
        Arc::new(Transcoder::default())
    }
    pub fn open(&self) {
        *lock(&self.open) = true;
        self.cv.notify_all();
    }
    fn wait(&self, cancel: &AtomicBool) {
        let mut g = lock(&self.open);
        while !*g && !cancel.load(Ordering::SeqCst) {
            g = self.cv.wait(g).unwrap_or_else(|e| e.into_inner());
        }
    }
    fn poke(&self) {
        let _g = lock(&self.open);
        self.cv.notify_all();
    }
}

// ---------- the queue (an actor in Swift) ----------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JobState {
    Queued,
    Running,
    Done,
    Cancelled,
}
pub struct Info {
    pub done: bool,
}
struct JobRec {
    id: u32,
    state: JobState,
    cancel: Arc<AtomicBool>,
    /// Dropped when the job ends, which finishes the progress stream (`AsyncStream.finish()`).
    tx: Option<Sender<Info>>,
}
#[derive(Default)]
struct QState {
    held: bool,
    jobs: Vec<JobRec>,
    next: u32,
}
#[derive(Clone)]
pub struct ProxyQueue {
    st: Arc<Mutex<QState>>,
    pool: Arc<WorkerPool>,
    log: Log,
    transcoder: Arc<Transcoder>,
}
impl ProxyQueue {
    pub fn new(pool: Arc<WorkerPool>, log: Log, transcoder: Arc<Transcoder>) -> Self {
        ProxyQueue { st: Arc::default(), pool, log, transcoder }
    }
    pub fn job_states(&self) -> Vec<JobState> {
        lock(&self.st).jobs.iter().map(|j| j.state).collect()
    }
    pub async fn enqueue(&self) -> (u32, Receiver<Info>) {
        yield_now().await; // actor hop
        let (tx, rx) = unbounded();
        let mut st = lock(&self.st);
        st.next += 1;
        let id = st.next;
        st.jobs.push(JobRec { id, state: JobState::Queued, cancel: Arc::default(), tx: Some(tx) });
        let held = st.held;
        drop(st);
        if !held {
            self.start(id);
        }
        (id, rx)
    }
    pub async fn set_held(&self, held: bool) {
        yield_now().await;
        let queued: Vec<u32> = {
            let mut st = lock(&self.st);
            st.held = held;
            if held { vec![] } else { st.jobs.iter().filter(|j| j.state == JobState::Queued).map(|j| j.id).collect() }
        };
        self.log.push(format!("queue.held:{held}"));
        queued.into_iter().for_each(|id| self.start(id));
    }
    pub async fn cancel(&self, id: u32) {
        yield_now().await;
        let mut st = lock(&self.st);
        if let Some(j) = st.jobs.iter_mut().find(|j| j.id == id) {
            j.cancel.store(true, Ordering::SeqCst);
            if j.state == JobState::Queued {
                j.state = JobState::Cancelled;
                j.tx = None;
                self.log.push("job canceled while queued");
            }
        }
        drop(st);
        self.transcoder.poke();
    }
    fn start(&self, id: u32) {
        let (cancel, tx) = {
            let mut st = lock(&self.st);
            let Some(j) = st.jobs.iter_mut().find(|j| j.id == id) else { return };
            if j.state != JobState::Queued {
                return;
            }
            j.state = JobState::Running;
            (j.cancel.clone(), j.tx.take())
        };
        let (st, log, tc) = (self.st.clone(), self.log.clone(), self.transcoder.clone());
        self.pool.execute(move || {
            log.push("transcode started");
            tc.wait(&cancel);
            let final_state = if cancel.load(Ordering::SeqCst) {
                log.push("transcode canceled");
                JobState::Cancelled
            } else {
                if let Some(tx) = &tx {
                    tx.send(Info { done: true });
                }
                JobState::Done
            };
            if let Some(j) = lock(&st).jobs.iter_mut().find(|j| j.id == id) {
                j.state = final_state;
            }
        });
    }
}

// ---------- the service ----------

struct Tracked {
    task: Option<JoinHandle<()>>,
    state: ProxyState<u32, ()>,
}
pub struct Svc {
    pub log: Log,
    clock: Arc<dyn Clock>,
    pool: Arc<WorkerPool>,
    pub queue: ProxyQueue,
    pub prober: Gate,
    is_busy: Arc<AtomicBool>,
    busy_poll: Duration,
    busy_resume: Duration,
    busy_held: Cell<bool>,
    idle_since: Cell<Option<Duration>>,
    busy_task: RefCell<Option<JoinHandle<()>>>,
    debounce: RefCell<Option<JoinHandle<()>>>,
    /// Settings as the user set them vs as applied (`settings.mode(...) != self.mode`).
    pub setting: Cell<u32>,
    applied: Cell<u32>,
    pub refreshes: Cell<u32>,
    tracked: RefCell<HashMap<u32, Tracked>>,
    last_media: RefCell<Vec<u32>>,
}
pub type Service = Rc<Svc>;

pub fn new_service(
    log: Log,
    clock: Arc<dyn Clock>,
    pool: Arc<WorkerPool>,
    transcoder: Arc<Transcoder>,
    is_busy: Arc<AtomicBool>,
    prober: Gate,
) -> Service {
    Rc::new(Svc {
        queue: ProxyQueue::new(pool.clone(), log.clone(), transcoder),
        log,
        clock,
        pool,
        prober,
        is_busy,
        busy_poll: Duration::from_millis(500),
        busy_resume: Duration::from_secs(2),
        busy_held: Cell::new(false),
        idle_since: Cell::new(None),
        busy_task: RefCell::new(None),
        debounce: RefCell::new(None),
        setting: Cell::new(0),
        applied: Cell::new(0),
        refreshes: Cell::new(0),
        tracked: RefCell::default(),
        last_media: RefCell::default(),
    })
}

impl Svc {
    pub fn is_busy_held(&self) -> bool {
        self.busy_held.get()
    }
    pub fn is_busy_polling(&self) -> bool {
        self.busy_task.borrow().is_some()
    }
    pub fn pending_media(&self) -> Vec<u32> {
        let mut v: Vec<u32> = self
            .tracked
            .borrow()
            .iter()
            .filter(|(_, t)| !t.state.is_ready() && t.state.job().is_some())
            .map(|(k, _)| *k)
            .collect();
        v.sort();
        v
    }
    pub fn ready_media(&self) -> Vec<u32> {
        let mut v: Vec<u32> =
            self.tracked.borrow().iter().filter(|(_, t)| t.state.is_ready()).map(|(k, _)| *k).collect();
        v.sort();
        v
    }
    pub fn tracked_count(&self) -> usize {
        self.tracked.borrow().len()
    }

    fn apply_hold(&self) {
        let (q, hold) = (self.queue.clone(), self.busy_held.get());
        spawn_local(async move { q.set_held(hold).await });
    }
    /// One reading of the busy signal (`pollBusy`).
    pub fn poll_busy(&self) {
        if self.is_busy.load(Ordering::SeqCst) {
            self.idle_since.set(None);
            if !self.busy_held.get() {
                self.busy_held.set(true);
                self.apply_hold();
            }
        } else if self.busy_held.get() {
            let now = self.clock.now();
            let since = self.idle_since.get().unwrap_or(now);
            self.idle_since.set(Some(since));
            if now - since >= self.busy_resume {
                self.busy_held.set(false);
                self.idle_since.set(None);
                self.apply_hold();
            }
        }
    }
    fn needs_busy_polling(&self) -> bool {
        self.tracked.borrow().values().any(|t| t.state.is_active())
    }
    fn ensure_busy_polling(self: &Rc<Self>) {
        self.poll_busy();
        if self.busy_task.borrow().is_some() {
            return;
        }
        let w: Weak<Svc> = Rc::downgrade(self);
        let h = spawn_cooperative(async move {
            while !is_cancelled() {
                let Some(me) = w.upgrade() else { return };
                me.poll_busy();
                if !me.needs_busy_polling() && !me.busy_held.get() {
                    *me.busy_task.borrow_mut() = None;
                    return;
                }
                let d = me.busy_poll;
                drop(me);
                let _ = sleep(d).await; // try? await Task.sleep
            }
        });
        *self.busy_task.borrow_mut() = Some(h);
    }

    /// Settings changed: re-read after 100 ms of quiet (`defaultsChanged`).
    pub fn defaults_changed(self: &Rc<Self>) {
        if let Some(h) = self.debounce.borrow().as_ref() {
            h.cancel();
        }
        let w = Rc::downgrade(self);
        let h = spawn_cooperative(async move {
            let _ = sleep(Duration::from_millis(100)).await;
            if is_cancelled() {
                return;
            }
            let Some(me) = w.upgrade() else { return };
            if me.setting.get() != me.applied.get() {
                me.refresh();
            }
        });
        *self.debounce.borrow_mut() = Some(h);
    }
    pub fn refresh(self: &Rc<Self>) {
        self.refreshes.set(self.refreshes.get() + 1);
        self.applied.set(self.setting.get());
        self.log.push("refresh");
        let media = self.last_media.borrow().clone();
        self.sync(&media);
    }

    pub fn sync(self: &Rc<Self>, media: &[u32]) {
        *self.last_media.borrow_mut() = media.to_vec();
        let gone: Vec<u32> = self.tracked.borrow().keys().filter(|k| !media.contains(k)).copied().collect();
        for id in gone {
            let t = self.tracked.borrow_mut().remove(&id);
            if let Some(t) = t {
                self.stop(t);
            }
        }
        for &id in media {
            if !self.tracked.borrow().contains_key(&id) {
                self.tracked.borrow_mut().insert(id, Tracked { task: None, state: ProxyState::NotNeeded });
                self.start(id);
            }
        }
    }
    fn stop(&self, t: Tracked) {
        if let Some(h) = &t.task {
            h.cancel();
        }
        if let Some(job) = t.state.job() {
            self.release(job);
        }
    }
    fn release(&self, job: u32) {
        if self.tracked.borrow().values().any(|t| t.state.job() == Some(job)) {
            return;
        }
        let q = self.queue.clone();
        spawn_local(async move { q.cancel(job).await });
    }

    fn start(self: &Rc<Self>, id: u32) {
        let w = Rc::downgrade(self);
        let (gate, pool, queue, log) = (self.prober.clone(), self.pool.clone(), self.queue.clone(), self.log.clone());
        let task = spawn_cooperative(async move {
            gate.wait().await; // try? await prober.probe(url)
            if is_cancelled() {
                return;
            }
            let _disk = pool.run(|_| 100u64).await; // diskNow() off the UI thread
            if is_cancelled() {
                return;
            }
            let (job, mut rx) = queue.enqueue().await;
            log.push(format!("enqueued:{id}"));
            let Some(me) = w.upgrade() else { return };
            let live = me.tracked.borrow().contains_key(&id);
            if !live || is_cancelled() {
                me.release(job);
                return;
            }
            if let Some(t) = me.tracked.borrow_mut().get_mut(&id) {
                t.state = std::mem::replace(&mut t.state, ProxyState::NotNeeded).next(ProxyEvent::JobQueued { job });
            }
            drop(me);
            while let Some(info) = rx.next().await {
                if is_cancelled() {
                    break;
                }
                if info.done
                    && let Some(me) = w.upgrade()
                {
                    if let Some(t) = me.tracked.borrow_mut().get_mut(&id) {
                        t.state = std::mem::replace(&mut t.state, ProxyState::NotNeeded)
                            .next(ProxyEvent::JobDone { record: None });
                    }
                    me.log.push(format!("proxy ready:{id}"));
                }
            }
        });
        if let Some(t) = self.tracked.borrow_mut().get_mut(&id) {
            t.task = Some(task);
            t.state = std::mem::replace(&mut t.state, ProxyState::NotNeeded).next(ProxyEvent::DecisionStarted);
        }
        self.ensure_busy_polling();
    }
}
