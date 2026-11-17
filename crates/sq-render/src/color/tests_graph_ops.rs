//! Port of the lowering and CPU parts of ColorGroupTests, the window part of ColorGraphRenderTests and ColorGraphKeyTests
//! (key wires, mixer keys, Layer mix).

use std::sync::Arc;

use sq_core_color::{ColorGraphExt, ColorGraphWiringExt};
use sq_core_model::{
    ColorGraph, ColorQualifier, ColorStep, CurvePoint, GraphPort, KeyMixMode, LUTRef, LayerMixMode, RGBCurves,
    StepKind, StepPrimaries, StepWindow, StepWindowShape,
};
use sq_core_time::{Id, IdSource, SequentialIds};

use super::clip_pipeline::{LutProvider, graph_ops};
use super::cube_lut::CubeLut;
use super::pipeline::{ColorOp, ColorPipeline};
use super::source_space::SourceColorSpace as S;
use super::testing::{constant_lut, dist};
use super::tone_mapping::ToneMapping;
use super::transfer::{bt709_inverse_oetf as inv, bt709_oetf as oetf};
use super::vec::Vec3;

fn primaries(k: f32) -> StepPrimaries {
    let mut p = StepPrimaries::default();
    (p.lift.r, p.lift.g, p.lift.b) = (0.02 * k, 0.0, -0.01 * k);
    (p.gamma.r, p.gamma.g, p.gamma.b) = (1.0 + 0.1 * k, 0.95, 1.0);
    (p.gain.r, p.gain.g, p.gain.b) = (1.1, 1.0, 0.9 + 0.02 * k);
    (p.offset.r, p.offset.g, p.offset.b) = (0.0, 0.01, 0.005);
    p.contrast = 1.15;
    p.saturation = 0.85;
    p
}

fn curves() -> RGBCurves {
    RGBCurves {
        master: [(0.0, 0.03), (0.5, 0.55), (1.0, 0.97)].map(|(x, y)| CurvePoint { x, y }).to_vec(),
        ..RGBCurves::default()
    }
}

fn qualifier() -> ColorQualifier {
    ColorQualifier { hue_center: 30.0, hue_width: 80.0, sat_min: 5.0, softness: 40.0, ..ColorQualifier::default() }
}

fn window(shape: StepWindowShape) -> StepWindow {
    StepWindow {
        shape,
        center_x: 0.45,
        center_y: 0.55,
        width: 0.6,
        height: 0.4,
        rotation: 20.0,
        softness: 0.3,
        ..StepWindow::default()
    }
}

struct Lut(Arc<CubeLut>);

impl LutProvider for Lut {
    fn lut(&self, r: &LUTRef) -> Option<Arc<CubeLut>> {
        matches!(r, LUTRef::File { .. }).then(|| Arc::clone(&self.0))
    }
}

fn tag(o: &ColorOp) -> String {
    match o {
        ColorOp::Primaries(_) => "prim".into(),
        ColorOp::Curves(_) => "curves".into(),
        ColorOp::HueCurves(_) => "hue".into(),
        ColorOp::Look(..) => "look".into(),
        ColorOp::StepBegin => "begin".into(),
        ColorOp::StepEnd { mix, .. } => if *mix < 1.0 { "endMix" } else { "end" }.into(),
        ColorOp::GroupBegin => "gbegin".into(),
        ColorOp::BranchEnd { layer, .. } => if *layer { "layer" } else { "branch" }.into(),
        ColorOp::GroupMerge { count } => format!("merge{count}"),
        ColorOp::GroupEnd => "gend".into(),
        _ => "other".into(),
    }
}

fn tags(g: &ColorGraph, p: Option<&dyn LutProvider>) -> Vec<String> {
    graph_ops(g, p).iter().map(tag).collect()
}

/// A graph whose first Step has primaries, edited by `f`.
fn graph(f: impl FnOnce(&mut ColorGraph, &mut SequentialIds)) -> ColorGraph {
    let mut ids = SequentialIds::default();
    let mut g = ColorGraph::new(Vec::new(), None, None, ids.next_id());
    let first = g.steps()[0].id;
    g.update(first, |s| s.primaries = primaries(1.0));
    f(&mut g, &mut ids);
    g
}

