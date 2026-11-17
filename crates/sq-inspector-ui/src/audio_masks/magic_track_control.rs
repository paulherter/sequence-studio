// Swift: MagicTrackControl.swift
//! The state of the Magic mask's explicit tracking controls. A pick only stores its matte on the frame it was made on;
//! nothing follows it until the user asks: one frame back / forward (`step`), back to the clip's start / on to its end
//! (`run`, continuous until it ends or Stop). One piece at a time.

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Phase {
    Idle,
    /// Tracking `forward`; `frame` is the source time of the frame being done, `done` the frames finished.
    Tracking {
        forward: bool,
        step: bool,
        frame: f64,
        done: i64,
        total: i64,
    },
    /// The user pressed Stop; `done` frames were kept.
    Stopped {
        done: i64,
    },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Command {
    Step { forward: bool },
    Run { forward: bool },
}

/// What to track: source seconds, `from` to `to`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Leg {
    pub from: f64,
    pub to: f64,
    pub forward: bool,
    pub frames: i64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MagicTrackControl {
    phase: Phase,
    leg: Option<Leg>,
}

impl Default for MagicTrackControl {
    fn default() -> Self {
        MagicTrackControl::new()
    }
}

impl MagicTrackControl {
    pub fn new() -> Self {
        MagicTrackControl { phase: Phase::Idle, leg: None }
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    pub fn is_tracking(&self) -> bool {
        matches!(self.phase, Phase::Tracking { .. })
    }

    /// A pick was stored. It never starts tracking: the matte is the keyframe of the frame it was made on.
    pub fn pick_stored(&mut self) {
        if !self.is_tracking() {
            self.phase = Phase::Idle;
        }
    }

    /// Starts `command` from source time `playhead`; `edge` is the clip's last (forward) or first (backward) source time,
    /// `frame` one source frame in seconds. None (and no change) while tracking or when there is no frame to go to.
    pub fn begin(&mut self, command: Command, playhead: f64, edge: f64, frame: f64) -> Option<Leg> {
        if self.is_tracking() || frame <= 0.0 {
            return None;
        }
        let (forward, step) = match command {
            Command::Step { forward } => (forward, true),
            Command::Run { forward } => (forward, false),
        };
        let mut to = if step { playhead + if forward { frame } else { -frame } } else { edge };
        to = if forward { to.min(edge) } else { to.max(edge) };
        let distance = if forward { to - playhead } else { playhead - to };
        if distance <= frame * 0.25 {
            return None;
        }
        let frames = (((distance / frame).round()) as i64 + 1).max(2);
        let l = Leg { from: playhead, to, forward, frames };
        self.leg = Some(l);
        self.phase = Phase::Tracking { forward, step, frame: playhead, done: 0, total: frames };
        Some(l)
    }

    /// `fraction` (0...1) of the running leg is done.
    pub fn progress(&mut self, fraction: f64) {
        let Phase::Tracking { forward, step, total, .. } = self.phase else { return };
        let Some(l) = self.leg else { return };
        let p = fraction.clamp(0.0, 1.0);
        self.phase = Phase::Tracking {
            forward,
            step,
            frame: l.from + (l.to - l.from) * p,
            done: (p * total as f64).floor() as i64,
            total,
        };
    }

    /// The user's Stop. False when nothing was tracking.
    pub fn stop(&mut self) -> bool {
        let Phase::Tracking { done, .. } = self.phase else { return false };
        self.phase = Phase::Stopped { done };
        self.leg = None;
        true
    }

    /// The leg ended by itself (all frames, the object was lost, an error). A stop stays `stopped`.
    pub fn finish(&mut self) {
        if self.is_tracking() {
            self.phase = Phase::Idle;
        }
        self.leg = None;
    }

    /// One line for the track row.
    pub fn status_text(&self) -> String {
        match self.phase {
            Phase::Idle => "Idle".to_string(),
            Phase::Tracking { forward, done, total, .. } => {
                format!("Tracking {}: {done} of {total} frames", if forward { "forward" } else { "backward" })
            }
            Phase::Stopped { done } => format!("Stopped after {done} frames"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FD: f64 = 1.0 / 24.0;

    #[test]
    fn a_pick_starts_nothing() {
        let mut c = MagicTrackControl::new();
        c.pick_stored();
        assert_eq!(c.phase(), Phase::Idle);
        assert!(!c.is_tracking());
    }

    #[test]
    fn step_goes_one_frame_each_way() {
        let mut c = MagicTrackControl::new();
        let f = c.begin(Command::Step { forward: true }, 1.0, 5.0, FD);
        assert!(f.is_some_and(|f| f.from == 1.0 && (f.to - (1.0 + FD)).abs() < 1e-9 && f.forward));
        c.finish();
        let b = c.begin(Command::Step { forward: false }, 1.0, 0.0, FD);
        assert!(b.is_some_and(|b| (b.to - (1.0 - FD)).abs() < 1e-9 && !b.forward));
    }

    #[test]
    fn step_at_the_edge_does_nothing() {
        let mut c = MagicTrackControl::new();
        let a = c.begin(Command::Step { forward: true }, 5.0, 5.0, FD);
        let b = c.begin(Command::Run { forward: false }, 0.0, 0.0, FD);
        assert!(a.is_none() && b.is_none());
        assert_eq!(c.phase(), Phase::Idle);
    }

    #[test]
    fn run_goes_to_the_edge_and_refuses_a_second_start() {
        let mut c = MagicTrackControl::new();
        let r = c.begin(Command::Run { forward: true }, 1.0, 3.0, FD);
        assert!(r.is_some_and(|r| r.to == 3.0 && r.frames == 49));
        assert!(c.is_tracking());
        let second = c.begin(Command::Step { forward: false }, 1.0, 0.0, FD);
        assert!(second.is_none());
        c.progress(0.5);
        let Phase::Tracking { frame, done, total, .. } = c.phase() else { panic!("not tracking") };
        assert!((frame - 2.0).abs() < 1e-9 && done == 24 && total == 49);
        c.finish();
        assert_eq!(c.phase(), Phase::Idle);
    }

    #[test]
    fn stop_keeps_the_count() {
        let mut c = MagicTrackControl::new();
        assert!(!c.stop());
        let _ = c.begin(Command::Run { forward: false }, 3.0, 0.0, FD);
        c.progress(0.25);
        assert!(c.stop());
        assert_eq!(c.phase(), Phase::Stopped { done: 18 });
        c.finish();
        assert_eq!(c.phase(), Phase::Stopped { done: 18 });
        let again = c.begin(Command::Step { forward: true }, 1.0, 5.0, FD);
        assert!(again.is_some());
    }
}
