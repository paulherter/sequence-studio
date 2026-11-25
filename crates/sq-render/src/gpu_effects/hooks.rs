// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: GPUCompositor+Effects.swift, GPUCompositor+Flow.swift
//! The clip effect chain on the compositor: [`ClipEffectHooks`] implements [`EffectHooks`] with the same plans, passes and
//! draws as the Swift `GPUCompositor` (`finishLayer`, masks, Picture mattes, film look, anti-flicker, masked grades, frame
//! blending, optical flow, Deflicker / Video Denoise / Trails). `GpuCompositor::with_hooks(gpu, ClipEffectHooks::new(gpu))`
//! renders the full tree.

use super::effect_chain_plan::{effect_chain_factor, pixel_budget, repeat_edge_rect};
use super::effect_passes::EffectPasses;
use super::kernels::Kernels;
use super::look_passes::LookPasses;
use super::mask_data::{
    MaskInputs, MaskTextures, ScreenMap, mask_entries, mask_scope, matte_slots, opacity_masks, pack_mattes,
};
use super::optical_flow_passes::FlowStore;
use super::scratch::Scratch;
use super::temporal_passes::{TemporalInput, TemporalPasses, neighbor_limits};
use super::uniform_plan::{
    MASKED_GRADE_MEDIA, apply_weave, configure, cut_to_mask_rect, masked_grade_color, masked_grade_owner,
    screen_from_local, upright,
};
use crate::color::pipeline::ColorPipeline;
use crate::color::pipeline_from_clip_color;
use crate::compositor::{
    CompositorError, ConvertUniforms, Draw, EffectHooks, GpuCompositor, OpticalFlowRequest, Picture, PictureKind,
    PictureSource, RenderLayer, RenderNode, TemporalFrames, Uniforms,
};
use crate::effects::gaussian_blur::Plan;
use crate::effects::image_filters::Frame;
use crate::effects::simd::Float2;
use crate::effects::visible_source_region::effect_work_factor;
use sq_core_color::FilmLook;
use sq_core_effects::effects_evaluation::{ClipEffects, EffectSegment};
use sq_core_masks::{MaskShape, SubjectMatte};
use sq_core_model::{BlendMode, ColorEffect, SequenceFormat};
use sq_core_time::Id;
use sq_gpu::frames::GpuTexture;
use sq_gpu::gpu::{Gpu, GpuCommands, GpuError};
use sq_gpu::layout::PixelFormat;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

/// Largest side of an effect intermediate (`GaussianBlur.maxTextureSize`).
const MAX_TEXTURE_SIZE: u32 = 16_384;
/// Matte textures kept across frames (a still matte uploads once).
const MATTE_CACHE: usize = 8;
const TRANSPARENT: [f64; 4] = [0.0; 4];

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The clip effect passes of one device, wired to the compositor.
pub struct ClipEffectHooks {
    gpu: Arc<Gpu>,
    passes: EffectPasses,
    kernels: Kernels,
    look: LookPasses,
    temporal: TemporalPasses,
    flow: Mutex<FlowStore>,
    /// Intermediates of the running render; released at the next `begin_render` (as the compositor's own).
    scratch: Mutex<Scratch>,
    /// Packed matte textures by the mattes' storage (the entry keeps the mattes alive, so an address is never reused).
    mattes: Mutex<Vec<(Vec<Arc<SubjectMatte>>, GpuTexture)>>,
    matte_uploads: std::sync::atomic::AtomicUsize,
}

impl ClipEffectHooks {
    pub fn new(gpu: &Arc<Gpu>) -> Arc<ClipEffectHooks> {
        Arc::new(ClipEffectHooks {
            gpu: Arc::clone(gpu),
            passes: EffectPasses::new(gpu),
            kernels: Kernels::new(gpu),
            look: LookPasses::new(gpu),
            temporal: TemporalPasses::new(gpu),
            flow: Mutex::new(FlowStore::new(gpu)),
            scratch: Mutex::new(Scratch::new(gpu)),
            mattes: Mutex::new(Vec::new()),
            matte_uploads: std::sync::atomic::AtomicUsize::new(0),
        })
    }

