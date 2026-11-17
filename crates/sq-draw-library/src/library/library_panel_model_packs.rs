// Swift: LibraryPanelModel+Packs.swift
//! `.sqpack` export and import of the Library (format and validation: `sq-library` `SQPackFormat`).
//!
//! shortcut: pack files are read and written on the UI thread (Swift: a detached task); upgrade when `sq-runtime` offers
//! background jobs.

use crate::library::library_panel_logic::LibraryError;
use crate::library::library_panel_model::{LibraryModelEvent, LibraryPanelModel, LibrarySection};
use crate::library::workspace_pack_kind::WorkspacePackKind;
use sq_core_time::Id;
use sq_library::library_search::{fold, numeric_compare};
use sq_library::sqpack::{
    SQPack, SQPackAsset, SQPackCaps, SQPackFormat, SQPackKindRegistry, SQPackManifest, SQPackReadResult,
};
use sq_library::sqpack_store::{SQPackAssetScanner, SQPackConflict, SQPackInstaller};
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};

/// What an import did, for the confirmation line.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LibraryPackImportSummary {
    /// The pack's name.
    pub pack_name: String,
    /// New presets.
    pub added: usize,
    /// Presets overwritten.
    pub replaced: usize,
    /// Pack presets dropped.
    pub skipped: usize,
    /// Workspace layouts handed to the host.
    pub workspaces: usize,
    /// LUTs and fonts installed.
    pub assets: usize,
    /// Entries of kinds made by a newer version of the app: left out.
    pub unreadable: usize,
}

impl LibraryPanelModel {
    /// The kinds this build can read: every preset kind plus workspaces. A later kind (multi-layer text templates)
    /// registers its validator here and needs no format change.
    pub fn pack_registry() -> SQPackKindRegistry {
        let mut r = SQPackKindRegistry::standard();
        WorkspacePackKind::register(&mut r);
        r
    }

    /// Names of the pack folders in the Library, sorted.
    pub fn pack_names(&self) -> Vec<String> {
        let set: BTreeSet<String> = self.presets().iter().filter_map(|p| p.pack.clone()).collect();
        let mut names: Vec<String> = set.into_iter().collect();
        names.sort_by(|a, b| numeric_compare(&fold(a), &fold(b)));
        names
    }

    /// The ids of the presets imported from one pack.
    pub fn preset_ids_in_pack(&self, name: &str) -> Vec<Id> {
        self.presets().iter().filter(|p| p.pack.as_deref() == Some(name)).map(|p| p.id).collect()
    }

    /// Writes the presets `ids` (and the LUTs their payloads name) as one pack.
    pub fn export_pack(&self, ids: &[Id], manifest: &SQPackManifest, url: &Path) -> Result<(), LibraryError> {
        let items: Vec<&sq_library::preset_store::PresetItem> =
            self.presets().iter().filter(|p| ids.contains(&p.id)).collect();
        let mut assets: Vec<SQPackAsset> = Vec::new();
        let mut refs: HashMap<Id, Vec<String>> = HashMap::new();
        for item in &items {
            for name in SQPackAssetScanner::lut_file_names(&item.payload) {
                let path = format!("luts/{name}");
                let Ok(data) = std::fs::read(self.lut_directory.join(&name)) else { continue };
                if !assets.iter().any(|a| a.path == path) {
                    assets.push(SQPackAsset::new(&path, data));
                }
                refs.entry(item.id).or_default().push(path);
            }
        }
        let item_ids: Vec<Id> = items.iter().map(|i| i.id).collect();
        let pack = self.preset_store.make_pack(&item_ids, manifest, assets, &refs)?;
        SQPackFormat::write(&pack, url, &Self::pack_registry())?;
        Ok(())
    }

    /// Reads and validates a pack file.
    pub fn read_pack(&self, url: &Path) -> Result<SQPackReadResult, LibraryError> {
        Ok(SQPackFormat::read(url, &SQPackCaps::default(), &Self::pack_registry())?)
    }

    /// Names in `pack` that already exist in its folder.
    pub fn pack_conflicts(&self, pack: &SQPack) -> Vec<String> {
        self.preset_store.conflicts(pack)
    }

