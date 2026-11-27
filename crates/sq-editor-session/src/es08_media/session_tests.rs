//! Tests of the ES8 session parts that need a session: disk looks, growing files, relink helpers, the render cache and
//! AutoProxy. (Swift: MediaDiskTrackerTests, GrowingFileRefreshTests, RelinkOfferTests, RelinkNearProjectTests,
//! RenderCacheResolverTests, AutoProxyServiceTests.) The async flows are tested through their synchronous halves.

use std::cell::Cell;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use sq_core_model::{MediaFingerprint, MediaRef};
use sq_core_time::{Id, IdSource, SequentialIds, Time, Timestamp};
use sq_library::media_file_stamp::MediaFileStamp;
use sq_media::media_error::MediaError;
use sq_media::media_opener::{MediaOpener, OpenedMedia};
use sq_proxy::auto_proxy::{MachineProfile, ProxyDefaults, ProxyMode, ProxySettingsStore};
use sq_proxy::model::ProxyKind;
use sq_proxy::proxy_cache::ProxyCache;
use sq_proxy::proxy_policy::{SourceSeekInfo, SourceSeekProbing};
use sq_proxy::proxy_transcoding::ProxyTranscodeError;

use crate::es08_media::testing;
use crate::es08_media::*;
use crate::{Change, EditorSession, ProxyUse, SessionDeps, SessionEvent};

struct TempDir(PathBuf);