    /// A compositor that renders the full tree: core plus every clip effect.
    pub fn compositor(gpu: &Arc<Gpu>) -> Result<GpuCompositor, CompositorError> {
        GpuCompositor::with_hooks(gpu, Self::new(gpu))
    }

    /// Optical-flow fields measured so far (a cached pair measures once).
    pub fn flow_measure_count(&self) -> usize {
        lock(&self.flow).measure_count()
    }

    /// Matte textures uploaded so far.
    pub fn matte_upload_count(&self) -> usize {
        self.matte_uploads.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// `p` drawn upright (no transform, full opacity, no masks) into `target`, cleared transparent first.
    fn draw_upright(
        c: &mut GpuCompositor,
        p: &Draw,
        u: Uniforms,
        target: &GpuTexture,
        cmds: &mut GpuCommands,
    ) -> Result<(), CompositorError> {
        let mut d = p.clone();
        d.u = u;
        d.blend = BlendMode::Normal;
        d.stencil = false;
        d.mix = None;
        d.mask_data = None;
        d.matte = None;
        c.draw_all(cmds, &[d], target, Some(TRANSPARENT), false)
    }

    /// Up to 4 mattes in the r/g/b/a channels of one rgba16Float texture at the largest one's size. Cached by matte storage: a
    /// still matte (or one held by the matte cache across frames) uploads once; a cached texture is never rewritten.
    fn matte_texture(&self, ms: &[&Arc<SubjectMatte>]) -> Option<GpuTexture> {
        let used: Vec<Arc<SubjectMatte>> = ms.iter().take(4).map(|m| Arc::clone(m)).collect();
        let mut cache = lock(&self.mattes);
        if let Some((_, t)) =
            cache.iter().find(|(m, _)| m.len() == used.len() && m.iter().zip(&used).all(|(a, b)| Arc::ptr_eq(a, b)))
        {
            return Some(t.clone());
        }
        let refs: Vec<&SubjectMatte> = ms.iter().map(|m| &***m).collect();
        let (w, h, px) = pack_mattes(&refs)?;
        let t = self.gpu.texture(w as u32, h as u32, PixelFormat::Rgba16Float);
        let bytes: Vec<u8> = px.iter().flat_map(|v| v.to_le_bytes()).collect();
        self.gpu.upload_texture(&t, &bytes, (w * 8) as u32);
        self.matte_uploads.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        cache.push((used, t.clone()));
        if cache.len() > MATTE_CACHE {
            cache.remove(0);
        }
        Some(t)
    }

    /// The clip masks on a draw: mask entries in a data buffer, subject / Magic mattes in one texture. Picture masks read the
    /// current level's matte images (at most two distinct ones per draw, inputs 4 / 5).
    #[allow(clippy::too_many_arguments)]
    fn apply_masks(
        &self,
        c: &mut GpuCompositor,
        masks: &[MaskShape],
        matte: Option<&Arc<SubjectMatte>>,
        mattes: &HashMap<Id, Arc<SubjectMatte>>,
        edge_scale: f32,
        screen: Option<&ScreenMap>,
        p: &mut Draw,
    ) {
        if masks.is_empty() {
            return;
        }
        let scope = c.picture_scopes.last().cloned().unwrap_or_default();
        let mut images: Vec<GpuTexture> = Vec::new();
        let mut ids: Vec<Id> = Vec::new();
        let mut picture_slot: Vec<Option<usize>> = Vec::new();
        for m in masks {
            let found = (m.source == sq_core_model::MaskSource::Picture && screen.is_some())
                .then_some(m.picture_track)
                .flatten()
                .and_then(|track| scope.get(&track).map(|t| (track, t)));
            let Some((track, t)) = found else {
                picture_slot.push(None);
                continue;
            };
            if let Some(i) = ids.iter().position(|x| *x == track) {
                picture_slot.push(Some(i));
            } else if images.len() < 2 {
                images.push(t.clone());
                ids.push(track);
                picture_slot.push(Some(images.len() - 1));
            } else {
                picture_slot.push(None);
            }
        }
        let (distinct, slot) = matte_slots(masks, matte.map(|m| &**m), mattes);
        let owners = Self::matte_owners(&distinct, matte, mattes);
        let matte_tex = if owners.is_empty() { None } else { self.matte_texture(&owners) };
        let frame = if p.u.mask_size[0] > 0.0 { p.u.mask_size } else { p.u.size };
        let entries = mask_entries(
            masks,
            &MaskInputs {
                frame,
                edge_scale,
                screen,
                picture_slot: &picture_slot,
                matte_slot: &slot,
                has_matte: matte_tex.is_some(),
            },
        );
        let bytes: Vec<u8> = entries.iter().flat_map(|e| e.iter().flat_map(|v| v.to_le_bytes())).collect();
        let mut size = 256usize;
        while size < bytes.len() {
            size *= 2;
        }
        let buf = c.scratch_buffer(size as u64);
        self.gpu.queue().write_buffer(&buf, 0, &bytes);
        p.mask_data = Some(buf);
        p.u.mask_count = masks.len() as u32;
        p.matte = matte_tex;
        p.picture0 = images.first().cloned();
        p.picture1 = images.get(1).cloned();
    }

    /// The `Arc`s behind `distinct` (the matte of the layer or one of its Magic mattes).
    fn matte_owners<'a>(
        distinct: &[&SubjectMatte],
        matte: Option<&'a Arc<SubjectMatte>>,
        mattes: &'a HashMap<Id, Arc<SubjectMatte>>,
    ) -> Vec<&'a Arc<SubjectMatte>> {
        distinct
            .iter()
            .filter_map(|d| matte.into_iter().chain(mattes.values()).find(|a| std::ptr::eq(&***a, *d)))
            .collect()
    }

    /// `out` = `pre` where `masks` do not cover, `post` where they do.
    #[allow(clippy::too_many_arguments)]
    fn mask_scope(
        &self,
        c: &mut GpuCompositor,
        masks: &[MaskShape],
        layer: &RenderLayer,
        pre: &GpuTexture,
        post: &GpuTexture,
        out: &GpuTexture,
        frame: [f32; 2],
        pf: f32,
        screen: Option<ScreenMap>,
        cmds: &mut GpuCommands,
    ) -> Result<bool, CompositorError> {
        let u = Uniforms { size: frame, mask_size: frame, scale: [1.0, 1.0], ..Uniforms::default() };
        let mut q = Draw::new(u, Some(pre.clone()), None);
        let scaled = screen.map(|s| s.scaled(pf));
        self.apply_masks(
            c,
            masks,
            layer.subject_matte.as_ref(),
            &layer.mattes,
            1.0 / pf.max(1.0),
            scaled.as_ref(),
            &mut q,
        );
        let Some(md) = q.mask_data.clone() else { return Ok(false) };
        let dummy = c.dummy().clone();
        let textures = MaskTextures {
            matte: Some(q.matte.as_ref().unwrap_or(&dummy)),
            pictures: [Some(q.picture0.as_ref().unwrap_or(&dummy)), Some(q.picture1.as_ref().unwrap_or(&dummy))],
        };
        mask_scope(&self.gpu, cmds, &q.u.to_bytes(), &md, &textures, pre, post, out)?;
        Ok(true)
    }

    /// The look kernel on the draw drawn upright first; `None` when it cannot run.
    fn apply_look(
        &self,
        c: &mut GpuCommands,
        comp: &mut GpuCompositor,
        scratch: &mut Scratch,
        look: &FilmLook,
        p: &Draw,
    ) -> Result<Option<Draw>, CompositorError> {
        if !look.needs_pass() {
            return Ok(None);
        }
        let (w, h) = (p.u.size[0].round().max(1.0) as u32, p.u.size[1].round().max(1.0) as u32);
        if w.max(h) > MAX_TEXTURE_SIZE {
            return Ok(None);
        }
        let (a, b) = (scratch.image(w, h), scratch.image(w, h));
        Self::draw_upright(comp, p, upright(&p.u, w, h), &a, c)?;
        self.look.film_look(c, look, &a, &b)?;
        let mut out = p.clone();
        out.tex0 = Some(b);
        out.tex1 = None;
        out.u.mode = 3;
        out.u.linearize = 0;
        out.u.quarter = 0;
        out.u.part = [0.0; 4];
        out.u.size = [w as f32, h as f32];
        out.u.mask_size = [0.0; 2];
        out.u.crop = [0.0; 4];
        out.u.round_first = 0;
        out.u.crop_feather = 0.0;
        out.u.corner_radius = 0.0;
        out.u.key_count = 0;
        Ok(Some(out))
    }

    fn apply_anti_flicker(
        &self,
        c: &mut GpuCommands,
        comp: &mut GpuCompositor,
        scratch: &mut Scratch,
        strength: f64,
        p: &Draw,
    ) -> Result<Option<Draw>, CompositorError> {
        if strength <= 0.0 {
            return Ok(None);
        }
        let (w, h) = (p.u.size[0].round().max(1.0) as u32, p.u.size[1].round().max(1.0) as u32);
        if w.max(h) > MAX_TEXTURE_SIZE {
            return Ok(None);
        }
        let (a, b) = (scratch.image(w, h), scratch.image(w, h));
        let mut u1 = upright(&p.u, w, h);
        u1.crop = [0.0; 4];
        u1.round_first = 0;
        u1.crop_feather = 0.0;
        u1.corner_radius = 0.0;
        u1.key_count = 0;
        Self::draw_upright(comp, p, u1, &a, c)?;
        self.look.anti_flicker(c, &a, &b, strength)?;
        let mut out = p.clone();
        out.tex0 = Some(b);
        out.tex1 = None;
        out.u.mode = 3;
        out.u.linearize = 0;
        out.u.quarter = 0;
        out.u.part = [0.0; 4];
        out.u.size = [w as f32, h as f32];
        out.u.mask_size = [0.0; 2];
        Ok(Some(out))
    }

    /// A masked Color effect on an effect-chain image, into a new premultiplied texture.
    fn grade_segment(
        &self,
        c: &GpuCompositor,
        scratch: &mut Scratch,
        grade: &ColorEffect,
        tex: &GpuTexture,
        cmds: &mut GpuCommands,
    ) -> Result<Option<GpuTexture>, CompositorError> {
        let color = masked_grade_color(grade);
        let resolved: Option<Arc<ColorPipeline>> = match &c.color_resolver {
            Some(r) if c.color_resolver_blocks => {
                r.pipeline_blocking(&color, MASKED_GRADE_MEDIA, Some(masked_grade_owner(grade)))
            }
            Some(r) => r.pipeline(&color, MASKED_GRADE_MEDIA, Some(masked_grade_owner(grade))),
            None => {
                let p = pipeline_from_clip_color(&color, MASKED_GRADE_MEDIA, None, None);
                (!p.is_identity()).then(|| Arc::new(p))
            }
        };
        let Some(pipeline) = resolved.filter(|p| !p.is_identity()) else { return Ok(None) };
        let (mid, out) = (scratch.image(tex.width(), tex.height()), scratch.image(tex.width(), tex.height()));
        self.kernels.encode_709(cmds, tex, &mid)?;
        c.chain().encode(cmds, &pipeline, &mid, false)?;
        self.kernels.premultiply(cmds, &mid, &out)?;
        Ok(Some(out))
    }

    /// The plain draw of a layer turned into the draw(s) with its effects, in effect-list order.
    #[allow(clippy::too_many_lines, clippy::too_many_arguments)]
    fn finish(
        &self,
        c: &mut GpuCompositor,
        scratch: &mut Scratch,
        p0: Draw,
        layer: &RenderLayer,
        cmds: &mut GpuCommands,
        draws: &mut Vec<Draw>,
    ) -> Result<(), CompositorError> {
        let own;
        let fx = if layer.effects.is_identity() && layer.effects.segments.is_empty() {
            own = ClipEffects::with_corner_radius(layer.corner_radius);
            &own
        } else {
            &layer.effects
        };
        if fx.is_empty() {
            return Ok(());
        }
        let mut p = p0;
        p.blend = layer.blend_mode;
        if fx.anti_flicker > 0.0
            && let Some(soft) = self.apply_anti_flicker(cmds, c, scratch, fx.anti_flicker, &p)?
        {
            let blend = p.blend;
            p = soft;
            p.blend = blend;
        }
        let segs = &fx.segments;
        if segs.len() <= 1 {
            if let Some(seg) = segs.first() {
                configure(&mut p.u, seg, p.radius_factor, 1.0, Some(layer.corner_radius));
            }
            return self.emit(c, scratch, fx, layer, p, cmds, draws);
        }

        let layer_size = p.u.size;
        let mut cur = p.clone();
        let mut cur_size = layer_size;
        let mut first = true;
        let mut cut_to_frame = false;
        let linear_source = p.u.mode == 2 || p.u.mode == 3 || (p.u.mode == 1 && p.u.linearize == 0);
        let min_factor = if c.limits_color_work && layer_size[0].min(layer_size[1]) >= 128.0 {
            effect_chain_factor(
                segs,
                effect_work_factor(&layer.transform, Float2::new(layer_size[0], layer_size[1])),
                linear_source,
            )
        } else {
            1
        };
        let plan = |seg: &EffectSegment, size: [f32; 2]| -> Plan {
            let plain_blur = seg.shadow.is_none() && seg.filter.is_none();
            let margin = seg
                .shadow
                .as_ref()
                .map(|s| (s.dx * s.dx + s.dy * s.dy).sqrt() + 3.0 * s.sigma)
                .or_else(|| seg.filter.as_ref().map(|f| f.axis_margin().x))
                .unwrap_or(0.0);
            let margin_y = if seg.shadow.is_none() { seg.filter.as_ref().map(|f| f.axis_margin().y) } else { None };
            Plan::new(
                f64::from(size[0]),
                f64::from(size[1]),
                if plain_blur { seg.blur_after } else { 0.0 },
                margin,
                margin_y,
                min_factor,
                pixel_budget(seg),
            )
        };
        let mut scope_focal = 0.0f32;
        if p.u.tilt[2] > 0.0 {
            let mut size = layer_size;
            for seg in &segs[..segs.len() - 1] {
                let pl = plan(seg, size);
                size = [pl.output_width(), pl.output_height()];
            }
            let mut fu = p.u.clone();
            fu.size = size;
            scope_focal = fu.tilt_focal();
        }
        for seg in &segs[..segs.len() - 1] {
            let pl = plan(seg, cur_size);
            let (tw, th) = (pl.texture_width as u32, pl.texture_height as u32);
            let (mark, previous) = (scratch.mark(), cur.tex0.clone());
            let mut a = scratch.image(tw, th);
            let pf = pl.factor as f32;
            let b =
                (seg.blur_after > 0.0 && seg.shadow.is_none() && seg.filter.is_none()).then(|| scratch.image(tw, th));
            let mut u1 = cur.u.clone();
            u1.canvas = [tw as f32, th as f32];
            u1.size = [cur_size[0] / pf, cur_size[1] / pf];
            u1.position = [0.0; 2];
            u1.anchor = [0.0; 2];
            u1.scale = [1.0, 1.0];
            u1.rot_cos = 1.0;
            u1.rot_sin = 0.0;
            u1.opacity = 1.0;
            u1.blend = 0;
            u1.tilt = [0.0; 3];
            u1.mask_size = if first { [0.0; 2] } else { [layer_size[0] / pf, layer_size[1] / pf] };
            u1.key_count = 0;
            u1.crop = [0.0; 4];
            u1.round_first = 0;
            u1.mask_count = 0;
            u1.crop_feather = 0.0;
            configure(&mut u1, seg, p.radius_factor, pf, None);
            if cut_to_frame {
                cut_to_mask_rect(&mut u1);
            }
            let mut pre: Option<GpuTexture> = None;
            if seg.scopes_keys() {
                let t = scratch.image(tw, th);
                let mut u0 = u1.clone();
                u0.key_count = 0;
                Self::draw_upright(c, &cur, u0, &t, cmds)?;
                pre = Some(t);
            }
            Self::draw_upright(c, &cur, u1, &a, cmds)?;
            if pre.is_none() && !seg.scope.is_empty() && seg.shadow.is_none() && (seg.filter.is_some() || b.is_some()) {
                let t = scratch.image(tw, th);
                cmds.copy(&a, &t);
                pre = Some(t);
            }
            if let Some(sh) = &seg.shadow {
                let out = scratch.image(tw, th);
                self.passes.shadow(cmds, scratch, sh, &pl, &a, &out)?;
                a = out;
            } else if let Some(f) = &seg.filter {
                let frame = Frame {
                    center: Float2::new(tw as f32, th as f32) / 2.0,
                    size: Float2::new(layer_size[0] / pf, layer_size[1] / pf),
                };
                let out = scratch.image(tw, th);
                if !self.passes.filter(cmds, scratch, f, &a, &out, &frame, pl.factor as f64)? {
                    break;
                }
                a = out;
            } else if let Some(g) = &seg.grade {
                if let Some(out) = self.grade_segment(c, scratch, g, &a, cmds)? {
                    if !seg.scope.is_empty() {
                        pre = Some(a.clone());
                    }
                    a = out;
                }
            } else if let Some(b) = &b {
                let edges = seg
                    .blur_repeats_edges
                    .then(|| repeat_edge_rect([layer_size[0] / pf, layer_size[1] / pf], [tw as i32, th as i32]));
                self.passes.blur(cmds, &pl, &a, b, edges)?;
            }
            if let Some(pre) = pre {
                let out = scratch.image(tw, th);
                let mut map = screen_from_local(&p.u);
                if scope_focal > 0.0 {
                    map.tilt[2] = scope_focal;
                }
                if self.mask_scope(
                    c,
                    &seg.scope,
                    layer,
                    &pre,
                    &a,
                    &out,
                    [layer_size[0] / pf, layer_size[1] / pf],
                    pf,
                    Some(map),
                    cmds,
                )? {
                    a = out;
                }
            }
            cut_to_frame =
                seg.blur_after > 0.0 && seg.blur_repeats_edges && seg.shadow.is_none() && seg.filter.is_none();

            let mut next = p.clone();
            next.tex0 = Some(a);
            next.tex1 = None;
            next.u.mode = 3;
            next.u.linearize = 0;
            next.u.quarter = 0;
            next.u.part = [0.0; 4];
            cur_size = [pl.output_width(), pl.output_height()];
            next.u.size = cur_size;
            cur = next;
            first = false;
            // This step's temporaries and the previous step's result are read by no later pass: back to the pool now
            // (see `Scratch::release_since`), so a long chain on a 4K layer does not hold a few 4K textures per step.
            scratch.release_since(mark, cur.tex0.as_ref());
            if let Some(previous) = previous {
                scratch.release(&previous);
            }
        }

        let mut fin = cur;
        fin.u = p.u.clone();
        fin.blend = p.blend;
        if !first {
            fin.u.mode = 3;
            fin.u.linearize = 0;
            fin.u.quarter = 0;
            fin.u.part = [0.0; 4];
            fin.u.size = cur_size;
            fin.u.mask_size = layer_size;
        }
        if fin.u.tilt[2] > 0.0 {
            fin.u.tilt[2] = fin.u.tilt_focal();
        }
        fin.u.key_count = 0;
        fin.u.crop = [0.0; 4];
        fin.u.round_first = 0;
        fin.u.crop_feather = 0.0;
        if let Some(last) = segs.last() {
            configure(&mut fin.u, last, p.radius_factor, 1.0, None);
        }
        if cut_to_frame {
            cut_to_mask_rect(&mut fin.u);
        }
        self.emit(c, scratch, fx, layer, fin, cmds, draws)
    }

    /// The last step of a layer's chain: clip masks, film look and Gate Weave on the final draw.
    #[allow(clippy::too_many_arguments)]
    fn emit(
        &self,
        c: &mut GpuCompositor,
        scratch: &mut Scratch,
        fx: &ClipEffects,
        layer: &RenderLayer,
        mut q: Draw,
        cmds: &mut GpuCommands,
        draws: &mut Vec<Draw>,
    ) -> Result<(), CompositorError> {
        let mut placed = q.u.clone();
        if let Some(weave) = &fx.look.weave {
            apply_weave(weave, &mut placed);
        }
        let masks = opacity_masks(&fx.masks, &layer.mattes);
        self.apply_masks(
            c,
            &masks,
            layer.subject_matte.as_ref(),
            &layer.mattes,
            1.0,
            Some(&screen_from_local(&placed)),
            &mut q,
        );
        if fx.look.needs_pass()
            && let Some(looked) = self.apply_look(cmds, c, scratch, &fx.look, &q)?
        {
            q = looked;
        }
        if let Some(weave) = &fx.look.weave {
            apply_weave(weave, &mut q.u);
        }
        draws.push(q);
        Ok(())
    }
}

