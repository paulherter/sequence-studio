// Swift: Mascot/SQMascotReactor.swift
//! Reactions of a sleeping Pip, clock-free like the player: M3 (a file is dragged over: wakes, eyes and head follow it,
//! hops away on drop or goes back to sleep) and R2 (the pointer is over the monitor: one eye opens, falls shut again on
//! leave). Only a `sleep` animation reacts. The view feeds events and frame deltas and draws `advance`'s pose.

use crate::sqmascot_model::{SQMascotAnim, SQMascotAnimation, SQMascotFollower, SQMascotLibrary, SQMascotPose};
use crate::sqmascot_player::SQMascotPlayer;
use std::ops::RangeInclusive;
use std::sync::Arc;

/// Where the reaction state machine is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Base,
    Waking,
    Following,
    Leaving,
    Opening,
    Open,
    Dozing,
}

/// The state machine of the sleeping Pip.
#[derive(Clone)]
pub struct SQMascotReactor {
    mode: Mode,
    /// What is drawn now (the base animation, or a reaction part with its own view box).
    animation: SQMascotAnimation,
    player: SQMascotPlayer,
    rest_pause: Option<RangeInclusive<f64>>,
    base: SQMascotAnimation,
    library: Arc<SQMascotLibrary>,
    follower: SQMascotFollower,
    offset: (f64, f64),
    shown: SQMascotPose,
    seed: u64,
    /// Only the sleeping Pip reacts (the places that show him asleep are the empty Project panel and monitor).
    reacts: bool,
}

impl SQMascotReactor {
    pub fn new(base: SQMascotAnimation, library: Arc<SQMascotLibrary>, seed: u64, reacts: bool) -> Self {
        let player = SQMascotPlayer::new(base.clone(), library.idle.clone(), seed, None);
        let shown = player.pose().clone();
        SQMascotReactor {
            mode: Mode::Base,
            animation: base.clone(),
            player,
            rest_pause: None,
            base,
            follower: SQMascotFollower::new(library.look.clone()),
            library,
            offset: (0.0, 0.0),
            shown,
            seed,
            reacts,
        }
    }

    pub fn mode(&self) -> Mode {
        self.mode
    }

    pub fn animation(&self) -> &SQMascotAnimation {
        &self.animation
    }

    pub fn player(&self) -> &SQMascotPlayer {
        &self.player
    }

    pub fn rest_pause(&self) -> Option<&RangeInclusive<f64>> {
        self.rest_pause.as_ref()
    }

    /// Sets the rest pause of the player too.
    pub fn set_rest_pause(&mut self, pause: Option<RangeInclusive<f64>>) {
        self.player.rest_pause = pause.clone();
        self.rest_pause = pause;
    }

    pub fn pose(&self) -> &SQMascotPose {
        &self.shown
    }

    pub fn start(&mut self) {
        self.player.start();
        self.shown = self.player.pose().clone();
    }

    /// 30 fps is enough when nothing moves but breathing.
    pub fn is_calm(&self) -> bool {
        self.player.resting() && !self.player.is_busy() && self.mode != Mode::Following
    }

    // MARK: events

    /// A drag entered the place. Returns false when this Pip does not react.
    pub fn drag_began(&mut self) -> bool {
        if !(self.reacts && matches!(self.mode, Mode::Base | Mode::Opening | Mode::Open | Mode::Dozing)) {
            return false;
        }
        self.swap_to(self.library.animation(SQMascotAnim::DragWake).clone(), true);
        self.follower = SQMascotFollower::new(self.library.look.clone());
        self.mode = Mode::Waking;
        true
    }

    /// Where the dragged item is, as an offset from Pip's center in points (y grows down).
    pub fn drag_moved(&mut self, dx: f64, dy: f64) {
        self.offset = (dx, dy);
    }

