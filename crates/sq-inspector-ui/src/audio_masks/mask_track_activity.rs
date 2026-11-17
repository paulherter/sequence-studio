// Swift: MaskTrackActivity.swift
//! The mask track that is running (path or Magic; one at a time): the mask row shows Stop and the progress while it runs,
//! whichever clip Effect Controls shows. It also owns the run's task, so the one slot can never stay taken by a run that
//! nobody can end: `stop` frees the slot at once (it does not wait for the task), a run only ever clears its own slot
//! (`finish` with its token), and a run whose mask is gone is stopped (`stop_if_mask_gone`: Delete Mask, undo, deleted
//! effect or clip, another project).
//!
//! What a stopped run may still write, three endings:
//! - the user's stop (Stop, the track button again, Background Jobs: `keeps`): the run may write what it did so far to
//!   the project once (`may_write`: undo step, status line) and saves its frames;
//! - its mask is gone (`stop_if_mask_gone`: `discards`): nothing more, no undo step and no file;
//! - every other stop (tool switched, a correction or another run takes over, its pick changed, its project closes or
//!   another opens): no undo step and no status line, but the frames tracked so far are saved under the run's own
//!   key, at once (`save`, given at `start`) and again by the run when its last frame is in (`keeps_frames`). So frames
//!   are never in memory only while their key is still a mask's, and a pick that comes back (undo, redo) finds them.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use sq_core_time::Id;

use super::magic_track_control::MagicTrackControl;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Run {
    pub mask: Id,
    pub forward: bool,
    /// 0...100, -1 until the first progress report.
    pub percent: i64,
    /// Started by a pick, not by a track button: follows the pick in both directions (`turn`), and a tool switch
    /// or a new click ends it (`stop_automatic`).
    pub automatic: bool,
    /// The clip whose mask is tracked. The halves of a split clip share their mask ids: every lookup of the run's
    /// mask goes by clip and mask (`MagicPickWatch.mask`). None: found by the mask id alone.
    pub clip: Option<Id>,
}

impl Run {
    pub fn new(mask: Id, forward: bool) -> Run {
        Run { mask, forward, percent: -1, automatic: false, clip: None }
    }
}

/// Readable from the run's own thread: false once the run was stopped with `discards`.
#[derive(Debug)]
struct WriteSwitch(AtomicBool);

/// The optional arguments of `MaskTrackActivity::start` (Swift defaults: all unset).
#[derive(Default)]
pub struct StartOptions {
    /// Whose project the mask lives in (the editor session), so another window's edits do not stop it.
    pub owner: Option<usize>,
    /// Started by a pick, not by a track button.
    pub automatic: bool,
    /// The cache key its frames are stored under (`stop_if_key_changed`).
    pub key: Option<String>,
    /// The clip the mask is on (`Run.clip`).
    pub clip: Option<Id>,
    /// Writes the frames stored so far, called when the run is stopped and its frames stay.
    pub save: Option<Box<dyn FnMut()>>,
}

pub struct MaskTrackActivity {
    pub run: Option<Run>,
    /// The Magic mask's explicit track controls (step, run, Stop) and their state line.
    pub magic: MagicTrackControl,
    /// Cancels the run's task (Swift `Task.cancel`); set by `attach`.
    task: Option<Box<dyn FnOnce()>>,
    token: i64,
    /// Whose project the mask lives in (the editor session's identity).
    owner: Option<usize>,
    /// The run the user stopped: it may write what it did so far.
    kept: Option<i64>,
    /// The mask of that run.
    kept_mask: Option<Id>,
    kept_clip: Option<Id>,
    writes: Option<Arc<WriteSwitch>>,
    /// The cache key the run stores its frames under (a Magic track: the pick's key when it started).
    key: Option<String>,
    /// Saves the frames the run stored so far.
    save: Option<Box<dyn FnMut()>>,
}

impl Default for MaskTrackActivity {
    fn default() -> Self {
        MaskTrackActivity::new()
    }
}

