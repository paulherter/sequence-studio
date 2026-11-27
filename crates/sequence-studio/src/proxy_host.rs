//! The app's `AutoProxyService` (Swift: the service the session owns): the settings from `prefs.json`, a seek prober over
//! the first FFmpeg packets (`sq_proxy::seek_prober`), and the worker driver. Decisions and transcodes run on threads of
//! their own; the UI thread calls [`ProxyHost::pump`] every frame to take their results in and hand out new work, and
//! lists the unfinished jobs for the export queue popover (`ExportHost::background_jobs`).

use crate::proxy::{FfmpegProxyTranscoder, wall_clock};
use sq_core_model::{MediaRef, Timeline};
use sq_core_time::{Id, Time};
use sq_editor_session::es08_media::{
    AutoProxyDeps, AutoProxyService, DiskSpace, ProjectMediaResolver, ProxyDecisionWork, ProxyOutcome, ResolverDeps,
};
use sq_editor_session::{BackgroundProxyJob, ProxyEffect, SessionProxyServing};
use sq_media::media_opener::MediaOpener;
use sq_playback::engine::activity::PlayActivity;
use sq_playback::engine::media_source::DefaultOpener;
use sq_proxy::auto_proxy::{MachineProfile, ProxyDefaults, ProxySettingsStore};
use sq_proxy::model::ProxyRecord;
use sq_proxy::proxy_cache::ProxyCache;
use sq_proxy::proxy_queue::{JobError, ProxyJobID, ProxyJobState, StartedJob};
use sq_proxy::seek_prober::FfmpegSeekProber;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc::{Receiver, Sender, channel};

/// The proxy settings (`sq.proxy.*`) as Preferences stored them in `prefs.json`, read fresh on every call so a change
/// applies at the next `refresh`.
// shortcut: read-only; the writers are Preferences and the project's own setting, which store through the shell.
pub struct PrefsDefaults {
    path: PathBuf,
}

impl PrefsDefaults {
    pub fn new(support: &Path) -> PrefsDefaults {
        PrefsDefaults { path: support.join("prefs.json") }
    }

    fn value(&self, group: &str, key: &str) -> Option<serde_json::Value> {
        let all: serde_json::Value = serde_json::from_slice(&std::fs::read(&self.path).ok()?).ok()?;
        all.get(group)?.get(key).cloned()
    }
}

impl ProxyDefaults for PrefsDefaults {
    fn string(&self, key: &str) -> Option<String> {
        self.value("strings", key)?.as_str().map(str::to_string)
    }
    fn bool(&self, key: &str) -> bool {
        self.value("integers", key).and_then(|v| v.as_i64()).is_some_and(|v| v != 0)
    }
    fn set_string(&mut self, _key: &str, _value: &str) {}
    fn set_bool(&mut self, _key: &str, _value: bool) {}
    fn remove(&mut self, _key: &str) {}
}

/// What a worker reports.
enum Done {
    Decision(Box<ProxyDecisionWork>, ProxyOutcome),
    Progress(ProxyJobID, f64),
    Job(ProxyJobID, Result<ProxyRecord, JobError>),
}

/// The service and its workers. Lives on the UI thread (the session owns it).
pub struct ProxyHost {
    service: AutoProxyService<PrefsDefaults>,
    resolver: Arc<ProjectMediaResolver>,
    tx: Sender<Done>,
    rx: Receiver<Done>,
    wake: Arc<dyn Fn() + Send + Sync>,
}

/// Physical memory of the machine; 16 GB when the system cannot say.
fn physical_memory() -> u64 {
    sq_platform::physical_memory().unwrap_or(16 << 30)
}

