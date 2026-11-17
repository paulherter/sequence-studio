#![allow(non_snake_case, clippy::clone_on_ref_ptr, clippy::redundant_async_block)] // test names mirror the Swift test names
use crate::flows::Log;
use crate::flows::host::{Host, Response};
use crate::flows::proxy::{Gate, JobState, Transcoder, new_service};
use crate::flows::session::{SaveError, SaveQueue, Session};
use crate::testing::Rt;
use crate::{Clock, spawn_local};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

struct Rig {
    rt: Rt,
    log: Log,
    session: Rc<Session>,
    host: Rc<Host>,
    queue: SaveQueue,
    fail: Arc<AtomicBool>,
}
fn rig(rt: Rt) -> Rig {
    let log = Log::default();
    let fail = Arc::new(AtomicBool::new(false));
    let (l, f) = (log.clone(), fail.clone());
    let queue = SaveQueue::new(
        rt.pool.clone(),
        Arc::new(move |s, _| {
            if f.load(Ordering::SeqCst) {
                return Err("disk full".into());
            }
            l.push(format!("write:{}", s.name));
            Ok(())
        }),
    );
    let session = Rc::new(Session::new("P", queue.clone(), Arc::new(rt.clock.clone()), log.clone()));
    let host = Host::new(session.clone(), log.clone());
    Rig { rt, log, session, host, queue, fail }
}
fn confirm(r: &Rig) -> crate::JoinHandle<bool> {
    let h = r.host.clone();
    spawn_local(async move { h.confirm_discard_changes().await })
}
const TITLE: &str = "menu.dismiss";

// ---------------- Flow 1: ShellHost.confirmDiscardChanges ----------------

#[test]
fn clean_project_proceeds_without_a_dialog() {
    let r = rig(Rt::manual());
    let h = confirm(&r);
    r.rt.run_until_stalled();
    assert_eq!(h.try_take(), Some(Ok(true)));
    assert!(r.log.items().is_empty());
    assert!(r.host.dialog.borrow().is_none());
}

#[test]
fn dirty_with_file_save_writes_then_proceeds() {
    let r = rig(Rt::manual());
    r.session.set_file_url(Some("/p.sqproj"));
    r.session.perform_rename("Two");
    let h = confirm(&r);
    r.rt.run_until_stalled();
    // The task is suspended inside ask(): dialog visible, nothing written, nothing returned.
    assert!(!h.is_finished());
    {
        let d = r.host.dialog.borrow();
        let d = d.as_ref().unwrap();
        assert_eq!(d.title, "Save changes to “Two”?");
        assert_eq!(d.buttons, ["Save", "Cancel", "Don’t Save"]);
        assert_eq!(d.informative, "Your changes are lost if you don’t save them.");
    }
    assert_eq!(r.log.items(), [TITLE, "dialog.show:Save changes to “Two”?"]);
    assert!(r.host.click(Response::First));
    assert!(!r.host.click(Response::First), "a second click finds no dialog");
    r.rt.run_until_stalled();
    assert_eq!(h.try_take(), Some(Ok(true)));
    assert_eq!(
        r.log.items()[2..],
        ["dialog.close", "project save start: /p.sqproj", "collectLUTs", "write:Two", "project save ok"]
    );
    assert!(!r.session.is_dirty());
}

#[test]
fn cancel_stays_and_dont_save_proceeds_without_writing() {
    for (resp, expect) in [(Response::Second, false), (Response::Third, true)] {
        let r = rig(Rt::manual());
        r.session.set_file_url(Some("/p.sqproj"));
        r.session.perform_rename("Two");
        let h = confirm(&r);
        r.rt.run_until_stalled();
        r.host.click(resp);
        r.rt.run_until_stalled();
        assert_eq!(h.try_take(), Some(Ok(expect)));
        assert!(r.log.items().iter().all(|e| !e.starts_with("write:")));
        assert!(r.session.is_dirty());
    }
}