impl EffectHooks for ClipEffectHooks {
    fn begin_render(&self) {
        *lock(&self.scratch) = Scratch::new(&self.gpu);
    }

    fn finish_layer(
        &self,
        c: &mut GpuCompositor,
        draw: Draw,
        layer: &RenderLayer,
        _format: &SequenceFormat,
        cmds: &mut GpuCommands,
        draws: &mut Vec<Draw>,
    ) -> Result<(), CompositorError> {
        let mut scratch = lock(&self.scratch);
        self.finish(c, &mut scratch, draw, layer, cmds, draws)
    }

    fn encode_picture_mattes(
        &self,
        c: &mut GpuCompositor,
        nodes: &[RenderNode],
        format: &SequenceFormat,
        cmds: &mut GpuCommands,
        pictures: PictureSource,
    ) -> Result<bool, CompositorError> {
        let isolated = nodes.iter().any(|n| matches!(n, RenderNode::PictureScope));
        let base: HashMap<Id, GpuTexture> =
            if isolated { HashMap::new() } else { c.picture_scopes.last().cloned().unwrap_or_default() };
        let mut scope: Option<HashMap<Id, GpuTexture>> = isolated.then(HashMap::new);
        for node in nodes {
            let RenderNode::PictureMatte { track, children } = node else { continue };
            let tex = c.acquire(format.width, format.height);
            c.picture_scopes.push(HashMap::new());
            let r = c.encode(children, format, &tex, cmds, TRANSPARENT, false, pictures);
            c.picture_scopes.pop();
            r?;
            scope.get_or_insert_with(|| base.clone()).insert(*track, tex);
        }
        let Some(scope) = scope else { return Ok(false) };
        c.picture_scopes.push(scope);
        Ok(true)
    }

