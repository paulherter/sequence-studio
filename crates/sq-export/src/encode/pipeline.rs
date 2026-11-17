//! The frame pump: renders on its own thread, hands frames to the encoding thread through a bounded channel.

use crate::core::{CancelToken, ExportError, ExportFrame, FrameSource};
use std::sync::mpsc::sync_channel;

/// Frames between the renderer and the encoder: two queued plus the one being encoded.
pub const IN_FLIGHT: usize = 3;

/// Renders frames `0..frame_count` on a worker thread and calls `consume(index, frame)` here, in order. Cancel is
/// checked before every frame on both sides; the first error from either side ends the run.
pub(super) fn pump(
    video: &mut dyn FrameSource,
    cancel: &CancelToken,
    mut consume: impl FnMut(usize, ExportFrame) -> Result<(), ExportError>,
) -> Result<(), ExportError> {
    let n = video.frame_count();
    std::thread::scope(|scope| {
        let (tx, rx) = sync_channel::<Result<ExportFrame, ExportError>>(IN_FLIGHT - 1);
        scope.spawn(move || {
            for i in 0..n {
                if cancel.is_cancelled() {
                    break;
                }
                let frame = video.frame(i);
                let failed = frame.is_err();
                if tx.send(frame).is_err() || failed {
                    break;
                }
            }
        });
        for i in 0..n {
            cancel.check()?;
            match rx.recv() {
                Ok(frame) => consume(i, frame?)?,
                Err(_) => {
                    cancel.check()?;
                    return Err(ExportError::Other("the render thread stopped".to_string()));
                }
            }
        }
        Ok(())
    })
}