impl ProxyHost {
    /// The service over the default proxy cache. `wake` is called when a worker has news (it marks the frame dirty).
    pub fn new(support: &Path, wake: Arc<dyn Fn() + Send + Sync>) -> ProxyHost {
        ProxyHost::with_cache(
            ProxyCache::default_directory(|k| std::env::var(k).ok()),
            PrefsDefaults::new(support),
            MachineProfile::current_with(
                |k| std::env::var(k).ok(),
                physical_memory(),
                std::thread::available_parallelism().map_or(4, |n| n.get() as i64),
                cfg!(all(target_os = "macos", target_arch = "aarch64")),
            ),
            wake,
        )
    }

    /// The same over a cache folder, settings and machine of the caller (tests).
    pub fn with_cache(
        directory: PathBuf,
        defaults: PrefsDefaults,
        machine: MachineProfile,
        wake: Arc<dyn Fn() + Send + Sync>,
    ) -> ProxyHost {
        let disk: Arc<dyn Fn(&Path) -> DiskSpace + Send + Sync> = Arc::new(|dir| {
            let (free, total) = sq_platform::volume_bytes(dir);
            // Test switch: SQ_TEST_DISK_FREE_GB pretends the volume has that much free (shows the low-space notice).
            let free = std::env::var("SQ_TEST_DISK_FREE_GB")
                .ok()
                .and_then(|v| v.parse::<i64>().ok())
                .map(|g| g << 30)
                .or(free);
            DiskSpace { free, total }
        });
        ProxyHost::with_cache_and_disk(directory, defaults, machine, wake, disk)
    }

    /// `with_cache` with the free-space reader of the caller (tests on a small temp volume).
    pub fn with_cache_and_disk(
        directory: PathBuf,
        defaults: PrefsDefaults,
        machine: MachineProfile,
        wake: Arc<dyn Fn() + Send + Sync>,
        disk_space: Arc<dyn Fn(&Path) -> DiskSpace + Send + Sync>,
    ) -> ProxyHost {
        // shortcut: the decisions open files with the software opener (no GPU), so on the Mac "decodes in software" reads
        // true for every light source; hand the engines' opener over when the Mac needs the difference.
        let opener: Arc<dyn MediaOpener> = Arc::new(DefaultOpener::new(None));
        let resolver = Arc::new(ProjectMediaResolver::new(ResolverDeps::new(opener)));
        let deps = AutoProxyDeps {
            resolver: Arc::clone(&resolver),
            prober: Arc::new(FfmpegSeekProber::default()),
            machine,
            concurrency: 1,
            // No new proxy job starts while a monitor plays or scrubs (Swift `isBusy`); a running transcode stands still
            // between frames meanwhile (`FfmpegProxyTranscoder`). shortcut: an export does not hold the jobs back yet.
            is_busy: {
                let playback = PlayActivity::shared();
                Box::new(move || playback.is_busy())
            },
            busy_resume: 2.0,
            disk_space,
            clock: Box::new(wall_clock),
            ids: Box::new(sq_core_time::RandomIds),
        };
        // The monitors open proxies through the same cache object (`proxy::default_provider`), one per folder.
        let service =
            AutoProxyService::new(crate::proxy::shared_cache(directory), ProxySettingsStore::new(defaults), deps);
        let (tx, rx) = channel();
        ProxyHost { service, resolver, tx, rx, wake }
    }

    /// The service (tests read its state).
    #[cfg(test)]
    pub fn service(&self) -> &AutoProxyService<PrefsDefaults> {
        &self.service
    }

    fn dispatch(&mut self) {
        for work in self.service.take_decision_work() {
            let (tx, resolver, wake) = (self.tx.clone(), Arc::clone(&self.resolver), Arc::clone(&self.wake));
            let _ = std::thread::Builder::new().name("sq-proxy-decide".into()).spawn(move || {
                sq_os::thread::set_current_thread_role(sq_os::thread::Role::Background);
                // Opening the original reads its frame table and starts a decoder (the rule needs both).
                let outcome = guarded_outcome(|| {
                    let _ = resolver.demuxer(work.media);
                    work.run()
                });
                let _ = tx.send(Done::Decision(Box::new(work), outcome));
                wake();
            });
        }
        for job in self.service.take_started_jobs() {
            let (tx, wake) = (self.tx.clone(), Arc::clone(&self.wake));
            let _ = std::thread::Builder::new().name("sq-proxy-transcode".into()).spawn(move || {
                sq_os::thread::set_current_thread_role(sq_os::thread::Role::Background);
                run_job(&job, &tx, &wake)
            });
        }
    }

