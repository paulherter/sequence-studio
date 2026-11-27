// Swift: WorkspacePackKind.swift
//! Workspace layouts as a `.sqpack` entry kind.

use sq_editor_session::Workspace;
use sq_library::favorites::LibraryStoreError;
use sq_library::preset_store::PresetFileError;
use sq_library::sqpack::{SQPackEntry, SQPackKindRegistry};
use std::sync::Arc;

/// Workspace layouts as a `.sqpack` entry kind. Not a PresetStore kind: workspaces live in the workspace store, so the
/// Library hands imported entries to the host (`LibraryModelEvent::ImportWorkspaces`).
pub enum WorkspacePackKind {}

impl WorkspacePackKind {
    /// The entry kind name.
    pub const KIND: &'static str = "workspace";
    /// The payload format version.
    pub const PAYLOAD_VERSION: i64 = 1;

    /// The pack entry of a workspace (the maximized panel is not saved).
    pub fn entry(workspace: &Workspace) -> Result<SQPackEntry, serde_json::Error> {
        let mut w = workspace.clone();
        w.maximized = None;
        Ok(SQPackEntry {
            kind: Self::KIND.to_string(),
            name: w.name.clone(),
            payload_version: Self::PAYLOAD_VERSION,
            payload: serde_json::to_vec(&w)?,
            assets: Vec::new(),
            folder: None,
        })
    }

    /// The validated workspace of an entry; none when the layout is unreadable or inconsistent.
    pub fn workspace(entry: &SQPackEntry) -> Option<Workspace> {
        if entry.kind != Self::KIND || entry.payload_version > Self::PAYLOAD_VERSION {
            return None;
        }
        let w: Workspace = serde_json::from_slice(&entry.payload).ok()?;
        w.validation_problems().is_empty().then_some(w)
    }

    /// Makes the registry accept workspace entries.
    pub fn register(registry: &mut SQPackKindRegistry) {
        registry.register(
            Self::KIND,
            Arc::new(|payload, version| {
                if version > Self::PAYLOAD_VERSION {
                    return Err(PresetFileError::Store(LibraryStoreError::NewerFormat {
                        found: version,
                        supported: Self::PAYLOAD_VERSION,
                    }));
                }
                match serde_json::from_slice::<Workspace>(payload) {
                    Ok(w) if w.validation_problems().is_empty() => Ok(()),
                    _ => Err(PresetFileError::DamagedPayload),
                }
            }),
        );
    }
}
