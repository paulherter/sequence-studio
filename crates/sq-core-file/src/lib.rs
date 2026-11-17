// SPDX-License-Identifier: GPL-3.0-or-later
//! `.sqproj` reader and writer over `sq_core_model::Project` (Swift: `ProjectFile.swift`, `ProjectFile+V19 ... V94`,
//! `ProjectFile+Salvage.swift`).
//!
//! A project is a package folder `Name.sqproj/` with `project.json` and `Autosave/`, or one plain file. The JSON is the
//! envelope `{appFormat, formatVersion, project}`. `formatVersion` is the lowest version that can hold the project's
//! content (`written_version`), so an older build keeps opening a file that needs nothing newer and refuses one that
//! does. Older files run through `migrations` on read; a file that does not decode as a whole can be opened by
//! `read_salvaging`.
//!
//! Version history (what each v25...v94 added) is in the doc comments of Swift `ProjectFile.currentVersion` and of the
//! gates in `gates.rs`; a Rust change never bumps `CURRENT_VERSION`.

mod error;
mod extras;
mod files;
mod fixups;
mod gates;
mod id_repair;
mod migrations;
mod salvage;
mod variant_repair;

pub use error::ProjectFileError;
pub use files::{
    AUTOSAVE_DIR, FILE_NAME, NEW_PROJECTS_ARE_FILES, converted_path, document_file, is_legacy_path, is_project_path,
    is_single_file,
};
pub use fixups::{NoFixups, ProjectFixups};
pub use migrations::{JsonObject, MigrationStep, Migrations, migrate_v1_to_v2, migrate_v33_to_v34};
pub use salvage::ProjectSalvageReport;

use serde::Deserialize;
use serde_json::{Map, Value};
use sq_core_color::ProjectGradeLinksExt;
use sq_core_model::Project;
use sq_core_time::EncodeContext;

/// The newest format version this build reads and the version it stamps in `appFormat`.
pub const CURRENT_VERSION: i64 = 94;

/// The project file extension. Older builds wrote `LEGACY_FILE_EXTENSIONS`; those still open.
pub const FILE_EXTENSION: &str = "sqproj";
/// Extensions of older builds.
pub const LEGACY_FILE_EXTENSIONS: &[&str] = &["ssproj"];

/// Every migration step from this version on is identity (formats since v34 only add fields optional on decode), so a file
/// at this version or later decodes straight from its bytes. A real migration at or after it must raise this.
pub const IDENTITY_MIGRATIONS_FROM: i64 = 34;

/// The version that introduced Hold Ahead keys. Not part of `written_version`: the keys say so while they are written.
const V77: i64 = 77;
/// Perspective tilt (flag-gated like Hold Ahead).
const V84: i64 = 84;
/// Per-edge Follow padding (flag-gated like Hold Ahead).
const V85: i64 = 85;

/// The reader and writer. It holds the `ProjectFixups` of the build. The app builds it with `sq_core_project::project_file()`
/// (the real fixups); `without_fixups()` is for this crate's own tests, because a file written or opened without them keeps
/// unused groups and skips the v10 and v24 migrations.
pub struct ProjectFile<'a> {
    pub(crate) fixups: &'a dyn ProjectFixups,
}

impl ProjectFile<'static> {
    /// A reader and writer without fixups (`NoFixups`). There is no `new()` or `Default` on purpose: every caller states
    /// that it does without the project logic, so the app cannot pick it by accident.
    pub fn without_fixups() -> ProjectFile<'static> {
        ProjectFile { fixups: &NoFixups }
    }
}