    fn id_text(id: ProxyJobID) -> String {
        id.raw.to_string()
    }
}

/// A decision whose probe panicked ends as "no proxy" instead of leaving the media pending forever.
fn guarded_outcome(f: impl FnOnce() -> ProxyOutcome) -> ProxyOutcome {
    sq_core_time::caught_panic::catching(f).unwrap_or(ProxyOutcome::Skipped)
}

/// A transcode that panicked fails its job (the service frees the slot) instead of staying "running" forever.
fn guarded_job(f: impl FnOnce() -> Result<ProxyRecord, JobError>) -> Result<ProxyRecord, JobError> {
    sq_core_time::caught_panic::catching(f).unwrap_or_else(|payload| {
        Err(JobError::Failed(format!(
            "The proxy transcode stopped unexpectedly. {}",
            sq_core_time::caught_panic::message(payload.as_ref())
        )))
    })
}

fn run_job(job: &StartedJob, tx: &Sender<Done>, wake: &Arc<dyn Fn() + Send + Sync>) {
    let _span = sq_os::trace::span("proxy", "proxy job");
    let mut last = -1.0;
    let mut progress = |p: f64| {
        // About every 2 %: the UI redraws on each message.
        if p - last >= 0.02 || p >= 1.0 {
            last = p;
            let _ = tx.send(Done::Progress(job.id, p));
            wake();
        }
    };
    let result = guarded_job(|| job.run(&FfmpegProxyTranscoder, &mut progress, wall_clock()));
    let _ = tx.send(Done::Job(job.id, result));
    wake();
}

impl SessionProxyServing for ProxyHost {
    fn project_id(&self) -> Option<Id> {
        self.service.project_id()
    }

    fn sync(&mut self, media: &[MediaRef], project_id: Option<Id>, active_timeline: Option<&Timeline>) {
        self.resolver.update(media, None);
        self.service.sync(media, project_id, active_timeline);
        self.dispatch();
    }

    fn set_playhead(&mut self, playhead: Time) {
        self.service.set_playhead(playhead);
        self.dispatch(); // a dropped far job is decided again
    }

    fn take_effects(&mut self) -> Vec<ProxyEffect> {
        self.service.take_effects()
    }

    fn set_held(&mut self, held: bool) {
        self.service.set_held(held);
    }

    fn clear_cache(&mut self) -> i64 {
        self.service.clear_cache()
    }

    fn pump(&mut self) {
        while let Ok(done) = self.rx.try_recv() {
            match done {
                Done::Decision(work, outcome) => self.service.decision_finished(&work, outcome),
                Done::Progress(id, p) => self.service.set_job_progress(id, p),
                Done::Job(id, result) => self.service.complete_job(id, result),
            }
        }
        self.service.tick();
        self.dispatch();
    }

    fn proxies_settled(&self) -> bool {
        !self.service.needs_busy_polling()
    }

    fn background_jobs(&self) -> Vec<BackgroundProxyJob> {
        self.service
            .queue
            .all_jobs()
            .into_iter()
            .filter(|j| !j.state.is_terminal())
            .map(|j| {
                let name = j.source.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                BackgroundProxyJob {
                    id: ProxyHost::id_text(j.id),
                    title: format!("Proxy: {name}"),
                    progress: (j.state == ProxyJobState::Running).then_some(j.progress),
                }
            })
            .collect()
    }

    fn take_disk_notice(&mut self) -> Option<String> {
        self.service.take_disk_notice()
    }