    /// Installs LUTs and fonts, adds the presets in a folder named after the pack, hands workspaces to the host, and
    /// shows the new folder. Presets work right away (the Library reloads before this returns).
    pub fn import_pack(
        &mut self,
        read: &SQPackReadResult,
        conflict: SQPackConflict,
    ) -> Result<LibraryPackImportSummary, LibraryError> {
        let pack = &read.pack;
        let mut summary = LibraryPackImportSummary {
            pack_name: pack.manifest.name.clone(),
            unreadable: read.skipped.len(),
            ..Default::default()
        };
        let font_dir: PathBuf = self.support_directory.join("Packs").join(Self::safe_folder_name(&pack.manifest.name));
        let installed = SQPackInstaller::install(&pack.assets, &self.lut_directory, &font_dir)?;
        summary.assets = installed.luts.len() + installed.fonts.len();
        Self::register_fonts(&installed.fonts);
        let now = (self.clock)();
        let result = self.preset_store.import_pack(pack, conflict, &Self::pack_registry(), self.ids.as_mut(), now)?;
        summary.added = result.added.len();
        summary.replaced = result.replaced;
        summary.skipped = result.skipped;
        let workspaces: Vec<_> = result.deferred.iter().filter_map(WorkspacePackKind::workspace).collect();
        summary.workspaces = workspaces.len();
        if !workspaces.is_empty() {
            self.push_event(LibraryModelEvent::ImportWorkspaces(workspaces));
        }
        self.reload_presets();
        if self.pack_names().contains(&pack.manifest.name) {
            self.set_selection(LibrarySection::Pack(pack.manifest.name.clone()));
        }
        Ok(summary)
    }

    /// A pack name as a folder name: path separators and colons become dashes.
    pub fn safe_folder_name(name: &str) -> String {
        let t = name.trim();
        let s: String = t.chars().map(|c| if "/\\:".contains(c) { '-' } else { c }).collect();
        if s.is_empty() { "Pack".to_string() } else { s }
    }

    /// Makes pack fonts usable in this session (the fonts stay on disk; `register_installed_pack_fonts` re-registers them
    /// at launch).
    pub fn register_fonts(urls: &[PathBuf]) {
        if !urls.is_empty() {
            sq_text::portable_font_match::register_font_files(urls);
        }
    }

    /// At launch: registers the fonts of every imported pack.
    pub fn register_installed_pack_fonts(&self) {
        let root = self.support_directory.join("Packs");
        let mut fonts: Vec<PathBuf> = Vec::new();
        let mut stack = vec![root];
        while let Some(dir) = stack.pop() {
            let Ok(rd) = std::fs::read_dir(&dir) else { continue };
            for e in rd.flatten() {
                let p = e.path();
                if e.file_name().to_string_lossy().starts_with('.') {
                    continue;
                }
                if p.is_dir() {
                    stack.push(p);
                } else if p
                    .extension()
                    .is_some_and(|x| ["ttf", "otf"].contains(&x.to_string_lossy().to_lowercase().as_str()))
                {
                    fonts.push(p);
                }
            }
        }
        Self::register_fonts(&fonts);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pack_names_become_folder_names() {
        assert_eq!(LibraryPanelModel::safe_folder_name(" a/b\\c:d "), "a-b-c-d");
        assert_eq!(LibraryPanelModel::safe_folder_name("  "), "Pack");
    }

    #[test]
    fn the_registry_knows_the_preset_kinds_and_workspaces() {
        let r = LibraryPanelModel::pack_registry();
        assert!(r.knows("effect") && r.knows(WorkspacePackKind::KIND));
        assert!(!r.knows("hologram"));
    }

    #[test]
    fn registering_pack_fonts_makes_their_family_resolvable() {
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        let inter = sq_text::inter_font::font_urls(&root).into_iter().next().expect("inter file");
        let ps = sq_text::system_fonts::read_postscript(&inter).expect("postscript name");
        sq_text::portable_font_match::set_fonts_root(&root);
        let dir = std::env::temp_dir().join("sq-pack-launch-test").join("Packs").join("My Pack");
        std::fs::create_dir_all(&dir).expect("dir");
        std::fs::copy(&inter, dir.join("LaunchFace.otf.ttf")).expect("copy");
        LibraryPanelModel::register_fonts(&[dir.join("LaunchFace.otf.ttf")]);
        assert_eq!(
            sq_text::portable_font_match::PortableFontMatch::candidates(&ps),
            vec![dir.join("LaunchFace.otf.ttf")]
        );
    }
}
