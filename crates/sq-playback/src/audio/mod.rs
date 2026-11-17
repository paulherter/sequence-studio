// SPDX-License-Identifier: GPL-3.0-or-later
//! Audio of the playback engine: the block mixer (`AudioFeeder`), retiming, scrub grains, shuttle stretch, monitoring
//! stages, the timeline meter and the dialogue-pause detector for live ducking. Output, ring and clock live in
//! `sq-audio-out`.

mod feeder;
mod retimer;
mod scrub;
mod shuttle_stretch;
mod silences;
mod stages;
mod time_map;
mod track_mix;

pub use feeder::{AudioFeeder, FeederHandle, Resolver, SAMPLE_RATE, SharedSilences, ceil_frame, round_frame};
pub use retimer::{AudioRetimer, ConstantRetime, RetimeSpan};
pub use scrub::{ScrubAudio, ScrubGrain, ScrubGrainPlanner, ScrubSettings, ScrubVoice};
pub use shuttle_stretch::ShuttleStretch;
pub use silences::WaveformSilences;
pub use stages::{
    AudioMeterLevel, AudioMeterSnapshot, AudioMeterStore, ChannelMonitorStage, LoudnessLevels, MeterDrain, MeterTap,
    MeterThread, MonitorGainStage,
};
pub use time_map::AudioTimeMap;
pub use track_mix::{AUDIO_TAGS, Sequences};
