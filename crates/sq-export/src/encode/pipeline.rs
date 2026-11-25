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
        // SQ_EXPORT_TRACE=1: how long the encoding side waited for a frame (render-bound) and how long it consumed them.
        let trace = std::env::var_os("SQ_EXPORT_TRACE").is_some();
        let (mut waited, mut consumed) = (std::time::Duration::ZERO, std::time::Duration::ZERO);
        for i in 0..n {
            cancel.check()?;
            let t0 = std::time::Instant::now();
            let got = rx.recv();
            waited += t0.elapsed();
            match got {
                Ok(frame) => {
                    let t1 = std::time::Instant::now();
                    consume(i, frame?)?;
                    consumed += t1.elapsed();
                }
                Err(_) => {
                    cancel.check()?;
                    return Err(ExportError::Other("the render thread stopped".to_string()));
                }
            }
        }
        if trace {
            eprintln!(
                "export-trace encode side: {n} frames, waited for a frame {:.0} ms, consumed (convert+encode+audio) {:.0} ms",
                waited.as_secs_f64() * 1e3,
                consumed.as_secs_f64() * 1e3
            );
        }
        Ok(())
    })
}