impl MaskTrackActivity {
    pub fn new() -> Self {
        MaskTrackActivity {
            run: None,
            magic: MagicTrackControl::new(),
            task: None,
            token: 0,
            owner: None,
            kept: None,
            kept_mask: None,
            kept_clip: None,
            writes: None,
            key: None,
            save: None,
        }
    }

    pub fn is_running(&self) -> bool {
        self.run.is_some()
    }

    /// Takes the slot for a track of `mask` (a run still in it is stopped) and returns the run's token. `owner`: whose
    /// project the mask lives in (the editor session), so another window's edits do not stop it. `key`: the cache key
    /// its frames are stored under (`stop_if_key_changed`); `save`: writes the frames stored so far, called when the run
    /// is stopped and its frames stay. `clip`: the clip the mask is on (`Run.clip`).
    pub fn start(&mut self, mask: Id, forward: bool, opts: StartOptions) -> i64 {
        let StartOptions { owner, automatic, key, clip, save } = opts;
        if self.run.is_some() || self.task.is_some() {
            self.stop("another track starts", false, false);
        }
        self.token += 1;
        self.kept = None;
        self.kept_mask = None;
        self.kept_clip = None;
        self.writes = Some(Arc::new(WriteSwitch(AtomicBool::new(true))));
        self.key = key;
        self.save = save;
        self.owner = owner;
        self.run = Some(Run { mask, forward, percent: -1, automatic, clip });
        self.token
    }

    /// Track `token` goes on in the other direction (the pick's own track: forward first, then backward) in the same
    /// slot; its progress starts over. False when it is not the current run.
    pub fn turn(&mut self, forward: bool, token: i64) -> bool {
        if !self.is_current(token) {
            return false;
        }
        if let Some(r) = self.run.as_mut() {
            r.forward = forward;
            r.percent = -1;
        }
        true
    }

    /// Stops the running track when a pick started it (the tool was switched, a correction takes over); its frames are
    /// saved. A track the user started with a track button goes on. False when no automatic track ran.
    pub fn stop_automatic(&mut self, reason: &str, keeps: bool) -> bool {
        if self.run.is_none_or(|r| !r.automatic) {
            return false;
        }
        self.stop(reason, keeps, false)
    }

    /// The cancel hook of the task that runs track `token`; `stop` calls it. Ignored (and called at once) when that run
    /// is no longer the current one: it must not go on writing.
    pub fn attach(&mut self, cancel: Box<dyn FnOnce()>, token: i64) {
        if !self.is_current(token) {
            cancel();
            return;
        }
        self.task = Some(cancel);
    }

    pub fn is_current(&self, token: i64) -> bool {
        self.run.is_some() && token == self.token
    }

    /// The cache key the running track stores its frames under; None without a run or for a path track.
    pub fn run_key(&self) -> Option<&str> {
        if self.run.is_none() { None } else { self.key.as_deref() }
    }

    /// The token of the run the user stopped (Stop, the track button again, Background Jobs) while no run started
    /// since; None otherwise. `MagicPickWatch` holds its waiting picks back on it.
    pub fn user_stop(&self) -> Option<i64> {
        if self.run.is_none() { self.kept } else { None }
    }

    /// The mask whose run that was; None with `user_stop` None.
    pub fn user_stop_mask(&self) -> Option<Id> {
        if self.run.is_none() && self.kept.is_some() { self.kept_mask } else { None }
    }

    /// The clip that run named; None when it named none.
    pub fn user_stop_clip(&self) -> Option<Id> {
        if self.run.is_none() && self.kept.is_some() { self.kept_clip } else { None }
    }

    /// True while a run of `owner` stores frames under `key` for `mask` of `clip`: that pick needs no second run.
    pub fn is_following(&self, clip: Id, mask: Id, key: &str, owner: Option<usize>) -> bool {
        let Some(r) = self.run else { return false };
        if self.owner != owner {
            return false;
        }
        r.mask == mask && r.clip.unwrap_or(clip) == clip && self.key.as_deref() == Some(key)
    }

