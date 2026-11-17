// SPDX-License-Identifier: GPL-3.0-or-later
//! Playback clocks: the manual and host clocks, the audio master clock over any `AudioPlaying` output, the switching
//! clock with its host fallback, and the delay-locked loop that smooths callback time stamps.

mod audio_clock;
mod audio_playing;
mod playback_clock;
mod smoothing;

pub use audio_clock::{AudioClock, SwitchingClock};
pub use audio_playing::{AudioPlaying, AudioRenderStamp, Flushed, ManualAudio, RestartHandler, Unavailable};
pub use playback_clock::{HostClock, ManualClock, PlaybackClock, host_nanos_now, rounded, scaled};
pub use smoothing::StampSmoother;

use std::sync::{Mutex, MutexGuard, PoisonError};

/// Locks `m`, ignoring poisoning (a panicking holder leaves plain data behind; the clock keeps working).
pub(crate) fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests;