#[test]
fn serial_only_graph_lowers_without_extra_ops() {
    let g = graph(|g, ids| {
        let b = g.add_step(None, StepKind::Serial, ids);
        g.update(b, |s| {
            s.primaries = primaries(2.0);
            s.curves = curves();
        });
    });
    assert_eq!(tags(&g, None), ["prim", "prim", "curves"]);
}

#[test]
fn mix_below_100_wraps_a_serial_step() {
    let mut g = graph(|_, _| {});
    let first = g.steps()[0].id;
    g.update(first, |s| s.mix = 40.0);
    let ops = graph_ops(&g, None);
    assert_eq!(ops.iter().map(tag).collect::<Vec<_>>(), ["begin", "prim", "endMix"]);
    assert!(matches!(&ops[2], ColorOp::StepEnd { mix, .. } if (mix - 0.4).abs() < 1e-6));
    g.update(first, |s| s.mix = 0.0);
    assert!(graph_ops(&g, None).is_empty(), "Mix 0 shows nothing of the Step");
}

#[test]
fn parallel_column_lowers_to_a_group() {
    let g = graph(|g, ids| {
        let p = g.add_step(None, StepKind::Parallel, ids);
        g.update(p, |s| s.primaries = primaries(3.0));
    });
    assert_eq!(tags(&g, None), ["gbegin", "prim", "branch", "prim", "branch", "merge2", "gend"]);
}

#[test]
fn layer_without_parallels_still_averages_the_head() {
    let g = graph(|g, ids| {
        let l = g.add_step(None, StepKind::Layer, ids);
        g.update(l, |s| {
            s.primaries = primaries(3.0);
            s.qualifier = Some(qualifier());
        });
    });
    assert_eq!(tags(&g, None), ["gbegin", "prim", "branch", "merge1", "prim", "layer", "gend"]);
}

#[test]
fn neutral_layer_and_disabled_branches_are_skipped() {
    let g = graph(|g, ids| {
        g.add_step(None, StepKind::Layer, ids);
        let p = g.add_step(None, StepKind::Parallel, ids);
        g.update(p, |s| s.primaries = primaries(3.0));
        g.set_step_enabled(p, false);
    });
    assert_eq!(tags(&g, None), ["prim"], "falls back to the plain serial Step");
}

#[test]
fn a_group_that_does_not_fit_drops_the_branch_that_would_not() {
    let provider = Lut(Arc::new(constant_lut(0.5)));
    let g = graph(|g, ids| {
        let first = g.steps()[0].id;
        g.update(first, |s| s.lut = Some(LUTRef::File { path: "/a.cube".into() }));
        let p = g.add_step(None, StepKind::Parallel, ids);
        g.update(p, |s| s.lut = Some(LUTRef::File { path: "/b.cube".into() }));
        let q = g.add_step(Some(p), StepKind::Parallel, ids);
        g.update(q, |s| s.primaries = primaries(3.0));
    });
    let t = tags(&g, Some(&provider));
    assert_eq!(t.iter().filter(|x| *x == "look").count(), 1, "a second LUT cannot share the pass");
    assert!(t.contains(&"merge2".to_string()), "head and the third branch stay");
}

fn pipe(g: &ColorGraph) -> ColorPipeline {
    let mut ops = vec![ColorOp::Conversion(None)];
    ops.extend(graph_ops(g, None));
    ColorPipeline::new(S::Rec709, ops, ToneMapping::default())
}

fn single(s: ColorStep) -> ColorPipeline {
    let g = ColorGraph::new(vec![s], None, None, Id::fixed(1));
    pipe(&g)
}

fn step(label: &str, k: f32) -> ColorStep {
    let mut s = ColorStep::new(Id::fixed(k as u64 + 100), label);
    s.primaries = primaries(k);
    s
}

const PX: Vec3 = Vec3::new(0.3, 0.5, 0.7);

fn max_abs(a: Vec3, b: Vec3) -> f32 {
    (a - b).map(f32::abs).max_elem()
}

#[test]
fn mix_blends_the_step_with_its_input() {
    let mut s = step("A", 2.0);
    let plain = ColorPipeline::new(S::Rec709, vec![ColorOp::Conversion(None)], ToneMapping::default()).process(PX);
    let full = single(s.clone()).process(PX);
    s.mix = 25.0;
    let quarter = single(s).process(PX);
    let (dp, df) = (plain.map(oetf), full.map(oetf));
    let expected = (dp + (df - dp) * 0.25).map(inv);
    assert!(max_abs(quarter, expected) < 1e-4, "the blend happens on the display signal");
}

