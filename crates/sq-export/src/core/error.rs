// Swift: ExportEncoding.swift (ExportError, ExportDecodeError), FrameSource.swift (FrameSourceError)

use super::settings::ExportSettingsIssue;
use sq_core_time::{Id, Time};
use std::collections::BTreeSet;
use std::fmt;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// Cooperative cancellation (Swift `Task` cancellation): cloned to the thread that may cancel, polled by the worker
/// at every chunk and frame. Cancelling twice is harmless.
// shortcut: local to sq-export until a shared token lands in sq-media; replace with it then (same two methods).
#[derive(Clone, Debug, Default)]
pub struct CancelToken(Arc<AtomicBool>);

impl CancelToken {
    /// A token that is not cancelled.
    pub fn new() -> CancelToken {
        CancelToken::default()
    }

    /// Asks the worker to stop.
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }

    /// Whether `cancel` was called on any clone.
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }

    /// Swift `Task.checkCancellation()`.
    pub fn check(&self) -> Result<(), ExportError> {
        if self.is_cancelled() { Err(ExportError::Cancelled) } else { Ok(()) }
    }
}

/// Everything an export can fail with. Display is the English text (the display sink translates it).
#[derive(Clone, Debug, PartialEq)]
pub enum ExportError {
    /// The settings did not validate.
    InvalidSettings(BTreeSet<ExportSettingsIssue>),
    /// The video encoder does not accept the settings.
    CannotAddVideoInput,
    /// The audio encoder does not accept the settings.
    CannotAddAudioInput,
    /// The file could not be written.
    WriterFailed(String),
    /// Nothing to export.
    EmptySource,
    /// Loudness normalization is on but the audio source cannot be read twice.
    LoudnessNeedsRewindableSource,
    /// An audio-only export of a sequence without audio.
    NoAudio,
    /// Hardware encoding was asked for, the machine has a hardware encoder for the codec, yet the session fell back to software.
    HardwareEncoderUnavailable(String),
    /// No encoder of the chosen codec (or depth) opens on this computer. The export stops instead of writing another
    /// codec or profile; the text says what is missing and what to choose instead.
    NoEncoder(String),
    /// A source frame could not be decoded and damaged frames are not tolerated.
    Decode(ExportDecodeError),
    /// The operating system reported a full disk (ENOSPC and its Windows equivalents).
    DiskFull,
    /// The task was cancelled (Swift `CancellationError`).
    Cancelled,
    /// Any other failure, with its text.
    Other(String),
}

impl ExportError {
    /// Maps an I/O error: a full disk becomes `DiskFull`, the rest `Other`.
    pub fn from_io(e: &std::io::Error) -> ExportError {
        // 28 = ENOSPC (unix); 112 = ERROR_DISK_FULL and 39 = ERROR_HANDLE_DISK_FULL (Windows).
        if matches!(e.raw_os_error(), Some(28 | 112 | 39)) || e.kind() == std::io::ErrorKind::StorageFull {
            ExportError::DiskFull
        } else {
            ExportError::Other(e.to_string())
        }
    }
}

impl fmt::Display for ExportError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ExportError::InvalidSettings(_) => f.write_str("The export settings are not valid."),
            ExportError::CannotAddVideoInput => f.write_str("The video encoder does not accept these settings."),
            ExportError::CannotAddAudioInput => f.write_str("The audio encoder does not accept these settings."),
            ExportError::WriterFailed(why) => write!(f, "The file could not be written: {why}"),
            ExportError::EmptySource => f.write_str("There is nothing to export."),
            ExportError::LoudnessNeedsRewindableSource => {
                f.write_str("Loudness normalization needs an audio source that can be read twice.")
            }
            ExportError::NoAudio => f.write_str("This sequence has no audio to export."),
            ExportError::HardwareEncoderUnavailable(why) | ExportError::NoEncoder(why) | ExportError::Other(why) => {
                f.write_str(why)
            }
            ExportError::Decode(d) => fmt::Display::fmt(d, f),
            ExportError::DiskFull => f.write_str("The disk is full."),
            ExportError::Cancelled => f.write_str("cancelled"),
        }
    }
}

impl std::error::Error for ExportError {}

/// A source frame of a clip could not be decoded and "Continue on damaged frames" is off: the export stops here.
#[derive(Clone, Debug, PartialEq)]
pub struct ExportDecodeError {
    /// The clip.
    pub clip: Id,
    /// Its name.
    pub clip_name: String,
    /// Sequence time of the output frame.
    pub time: Time,
    /// Timecode of `time` (HH:MM:SS:FF at the sequence frame rate).
    pub timecode: String,
    /// Why decoding failed.
    pub reason: String,
}

impl fmt::Display for ExportDecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "Clip \u{201C}{}\u{201D} could not be decoded at {} ({}). Replace or re-encode the media, or turn on \
             \u{201C}Continue on damaged frames\u{201D} to export with a placeholder for those frames.",
            self.clip_name, self.timecode, self.reason
        )
    }
}

impl std::error::Error for ExportDecodeError {}

impl ExportDecodeError {
    /// Non-drop HH:MM:SS:FF of `t` at `frame_duration` (nominal integer rate).
    pub fn timecode(t: Time, frame_duration: Time) -> String {
        let f = t.frame_index(frame_duration).max(0);
        let fps = ((frame_duration.timescale() + frame_duration.value() / 2) / frame_duration.value().max(1)).max(1);
        let s = f / fps;
        format!("{:02}:{:02}:{:02}:{:02}", s / 3600, s / 60 % 60, s % 60, f % fps)
    }
}

/// Why a frame could not be handed out.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FrameSourceError {
    /// The index is past the last frame.
    IndexOutOfRange(usize),
    /// A pixel buffer could not be created (platform status code).
    BufferCreationFailed(i32),
}

impl fmt::Display for FrameSourceError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FrameSourceError::IndexOutOfRange(i) => write!(f, "frame {i} is out of range"),
            FrameSourceError::BufferCreationFailed(s) => write!(f, "frame buffer could not be created ({s})"),
        }
    }
}

impl std::error::Error for FrameSourceError {}

impl From<FrameSourceError> for ExportError {
    fn from(e: FrameSourceError) -> ExportError {
        ExportError::Other(e.to_string())
    }
}
