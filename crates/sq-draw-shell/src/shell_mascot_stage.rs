// Swift: ShellMascotStage.swift
//! One `SQMascotPlayer` per slot (a row, the dialog footer), advanced by the wall-clock time between draws, so Pip blinks and
//! breathes at any redraw rate (the same player the Mac view runs). A slot restarts when its animation changes.
//! [`ShellMascotStage::animating`] tells a host whether a redraw is still worth asking for.
//!
//! Breathing never ends, so a stage that [`sleeps`](ShellMascotStage::sleeping) would keep an idle window drawing at the
//! display rate for ever (the start screen did: 60 frames/s, 9 % of a core). It plays for [`AWAKE_SECONDS`] after it
//! appeared or was [woken](ShellMascotStage::wake) by input, then holds the resting pose and asks for no more frames.

use crate::shell_mascot::{ShellMascot, brand_violet};
use sq_draw::Canvas;
use sq_uikit::controls_grid::CGRect;
use sq_uikit::sqmascot_model::{SQMascotAnim, SQMascotLibrary, SQMascotPose};
use sq_uikit::sqmascot_player::SQMascotPlayer;
use std::collections::HashMap;

/// How long a sleeping stage plays after it appeared or the last input (seconds): a wink or two, then it settles.
pub const AWAKE_SECONDS: f64 = 8.0;

struct Slot {
    anim: SQMascotAnim,
    player: SQMascotPlayer,
    last: f64,
}

/// The players of the mascots on screen.
#[derive(Default)]
pub struct ShellMascotStage {
    slots: HashMap<i64, Slot>,
    /// Plays only [`AWAKE_SECONDS`] after the last wake (the start screen); `false` plays for ever (the installer).
    sleeps: bool,
    /// The steady time the stage falls asleep at; set by the first pose and moved on by [`ShellMascotStage::wake`].
    awake_until: Option<f64>,
    /// Asleep: every pose is the resting one and no frames are wanted.
    asleep: bool,
    /// The last pose had the eyes (part) shut: the stage never falls asleep in a blink.
    blinking: bool,
}

impl ShellMascotStage {
    /// An empty stage.
    pub fn new() -> ShellMascotStage {
        ShellMascotStage::default()
    }

    /// A stage that falls asleep [`AWAKE_SECONDS`] after it appeared or was woken, so an idle window stops drawing.
    pub fn sleeping() -> ShellMascotStage {
        ShellMascotStage { sleeps: true, ..ShellMascotStage::default() }
    }

    /// Input arrived: a sleeping stage plays again for [`AWAKE_SECONDS`] from `now`.
    pub fn wake(&mut self, now: f64) {
        if self.sleeps {
            self.awake_until = Some(now + AWAKE_SECONDS);
            self.asleep = false;
        }
    }

    /// The pose of `slot` at `now` (seconds, any steady clock).
    pub(crate) fn pose(&mut self, anim: SQMascotAnim, slot: i64, now: f64) -> SQMascotPose {
        let lib = SQMascotLibrary::shared();
        if self.sleeps {
            let until = *self.awake_until.get_or_insert(now + AWAKE_SECONDS);
            self.asleep |= now >= until && !self.blinking;
        }
        if sq_draw::motion::reduce_motion() || self.asleep {
            // Reduced motion or asleep: the still resting pose, no player runs.
            return lib.animation(anim).rest.clone();
        }
        let pose = self.advance_slot(anim, slot, now);
        self.blinking = pose.blink < 1.0;
        pose
    }

    fn advance_slot(&mut self, anim: SQMascotAnim, slot: i64, now: f64) -> SQMascotPose {
        let lib = SQMascotLibrary::shared();
        if let Some(s) = self.slots.get_mut(&slot).filter(|s| s.anim == anim) {
            let dt = ((now - s.last).max(0.0) * 1000.0).min(250.0);
            s.last = now;
            return s.player.advance(dt);
        }
        let mut player =
            SQMascotPlayer::new(lib.animation(anim).clone(), lib.idle.clone(), (slot as u64).wrapping_add(1), None);
        player.start();
        let p = player.advance(0.0);
        self.slots.insert(slot, Slot { anim, player, last: now });
        p
    }

    /// Drops the player of `slot`.
    pub fn forget(&mut self, slot: i64) {
        self.slots.remove(&slot);
    }

