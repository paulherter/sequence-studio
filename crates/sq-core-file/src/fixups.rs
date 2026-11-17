// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ProjectFile.swift, ProjectFile+V24.swift (calls into logic that lives in higher crates)

use sq_core_model::Project;

/// Project logic the file code calls but a higher `sq-core-*` crate owns. Every method defaults to "nothing to do", which is
/// right for a file without the content in question; `sq-core-project` implements the real thing.
pub trait ProjectFixups {
    /// W7.6: no hidden group sequence outlives the clips that played it (Swift `Project.pruneUnusedGroups`). Runs before
    /// every encode.
    fn prune_unused_groups(&self, _project: &mut Project) {}

    /// v26 step: drops overrides of variants and effects that do not exist (Swift `Project.pruneVariantOverrides`). True when
    /// anything changed.
    fn prune_variant_overrides(&self, _project: &mut Project) -> bool {
        false
    }

    /// v10 step: multiplies every picture clip's Scale by its fit scale (Swift `Project.migrateScaleToSourcePixels`).
    fn migrate_scale_to_source_pixels(&self, _project: &mut Project) {}

    /// v24 step: folds Drop Shadow's three channel parameters into the color parameter (Swift `Project.migrateLegacyShadowColor`).
    /// True when anything changed. Mints key ids for sampled keys, so it cannot live here.
    fn migrate_legacy_shadow_color(&self, _project: &mut Project) -> bool {
        false
    }
}

/// The fixups of a build that has none: every method does nothing.
#[derive(Clone, Copy, Debug, Default)]
pub struct NoFixups;

impl ProjectFixups for NoFixups {}
