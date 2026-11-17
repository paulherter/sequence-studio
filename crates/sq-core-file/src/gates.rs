// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ProjectFile.swift (`writtenVersion`), the `contains...` gates of ProjectFile+V56 ... V94 and of the feature files
//
// A file is written with the lowest version that can hold its content, so older builds keep opening it and a build that
// would lose the content on save refuses the file instead. Each gate below answers "does this project hold content that
// needs version N". They read the model's public fields; names of effect kinds and parameter keys are the stored strings.

use sq_core_model::{
    BlendMode, Clip, ClipEffect, ClipMask, ColorSpaceID, HSLMaskMode, LogMode, MaskSource, Project, SourcePatch,
    TargetSpace, TimelineEditMode, TrackKind, TransitionKind, TransitionLayer,
};

/// The version of a file with none of the gated content (every file since the stabilizer writes compact keyframes).
pub(crate) const FLOOR_VERSION: i64 = 36;

/// Gates from the newest version down; the first that holds decides. v77, v84 and v85 are not here: the encoder reports
/// them while writing (`SeenFlags`).
/// Does the project hold content that needs a version.
type Gate = fn(&Project) -> bool;

pub(crate) const GATES: &[(i64, Gate)] = &[
    (94, v94),
    (93, v93),
    (92, v92),
    (91, v91),
    (90, v90),
    (89, v89),
    (88, v88),
    (87, v87),
    (86, v86),
    (83, v83),
    (82, v82),
    (81, v81),
    (80, v80),
    (79, v79),
    (78, v78),
    (76, v76),
    (75, v75),
    (74, v74),
    (73, v73),
    (72, v72),
    (71, v71),
    (70, v70),
    (69, v69),
    (68, v68),
    (67, v67),
    (66, v66),
    (65, v65),
    (64, v64),
    (63, v63),
    (62, v62),
    (61, v61),
    (60, v60),
    (59, v59),
    (58, v58),
    (57, v57),
    (56, v56),
    (55, full_blend_modes),
    (54, mask_inputs),
    (53, transition_layers),
    (52, gyroflow_stabilizers),
    (51, gradient_effects),
    (50, range_fades),
    (49, extended_adjustments),
    (48, color_range_qualifiers),
    (47, independent_grades),
    (46, voice_chain_effects),
    (45, grade_links_or_ranges),
    (43, color_match_or_live_ducking),
    (42, graphics_clips),
    (41, adjustment_or_extended_blend),
    (40, motion_shutter_or_element_transitions),
    (39, audio_effects),
    (38, stinger),
    (37, subject_mask),
];

fn clips(p: &Project) -> impl Iterator<Item = &Clip> {
    p.timelines.iter().flat_map(|t| t.tracks.iter()).flat_map(|tr| tr.clips().iter())
}

fn masks(c: &Clip) -> &[ClipMask] {
    c.mask_store.as_deref().unwrap_or(&[])
}

/// The effects on the layers of a Graphics clip.
fn layer_effects(c: &Clip) -> impl Iterator<Item = &ClipEffect> {
    c.graphics().into_iter().flat_map(|g| g.layers.iter()).flat_map(|l| l.effects.iter())
}

/// Some clip effect satisfies `f`.
fn any_effect(p: &Project, f: impl Fn(&ClipEffect) -> bool) -> bool {
    clips(p).any(|c| c.effects.iter().any(&f))
}

/// Some clip effect or some effect on a graphics layer satisfies `f`.
fn any_effect_or_layer(p: &Project, f: impl Fn(&ClipEffect) -> bool) -> bool {
    clips(p).any(|c| c.effects.iter().chain(layer_effects(c)).any(&f))
}

fn kind_in(e: &ClipEffect, kinds: &[&str]) -> bool {
    kinds.contains(&e.kind.as_str())
}

