//! The ported analysis connected to the panels: the monitor eyedropper, the Stabilizer re-plan cache and the Magic Mask
//! tracking job.

pub mod analysis;
pub mod analysis_services;
pub mod anonymize_runner;
pub mod anonymizer;
pub mod audio_services;
pub mod eyedropper;
pub mod ffmpeg_frames;
pub mod magic_flow;
pub mod magic_job;
pub mod mask_eval;
pub mod mask_track;
pub mod matte_tint;
pub mod pacing;
pub mod picture_sampler;
pub mod scene_changes;
pub mod stabilization_analyzer;
pub mod stabilization_store;
pub mod stabilize_runner;
pub mod subject_detection;
