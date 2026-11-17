//! The editing session (port of the Swift package `SQEditorSession`): one project with undo history, the active
//! sequence, playhead, selection, file state and the Program engine. Every edit goes through
//! [`EditorSession::perform`] (one undo step each); views pull state from `&EditorSession` every frame and key their
//! caches on [`EditorSession::version`]. Hooks of the Swift class are [`SessionEvent`]s the app drains.
//!
//! Layout: the skeleton (this file, `session`, `change`, `events`, `services`, `root`, `pending`) is fixed; each
//! `esNN_*` module belongs to one ES worker (see `TASKS.md`), who may add submodules under `src/esNN_*/` declared in
//! that module, never here. Type mapping rules: `CONVENTIONS.md`.

#[macro_use]
pub mod pending;

mod change;
mod events;
mod root;
mod services;
mod session;

pub mod es01_session_core;
pub mod es02_timeline_ops;
pub mod es03_fast_cut;
pub mod es04_effects;
pub mod es05_captions_titles;
pub mod es06_audio_analysis;
pub mod es07_project_panel;
pub mod es08_media;
pub mod es09_export;
pub mod es10_workspace;

pub use change::Change;
pub use events::SessionEvent;
pub use root::SessionRoot;
pub use services::{
    AnalysisBackend, BackgroundProxyJob, DetectedColor, EngineCall, MeterReading, PreviewSurface, ProgramEngine,
    ProgramFrameSampling, ProxyUse, RefOnlyMediaResolver, SessionMediaResolving, SessionProxyServing,
    SessionRenderCaching, StubProgramEngine,
};
pub use session::{
    ColorDetector, ConfirmFormatChange, CutPoint, EditorSession, MediaInfoProbe, PlayheadStep, PushedTimeline,
    SaveError, SessionDeps, SideStep,
};

pub use es01_session_core::*;
pub use es02_timeline_ops::*;
#[allow(unused_imports)] // ES3 has no public type yet
pub use es03_fast_cut::*;
pub use es04_effects::*;
pub use es05_captions_titles::*;
pub use es06_audio_analysis::*;
pub use es07_project_panel::*;
pub use es08_media::*;
pub use es09_export::*;
pub use es10_workspace::*;