#[test]
fn untitled_save_asks_for_a_place_in_a_nested_wait() {
    let r = rig(Rt::manual());
    r.session.perform_rename("Two");
    let h = confirm(&r);
    r.rt.run_until_stalled();
    assert!(r.host.dialog.borrow().as_ref().unwrap().informative.ends_with("Save asks for a place."));
    r.host.click(Response::First);
    r.rt.run_until_stalled();
    assert!(!h.is_finished(), "waiting on the file chooser");
    assert_eq!(r.log.items().last().unwrap(), "panel.show");
    r.host.panel_choose(Some("/Users/p/Two"));
    r.rt.run_until_stalled();
    assert_eq!(h.try_take(), Some(Ok(true)));
    assert_eq!(r.session.file_url().as_deref(), Some("/Users/p/Two.sqproj"));
    assert_eq!(
        r.log.items()[3..],
        ["panel.show", "project save as start: /Users/p/Two.sqproj", "collectLUTs", "write:Two", "project save as ok"]
    );
}

#[test]
fn canceled_file_chooser_stays() {
    let r = rig(Rt::manual());
    r.session.perform_rename("Two");
    let h = confirm(&r);
    r.rt.run_until_stalled();
    r.host.click(Response::First);
    r.rt.run_until_stalled();
    r.host.panel_choose(None);
    r.rt.run_until_stalled();
    assert_eq!(h.try_take(), Some(Ok(false)));
    assert!(r.log.items().iter().all(|e| !e.starts_with("write:")));
}

#[test]
fn failed_save_shows_the_error_dialog_after_the_first_closed_and_stays() {
    let r = rig(Rt::manual());
    r.session.set_file_url(Some("/p.sqproj"));
    r.session.perform_rename("Two");
    r.fail.store(true, Ordering::SeqCst);
    let h = confirm(&r);
    r.rt.run_until_stalled();
    r.host.click(Response::First);
    r.rt.run_until_stalled();
    assert_eq!(h.try_take(), Some(Ok(false)));
    assert_eq!(r.host.shown.borrow().as_slice(), ["Save changes to “Two”?", "Could not save"]);
    assert_eq!(r.host.dialog.borrow().as_ref().unwrap().buttons, ["OK"]);
    assert_eq!(r.session.errors.borrow().as_slice(), ["Could not save:Write(\"disk full\")"]);
    r.host.click(Response::First);
    r.rt.run_until_stalled();
    assert!(r.host.dialog.borrow().is_none());
    assert_eq!(r.rt.ex.live_tasks(), 0);
}

#[test]
fn project_replaced_during_the_write_is_dropped_silently() {
    let r = rig(Rt::manual());
    r.session.set_file_url(Some("/p.sqproj"));
    r.session.perform_rename("Two");
    let h = confirm(&r);
    r.rt.run_until_stalled();
    r.host.click(Response::First);
    r.rt.ex.poll_frame(); // runs up to the queue.write await, the worker job is queued but not run
    assert_eq!(r.rt.pool.pending(), 1);
    r.session.replace_project("Other");
    r.rt.run_until_stalled();
    assert_eq!(h.try_take(), Some(Ok(false)));
    assert_eq!(r.log.items().last().unwrap(), "save canceled: another project was opened meanwhile");
    assert_eq!(r.host.shown.borrow().len(), 1, "no error dialog");
    assert!(!r.session.is_dirty(), "the new project is untouched");
}

// ---------------- Flow 2: EditorSession.save + ProjectSaveQueue + tickAutosave ----------------

#[test]
fn savesAreSerialisedThroughTheQueue() {
    // Swift: EditorSessionTests.savesAreSerialisedThroughTheQueue -> order == ["P", "Two"]
    let r = rig(Rt::manual());
    let s = r.session.clone();
    let h = spawn_local(async move {
        s.save_as("/x.sqproj").await.unwrap();
        s.perform_rename("Two");
        s.save().await.unwrap();
    });
    r.rt.run_until_stalled();
    assert!(h.try_take().unwrap().is_ok());
    let writes: Vec<_> = r.log.items().into_iter().filter(|e| e.starts_with("write:")).collect();
    assert_eq!(writes, ["write:P", "write:Two"]);
}

#[test]
fn saveWithoutURLThrows() {
    let r = rig(Rt::manual());
    let s = r.session.clone();
    let h = spawn_local(async move { s.save().await });
    r.rt.run_until_stalled();
    assert_eq!(h.try_take(), Some(Ok(Err(SaveError::NoFileUrl))));
}

#[test]
fn an_edit_during_the_write_keeps_the_project_dirty() {
    // Swift write(): "The written state is the saved one (undo during the write leaves the project dirty)".
    let r = rig(Rt::manual());
    r.session.set_file_url(Some("/p.sqproj"));
    r.session.perform_rename("Two");
    let s = r.session.clone();
    let h = spawn_local(async move { s.save().await });
    r.rt.ex.poll_frame();
    r.session.perform_rename("Three"); // while the worker job is queued
    r.rt.run_until_stalled();
    assert!(h.try_take().unwrap().unwrap().is_ok());
    assert!(r.session.is_dirty());
}

