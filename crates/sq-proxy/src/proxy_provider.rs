// Swift: ProxyProvider.swift (async calls are blocking; the fingerprint memo is a `Mutex`; `interlaced` replaces the
// AVFoundation field probe, which is not ported)
//! Read-only lookup API for the playback engine.

use crate::model::{
    ProxyDimensions, ProxyKind, ProxyRecord, ProxySettings, ProxyUseContext, SourceFingerprint, modified_millis,
};
use crate::proxy_cache::{ProxyCache, ProxyRecordID};
use sq_core_time::Timestamp;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::mpsc::Receiver;
use std::sync::{Arc, Mutex, PoisonError};

/// Color interpretation of a proxy. There is exactly one rule: always the ORIGINAL source's.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ProxyColorInterpretation {
    /// Interpret color (log curve, primaries, matrix, sidecar metadata such as Sony S-Log3) from the original
    /// source file. Never read color tags from the proxy: its BT.709 tag is an encoder default, not information.
    FromSource,
}

/// A ready proxy handed to the playback engine.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ProxyLookup {
    /// Always `FromSource`: see `ProxyColorInterpretation`.
    pub color_interpretation: ProxyColorInterpretation,
    /// The proxy file.
    pub url: PathBuf,
    /// Which proxy.
    pub kind: ProxyKind,
    /// Picture size of the proxy.
    pub dimensions: ProxyDimensions,
    /// Width/height divisor relative to the source (1, 2 or 4).
    pub scale_divisor: i64,
    /// The cache record handed out (to protect it from eviction while in use).
    pub record: Option<ProxyRecordID>,
}

struct Memo {
    size: i64,
    modified_millis: i64,
    fingerprint: SourceFingerprint,
}

/// `Date.distantPast` in seconds since 1970: the mtime Swift assumes when the system gives none.
const DISTANT_PAST_UNIX: f64 = -62_135_769_600.0;

/// Read-only lookup API for the playback engine. Never starts work; only reports proxies that are ready.
pub struct ProxyProvider {
    cache: Arc<ProxyCache>,
    memo: Mutex<HashMap<String, Memo>>,
    interlaced: Box<dyn Fn(&Path) -> bool + Send + Sync>,
}

impl ProxyProvider {
    /// Half first (what auto-generation produces), then quarter, then full-res optimized.
    pub const SCRUB_PREFERENCE: [ProxyKind; 3] = [ProxyKind::ProxyHalf, ProxyKind::ProxyQuarter, ProxyKind::Optimized];

    /// A provider with the default field probe (`has_fields`).
    pub fn new(cache: Arc<ProxyCache>) -> ProxyProvider {
        Self::with_interlaced(cache, Box::new(Self::has_fields))
    }

    /// `interlaced`: whether a source has fields (tests replace the file read).
    pub fn with_interlaced(
        cache: Arc<ProxyCache>,
        interlaced: Box<dyn Fn(&Path) -> bool + Send + Sync>,
    ) -> ProxyProvider {
        ProxyProvider { cache, memo: Mutex::new(HashMap::new()), interlaced }
    }

    /// The first video track of `source` is tagged interlaced.
    /// False for a file FFmpeg cannot open. Swift reads the AVFoundation field tags; the stream's field order is the
    /// same fact (`field_order_of`, the Swift rule: only a stream that says top or bottom first has fields).
    pub fn has_fields(source: &Path) -> bool {
        sq_media_ffmpeg::shim::Demux::open(source)
            .is_ok_and(|d| sq_media_ffmpeg::decode::field_order_of(d.info().field_order).is_some())
    }

    /// Proxies made before interlaced sources were deinterlaced (`ProxyRecord::build`) are woven when the source has
    /// fields: those are deleted (the automatic proxy flow makes them again), the others are marked current. Until this
    /// ran for a source, no lookup hands out its old proxies. Costs one track read per old proxy, once.
    fn settle_outdated(&self, source: &Path, fp: &SourceFingerprint) {
        let kinds = self.cache.outdated_kinds(fp);
        if kinds.is_empty() {
            return;
        }
        let woven = (self.interlaced)(source);
        for kind in kinds {
            // The track read took time: both look at the record again and leave one that is current by now.
            if woven {
                self.cache.remove_outdated(fp, kind);
            } else {
                self.cache.mark_current(fp, kind);
            }
        }
    }