#[test]
fn parallel_averages_the_branches() {
    let (a, mut b) = (step("A", 2.0), step("B", 5.0));
    b.kind = StepKind::Parallel;
    let g = ColorGraph::new(vec![a.clone(), b.clone()], None, None, Id::fixed(1));
    b.kind = StepKind::Serial;
    let (da, db) = (single(a).process(PX).map(oetf), single(b).process(PX).map(oetf));
    assert!(max_abs(pipe(&g).process(PX), ((da + db) * 0.5).map(inv)) < 1e-4);
}

#[test]
fn layer_replaces_without_a_key_and_follows_the_key_with_one() {
    let a = step("A", 2.0);
    let mut l = step("L", 6.0);
    l.kind = StepKind::Layer;
    let g = |l: &ColorStep| ColorGraph::new(vec![a.clone(), l.clone()], None, None, Id::fixed(1));
    let mut alone = l.clone();
    alone.kind = StepKind::Serial;
    let only_layer = single(alone).process(PX);
    assert!(max_abs(pipe(&g(&l)).process(PX), only_layer) < 1e-5, "no key: the layer replaces the column");
    // A qualifier that misses the pixel keeps the column's result.
    l.qualifier = Some(ColorQualifier {
        hue_center: 30.0,
        hue_width: 10.0,
        sat_min: 90.0,
        softness: 0.0,
        ..ColorQualifier::default()
    });
    assert!(max_abs(pipe(&g(&l)).process(PX), single(a.clone()).process(PX)) < 1e-5);
    // Mix 50 of a keyless layer: halfway between the column and the layer.
    l.qualifier = None;
    l.mix = 50.0;
    let half = pipe(&g(&l)).process(PX);
    let (da, dl) = (single(a).process(PX).map(oetf), only_layer.map(oetf));
    assert!(max_abs(half, ((da + dl) * 0.5).map(inv)) < 1e-4);
}

#[test]
fn window_limits_the_step() {
    let step_ops = vec![
        ColorOp::Conversion(None),
        ColorOp::StepBegin,
        ColorOp::Primaries(primaries(2.0)),
        ColorOp::StepEnd { qualifier: None, window: Some(window(StepWindowShape::Ellipse)), mix: 1.0 },
    ];
    let plain = ColorPipeline::new(S::Rec709, vec![ColorOp::Conversion(None)], ToneMapping::default());
    let limited = ColorPipeline::new(S::Rec709, step_ops, ToneMapping::default());
    let full = ColorPipeline::new(
        S::Rec709,
        vec![ColorOp::Conversion(None), ColorOp::Primaries(primaries(2.0))],
        ToneMapping::default(),
    );
    let (center, corner) = ([0.45, 0.55], [0.02, 0.02]);
    let at = |p: &ColorPipeline, uv| p.process_at(PX, uv, 16.0 / 9.0);
    assert!(dist(at(&limited, center), at(&full, center)) < 1e-6);
    assert!(dist(at(&limited, corner), at(&plain, corner)) < 1e-6);
}

// MARK: key wires and Layer mix (ColorGraphKeyTests)

const INSIDE: [f32; 2] = [0.45, 0.55];
const OUTSIDE: [f32; 2] = [0.02, 0.02];

fn run(g: &ColorGraph, uv: [f32; 2]) -> Vec3 {
    pipe(g).process_at(PX, uv, 16.0 / 9.0)
}

fn near(a: Vec3, b: Vec3, tol: f32) -> bool {
    max_abs(a, b) < tol
}

fn default_graph() -> ColorGraph {
    ColorGraph::new(Vec::new(), None, None, Id::fixed(1))
}

fn plain_b() -> ColorGraph {
    let mut g = default_graph();
    let first = g.steps()[0].id;
    g.update(first, |s| s.primaries = primaries(3.0));
    g
}

