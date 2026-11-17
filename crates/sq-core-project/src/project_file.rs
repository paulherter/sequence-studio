//! Port of `ProjectFile.swift` (logic only; saved types live in `sq-core-model`).
//!
//! `sq-core-file` reads and writes the file but calls project logic that lives in higher crates (the Swift file calls
//! `Project` methods directly). `ProjectLogic` is that logic, and `project_file()` is the one way the app builds a reader
//! and writer: every open and save goes through it, so a Swift-era project gets its v10 Scale, v24 shadow color and v26
//! override steps, and a save drops groups nothing plays.

use sq_core_edit::grouping::ProjectGroupingExt;
use sq_core_file::{ProjectFile, ProjectFixups};
use sq_core_graphics::format_variants_view::ProjectVariantsExt;
use sq_core_model::Project;
use sq_core_time::RandomIds;

/// The project logic `sq-core-file` calls while it opens and saves a file.
#[derive(Clone, Copy, Debug, Default)]
pub struct ProjectLogic;

impl ProjectFixups for ProjectLogic {
    fn prune_unused_groups(&self, project: &mut Project) {
        ProjectGroupingExt::prune_unused_groups(project);
    }

    fn prune_variant_overrides(&self, project: &mut Project) -> bool {
        ProjectVariantsExt::prune_variant_overrides(project)
    }

    fn migrate_scale_to_source_pixels(&self, project: &mut Project) {
        project.migrate_scale_to_source_pixels();
    }

    fn migrate_legacy_shadow_color(&self, project: &mut Project) -> bool {
        crate::project_file_v24::migrate_legacy_shadow_color(project, &mut RandomIds)
    }
}

/// The reader and writer of the app: `sq-core-file` with the real project logic.
pub fn project_file() -> ProjectFile<'static> {
    ProjectFile::with_fixups(&ProjectLogic)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use sq_core_model::{
        AnimatedProperty, Clip, ClipEffect, MediaFingerprint, MediaRef, SequenceFormat, Timeline, TimelineGroup, Track,
        TrackKind, VariantOverride, VariantOverrides,
    };
    use sq_core_time::{Id, Time, TimeRange, Vec2};

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    /// A 4K media in a 1080p sequence (fit scale 0.5) with one clip whose Scale is `scale`.
    fn project(scale: f64, effects: Vec<ClipEffect>) -> Project {
        let mut m = MediaRef::new(id(100), "m", "/x/m.mov", MediaFingerprint::new(1));
        m.duration = Some(Time::new(10, 1));
        m.info = serde_json::from_value(json!({"duration": {"value": 10, "timescale": 1}, "video": {
            "width": 3840, "height": 2160, "codec": "hvc1", "bitDepth": 10, "chroma": "4:2:0",
            "nominalFrameDuration": {"value": 1, "timescale": 30}, "isVariableFrameRate": false, "rotation": 0}}))
        .ok();
        let mut c =
            Clip::new(id(1), "c", m.id, TrackKind::Video, TimeRange::new(Time::ZERO, Time::new(5, 1)), Time::ZERO);
        c.animation.scale = AnimatedProperty::new(Vec2::new(scale, scale));
        c.effects = effects;
        let mut track = Track::new(id(9), TrackKind::Video);
        track.set_clips(vec![c]);
        let mut format = SequenceFormat::new(Time::new(1, 30));
        (format.width, format.height) = (1920, 1080);
        Project::new(id(7), "p", vec![m], vec![Timeline::new(id(8), "Main", format, vec![track])])
    }

    /// A file of an older build: `project` as JSON, stamped with `version`.
    fn old_file(project: &Project, version: i64) -> Vec<u8> {
        let bytes = ProjectFile::without_fixups().encode(project).expect("encodes");
        let mut v: Value = serde_json::from_slice(&bytes).expect("json");
        v["formatVersion"] = json!(version);
        serde_json::to_vec(&v).expect("bytes")
    }

    fn first_clip(p: &Project) -> Clip {
        p.timelines[0].tracks[0].clips()[0].clone()
    }

    #[test]
    fn a_v9_file_opens_with_its_scale_relative_to_the_source_pixels() {
        let bytes = old_file(&project(1.0, vec![]), 9);
        let plain = ProjectFile::without_fixups().decode(&bytes, None).expect("decodes");
        assert_eq!(first_clip(&plain).animation.scale.value, Vec2::new(1.0, 1.0), "no fixups: nothing converted");
        let opened = project_file().decode(&bytes, None).expect("decodes");
        assert_eq!(
            first_clip(&opened).animation.scale.value,
            Vec2::new(0.5, 0.5),
            "100 % fit = 50 % of the 4K picture"
        );
    }

    #[test]
    fn a_v23_file_opens_with_its_drop_shadow_color_as_one_parameter() {
        let mut shadow = ClipEffect::new(id(30), ClipEffect::DROP_SHADOW_KIND);
        shadow.parameters.insert(ClipEffect::SHADOW_RED_KEY.into(), AnimatedProperty::new(255.0));
        shadow.parameters.insert(ClipEffect::SHADOW_GREEN_KEY.into(), AnimatedProperty::new(51.0));
        let bytes = old_file(&project(0.5, vec![shadow]), 23);
        let plain = ProjectFile::without_fixups().decode(&bytes, None).expect("decodes");
        assert!(first_clip(&plain).effects[0].has_legacy_shadow_color());
        let opened = project_file().decode(&bytes, None).expect("decodes");
        let e = &first_clip(&opened).effects[0];
        assert!(!e.has_legacy_shadow_color());
        let c = e.colors[ClipEffect::SHADOW_COLOR_KEY].value;
        assert!((c.red, c.green, c.blue, c.alpha) == (1.0, 0.2, 0.0, 1.0), "{c:?}");
    }

    #[test]
    fn a_v25_file_opens_without_overrides_of_variants_that_do_not_exist() {
        let mut p = project(0.5, vec![]);
        let o =
            VariantOverride { scale: Some(AnimatedProperty::new(Vec2::new(2.0, 2.0))), ..VariantOverride::default() };
        let mut c = first_clip(&p);
        c.variant_store = Some(VariantOverrides { items: [(id(60), o)].into() });
        p.timelines[0].tracks[0].replace(c);
        let bytes = old_file(&p, 25);
        let plain = ProjectFile::without_fixups().decode(&bytes, None).expect("decodes");
        assert!(first_clip(&plain).variant_store.is_some_and(|v| !v.items.is_empty()));
        let opened = project_file().decode(&bytes, None).expect("decodes");
        assert!(first_clip(&opened).variant_store.is_none_or(|v| v.items.is_empty()));
    }

    #[test]
    fn a_save_drops_groups_no_clip_plays_and_keeps_the_rest() {
        let mut p = project(0.5, vec![]);
        let mut unused = Timeline::new(id(40), "Group", p.timelines[0].format.clone(), vec![]);
        unused.group = Some(TimelineGroup { source_tracks: Default::default() });
        p.timelines.push(unused);
        let read = |pf: ProjectFile| pf.decode(&pf.encode(&p).expect("encodes"), None).expect("decodes");
        assert_eq!(read(ProjectFile::without_fixups()).timelines.len(), 2, "no fixups: the group stays");
        let saved = read(project_file());
        assert_eq!(saved.timelines.iter().map(|t| t.id).collect::<Vec<_>>(), vec![id(8)]);
        assert_eq!(first_clip(&saved).animation.scale.value, Vec2::new(0.5, 0.5), "a current file means what it did");
    }
}
