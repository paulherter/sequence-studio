//! Port of `EditorSession.write/save/saveAs/tickAutosave` (Packages/SQEditorSession/.../EditorSession.swift:1759-1820, 2010-2030)
//! and `ProjectSaveQueue` (ProjectSaveQueue.swift). The Swift `actor` becomes a pool; serial iff the pool has one thread.
use super::Log;
use crate::{Clock, WorkerPool, yield_now};
use std::cell::{Cell, RefCell};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SaveError {
    NoFileUrl,
    ProjectChanged,
    Write(String),
}
#[derive(Clone, Debug)]
pub struct Snapshot {
    pub name: String,
    pub revision: u32,
}
pub type Writer = Arc<dyn Fn(&Snapshot, &str) -> Result<(), String> + Send + Sync>;

/// `ProjectSaveQueue`: all disk work, off the UI thread, FIFO.
#[derive(Clone)]
pub struct SaveQueue {
    pool: Arc<WorkerPool>,
    writer: Writer,
    pub autosaves: Arc<Mutex<Vec<(String, Duration)>>>,
}
impl SaveQueue {
    pub fn new(pool: Arc<WorkerPool>, writer: Writer) -> Self {
        SaveQueue { pool, writer, autosaves: Arc::default() }
    }
    pub async fn write(&self, s: Snapshot, url: String) -> Result<(), SaveError> {
        let w = self.writer.clone();
        match self.pool.run(move |_| w(&s, &url)).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) => Err(SaveError::Write(e)),
            Err(_) => Err(SaveError::Write("writer panicked".into())),
        }
    }
    pub async fn autosave(&self, s: Snapshot, date: Duration) -> Result<(), SaveError> {
        let store = self.autosaves.clone();
        self.pool
            .run(move |_| store.lock().unwrap_or_else(|e| e.into_inner()).push((s.name, date)))
            .await
            .map_err(|_| SaveError::Write("autosave panicked".into()))
    }
}

/// `AutosavePolicy.shouldAutosave`: dirty and (never autosaved or the interval passed).
pub const AUTOSAVE_INTERVAL: Duration = Duration::from_secs(300);

pub struct Session {
    pub log: Log,
    project_id: Cell<u32>,
    name: RefCell<String>,
    revision: Cell<u32>,
    saved_revision: Cell<u32>,
    force_dirty: Cell<bool>,
    file_url: RefCell<Option<String>>,
    queue: SaveQueue,
    clock: Arc<dyn Clock>,
    last_autosave: Cell<Option<Duration>>,
    pub errors: RefCell<Vec<String>>,
}
impl Session {
    pub fn new(name: &str, queue: SaveQueue, clock: Arc<dyn Clock>, log: Log) -> Self {
        Session {
            log,
            project_id: Cell::new(1),
            name: RefCell::new(name.into()),
            revision: Cell::new(0),
            saved_revision: Cell::new(0),
            force_dirty: Cell::new(false),
            file_url: RefCell::new(None),
            queue,
            clock,
            last_autosave: Cell::new(None),
            errors: RefCell::default(),
        }
    }
    pub fn name(&self) -> String {
        self.name.borrow().clone()
    }
    pub fn file_url(&self) -> Option<String> {
        self.file_url.borrow().clone()
    }
    pub fn set_file_url(&self, u: Option<&str>) {
        *self.file_url.borrow_mut() = u.map(String::from);
    }
    pub fn is_dirty(&self) -> bool {
        self.force_dirty.get() || self.revision.get() != self.saved_revision.get()
    }
    /// An edit (`session.perform("Rename") { $0.name = ... }`).
    pub fn perform_rename(&self, name: &str) {
        *self.name.borrow_mut() = name.into();
        self.revision.set(self.revision.get() + 1);
    }
    /// open / new / recover: another project replaces this one.
    pub fn replace_project(&self, name: &str) {
        self.project_id.set(self.project_id.get() + 1);
        *self.name.borrow_mut() = name.into();
        self.revision.set(0);
        self.saved_revision.set(0);
        self.force_dirty.set(false);
        *self.file_url.borrow_mut() = None;
    }
    fn snapshot(&self) -> (u32, Snapshot) {
        (self.revision.get(), Snapshot { name: self.name(), revision: self.revision.get() })
    }
    fn set_error(&self, m: String) {
        self.errors.borrow_mut().push(m);
    }

    pub async fn save(&self) -> Result<(), SaveError> {
        let Some(url) = self.file_url() else { return Err(SaveError::NoFileUrl) };
        self.write(&url).await
    }
    pub async fn save_as(&self, url: &str) -> Result<(), SaveError> {
        self.write(url).await?;
        *self.file_url.borrow_mut() = Some(url.into());
        Ok(())
    }

    async fn write(&self, url: &str) -> Result<(), SaveError> {
        let project_id = self.project_id.get();
        self.log.push("collectLUTs");
        yield_now().await; // `await collectLUTs(forSaveAt:)`: a suspension point where the project can be replaced
        if self.project_id.get() != project_id {
            return Err(SaveError::ProjectChanged);
        }
        let (base, snapshot) = self.snapshot();
        if let Err(e) = self.queue.write(snapshot, url.into()).await {
            self.set_error(format!("Could not save:{e:?}"));
            return Err(e);
        }
        if self.project_id.get() != project_id {
            return Err(SaveError::ProjectChanged);
        }
        let unchanged = self.revision.get() == base;
        self.saved_revision.set(base);
        let dirty_before = self.force_dirty.get();
        self.force_dirty.set(if unchanged { false } else { dirty_before });
        Ok(())
    }

    pub async fn tick_autosave(&self) -> bool {
        let now = self.clock.now();
        let due = self.last_autosave.get().is_none_or(|l| now.saturating_sub(l) >= AUTOSAVE_INTERVAL);
        if !(self.is_dirty() && due) {
            return false;
        }
        let (_, snapshot) = self.snapshot();
        let project_id = self.project_id.get();
        match self.queue.autosave(snapshot, now).await {
            Ok(()) => {
                if self.project_id.get() != project_id {
                    return false; // the version belongs to the old project
                }
                self.last_autosave.set(Some(now));
                self.log.push("autosave ok");
                true
            }
            Err(e) => {
                self.set_error(format!("Autosave failed: {e:?}"));
                false
            }
        }
    }
}
