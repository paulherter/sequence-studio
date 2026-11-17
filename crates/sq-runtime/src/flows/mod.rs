#![allow(clippy::clone_on_ref_ptr)] // test doubles clone shared handles freely
//! Three real Swift flows ported 1:1 (logic only; UI replaced by test doubles).
//!  1. `host`:    ShellHost.confirmDiscardChanges / saveDocument / saveDocumentAs / presentError (modal asks, nested dialogs).
//!  2. `session`: EditorSession.write / save / saveAs / tickAutosave on ProjectSaveQueue (serial off-UI queue, race with project switch).
//!  3. `proxy`:   AutoProxyService settings debounce, busy polling, cancelable decision task + job stream.
mod host;
mod proxy;
mod session;
#[cfg(test)]
mod tests;

use std::sync::{Arc, Mutex};

/// Thread-safe event log; tests compare it to the order of events the Swift code produces.
#[derive(Clone, Default)]
pub(crate) struct Log(Arc<Mutex<Vec<String>>>);
impl Log {
    pub fn push(&self, s: impl Into<String>) {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).push(s.into());
    }
    pub fn items(&self) -> Vec<String> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}