    /// True when track `token` may write to the project and its files: it is the running one, or the user stopped it
    /// (what it did so far is kept) and no other run started since.
    pub fn may_write(&self, token: i64) -> bool {
        self.is_current(token) || (self.run.is_none() && self.kept == Some(token))
    }

    /// Whether the run's frames stay, for the run's own thread (a Magic track saves its mattes file when it ends):
    /// false only once the run was stopped because its mask is gone. A token that is not the current run: always false.
    pub fn keeps_frames(&self, token: i64) -> Box<dyn Fn() -> bool + Send + Sync> {
        let writes = if self.is_current(token) { self.writes.as_ref().map(Arc::clone) } else { None };
        match writes {
            Some(w) => Box::new(move || w.0.load(Ordering::SeqCst)),
            None => Box::new(|| false),
        }
    }

    /// Progress of track `token` in percent; false when it is not the current run or the value did not change.
    pub fn progress(&mut self, percent: i64, token: i64) -> bool {
        if !self.is_current(token) || self.run.is_some_and(|r| r.percent == percent) {
            return false;
        }
        if let Some(r) = self.run.as_mut() {
            r.percent = percent;
        }
        true
    }

    /// Track `token` ended by itself: frees the slot unless a newer run took it.
    pub fn finish(&mut self, token: i64) {
        if token != self.token {
            return;
        }
        self.clear_slot();
    }

    fn clear_slot(&mut self) {
        self.task = None;
        self.run = None;
        self.owner = None;
        self.key = None;
        self.save = None;
    }

    /// Stops the running track: the slot is free when this returns, the task is canceled and ends at its next frame
    /// without tracking more. Nothing waits for it. `keeps` (the user's Stop): the run may still write what it did so
    /// far to the project. `discards` (its mask is gone): it writes nothing at all, no file either. Otherwise the
    /// frames it stored are saved (here and by the run itself at its end), the project is not touched. False when no
    /// track ran.
    pub fn stop(&mut self, _reason: &str, keeps: bool, discards: bool) -> bool {
        if self.run.is_none() && self.task.is_none() {
            return false;
        }
        if let Some(cancel) = self.task.take() {
            cancel();
        }
        self.kept = if keeps && !discards { Some(self.token) } else { None };
        self.kept_mask = if self.kept.is_none() { None } else { self.run.map(|r| r.mask) };
        self.kept_clip = if self.kept.is_none() { None } else { self.run.and_then(|r| r.clip) };
        if discards {
            if let Some(w) = &self.writes {
                w.0.store(false, Ordering::SeqCst);
            }
        } else if let Some(save) = self.save.as_mut() {
            save();
        }
        self.writes = None;
        self.clear_slot();
        true
    }

    /// Stops the running track when its mask no longer exists (`exists` looks for the run's mask on the run's clip in
    /// the project of `owner`). Called after every project change of that owner; a run of another owner is left
    /// alone. Its frames are not saved.
    pub fn stop_if_mask_gone(&mut self, owner: Option<usize>, exists: impl Fn(Option<Id>, Id) -> bool) -> bool {
        let Some(r) = self.run else { return false };
        if self.owner != owner || exists(r.clip, r.mask) {
            return false;
        }
        self.stop("its mask was removed", false, true)
    }

    /// Stops the running track when its mask's cache key is no longer the one it started with (`current` looks for
    /// the run's mask on the run's clip in the project of `owner`, not for the first clip with that mask id: the
    /// other half of a split clip has the same ids. A new click, undo or redo of a point changed the pick), so a run never goes on storing
    /// frames for a pick the mask does not have. The frames it stored are saved under its own key: the pick can come
    /// back (undo, redo) and finds them. Returns the stopped run; None when nothing was stopped (also a run without a
    /// key: a path track).
    pub fn stop_if_key_changed(
        &mut self,
        owner: Option<usize>,
        current: impl Fn(Option<Id>, Id) -> Option<String>,
    ) -> Option<Run> {
        let r = self.run?;
        let key = self.key.as_ref()?;
        if self.owner != owner || current(r.clip, r.mask).as_ref() == Some(key) {
            return None;
        }
        self.stop("its pick changed", false, false);
        Some(r)
    }

