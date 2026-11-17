// Swift: LottieDocument.swift (`enum LottieRenderer` with static caches is an owned struct here; the ThorVG handle sits behind
// the `LottieEngine` seam, see NOTES.md)
//! Lottie clips as portable frames: the documents, the frame timing and the 8-bit to linear conversion. The Mac turns frames
//! into CoreVideo buffers (not ported), Windows into GPU textures through `LottieRenderer::portable_frame`.
//!
//! Limits: no Lottie expressions, no text layers that rely on fonts (outlined text is fine), no 3D layers; unsupported parts
//! are skipped by the rasterizer. Colors in the file are display-encoded (BT.709 OETF) like solids and shapes and are
//! linearised with the same inverse OETF.

use crate::lottie_renderer::{LottieDrawing, LottieEngine};
use sq_core_effects::evaluation::LayerRequest;
use sq_core_graphics::lottie_generator::{GeneratorRefLottieExt, LOTTIE_KIND, LottieInfo, LottieSpec, LottieTiming};
use sq_core_model::{GeneratorRef, SequenceFormat};
use sq_core_time::Id;
use std::collections::{BTreeMap, HashMap};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

/// A drawn frame's identity: the document, the animation frame and the raster size.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct FrameKey {
    /// The document's id.
    pub doc: u64,
    /// Bit pattern of the animation frame (`f32::to_bits`).
    pub frame: u32,
    /// Raster width.
    pub width: usize,
    /// Raster height.
    pub height: usize,
}

/// One frame of a Lottie clip without CoreVideo (Windows): linear premultiplied RGBA floats, top row first.
#[derive(Clone, Debug, PartialEq)]
pub enum PortableFrame {
    /// The animation cannot be read.
    Offline,
    /// The draw failed: nothing is shown.
    Hidden,
    /// The picture. `key` names the frame (same key, same pixels) for the caller's texture cache.
    Picture {
        /// Identity of the frame.
        key: FrameKey,
        /// Width in px.
        width: usize,
        /// Height in px.
        height: usize,
        /// `width * height * 4` floats.
        pixels: Vec<f32>,
    },
}

/// A parsed animation: the spec, its header, and the rasterizer handle (used under its lock).
struct Document {
    spec: LottieSpec,
    info: LottieInfo,
    id: u64,
    handle: Mutex<Box<dyn LottieDrawing>>,
}