impl TempDir {
    fn new(tag: &str) -> TempDir {
        static N: AtomicUsize = AtomicUsize::new(0);
        let dir = std::env::temp_dir().join(format!(
            "sq-es08-{tag}-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&dir).unwrap_or_default();
        TempDir(dir)
    }

    fn path(&self) -> &Path {
        &self.0
    }

    fn file(&self, rel: &str, bytes: usize) -> PathBuf {
        let p = self.0.join(rel);
        if let Some(parent) = p.parent() {
            std::fs::create_dir_all(parent).unwrap_or_default();
        }
        std::fs::write(&p, vec![7u8; bytes]).unwrap_or_default();
        p
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn id(n: u128) -> Id {
    Id::from_u128(n)
}

fn media_at(n: u128, path: &str, size: i64) -> MediaRef {
    MediaRef::new(id(n), "a.mov", path, MediaFingerprint::new(size))
}

fn session_with(media: Vec<MediaRef>, file_url: Option<PathBuf>) -> EditorSession {
    let mut ids = SequentialIds::default();
    let mut project = EditorSession::make_untitled(&mut ids);
    for m in media {
        project.add(m);
    }
    let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-es08-autosave"));
    deps.ids = Box::new(ids);
    deps.file_url = file_url;
    EditorSession::new(project, deps)
}

/// One disk look without the worker: stat, fold in, return the touched items.
fn disk_look(s: &mut EditorSession) -> BTreeSet<Id> {
    let Some(job) = s.begin_disk_refresh() else { return BTreeSet::new() };
    let snapshot = MediaDiskTracker::snapshot(&job.paths);
    s.finish_disk_refresh(&job, Some(snapshot)).touched
}

// MARK: MediaDiskTracker

fn state(id: Id, exists: bool, size: i64, t: f64) -> BTreeMap<Id, MediaDiskState> {
    let s = MediaDiskState::new(exists, exists.then_some(size), exists.then(|| Timestamp::from_unix_seconds(t)));
    BTreeMap::from([(id, s)])
}

#[test]
fn first_look_only_records() {
    let mut t = MediaDiskTracker::new();
    assert!(t.update(state(id(1), true, 10, 100.0)).is_empty());
    assert!(t.update(state(id(1), true, 10, 100.0)).is_empty());
}

#[test]
fn overwritten_file_is_modified() {
    let (a, mut t) = (id(1), MediaDiskTracker::new());
    t.update(state(a, true, 10, 100.0));
    assert_eq!(t.update(state(a, true, 20, 100.0)).modified, BTreeSet::from([a]));
    assert_eq!(t.update(state(a, true, 20, 200.0)).modified, BTreeSet::from([a])); // date only
    assert!(t.update(state(a, true, 20, 200.0)).is_empty());
}

#[test]
fn gone_and_back() {
    let (a, mut t) = (id(1), MediaDiskTracker::new());
    t.update(state(a, true, 10, 100.0));
    assert_eq!(t.update(state(a, false, 10, 100.0)).vanished, BTreeSet::from([a]));
    assert!(t.update(state(a, false, 10, 100.0)).is_empty());
    let back = t.update(state(a, true, 10, 100.0));
    assert_eq!(back.appeared, BTreeSet::from([a]));
    assert_eq!(back.all(), BTreeSet::from([a]));
}

#[test]
fn item_new_to_the_project_is_a_baseline() {
    let mut t = MediaDiskTracker::new();
    t.update(BTreeMap::new());
    assert!(t.update(state(id(1), true, 10, 100.0)).is_empty());
    assert_eq!(t.known_count(), 1);
    assert!(t.is_online(id(1)) && !t.is_online(id(2)));
    t.accept(id(2), MediaDiskState::new(true, Some(1), None));
    assert!(t.is_online(id(2)));
}

#[test]
fn reads_a_real_file() {
    let dir = TempDir::new("read");
    let p = dir.path().join("a.bin");
    assert!(!MediaDiskState::read(&p.to_string_lossy()).exists);
    std::fs::write(&p, [1, 2, 3]).unwrap_or_default();
    let s = MediaDiskState::read(&p.to_string_lossy());
    assert!(s.exists && s.size == Some(3) && s.modified.is_some());
}

// MARK: Session disk looks

#[test]
fn file_replaced_on_disk_is_reported_once() {
    let dir = TempDir::new("disk");
    let f = dir.file("a.mov", 3);
    let m = media_at(1, &f.to_string_lossy(), 1);
    let mut s = session_with(vec![m], None);
    assert!(disk_look(&mut s).is_empty()); // baseline
    std::fs::write(&f, [1, 2, 3, 4, 5]).unwrap_or_default();
    assert_eq!(disk_look(&mut s), BTreeSet::from([id(1)]));
    let events: Vec<_> =
        s.take_events().into_iter().filter(|e| matches!(e, SessionEvent::MediaFilesChanged(_))).collect();
    assert_eq!(events, vec![SessionEvent::MediaFilesChanged(BTreeSet::from([id(1)]))]);
    assert!(s.requested_media.contains(&id(1)));
    assert!(disk_look(&mut s).is_empty());
}

#[test]
fn vanished_and_returned_file_is_reported() {
    let dir = TempDir::new("disk2");
    let f = dir.file("a.mov", 3);
    let mut s = session_with(vec![media_at(1, &f.to_string_lossy(), 1)], None);
    disk_look(&mut s);
    std::fs::remove_file(&f).unwrap_or_default();
    assert_eq!(disk_look(&mut s), BTreeSet::from([id(1)]));
    assert!(!s.requested_media.contains(&id(1)), "a vanished file is not reopened");
    std::fs::write(&f, [1, 2, 3]).unwrap_or_default();
    assert_eq!(disk_look(&mut s), BTreeSet::from([id(1)]));
    assert!(s.requested_media.contains(&id(1)));
}

#[test]
fn a_running_look_blocks_the_next_one_and_a_replaced_project_drops_the_result() {
    let mut s = session_with(vec![media_at(1, "/nowhere/a.mov", 1)], None);
    let job = s.begin_disk_refresh();
    assert!(job.is_some() && s.begin_disk_refresh().is_none());
    let mut stale = job.unwrap_or_else(unreachable_job);
    stale.project = id(999);
    let applied = s.finish_disk_refresh(&stale, Some(state(id(1), true, 1, 1.0)));
    assert!(applied.touched.is_empty());
    assert_eq!(s.disk_tracker.known_count(), 0);
    assert!(s.begin_disk_refresh().is_some(), "the flag is released");
}

fn unreachable_job() -> DiskRefreshJob {
    DiskRefreshJob { project: id(0), paths: BTreeMap::new() }
}

#[test]
fn applying_changes_tells_engines_and_views() {
    let mut s = session_with(vec![media_at(1, "/nowhere/a.mov", 1)], None);
    let before = s.versions()[Change::MEDIA.index().unwrap_or(0)];
    let changes = MediaDiskChanges { modified: BTreeSet::from([id(1)]), ..Default::default() };
    let applied = s.apply_disk_changes(&changes);
    assert_eq!((applied.touched.len(), applied.reopen.clone()), (1, vec![id(1)]));
    assert!(s.versions()[Change::MEDIA.index().unwrap_or(0)] > before);
    let engine = s.engine.as_any().downcast_ref::<crate::StubProgramEngine>();
    assert_eq!(engine.map(|e| e.changed_media.clone()), Some(vec![BTreeSet::from([id(1)])]));
}

// MARK: Growing files

#[test]
fn off_or_nothing_online_does_not_poll() {
    assert!(!GrowingFilePolicy::decide(false, 3, false, false, 0).poll);
    assert!(!GrowingFilePolicy::decide(true, 0, false, false, 0).poll);
}

#[test]
fn busy_work_skips_the_stats_and_waits_longer() {
    let idle = GrowingFilePolicy::decide(true, 2, false, false, 0);
    let play = GrowingFilePolicy::decide(true, 2, true, false, 0);
    let export = GrowingFilePolicy::decide(true, 2, false, true, 0);
    assert!(idle.poll && !play.poll && !export.poll);
    assert!(play.next > idle.next && export.next > idle.next);
}

#[test]
fn quiet_project_backs_off() {
    let fresh = GrowingFilePolicy::decide(true, 1, false, false, 0);
    let calm = GrowingFilePolicy::decide(true, 1, false, false, GrowingFilePolicy::QUIET_POLLS_BEFORE_BACKOFF);
    assert!(calm.poll && calm.next > fresh.next);
}

#[test]
fn refreshed_item_takes_new_length_and_stamp() {
    let mut old = MediaRef::new(id(1), "a.mov", "/a.mov", MediaFingerprint::new(10));
    old.fingerprint.head_hash = Some("h".into());
    old.duration = Some(Time::new(5, 1));
    old.info = Some(testing::info(Time::new(5, 1), None));
    let when = Timestamp::from_unix_seconds(500.0);
    let new = GrowingFileProbe::refreshed(
        &old,
        testing::info(Time::new(9, 1), None),
        Some(MediaFileStamp { size: 99, modified: when }),
    );
    assert_eq!(new.duration, Some(Time::new(9, 1)));
    assert_eq!(new.info.map(|i| i.duration), Some(Time::new(9, 1)));
    assert!(new.fingerprint.size == 99 && new.fingerprint.modified == Some(when));
    assert_eq!(new.fingerprint.head_hash.as_deref(), Some("h"));
    assert!(new.id == old.id && new.path == old.path);
}

#[test]
fn a_reprobe_is_folded_in_without_an_undo_step() {
    let mut s = session_with(vec![media_at(1, "/a.mov", 10)], None);
    let mut found = Reprobed::new();
    found.insert(
        id(1),
        (
            testing::info(Time::new(9, 1), None),
            Some(MediaFileStamp { size: 99, modified: Timestamp::from_unix_seconds(5.0) }),
        ),
    );
    s.requested_media.insert(id(1));
    s.fold_growing_probes(found);
    let m = s.project().media(id(1));
    assert_eq!(m.map(|m| (m.fingerprint.size, m.duration)), Some((99, Some(Time::new(9, 1)))));
    assert!(!s.can_undo());
    assert!(s.is_dirty());
    assert!(!s.requested_media.contains(&id(1)));
}

// MARK: Relink

fn volumes_free(d: &TempDir, name: &str) -> PathBuf {
    let p = d.path().join(name);
    std::fs::create_dir_all(&p).unwrap_or_default();
    p
}

#[test]
fn roots_include_old_folder_and_extras_once() {
    let d = TempDir::new("roots");
    let (old, extra) = (volumes_free(&d, "Old"), volumes_free(&d, "Extra"));
    let m = media_at(1, &old.join("a.mov").to_string_lossy(), 1);
    let roots = EditorSession::relink_offer_roots(&[m], &[], None, &[extra.clone(), extra.clone()]);
    assert_eq!(roots, vec![(old, 1), (extra, 12)]);
}

#[test]
#[cfg(unix)] // a `/Volumes/...` path is not absolute on Windows, where the volume rule does not apply
fn other_volume_counterpart_is_searched() {
    let d = TempDir::new("vols");
    let vol = volumes_free(&d, "NEWDISK");
    let shots = vol.join("Shots");
    std::fs::create_dir_all(&shots).unwrap_or_default();
    let m = media_at(1, "/Volumes/OLDDISK/Shots/a.mov", 1);
    let roots = EditorSession::relink_offer_roots(&[m], &[PathBuf::from("/Volumes/OLDDISK"), vol], None, &[]);
    assert_eq!(roots, vec![(shots, 1)]);
}

#[test]
fn quiet_relink_changes_the_path_without_an_undo_step() {
    let d = TempDir::new("quiet");
    let file = d.file("a.mov", 3);
    let mut s = session_with(vec![media_at(1, "/nowhere/a.mov", 3)], None);
    s.relink_media_quietly(&BTreeMap::from([(id(1), file.to_string_lossy().into_owned())]));
    assert_eq!(s.project().media(id(1)).map(|m| m.path.clone()), Some(file.to_string_lossy().into_owned()));
    assert!(!s.can_undo() && s.is_dirty());
}

#[test]
fn relink_with_a_name_is_one_undo_step() {
    let d = TempDir::new("named");
    let file = d.file("a.mov", 3);
    let mut s = session_with(vec![media_at(1, "/nowhere/a.mov", 3)], None);
    s.relink_media(&BTreeMap::from([(id(1), file.to_string_lossy().into_owned())]), "Reconnect Media");
    assert!(s.can_undo());
}

// MARK: Render cache

struct NoOpener;

impl MediaOpener for NoOpener {
    fn open(&self, _path: &Path, _media: Id) -> Result<OpenedMedia, MediaError> {
        Err(MediaError::Unreadable)
    }
}

fn resolver() -> Arc<ProjectMediaResolver> {
    Arc::new(ProjectMediaResolver::new(ResolverDeps::new(Arc::new(NoOpener))))
}

fn controller(dir: &Path, media: Arc<ProjectMediaResolver>) -> RenderCacheController {
    let inputs = RenderCacheInputs::new(
        Box::new(|| Time::ZERO),
        Box::new(|| false),
        Box::new(|| 0),
        Box::new(|| Timestamp::from_unix_seconds(1000.0)),
    );
    RenderCacheController::new(dir.to_path_buf(), 1 << 30, media, inputs, "test", 0.3, None)
}

#[test]
fn a_disabled_cache_has_no_spans_and_no_job() {
    let d = TempDir::new("rc-off");
    let mut c = controller(d.path(), resolver());
    assert!(!c.is_enabled() && c.tick().is_none());
    let t = session_with(Vec::new(), None).active_timeline().cloned();
    if let Some(t) = t {
        assert!(c.spans(&t, &BTreeMap::new()).is_empty());
        assert!(c.export_spans(&t, &BTreeMap::new()).is_empty());
    }
}

#[test]
fn turning_the_cache_on_registers_the_cached_files_and_off_forgets_them() {
    use sq_core_project::render_cache_index::RenderCacheIndex;
    use sq_core_project::render_cache_store::RenderCacheStore;
    let d = TempDir::new("rc-on");
    let key = "00000000000000000000000000000042";
    d.file(&format!("{key}.mov"), 100);
    let store = RenderCacheStore::new(
        d.path().to_path_buf(),
        1 << 30,
        sq_core_project::cache_disk_policy::CacheDiskPolicy::unchecked(),
    );
    let mut index = RenderCacheIndex::new();
    index.record(key, 100, Time::new(2, 1), Timestamp::from_unix_seconds(5.0));
    assert!(store.save(&index).is_ok());

    let media = resolver();
    let mut c = controller(d.path(), Arc::clone(&media));
    c.configure(true, d.path().to_path_buf(), 1 << 30);
    assert!(c.is_enabled() && c.take_spans_changed() && !c.take_spans_changed());
    assert_eq!(c.stats().bytes, 100);
    let fake = sq_core_model::RenderCacheMedia::id_for_key(key);
    assert_eq!(fake, id(0x42));
    // Registered: the file exists but the opener cannot read it (not "unknown media").
    assert_eq!(media.demuxer(fake).err(), Some(MediaResolveError::Unreadable(fake)));
    c.configure(false, d.path().to_path_buf(), 1 << 30);
    assert_eq!(media.demuxer(fake).err(), Some(MediaResolveError::UnknownMedia(fake)));
    assert_eq!(c.stats().bytes, 0);
}

#[test]
fn media_changed_asks_for_new_spans_only_while_enabled() {
    let d = TempDir::new("rc-media");
    let mut c = controller(d.path(), resolver());
    c.media_changed();
    assert!(!c.take_spans_changed());
    c.configure(true, d.path().to_path_buf(), 1 << 30);
    c.take_spans_changed();
    c.media_changed();
    assert!(c.take_spans_changed());
}

// MARK: AutoProxy

#[derive(Default)]
struct MemoryDefaults(HashMap<String, String>);

impl ProxyDefaults for MemoryDefaults {
    fn string(&self, key: &str) -> Option<String> {
        self.0.get(key).cloned()
    }
    fn bool(&self, key: &str) -> bool {
        self.0.get(key).is_some_and(|v| v == "1")
    }
    fn set_string(&mut self, key: &str, value: &str) {
        self.0.insert(key.into(), value.into());
    }
    fn set_bool(&mut self, key: &str, value: bool) {
        self.0.insert(key.into(), if value { "1" } else { "0" }.into());
    }
    fn remove(&mut self, key: &str) {
        self.0.remove(key);
    }
}

struct FailingProber;

impl SourceSeekProbing for FailingProber {
    fn probe(&self, _url: &Path) -> Result<SourceSeekInfo, ProxyTranscodeError> {
        Err(ProxyTranscodeError::ReaderFailed("test".into()))
    }
}

struct ProxyFixture {
    service: AutoProxyService<MemoryDefaults>,
    busy: Rc<Cell<bool>>,
    now: Rc<Cell<f64>>,
    /// Free bytes the fixture's disk reader reports; -1 = unknown.
    free: Arc<std::sync::atomic::AtomicI64>,
    dir: TempDir,
    cache: Arc<ProxyCache>,
}

fn proxy_fixture(mode: Option<ProxyMode>) -> ProxyFixture {
    proxy_fixture_on(mode, MachineProfile { memory_bytes: 8 << 30, cores: 4, is_apple_silicon: true })
}

fn proxy_fixture_on(mode: Option<ProxyMode>, machine: MachineProfile) -> ProxyFixture {
    let dir = TempDir::new("proxy");
    let cache = Arc::new(ProxyCache::new(dir.path().join("cache")));
    let mut settings = ProxySettingsStore::new(MemoryDefaults::default());
    settings.set_mode(mode, None);
    let (busy, now) = (Rc::new(Cell::new(false)), Rc::new(Cell::new(1000.0)));
    let (b, n) = (Rc::clone(&busy), Rc::clone(&now));
    let free = Arc::new(std::sync::atomic::AtomicI64::new(-1));
    let fr = Arc::clone(&free);
    let deps = AutoProxyDeps {
        resolver: resolver(),
        prober: Arc::new(FailingProber),
        machine,
        concurrency: 1,
        is_busy: Box::new(move || b.get()),
        busy_resume: 2.0,
        disk_space: Arc::new(move |_| {
            let f = fr.load(Ordering::SeqCst);
            DiskSpace { free: (f >= 0).then_some(f), total: (f >= 0).then_some(100 << 30) }
        }),
        clock: Box::new(move || Timestamp::from_unix_seconds(n.get())),
        ids: Box::new(SequentialIds::default()),
    };
    ProxyFixture { service: AutoProxyService::new(Arc::clone(&cache), settings, deps), busy, now, free, dir, cache }
}

fn video_media(n: u128, path: &Path) -> MediaRef {
    let mut m = MediaRef::new(id(n), "a.mov", &path.to_string_lossy(), MediaFingerprint::new(1));
    m.info = Some(testing::info(Time::new(10, 1), Some(testing::video(3840, 2160))));
    m
}

#[test]
fn mode_off_decides_nothing_and_turns_the_monitors_proxy_use_off() {
    let mut f = proxy_fixture(Some(ProxyMode::Off));
    let file = f.dir.file("a.mov", 100);
    f.service.sync(&[video_media(1, &file)], Some(id(50)), None);
    assert!(f.service.take_decision_work().is_empty());
    assert_eq!(f.service.take_effects(), vec![ProxyEffect::UseChanged(ProxyUse::OFF)]);
    assert_eq!(f.service.project_id(), Some(id(50)));
}

/// The playback rule (Swift `usesProxiesForPlayback`): Auto means weak machines only, which includes every machine that is
/// not Apple silicon (all Windows PCs); On and Off are absolute; the mode Off wins over everything.
#[test]
fn playback_uses_proxies_by_the_machine_class_and_the_setting() {
    use sq_proxy::auto_proxy::ProxyPlaybackMode as P;
    let strong_mac = MachineProfile { memory_bytes: 32 << 30, cores: 10, is_apple_silicon: true };
    let big_pc = MachineProfile { memory_bytes: 64 << 30, cores: 16, is_apple_silicon: false };
    let weak_mac = MachineProfile { memory_bytes: 8 << 30, cores: 8, is_apple_silicon: true };
    let playback_after_sync = |mode: ProxyMode, machine: MachineProfile, setting: Option<P>| {
        let mut f = proxy_fixture_on(Some(mode), machine);
        if let Some(p) = setting {
            f.service.settings.set_playback(p);
        }
        f.service.sync(&[], None, None);
        match f.service.take_effects().first() {
            Some(ProxyEffect::UseChanged(u)) => Some((u.scrubbing, u.playback)),
            _ => None,
        }
    };
    assert_eq!(playback_after_sync(ProxyMode::Auto, strong_mac, None), Some((true, false)));
    assert_eq!(playback_after_sync(ProxyMode::Auto, big_pc, None), Some((true, true)));
    assert_eq!(playback_after_sync(ProxyMode::Auto, weak_mac, None), Some((true, true)));
    assert_eq!(playback_after_sync(ProxyMode::Auto, strong_mac, Some(P::On)), Some((true, true)));
    assert_eq!(playback_after_sync(ProxyMode::Auto, big_pc, Some(P::Off)), Some((true, false)));
    assert_eq!(playback_after_sync(ProxyMode::Off, big_pc, Some(P::On)), Some((false, false)));
}

#[test]
fn a_changed_source_is_decided_once_and_an_offline_one_not_at_all() {
    let mut f = proxy_fixture(Some(ProxyMode::Always));
    let file = f.dir.file("a.mov", 100);
    let gone = f.dir.path().join("missing.mov");
    let media = [video_media(1, &file), video_media(2, &gone)];
    f.service.sync(&media, None, None);
    let work = f.service.take_decision_work();
    assert_eq!(work.iter().map(|w| w.media).collect::<Vec<_>>(), vec![id(1)]);
    assert!(f.service.wants_tick(), "the decision is live");
    f.service.sync(&media, None, None);
    assert!(f.service.take_decision_work().is_empty(), "same file, nothing new");
    f.dir.file("a.mov", 200);
    f.service.sync(&media, None, None);
    assert_eq!(f.service.take_decision_work().len(), 1, "a changed file starts over");
    // The first answer is stale now (a new ticket): ignored.
    f.service.decision_finished(&work[0], ProxyOutcome::Ready { record: None, software: false });
    assert!(f.service.ready_media().is_empty());
}

#[test]
fn a_cached_proxy_makes_the_media_ready_and_tells_the_monitors() {
    let mut f = proxy_fixture(Some(ProxyMode::Always));
    let file = f.dir.file("a.mov", 100);
    f.service.sync(&[video_media(1, &file)], None, None);
    let work = f.service.take_decision_work();
    f.service.take_effects();
    assert_eq!(work[0].run(), ProxyOutcome::Skipped, "the failing prober decides nothing");
    f.service.decision_finished(&work[0], ProxyOutcome::Ready { record: None, software: false });
    assert_eq!(f.service.ready_media(), BTreeSet::from([id(1)]));
    assert_eq!(f.service.take_effects(), vec![ProxyEffect::ProxiesChanged(BTreeSet::from([id(1)]))]);
    assert!(!f.service.wants_tick());
    // The file is replaced: the old proxy is dropped at once.
    f.dir.file("a.mov", 300);
    f.service.sync(&[video_media(1, &file)], None, None);
    assert!(f.service.ready_media().is_empty());
    assert!(f.service.take_effects().contains(&ProxyEffect::ProxiesChanged(BTreeSet::from([id(1)]))));
}

/// The playback set follows the live decoder fact of the resolver, not a flag stored once: a clip whose original is not
/// open (or was opened in hardware after a transient failure) is not in the set, whatever the first decision said.
#[test]
fn auto_playback_set_follows_the_live_decoder_fact() {
    let strong = MachineProfile { memory_bytes: 32 << 30, cores: 10, is_apple_silicon: true };
    let mut f = proxy_fixture_on(Some(ProxyMode::Always), strong);
    let (a, b) = (f.dir.file("a.mov", 100), f.dir.file("b.mov", 100));
    f.service.sync(&[video_media(1, &a), video_media(2, &b)], None, None);
    let work = f.service.take_decision_work();
    f.service.take_effects();
    let by = |m: u128| work.iter().find(|w| w.media == id(m)).unwrap();
    f.service.decision_finished(by(1), ProxyOutcome::Ready { record: None, software: true });
    f.service.decision_finished(by(2), ProxyOutcome::Ready { record: None, software: false });
    let effects = f.service.take_effects();
    assert!(!effects.iter().any(|e| matches!(e, ProxyEffect::PlaybackMediaChanged(_))), "no live fact: {effects:?}");
}

#[test]
fn the_disk_reserve_refuses_a_job_until_refresh() {
    let mut f = proxy_fixture(Some(ProxyMode::Always));
    let file = f.dir.file("a.mov", 100);
    f.service.sync(&[video_media(1, &file)], None, None);
    let work = f.service.take_decision_work();
    let tight = DiskSpace { free: Some(1 << 30), total: Some(100 << 30) };
    f.service.decision_finished(
        &work[0],
        ProxyOutcome::NeedsJob { kind: ProxyKind::ProxyHalf, software: false, estimate: 5 << 30, disk: tight },
    );
    assert_eq!(f.service.disk_refused_media(), BTreeSet::from([id(1)]));
    assert!(f.service.pending_media().is_empty());
    f.service.refresh();
    assert_eq!(f.service.take_decision_work().len(), 1, "refresh decides refused media again");
}

#[test]
fn the_disk_notice_shows_once_stays_while_refused_and_ends_when_space_is_freed() {
    let mut f = proxy_fixture(Some(ProxyMode::Always));
    let file = f.dir.file("a.mov", 100);
    f.service.sync(&[video_media(1, &file)], Some(id(9)), None);
    let work = f.service.take_decision_work();
    let tight = DiskSpace { free: Some(11 << 30), total: Some(100 << 30) };
    f.free.store(11 << 30, Ordering::SeqCst);
    f.service.decision_finished(
        &work[0],
        ProxyOutcome::NeedsJob { kind: ProxyKind::ProxyHalf, software: false, estimate: 12 << 30, disk: tight },
    );
    assert_eq!(
        f.service.take_disk_notice().as_deref(),
        Some("Not enough disk space for preview files: 11 GB free, 17 GB needed. Playback may stutter.")
    );
    assert!(f.service.disk_notice_active() && f.service.wants_tick());
    assert_eq!(f.service.take_disk_notice(), None, "once");
    // Still no room after the re-check interval: nothing changes, no second line.
    f.now.set(f.now.get() + 31.0);
    f.service.tick();
    assert!(f.service.disk_notice_active());
    assert_eq!(f.service.take_disk_notice(), None);
    // Space is freed: the re-check decides the media again, and the notice goes once nothing is refused.
    f.free.store(60 << 30, Ordering::SeqCst);
    f.now.set(f.now.get() + 31.0);
    f.service.tick();
    assert!(f.service.disk_refused_media().is_empty());
    let again = f.service.take_decision_work();
    assert_eq!(again.len(), 1);
    f.service.tick();
    assert!(f.service.disk_notice_active(), "the new decision is out: the notice waits for its answer");
    f.service.decision_finished(&again[0], ProxyOutcome::Skipped);
    f.service.tick();
    assert!(!f.service.disk_notice_active());
}

#[test]
fn a_disk_refusal_says_why_in_the_app_log() {
    let tight = DiskSpace { free: Some(11 << 30), total: Some(100 << 30) };
    use crate::es08_media::auto_proxy::disk_refusal_line;
    let line = disk_refusal_line(5 << 30, 1 << 30, tight);
    assert_eq!(
        line,
        "proxy refused: disk reserve, needs 5.0 GB (+1.0 GB queued), 11.0 GB free; the volume keeps at least 5.0 GB free"
    );
    assert!(disk_refusal_line(1, 0, DiskSpace { free: None, total: None }).contains("unknown free"));
}

#[test]
fn a_job_is_queued_with_its_reserve_and_canceled_when_the_media_leaves() {
    let mut f = proxy_fixture(Some(ProxyMode::Always));
    let file = f.dir.file("a.mov", 100);
    f.service.sync(&[video_media(1, &file)], None, None);
    let work = f.service.take_decision_work();
    let roomy = DiskSpace { free: Some(500 << 30), total: Some(1000 << 30) };
    f.service.decision_finished(
        &work[0],
        ProxyOutcome::NeedsJob { kind: ProxyKind::ProxyHalf, software: false, estimate: 1 << 30, disk: roomy },
    );
    assert_eq!(f.service.pending_media(), BTreeSet::from([id(1)]));
    assert_eq!(f.service.reserved_disk_bytes(), 1 << 30);
    assert_eq!(f.service.take_started_jobs().len(), 1, "the free slot starts it");
    f.service.sync(&[], None, None);
    assert!(f.service.pending_media().is_empty());
    assert_eq!(f.service.reserved_disk_bytes(), 0);
}

#[test]
fn playing_or_exporting_holds_the_queue_and_idle_releases_it_after_the_resume_time() {
    let mut f = proxy_fixture(Some(ProxyMode::Always));
    assert!(!f.service.is_busy_held());
    f.busy.set(true);
    f.service.tick();
    assert!(f.service.is_busy_held() && f.service.queue.is_held() && f.service.wants_tick());
    f.busy.set(false);
    f.service.tick(); // idle starts counting
    assert!(f.service.is_busy_held());
    f.now.set(1001.0);
    f.service.tick();
    assert!(f.service.is_busy_held(), "a pause between two plays does not restart a transcode");
    f.now.set(1002.5);
    f.service.tick();
    assert!(!f.service.is_busy_held() && !f.service.queue.is_held());
    f.service.set_held(true);
    assert!(f.service.queue.is_held());
    f.service.set_held(false);
    assert!(!f.service.queue.is_held());
}

#[test]
fn a_proxy_can_only_match_an_index_without_hidden_samples() {
    use sq_media::sample_index::Entry;
    let e = |pts: i64, dur: i64| Entry {
        pts: Time::new(pts, 30),
        dts: Time::new(pts, 30),
        duration: Time::new(dur, 30),
        is_sync: true,
        decode_ordinal: pts,
    };
    let can = AutoProxyService::<MemoryDefaults>::proxy_can_match;
    assert!(can(&sq_media::sample_index::SampleIndex::new(vec![e(0, 1), e(1, 1)])));
    assert!(!can(&sq_media::sample_index::SampleIndex::new(vec![e(0, 1), e(1, 0)])));
    assert!(!can(&sq_media::sample_index::SampleIndex::new(Vec::new())));
}

#[test]
fn make_builds_the_cache_in_the_given_folder() {
    let dir = TempDir::new("make");
    let deps = AutoProxyDeps {
        resolver: resolver(),
        prober: Arc::new(FailingProber),
        machine: MachineProfile { memory_bytes: 32 << 30, cores: 10, is_apple_silicon: true },
        concurrency: 1,
        is_busy: Box::new(|| false),
        busy_resume: 2.0,
        disk_space: Arc::new(|_| DiskSpace { free: None, total: None }),
        clock: Box::new(|| Timestamp::from_unix_seconds(0.0)),
        ids: Box::new(SequentialIds::default()),
    };
    let s = AutoProxyService::make(dir.path().join("p"), ProxySettingsStore::new(MemoryDefaults::default()), deps);
    assert_eq!(s.cache.directory(), dir.path().join("p"));
}

#[allow(dead_code)]
fn ids_are_unique() -> Id {
    SequentialIds::default().next_id()
}

#[test]
fn relink_missing_finds_files_by_name_and_size_in_one_undo_step() {
    let d = TempDir::new("missing");
    let file = d.file("a.mov", 3);
    d.file("b.mov", 99);
    let mut s = session_with(vec![media_at(1, "/nowhere/a.mov", 3), media_at(2, "/nowhere/b.mov", 5)], None);
    let out = s.relink_missing(d.path());
    assert_eq!((out.relinked, out.offline, out.size_differs), (1, 2, 1));
    // The scanner reports paths with forward slashes on every platform.
    let slashes = |p: String| p.replace('\\', "/");
    assert_eq!(
        s.project().media(id(1)).map(|m| slashes(m.path.clone())),
        Some(slashes(file.to_string_lossy().into_owned()))
    );
    assert!(s.can_undo());
    let quiet = s.relink_missing_in(&[d.path().to_path_buf()], false);
    assert_eq!(quiet.relinked, 0);
}

#[test]
fn missing_siblings_offers_files_beside_the_located_one() {
    let d = TempDir::new("siblings");
    let file = d.file("b.mov", 5);
    let s = session_with(vec![media_at(1, "/nowhere/a.mov", 3), media_at(2, "/nowhere/b.mov", 5)], None);
    let plan = s.missing_siblings(d.path(), id(1));
    assert_eq!(plan, BTreeMap::from([(id(2), file.to_string_lossy().replace('\\', "/"))]));
}

#[test]
fn proxy_effects_reach_the_program_engine() {
    struct Fake(Vec<ProxyEffect>);
    impl crate::SessionProxyServing for Fake {
        fn project_id(&self) -> Option<Id> {
            None
        }
        fn sync(&mut self, _: &[MediaRef], _: Option<Id>, _: Option<&sq_core_model::Timeline>) {}
        fn take_effects(&mut self) -> Vec<ProxyEffect> {
            std::mem::take(&mut self.0)
        }
    }
    let mut s = session_with(Vec::new(), None);
    s.set_auto_proxy(Some(Box::new(Fake(vec![ProxyEffect::UseChanged(ProxyUse::DEFAULT)]))));
    let seen = s.engine().as_any().downcast_ref::<crate::StubProgramEngine>().map(|e| e.proxy_use);
    assert_eq!(seen, Some(Some(ProxyUse::DEFAULT)));
}

#[test]
fn a_skipped_proxy_decision_gives_no_notice() {
    let mut f = proxy_fixture(Some(ProxyMode::Always));
    let file = f.dir.file("a.mov", 100);
    f.service.sync(&[video_media(1, &file)], Some(id(9)), None);
    let work = f.service.take_decision_work();
    f.service.decision_finished(&work[0], ProxyOutcome::Skipped);
    assert_eq!(f.service.take_disk_notice(), None, "skipped: log only");
}

// MARK: Proxy queue follows the playhead

/// Media 1 sits at 0..10 s, media 2 at 1000..1010 s of the active timeline.
fn two_clip_timeline() -> sq_core_model::Timeline {
    use sq_core_model::{Clip, SequenceFormat, Timeline, Track, TrackKind};
    use sq_core_time::TimeRange;
    let clip = |n: u128, at: i64| {
        let source = TimeRange::new(Time::ZERO, Time::new(10, 1));
        Clip::new(id(900 + n), "c", id(n), TrackKind::Video, source, Time::new(at, 1))
    };
    let mut track = Track::new(id(70), TrackKind::Video);
    track.set_clips(vec![clip(1, 0), clip(2, 1000)]);
    Timeline::new(id(71), "T", SequenceFormat::new(Time::new(1, 30)), vec![track])
}

fn needs_job() -> ProxyOutcome {
    let roomy = DiskSpace { free: Some(500 << 30), total: Some(1000 << 30) };
    ProxyOutcome::NeedsJob { kind: ProxyKind::ProxyHalf, software: false, estimate: 1 << 30, disk: roomy }
}

#[test]
fn the_source_under_the_playhead_is_transcoded_first_and_moving_the_playhead_reorders_the_queue() {
    let timeline = two_clip_timeline();
    // The playhead is known before the sync: B (import order second) goes first.
    let mut f = proxy_fixture(Some(ProxyMode::Always));
    let (a, b) = (f.dir.file("a.mov", 100), f.dir.file("b.mov", 200));
    let media = [video_media(1, &a), video_media(2, &b)];
    f.service.set_held(true);
    f.service.set_playhead(Time::new(1005, 1));
    f.service.sync(&media, None, Some(&timeline));
    for w in f.service.take_decision_work() {
        f.service.decision_finished(&w, needs_job());
    }
    f.service.set_held(false);
    let started = f.service.take_started_jobs();
    assert_eq!(started.len(), 1);
    assert!(started[0].source.ends_with("b.mov"), "the clip under the playhead goes first, not the import order");

    // The playhead moves while both wait: the queue is re-ranked.
    let mut g = proxy_fixture(Some(ProxyMode::Always));
    let (a, b) = (g.dir.file("a.mov", 100), g.dir.file("b.mov", 200));
    let media = [video_media(1, &a), video_media(2, &b)];
    g.service.set_held(true);
    g.service.sync(&media, None, Some(&timeline)); // playhead 0: A first
    for w in g.service.take_decision_work() {
        g.service.decision_finished(&w, needs_job());
    }
    g.now.set(g.now.get() + 1.0);
    g.service.set_playhead(Time::new(1005, 1));
    g.service.set_held(false);
    let started = g.service.take_started_jobs();
    assert!(started[0].source.ends_with("b.mov"), "the re-rank moved B ahead of the queued A");
}

#[test]
fn a_far_unfinished_running_job_makes_way_for_a_near_one_but_a_near_one_never_does() {
    let timeline = two_clip_timeline();
    let run = |playhead_s: i64| {
        let mut f = proxy_fixture(Some(ProxyMode::Always));
        let (a, b) = (f.dir.file("a.mov", 100), f.dir.file("b.mov", 200));
        let media = [video_media(1, &a), video_media(2, &b)];
        f.service.sync(&media, None, Some(&timeline)); // playhead 0: decisions for A then B
        let work = f.service.take_decision_work();
        f.service.decision_finished(&work[0], needs_job()); // A starts (one slot)
        f.service.decision_finished(&work[1], needs_job()); // B waits
        assert_eq!(f.service.take_started_jobs().len(), 1);
        f.now.set(f.now.get() + 1.0);
        f.service.set_playhead(Time::new(playhead_s, 1));
        f.service.take_decision_work().len() // a dropped job is decided again
    };
    assert_eq!(run(1005), 1, "A is 995 s away and B waits under the playhead: A is dropped and decided again");
    assert_eq!(run(5), 0, "the running A is under the playhead: it keeps going");
}

/// A ready proxy the opener refused for its frame times is made again: the service decides the media anew, once.
#[test]
fn a_proxy_refused_for_its_frame_times_is_queued_again_once() {
    use sq_proxy::model::{ProxyDimensions, ProxyRecord, SourceFingerprint};
    let mut f = proxy_fixture(Some(ProxyMode::Always));
    let file = f.dir.file("a.mov", 100);
    let fp = SourceFingerprint::compute(&file).unwrap();
    let kind = ProxyKind::ProxyHalf;
    let commit = |f: &ProxyFixture| {
        let r = ProxyRecord::new(
            fp.clone(),
            kind,
            ProxyCache::file_name(&fp, kind),
            ProxyDimensions { width: 1920, height: 1080 },
            Timestamp::from_unix_seconds(1.0),
            Time::new(10, 1),
        );
        let partial = f.cache.partial_url(&fp, kind);
        std::fs::write(&partial, b"x").unwrap();
        f.cache.commit(&partial, &r).unwrap();
        sq_proxy::proxy_cache::ProxyRecordID::new(&r)
    };
    let ready = |f: &mut ProxyFixture, record| {
        f.service.sync(&[video_media(1, &file)], None, None);
        let work = f.service.take_decision_work();
        assert_eq!(work.len(), 1);
        f.service.decision_finished(&work[0], ProxyOutcome::Ready { record: Some(record), software: false });
        f.service.take_effects();
    };
    let record = commit(&f);
    ready(&mut f, record);
    assert!(f.cache.retire_mismatched(&fp, kind), "first refusal");
    f.service.tick();
    let work = f.service.take_decision_work();
    assert_eq!(work.len(), 1, "the media is decided anew");
    // The new proxy differs too: no second removal, nothing queued.
    let record = commit(&f);
    f.service.decision_finished(&work[0], ProxyOutcome::Ready { record: Some(record), software: false });
    f.service.take_effects();
    assert!(!f.cache.retire_mismatched(&fp, kind), "second refusal");
    f.service.tick();
    assert!(f.service.take_decision_work().is_empty(), "no loop");
}