/// A stored parameter is keyed or differs from `default`.
fn changed(e: &ClipEffect, key: &str, default: f64) -> bool {
    e.parameters.get(key).is_some_and(|p| p.is_animated() || p.value != default)
}

// v37 ... v55: the gates that sit next to their features in Swift.

fn subject_mask(p: &Project) -> bool {
    clips(p).any(|c| masks(c).iter().any(|m| m.source() == MaskSource::Subject))
}

fn stinger(p: &Project) -> bool {
    p.timelines.iter().any(|t| {
        t.tracks
            .iter()
            .any(|tr| tr.transitions.iter().any(|x| x.kind == TransitionKind::Stinger || x.stinger.is_some()))
    })
}

fn audio_effects(p: &Project) -> bool {
    clips(p).any(|c| c.kind == TrackKind::Audio && c.effects.iter().any(|e| e.kind.starts_with("audio.")))
}

fn motion_shutter_or_element_transitions(p: &Project) -> bool {
    let shutter = clips(p).any(|c| {
        c.animation.is_shutter_open_or_keyed()
            || c.baked_store.iter().flatten().any(|b| b.motion.is_shutter_open_or_keyed())
    });
    let element = p.timelines.iter().any(|t| {
        t.tracks.iter().any(|tr| {
            tr.transitions
                .iter()
                .any(|x| matches!(x.kind, TransitionKind::Move | TransitionKind::Zoom | TransitionKind::Pop))
        })
    });
    shutter || element
}

fn is_generator(c: &Clip, kind: &str) -> bool {
    c.generator.as_ref().is_some_and(|g| g.kind == kind)
}

fn is_adjustment(c: &Clip) -> bool {
    is_generator(c, "adjustment")
}

fn adjustment_or_extended_blend(p: &Project) -> bool {
    clips(p).any(|c| is_adjustment(c) || !c.blend_mode.is_legacy())
}

fn graphics_clips(p: &Project) -> bool {
    clips(p).any(Clip::is_graphics)
}

fn color_match_or_live_ducking(p: &Project) -> bool {
    let color_match = any_effect(p, |e| e.grade.as_ref().is_some_and(|g| g.match_reference.is_some()));
    let ducking = p.live_ducking.is_some()
        || p.timelines.iter().any(|t| t.tracks.iter().any(|tr| tr.is_excluded_from_live_ducking()));
    color_match || ducking
}

fn is_color(e: &ClipEffect) -> bool {
    e.kind == "color"
}

fn grade_links_or_ranges(p: &Project) -> bool {
    clips(p).any(|c| c.grade_link.is_some() || c.effects.iter().any(|e| is_color(e) && e.color_range.is_some()))
}

fn voice_chain_effects(p: &Project) -> bool {
    any_effect(p, |e| kind_in(e, &["audio.multiband", "audio.parametricEQ"]))
}

fn independent_grades(p: &Project) -> bool {
    clips(p).any(|c| c.grade_independent_store == Some(true))
}

fn color_range_qualifiers(p: &Project) -> bool {
    any_effect(p, |e| is_color(e) && e.grade.as_ref().is_some_and(|g| g.hsl_secondary.is_some()))
}

fn extended_adjustments(p: &Project) -> bool {
    clips(p).any(|c| c.extends_to_end_store == Some(true) && is_adjustment(c))
}

fn range_fades(p: &Project) -> bool {
    any_effect(p, |e| e.color_fade_in.is_some() || e.color_fade_out.is_some())
}

fn gradient_effects(p: &Project) -> bool {
    any_effect(p, |e| e.kind == "gradient")
}

/// The Stabilizer's engine is Gyroflow (stored as the rounded parameter value 1).
fn is_gyroflow(e: &ClipEffect) -> bool {
    e.kind == "stabilize"
        && e.parameters.get("stabilizeMethod").is_some_and(|p| p.value.is_finite() && p.value.round() == 1.0)
}

fn gyroflow_stabilizers(p: &Project) -> bool {
    any_effect(p, is_gyroflow)
}

