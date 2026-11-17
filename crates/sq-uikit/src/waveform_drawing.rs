// Swift: WaveformDrawing.swift (the CoreGraphics paths and `draw` are Apple-only and not ported: the canvas toolkit
// fills `bars`, `outline_polygons` and `clip_mark_rects`)
//! Pure waveform geometry: peaks -> per-pixel columns -> rectangles and polygons. No drawing state. Also the cache of
//! peaks resampled to a zoom bucket.

use crate::keyframe_graph_geometry::{Point, Rect};
use sq_core_time::{Id, Time, TimeRange};
use sq_media::waveform_data::{WaveformData, WaveformPeak};
use std::collections::{HashMap, HashSet};
use std::ops::Range;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use crate::timeline_signposts::TimelineSignpost;

/// How the waveform is shaped.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct WaveformStyle {
    /// Rectified grows from the bottom of the clip (DESIGN.md); bipolar is centered.
    pub shape: WaveformShape,
    /// Mixed draws one envelope (union of channels); stacked gives each channel its own lane.
    pub channels: WaveformChannels,
}

impl Default for WaveformStyle {
    fn default() -> Self {
        WaveformStyle { shape: WaveformShape::Rectified, channels: WaveformChannels::Mixed }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum WaveformShape {
    Rectified,
    Bipolar,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum WaveformChannels {
    Mixed,
    Stacked,
}

/// One pixel column of waveform, already volume-scaled and clamped to -1...1.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WaveformColumn {
    pub lo: f32,
    pub hi: f32,
    /// Scaled peak exceeded 0 dBFS.
    pub clipped: bool,
}

/// `min(a, b)` as Swift writes it.
fn smin(a: f32, b: f32) -> f32 {
    if b < a { b } else { a }
}

/// `max(a, b)` as Swift writes it.
fn smax(a: f32, b: f32) -> f32 {
    if b > a { b } else { a }
}

/// Seconds as a function of a position, shared across threads.
pub type SecondsFn = Arc<dyn Fn(f64) -> f64 + Send + Sync>;

/// What `WaveformPath::columns` needs.
#[derive(Clone)]
pub struct WaveformInput {
    pub data: Arc<WaveformData>,
    /// Source range shown by the whole clip (offset + duration).
    pub source: TimeRange,
    /// Width of the whole clip in pixels (columns); column i covers source time i/clipWidth of `source`.
    pub clip_width: f64,
    /// Columns to produce (clip-local, clamped to the clip).
    pub visible_columns: Range<i64>,
    pub style: WaveformStyle,
    /// Clip volume in dB at seconds since clip start (keyframes sampled by the caller).
    pub volume_db: SecondsFn,
    /// Optional cache to reuse resampled peaks while zooming/scrolling.
    pub cache: Option<(Arc<WaveformCache>, Id)>,
    /// Reversed clip: the picture is the mirror image of the source's peaks.
    pub reversed: bool,
    /// Clip with a speed track: source seconds since `source.start` at a fraction 0...1 of the clip's width. When set, every
    /// column reads the peaks of the source it plays (variable speed, direction changes) instead of the linear mapping.
    pub source_map: Option<SecondsFn>,
}

impl WaveformInput {
    /// Mixed rectified columns at 0 dB, no cache, not reversed.
    pub fn new(data: Arc<WaveformData>, source: TimeRange, clip_width: f64, visible_columns: Range<i64>) -> Self {
        WaveformInput {
            data,
            source,
            clip_width,
            visible_columns,
            style: WaveformStyle::default(),
            volume_db: Arc::new(|_| 0.0),
            cache: None,
            reversed: false,
            source_map: None,
        }
    }
}

/// Pure waveform geometry: peaks -> per-pixel columns -> rectangles.
pub struct WaveformPath;

/// Linear gain of a dB value (silence at -120 dB and below).
fn gain_of(db: f64) -> f32 {
    (if db <= -120.0 { 0.0 } else { 10f64.powf(db / 20.0) }) as f32
}

/// Scales one lane/column pair and applies the shape.
fn shaped(lo: f32, hi: f32, gain: f32, style: WaveformStyle) -> WaveformColumn {
    let (mut lo, mut hi) = (lo * gain, hi * gain);
    let clipped = smax(lo.abs(), hi.abs()) > 1.0;
    if style.shape == WaveformShape::Rectified {
        hi = smin(smax(lo.abs(), hi.abs()), 1.0);
        lo = 0.0;
    } else {
        lo = smax(lo, -1.0);
        hi = smin(hi, 1.0);
    }
    WaveformColumn { lo, hi, clipped }
}

impl WaveformPath {
    /// `result[lane][column]`; one lane when mixed, one per source channel when stacked.
    pub fn columns(input: &WaveformInput) -> Vec<Vec<WaveformColumn>> {
        TimelineSignpost::interval("waveformColumns", || Self::columns_inner(input))
    }

    fn columns_inner(input: &WaveformInput) -> Vec<Vec<WaveformColumn>> {
        let total = (input.clip_width.round() as i64).max(1);
        let vis = input.visible_columns.start.max(0)..input.visible_columns.end.min(total);
        let lanes = if input.style.channels == WaveformChannels::Stacked { input.data.channel_count.max(1) } else { 1 };
        if vis.is_empty() {
            return vec![Vec::new(); lanes];
        }
        if let Some(map) = &input.source_map {
            return Self::mapped_columns(input, map.as_ref(), total, vis, lanes);
        }
        if input.reversed {
            // mirrored: compute the mirrored columns forwards, then flip them
            let mut mirrored = input.clone();
            mirrored.reversed = false;
            mirrored.visible_columns = (total - vis.end)..(total - vis.start);
            return Self::columns(&mirrored)
                .into_iter()
                .map(|mut c| {
                    c.reverse();
                    c
                })
                .collect();
        }

        let src = input.source;
        let time = |col: i64| src.start + Time::new(src.duration.value() * col, src.duration.timescale() * total);
        let range = TimeRange::from_end(time(vis.start), time(vis.end));
        let src_seconds = (src.duration.value() as f64 / src.duration.timescale() as f64).max(1e-9);
        let count = (vis.end - vis.start) as usize;

        // Beyond ~500 columns per second the whole-file resample would be huge (hours at deep zoom): read the mip pyramid
        // for the visible range only.
        let peaks: Vec<Vec<WaveformPeak>> = match &input.cache {
            Some((cache, media)) if total as f64 / src_seconds <= WaveformCache::MAX_COLUMNS_PER_SECOND => {
                let pps = total as f64 / src_seconds;
                if let Some(r) = cache.cached(*media, pps) {
                    r.peaks(range, count)
                } else if let Some(r) = cache.cached_finer(*media, pps) {
                    // A finer bucket is already there: same picture, no inline work. The exact bucket is built behind it.
                    cache.request_build(*media, Arc::clone(&input.data), pps, 2);
                    r.peaks(range, count)
                } else {
                    // Cold bucket: never resample the whole file inside a draw (hundreds of ms on a long file). Read the
                    // visible range from the mip pyramid now and let a background build fill this bucket and its neighbors.
                    cache.request_build(*media, Arc::clone(&input.data), pps, 2);
                    input.data.peaks(range, count)
                }
            }
            _ => input.data.peaks(range, count),
        };
        if peaks.is_empty() {
            return vec![Vec::new(); lanes];
        }

        let seconds_per_column = src_seconds / total as f64;
        let mut out: Vec<Vec<WaveformColumn>> = vec![Vec::with_capacity(count); lanes];
        for (n, col) in vis.enumerate() {
            let db = (input.volume_db)((col as f64 + 0.5) * seconds_per_column);
            let gain = gain_of(db);
            for (lane, lane_out) in out.iter_mut().enumerate() {
                let (mut lo, mut hi) = (f32::MAX, -f32::MAX);
                if input.style.channels == WaveformChannels::Stacked {
                    let p = &peaks[lane.min(peaks.len() - 1)][n];
                    lo = p.min;
                    hi = p.max;
                } else {
                    for ch in &peaks {
                        lo = smin(lo, ch[n].min);
                        hi = smax(hi, ch[n].max);
                    }
                }
                lane_out.push(shaped(lo, hi, gain, input.style));
            }
        }
        out
    }

    /// Columns of a clip with a speed track: column `i` shows the peaks of the source range between the mapped times of its two edges.
    fn mapped_columns(
        input: &WaveformInput,
        map: &(dyn Fn(f64) -> f64 + Send + Sync),
        total: i64,
        vis: Range<i64>,
        lanes: usize,
    ) -> Vec<Vec<WaveformColumn>> {
        let mut out: Vec<Vec<WaveformColumn>> = vec![Vec::new(); lanes];
        let base = input.source.start.value() as f64 / input.source.start.timescale() as f64;
        let fine: i64 = 1_000_000;
        let t = |sec: f64| Time::new(((base + sec) * fine as f64).round() as i64, fine);
        for col in vis {
            let a = map(col as f64 / total as f64);
            let b = map((col + 1) as f64 / total as f64);
            let lo = a.min(b);
            let hi = a.max(b).max(a.min(b) + 1e-6);
            let peaks = input.data.peaks(TimeRange::from_end(t(lo), t(hi)), 1);
            let db = (input.volume_db)(map((col as f64 + 0.5) / total as f64));
            let gain = gain_of(db);
            for (lane, lane_out) in out.iter_mut().enumerate() {
                let (mut l, mut h) = (f32::MAX, -f32::MAX);
                if peaks.is_empty() {
                    l = 0.0;
                    h = 0.0;
                } else if input.style.channels == WaveformChannels::Stacked {
                    let p = &peaks[lane.min(peaks.len() - 1)][0];
                    l = p.min;
                    h = p.max;
                } else {
                    for ch in &peaks {
                        l = smin(l, ch[0].min);
                        h = smax(h, ch[0].max);
                    }
                }
                lane_out.push(shaped(l, h, gain, input.style));
            }
        }
        out
    }

    /// Lane rectangles inside `rect` (top to bottom).
    pub fn lane_rects(rect: Rect, lanes: usize) -> Vec<Rect> {
        let n = lanes.max(1);
        let h = rect.height / n as f64;
        (0..n).map(|i| Rect { x: rect.min_x(), y: rect.min_y() + h * i as f64, width: rect.width, height: h }).collect()
    }

    /// The bars of the waveform as rectangles (one 1 pt column each): the canvas toolkit fills these directly.
    pub fn bars(columns: &[Vec<WaveformColumn>], rect: Rect, style: WaveformStyle, first_column: i64) -> Vec<Rect> {
        let mut out = Vec::new();
        for (lane, lane_rect) in Self::lane_rects(rect, columns.len()).into_iter().enumerate() {
            let Some(cols) = columns.get(lane) else { continue };
            for (i, c) in cols.iter().enumerate() {
                let x = rect.min_x() + (first_column + i as i64) as f64;
                if !(x >= rect.min_x() && x + 1.0 <= rect.max_x() + 0.001) {
                    continue;
                }
                let (top, bottom) = Self::y_range(c, lane_rect, style);
                if bottom - top < 0.5 {
                    continue;
                }
                out.push(Rect { x, y: top, width: 1.0, height: bottom - top });
            }
        }
        out
    }

    /// The 0 dBFS marks (small 2 pt marks at the peak end of columns that exceed 0 dBFS) as rectangles.
    pub fn clip_mark_rects(
        columns: &[Vec<WaveformColumn>],
        rect: Rect,
        style: WaveformStyle,
        first_column: i64,
    ) -> Vec<Rect> {
        let mut out = Vec::new();
        for (lane, lane_rect) in Self::lane_rects(rect, columns.len()).into_iter().enumerate() {
            let Some(cols) = columns.get(lane) else { continue };
            for (i, c) in cols.iter().enumerate().filter(|(_, c)| c.clipped) {
                let x = rect.min_x() + (first_column + i as i64) as f64;
                if !(x >= rect.min_x() && x + 1.0 <= rect.max_x() + 0.001) {
                    continue;
                }
                let (top, bottom) = Self::y_range(c, lane_rect, style);
                out.push(Rect { x, y: top, width: 1.0, height: 2.0 });
                if style.shape == WaveformShape::Bipolar {
                    out.push(Rect { x, y: bottom - 2.0, width: 1.0, height: 2.0 });
                }
            }
        }
        out
    }

    /// The step outlines as point lists (portable: the canvas toolkit fills them as polygons).
    pub fn outline_polygons(
        columns: &[Vec<WaveformColumn>],
        rect: Rect,
        style: WaveformStyle,
        first_column: i64,
    ) -> Vec<Vec<Point>> {
        fn flush(out: &mut Vec<Vec<Point>>, tops: &mut Vec<Point>, bottoms: &mut Vec<Point>) {
            if tops.is_empty() {
                return;
            }
            let mut poly = std::mem::take(tops);
            poly.extend(bottoms.iter().rev());
            out.push(poly);
            bottoms.clear();
        }
        let mut out: Vec<Vec<Point>> = Vec::new();
        let mut tops: Vec<Point> = Vec::new();
        let mut bottoms: Vec<Point> = Vec::new();
        for (lane, lane_rect) in Self::lane_rects(rect, columns.len()).into_iter().enumerate() {
            let Some(cols) = columns.get(lane) else { continue };
            for (i, c) in cols.iter().enumerate() {
                let x = rect.min_x() + (first_column + i as i64) as f64;
                if !(x >= rect.min_x() && x + 1.0 <= rect.max_x() + 0.001) {
                    flush(&mut out, &mut tops, &mut bottoms);
                    continue;
                }
                let (top, bottom) = Self::y_range(c, lane_rect, style);
                if bottom - top < 0.5 {
                    flush(&mut out, &mut tops, &mut bottoms);
                    continue;
                }
                let x1 = Rect { x, y: top, width: 1.0, height: bottom - top }.max_x(); // the same edge a bar's rectangle has
                if tops.last().is_some_and(|last| last.x != x) {
                    flush(&mut out, &mut tops, &mut bottoms);
                }
                tops.push(Point { x, y: top });
                tops.push(Point { x: x1, y: top });
                bottoms.push(Point { x, y: bottom });
                bottoms.push(Point { x: x1, y: bottom });
            }
            flush(&mut out, &mut tops, &mut bottoms);
        }
        out
    }

    /// Top and bottom of a column inside its lane.
    pub fn y_range(c: &WaveformColumn, lane: Rect, style: WaveformStyle) -> (f64, f64) {
        match style.shape {
            WaveformShape::Rectified => (lane.max_y() - c.hi as f64 * lane.height, lane.max_y()),
            WaveformShape::Bipolar => {
                let mid = lane.mid_y();
                let half = lane.height / 2.0;
                (mid - c.hi as f64 * half, mid - c.lo as f64 * half)
            }
        }
    }
}

/// System memory-pressure level. The part of a cache's full budget kept at each level is one rule for every cache.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum MemoryPressure {
    Normal,
    Warning,
    Critical,
}

impl MemoryPressure {
    /// Normal all, warning 1/2, critical 1/4.
    pub fn budget(self, full: i64) -> i64 {
        match self {
            MemoryPressure::Normal => full,
            MemoryPressure::Warning => full / 2,
            MemoryPressure::Critical => full / 4,
        }
    }
}

/// Whole-file peaks resampled to a zoom bucket, so scrolling and small zoom changes do not re-read the mip pyramid.
pub struct ResampledPeaks {
    columns_per_second: f64,
    /// `channels[channel][column]`
    channels: Vec<Vec<WaveformPeak>>,
}

impl ResampledPeaks {
    fn byte_count(&self) -> i64 {
        self.channels.iter().map(|c| (c.len() * std::mem::size_of::<WaveformPeak>()) as i64).sum()
    }

