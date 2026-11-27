// Swift: LayerColorResolver.swift
//! Turns a layer's `ClipColor` + its media into the `ColorPipeline` the compositor needs. Shared by playback and export.
//!
//! Returns `None` (identity fast path) when the layer is plain Rec.709 with no correction and no LUT: the compositor then
//! takes its cheap inverse-OETF path and never allocates the color intermediate.
//!
//! Two levels, so a keyframed grade (a new `ClipColor` every frame) neither lags behind the playhead nor floods a cache:
//! - The LUTs a grade references (the static part: Input LUTs, look LUTs, the automatic camera LUT) are loaded once per
//!   distinct LUT set and media, and cached. Loading reads and parses files, so it never happens on the render thread:
//!   `pipeline` schedules it in the background on a miss and serves the owner's previous pipeline until `on_warmed` fires
//!   (the engine answers with a redraw). `warm` (timeline push) re-checks file LUT stamps, so an edited `.cube` is reloaded,
//!   and retries LUTs that failed. `pipeline_blocking` (export) loads inline.
//! - The pipeline itself (the numbers: sliders, wheels, curves, vignette; uploaded as uniforms) is assembled from those
//!   cached LUTs without I/O whenever the grade changes, and remembered per owner so an unchanged grade costs one comparison.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use sq_core_color::ClipColorExt;
use sq_core_model::{ClipColor, ColorSpaceID, LUTRef, LogMode, MediaInfo};
use sq_core_time::Id;

use crate::color::CubeLut;
use crate::color::clip_pipeline::{LutProvider, LutStamp, effective_source, pipeline_from_clip_color};
use crate::color::pipeline::ColorPipeline;

/// Looks up the project's info of a media item.
pub type MediaInfoLookup = Arc<dyn Fn(Id) -> Option<MediaInfo> + Send + Sync>;

const CACHE_LIMIT: usize = 256;
/// Owners whose last pipeline is remembered.
const SERVED_LIMIT: usize = 4 * CACHE_LIMIT;
const FAILURE_RETRY: Duration = Duration::from_secs(2);

/// The static part of a layer's color: which LUTs it needs, for which media. `refs` is sorted: Step order does not change
/// what is cached.
#[derive(Clone, PartialEq, Eq, Hash)]
struct LutKey {
    refs: Vec<LUTRef>,
    media: Id,
    embedded_lut: Option<String>,
}

#[derive(Clone)]
struct LutEntry {
    luts: HashMap<LUTRef, Arc<CubeLut>>,
    /// Stamps of the file LUTs the entry was loaded from.
    stamps: HashMap<LUTRef, LutStamp>,
    /// Set when a referenced LUT failed to load: the entry is degraded and is reloaded after this date or on the next warm.
    retry_after: Option<Instant>,
    /// New on every load, so a pipeline assembled from an older load is rebuilt.
    generation: u64,
}

/// The pipeline last served for an owner, with what it was assembled from.
struct Served {
    color: ClipColor,
    media: Id,
    space: Option<ColorSpaceID>,
    generation: u64,
    pipeline: Option<Arc<ColorPipeline>>,
    /// `State::clock` when last served or assembled (eviction drops the least recently used owners first).
    last_use: u64,
}

impl Served {
    fn matches(&self, c: &ClipColor, m: Id, info: Option<&MediaInfo>, generation: u64) -> bool {
        self.generation == generation
            && self.media == m
            && self.space == info.and_then(|i| i.detected_color_space)
            && self.color == *c
    }
}

#[derive(Default)]
struct State {
    entries: HashMap<LutKey, LutEntry>,
    inflight: HashSet<LutKey>,
    /// Last served pipeline per owner (the clip, else the media): reused while the grade is unchanged and drawn while the LUTs
    /// of a changed grade are still loading.
    served: HashMap<Id, Served>,
    clock: u64,
    /// Keys in load order (oldest first) for eviction.
    order: Vec<LutKey>,
    generation: u64,
    on_warmed: Option<Arc<dyn Fn() + Send + Sync>>,
}