    fn blend_intermediate(
        &self,
        c: &mut GpuCompositor,
        a: &Picture,
        b: &Picture,
        weight: f32,
        flow: Option<OpticalFlowRequest>,
        u: &Uniforms,
        pipeline: Option<&ColorPipeline>,
        cmds: &mut GpuCommands,
    ) -> Result<Option<GpuTexture>, CompositorError> {
        let (w, h) = (a.planes.0.width(), a.planes.0.height());
        if b.planes.0.width() != w || b.planes.0.height() != h {
            return Ok(None);
        }
        let mut alpha_b = u.alpha_mode;
        match (a.kind, b.kind) {
            (PictureKind::Ycbcr { .. }, PictureKind::Ycbcr { .. }) if b.planes.1.is_some() => {}
            (PictureKind::Rgba { .. }, PictureKind::Rgba { alpha_mode }) => alpha_b = alpha_mode,
            _ => return Ok(None),
        }
        let mut scratch = lock(&self.scratch);
        let (ma, mb, mc) = (scratch.image(w, h), scratch.image(w, h), scratch.image(w, h));
        {
            let mut cu = u.clone();
            let dummy = c.dummy().clone();
            let mut enc = cmds.compute();
            enc.set_pipeline(&self.gpu.compute_pipeline("SourceConvert", "convertToRGB", PixelFormat::Rgba16Float)?);
            enc.set_constants(&ConvertUniforms { origin: [0, 0], transfer: u32::MAX }.to_bytes(), 1)?;
            for (pic, out, alpha) in [(a, &ma, u.alpha_mode), (b, &mb, alpha_b)] {
                cu.alpha_mode = alpha;
                enc.set_constants(&cu.to_bytes(), 0)?;
                enc.set_input(&pic.planes.0, 0)?;
                enc.set_input(pic.planes.1.as_ref().unwrap_or(&dummy), 1)?;
                enc.set_output(out);
                enc.dispatch(w, h)?;
            }
        }
        // Optical flow: the motion is measured on the source pictures, before any grade changes them (cached per pair).
        let field = match flow {
            Some(request) => Some(lock(&self.flow).field(cmds, &mut scratch, &ma, &mb, &request)?),
            None => None,
        };
        let mut encoded = true;
        if let Some(pipeline) = pipeline {
            let turned = u.quarter & 1 == 1;
            c.chain().encode(cmds, pipeline, &ma, turned)?;
            c.chain().encode(cmds, pipeline, &mb, turned)?;
            encoded = false;
        }
        if let Some(field) = field {
            lock(&self.flow).passes().interpolate(cmds, &ma, &mb, &field, weight, encoded, &mc)?;
        } else {
            self.kernels.blend_frames(cmds, &ma, &mb, &mc, weight, encoded)?;
        }
        Ok(Some(mc))
    }