fn transition_layers(p: &Project) -> bool {
    clips(p).any(|c| is_generator(c, TransitionLayer::GENERATOR_KIND))
}

fn mask_inputs(p: &Project) -> bool {
    clips(p).any(|c| {
        masks(c).iter().any(|m| m.source() == MaskSource::Magic || !m.used_by_opacity())
            || c.effects.iter().any(|e| !e.mask_input.is_empty())
    })
}

fn full_blend_modes(p: &Project) -> bool {
    let gate = 55;
    let needs = |m: BlendMode| m.minimum_file_version() >= gate;
    clips(p).any(|c| needs(c.blend_mode) || c.graphics().is_some_and(|g| g.layers.iter().any(|l| needs(l.blend_mode))))
}

// v56 ... v94.

/// Effect kinds and options added after the v55 gates, none of which had one.
fn needs_v56(e: &ClipEffect) -> bool {
    const KINDS: &[&str] = &[
        "dynamicZoom",
        "dateStamp",
        "posterizeTime",
        "videoDenoise",
        "deflicker",
        "motionBlurFX",
        "lumaKey",
        "gateWeave",
        "scanlines",
        "chromaBleed",
        "trackingNoise",
        "audio.deReverb",
        "audio.deHum",
        "audio.lowCut",
        "audio.dialogueLeveler",
        "audio.enhanceSpeech",
    ];
    if kind_in(e, KINDS) {
        return true;
    }
    match e.kind.as_str() {
        "audio.deEsser" => {
            changed(e, "frequency", 7_000.0)
                || changed(e, "range", 1.0)
                || changed(e, "speed", 1.0)
                || changed(e, "listen", 0.0)
        }
        "crop" => changed(e, ClipEffect::CROP_SOFTNESS_KEY, 0.0),
        _ => false,
    }
}

fn v56(p: &Project) -> bool {
    use sq_core_model::DuckTiming;
    // `DuckTiming.classic`: the original symmetric 300 ms fade each way.
    let classic = |t: &DuckTiming| {
        (t.lookahead_ms, t.attack_ms, t.hold_ms, t.recovery_ms, t.min_pause_ms) == (0.0, 300.0, 0.0, 300.0, 0.0)
    };
    p.live_ducking.as_ref().and_then(|d| d.timing.as_ref()).is_some_and(|t| !classic(t))
        || any_effect_or_layer(p, needs_v56)
}

fn v57(p: &Project) -> bool {
    p.media.iter().any(|m| m.subclip.is_some()) || clips(p).any(|c| c.bundle.is_some())
}

fn v58(p: &Project) -> bool {
    clips(p).any(|c| c.zones.is_some() || c.template_slots.is_some())
}

/// A Gyroflow Stabilizer's Field of View, Lens Correction or Sync Offset set away from the default. The values are read
/// the way `GyroflowOptions` does: non-finite means default, the rest is clamped to the stored range.
fn changes_lens_or_sync(e: &ClipEffect) -> bool {
    let v = |key: &str, lo: f64, hi: f64, default: f64| {
        e.parameters.get(key).map(|p| p.value).filter(|x| x.is_finite()).map_or(default, |x| x.clamp(lo, hi))
    };
    v("gyroFieldOfView", 10.0, 300.0, 100.0) != 100.0
        || v("gyroLensCorrection", 0.0, 100.0, 100.0) != 100.0
        || v("gyroSyncOffset", -5000.0, 5000.0, 0.0) != 0.0
}

fn v59(p: &Project) -> bool {
    any_effect(p, |e| is_gyroflow(e) && changes_lens_or_sync(e))
}

fn v60(p: &Project) -> bool {
    let needs = |e: &ClipEffect| {
        kind_in(e, &["audio.highCut", "audio.stereoWidth", "audio.chorus", "edgeFeather", "glitchDisplace"])
    };
    clips(p).any(|c| c.markers.as_ref().is_some_and(|m| !m.is_empty())) || any_effect_or_layer(p, needs)
}