    /// The drag ended: `dropped` hops Pip away, else he goes back to sleep.
    pub fn drag_ended(&mut self, dropped: bool) {
        if !matches!(self.mode, Mode::Waking | Mode::Following) {
            return;
        }
        if dropped {
            self.swap_to(self.library.animation(SQMascotAnim::DragAway).clone(), true);
            self.mode = Mode::Leaving;
        } else {
            self.return_to_base();
        }
    }

    pub fn hover_changed(&mut self, inside: bool) {
        if !self.reacts {
            return;
        }
        if inside && matches!(self.mode, Mode::Base | Mode::Dozing) {
            self.swap_to(self.library.animation(SQMascotAnim::HoverOpen).clone(), true);
            self.mode = Mode::Opening;
        } else if !inside && matches!(self.mode, Mode::Opening | Mode::Open) {
            self.swap_to(self.library.animation(SQMascotAnim::HoverClose).clone(), true);
            self.mode = Mode::Dozing;
        }
    }

    /// Back to the plain animation (view hidden, shown again).
    pub fn reset(&mut self, seed: u64) {
        self.seed = seed;
        self.mode = Mode::Base;
        self.animation = self.base.clone();
        self.player = SQMascotPlayer::new(self.base.clone(), self.library.idle.clone(), seed, None);
        self.player.rest_pause = self.rest_pause.clone();
        self.shown = self.player.pose().clone();
    }

    pub fn advance(&mut self, dt: f64) -> SQMascotPose {
        match self.mode {
            Mode::Following => {
                self.shown = self.follower.advance(dt, self.offset.0, self.offset.1);
            }
            Mode::Waking => {
                self.shown = self.player.advance(dt);
                if self.player.resting() {
                    self.mode = Mode::Following;
                }
            }
            Mode::Opening => {
                self.shown = self.player.advance(dt);
                if self.player.resting() {
                    self.mode = Mode::Open;
                }
            }
            Mode::Dozing => {
                self.shown = self.player.advance(dt);
                if self.player.resting() {
                    self.return_to_base();
                }
            }
            Mode::Base | Mode::Open | Mode::Leaving => {
                self.shown = self.player.advance(dt);
            }
        }
        self.shown.clone()
    }

    fn return_to_base(&mut self) {
        self.swap_to(self.base.clone(), false);
        self.player.rest_pause = self.rest_pause.clone();
        self.player.start();
        self.shown = self.player.pose().clone();
        self.mode = Mode::Base;
    }

