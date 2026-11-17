//! The app root of the shared draw UI (Swift `SQAppShell` plus the portable part of the Windows `AppController`):
//! [`App`] owns the editing session, the platform services and the panel hosts; the platform traits are the seams the
//! binary and the platform crates implement; [`Headless`] runs the frame loop without a window.
//! Design: docs/rust/session-ui-design.md sections 1, 2 and 4 (task K3).

mod app;
mod app_platform;
mod headless;
mod host;

pub use app::{App, AppDeps, AppMessage, AppServices, HostId};
pub use app_platform::{
    AppMagicMasks, AppMonitorBackend, AppMonitorEngine, AppPicture, AppPictureSource, AppPlatform, AppPointer,
    AppPointerFacts, AppPointerShape, AppScreenSampler, LUTFileTypes, MaskTintImage, MaskTintPicture, PanelFileChooser,
};
pub use headless::{CancelAllFiles, Headless, TurnTimes, file_pickers_cancelled, take_phases, timed};
pub use host::{A11yAction, ATLAS_SIZE, ATLAS_SLOT, AppEvent, AppHost, HostCx, ImageUpload};
pub use sq_draw_shell::{ShellFilePicker, answered};

#[cfg(test)]
mod hover_scroll_tests;
#[cfg(test)]
mod tests;