fn v61(p: &Project) -> bool {
    any_effect_or_layer(p, |e| kind_in(e, &["halftone", "tile", "kaleidoscope"]))
}

fn v62(p: &Project) -> bool {
    clips(p).any(|c| c.template_slots.iter().flatten().any(|s| s.graphics_layer.is_some()))
}

fn v63(p: &Project) -> bool {
    clips(p).any(|c| c.graphics().is_some_and(|g| g.layers.iter().any(|l| l.follow.is_some())))
}

fn v64(p: &Project) -> bool {
    any_effect_or_layer(p, |e| kind_in(e, &["trails", "alphaOutline", "longShadow"]))
}

fn v65(p: &Project) -> bool {
    clips(p).any(|c| masks(c).iter().any(|m| m.source() == MaskSource::Picture))
}

fn v66(p: &Project) -> bool {
    p.timelines.iter().any(|t| t.master_level.is_some())
}

fn v67(p: &Project) -> bool {
    p.timelines.iter().any(|t| {
        t.edit_mode_store == Some(TimelineEditMode::Magnetic)
            || t.tracks.iter().any(|tr| tr.clips().iter().any(|c| c.attachment.is_some()))
    })
}

/// The nine Canon Log input color spaces (v68).
fn needs_v68(id: ColorSpaceID) -> bool {
    matches!(
        id,
        ColorSpaceID::CanonLog3CinemaGamut
            | ColorSpaceID::CanonLog3BT2020
            | ColorSpaceID::CanonLog3BT709
            | ColorSpaceID::CanonLog2CinemaGamut
            | ColorSpaceID::CanonLog2BT2020
            | ColorSpaceID::CanonLog2BT709
            | ColorSpaceID::CanonLogCinemaGamut
            | ColorSpaceID::CanonLogBT2020
            | ColorSpaceID::CanonLogBT709
    )
}

fn v68(p: &Project) -> bool {
    p.input_color_space.is_some_and(needs_v68)
        || clips(p).any(|c| c.footage_color.source.is_some_and(needs_v68))
        || p.media.iter().any(|m| m.info.as_ref().and_then(|i| i.detected_color_space).is_some_and(needs_v68))
}

fn v69(p: &Project) -> bool {
    p.media.iter().any(|m| {
        m.info
            .as_ref()
            .and_then(|i| i.video.as_ref())
            .is_some_and(|v| !v.pixel_aspect.is_square() || v.pixel_aspect_override.is_some())
    })
}

fn v70(p: &Project) -> bool {
    p.media.iter().any(|m| m.info.as_ref().and_then(|i| i.audio.as_ref()).is_some_and(|a| a.channel_map.is_some()))
        || any_effect_or_layer(p, |e| kind_in(e, &["audio.pitchShift", "audio.disguiseVoice"]))
}

fn v71(p: &Project) -> bool {
    p.timelines.iter().any(|t| t.angles.is_some()) || clips(p).any(|c| c.angle.is_some())
}

fn v72(p: &Project) -> bool {
    // Payload version 1 is the caption look every build since W8.3 reads.
    p.style_kit.as_ref().is_some_and(|k| k.looks.values().any(|l| l.payload_version > 1))
}

fn v73(p: &Project) -> bool {
    any_effect_or_layer(p, |e| e.kind == "audio.notch")
}

fn v74(p: &Project) -> bool {
    clips(p).any(|c| c.graphics().is_some_and(|g| g.has_item_ranges()))
}

fn v75(p: &Project) -> bool {
    p.timelines.iter().any(|t| {
        t.caption_tracks.iter().any(|ct| ct.items().iter().any(|i| i.words.iter().any(|w| w.confidence.is_some())))
    })
}