fn keyed_step(outside: bool, q: Option<ColorQualifier>) -> ColorGraph {
    let mut ids = SequentialIds::default();
    let mut g = ColorGraph::new(Vec::new(), None, None, ids.next_id());
    let d = g.steps()[0].id;
    g.update(d, |s| {
        s.window = Some(window(StepWindowShape::Ellipse));
        s.key_outside = outside;
        s.qualifier = q;
    });
    let b = g.add_step(Some(d), StepKind::Serial, &mut ids);
    g.update(b, |s| s.primaries = primaries(3.0));
    assert!(g.connect_key(d, GraphPort::Step(b)).is_none());
    g
}

#[test]
fn graphs_without_keys_lower_and_render_as_before() {
    let mut ids = SequentialIds::default();
    let mut g = ColorGraph::new(Vec::new(), None, None, ids.next_id());
    let first = g.steps()[0].id;
    g.update(first, |s| {
        s.primaries = primaries(2.0);
        s.window = Some(window(StepWindowShape::Ellipse));
    });
    let b = g.add_step(None, StepKind::Serial, &mut ids);
    g.update(b, |s| {
        s.primaries = primaries(4.0);
        s.mix = 50.0;
    });
    let kinds: Vec<String> = graph_ops(&g, None).iter().map(tag).collect();
    assert_eq!(kinds, ["begin", "prim", "end", "begin", "prim", "endMix"]);
    let hand = vec![
        ColorOp::Conversion(None),
        ColorOp::StepBegin,
        ColorOp::Primaries(primaries(2.0)),
        ColorOp::StepEnd { qualifier: None, window: Some(window(StepWindowShape::Ellipse)), mix: 1.0 },
        ColorOp::StepBegin,
        ColorOp::Primaries(primaries(4.0)),
        ColorOp::StepEnd { qualifier: None, window: None, mix: 0.5 },
    ];
    let old = ColorPipeline::new(S::Rec709, hand, ToneMapping::default());
    for uv in [INSIDE, OUTSIDE] {
        assert_eq!(pipe(&g).process_at(PX, uv, 2.0), old.process_at(PX, uv, 2.0), "bit for bit");
    }
}

#[test]
fn a_step_key_limits_the_step_it_feeds() {
    let g = keyed_step(false, None);
    let (plain, full) = (run(&default_graph(), INSIDE), run(&plain_b(), INSIDE));
    assert!(near(run(&g, INSIDE), full, 1e-4), "inside the donor's window the Step shows fully");
    assert!(near(run(&g, OUTSIDE), plain, 1e-4), "outside the window the Step shows nothing");
    assert!(!near(full, plain, 1e-4));
    let inv_key = keyed_step(true, None);
    assert!(near(run(&inv_key, INSIDE), run(&default_graph(), INSIDE), 1e-4));
    assert!(near(run(&inv_key, OUTSIDE), run(&plain_b(), OUTSIDE), 1e-4));
}

#[test]
fn a_donor_qualifier_limits_by_color_and_a_disabled_donor_gives_no_key() {
    let q =
        ColorQualifier { hue_center: 30.0, hue_width: 10.0, sat_min: 90.0, softness: 0.0, ..ColorQualifier::default() };
    let g = keyed_step(false, Some(q.clone()));
    assert!(near(run(&g, INSIDE), run(&default_graph(), INSIDE), 1e-4), "the qualifier selects nothing: no effect");
    let hit = keyed_step(true, Some(q));
    assert!(near(run(&hit, OUTSIDE), run(&plain_b(), OUTSIDE), 1e-4));
    let mut g = keyed_step(false, None);
    let first = g.steps()[0].id;
    g.update(first, |s| s.enabled = false);
    assert!(near(run(&g, OUTSIDE), run(&plain_b(), OUTSIDE), 1e-4));
}

fn mixed(mode: KeyMixMode) -> ColorGraph {
    let mut ids = SequentialIds::default();
    let mut g = ColorGraph::new(Vec::new(), None, None, ids.next_id());
    let d1 = g.steps()[0].id;
    g.update(d1, |s| s.window = Some(window(StepWindowShape::Ellipse)));
    let d2 = g.add_step(Some(d1), StepKind::Serial, &mut ids);
    g.update(d2, |s| {
        s.window = Some(window(StepWindowShape::Ellipse));
        s.key_outside = true;
    });
    let a = g.add_step(Some(d2), StepKind::Serial, &mut ids);
    g.update(a, |s| {
        s.primaries = primaries(3.0);
        s.key_mix = mode;
    });
    let p = g.add_step(Some(a), StepKind::Parallel, &mut ids);
    g.update(p, |s| s.primaries = primaries(5.0));
    assert!(g.connect_key(d1, GraphPort::Mixer(a)).is_none());
    assert!(g.connect_key(d2, GraphPort::Mixer(a)).is_none());
    g
}