impl Document {
    /// Straight RGBA8 pixels of `frame` at `width` x `height`, or `None` when the rasterizer fails.
    fn render(&self, frame: f32, width: usize, height: usize) -> Option<Vec<u8>> {
        self.handle.lock().unwrap_or_else(PoisonError::into_inner).render(frame, width, height)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct DocKey {
    clip: Id,
    print: u64,
}

/// Documents kept at once: a handful of Lottie clips per project, so a simple reset beats an LRU.
const MAX_DOCUMENTS: usize = 16;

/// Byte budget of the frame cache (Swift `LottieRenderer.cacheBudget`, 256 MiB).
pub const FRAME_CACHE_BUDGET: usize = 256 << 20;

/// Drawn frames by key, least recently used out first once the bytes pass the budget. The frame just stored always stays.
struct FrameCache {
    budget: usize,
    entries: HashMap<FrameKey, (Arc<Vec<f32>>, usize, u64)>,
    bytes: usize,
    tick: u64,
}

impl FrameCache {
    fn new(budget: usize) -> FrameCache {
        FrameCache { budget, entries: HashMap::new(), bytes: 0, tick: 0 }
    }

    fn lookup(&mut self, k: &FrameKey) -> Option<Arc<Vec<f32>>> {
        self.tick += 1;
        let tick = self.tick;
        let e = self.entries.get_mut(k)?;
        e.2 = tick;
        Some(Arc::clone(&e.0))
    }

    fn store(&mut self, k: FrameKey, pixels: Arc<Vec<f32>>, bytes: usize) {
        self.tick += 1;
        if let Some(old) = self.entries.insert(k, (pixels, bytes, self.tick)) {
            self.bytes -= old.1;
        }
        self.bytes += bytes;
        while self.bytes > self.budget && self.entries.len() > 1 {
            let Some(oldest) =
                self.entries.iter().filter(|(key, _)| **key != k).min_by_key(|(_, e)| e.2).map(|(key, _)| *key)
            else {
                break;
            };
            if let Some(e) = self.entries.remove(&oldest) {
                self.bytes -= e.1;
            }
        }
    }
}

/// Lottie clips drawn through a `LottieEngine`, with the parsed documents cached per clip and content and the drawn
/// frames cached under a byte budget.
pub struct LottieRenderer {
    engine: Box<dyn LottieEngine>,
    docs: Mutex<BTreeMap<DocKey, Arc<Document>>>,
    frames: Mutex<FrameCache>,
    next_id: AtomicU64,
}

impl LottieRenderer {
    /// A renderer over `engine`.
    pub fn new(engine: Box<dyn LottieEngine>) -> LottieRenderer {
        Self::with_frame_budget(engine, FRAME_CACHE_BUDGET)
    }

    /// A renderer whose frame cache holds at most `bytes` (the newest frame stays even when it alone is larger).
    pub fn with_frame_budget(engine: Box<dyn LottieEngine>, bytes: usize) -> LottieRenderer {
        LottieRenderer {
            engine,
            docs: Mutex::new(BTreeMap::new()),
            frames: Mutex::new(FrameCache::new(bytes)),
            next_id: AtomicU64::new(1),
        }
    }

    /// Bytes of the frames cached now.
    pub fn cached_frame_bytes(&self) -> usize {
        self.frames.lock().unwrap_or_else(PoisonError::into_inner).bytes
    }

    /// Drops all cached documents (memory pressure, tests).
    pub fn clear_cache(&self) {
        self.docs.lock().unwrap_or_else(PoisonError::into_inner).clear();
        let mut f = self.frames.lock().unwrap_or_else(PoisonError::into_inner);
        *f = FrameCache::new(f.budget);
    }

    /// The key of the frame `r` shows (`None` for an unreadable file), so a cached texture can skip the draw.
    pub fn frame_key(&self, r: &LayerRequest, canvas: &SequenceFormat) -> Option<FrameKey> {
        let doc = self.document(r.generator.as_ref()?, r.clip)?;
        let (frame, w, h) = Self::placement(&doc, r, canvas);
        Some(FrameKey { doc: doc.id, frame: frame.to_bits(), width: w, height: h })
    }

    /// The picture of a Lottie layer as floats: unreadable is `Offline`, a failed draw `Hidden`.
    pub fn portable_frame(&self, r: &LayerRequest, canvas: &SequenceFormat) -> PortableFrame {
        let Some(doc) = r.generator.as_ref().and_then(|g| self.document(g, r.clip)) else {
            return PortableFrame::Offline;
        };
        let (frame, w, h) = Self::placement(&doc, r, canvas);
        let key = FrameKey { doc: doc.id, frame: frame.to_bits(), width: w, height: h };
        let hit = self.frames.lock().unwrap_or_else(PoisonError::into_inner).lookup(&key);
        let pixels = match hit {
            Some(p) => p,
            None => {
                let Some(rgba) = doc.render(frame, w, h) else { return PortableFrame::Hidden };
                let p = Arc::new(Self::linear_pixels(&rgba));
                let bytes = p.len() * std::mem::size_of::<f32>();
                self.frames.lock().unwrap_or_else(PoisonError::into_inner).store(key, Arc::clone(&p), bytes);
                p
            }
        };
        PortableFrame::Picture { key, width: w, height: h, pixels: pixels.as_ref().clone() }
    }

    /// The animation frame (from the in point) and the raster size of `r` on `canvas`.
    fn placement(doc: &Document, r: &LayerRequest, canvas: &SequenceFormat) -> (f32, usize, usize) {
        let (w, h) = LottieTiming::raster_size(&doc.info, canvas.display_width(), canvas.height);
        let frame = (LottieTiming::frame(r.local_time, &doc.info, &doc.spec) - doc.info.in_point) as f32;
        // `raster_size` clamps both sides to 1...MAX_SIDE.
        (frame, w as usize, h as usize)
    }

    /// Cheap content fingerprint of a payload (size + sampled bytes + the tail, where the play settings sit); a full hash of
    /// several MB per frame would cost more than a cached draw.
    fn fingerprint(d: &[u8]) -> u64 {
        let mut h: u64 = 0xcbf2_9ce4_8422_2325 ^ d.len() as u64;
        let mut mix = |b: u8| h = (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3);
        let n = d.len();
        let step = (n / 512).max(1);
        let mut i = 0;
        while i < n {
            mix(d[i]);
            i += step;
        }
        for &b in &d[n.saturating_sub(512)..] {
            mix(b);
        }
        h
    }

    fn document(&self, g: &GeneratorRef, clip: Id) -> Option<Arc<Document>> {
        if g.kind != LOTTIE_KIND {
            return None;
        }
        let key = DocKey { clip, print: Self::fingerprint(&g.payload) };
        if let Some(d) = self.docs.lock().unwrap_or_else(PoisonError::into_inner).get(&key) {
            return Some(Arc::clone(d));
        }
        let spec = g.lottie_spec()?;
        let info = LottieInfo::parse(&spec.json)?;
        let handle = self.engine.open(&spec.json)?;
        let doc = Arc::new(Document {
            id: self.next_id.fetch_add(1, Ordering::Relaxed),
            spec,
            info,
            handle: Mutex::new(handle),
        });
        let mut docs = self.docs.lock().unwrap_or_else(PoisonError::into_inner);
        if docs.len() >= MAX_DOCUMENTS {
            docs.clear();
        }
        docs.insert(key, Arc::clone(&doc));
        Some(doc)
    }

    /// Display-encoded 8-bit -> linear (BT.709 inverse OETF, the shape renderer's), once per value.
    fn linear_lut() -> [f32; 256] {
        std::array::from_fn(|i| {
            let e = i as f64 / 255.0;
            (if e < 0.081242858 { e / 4.5 } else { ((e + 0.09929682680944) / 1.09929682680944).powf(1.0 / 0.45) })
                as f32
        })
    }

    /// Straight display-encoded RGBA8 -> linear premultiplied RGBA floats.
    pub fn linear_pixels(rgba: &[u8]) -> Vec<f32> {
        let lut = Self::linear_lut();
        let mut out = vec![0.0f32; rgba.len()];
        let (src_px, _) = rgba.as_chunks::<4>();
        let (dst_px, _) = out.as_chunks_mut::<4>();
        for (src, dst) in src_px.iter().zip(dst_px.iter_mut()) {
            if src[3] == 0 {
                continue;
            }
            let a = f32::from(src[3]) / 255.0;
            dst[0] = lut[usize::from(src[0])] * a;
            dst[1] = lut[usize::from(src[1])] * a;
            dst[2] = lut[usize::from(src[2])] * a;
            dst[3] = a;
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_effects::evaluation::LayerRequest;
    use sq_core_time::Time;

    /// Stands in for the rasterizer: a red 20 x 20 square (in a 100 x 100 animation) that moves right with the frame.
    struct SquareEngine;

    struct SquareDrawing {
        sizes: Vec<(usize, usize)>,
    }

    impl LottieEngine for SquareEngine {
        fn open(&self, json: &[u8]) -> Option<Box<dyn LottieDrawing>> {
            json.starts_with(b"{").then(|| Box::new(SquareDrawing { sizes: Vec::new() }) as Box<dyn LottieDrawing>)
        }
    }

    impl LottieDrawing for SquareDrawing {
        fn render(&mut self, frame: f32, width: usize, height: usize) -> Option<Vec<u8>> {
            self.sizes.push((width, height));
            let mut out = vec![0u8; width * height * 4];
            let cx = (50.0 + 40.0 * frame / 29.0) * width as f32 / 100.0;
            let (cy, half) = (height as f32 / 2.0, 10.0 * width as f32 / 100.0);
            for y in 0..height {
                for x in 0..width {
                    if (x as f32 - cx).abs() <= half && (y as f32 - cy).abs() <= half {
                        out[(y * width + x) * 4..][..4].copy_from_slice(&[255, 0, 0, 255]);
                    }
                }
            }
            Some(out)
        }
    }

    /// 100 x 100, 30 frames.
    const JSON: &str =
        r#"{"v":"5.7.0","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"t","ddd":0,"assets":[],"layers":[]}"#;

    fn canvas() -> SequenceFormat {
        let mut c = SequenceFormat::new(Time::new(1, 30));
        c.width = 100;
        c.height = 100;
        c
    }

    fn request(data: &str, at: Time) -> LayerRequest {
        let spec = LottieSpec::new(data.as_bytes().to_vec(), "square.json");
        let mut r = LayerRequest::new(Id::fixed(1), Id::fixed(1), Id::fixed(3), at);
        r.generator = Some(spec.generator());
        r.local_time = at;
        r
    }

    fn alpha(p: &[f32], w: usize, x: usize, y: usize) -> f32 {
        p[(y * w + x) * 4 + 3]
    }

    #[test]
    fn draws_the_square_where_the_clip_time_says() {
        let r = LottieRenderer::new(Box::new(SquareEngine));
        let PortableFrame::Picture { key, width: w, height: h, pixels: px } =
            r.portable_frame(&request(JSON, Time::ZERO), &canvas())
        else {
            panic!("no picture");
        };
        assert!(w == 100 && h == 100 && px.len() == w * h * 4);
        assert!(px[(50 * w + 50) * 4] > 0.99 && px[(50 * w + 50) * 4 + 1] < 0.01 && alpha(&px, w, 50, 50) > 0.99);
        assert_eq!(alpha(&px, w, 5, 5), 0.0);
        assert_eq!(r.frame_key(&request(JSON, Time::ZERO), &canvas()), Some(key));
        let PortableFrame::Picture { key: late, pixels: lp, .. } =
            r.portable_frame(&request(JSON, Time::new(28, 30)), &canvas())
        else {
            panic!("no late picture");
        };
        assert_ne!(late, key);
        assert!(alpha(&lp, w, 88, 50) > 0.99);
    }

    #[test]
    fn unreadable_file_is_offline() {
        let r = LottieRenderer::new(Box::new(SquareEngine));
        assert_eq!(r.portable_frame(&request("not lottie", Time::ZERO), &canvas()), PortableFrame::Offline);
        assert_eq!(r.frame_key(&request("not lottie", Time::ZERO), &canvas()), None);
    }

    #[test]
    fn a_generator_of_another_kind_is_offline() {
        let r = LottieRenderer::new(Box::new(SquareEngine));
        let mut req = request(JSON, Time::ZERO);
        if let Some(g) = req.generator.as_mut() {
            g.kind = "text".into();
        }
        assert_eq!(r.portable_frame(&req, &canvas()), PortableFrame::Offline);
    }

    #[test]
    fn documents_are_cached_per_clip_and_content() {
        let r = LottieRenderer::new(Box::new(SquareEngine));
        let a = r.frame_key(&request(JSON, Time::ZERO), &canvas()).unwrap();
        let b = r.frame_key(&request(JSON, Time::ZERO), &canvas()).unwrap();
        assert_eq!(a.doc, b.doc);
        let mut other = request(JSON, Time::ZERO);
        other.clip = Id::fixed(2);
        assert_ne!(r.frame_key(&other, &canvas()).unwrap().doc, a.doc);
        r.clear_cache();
        assert_ne!(r.frame_key(&request(JSON, Time::ZERO), &canvas()).unwrap().doc, a.doc);
    }

    #[test]
    fn a_second_request_hits_the_frame_cache() {
        let r = LottieRenderer::new(Box::new(SquareEngine));
        let a = r.portable_frame(&request(JSON, Time::new(5, 30)), &canvas());
        let bytes = r.cached_frame_bytes();
        assert_eq!(bytes, 100 * 100 * 4 * 4);
        let b = r.portable_frame(&request(JSON, Time::new(5, 30)), &canvas());
        assert_eq!(a, b);
        assert_eq!(r.cached_frame_bytes(), bytes, "no second entry");
        r.clear_cache();
        assert_eq!(r.cached_frame_bytes(), 0);
    }

    #[test]
    fn the_frame_cache_stays_inside_its_byte_budget() {
        let one = 100 * 100 * 4 * 4;
        let r = LottieRenderer::with_frame_budget(Box::new(SquareEngine), 3 * one);
        for f in 0..10 {
            r.portable_frame(&request(JSON, Time::new(f, 30)), &canvas());
            assert!(r.cached_frame_bytes() <= 3 * one, "frame {f}");
        }
        assert_eq!(r.cached_frame_bytes(), 3 * one);
        // A budget smaller than one frame still keeps the newest one.
        let tiny = LottieRenderer::with_frame_budget(Box::new(SquareEngine), 10);
        tiny.portable_frame(&request(JSON, Time::ZERO), &canvas());
        tiny.portable_frame(&request(JSON, Time::new(1, 30)), &canvas());
        assert_eq!(tiny.cached_frame_bytes(), one);
    }

    /// Linear premultiplied with the shapes' BT.709 inverse OETF.
    #[test]
    fn eight_bit_to_linear_premultiplied() {
        let p = LottieRenderer::linear_pixels(&[255, 128, 0, 128, 9, 9, 9, 0]);
        let half = 128.0f32 / 255.0;
        let lin = ((f64::from(half) + 0.09929682680944) / 1.09929682680944).powf(1.0 / 0.45) as f32;
        assert!(
            (p[0] - half).abs() < 1e-6 && (p[1] - lin * half).abs() < 1e-6 && p[2] == 0.0 && (p[3] - half).abs() < 1e-6
        );
        assert!(p[4..8].iter().all(|&v| v == 0.0));
    }

    #[test]
    fn the_fingerprint_sees_the_size_the_samples_and_the_tail() {
        let a = LottieRenderer::fingerprint(b"abc");
        assert_ne!(a, LottieRenderer::fingerprint(b"abd"));
        assert_ne!(a, LottieRenderer::fingerprint(b"abcd"));
        let long = vec![7u8; 5000];
        let mut tail = long.clone();
        tail[4990] = 8;
        assert_ne!(LottieRenderer::fingerprint(&long), LottieRenderer::fingerprint(&tail));
    }
}