impl State {
    fn touch(&mut self, slot: Id) {
        if self.served.contains_key(&slot) {
            self.clock += 1;
            let clock = self.clock;
            if let Some(s) = self.served.get_mut(&slot) {
                s.last_use = clock;
            }
        }
    }
}

struct Inner {
    lut_provider: Option<Arc<dyn LutProvider>>,
    media_info: MediaInfoLookup,
    /// An HDR delivery export: HLG / PQ sources keep their range above SDR white (Swift `TimelineFrameSource`, `hdrOutput`).
    hdr_output: bool,
    state: Mutex<State>,
}

impl Inner {
    fn state(&self) -> MutexGuard<'_, State> {
        let t = sq_gpu::gpu::timing::sub_start();
        let guard = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        sq_gpu::gpu::timing::sub_add(sq_gpu::gpu::timing::Sub::ColorLock, t);
        guard
    }
}

enum Lookup {
    Served(Option<Arc<ColorPipeline>>),
    Entry(LutEntry),
    Miss(Option<Arc<ColorPipeline>>),
}

/// See the module docs.
pub struct LayerColorResolver {
    inner: Arc<Inner>,
}

impl LayerColorResolver {
    pub fn new(lut_provider: Option<Arc<dyn LutProvider>>, media_info: MediaInfoLookup) -> LayerColorResolver {
        Self::with_hdr_output(lut_provider, media_info, false)
    }

    /// A resolver for an export; `hdr_output`: the file is HLG / PQ, so HDR sources are not tone-mapped down to SDR.
    pub fn with_hdr_output(
        lut_provider: Option<Arc<dyn LutProvider>>,
        media_info: MediaInfoLookup,
        hdr_output: bool,
    ) -> LayerColorResolver {
        LayerColorResolver {
            inner: Arc::new(Inner { lut_provider, media_info, hdr_output, state: Mutex::new(State::default()) }),
        }
    }

    /// The project's info of `media`: the engines read the item's pixel aspect from it. Never does I/O.
    pub fn info_of(&self, media: Id) -> Option<MediaInfo> {
        (self.inner.media_info)(media)
    }

    /// Called (on a background thread) after a background load finished; the engine redraws.
    pub fn set_on_warmed(&self, f: Option<Arc<dyn Fn() + Send + Sync>>) {
        self.inner.state().on_warmed = f;
    }

    /// `None` = identity Rec.709 (use the fast path). Never does I/O. While the LUTs of a changed grade are still loading,
    /// the pipeline last served for the same `owner` (the clip; the media when `None`) keeps drawing: with `owner` a clip
    /// never shows another clip's grade of the same media.
    pub fn pipeline(&self, color: &ClipColor, media: Id, owner: Option<Id>) -> Option<Arc<ColorPipeline>> {
        let info = (self.inner.media_info)(media);
        let key = lut_key(color, media, info.as_ref())?;
        let slot = owner.unwrap_or(media);
        // No LUTs: nothing to read from disk, so the grade is assembled on the spot (never a frame behind).
        if key.refs.is_empty() {
            return self.pipeline_blocking(color, media, owner);
        }
        let (found, due) = {
            let mut s = self.inner.state();
            match s.entries.get(&key).cloned() {
                None => {
                    s.touch(slot);
                    (Lookup::Miss(s.served.get(&slot).and_then(|p| p.pipeline.clone())), true)
                }
                Some(e) => {
                    let due = e.retry_after.is_some_and(|t| t <= Instant::now());
                    if s.served.get(&slot).is_some_and(|p| p.matches(color, media, info.as_ref(), e.generation)) {
                        s.touch(slot);
                        (Lookup::Served(s.served.get(&slot).and_then(|p| p.pipeline.clone())), due)
                    } else {
                        (Lookup::Entry(e), due)
                    }
                }
            }
        };
        if due {
            self.schedule(&key, media, false);
        }
        match found {
            Lookup::Served(p) | Lookup::Miss(p) => p,
            Lookup::Entry(e) => assemble(&self.inner, color, media, info.as_ref(), &e, slot),
        }
    }