    /// Whether a player is running (a sleeping stage that fell asleep asks for no frames).
    pub fn animating(&self) -> bool {
        !sq_draw::motion::reduce_motion() && !self.asleep && !self.slots.is_empty()
    }

    /// Draws `anim` for `slot` aspect-fitted in `rect`. `now` is the steady clock in seconds.
    pub fn draw(&mut self, anim: SQMascotAnim, slot: i64, now: f64, rect: CGRect, c: &mut Canvas) {
        let a = SQMascotLibrary::shared().animation(anim);
        let (mut tight, mut vb) = (a.tight, a.view_box);
        if rect.width.min(rect.height) <= 24.0 {
            tight = true;
            vb = CGRect::new(125.0, 268.0, 774.0, 774.0);
        }
        let pose = self.pose(anim, slot, now);
        ShellMascot::draw_pose(&pose, tight, vb, rect, c, brand_violet());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn the_stage_plays_and_blinks_over_time() {
        let mut stage = ShellMascotStage::new();
        let mut seen = BTreeSet::new();
        for (n, anim) in
            [SQMascotAnim::Proud, SQMascotAnim::Think, SQMascotAnim::Wink, SQMascotAnim::Peek, SQMascotAnim::Sad]
                .into_iter()
                .enumerate()
        {
            let mut t = 0.0;
            for _ in 0..2400 {
                // 24 s at 100 fps
                seen.insert((stage.pose(anim, n as i64, t).blink * 100.0).round() as i64);
                t += 0.01;
            }
        }
        assert!(seen.contains(&0) && seen.contains(&100), "the eyes close and open");
        assert!(stage.animating());
        stage.forget(0);
    }

    #[test]
    fn a_sleeping_stage_settles_to_the_rest_pose_and_input_wakes_it() {
        let mut stage = ShellMascotStage::sleeping();
        let rest = SQMascotLibrary::shared().animation(SQMascotAnim::Peek).rest.clone();
        let mut t = 0.0;
        while t < AWAKE_SECONDS - 0.1 {
            let _ = stage.pose(SQMascotAnim::Peek, 1, t);
            assert!(stage.animating(), "plays while awake (t = {t:.2})");
            t += 1.0 / 60.0;
        }
        // Frames go on until the eyes are open, then the stage holds the rest pose and wants no frame.
        let mut frames = 0;
        while stage.animating() {
            t += 1.0 / 60.0;
            let _ = stage.pose(SQMascotAnim::Peek, 1, t);
            frames += 1;
            assert!(frames < 120, "never fell asleep");
        }
        assert_eq!(stage.pose(SQMascotAnim::Peek, 1, t + 30.0), rest);
        assert!(!stage.animating());
        stage.wake(t + 31.0);
        assert!(stage.animating(), "input wakes the stage");
        let _ = stage.pose(SQMascotAnim::Peek, 1, t + 31.0);
        assert!(stage.animating());
    }

    #[test]
    fn a_stage_without_the_sleep_policy_plays_for_ever() {
        let mut stage = ShellMascotStage::new();
        for n in 0..3600 {
            let _ = stage.pose(SQMascotAnim::Work, 1, f64::from(n) * 0.1);
        }
        assert!(stage.animating(), "6 minutes in, the installer's Pip still plays");
    }

    #[test]
    fn reduced_motion_shows_the_still_rest_pose_and_asks_for_no_frames() {
        sq_draw::motion::set_reduce_motion(true);
        let mut stage = ShellMascotStage::new();
        let a = stage.pose(SQMascotAnim::Peek, 1, 0.0);
        let b = stage.pose(SQMascotAnim::Peek, 1, 7.3);
        let animating = stage.animating();
        sq_draw::motion::set_reduce_motion(false);
        assert_eq!(a, b);
        assert!(!animating);
    }

    #[test]
    fn a_slot_restarts_when_its_animation_changes() {
        let mut stage = ShellMascotStage::new();
        let _ = stage.pose(SQMascotAnim::Work, 2, 0.0);
        let p = stage.pose(SQMascotAnim::Cheer, 2, 0.01);
        assert!(p[sq_uikit::sqmascot_model::SQMascotKey::Hide] < 0.5);
    }
}