    fn temporal_intermediate(
        &self,
        c: &mut GpuCompositor,
        center: &Picture,
        frames: &TemporalFrames,
        u: &Uniforms,
        pipeline: Option<&ColorPipeline>,
        cmds: &mut GpuCommands,
        pictures: PictureSource,
    ) -> Result<Option<GpuTexture>, CompositorError> {
        let (w, h) = (center.planes.0.width(), center.planes.0.height());
        let dummy = c.dummy().clone();
        let same_kind = |p: &Picture| match (center.kind, p.kind) {
            (PictureKind::Ycbcr { .. }, PictureKind::Ycbcr { .. }) => center.kind == p.kind && p.planes.1.is_some(),
            (PictureKind::Rgba { .. }, PictureKind::Rgba { .. }) => center.kind == p.kind,
            _ => false,
        };
        let planes = |list: &[sq_frame::sqframe::SQFrame], limit: usize| -> Vec<(GpuTexture, GpuTexture)> {
            let mut out = Vec::new();
            for frame in list {
                if out.len() >= limit {
                    break;
                }
                let Some(p) = pictures(frame) else { break };
                if p.planes.0.width() != w || p.planes.0.height() != h || !same_kind(&p) {
                    break;
                }
                out.push((p.planes.0.clone(), p.planes.1.clone().unwrap_or_else(|| dummy.clone())));
            }
            out
        };
        let (n_before, n_after) = neighbor_limits(&frames.filter);
        let before = planes(&frames.before, n_before);
        let after = planes(&frames.after, n_after);
        let center_planes = (center.planes.0.clone(), center.planes.1.clone().unwrap_or_else(|| dummy.clone()));
        let composite = u.to_bytes();
        let input = TemporalInput {
            center: &center_planes,
            before: &before,
            after: &after,
            composite: &composite,
            size: (w, h),
        };
        let turned = u.quarter & 1 == 1;
        let chain = c.chain();
        let mut grade = |cmds: &mut GpuCommands, tex: &GpuTexture| -> Result<(), GpuError> {
            pipeline
                .map_or(Ok(()), |p| chain.encode(cmds, p, tex, turned))
                .map_err(|e| GpuError::Binding(e.to_string()))
        };
        let mut scratch = lock(&self.scratch);
        let out = self.temporal.run(
            cmds,
            &mut scratch,
            &frames.filter,
            &input,
            if pipeline.is_some() { Some(&mut grade) } else { None },
        )?;
        Ok(out)
    }
}
