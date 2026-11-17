// Swift: ProxyTranscoding.swift (the async protocol is a blocking trait: PORTING section 9; `Task` cancellation is a
// `CancelToken` argument)
//! The transcoder seam of the proxy queue.

use crate::model::{ProxyDimensions, ProxyKind};
use sq_core_time::{Time, TimeRange};
use std::fmt;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

/// What a finished transcode reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct TranscodeOutput {
    /// Picture size of the written proxy.
    pub dimensions: ProxyDimensions,
    /// Duration of the source.
    pub source_duration: Time,
}

/// Shared flag a running job polls; clones share the flag.
#[derive(Clone, Debug, Default)]
pub struct CancelToken(Arc<AtomicBool>);

impl CancelToken {
    /// A token that is not cancelled.
    pub fn new() -> CancelToken {
        CancelToken::default()
    }

    /// Asks the job to stop.
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    /// Whether `cancel` was called.
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

/// Writes proxies. Implementations block; the driver of the queue runs them on a worker thread.
pub trait ProxyTranscoding: Send + Sync {
    /// Writes a proxy of `source` to `destination` (a `.partial` path; the caller moves it into place).
    /// Reports progress in 0...1. Must honor `cancel` (return `Cancelled`, and leave no file at `destination`).
    fn transcode(
        &self,
        source: &Path,
        kind: ProxyKind,
        destination: &Path,
        time_range: Option<TimeRange>,
        progress: &mut dyn FnMut(f64),
        cancel: &CancelToken,
    ) -> Result<TranscodeOutput, ProxyTranscodeError>;
}

/// Why a transcode or probe failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProxyTranscodeError {
    /// The file has no video track.
    NoVideoTrack,
    /// The media could not be read.
    ReaderFailed(String),
    /// The proxy could not be written.
    WriterFailed(String),
    /// A time range is not valid.
    InvalidTime(String),
    /// An interlaced source whose pictures could not be deinterlaced: no proxy is written rather than a woven one.
    DeinterlaceFailed,
    /// The job was canceled (Swift `CancellationError`).
    Cancelled,
}

/// English; the display sink translates (this crate cannot import the UI kit).
impl fmt::Display for ProxyTranscodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ProxyTranscodeError::NoVideoTrack => write!(f, "The file has no video track."),
            ProxyTranscodeError::ReaderFailed(s) => write!(f, "The media could not be read: {s}"),
            ProxyTranscodeError::WriterFailed(s) => write!(f, "The proxy could not be written: {s}"),
            ProxyTranscodeError::InvalidTime(s) => write!(f, "The time range is not valid: {s}"),
            ProxyTranscodeError::DeinterlaceFailed => {
                write!(f, "The interlaced pictures could not be deinterlaced, so no proxy was written.")
            }
            ProxyTranscodeError::Cancelled => write!(f, "The job was canceled."),
        }
    }
}

impl std::error::Error for ProxyTranscodeError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancel_token_clones_share_the_flag() {
        let a = CancelToken::new();
        let b = a.clone();
        assert!(!b.is_cancelled());
        a.cancel();
        assert!(b.is_cancelled());
    }

    #[test]
    fn errors_read_in_english() {
        assert_eq!(ProxyTranscodeError::NoVideoTrack.to_string(), "The file has no video track.");
        assert_eq!(ProxyTranscodeError::ReaderFailed("x".into()).to_string(), "The media could not be read: x");
    }
}