#[test]
fn autosaveTimerTickWritesSnapshotOnlyWhenDirtyAndDue() {
    // Swift: EditorSessionTests.autosaveTimerTickWritesSnapshotOnlyWhenDirtyAndDue (fake clock)
    let r = rig(Rt::manual());
    let tick = |r: &Rig| {
        let s = r.session.clone();
        let h = spawn_local(async move { s.tick_autosave().await });
        r.rt.run_until_stalled();
        h.try_take().unwrap().unwrap()
    };
    assert!(!tick(&r)); // clean
    r.session.perform_rename("P2");
    assert!(tick(&r)); // dirty, never autosaved
    assert_eq!(r.queue.autosaves.lock().unwrap().len(), 1);
    r.rt.clock.advance(Duration::from_secs(100));
    assert!(!tick(&r)); // not due
    r.rt.clock.advance(Duration::from_secs(250));
    assert!(tick(&r)); // 350 s later
    assert_eq!(r.queue.autosaves.lock().unwrap().len(), 2);
}

#[test]
fn autosave_for_a_replaced_project_is_not_recorded() {
    let r = rig(Rt::manual());
    r.session.perform_rename("P2");
    let s = r.session.clone();
    let h = spawn_local(async move { s.tick_autosave().await });
    r.rt.ex.poll_frame();
    r.session.replace_project("Other");
    r.rt.run_until_stalled();
    assert_eq!(h.try_take(), Some(Ok(false)));
    assert!(!r.log.items().contains(&"autosave ok".to_string()));
}

#[test]
fn threaded_single_lane_keeps_fifo_order_of_many_writes() {
    let rt = Rt::threaded(1);
    let order = Arc::new(Mutex::new(vec![]));
    let o = order.clone();
    let q = SaveQueue::new(
        rt.pool.clone(),
        Arc::new(move |s, _| {
            o.lock().unwrap().push(s.revision);
            Ok(())
        }),
    );
    let session = Rc::new(Session::new("P", q, Arc::new(rt.clock.clone()), Log::default()));
    let done = Rc::new(std::cell::Cell::new(0));
    for _ in 0..200 {
        let (s, d) = (session.clone(), done.clone());
        spawn_local(async move {
            s.perform_rename("x");
            let _ = s.save_as("/a").await;
            d.set(d.get() + 1);
        });
    }
    rt.wait_until(|| done.get() == 200);
    let o = order.lock().unwrap();
    assert_eq!(o.len(), 200);
}

// ---------------- Flow 3: AutoProxyService ----------------

fn svc(rt: &Rt, busy: &Arc<AtomicBool>, tc: Arc<Transcoder>, gate: Gate) -> (crate::flows::proxy::Service, Log) {
    let log = Log::default();
    (new_service(log.clone(), Arc::new(rt.clock.clone()), rt.pool.clone(), tc, busy.clone(), gate), log)
}

#[test]
fn settingsChangesApplyByThemselves_with_a_100ms_debounce() {
    let rt = Rt::manual();
    let (s, log) = svc(&rt, &Arc::new(AtomicBool::new(false)), Transcoder::opened(), Gate::default());
    s.setting.set(1);
    // A new task is first polled at the next frame, so the harness runs a frame at the same instant (as a real host does).
    s.defaults_changed(); // t=0
    rt.run_until_stalled();
    rt.advance(Duration::from_millis(40));
    s.defaults_changed(); // t=40: the first debounce is canceled
    rt.run_until_stalled();
    rt.advance(Duration::from_millis(40));
    s.defaults_changed(); // t=80
    rt.run_until_stalled();
    rt.advance(Duration::from_millis(99)); // t=179
    assert_eq!(s.refreshes.get(), 0);
    rt.advance(Duration::from_millis(1)); // t=180 = 80 + 100
    assert_eq!(s.refreshes.get(), 1);
    assert_eq!(log.items(), ["refresh"]);
    // Unchanged settings: the debounce fires but nothing is re-read.
    s.defaults_changed();
    rt.run_until_stalled();
    rt.advance(Duration::from_millis(100));
    assert_eq!(s.refreshes.get(), 1);
    assert_eq!(rt.ex.live_tasks(), 0, "all debounce tasks ended");
}

