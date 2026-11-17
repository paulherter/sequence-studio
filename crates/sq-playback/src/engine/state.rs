//! The engine's lifecycle as data: one `EngineState` (transport) with one transition function, and the compositor's own
//! three-way slot. The A/V clock (`clock_held_since`, the master clock) stays separate: it is not a transport state, it
//! only runs while the transport is `Playing`.
//!
//! Swift truth (`PlaybackEngine.swift`): `play` ends a scrub, `beginScrub` pauses first, `endScrub` is a no-op unless a
//! scrub runs, `pause` while paused (or scrubbing) changes nothing. `Warming` is the short decoder warm-up of a resting
//! playhead: only entered from `Paused`, and read like `Paused` everywhere except the reduced-picture rule.

use sq_core_edit::playback::PlaybackRate;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EngineState {
    /// The playhead rests (nothing runs).
    Paused,
    /// Paused, and the warm-up decodes the first playback frames right now.
    Warming,
    /// The master clock moves the playhead at `rate` (never the zero rate).
    Playing(PlaybackRate),
    /// A scrub gesture: the playhead jumps, the decode favors keyframes.
    Scrubbing,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    /// `Play(ZERO)` is a pause.
    Play(PlaybackRate),
    Pause,
    BeginScrub,
    EndScrub,
    BeginWarm,
    EndWarm,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InvalidTransition {
    pub from: EngineState,
    pub event: Event,
}

impl EngineState {
    /// The one place a transport change is decided. `Err` leaves the state as it was.
    pub fn next(self, event: Event) -> Result<EngineState, InvalidTransition> {
        use EngineState::{Paused, Playing, Scrubbing, Warming};
        let bad = Err(InvalidTransition { from: self, event });
        match (self, event) {
            (Warming, _) if !matches!(event, Event::EndWarm) => bad,
            (_, Event::Play(r)) if r.is_paused() => self.next(Event::Pause),
            (_, Event::Play(r)) => Ok(Playing(r)),
            (Playing(_), Event::Pause) => Ok(Paused),
            (Paused | Scrubbing, Event::Pause) => Ok(self),
            (Paused | Playing(_) | Scrubbing, Event::BeginScrub) => Ok(Scrubbing),
            (Scrubbing, Event::EndScrub) => Ok(Paused),
            (Paused, Event::BeginWarm) => Ok(Warming),
            (Warming, Event::EndWarm) => Ok(Paused),
            _ => bad,
        }
    }

    /// The playback rate; zero unless `Playing`.
    pub fn rate(self) -> PlaybackRate {
        match self {
            EngineState::Playing(r) => r,
            _ => PlaybackRate::ZERO,
        }
    }
    pub fn is_playing(self) -> bool {
        matches!(self, EngineState::Playing(_))
    }
    pub fn is_scrubbing(self) -> bool {
        self == EngineState::Scrubbing
    }
    pub fn is_warming(self) -> bool {
        self == EngineState::Warming
    }
    /// The render thread ticks fast: playing or scrubbing.
    pub fn is_busy(self) -> bool {
        matches!(self, EngineState::Playing(_) | EngineState::Scrubbing)
    }
}

/// The compositor: never created, ready, drawing right now (taken out of the slot), or failed to be created.
/// `Failed` is final for this engine: it is reported, not retried every frame.
#[derive(Debug)]
pub enum CompositorSlot<C> {
    NotCreated,
    Ready(C),
    InUse,
    Failed(String),
}

impl<C> CompositorSlot<C> {
    /// Creation result: only from `NotCreated`. Returns false (and drops `made`) from any other state.
    pub fn settle(&mut self, made: Result<C, String>) -> bool {
        if !matches!(self, CompositorSlot::NotCreated) {
            return false;
        }
        *self = match made {
            Ok(c) => CompositorSlot::Ready(c),
            Err(e) => CompositorSlot::Failed(e),
        };
        true
    }
    /// `Ready` -> `InUse`, handing out the compositor.
    pub fn take(&mut self) -> Option<C> {
        match std::mem::replace(self, CompositorSlot::InUse) {
            CompositorSlot::Ready(c) => Some(c),
            other => {
                *self = other;
                None
            }
        }
    }
    /// `InUse` -> `Ready`. Returns false from any other state.
    pub fn give_back(&mut self, c: C) -> bool {
        if matches!(self, CompositorSlot::InUse) {
            *self = CompositorSlot::Ready(c);
            true
        } else {
            false
        }
    }
    pub fn ready_mut(&mut self) -> Option<&mut C> {
        match self {
            CompositorSlot::Ready(c) => Some(c),
            _ => None,
        }
    }
    pub fn needs_creation(&self) -> bool {
        matches!(self, CompositorSlot::NotCreated)
    }
    pub fn failure(&self) -> Option<&str> {
        match self {
            CompositorSlot::Failed(e) => Some(e),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use EngineState::{Paused, Playing, Scrubbing, Warming};

    const FWD: PlaybackRate = PlaybackRate::FORWARD;

    fn ev(s: EngineState, e: Event) -> Result<EngineState, InvalidTransition> {
        s.next(e)
    }

    #[test]
    fn play_and_pause_move_between_paused_and_playing() {
        assert_eq!(ev(Paused, Event::Play(FWD)), Ok(Playing(FWD)));
        assert_eq!(ev(Playing(FWD), Event::Play(PlaybackRate::new(2, 1))), Ok(Playing(PlaybackRate::new(2, 1))));
        assert_eq!(ev(Playing(FWD), Event::Pause), Ok(Paused));
        assert_eq!(ev(Playing(FWD), Event::Play(PlaybackRate::ZERO)), Ok(Paused));
        assert_eq!(ev(Paused, Event::Pause), Ok(Paused));
    }

    #[test]
    fn play_ends_a_scrub_and_a_scrub_stops_play() {
        assert_eq!(ev(Scrubbing, Event::Play(FWD)), Ok(Playing(FWD)));
        assert_eq!(ev(Playing(FWD), Event::BeginScrub), Ok(Scrubbing));
        assert_eq!(ev(Paused, Event::BeginScrub), Ok(Scrubbing));
        assert_eq!(ev(Scrubbing, Event::BeginScrub), Ok(Scrubbing));
        assert_eq!(ev(Scrubbing, Event::Pause), Ok(Scrubbing), "a step during a scrub keeps the scrub");
        assert_eq!(ev(Scrubbing, Event::EndScrub), Ok(Paused));
    }

    #[test]
    fn warming_is_a_visit_to_paused() {
        assert_eq!(ev(Paused, Event::BeginWarm), Ok(Warming));
        assert_eq!(ev(Warming, Event::EndWarm), Ok(Paused));
        assert!(Warming.rate().is_paused() && !Warming.is_busy() && Warming.is_warming());
    }

    #[test]
    fn invalid_transitions_are_refused() {
        for e in [Event::Play(FWD), Event::Pause, Event::BeginScrub, Event::EndScrub, Event::BeginWarm] {
            assert_eq!(ev(Warming, e), Err(InvalidTransition { from: Warming, event: e }), "{e:?} while warming");
        }
        assert!(ev(Paused, Event::EndScrub).is_err());
        assert!(ev(Playing(FWD), Event::EndScrub).is_err());
        assert!(ev(Playing(FWD), Event::BeginWarm).is_err());
        assert!(ev(Scrubbing, Event::BeginWarm).is_err());
        assert!(ev(Paused, Event::EndWarm).is_err());
        assert!(ev(Playing(FWD), Event::EndWarm).is_err());
        assert!(ev(Scrubbing, Event::EndWarm).is_err());
    }

    #[test]
    fn rate_is_zero_unless_playing() {
        assert_eq!(Playing(FWD).rate(), FWD);
        for s in [Paused, Warming, Scrubbing] {
            assert!(s.rate().is_paused() && !s.is_playing());
        }
        assert!(Playing(FWD).is_busy() && Scrubbing.is_busy() && !Paused.is_busy());
    }

    #[test]
    fn compositor_slot_creates_once_and_failure_is_final() {
        let mut s: CompositorSlot<u8> = CompositorSlot::NotCreated;
        assert!(s.needs_creation() && s.take().is_none() && s.failure().is_none());
        assert!(s.settle(Err("no adapter".into())));
        assert_eq!(s.failure(), Some("no adapter"));
        assert!(!s.needs_creation() && s.take().is_none());
        assert!(!s.settle(Ok(1)), "a failed slot is not retried");
        assert_eq!(s.failure(), Some("no adapter"));
    }

    #[test]
    fn compositor_slot_hands_out_and_takes_back() {
        let mut s = CompositorSlot::NotCreated;
        assert!(!s.give_back(7u8), "nothing was taken");
        assert!(s.settle(Ok(7u8)));
        assert!(!s.settle(Ok(8)));
        assert_eq!(s.take(), Some(7));
        assert!(s.take().is_none(), "in use");
        assert!(!s.settle(Ok(9)));
        assert!(s.give_back(7));
        assert!(!s.give_back(7));
        assert_eq!(s.take(), Some(7));
    }
}
