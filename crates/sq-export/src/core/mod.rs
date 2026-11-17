//! Portable export core: settings, presets, queue, loudness, stems, delivery checks, the encoder/source traits.
//! Design: docs/rust/render-playback-export-design.md section 1. Interchange and text writers are in `formats`, the
//! encode pipeline in `encode`.
//!
//! Deviations from the Swift package (all deliberate):
//! - `async` reads are blocking calls on traits taking `&mut self` and a `CancelToken` (design section 2).
//! - `ExportQueue` is a clonable handle over one mutex-guarded state machine; `run_all` blocks the export thread.
//!   Sidecar captions and cover stills go through `SidecarWriting` / `CoverWriting`, implemented by `formats` / `encode`.
//! - `SrtCue` lives here (the queue carries cues); `formats` should re-export it for its writers.
//! - Not ported: smart render (`SmartRenderEligibility`, dropped by the design), `OutputAudioVerifier` (now `encode::measure_output_audio`, FFmpeg),
//!   the Swift parity tests that need the playback `AudioFeeder` (they return with `TimelineAudioSource`'s feeder).
//! - `ExportMetadata::from_markers` (needs `YouTubeChapters`) belongs with the text writers in `formats`.

pub mod audio_delivery;
pub mod delivery;
pub mod encoder_support;
pub mod error;
pub mod frame_output;
pub mod gif_palette;
pub mod hdr;
pub mod loudness;
pub mod metadata;
pub mod platform_spec;
pub mod prefetch;
pub mod preflight;
pub mod preset;
pub mod progress;
pub mod queue;
pub mod queue_state;
pub mod render_cache;
pub mod serde_util;
pub mod settings;
pub mod stems;
pub mod still_pixels;
pub mod timeline_audio;
pub mod traits;

pub use audio_delivery::*;
pub use delivery::*;
pub use error::*;
pub use frame_output::*;
pub use gif_palette::*;
pub use hdr::*;
pub use loudness::*;
pub use metadata::*;
pub use platform_spec::*;
pub use prefetch::*;
pub use preflight::*;
pub use preset::*;
pub use progress::*;
pub use queue::*;
pub use queue_state::*;
pub use settings::*;
pub use stems::*;
pub use still_pixels::*;
pub use timeline_audio::*;
pub use traits::*;

#[cfg(test)]
mod tests;