    /// First ready proxy in `preferring` order. Computes (and memoizes) the source fingerprint if needed,
    /// which reads 128 KB of the source.
    pub fn optimized_file(&self, source: &Path, preferring: &[ProxyKind], now: Timestamp) -> Option<ProxyLookup> {
        let fp = self.fingerprint(source, true)?;
        self.settle_outdated(source, &fp);
        self.resolve(&fp, preferring, now)
    }

    /// Stat-only variant for hot paths (e.g. building a decoder on the main thread): never reads file content.
    /// Returns `None` until `optimized_file` (or `warm`) has computed the fingerprint for the current file state.
    pub fn cached_lookup(&self, source: &Path, preferring: &[ProxyKind], now: Timestamp) -> Option<ProxyLookup> {
        let fp = self.fingerprint(source, false)?;
        self.resolve(&fp, preferring, now)
    }

    /// Precomputes the fingerprint so `cached_lookup` works afterwards.
    pub fn warm(&self, source: &Path) {
        if let Some(fp) = self.fingerprint(source, true) {
            self.settle_outdated(source, &fp);
        }
    }

    /// Decoder file choice for the playhead state. Stat-only (see `cached_lookup`), so warm the source first.
    /// Returns a proxy only for `Scrubbing`, or also for `Playback` when `settings.use_proxies_for_playback` is on.
    /// `Paused` always returns `None` (exact frames come from the original).
    pub fn file(
        &self,
        source: &Path,
        context: ProxyUseContext,
        settings: &ProxySettings,
        now: Timestamp,
    ) -> Option<ProxyLookup> {
        if !Self::uses_proxy(context, settings) {
            return None;
        }
        self.cached_lookup(source, &Self::SCRUB_PREFERENCE, now)
    }

    /// Whether the playhead state reads proxies at all.
    pub fn uses_proxy(context: ProxyUseContext, settings: &ProxySettings) -> bool {
        match context {
            ProxyUseContext::Scrubbing => true,
            ProxyUseContext::Playback => settings.use_proxies_for_playback,
            ProxyUseContext::Paused => false,
        }
    }

    /// The ready proxy `lookup` of `source` has other frame times than the original: see
    /// `ProxyCache::retire_mismatched`. `true` when it was thrown away and a new one will be made.
    pub fn retire_mismatched(&self, source: &Path, lookup: &ProxyLookup) -> bool {
        self.fingerprint(source, false).is_some_and(|fp| self.cache.retire_mismatched(&fp, lookup.kind))
    }

    /// Fires when any proxy becomes ready (the record's fingerprint identifies the source).
    pub fn ready_events(&self) -> Receiver<ProxyRecord> {
        self.cache.ready_records()
    }

    fn resolve(&self, fp: &SourceFingerprint, preferring: &[ProxyKind], now: Timestamp) -> Option<ProxyLookup> {
        preferring.iter().find_map(|&kind| {
            self.cache.current_lookup(fp, kind, now).map(|r| ProxyLookup {
                color_interpretation: ProxyColorInterpretation::FromSource,
                url: self.cache.file_url(&r),
                kind,
                dimensions: r.dimensions,
                scale_divisor: kind.scale_divisor(),
                record: Some(ProxyRecordID::new(&r)),
            })
        })
    }