#[test]
fn keys_into_a_mixer_combine_and_limit_the_stack() {
    let mut stack = mixed(KeyMixMode::Multiply);
    stack.key_links.clear();
    assert!(!near(run(&stack, INSIDE), run(&default_graph(), INSIDE), 1e-4));
    // d1 = window, d2 = 1 - window. Inside: (1, 0). Outside: (0, 1).
    for (mode, k_in, k_out) in [
        (KeyMixMode::Add, 1.0, 1.0),
        (KeyMixMode::Multiply, 0.0, 0.0),
        (KeyMixMode::Subtract, 1.0, 0.0),
        (KeyMixMode::Max, 1.0, 1.0),
    ] {
        let g = mixed(mode);
        for (uv, k) in [(INSIDE, k_in), (OUTSIDE, k_out)] {
            let (full, none) = (run(&stack, uv), run(&default_graph(), uv));
            let (df, dn) = (full.map(oetf), none.map(oetf));
            let want = (dn + (df - dn) * k).map(inv);
            assert!(near(run(&g, uv), want, 2e-4), "{mode:?} at {uv:?}");
        }
    }
}

fn layer_graph(mode: LayerMixMode, mix: f32) -> ColorGraph {
    let a = step("A", 2.0);
    let mut l = step("L", 6.0);
    l.kind = StepKind::Layer;
    l.layer_mix = mode;
    l.mix = mix;
    ColorGraph::new(vec![a, l], None, None, Id::fixed(1))
}

#[test]
fn layer_mix_composites_over_the_result_below() {
    let below = run(&ColorGraph::new(vec![step("A", 2.0)], None, None, Id::fixed(1)), INSIDE).map(oetf);
    let top = run(&ColorGraph::new(vec![step("L", 6.0)], None, None, Id::fixed(1)), INSIDE).map(oetf);
    let one = Vec3::ONE;
    let cases = [
        (LayerMixMode::Normal, top),
        (LayerMixMode::Add, below + top),
        (LayerMixMode::Subtract, below - top),
        (LayerMixMode::Multiply, below * top),
        (LayerMixMode::Screen, one - (one - below) * (one - top)),
        (LayerMixMode::Lighten, below.max(top)),
        (LayerMixMode::Darken, below.min(top)),
    ];
    for (mode, want) in cases {
        assert!(near(run(&layer_graph(mode, 100.0), INSIDE), want.map(inv), 2e-4), "{mode:?}");
        // The Step's Mix is the strength: half way between the result below and the composite.
        let half = (below + (want - below) * 0.5).map(inv);
        assert!(near(run(&layer_graph(mode, 50.0), INSIDE), half, 2e-4), "{mode:?} at Mix 50");
    }
}

#[test]
fn a_layer_key_from_another_step_controls_the_strength() {
    let mut ids = SequentialIds::default();
    let mut g = ColorGraph::new(Vec::new(), None, None, ids.next_id());
    let d = g.steps()[0].id;
    g.update(d, |s| s.window = Some(window(StepWindowShape::Ellipse)));
    let a = g.add_step(Some(d), StepKind::Serial, &mut ids);
    g.update(a, |s| s.primaries = primaries(2.0));
    let l = g.add_step(Some(a), StepKind::Layer, &mut ids);
    g.update(l, |s| {
        s.primaries = primaries(6.0);
        s.layer_mix = LayerMixMode::Multiply;
    });
    assert!(g.connect_key(d, GraphPort::Step(l)).is_none());
    let mut plain = g.clone();
    plain.key_links.clear();
    assert!(near(run(&g, INSIDE), run(&plain, INSIDE), 1e-4), "full strength inside the window");
    let mut col_only = plain.clone();
    col_only.update(l, |s| s.enabled = false);
    assert!(near(run(&g, OUTSIDE), run(&col_only, OUTSIDE), 1e-4), "no layer outside the window");
}