impl<'a> ProjectFile<'a> {
    /// A reader and writer that call `fixups` where Swift calls into higher-level project logic.
    pub fn with_fixups(fixups: &'a dyn ProjectFixups) -> ProjectFile<'a> {
        ProjectFile { fixups }
    }

    /// The version a project is written with: the lowest one that can hold its content. v36 is the floor. Hold Ahead keys,
    /// tilt and Follow edge padding raise it further while the project is encoded (`encode`).
    pub fn written_version(project: &Project) -> i64 {
        gates::GATES.iter().find(|(_, holds)| holds(project)).map_or(gates::FLOOR_VERSION, |(v, _)| *v)
    }

    /// The project as a JSON value, the way the project file encoder writes it (compact keyframes, versions recorded in
    /// the open `EncodeContext`).
    pub(crate) fn project_value(&self, project: &Project) -> Option<Value> {
        sq_core_time::json_sorted::to_value(project).ok()
    }

    /// A project from a JSON value (Swift: `decoder().decode(Project.self, ...)` after `JSONSerialization`).
    pub(crate) fn decode_project(&self, value: &Value) -> Option<Project> {
        Project::deserialize(value).ok()
    }

    /// Media and LUT paths in the stored form (plain, `/` separators; see `sq_os::paths`). Files written on Windows by an
    /// earlier build hold `//?/C:/...`, the verbatim spelling `canonicalize` returns, which the shell does not open.
    /// Nothing is touched (and nothing copied) when every path is already plain.
    pub(crate) fn plain_paths(project: &mut Project) {
        let plain = |text: &str| sq_os::paths::stored_form(text) == text;
        if !project.media.iter().all(|m| plain(&m.path)) {
            for m in project.media.iter_mut() {
                m.path = sq_os::paths::stored_form(&m.path);
            }
        }
        if !project.referenced_lut_files().iter().all(|p| plain(p)) {
            project.replace_lut_paths(|p| Some(sq_os::paths::stored_form(p)));
        }
    }

    /// The project's own JSON and what the encoder saw while writing it (versions recorded in the open `EncodeContext`).
    fn encode_value(p: &Project) -> (Result<Value, ProjectFileError>, sq_core_time::SeenFlags) {
        let scope = EncodeContext::project_file();
        let encoded = sq_core_time::json_sorted::to_value(p).map_err(|e| ProjectFileError::Encode(e.to_string()));
        let seen = scope.seen();
        drop(scope);
        (encoded, seen)
    }

    /// Records what the file holds beyond the model: the keys next to `project` and, at every level, the keys the model
    /// has no field for (`extras`).
    pub(crate) fn adopt_file_keys(project: &mut Project, envelope: &Map<String, Value>, file_project: &Value) {
        project.file_unknown =
            sq_core_model::UnknownKeys::from_object_except(envelope, &["appFormat", "formatVersion", "project"]);
        let written = Self::encode_value(project).0.ok();
        let extras = written.and_then(|w| extras::diff(file_project, &w));
        project.file_extras = sq_core_model::FileExtras(extras.map(std::sync::Arc::new));
    }

    /// The file contents of `project`: pretty printed, keys sorted.
    pub fn encode(&self, project: &Project) -> Result<Vec<u8>, ProjectFileError> {
        let mut p = project.clone();
        Self::plain_paths(&mut p);
        self.fixups.prune_unused_groups(&mut p); // W7.6: no hidden group sequence outlives the clips that played it
        let version = Self::written_version(&p);
        let (encoded, seen) = Self::encode_value(&p);
        // The project is encoded first: its keys mark a Hold Ahead, a tilt or an edge padding while they are written.
        let base = if seen.hold_ahead { version.max(V77) } else { version };
        let v84 = if seen.tilt { base.max(V84) } else { base };
        let format_version = if seen.follow_edge_padding { v84.max(V85) } else { v84 };
        let mut encoded = encoded?;
        whole_numbers_as_integers(&mut encoded);
        // Keys the file had at any level that the model has no field for go back where they were.
        if let Some(extras) = p.file_extras.0.as_deref() {
            extras::apply(&mut encoded, extras);
        }
        let mut envelope = serde_json::Map::new();
        // Keys a newer build wrote next to `project` stay (the three the file always owns are not replaced).
        p.file_unknown.put_into(&mut envelope);
        envelope.insert("appFormat".to_string(), CURRENT_VERSION.into());
        envelope.insert("formatVersion".to_string(), format_version.into());
        envelope.insert("project".to_string(), encoded);
        serde_json::to_vec_pretty(&Value::Object(envelope)).map_err(|e| ProjectFileError::Encode(e.to_string()))
    }

    /// Decodes file contents, running migrations from older versions. `None` = the standard chain (`migrations`), which
    /// lets a file needing no real migration skip the JSON rewrite.
    pub fn decode(&self, data: &[u8], migrations: Option<&Migrations<'_>>) -> Result<Project, ProjectFileError> {
        let Ok(Value::Object(mut obj)) = serde_json::from_slice::<Value>(data) else {
            return Err(ProjectFileError::Corrupt);
        };
        let Some(mut version) = obj.get("formatVersion").and_then(Value::as_i64) else {
            return Err(ProjectFileError::Corrupt);
        };
        if !obj.contains_key("project") {
            return Err(ProjectFileError::Corrupt);
        }
        if version > CURRENT_VERSION {
            return Err(ProjectFileError::NewerVersion { found: version, supported: CURRENT_VERSION });
        }
        let skip_steps = migrations.is_none() && version >= IDENTITY_MIGRATIONS_FROM;
        if !skip_steps {
            let standard;
            let steps = match migrations {
                Some(m) => m,
                None => {
                    standard = self.migrations();
                    &standard
                }
            };
            while version < CURRENT_VERSION {
                let step = steps.get(&version).ok_or(ProjectFileError::Corrupt)?;
                obj = step(obj)?;
                version += 1;
            }
        }
        // A project that is not an object (`"project": 5`) does not decode either.
        let mut file_project = obj.get("project").cloned().unwrap_or(Value::Null);
        // Ids that older builds handed out twice are made unique before the project decodes (see `id_repair`).
        id_repair::repair_duplicate_ids(&mut file_project);
        let mut project = self.decode_project(&file_project).ok_or(ProjectFileError::Corrupt)?;
        Self::plain_paths(&mut project);
        Self::adopt_file_keys(&mut project, &obj, &file_project);
        Ok(project)
    }
}

/// Foundation writes a whole `Double` such as 48.0 as `48`; serde_json writes `48.0`. Both read back as the same number, but
/// the written content then equals Swift's. Only exact whole values below 2^53 change; `-0.0` keeps its sign.
fn whole_numbers_as_integers(v: &mut Value) {
    match v {
        Value::Number(n) => {
            if let Some(f) = n.as_f64().filter(|f| n.is_f64() && f.fract() == 0.0 && f.abs() < 9_007_199_254_740_992.0)
                && (f != 0.0 || f.is_sign_positive())
            {
                *v = Value::from(f as i64);
            }
        }
        Value::Array(a) => a.iter_mut().for_each(whole_numbers_as_integers),
        Value::Object(o) => o.values_mut().for_each(whole_numbers_as_integers),
        _ => {}
    }
}

#[cfg(test)]
mod tests;

#[cfg(test)]
mod variant_repair_tests;