    fn fingerprint(&self, path: &Path, compute: bool) -> Option<SourceFingerprint> {
        let meta = fs::metadata(path).ok()?;
        let size = i64::try_from(meta.len()).unwrap_or(i64::MAX);
        let millis = modified_millis(&meta, DISTANT_PAST_UNIX);
        let key = path.to_string_lossy().into_owned();
        if let Some(m) = self.memo.lock().unwrap_or_else(PoisonError::into_inner).get(&key)
            && m.size == size
            && m.modified_millis == millis
        {
            return Some(m.fingerprint.clone());
        }
        if !compute {
            return None;
        }
        let fp = SourceFingerprint::compute(path).ok()?;
        self.memo
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(key, Memo { size, modified_millis: millis, fingerprint: fp.clone() });
        Some(fp)
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn a_file_ffmpeg_cannot_open_has_no_fields() {
        assert!(!ProxyProvider::has_fields(Path::new("/no/such/file.mov")));
    }

    use super::*;
    use crate::model::test_support::*;
    use sq_core_time::Time;
    use std::collections::BTreeSet;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;

    fn now() -> Timestamp {
        Timestamp::from_unix_seconds(1.0)
    }

    fn commit(cache: &ProxyCache, src: &Path, kind: ProxyKind, build: i64) {
        let fp = SourceFingerprint::compute(src).unwrap();
        let mut r = ProxyRecord::new(
            fp.clone(),
            kind,
            ProxyCache::file_name(&fp, kind),
            ProxyDimensions { width: 1920, height: 1080 }.scaled(kind.scale_divisor()),
            now(),
            Time::new(5, 1),
        );
        r.build = build;
        let p = cache.partial_url(&fp, kind);
        fs::write(&p, b"x").unwrap();
        cache.commit(&p, &r).unwrap();
    }

    fn source(dir: &TempDir) -> PathBuf {
        let src = dir.join("clip.mov");
        write_file(&src, 500, 1);
        src
    }

    #[test]
    fn old_proxies_of_interlaced_sources_are_dropped() {
        for fields in [true, false] {
            let dir = TempDir::new();
            let src = source(&dir);
            let cache_dir = dir.join("c");
            let cache = Arc::new(ProxyCache::new(cache_dir.clone()));
            commit(&cache, &src, ProxyKind::ProxyHalf, 0);
            commit(&cache, &src, ProxyKind::Optimized, ProxyRecord::CURRENT_BUILD);
            let fp = SourceFingerprint::compute(&src).unwrap();
            assert_eq!(cache.outdated_kinds(&fp), vec![ProxyKind::ProxyHalf]);
            assert!(cache.current_lookup(&fp, ProxyKind::ProxyHalf, now()).is_none());
            let provider = ProxyProvider::with_interlaced(Arc::clone(&cache), Box::new(move |_| fields));
            assert!(provider.cached_lookup(&src, &[ProxyKind::ProxyHalf], now()).is_none());
            provider.warm(&src);
            let half = provider.cached_lookup(&src, &[ProxyKind::ProxyHalf], now());
            assert_eq!(half.is_none(), fields, "fields {fields}");
            let half_file = cache_dir.join(ProxyCache::file_name(&fp, ProxyKind::ProxyHalf));
            assert_eq!(half_file.exists(), !fields);
            let optimized = provider.cached_lookup(&src, &[ProxyKind::Optimized], now());
            assert_eq!(optimized.map(|l| l.kind), Some(ProxyKind::Optimized), "a new proxy is untouched");
            assert!(cache.outdated_kinds(&fp).is_empty());
            // The verdict is stored: the next launch does not ask again.
            let asked = Arc::new(AtomicBool::new(false));
            let flag = Arc::clone(&asked);
            let again = ProxyProvider::with_interlaced(
                Arc::new(ProxyCache::new(cache_dir)),
                Box::new(move |_| {
                    flag.store(true, Ordering::SeqCst);
                    true
                }),
            );
            assert_eq!(again.optimized_file(&src, &[ProxyKind::ProxyHalf], now()).is_none(), fields);
            assert!(!asked.load(Ordering::SeqCst), "asked twice");
        }
    }

    #[test]
    fn prefers_in_order_and_skips_missing() {
        let dir = TempDir::new();
        let src = source(&dir);
        let cache = Arc::new(ProxyCache::new(dir.join("c")));
        let provider = ProxyProvider::new(Arc::clone(&cache));
        assert!(provider.optimized_file(&src, &[ProxyKind::Optimized], now()).is_none());
        commit(&cache, &src, ProxyKind::ProxyQuarter, ProxyRecord::CURRENT_BUILD);
        let l = provider
            .optimized_file(&src, &[ProxyKind::Optimized, ProxyKind::ProxyHalf, ProxyKind::ProxyQuarter], now())
            .unwrap();
        assert!(l.kind == ProxyKind::ProxyQuarter && l.scale_divisor == 4);
        assert_eq!(l.dimensions, ProxyDimensions { width: 480, height: 270 });
        assert!(l.url.exists());
        commit(&cache, &src, ProxyKind::ProxyHalf, ProxyRecord::CURRENT_BUILD);
        let both = [ProxyKind::ProxyHalf, ProxyKind::ProxyQuarter];
        assert_eq!(provider.optimized_file(&src, &both, now()).map(|l| l.kind), Some(ProxyKind::ProxyHalf));
        assert!(provider.optimized_file(&src, &[], now()).is_none());
    }

    #[test]
    fn sync_variant_needs_warm_fingerprint() {
        let dir = TempDir::new();
        let src = source(&dir);
        let cache = Arc::new(ProxyCache::new(dir.join("c")));
        let provider = ProxyProvider::new(Arc::clone(&cache));
        commit(&cache, &src, ProxyKind::ProxyHalf, ProxyRecord::CURRENT_BUILD);
        assert!(provider.cached_lookup(&src, &[ProxyKind::ProxyHalf], now()).is_none()); // cold: never reads content
        provider.optimized_file(&src, &[ProxyKind::ProxyHalf], now());
        assert_eq!(
            provider.cached_lookup(&src, &[ProxyKind::ProxyHalf], now()).map(|l| l.kind),
            Some(ProxyKind::ProxyHalf)
        );
        // file modified -> stat mismatch -> cold again
        write_file(&src, 600, 1);
        assert!(provider.cached_lookup(&src, &[ProxyKind::ProxyHalf], now()).is_none());
    }

    #[test]
    fn survives_rename_of_source() {
        let dir = TempDir::new();
        let src = source(&dir);
        let cache = Arc::new(ProxyCache::new(dir.join("c")));
        let provider = ProxyProvider::new(Arc::clone(&cache));
        commit(&cache, &src, ProxyKind::ProxyHalf, ProxyRecord::CURRENT_BUILD);
        let moved = dir.join("moved.mov");
        fs::rename(&src, &moved).unwrap();
        assert!(provider.optimized_file(&moved, &[ProxyKind::ProxyHalf], now()).is_some());
    }

    #[test]
    fn ready_events() {
        let dir = TempDir::new();
        let src = source(&dir);
        let cache = Arc::new(ProxyCache::new(dir.join("c")));
        let provider = ProxyProvider::new(Arc::clone(&cache));
        let rx = provider.ready_events();
        commit(&cache, &src, ProxyKind::Optimized, ProxyRecord::CURRENT_BUILD);
        let ev = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(ev.kind, ProxyKind::Optimized);
        assert_eq!(ev.fingerprint, SourceFingerprint::compute(&src).unwrap());
    }

    #[test]
    fn a_refused_proxy_is_thrown_away_once() {
        let dir = TempDir::new();
        let src = source(&dir);
        let cache = Arc::new(ProxyCache::new(dir.join("c")));
        let provider = ProxyProvider::with_interlaced(Arc::clone(&cache), Box::new(|_| false));
        let removed = cache.removed_records();
        let kinds = [ProxyKind::ProxyHalf];
        commit(&cache, &src, ProxyKind::ProxyHalf, ProxyRecord::CURRENT_BUILD);
        let hit = provider.optimized_file(&src, &kinds, now()).unwrap();
        assert!(provider.retire_mismatched(&src, &hit), "first refusal: thrown away");
        assert!(provider.optimized_file(&src, &kinds, now()).is_none());
        assert_eq!(removed.try_iter().count(), 1);
        assert!(cache.take_retired(&hit.record.clone().unwrap()), "the service is told once");
        assert!(!cache.take_retired(&hit.record.clone().unwrap()));
        // The new proxy differs too: it stays, nothing is made a third time.
        commit(&cache, &src, ProxyKind::ProxyHalf, ProxyRecord::CURRENT_BUILD);
        let hit = provider.optimized_file(&src, &kinds, now()).unwrap();
        assert!(!provider.retire_mismatched(&src, &hit), "second refusal: kept");
        assert!(provider.optimized_file(&src, &kinds, now()).is_some());
        assert_eq!(removed.try_iter().count(), 0);
    }

    #[test]
    fn the_once_marker_survives_a_restart() {
        let dir = TempDir::new();
        let src = source(&dir);
        let fp = SourceFingerprint::compute(&src).unwrap();
        let kind = ProxyKind::ProxyHalf;
        let cache = ProxyCache::new(dir.join("c"));
        commit(&cache, &src, kind, ProxyRecord::CURRENT_BUILD);
        // The service protects its ready proxy; the replacement still goes ahead.
        cache.set_protected(BTreeSet::from([ProxyRecordID::of(&fp, kind)]));
        assert!(cache.retire_mismatched(&fp, kind));
        // A new app start: the new proxy differs too and stays.
        let cache = ProxyCache::new(dir.join("c"));
        commit(&cache, &src, kind, ProxyRecord::CURRENT_BUILD);
        assert!(!cache.retire_mismatched(&fp, kind), "once across a reload");
        assert!(cache.lookup(&fp, kind, now()).is_some());
    }

    #[test]
    fn scrubbing_only_by_default() {
        let s = ProxySettings::default();
        assert!(ProxyProvider::uses_proxy(ProxyUseContext::Scrubbing, &s));
        assert!(!ProxyProvider::uses_proxy(ProxyUseContext::Playback, &s));
        assert!(!ProxyProvider::uses_proxy(ProxyUseContext::Paused, &s));
    }

    #[test]
    fn toggle_adds_playback_but_paused_stays_original() {
        let s = ProxySettings { use_proxies_for_playback: true, ..ProxySettings::default() };
        assert!(ProxyProvider::uses_proxy(ProxyUseContext::Scrubbing, &s));
        assert!(ProxyProvider::uses_proxy(ProxyUseContext::Playback, &s));
        assert!(!ProxyProvider::uses_proxy(ProxyUseContext::Paused, &s));
    }

    #[test]
    fn provider_file_honors_context() {
        let dir = TempDir::new();
        let src = source(&dir);
        let cache = Arc::new(ProxyCache::new(dir.join("c")));
        let provider = ProxyProvider::new(Arc::clone(&cache));
        commit(&cache, &src, ProxyKind::ProxyHalf, ProxyRecord::CURRENT_BUILD);
        provider.warm(&src);
        let off = ProxySettings::default();
        let on = ProxySettings { use_proxies_for_playback: true, ..off };
        let scrub = provider.file(&src, ProxyUseContext::Scrubbing, &off, now()).unwrap();
        assert_eq!(scrub.kind, ProxyKind::ProxyHalf);
        assert_eq!(scrub.color_interpretation, ProxyColorInterpretation::FromSource);
        assert!(provider.file(&src, ProxyUseContext::Playback, &off, now()).is_none());
        assert!(provider.file(&src, ProxyUseContext::Playback, &on, now()).is_some());
        assert!(provider.file(&src, ProxyUseContext::Paused, &on, now()).is_none());
    }

    #[test]
    fn lookup_carries_the_record_id() {
        let dir = TempDir::new();
        let src = dir.join("src.mov");
        write_file(&src, 300_000, 1);
        let cache = Arc::new(ProxyCache::new(dir.join("cache")));
        commit(&cache, &src, ProxyKind::ProxyHalf, ProxyRecord::CURRENT_BUILD);
        let provider = ProxyProvider::new(Arc::clone(&cache));
        let hit = provider.optimized_file(&src, &ProxyProvider::SCRUB_PREFERENCE, now()).unwrap();
        let fp = SourceFingerprint::compute(&src).unwrap();
        assert_eq!(hit.record, Some(ProxyRecordID::of(&fp, ProxyKind::ProxyHalf)));
    }
}