    /// Loads inline and caches (export, tests). Never returns a stale entry for edited LUT files.
    pub fn pipeline_blocking(&self, color: &ClipColor, media: Id, owner: Option<Id>) -> Option<Arc<ColorPipeline>> {
        use sq_gpu::gpu::timing::{Sub, sub_add, sub_start};
        let t = sub_start();
        let info = (self.inner.media_info)(media);
        sub_add(Sub::GradeInfo, t);
        let key = lut_key(color, media, info.as_ref())?;
        let t = sub_start();
        let entry = load(&self.inner, &key, media, false);
        sub_add(Sub::GradeLoad, t);
        let slot = owner.unwrap_or(media);
        let hit = {
            let mut s = self.inner.state();
            let hit = s
                .served
                .get(&slot)
                .filter(|p| p.matches(color, media, info.as_ref(), entry.generation))
                .map(|p| p.pipeline.clone());
            if hit.is_some() {
                s.touch(slot);
            }
            hit
        };
        match hit {
            Some(p) => p,
            None => {
                let t = sub_start();
                let built = assemble(&self.inner, color, media, info.as_ref(), &entry, slot);
                sub_add(Sub::GradeAssemble, t);
                built
            }
        }
    }

    /// Schedules background LUT loads for the given layers (timeline push / color change).
    pub fn warm(&self, layers: &[(ClipColor, Id)]) {
        let mut seen = HashSet::new();
        for (color, media) in layers {
            let Some(key) = lut_key(color, *media, (self.inner.media_info)(*media).as_ref()) else { continue };
            if seen.insert(key.clone()) {
                self.schedule(&key, *media, true);
            }
        }
    }

    /// Drops cached LUTs (media relinked, project opened). The last served pipelines stay as fallbacks.
    pub fn invalidate(&self) {
        let mut s = self.inner.state();
        s.entries.clear();
        s.order.clear();
    }

