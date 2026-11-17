//! Port of `ProjectFile+V24.swift` (logic only; saved types live in `sq-core-model`).

use sq_core_model::{ClipEffect, Project};
use sq_core_time::IdSource;

/// Runs `ClipEffect::upgrading_legacy_shadow_color` on every effect of every clip (Swift `Project.migrateLegacyShadowColor`).
/// New key ids come from `ids`. True when anything changed.
pub fn migrate_legacy_shadow_color(project: &mut Project, ids: &mut dyn IdSource) -> bool {
    let mut changed = false;
    for timeline in project.timelines.iter_mut() {
        for track in timeline.tracks.iter_mut() {
            let upgraded: Vec<_> = track
                .clips()
                .iter()
                .filter(|c| c.effects.iter().any(ClipEffect::has_legacy_shadow_color))
                .map(|c| {
                    let mut n = c.clone();
                    n.effects = c.effects.iter().map(|e| e.upgrading_legacy_shadow_color(ids)).collect();
                    n
                })
                .collect();
            changed |= !upgraded.is_empty();
            for n in upgraded {
                track.replace(n);
            }
        }
    }
    changed
}