    /// Same contract as `WaveformData::peaks`, merged from the resampled columns.
    pub fn peaks(&self, range: TimeRange, buckets: usize) -> Vec<Vec<WaveformPeak>> {
        let start = range.start.value() as f64 / range.start.timescale() as f64;
        let span = range.duration.value() as f64 / range.duration.timescale() as f64;
        let silent = WaveformPeak { min: 0.0, max: 0.0 };
        let b = buckets as f64;
        let bounds: Vec<(i64, i64)> = (0..buckets)
            .map(|i| {
                let a = ((start + span * i as f64 / b) * self.columns_per_second).floor() as i64;
                let e = ((start + span * (i + 1) as f64 / b) * self.columns_per_second).ceil() as i64;
                (a, e.max(a + 1))
            })
            .collect();
        self.channels
            .iter()
            .map(|c| {
                let mut out = vec![silent; bounds.len()];
                for (i, (a, e)) in bounds.iter().enumerate() {
                    let lo = (*a).max(0);
                    let hi = (*e).min(c.len() as i64);
                    if lo >= hi {
                        continue;
                    }
                    let (mut mn, mut mx) = (f32::MAX, -f32::MAX);
                    for p in &c[lo as usize..hi as usize] {
                        mn = smin(mn, p.min);
                        mx = smax(mx, p.max);
                    }
                    out[i] = WaveformPeak { min: mn, max: mx };
                }
                out
            })
            .collect()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
struct CacheKey {
    media: Id,
    bucket: i64,
}

type BuiltHandler = Arc<dyn Fn() + Send + Sync>;

#[derive(Default)]
struct CacheState {
    store: HashMap<CacheKey, Arc<ResampledPeaks>>,
    /// Least recently used first.
    order: Vec<CacheKey>,
    bytes: i64,
    pressure: Option<MemoryPressure>,
    built_handler: Option<BuiltHandler>,
    in_flight: HashSet<CacheKey>,
    /// Builds requested by draws, run by `run_queued_builds` on the host's background thread.
    queued: Vec<(CacheKey, Arc<WaveformData>)>,
}

/// Small cache keyed by (media, zoom bucket). Thread-safe; evicts the least recently used entries beyond `limit`.
///
/// Swift builds buckets on its own utility queue; here `request_build` only queues them and the host calls
/// `run_queued_builds` on a background thread (threads belong to the app shell, not to this model crate).
pub struct WaveformCache {
    state: Mutex<CacheState>,
    limit: usize,
    max_bytes: i64,
}

impl WaveformCache {
    /// Zoom beyond this many columns per second is not cached (the draw reads the visible range directly).
    pub const MAX_COLUMNS_PER_SECOND: f64 = 500.0;

    /// `max_bytes`: `WorkLimits::waveform_cache_bytes` (32 MB on 8 GB Macs, 64 MB from 16 GB). The memory-pressure
    /// registration is the host's: it calls `apply_memory_pressure`.
    pub fn new(limit: usize, max_bytes: i64) -> WaveformCache {
        WaveformCache { state: Mutex::new(CacheState::default()), limit: limit.max(1), max_bytes }
    }

    fn lock(&self) -> MutexGuard<'_, CacheState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn budget(&self, s: &CacheState) -> i64 {
        s.pressure.unwrap_or(MemoryPressure::Normal).budget(self.max_bytes)
    }

    /// Caps the cache at its share of `max_bytes` and drops the least recently used entries beyond it; normal lifts the cap.
    pub fn apply_memory_pressure(&self, level: MemoryPressure) {
        let mut s = self.lock();
        s.pressure = Some(level);
        let cap = self.budget(&s);
        while !s.order.is_empty() && s.bytes > cap {
            let first = s.order.remove(0);
            if let Some(gone) = s.store.remove(&first) {
                s.bytes -= gone.byte_count();
            }
        }
    }

    pub fn count(&self) -> usize {
        self.lock().store.len()
    }

    pub fn byte_count(&self) -> i64 {
        self.lock().bytes
    }

    pub fn remove_all(&self) {
        let mut s = self.lock();
        s.store.clear();
        s.order.clear();
        s.bytes = 0;
    }

    pub fn remove(&self, media: Id) {
        let mut s = self.lock();
        s.store.retain(|k, _| k.media != media);
        s.order.retain(|k| k.media != media);
        s.bytes = s.store.values().map(|v| v.byte_count()).sum();
    }

    /// Half-octave zoom buckets: pps within a factor of ~1.41 share a bucket.
    pub fn zoom_bucket(points_per_second: f64) -> i64 {
        (points_per_second.max(1e-6).log2() * 2.0).round() as i64
    }

    /// Resampled resolution for a bucket: at least as fine as the requested zoom.
    fn columns_per_second(bucket: i64) -> f64 {
        2f64.powf((bucket + 1) as f64 / 2.0)
    }

    /// Non-blocking lookup: the resampled peaks of the bucket, or `None` when it is not built yet.
    pub fn cached(&self, media: Id, points_per_second: f64) -> Option<Arc<ResampledPeaks>> {
        let key = CacheKey { media, bucket: Self::zoom_bucket(points_per_second) };
        Self::touch(&mut self.lock(), key)
    }

    /// The stored peaks for `key`, marked as just used (eviction is least recently used, so the buckets on screen are not
    /// evicted by the prefetch of their neighbors).
    fn touch(s: &mut CacheState, key: CacheKey) -> Option<Arc<ResampledPeaks>> {
        let hit = s.store.get(&key).map(Arc::clone)?;
        if s.order.last() != Some(&key)
            && let Some(i) = s.order.iter().position(|k| *k == key)
        {
            s.order.remove(i);
            s.order.push(key);
        }
        Some(hit)
    }

    /// A cached bucket up to two half-octaves finer than `points_per_second` (at least as detailed as asked for).
    pub fn cached_finer(&self, media: Id, points_per_second: f64) -> Option<Arc<ResampledPeaks>> {
        let b = Self::zoom_bucket(points_per_second);
        let mut s = self.lock();
        (1..=2).find_map(|d| Self::touch(&mut s, CacheKey { media, bucket: b + d }))
    }

    /// Called by `run_queued_builds` after background builds stored new peaks.
    pub fn set_on_built(&self, handler: Option<BuiltHandler>) {
        self.lock().built_handler = handler;
    }

    /// Queues the bucket for `points_per_second` and `radius` buckets either side (the requested bucket goes first),
    /// skipping buckets that are cached, queued, or beyond `MAX_COLUMNS_PER_SECOND`.
    pub fn request_build(&self, media: Id, data: Arc<WaveformData>, points_per_second: f64, radius: i64) {
        let centre = Self::zoom_bucket(points_per_second);
        let mut order = vec![centre];
        for d in 1..=radius {
            order.push(centre + d);
            order.push(centre - d);
        }
        for bucket in order {
            let key = CacheKey { media, bucket };
            if Self::columns_per_second(bucket) > Self::MAX_COLUMNS_PER_SECOND * 1.5 {
                continue;
            }
            let mut s = self.lock();
            if s.store.contains_key(&key) || s.in_flight.contains(&key) {
                continue;
            }
            s.in_flight.insert(key);
            s.queued.push((key, Arc::clone(&data)));
        }
    }

    /// Builds every queued bucket, then calls the built handler once. Run it on a background thread.
    pub fn run_queued_builds(&self) {
        let mut built = false;
        loop {
            let next = {
                let mut s = self.lock();
                if s.queued.is_empty() { None } else { Some(s.queued.remove(0)) }
            };
            let Some((key, data)) = next else { break };
            let _ = self.resampled_bucket(key.media, key.bucket, &data);
            self.lock().in_flight.remove(&key);
            built = true;
        }
        let handler = if built { self.lock().built_handler.clone() } else { None };
        if let Some(h) = handler {
            h();
        }
    }

    pub fn resampled(&self, media: Id, data: &WaveformData, points_per_second: f64) -> Arc<ResampledPeaks> {
        self.resampled_bucket(media, Self::zoom_bucket(points_per_second), data)
    }

    fn resampled_bucket(&self, media: Id, bucket: i64, data: &WaveformData) -> Arc<ResampledPeaks> {
        let key = CacheKey { media, bucket };
        if let Some(hit) = self.lock().store.get(&key) {
            return Arc::clone(hit);
        }
        let rate = data.sample_rate.max(1);
        let r = TimelineSignpost::interval("waveformBucketBuild", || {
            let seconds = data.total_frames as f64 / rate as f64;
            let n = ((seconds * Self::columns_per_second(key.bucket)).ceil() as i64).max(1) as usize;
            let whole = data.peaks(TimeRange::new(Time::ZERO, Time::new(data.total_frames as i64, rate as i64)), n);
            Arc::new(ResampledPeaks { columns_per_second: n as f64 / seconds.max(1e-9), channels: whole })
        });
        let mut s = self.lock();
        if let Some(old) = s.store.get(&key) {
            s.bytes -= old.byte_count();
        } else {
            s.order.push(key);
        }
        s.store.insert(key, Arc::clone(&r));
        s.bytes += r.byte_count();
        // Least recently used first, by count and by bytes; the entry just made always stays.
        while s.order.len() > 1 && (s.order.len() > self.limit || s.bytes > self.budget(&s)) {
            let first = s.order.remove(0);
            if let Some(gone) = s.store.remove(&first) {
                s.bytes -= gone.byte_count();
            }
        }
        r
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One base bucket per 10 frames, 2 channels; bucket i of ch0 has peak (i+1)/buckets (symmetric), ch1 half of it.
    fn make_data(buckets: usize) -> Arc<WaveformData> {
        let mut l0: Vec<f32> = Vec::new();
        for i in 0..buckets {
            let v = (i + 1) as f32 / buckets as f32;
            l0.extend([-v, v, -v / 2.0, v / 2.0]);
        }
        Arc::new(WaveformData::new(1000, 2, buckets * 10, 10, vec![l0]))
    }

    /// Mono fake of the warm-up tests: 4000 base buckets.
    fn warm_data(frames: usize) -> Arc<WaveformData> {
        let l0: Vec<f32> = (0..4000)
            .flat_map(|i| {
                let a = (i % 50) as f32 / 60.0;
                [-a, a]
            })
            .collect();
        Arc::new(WaveformData::new(1000, 1, frames, 10, vec![l0]))
    }

    fn input(data: &Arc<WaveformData>, width: f64) -> WaveformInput {
        WaveformInput::new(Arc::clone(data), TimeRange::new(Time::ZERO, Time::new(1000, 1000)), width, 0..width as i64)
    }

    fn stacked() -> WaveformStyle {
        WaveformStyle { channels: WaveformChannels::Stacked, ..Default::default() }
    }

    fn union(rects: &[Rect]) -> Rect {
        let x0 = rects.iter().map(Rect::min_x).fold(f64::INFINITY, f64::min);
        let y0 = rects.iter().map(Rect::min_y).fold(f64::INFINITY, f64::min);
        let x1 = rects.iter().map(Rect::max_x).fold(f64::NEG_INFINITY, f64::max);
        let y1 = rects.iter().map(Rect::max_y).fold(f64::NEG_INFINITY, f64::max);
        Rect { x: x0, y: y0, width: x1 - x0, height: y1 - y0 }
    }

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    #[test]
    fn mixed_rectified_columns() {
        let cols = WaveformPath::columns(&input(&make_data(100), 100.0));
        assert_eq!(cols.len(), 1);
        assert_eq!(cols[0].len(), 100);
        assert_eq!(cols[0][0].lo, 0.0);
        assert!((cols[0][99].hi - 1.0).abs() < 1e-6);
        assert!((cols[0][49].hi - 0.5).abs() < 1e-6); // mixed = max over channels
        assert!(cols[0].iter().all(|c| !c.clipped));
    }

    #[test]
    fn stacked_gives_two_lanes() {
        let mut i = input(&make_data(100), 100.0);
        i.style = stacked();
        let cols = WaveformPath::columns(&i);
        assert_eq!(cols.len(), 2);
        assert!((cols[1][49].hi - 0.25).abs() < 1e-6);
    }

    #[test]
    fn bipolar_keeps_sign() {
        let mut i = input(&make_data(100), 100.0);
        i.style.shape = WaveformShape::Bipolar;
        let cols = WaveformPath::columns(&i);
        assert!((cols[0][49].lo + 0.5).abs() < 1e-6 && (cols[0][49].hi - 0.5).abs() < 1e-6);
    }

    #[test]
    fn volume_scales_and_clips() {
        let mut i = input(&make_data(100), 100.0);
        i.volume_db = Arc::new(|_| 6.0206); // x2
        let cols = WaveformPath::columns(&i);
        assert!((cols[0][24].hi - 0.5).abs() < 1e-3);
        assert!(!cols[0][24].clipped);
        assert!(cols[0][60].clipped);
        assert_eq!(cols[0][60].hi, 1.0); // clamped
    }

    #[test]
    fn keyframed_volume_follows_clip_time() {
        let mut i = input(&make_data(100), 100.0);
        i.volume_db = Arc::new(|t| if t < 0.5 { 0.0 } else { -120.0 });
        let cols = WaveformPath::columns(&i);
        assert!(cols[0][10].hi > 0.05);
        assert!(cols[0][90].hi < 0.001);
    }

    #[test]
    fn source_offset_shifts() {
        let d = make_data(100);
        let i = WaveformInput::new(
            Arc::clone(&d),
            TimeRange::new(Time::new(500, 1000), Time::new(500, 1000)),
            100.0,
            0..100,
        );
        let c = WaveformPath::columns(&i);
        assert!(c[0][0].hi > 0.49);
        assert!((c[0][99].hi - 1.0).abs() < 1e-6);
    }

    #[test]
    fn visible_range_only_and_outside_silent() {
        let mut i = input(&make_data(100), 100.0);
        i.visible_columns = 50..60;
        let cols = WaveformPath::columns(&i);
        assert_eq!(cols[0].len(), 10);
        assert!((cols[0][0].hi - 0.51).abs() < 0.02);
        let c = WaveformPath::columns(&input(&make_data(50), 100.0)); // 0.5 s of audio, clip shows 1 s
        assert_eq!(c[0][90].hi, 0.0);
    }

    #[test]
    fn bars_rectified_grow_from_bottom() {
        let cols = WaveformPath::columns(&input(&make_data(100), 100.0));
        let rect = Rect { x: 10.0, y: 20.0, width: 100.0, height: 40.0 };
        let b = union(&WaveformPath::bars(&cols, rect, WaveformStyle::default(), 0));
        assert!((b.max_y() - rect.max_y()).abs() < 1e-6);
        assert!((b.min_y() - rect.min_y()).abs() < 1.5);
        assert!(b.min_x() >= rect.min_x() - 1e-6 && b.max_x() <= rect.max_x() + 1e-6);
    }

    #[test]
    fn bars_stacked_use_lanes() {
        let mut i = input(&make_data(100), 100.0);
        i.style = stacked();
        let cols = WaveformPath::columns(&i);
        let bars = WaveformPath::bars(&cols, Rect { x: 0.0, y: 0.0, width: 100.0, height: 40.0 }, stacked(), 0);
        let hit = |x: f64, y: f64| bars.iter().any(|r| r.contains(Point { x, y }));
        assert!(union(&bars).max_y() <= 40.0 + 1e-6);
        assert!(hit(99.5, 19.0)); // lane 0 (top) bottom edge
        assert!(hit(99.5, 39.0)); // lane 1 bottom edge
        assert!(!hit(0.5, 39.0)); // quiet start of lane 1
    }

    #[test]
    fn clip_marks_only_where_clipped() {
        let mut i = input(&make_data(100), 100.0);
        i.volume_db = Arc::new(|_| 6.0206);
        let cols = WaveformPath::columns(&i);
        let m = WaveformPath::clip_mark_rects(
            &cols,
            Rect { x: 0.0, y: 0.0, width: 100.0, height: 40.0 },
            WaveformStyle::default(),
            0,
        );
        assert!(!m.is_empty());
        assert!(union(&m).min_x() >= 45.0);
    }

    #[test]
    fn portable_bars_and_outlines_agree() {
        let mut i = input(&make_data(100), 100.0);
        i.volume_db = Arc::new(|_| 6.0206);
        let cols = WaveformPath::columns(&i);
        let rect = Rect { x: 10.0, y: 20.0, width: 100.0, height: 40.0 };
        let style = WaveformStyle::default();
        let bars = WaveformPath::bars(&cols, rect, style, 0);
        assert!(bars.len() == 100 && bars.iter().all(|r| r.max_y() == rect.max_y()));
        let polys = WaveformPath::outline_polygons(&cols, rect, style, 0);
        assert!(polys.len() == 1 && polys[0].len() == 400); // one run: 2 top + 2 bottom points per column
        let u = union(&bars);
        let xs = polys[0].iter().map(|p| p.x).fold(f64::INFINITY, f64::min)
            ..=polys[0].iter().map(|p| p.x).fold(f64::NEG_INFINITY, f64::max);
        assert!(*xs.start() == u.min_x() && *xs.end() == u.max_x());
        assert!(WaveformPath::clip_mark_rects(&cols, rect, style, 0).iter().all(|r| r.min_x() >= 55.0));
    }

    #[test]
    fn cache_buckets_zoom_and_reuses() {
        let cache = WaveformCache::new(24, 64 << 20);
        assert_eq!(WaveformCache::zoom_bucket(100.0), WaveformCache::zoom_bucket(101.0));
        assert_ne!(WaveformCache::zoom_bucket(100.0), WaveformCache::zoom_bucket(400.0));
        let a = cache.resampled(id(1), &make_data(100), 100.0);
        let b = cache.resampled(id(1), &make_data(100), 101.0);
        assert!(Arc::ptr_eq(&a, &b));
        assert_eq!(cache.count(), 1);
    }

    #[test]
    fn cached_columns_match_direct() {
        let cache = Arc::new(WaveformCache::new(24, 64 << 20));
        let mut i = input(&make_data(100), 100.0);
        let direct = WaveformPath::columns(&i);
        i.cache = Some((cache, id(9)));
        let cached = WaveformPath::columns(&i);
        assert_eq!(cached[0].len(), direct[0].len());
        for k in (0..100).step_by(9) {
            assert!((cached[0][k].hi - direct[0][k].hi).abs() < 0.03);
        }
    }

    // Review finding 1: the cache had no byte budget and resampled whole files at any zoom.
    #[test]
    fn cache_has_a_byte_budget() {
        let cache = WaveformCache::new(24, 1);
        let _ = cache.resampled(id(1), &make_data(100), 100.0);
        let _ = cache.resampled(id(1), &make_data(100), 400.0);
        assert_eq!(cache.count(), 1); // only the newest entry stays above the budget
    }

    #[test]
    fn deep_zoom_skips_the_whole_file_resample() {
        let cache = Arc::new(WaveformCache::new(24, 64 << 20));
        let mut i = input(&make_data(100), 5000.0); // 5000 points for one second: far beyond the cache's range
        let direct = WaveformPath::columns(&i);
        i.cache = Some((Arc::clone(&cache), id(9)));
        let cached = WaveformPath::columns(&i);
        assert_eq!(cache.count(), 0);
        assert_eq!(cached[0].len(), direct[0].len());
    }

    #[test]
    fn cold_lookup_misses_and_does_not_build() {
        let cache = WaveformCache::new(24, 64 << 20);
        assert!(cache.cached(id(1), 100.0).is_none());
        assert_eq!(cache.count(), 0);
    }

    #[test]
    fn request_build_fills_bucket_and_neighbours() {
        let cache = WaveformCache::new(24, 64 << 20);
        cache.request_build(id(1), warm_data(40_000), 100.0, 1);
        assert_eq!(cache.count(), 0); // queued only: the draw path never builds
        cache.run_queued_builds();
        assert_eq!(cache.count(), 3);
        assert!(cache.cached(id(1), 100.0).is_some());
        assert!(cache.cached(id(1), 100.0 * 1.42).is_some());
        assert!(cache.cached(id(1), 100.0 / 1.42).is_some());
    }

    #[test]
    fn request_build_skips_buckets_cached_or_beyond_the_column_limit() {
        let cache = WaveformCache::new(24, 64 << 20);
        let _ = cache.resampled(id(1), &warm_data(40_000), 100.0);
        cache.request_build(id(1), warm_data(40_000), 100.0, 0);
        cache.request_build(id(1), warm_data(40_000), WaveformCache::MAX_COLUMNS_PER_SECOND * 4.0, 0);
        cache.run_queued_builds();
        assert_eq!(cache.count(), 1);
    }

    /// Eviction is least recently used, not first built: a bucket the view keeps drawing from survives the prefetch of its
    /// neighbors (which used to evict it, leaving the view on a fallback picture and rebuilding it).
    #[test]
    fn eviction_keeps_the_bucket_in_use() {
        let cache = WaveformCache::new(2, 64 << 20);
        let d = warm_data(40_000);
        let _ = cache.resampled(id(1), &d, 100.0);
        let _ = cache.resampled(id(2), &d, 100.0);
        assert!(cache.cached(id(1), 100.0).is_some()); // a is in use
        let _ = cache.resampled(id(3), &d, 100.0);
        assert!(cache.cached(id(1), 100.0).is_some());
        assert!(cache.cached(id(2), 100.0).is_none());
        assert!(cache.cached(id(3), 100.0).is_some());
    }

    #[test]
    fn build_notifies_once_built() {
        let cache = WaveformCache::new(24, 64 << 20);
        let flag = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let f = Arc::clone(&flag);
        cache.set_on_built(Some(Arc::new(move || {
            f.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        })));
        cache.request_build(id(1), warm_data(40_000), 50.0, 0);
        cache.run_queued_builds();
        assert_eq!(flag.load(std::sync::atomic::Ordering::SeqCst), 1);
    }

    #[test]
    fn draw_path_on_cold_cache_reads_directly_then_warms() {
        let cache = Arc::new(WaveformCache::new(24, 64 << 20));
        let mut i = WaveformInput::new(warm_data(40_000), TimeRange::new(Time::ZERO, Time::new(4, 1)), 400.0, 0..400);
        i.cache = Some((Arc::clone(&cache), id(1)));
        let cold = WaveformPath::columns(&i);
        assert_eq!(cache.count(), 0); // nothing was resampled inline
        assert_eq!(cold[0].len(), 400);
        cache.run_queued_builds();
        assert!(cache.count() >= 1);
        let warm = WaveformPath::columns(&i);
        assert_eq!(warm[0].len(), 400);
        for k in (0..400).step_by(37) {
            assert!((warm[0][k].hi - cold[0][k].hi).abs() < 0.05);
        }
    }

    #[test]
    fn finer_bucket_is_used_while_the_exact_one_builds() {
        let cache = WaveformCache::new(24, 64 << 20);
        assert!(cache.cached_finer(id(1), 100.0).is_none());
        let _ = cache.resampled(id(1), &warm_data(40_000), 100.0 * 1.42);
        assert!(cache.cached_finer(id(1), 100.0).is_some());
        assert!(cache.cached_finer(id(1), 100.0 * 1.42).is_none()); // not finer than itself
    }

    #[test]
    fn memory_pressure_shrinks_the_cache() {
        let cache = WaveformCache::new(64, 1 << 30);
        let d = warm_data(40_000);
        for m in 1..=4 {
            let _ = cache.resampled(id(m), &d, 100.0);
        }
        let entry = cache.byte_count() / 4;
        let small = WaveformCache::new(64, entry * 4);
        for m in 1..=4 {
            let _ = small.resampled(id(m), &d, 100.0);
        }
        assert_eq!(small.count(), 4);
        small.apply_memory_pressure(MemoryPressure::Warning);
        assert_eq!(small.count(), 2);
        small.apply_memory_pressure(MemoryPressure::Critical);
        assert_eq!(small.count(), 1);
    }
}