    /// Waits for running background loads (tests).
    pub fn wait_until_idle(&self) {
        while !self.inner.state().inflight.is_empty() {
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    /// Cached LUT sets (tests).
    pub fn cached_count(&self) -> usize {
        self.inner.state().entries.len()
    }

    /// Owners with a remembered pipeline (tests).
    pub fn served_count(&self) -> usize {
        self.inner.state().served.len()
    }

    fn schedule(&self, key: &LutKey, media: Id, force: bool) {
        if !self.inner.state().inflight.insert(key.clone()) {
            return;
        }
        let (inner, key) = (Arc::clone(&self.inner), key.clone());
        std::thread::spawn(move || {
            load(&inner, &key, media, force);
            let notify = inner.state().on_warmed.clone();
            if let Some(f) = notify {
                f();
            }
            inner.state().inflight.remove(&key);
        });
    }
}

fn sort_key(r: &LUTRef) -> String {
    match r {
        LUTRef::Automatic => "a".into(),
        LUTRef::File { path } => format!("f{path}"),
        LUTRef::Embedded { media } => format!("e{media:?}"),
    }
}

/// `None` when the layer needs no pipeline. Otherwise the LUTs its enabled sections reference (the automatic Input LUT
/// resolved to the media's embedded LUT where `pipeline_from_clip_color` would use it), independent of every number.
fn lut_key(color: &ClipColor, media: Id, info: Option<&MediaInfo>) -> Option<LutKey> {
    use sq_core_model::ColorSectionKind::{BasicCorrection, Creative};
    let source = effective_source(color, info.map(MediaInfo::color_space));
    // Default settings on Rec.709 media: nothing to do (automatic embedded LUT applies to S-Log3 only).
    if color.is_identity(source == ColorSpaceID::Rec709) {
        return None;
    }
    let uses_input_lut = color.log_mode == LogMode::CameraLUT;
    let mut refs: Vec<LUTRef> = Vec::new();
    let mut add = |r: LUTRef| {
        if !refs.contains(&r) {
            refs.push(r);
        }
    };
    for (n, e) in color.effects().iter().enumerate() {
        if e.is_enabled(BasicCorrection) && (n > 0 || uses_input_lut) {
            match &e.input_lut {
                Some(r @ (LUTRef::File { .. } | LUTRef::Embedded { .. })) => add(r.clone()),
                Some(LUTRef::Automatic)
                    if n == 0
                        && color.use_embedded_lut
                        && info.is_some_and(|i| i.embedded_lut_name.is_some())
                        && source == ColorSpaceID::SLog3SGamut3Cine =>
                {
                    add(LUTRef::Embedded { media });
                }
                Some(LUTRef::Automatic) | None => {}
            }
        }
        if e.is_enabled(Creative)
            && color.graph.is_none()
            && let Some(r) = e.creative.look.as_ref().filter(|r| **r != LUTRef::Automatic)
        {
            add(r.clone());
        }
    }
    if let Some(g) = &color.graph {
        for s in g.steps().iter().filter(|s| s.enabled) {
            if let Some(r) = s.lut.as_ref().filter(|r| **r != LUTRef::Automatic) {
                add(r.clone());
            }
        }
        if let Some(r) = g.output_lut.as_ref().filter(|r| **r != LUTRef::Automatic) {
            add(r.clone());
        }
    }
    refs.sort_by_key(sort_key);
    Some(LutKey { refs, media, embedded_lut: info.and_then(|i| i.embedded_lut_name.clone()) })
}

/// Serves already loaded LUTs (no I/O); a missing one is treated as absent, like a failed load.
struct LoadedLuts(HashMap<LUTRef, Arc<CubeLut>>);

impl LutProvider for LoadedLuts {
    fn lut(&self, r: &LUTRef) -> Option<Arc<CubeLut>> {
        self.0.get(r).cloned()
    }
}

/// Builds the pipeline from loaded LUTs (no I/O) and remembers it for `slot`.
fn assemble(
    inner: &Inner,
    color: &ClipColor,
    media: Id,
    info: Option<&MediaInfo>,
    entry: &LutEntry,
    slot: Id,
) -> Option<Arc<ColorPipeline>> {
    let provider = LoadedLuts(entry.luts.clone());
    let mut built = pipeline_from_clip_color(color, media, info, Some(&provider));
    if inner.hdr_output && matches!(built.source(), ColorSpaceID::HlgBT2020 | ColorSpaceID::PqBT2020) {
        built.set_skips_tone_map(true);
    }
    let result = (!built.is_identity()).then(|| Arc::new(built));
    let mut s = inner.state();
    s.clock += 1;
    let last_use = s.clock;
    s.served.insert(
        slot,
        Served {
            color: color.clone(),
            media,
            space: info.and_then(|i| i.detected_color_space),
            generation: entry.generation,
            pipeline: result.clone(),
            last_use,
        },
    );
    // Full: drop the least recently used quarter, never everything (every visible layer would lose the fallback it draws
    // while a changed grade's LUTs load, and flash ungraded).
    if s.served.len() > SERVED_LIMIT {
        let mut by_use: Vec<(u64, Id)> = s.served.iter().map(|(k, v)| (v.last_use, *k)).collect();
        by_use.sort();
        for (_, k) in by_use.into_iter().take(SERVED_LIMIT / 4) {
            s.served.remove(&k);
        }
    }
    result
}

/// `force`: re-check file stamps and retry failed LUTs even when an entry exists.
fn load(inner: &Inner, key: &LutKey, media: Id, force: bool) -> LutEntry {
    let stamps: HashMap<LUTRef, LutStamp> = key
        .refs
        .iter()
        .filter(|r| matches!(r, LUTRef::File { .. }))
        .filter_map(|r| inner.lut_provider.as_ref().and_then(|p| p.stamp(r)).map(|st| (r.clone(), st)))
        .collect();
    let cached = inner.state().entries.get(key).cloned();
    if let Some(e) = cached
        && e.stamps == stamps
        && e.retry_after.is_none_or(|t| !force && t > Instant::now())
    {
        return e;
    }
    let mut luts = HashMap::new();
    let mut failed = false;
    for r in &key.refs {
        match inner.lut_provider.as_ref().and_then(|p| p.lut(r)) {
            Some(l) => {
                luts.insert(r.clone(), l);
            }
            None => failed = true,
        }
    }
    if std::env::var("SQ_COLOR_LOG").is_ok_and(|v| v == "1") {
        sq_os::errln!(
            "COLOR: media={media:?} luts={}/{}{}",
            luts.len(),
            key.refs.len(),
            if failed { " (LUT failed)" } else { "" }
        );
    }
    let mut s = inner.state();
    // Full: drop the oldest quarter, not everything (every visible layer would otherwise miss at once).
    if s.entries.len() >= CACHE_LIMIT {
        let drop: Vec<LutKey> = s.order.iter().take(CACHE_LIMIT / 4).cloned().collect();
        for k in &drop {
            s.entries.remove(k);
        }
        let n = drop.len().min(s.order.len());
        s.order.drain(..n);
    }
    if !s.entries.contains_key(key) {
        s.order.push(key.clone());
    }
    s.generation += 1;
    let e = LutEntry {
        luts,
        stamps,
        retry_after: failed.then(|| Instant::now() + FAILURE_RETRY),
        generation: s.generation,
    };
    s.entries.insert(key.clone(), e.clone());
    e
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color::CubeKind;
    use crate::color::vec::Vec3;
    use sq_core_model::{ColorGraph, ColorSectionKind, ColorStep};

    fn constant_lut(v: f32, title: &str) -> Arc<CubeLut> {
        let table = vec![Vec3::splat(v); 8];
        Arc::new(
            CubeLut::new(title, CubeKind::Lut3D, 2, (Vec3::ZERO, Vec3::ONE), table, (false, false)).expect("table"),
        )
    }

    /// LUT provider whose contents and file stamps tests can change; counts lookups.
    #[derive(Default)]
    struct MutableProvider {
        table: Mutex<HashMap<LUTRef, Arc<CubeLut>>>,
        stamps: Mutex<HashMap<LUTRef, LutStamp>>,
        lookups: Mutex<usize>,
    }

    impl MutableProvider {
        fn set(&self, r: &LUTRef, lut: Option<Arc<CubeLut>>, stamp: Option<LutStamp>) {
            let mut t = self.table.lock().unwrap_or_else(PoisonError::into_inner);
            match lut {
                Some(l) => t.insert(r.clone(), l),
                None => t.remove(r),
            };
            let mut s = self.stamps.lock().unwrap_or_else(PoisonError::into_inner);
            match stamp {
                Some(st) => s.insert(r.clone(), st),
                None => s.remove(r),
            };
        }

        fn lookups(&self) -> usize {
            *self.lookups.lock().unwrap_or_else(PoisonError::into_inner)
        }
    }

    impl LutProvider for MutableProvider {
        fn lut(&self, r: &LUTRef) -> Option<Arc<CubeLut>> {
            *self.lookups.lock().unwrap_or_else(PoisonError::into_inner) += 1;
            self.table.lock().unwrap_or_else(PoisonError::into_inner).get(r).cloned()
        }

        fn stamp(&self, r: &LUTRef) -> Option<LutStamp> {
            self.stamps.lock().unwrap_or_else(PoisonError::into_inner).get(r).copied()
        }
    }

    fn media_info(space: ColorSpaceID, embedded: Option<&str>) -> MediaInfo {
        let mut v = serde_json::json!({"duration": {"value": 1, "timescale": 1}, "detectedColorSpace": null});
        v["embeddedLUTName"] = embedded.map_or(serde_json::Value::Null, |e| e.into());
        let mut info: MediaInfo = serde_json::from_value(v).expect("media info");
        info.detected_color_space = Some(space);
        info
    }

    const SLOG: Id = Id::from_u128(1);
    const REC709: Id = Id::from_u128(2);

    fn make(provider: Option<Arc<MutableProvider>>, embedded: Option<&str>) -> LayerColorResolver {
        let slog = media_info(ColorSpaceID::SLog3SGamut3Cine, embedded);
        let plain = media_info(ColorSpaceID::Rec709, None);
        let lookup: MediaInfoLookup = Arc::new(move |m| match m {
            SLOG => Some(slog.clone()),
            REC709 => Some(plain.clone()),
            _ => None,
        });
        LayerColorResolver::new(provider.map(|p| p as Arc<dyn LutProvider>), lookup)
    }

    fn with_look(look: &LUTRef) -> ClipColor {
        let mut c = ClipColor::default();
        c.edit_effects(|e| e[0].creative.look = Some(look.clone()));
        c
    }

    fn with_exposure(mut c: ClipColor, exposure: f32) -> ClipColor {
        c.edit_effects(|e| e[0].basic.exposure = exposure);
        c
    }

    #[test]
    fn identity_rec709_takes_the_fast_path() {
        let r = make(None, None);
        assert!(r.pipeline(&ClipColor::default(), REC709, None).is_none());
        assert!(r.pipeline(&ClipColor::default(), Id::from_u128(99), None).is_none()); // unknown media = Rec.709
        assert_eq!(r.cached_count(), 0); // no work, no cache
        let mut c = ClipColor::default();
        c.edit_effects(|e| {
            e[0].basic.exposure = 1.0;
            e[0].set_enabled(ColorSectionKind::BasicCorrection, false);
        });
        assert!(r.pipeline_blocking(&c, REC709, None).is_none()); // disabled correction is identity
    }

    #[test]
    fn reordering_graph_steps_keeps_the_lut_cache_entry() {
        let p = Arc::new(MutableProvider::default());
        let (a, b) = (LUTRef::File { path: "/a.cube".into() }, LUTRef::File { path: "/b.cube".into() });
        p.set(&a, Some(constant_lut(0.2, "a")), None);
        p.set(&b, Some(constant_lut(0.6, "b")), None);
        let grade = |order: [&LUTRef; 2]| {
            let steps = order
                .iter()
                .enumerate()
                .map(|(i, l)| {
                    let mut s = ColorStep::new(Id::from_u128(10 + i as u128), "S");
                    s.lut = Some((*l).clone());
                    s
                })
                .collect();
            let mut g = ColorGraph::new(steps, None, None, Id::from_u128(9));
            g.is_active = true;
            let mut c = ClipColor::default();
            c.graph = Some(g);
            c
        };
        let r = make(Some(p), None);
        r.pipeline(&grade([&a, &b]), SLOG, None);
        r.wait_until_idle();
        r.pipeline(&grade([&b, &a]), SLOG, None);
        r.wait_until_idle();
        assert_eq!(r.cached_count(), 1, "same LUT set in another Step order is the same cache entry");
    }

    #[test]
    fn lookup_never_builds_on_the_calling_thread() {
        let p = Arc::new(MutableProvider::default());
        let x = LUTRef::File { path: "/x.cube".into() };
        let mut c = ClipColor::default();
        c.edit_effects(|e| e[0].input_lut = Some(x.clone()));
        c.log_mode = LogMode::CameraLUT;
        p.set(&x, Some(constant_lut(0.5, "x")), None);
        let r = make(Some(p), None);
        assert!(r.pipeline(&c, SLOG, None).is_none()); // miss: identity until warm
        r.wait_until_idle();
        assert_eq!(
            r.pipeline(&c, SLOG, None).and_then(|p| p.conversion_lut().map(|l| l.title.clone())).as_deref(),
            Some("x")
        );
    }

    #[test]
    fn a_miss_returns_the_previous_pipeline_of_that_media_and_notifies_when_warm() {
        let p = Arc::new(MutableProvider::default());
        let look = LUTRef::File { path: "/look.cube".into() };
        p.set(&look, Some(constant_lut(0.5, "look")), None);
        let r = make(Some(p), None);
        let warmed = Arc::new(Mutex::new(0));
        let w = Arc::clone(&warmed);
        r.set_on_warmed(Some(Arc::new(move || *w.lock().unwrap_or_else(PoisonError::into_inner) += 1)));
        // Without LUTs nothing is read from disk: the pipeline is assembled on the spot.
        assert_eq!(
            r.pipeline(&ClipColor::default(), SLOG, None).map(|p| p.source()),
            Some(ColorSpaceID::SLog3SGamut3Cine)
        );
        let c = with_look(&look);
        let during = r.pipeline(&c, SLOG, None); // LUT not loaded yet: previous pipeline
        assert!(
            during.as_ref().is_some_and(|p| p.source() == ColorSpaceID::SLog3SGamut3Cine && p.creative_lut().is_none())
        );
        r.wait_until_idle();
        assert_eq!(*warmed.lock().unwrap_or_else(PoisonError::into_inner), 1);
        assert_eq!(
            r.pipeline(&c, SLOG, None).and_then(|p| p.creative_lut().map(|l| l.title.clone())).as_deref(),
            Some("look")
        );
    }

    /// The remembered pipeline per owner is bounded by pruning the least recently used owners, not by forgetting all of them.
    #[test]
    fn served_pruning_keeps_recently_used_owners() {
        let p = Arc::new(MutableProvider::default());
        let late = LUTRef::File { path: "/late.cube".into() };
        let r = make(Some(Arc::clone(&p)), None);
        let on_screen = Id::from_u128(5_000_000);
        let graded = with_exposure(ClipColor::default(), 1.0);
        let next_owner = std::cell::Cell::new(1_000_000u128);
        let filler = |n: usize| {
            for i in 0..n {
                let c = with_exposure(ClipColor::default(), (i % 7 + 2) as f32 / 10.0);
                next_owner.set(next_owner.get() + 1);
                r.pipeline_blocking(&c, REC709, Some(Id::from_u128(next_owner.get())));
            }
        };
        filler(SERVED_LIMIT - 2);
        assert!(r.pipeline(&graded, REC709, Some(on_screen)).is_some());
        filler(8); // overflows right after the owner was drawn
        assert!(r.served_count() <= SERVED_LIMIT);
        let changed = with_look(&late); // LUT not loaded yet: previous pipeline
        let mut changed = changed;
        changed.edit_effects(|e| e[0].basic.exposure = 1.0);
        p.set(&late, Some(constant_lut(0.5, "late")), None);
        let during = r.pipeline(&changed, REC709, Some(on_screen));
        assert!(during.as_ref().is_some_and(|p| p.creative_lut().is_none()));
        r.wait_until_idle();
    }

    /// A keyframed grade is a new `ClipColor` every frame. Each frame must render its own values at once (no lag behind the
    /// playhead) while the LUTs are loaded only once.
    #[test]
    fn keyframed_grade_frames_share_the_luts_and_render_their_own_values() {
        let p = Arc::new(MutableProvider::default());
        let look = LUTRef::File { path: "/look.cube".into() };
        p.set(&look, Some(constant_lut(0.5, "look")), None);
        let r = make(Some(Arc::clone(&p)), None);
        let frame = |exposure: f32| {
            let mut c = with_look(&look);
            c.edit_effects(|e| {
                e[0].creative.intensity = 50.0;
                e[0].basic.exposure = exposure;
            });
            c
        };
        r.warm(&[(frame(0.0), SLOG)]);
        r.wait_until_idle();
        let loads = p.lookups();
        let probe = Vec3::splat(0.4);
        let info = media_info(ColorSpaceID::SLog3SGamut3Cine, None);
        for exposure in [0.0, 0.5, 1.0, 1.5] {
            let c = frame(exposure);
            let got = r.pipeline(&c, SLOG, None).map(|p| p.process(probe));
            let expected =
                pipeline_from_clip_color(&c, SLOG, Some(&info), Some(p.as_ref() as &dyn LutProvider)).process(probe);
            assert_eq!(got, Some(expected), "exposure {exposure}");
        }
        assert_eq!(
            r.pipeline_blocking(&frame(2.0), SLOG, None)
                .and_then(|p| p.creative_lut().map(|l| l.title.clone()))
                .as_deref(),
            Some("look")
        );
        // `expected` above asked the provider 4 times; the resolver itself loaded nothing more.
        assert_eq!(p.lookups(), loads + 4);
        assert_eq!(r.cached_count(), 1);
    }

    #[test]
    fn blocking_build_caches_for_lookups() {
        let r = make(None, None);
        assert_eq!(
            r.pipeline_blocking(&ClipColor::default(), SLOG, None).map(|p| p.source()),
            Some(ColorSpaceID::SLog3SGamut3Cine)
        );
        assert_eq!(r.cached_count(), 1);
        assert!(r.pipeline(&ClipColor::default(), SLOG, None).is_some());
        r.invalidate();
        assert_eq!(r.cached_count(), 0);
    }

    #[test]
    fn a_failed_lut_is_retried_on_the_next_warm() {
        let p = Arc::new(MutableProvider::default());
        let embedded = LUTRef::Embedded { media: SLOG };
        let r = make(Some(Arc::clone(&p)), Some("Look"));
        let mut c = ClipColor::default();
        c.log_mode = LogMode::CameraLUT;
        assert!(r.pipeline_blocking(&c, SLOG, None).is_some_and(|p| p.conversion_lut().is_none())); // embedded LUT failed to load
        p.set(&embedded, Some(constant_lut(0.25, "embedded")), None);
        r.warm(&[(c.clone(), SLOG)]);
        r.wait_until_idle();
        assert_eq!(
            r.pipeline(&c, SLOG, None).and_then(|p| p.conversion_lut().map(|l| l.title.clone())).as_deref(),
            Some("embedded")
        );
    }

    #[test]
    fn an_edited_file_lut_is_reloaded_on_warm() {
        use std::time::{Duration, UNIX_EPOCH};
        let p = Arc::new(MutableProvider::default());
        let a = LUTRef::File { path: "/a.cube".into() };
        let c = with_look(&a);
        let stamp = |s| Some(LutStamp { modified: Some(UNIX_EPOCH + Duration::from_secs(s)), size: 10 });
        p.set(&a, Some(constant_lut(0.1, "v1")), stamp(1));
        let r = make(Some(Arc::clone(&p)), None);
        assert_eq!(
            r.pipeline_blocking(&c, SLOG, None).and_then(|p| p.creative_lut().map(|l| l.title.clone())).as_deref(),
            Some("v1")
        );
        p.set(&a, Some(constant_lut(0.2, "v2")), stamp(2));
        r.warm(&[(c.clone(), SLOG)]);
        r.wait_until_idle();
        assert_eq!(
            r.pipeline(&c, SLOG, None).and_then(|p| p.creative_lut().map(|l| l.title.clone())).as_deref(),
            Some("v2")
        );
    }

    #[test]
    fn a_source_override_to_rec709_is_identity() {
        let r = make(None, None);
        let mut c = ClipColor::default();
        c.source = Some(ColorSpaceID::Rec709);
        assert!(r.pipeline_blocking(&c, SLOG, None).is_none());
        c.source = Some(ColorSpaceID::HlgBT2020);
        assert_eq!(r.pipeline_blocking(&c, REC709, None).map(|p| p.source()), Some(ColorSpaceID::HlgBT2020));
    }

    #[test]
    fn source_and_program_share_the_color_pipeline() {
        // The Source and Program monitors resolve color through the same resolver: a clip (owner) and a bare media preview
        // (no owner) with the same settings give the same chain.
        let r = make(None, None);
        let program = r.pipeline_blocking(&ClipColor::default(), SLOG, Some(Id::from_u128(77)));
        let source = r.pipeline_blocking(&ClipColor::default(), SLOG, None);
        let media = r.pipeline_blocking(&ClipColor::default(), SLOG, Some(SLOG));
        assert_eq!(
            program.as_ref().map(|p| p.source()),
            Some(ColorSpaceID::SLog3SGamut3Cine),
            "a detected log source is converted"
        );
        for other in [source, media] {
            assert_eq!(other.as_ref().map(|p| p.source()), program.as_ref().map(|p| p.source()));
            for v in [0.1f32, 0.35, 0.6, 0.9] {
                let px = Vec3::new(v, v * 0.8, v * 0.6);
                assert_eq!(other.as_ref().map(|p| p.process(px)), program.as_ref().map(|p| p.process(px)));
            }
        }
        assert!(r.pipeline_blocking(&ClipColor::default(), REC709, None).is_none());
        assert!(r.pipeline_blocking(&ClipColor::default(), REC709, Some(Id::from_u128(78))).is_none());
    }
}
