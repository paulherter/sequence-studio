//! Port of `SQUIKit/Sources/SQUIKit/Mascot/SQMascotPlayer.swift`.

use crate::sqmascot_model::{
    SQMascotAnimation, SQMascotEase, SQMascotIdleConfig, SQMascotKey, SQMascotKind, SQMascotPose, SQMascotStep,
};
use std::f64::consts::PI;
use std::ops::RangeInclusive;

/// Small deterministic generator so tests can pin the idle schedule.
#[derive(Clone, Copy, Debug)]
pub struct SQMascotRandom {
    state: u64,
}

impl SQMascotRandom {
    pub fn new(seed: u64) -> SQMascotRandom {
        SQMascotRandom { state: seed.wrapping_add(0x9E37_79B9_7F4A_7C15) }
    }

    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> f64 {
        self.state = self.state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        (z >> 11) as f64 / (1u64 << 53) as f64
    }

    pub fn next_in(&mut self, r: &RangeInclusive<f64>) -> f64 {
        r.start() + self.next() * (r.end() - r.start())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Done {
    None,
    Idle,
    Loop,
    Settled,
}

/// The clock-free state machine behind a mascot: key-pose steps, then rest with breathing, sway, blinks and (for
/// `rest` animations) a repeat after a random pause. Advance it with real frame deltas in milliseconds; it returns the
/// pose to draw. All times in milliseconds.
#[derive(Clone, Debug)]
pub struct SQMascotPlayer {
    pub animation: SQMascotAnimation,
    pub idle: SQMascotIdleConfig,
    /// Overrides the animation's rest pause between repeats (seconds); nil keeps the design value.
    pub rest_pause: Option<RangeInclusive<f64>>,

    pose: SQMascotPose,
    resting: bool,
    clock: f64,
    /// Clock time of the next repeat; nil none scheduled.
    next_action: Option<f64>,
    next_blink: f64,
    blink_count: i64,

    queue: Vec<SQMascotStep>,
    index: usize,
    t: f64,
    holding: bool,
    from: SQMascotPose,
    done: Done,
    fade: f64,
    blink_t: f64,
    blink_double: bool,
    rng: SQMascotRandom,
}

impl SQMascotPlayer {
    /// `start_pose` continues from a pose already on screen (a reaction taking over); nil starts at the animation's own.
    pub fn new(
        animation: SQMascotAnimation,
        idle: SQMascotIdleConfig,
        seed: u64,
        start_pose: Option<SQMascotPose>,
    ) -> SQMascotPlayer {
        let pose = start_pose.unwrap_or_else(|| {
            if animation.kind == SQMascotKind::Once {
                animation.from.clone().unwrap_or_else(|| animation.rest.clone())
            } else {
                animation.rest.clone()
            }
        });
        SQMascotPlayer {
            animation,
            idle,
            rest_pause: None,
            from: pose.clone(),
            pose,
            resting: false,
            clock: 0.0,
            next_action: None,
            next_blink: 0.0,
            blink_count: 0,
            queue: Vec::new(),
            index: 0,
            t: 0.0,
            holding: false,
            done: Done::None,
            fade: 0.0,
            blink_t: -1.0,
            blink_double: false,
            rng: SQMascotRandom::new(seed),
        }
    }

    pub fn pose(&self) -> &SQMascotPose {
        &self.pose
    }

    pub fn resting(&self) -> bool {
        self.resting
    }

    pub fn clock(&self) -> f64 {
        self.clock
    }

    pub fn next_action(&self) -> Option<f64> {
        self.next_action
    }

    pub fn next_blink(&self) -> f64 {
        self.next_blink
    }

    pub fn blink_count(&self) -> i64 {
        self.blink_count
    }

    pub fn is_busy(&self) -> bool {
        !self.queue.is_empty()
    }

    /// Begins the animation by its kind (loop: runs on; once: plays then rests; rest: plays once, then repeats).
    pub fn start(&mut self) {
        self.next_action = None;
        match self.animation.kind {
            SQMascotKind::Loop => {
                if !self.animation.steps.is_empty() {
                    let steps = self.animation.steps.clone();
                    self.run(steps, Done::Loop);
                } else {
                    self.settle();
                }
            }
            SQMascotKind::Part => self.settle(),
            SQMascotKind::Once => {
                let first = SQMascotStep {
                    to: self.animation.from.clone().unwrap_or_else(|| self.animation.rest.clone()),
                    duration: 320.0,
                    ease: SQMascotEase::Io,
                    hold: 520.0,
                };
                let steps = std::iter::once(first).chain(self.animation.steps.iter().cloned()).collect();
                self.run(steps, Done::Idle);
            }
            SQMascotKind::Rest => {
                if self.animation.steps.is_empty() {
                    self.settle();
                } else {
                    let first = SQMascotStep {
                        to: self.animation.rest.clone(),
                        duration: 300.0,
                        ease: SQMascotEase::Io,
                        hold: 500.0,
                    };
                    let steps = std::iter::once(first).chain(self.animation.steps.iter().cloned()).collect();
                    self.run(steps, Done::Idle);
                }
            }
        }
    }

    /// Plays the steps once from the current pose, then settles to the animation's rest (reactions: kind `part`).
    pub fn play_once(&mut self) {
        self.next_action = None;
        let steps = self.animation.steps.clone();
        self.run(steps, Done::Idle);
    }

    fn run(&mut self, steps: Vec<SQMascotStep>, d: Done) {
        self.resting = false;
        self.fade = 0.0;
        self.blink_t = -1.0;
        let empty = steps.is_empty();
        self.queue = steps;
        self.index = 0;
        self.t = 0.0;
        self.holding = false;
        self.from = self.pose.clone();
        self.done = d;
        if empty {
            self.finish();
        }
    }

    fn finish(&mut self) {
        let d = self.done;
        self.done = Done::None;
        self.queue = Vec::new();
        match d {
            Done::None => {}
            Done::Idle => self.settle(),
            Done::Loop => {
                let steps = self.animation.steps.clone();
                self.run(steps, Done::Loop);
            }
            Done::Settled => {
                self.resting = true;
                self.next_blink = self.clock + self.rng.next_in(&self.idle.blink_every);
                if self.animation.kind == SQMascotKind::Rest
                    && !self.animation.steps.is_empty()
                    && self.next_action.is_none()
                {
                    let pause = self.rest_pause.clone().or_else(|| self.animation.pause.clone()).unwrap_or(5.0..=9.0);
                    self.next_action = Some(self.clock + self.rng.next_in(&pause) * 1000.0);
                }
            }
        }
    }

    fn settle(&mut self) {
        let step = SQMascotStep {
            to: self.animation.rest.clone(),
            duration: self.idle.settle,
            ease: SQMascotEase::Io,
            hold: 0.0,
        };
        self.run(vec![step], Done::Settled);
    }

    fn act(&mut self) {
        self.next_action = None;
        let steps = self.animation.steps.clone();
        self.run(steps, Done::Idle);
    }

    /// Advances by `dt` ms and returns the pose to draw.
    pub fn advance(&mut self, dt: f64) -> SQMascotPose {
        self.clock += dt;
        if !self.queue.is_empty() {
            let mut left = dt;
            while !self.queue.is_empty() && left > 0.0 {
                let (duration, ease, hold) = {
                    let s = &self.queue[self.index];
                    (s.duration, s.ease, s.hold)
                };
                if !self.holding {
                    let used = left.min(duration - self.t);
                    self.t += used;
                    left -= used;
                    self.pose =
                        SQMascotPose::mix(&self.from, &self.queue[self.index].to, ease.value(self.t / duration));
                    if self.t >= duration {
                        self.pose = self.queue[self.index].to.clone();
                        self.holding = true;
                        self.t = 0.0;
                    }
                } else {
                    let used = left.min(hold - self.t);
                    self.t += used;
                    left -= used;
                    if self.t >= hold {
                        self.from = self.pose.clone();
                        self.holding = false;
                        self.t = 0.0;
                        self.index += 1;
                        if self.index >= self.queue.len() {
                            self.finish();
                            if self.queue.is_empty() {
                                break;
                            }
                        }
                    }
                }
            }
            return self.pose.clone();
        }
        if !self.resting {
            return self.pose.clone();
        }
        self.fade = (self.fade + dt / self.idle.fade_in).min(1.0);
        if let Some(n) = self.next_action
            && self.clock >= n
            && self.blink_t < 0.0
        {
            self.act();
            return self.pose.clone();
        }
        let w = self.fade * self.fade * (3.0 - 2.0 * self.fade) * self.animation.breath;
        let ph1 = self.clock / self.idle.breath_period * 2.0 * PI;
        let ph2 = self.clock / self.idle.sway_period * 2.0 * PI;
        let mut p = self.pose.clone();
        p[SQMascotKey::Sy] = self.pose[SQMascotKey::Sy] * (1.0 + self.idle.breath_height * w * ph1.sin());
        p[SQMascotKey::Sx] = self.pose[SQMascotKey::Sx] * (1.0 - self.idle.breath_width * w * ph1.sin());
        p[SQMascotKey::Rot] = self.pose[SQMascotKey::Rot] + self.idle.sway_degrees * w * ph2.sin();
        if self.animation.breath > 0.0 {
            if self.blink_t < 0.0 && self.clock >= self.next_blink {
                self.blink_t = 0.0;
                self.blink_count += 1;
                self.blink_double = self.blink_count % self.idle.double_every == 0;
            }
            if self.blink_t >= 0.0 {
                let one = self.idle.blink_close + self.idle.blink_shut + self.idle.blink_open;
                self.blink_t += dt;
                let u = if self.blink_double && self.blink_t >= one + self.idle.blink_gap {
                    self.blink_t - one - self.idle.blink_gap
                } else {
                    self.blink_t
                };
                p.blink = Self::blink_openness(u, &self.idle);
                let end = if self.blink_double { 2.0 * one + self.idle.blink_gap } else { one };
                if self.blink_t >= end {
                    self.blink_t = -1.0;
                    self.next_blink = self.clock + self.rng.next_in(&self.idle.blink_every);
                }
            }
        }
        p
    }

    /// Eye openness 0...1 at `u` ms into one blink (close, shut, open).
    pub fn blink_openness(u: f64, c: &SQMascotIdleConfig) -> f64 {
        let e = SQMascotEase::Io;
        if u < c.blink_close {
            return 1.0 - e.value(u / c.blink_close);
        }
        if u < c.blink_close + c.blink_shut {
            return 0.0;
        }
        if u < c.blink_close + c.blink_shut + c.blink_open {
            return e.value((u - c.blink_close - c.blink_shut) / c.blink_open);
        }
        1.0
    }
}