    fn cancel_job(&mut self, id: &str) {
        let found = self.service.queue.all_jobs().into_iter().find(|j| ProxyHost::id_text(j.id) == id);
        if let Some(job) = found {
            self.service.queue.cancel(job.id);
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_panicking_decision_or_transcode_still_ends_instead_of_hanging() {
        assert_eq!(guarded_outcome(|| panic!("probe blew up")), ProxyOutcome::Skipped);
        let failed = guarded_job(|| panic!("encoder blew up"));
        assert!(matches!(failed, Err(JobError::Failed(ref m)) if m.contains("encoder blew up")), "{failed:?}");
    }

    use super::*;
    use crate::export::tests::ffmpeg_tool;
    use sq_media::media_opener::MonitorUse;
    use sq_proxy::proxy_transcoding::ProxyTranscoding;
    use std::time::{Duration, Instant};

    struct Rig {
        dir: PathBuf,
        host: ProxyHost,
        media: MediaRef,
        wakes: Arc<std::sync::atomic::AtomicUsize>,
    }

    impl Drop for Rig {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    /// A 3 s long-GOP clip imported like the app does (probe), a service over a private cache that proxies every long-GOP
    /// source (mode "always"), on a weak machine.
    fn rig(name: &str) -> Option<Rig> {
        let tool = ffmpeg_tool()?;
        let dir = std::env::temp_dir().join(format!("sq-proxy-host-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let support = dir.join("support");
        std::fs::create_dir_all(&support).ok()?;
        std::fs::write(support.join("prefs.json"), r#"{"strings":{"sq.proxy.mode":"always"}}"#).ok()?;
        let clip = dir.join("clip.mp4");
        let made = std::process::Command::new(tool)
            .args(["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=3"])
            .args(["-c:v", "mpeg4", "-g", "100", "-pix_fmt", "yuv420p"])
            .arg(&clip)
            .status()
            .ok()?;
        if !made.success() {
            return None;
        }
        let media = crate::probe::FfmpegProbe::default().probe_in(&clip, &dir.join("animated")).ok()?;
        let wakes = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = Arc::clone(&wakes);
        let machine = MachineProfile { memory_bytes: 8 << 30, cores: 4, is_apple_silicon: false };
        // A roomy volume, so the reserve rule does not depend on the temp folder of the machine running the test.
        let roomy: Arc<dyn Fn(&Path) -> DiskSpace + Send + Sync> =
            Arc::new(|_| DiskSpace { free: Some(500 << 30), total: Some(1000 << 30) });
        let host = ProxyHost::with_cache_and_disk(
            dir.join("cache"),
            PrefsDefaults::new(&support),
            machine,
            Arc::new(move || {
                counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            }),
            roomy,
        );
        Some(Rig { dir, host, media, wakes })
    }

    /// Pumps until `done` holds (60 s limit); returns the longest job list seen.
    fn pump_until(r: &mut Rig, done: impl Fn(&ProxyHost) -> bool) -> Vec<BackgroundProxyJob> {
        let mut seen = Vec::new();
        let end = Instant::now() + Duration::from_secs(60);
        while Instant::now() < end && !done(&r.host) {
            r.host.pump();
            let jobs = r.host.background_jobs();
            if jobs.len() > seen.len() {
                seen = jobs;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        seen
    }

    #[test]
    fn the_service_makes_a_proxy_that_playback_opens_and_pause_does_not() {
        let Some(mut r) = rig("e2e") else { return };
        let id = r.media.id;
        r.host.sync(std::slice::from_ref(&r.media), Some(Id::from_u128(7)), None);
        let seen = pump_until(&mut r, |h| h.service().ready_media().contains(&id));
        assert!(r.host.service().ready_media().contains(&id), "no proxy: {:?}", r.host.service().proxy_state(id));
        assert_eq!(seen.len(), 1, "the export queue popover lists the transcode");
        assert!(seen[0].title.starts_with("Proxy: clip"), "{:?}", seen[0]);
        assert!(r.wakes.load(std::sync::atomic::Ordering::SeqCst) > 0, "the workers woke the window loop");
        assert!(r.host.background_jobs().is_empty(), "a finished job leaves the list");
        let effects = r.host.take_effects();
        assert!(effects.iter().any(|e| matches!(e, ProxyEffect::ProxiesChanged(ids) if ids.contains(&id))));

        let plain: Arc<dyn MediaOpener> = Arc::new(DefaultOpener::new(None));
        let opener = crate::proxy::monitor_opener_over(Arc::clone(&plain), Arc::clone(&r.host.service().provider));
        let path = Path::new(&r.media.path);
        let original = opener.open(path, id).expect("original");
        assert!(!original.label.ends_with("proxy"), "open is the original: {}", original.label);
        let playing = opener.open_for(path, id, MonitorUse::Playing).and_then(Result::ok).expect("a proxy to play");
        assert!(playing.label.ends_with("proxy"));
        assert_eq!(playing.demuxer.format_description().width, original.info.width / 2);
        assert!(opener.open_for(path, id, MonitorUse::Scrubbing).is_some(), "scrubbing reads the proxy too");
        assert!(opener.open_for(path, id, MonitorUse::Paused).is_none(), "a paused frame is the original's");

        // Export: with "Use proxies when exporting" off (the default) the plain opener is used.
        let export = crate::proxy::export_opener(Arc::clone(&plain), false);
        assert!(Arc::ptr_eq(&export, &plain));
        assert!(!export.open(path, id).expect("export open").label.ends_with("proxy"));
    }

    /// The monitor plays: the running transcode makes no progress until the picture rests (and a cancel still ends it).
    #[test]
    fn a_running_transcode_stands_still_while_the_monitor_plays() {
        let Some(tool) = ffmpeg_tool() else { return };
        let dir = std::env::temp_dir().join(format!("sq-proxy-hold-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        assert!(std::fs::create_dir_all(&dir).is_ok());
        let clip = dir.join("clip.mp4");
        let made = std::process::Command::new(tool)
            .args(["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25:duration=2"])
            .args(["-c:v", "mpeg4", "-pix_fmt", "yuv420p"])
            .arg(&clip)
            .status();
        if !made.is_ok_and(|s| s.success()) {
            return;
        }
        let steps = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let mut mark = sq_playback::engine::activity::PlayMark::new(PlayActivity::shared());
        mark.set(true);
        let worker = {
            let (clip, partial, steps) = (clip.clone(), dir.join("proxy"), Arc::clone(&steps));
            std::thread::spawn(move || {
                let mut progress = |_: f64| {
                    steps.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                };
                FfmpegProxyTranscoder.transcode(
                    &clip,
                    sq_proxy::model::ProxyKind::ProxyHalf,
                    &partial,
                    None,
                    &mut progress,
                    &sq_proxy::proxy_transcoding::CancelToken::new(),
                )
            })
        };
        std::thread::sleep(Duration::from_millis(500));
        let held = steps.load(std::sync::atomic::Ordering::SeqCst);
        mark.set(false);
        let done = worker.join();
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(held, 0, "no progress while a monitor plays");
        assert!(matches!(done, Ok(Ok(_))), "it finishes after playback stopped: {done:?}");
        assert!(steps.load(std::sync::atomic::Ordering::SeqCst) > 0);
    }

    #[test]
    fn cancel_on_a_background_row_stops_the_job_and_no_proxy_appears() {
        let Some(mut r) = rig("cancel") else { return };
        let id = r.media.id;
        r.host.sync(std::slice::from_ref(&r.media), Some(Id::from_u128(7)), None);
        pump_until(&mut r, |h| !h.background_jobs().is_empty());
        let job = r.host.background_jobs().into_iter().next().expect("a job in the list");
        r.host.cancel_job(&job.id);
        pump_until(&mut r, |h| h.background_jobs().is_empty());
        assert!(r.host.background_jobs().is_empty());
        assert!(!r.host.service().ready_media().contains(&id), "a canceled job makes no proxy");
    }
}