    fn swap_to(&mut self, a: SQMascotAnimation, playing: bool) {
        self.seed = self.seed.wrapping_add(1);
        self.animation = a.clone();
        self.player = SQMascotPlayer::new(a, self.library.idle.clone(), self.seed, Some(self.shown.clone()));
        if playing {
            self.player.play_once();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sqmascot_model::{SQMascotFollower, SQMascotKey};

    fn lib() -> Arc<SQMascotLibrary> {
        Arc::new(SQMascotLibrary::shared().clone())
    }

    fn sleeper(reacts: bool) -> SQMascotReactor {
        let l = lib();
        let mut r = SQMascotReactor::new(l.animation(SQMascotAnim::Sleep).clone(), l, 4, reacts);
        r.start();
        r
    }

    fn run(r: &mut SQMascotReactor, ms: f64) {
        let mut t = 0.0;
        while t < ms {
            r.advance(16.0);
            t += 16.0;
        }
    }

    #[test]
    fn look_config_matches_design() {
        let l = &lib().look;
        assert!(l.rx == 55.0 && l.ry == 42.0 && l.lag == 130.0);
        assert!(l.x[&SQMascotKey::Ex] == 15.0 && l.x[&SQMascotKey::Fx] == 8.0 && l.x[&SQMascotKey::Rot] == 2.4);
        assert!(l.y[&SQMascotKey::Ey] == 13.0 && l.y[&SQMascotKey::Fy] == 7.0);
    }

    #[test]
    fn target_is_steps_clamped_to_three_and_one() {
        let l = lib();
        let a = l.look.target(110.0, 21.0);
        assert!((a.0 - 2.0).abs() < 1e-9 && (a.1 - 0.5).abs() < 1e-9);
        let b = l.look.target(-1000.0, 1000.0);
        assert!(b.0 == -3.0 && b.1 == 1.0);
    }

    #[test]
    fn follower_lags_with_time_constant() {
        let l = lib();
        let mut f = SQMascotFollower::new(l.look.clone());
        f.advance(130.0, 55.0 * 2.0, 0.0); // one time constant toward 2 steps
        assert!((f.gx() - 2.0 * (1.0 - (-1f64).exp())).abs() < 1e-9);
        for _ in 0..200 {
            f.advance(16.0, 55.0 * 2.0, 0.0);
        }
        assert!((f.gx() - 2.0).abs() < 1e-3);
        let p = f.look.pose(3.0, 1.0);
        assert!((p[SQMascotKey::Ex] - (l.look.base[SQMascotKey::Ex] + 45.0)).abs() < 1e-9);
        assert!((p[SQMascotKey::Ey] - (l.look.base[SQMascotKey::Ey] + 13.0)).abs() < 1e-9);
    }

    #[test]
    fn drag_wakes_follows_then_sleeps_or_hops() {
        let l = lib();
        let ex = l.look.base[SQMascotKey::Ex];
        let ey = l.look.base[SQMascotKey::Ey];
        let mut r = sleeper(true);
        assert_eq!(r.mode(), Mode::Base);
        assert!(r.drag_began());
        assert_eq!(r.mode(), Mode::Waking);
        run(&mut r, 1500.0);
        assert_eq!(r.mode(), Mode::Following);
        r.drag_moved(200.0, 0.0);
        run(&mut r, 1000.0);
        assert!((r.pose()[SQMascotKey::Ex] - (ex + 3.0 * 15.0)).abs() < 0.5); // clamped to 3 steps
        r.drag_moved(-55.0, 100.0);
        run(&mut r, 1000.0);
        assert!((r.pose()[SQMascotKey::Ex] - (ex - 15.0)).abs() < 0.5);
        assert!((r.pose()[SQMascotKey::Ey] - (ey + 13.0)).abs() < 0.5);
        let mut away = r.clone();
        r.drag_ended(false);
        assert_eq!(r.mode(), Mode::Base);
        away.drag_ended(true);
        assert_eq!(away.mode(), Mode::Leaving);
        run(&mut away, 1500.0);
        assert_eq!(away.pose()[SQMascotKey::Hide], 1.0);
    }

    #[test]
    fn non_sleeping_pip_ignores_everything() {
        let mut r = sleeper(false);
        assert!(!r.drag_began());
        r.hover_changed(true);
        assert_eq!(r.mode(), Mode::Base);
    }

    #[test]
    fn hover_opens_an_eye_and_falls_shut() {
        let mut r = sleeper(true);
        r.hover_changed(true);
        assert_eq!(r.mode(), Mode::Opening);
        run(&mut r, 1500.0);
        assert_eq!(r.mode(), Mode::Open);
        assert_eq!(r.pose().e_r.kind, "pill"); // one eye open and held
        r.hover_changed(false);
        assert_eq!(r.mode(), Mode::Dozing);
        run(&mut r, 1500.0);
        assert_eq!(r.mode(), Mode::Base);
        assert_eq!(r.animation().kind, lib().animation(SQMascotAnim::Sleep).kind);
    }

    #[test]
    fn leaving_mid_open_still_closes() {
        let mut r = sleeper(true);
        r.hover_changed(true);
        run(&mut r, 200.0);
        r.hover_changed(false);
        assert_eq!(r.mode(), Mode::Dozing);
        run(&mut r, 1500.0);
        assert_eq!(r.mode(), Mode::Base);
    }

    #[test]
    fn drag_takes_over_from_hover() {
        let mut r = sleeper(true);
        r.hover_changed(true);
        run(&mut r, 1500.0);
        assert!(r.drag_began());
        assert_eq!(r.mode(), Mode::Waking);
    }
}