fn v76(p: &Project) -> bool {
    let needs =
        |e: &ClipEffect| e.kind == "audio.graphicEQ" || (e.kind == "audio.noiseGate" && changed(e, "hold", 0.0));
    any_effect_or_layer(p, needs)
}

fn v78(p: &Project) -> bool {
    any_effect_or_layer(p, |e| e.kind == "colorGraph")
}

fn v79(p: &Project) -> bool {
    use sq_core_model::StepKind;
    let uses = |e: &ClipEffect| {
        e.kind == "colorGraph"
            && e.color_graph.as_ref().is_some_and(|g| {
                g.steps().iter().any(|s| {
                    s.kind != StepKind::Serial || s.mix != 100.0 || s.position.is_some() || s.mixer_position.is_some()
                })
            })
    };
    any_effect_or_layer(p, uses)
}

fn v80(p: &Project) -> bool {
    use sq_core_model::{KeyMixMode, LayerMixMode};
    let uses = |e: &ClipEffect| {
        e.kind == "colorGraph"
            && e.color_graph.as_ref().is_some_and(|g| {
                g.links.is_some()
                    || !g.key_links.is_empty()
                    || g.steps().iter().any(|s| {
                        s.layer_mix != LayerMixMode::Normal || s.key_outside || s.key_mix != KeyMixMode::Multiply
                    })
            })
    };
    any_effect_or_layer(p, uses)
}

fn v81(p: &Project) -> bool {
    p.timelines.iter().any(|t| {
        t.timecode_start_store.is_some() || t.timecode_display_store.is_some() || t.preview_quality_store.is_some()
    })
}

fn v82(p: &Project) -> bool {
    p.timelines.iter().any(|t| t.channel_layout_store.is_some() || t.format.pixel_aspect_store.is_some())
}

fn v83(p: &Project) -> bool {
    p.notes_store.is_some()
}

fn v86(p: &Project) -> bool {
    p.timelines.iter().any(|t| t.is_master_volume_keyed()) || any_effect_or_layer(p, |e| e.kind == "agedFilm")
}

fn v87(p: &Project) -> bool {
    clips(p).any(|c| masks(c).iter().any(|m| m.source() == MaskSource::ColorRange))
}

fn v88(p: &Project) -> bool {
    p.timelines.iter().any(|t| t.source_patch_store.as_ref().is_some_and(|s| *s != SourcePatch::default()))
}

fn v89(p: &Project) -> bool {
    let layer_reversed = |c: &Clip| {
        c.generator
            .as_ref()
            .filter(|g| g.kind == TransitionLayer::GENERATOR_KIND)
            .and_then(|g| serde_json::from_slice::<TransitionLayer>(&g.payload).ok())
            .is_some_and(|l| l.reversed == Some(true))
    };
    p.timelines.iter().any(|t| {
        t.tracks
            .iter()
            .any(|tr| tr.transitions.iter().any(|x| x.reversed == Some(true)) || tr.clips().iter().any(layer_reversed))
    })
}

fn v90(p: &Project) -> bool {
    any_effect(p, |e| e.kind == "trackMask")
}

fn v91(p: &Project) -> bool {
    p.timelines.iter().any(|t| t.snapping_off_store == Some(true) || t.linked_selection_off_store == Some(true))
}

fn v92(p: &Project) -> bool {
    clips(p).any(|c| c.animation.is_anti_flicker_set_or_keyed())
}

fn v93(p: &Project) -> bool {
    clips(p).any(|c| {
        let f = &c.footage_color;
        f.log_mode != LogMode::CameraLUT || f.target_space != TargetSpace::Rec709 || !f.hdr_conform
    })
}

fn v94(p: &Project) -> bool {
    any_effect(p, |e| {
        is_color(e)
            && e.grade.as_ref().is_some_and(|g| {
                g.zone_board.is_some()
                    || g.zone_board_off
                    || g.hsl_secondary.as_ref().is_some_and(|h| h.mask_mode == HSLMaskMode::Volume)
            })
    })
}