#[test]
fn busyMachineHoldsJobsUntilIdle() {
    // Swift: AutoProxyServiceTests.busyMachineHoldsJobsUntilIdle (busyPoll 500 ms, busyResume 2 s)
    let rt = Rt::manual();
    let busy = Arc::new(AtomicBool::new(true));
    let gate = Gate::closed();
    let (s, log) = svc(&rt, &busy, Transcoder::opened(), gate.clone());
    s.sync(&[1]);
    rt.run_until_stalled();
    assert!(s.is_busy_held(), "held at once, before the probe returns");
    assert_eq!(log.items(), ["queue.held:true"]);
    gate.open();
    rt.run_until_stalled();
    assert_eq!(s.queue.job_states(), [JobState::Queued]);
    assert!(!log.items().contains(&"transcode started".to_string()));
    rt.advance(Duration::from_secs(5));
    assert!(s.is_busy_held(), "still busy");
    busy.store(false, Ordering::SeqCst);
    // idle begins at the next poll, resumes after 2 s without interruption
    let t0 = rt.clock.now();
    while s.is_busy_held() {
        assert!(rt.advance_to_next_timer());
    }
    let waited = rt.clock.now() - t0;
    assert!(waited >= Duration::from_secs(2) && waited <= Duration::from_millis(2500), "{waited:?}");
    rt.run_until_stalled();
    assert_eq!(
        log.items(),
        ["queue.held:true", "enqueued:1", "queue.held:false", "transcode started", "proxy ready:1"]
    );
    assert_eq!(s.ready_media(), [1]);
    rt.advance(Duration::from_millis(500));
    assert!(!s.is_busy_polling(), "polling stops when nothing is pending and nothing is held");
}

#[test]
fn busyPollingContinuesWhileProbing() {
    // Swift: a playback that starts while a decision task is probing (no job yet) must still hold the queue.
    let rt = Rt::manual();
    let busy = Arc::new(AtomicBool::new(false));
    let gate = Gate::closed();
    let (s, _log) = svc(&rt, &busy, Transcoder::opened(), gate.clone());
    s.sync(&[1]);
    rt.advance(Duration::from_secs(2)); // several polls, nothing busy, no job yet
    assert!(s.is_busy_polling());
    busy.store(true, Ordering::SeqCst);
    rt.advance(Duration::from_millis(500));
    assert!(s.is_busy_held());
    gate.open();
}

#[test]
fn removingTheMediaCancelsItsRunningJob() {
    // Swift: removingTheMediaCancelsItsJob (transcode started, then canceled); real worker threads, gate-controlled.
    let rt = Rt::threaded(2);
    let busy = Arc::new(AtomicBool::new(false));
    let gate = Gate::closed();
    let (s, log) = svc(&rt, &busy, Transcoder::closed(), gate.clone());
    s.sync(&[1]);
    gate.open();
    rt.wait_until(|| log.items().contains(&"transcode started".to_string()));
    assert_eq!(s.pending_media(), [1]);
    s.sync(&[]);
    rt.wait_until(|| log.items().contains(&"transcode canceled".to_string()));
    rt.clock.advance(Duration::from_secs(1)); // lets the busy-poll loop see that nothing is pending
    rt.wait_until(|| rt.ex.live_tasks() == 0);
    assert!(s.pending_media().is_empty());
    assert_eq!(s.queue.job_states(), [JobState::Cancelled]);
    assert!(!log.items().iter().any(|e| e.starts_with("proxy ready")));
}

#[test]
fn media_removed_while_probing_never_enqueues() {
    // Cooperative cancel: the awaited probe still returns, the `!Task.isCancelled` guard then ends the task.
    let rt = Rt::manual();
    let gate = Gate::closed();
    let (s, log) = svc(&rt, &Arc::new(AtomicBool::new(false)), Transcoder::opened(), gate.clone());
    s.sync(&[1]);
    rt.run_until_stalled();
    s.sync(&[]);
    rt.run_until_stalled();
    gate.open();
    rt.run_until_stalled();
    assert!(log.items().is_empty());
    assert!(s.queue.job_states().is_empty());
    assert_eq!(s.tracked_count(), 0);
    rt.advance(Duration::from_secs(1));
    assert_eq!(rt.ex.live_tasks(), 0);
}