    /// Stops the running track of `owner` (its window or project closes); its frames are saved.
    pub fn stop_owner(&mut self, owner: Option<usize>, reason: &str) -> bool {
        if self.run.is_none() || self.owner != owner {
            return false;
        }
        self.stop(reason, false, false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::rc::Rc;

    fn mask(n: u128) -> Id {
        Id::from_u128(n)
    }

    #[test]
    fn a_new_start_stops_the_old_run_and_cancels_its_task() {
        let mut a = MaskTrackActivity::new();
        let t1 = a.start(mask(1), true, StartOptions::default());
        let canceled = Rc::new(Cell::new(false));
        let c2 = Rc::clone(&canceled);
        a.attach(Box::new(move || c2.set(true)), t1);
        let t2 = a.start(mask(2), false, StartOptions::default());
        assert!(canceled.get());
        assert!(!a.is_current(t1) && a.is_current(t2));
        assert!(!a.may_write(t1));
    }

    #[test]
    fn the_users_stop_may_still_write_once() {
        let mut a = MaskTrackActivity::new();
        let t = a.start(mask(1), true, StartOptions { clip: Some(mask(9)), ..Default::default() });
        assert!(a.stop("Stop", true, false));
        assert!(!a.is_running() && a.may_write(t));
        assert_eq!((a.user_stop(), a.user_stop_mask(), a.user_stop_clip()), (Some(t), Some(mask(1)), Some(mask(9))));
        let t2 = a.start(mask(1), true, StartOptions::default());
        assert!(!a.may_write(t) && a.may_write(t2));
        assert!(a.user_stop().is_none());
    }

    #[test]
    fn a_gone_mask_discards_and_other_owners_are_left_alone() {
        let mut a = MaskTrackActivity::new();
        let t = a.start(mask(1), true, StartOptions { owner: Some(7), key: Some("k".into()), ..Default::default() });
        let keeps = a.keeps_frames(t);
        assert!(keeps());
        assert!(!a.stop_if_mask_gone(Some(8), |_, _| false));
        assert!(a.stop_if_mask_gone(Some(7), |_, _| false));
        assert!(!keeps() && !a.is_running());
    }

    #[test]
    fn a_changed_key_stops_and_saves() {
        let mut a = MaskTrackActivity::new();
        let saved = Rc::new(Cell::new(0));
        let s2 = Rc::clone(&saved);
        a.start(
            mask(1),
            true,
            StartOptions {
                owner: Some(7),
                key: Some("k1".into()),
                save: Some(Box::new(move || s2.set(s2.get() + 1))),
                ..Default::default()
            },
        );
        assert!(a.is_following(mask(5), mask(1), "k1", Some(7)));
        assert!(a.stop_if_key_changed(Some(7), |_, _| Some("k1".into())).is_none());
        let r = a.stop_if_key_changed(Some(7), |_, _| Some("k2".into()));
        assert!(r.is_some() && saved.get() == 1 && !a.is_running());
    }

    #[test]
    fn progress_turn_and_finish_follow_the_token() {
        let mut a = MaskTrackActivity::new();
        let t = a.start(mask(1), true, StartOptions { automatic: true, ..Default::default() });
        assert!(a.progress(40, t) && !a.progress(40, t) && !a.progress(50, t + 1));
        assert!(a.turn(false, t));
        assert_eq!(a.run.map(|r| (r.forward, r.percent)), Some((false, -1)));
        assert!(a.stop_automatic("tool", false));
        let t2 = a.start(mask(1), true, StartOptions::default());
        a.finish(t);
        assert!(a.is_running());
        a.finish(t2);
        assert!(!a.is_running());
    }
}
