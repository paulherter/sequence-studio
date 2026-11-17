// Swift: MagicTrackHealthCache.swift
//! Weak stretches of tracked Magic masks for the timeline's confidence strip (MASK-UX 5.4) and "Go to Next Weak
//! Tracking", by matte cache key. Computed off the UI thread from the stored matte areas the first time a key is asked
//! for, then served from memory; `forget` after a Track run so the next ask recomputes. The platform supplies where the
//! matte areas come from.
//!
//! The Swift cache detaches a task per key. Here the cache hands out [`HealthJob`]s ([`MagicTrackHealthCache::take_jobs`]);
//! the host runs each on a worker and feeds the [`HealthResult`] to [`MagicTrackHealthCache::finish`].

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use sq_core_masks::magic_mask::MagicSelectionExt;
use sq_core_masks::magic_track_health::{HealthSample, HealthSpan, MagicTrackHealth};
use sq_core_masks::masks::ClipMasksExt;
use sq_core_model::{Clip, MaskSource, Timeline, TrackKind};
use sq_core_time::Time;

/// The coverage of every stored frame of a matte key; runs off the UI thread.
// Swift: MagicTrackHealthCache.swift:13
pub type HealthSamples = Arc<dyn Fn(&str) -> Vec<HealthSample> + Send + Sync>;

/// What a cache tells its host (Swift `onForget`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MagicTrackHealthEvent {
    /// `forget` ran: the host drops what else it keeps per key (the Mac's key lanes).
    // Swift: MagicTrackHealthCache.swift:21
    Forgotten,
}

/// One key to compute on a worker.
pub struct HealthJob {
    key: String,
    samples: HealthSamples,
}

/// The answer of a [`HealthJob`].
#[derive(Clone, Debug, PartialEq)]
pub struct HealthResult {
    key: String,
    spans: Option<Vec<HealthSpan>>,
}

impl HealthJob {
    /// Reads the stored areas and finds the weak stretches (three frames at least, else no answer).
    pub fn run(self) -> HealthResult {
        let all = (self.samples)(&self.key);
        let spans = (all.len() >= 3).then(|| MagicTrackHealth::weak_spans(&all));
        HealthResult { key: self.key, spans }
    }
}

/// Where the next weak stretch is (Go to Next Weak Tracking).
// Swift: MagicTrackHealthCache.swift:61
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WeakJump {
    Found(Time),
    /// Tracked masks exist but no weak stretch begins after the playhead.
    None,
    NoTrackedMask,
    /// A clip's stretches are still being computed (the first ask starts it).
    Pending,
}

/// Weak stretches of tracked Magic masks by matte key.
// Swift: MagicTrackHealthCache.swift:11
pub struct MagicTrackHealthCache {
    spans: BTreeMap<String, Vec<HealthSpan>>,
    pending: BTreeSet<String>,
    samples: HealthSamples,
    jobs: Vec<HealthJob>,
    events: Vec<MagicTrackHealthEvent>,
    version: u64,
}

impl MagicTrackHealthCache {
    // Swift: MagicTrackHealthCache.swift:22
    pub fn new(samples: HealthSamples) -> MagicTrackHealthCache {
        MagicTrackHealthCache {
            spans: BTreeMap::new(),
            pending: BTreeSet::new(),
            samples,
            jobs: Vec::new(),
            events: Vec::new(),
            version: 0,
        }
    }

    /// Bumped when computed spans arrived or were forgotten: the strip draws again (Swift `onChange`).
    // Swift: MagicTrackHealthCache.swift:19
    pub fn version(&self) -> u64 {
        self.version
    }

    /// The matte cache key of the clip's tracked Magic mask, `None` when it has none.
    // Swift: MagicTrackHealthCache.swift:26
    pub fn key(&self, clip: &Clip) -> Option<String> {
        if clip.sequence.is_some() || clip.is_generator() || clip.is_still {
            return None;
        }
        clip.masks()
            .iter()
            .find(|m| m.source() == MaskSource::Magic && m.magic.as_ref().is_some_and(|g| !g.points.is_empty()))
            .and_then(|m| m.magic.as_ref())
            .map(|g| g.cache_key(clip.media))
    }

    /// True while the clip's weak stretches are being computed.
    // Swift: MagicTrackHealthCache.swift:32
    pub fn is_pending(&self, clip: &Clip) -> bool {
        self.key(clip).is_some_and(|k| self.pending.contains(&k))
    }

    /// `None` = the clip has no Magic mask with stored mattes (no strip), or the answer is still being computed (the
    /// first ask queues the job).
    // Swift: MagicTrackHealthCache.swift:35
    pub fn weak_spans(&mut self, clip: &Clip) -> Option<Vec<HealthSpan>> {
        let key = self.key(clip)?;
        if let Some(s) = self.spans.get(&key) {
            return Some(s.clone());
        }
        if self.pending.insert(key.clone()) {
            self.jobs.push(HealthJob { key, samples: Arc::clone(&self.samples) });
        }
        None
    }

    /// The jobs queued by `weak_spans` since the last call: run each on a worker.
    pub fn take_jobs(&mut self) -> Vec<HealthJob> {
        std::mem::take(&mut self.jobs)
    }

    /// A worker's answer. A key that was forgotten meanwhile is asked again by the next `weak_spans`.
    pub fn finish(&mut self, result: HealthResult) {
        self.pending.remove(&result.key);
        if let Some(spans) = result.spans {
            self.spans.insert(result.key, spans);
            self.version += 1;
        }
    }

    /// Tracking changed the mattes: every key is read again on its next ask.
    // Swift: MagicTrackHealthCache.swift:53
    pub fn forget(&mut self) {
        self.spans.clear();
        self.events.push(MagicTrackHealthEvent::Forgotten);
        self.version += 1;
    }

    /// The host events since the last call.
    pub fn take_events(&mut self) -> Vec<MagicTrackHealthEvent> {
        std::mem::take(&mut self.events)
    }

    // MARK: Go to Next Weak Tracking

    /// "Go to Next Weak Tracking" (Option+Shift+M, Markers menu): where the next weak stretch of a tracked Magic mask
    /// begins, over every video clip of the sequence (the confidence strip's amber stretches).
    // Swift: MagicTrackHealthCache.swift:72
    pub fn next_weak_start(&mut self, t: Time, timeline: Option<&Timeline>) -> WeakJump {
        let Some(tl) = timeline else { return WeakJump::NoTrackedMask };
        let clips: Vec<Clip> = tl
            .tracks
            .iter()
            .flat_map(|tr| tr.clips().iter())
            .filter(|c| c.kind == TrackKind::Video && self.key(c).is_some())
            .cloned()
            .collect();
        if clips.is_empty() {
            return WeakJump::NoTrackedMask;
        }
        let known: BTreeMap<sq_core_time::Id, Vec<HealthSpan>> =
            clips.iter().filter_map(|c| self.weak_spans(c).map(|s| (c.id, s))).collect();
        if let Some(next) =
            MagicTrackHealth::next_weak_start(t, &clips, &|c| known.get(&c.id).cloned(), tl.frame_duration())
        {
            return WeakJump::Found(next);
        }
        if clips.iter().any(|c| self.is_pending(c)) { WeakJump::Pending } else { WeakJump::None }
    }

    /// The status line of a jump that did not find a stretch; `None` when it did.
    // Swift: MagicTrackHealthCache.swift:83
    pub fn message(jump: WeakJump) -> Option<&'static str> {
        match jump {
            WeakJump::Found(_) => None,
            WeakJump::None => Some("No weak tracking after the playhead."),
            WeakJump::NoTrackedMask => Some("No tracked Magic mask in this sequence."),
            WeakJump::Pending => Some("Checking the tracking. Try again in a moment."),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::{ClipMask, MagicPoint, MagicSelection, TrackKind};
    use sq_core_time::{SequentialIds, TimeRange, Vec2};

    fn tracked_clip(ids: &mut SequentialIds) -> Clip {
        use sq_core_time::IdSource;
        let media = ids.next_id();
        let mut c = Clip::new(
            ids.next_id(),
            "A",
            media,
            TrackKind::Video,
            TimeRange::new(Time::ZERO, Time::new(10, 1)),
            Time::ZERO,
        );
        let mut m = ClipMask::make_subject(ids.next_id(), "Magic");
        m.source_store = Some(MaskSource::Magic);
        m.magic = Some(MagicSelection {
            points: vec![MagicPoint { position: Vec2::new(0.5, 0.5), subtract: false, source_time: Time::ZERO }],
            part: None,
        });
        c.set_masks(vec![m]);
        c
    }

    fn samples() -> HealthSamples {
        // 10 frames at 1 s; frame 4 nearly loses the subject.
        Arc::new(|_| {
            (0..10).map(|i| HealthSample { pts: f64::from(i), area: if i == 4 { 0.01 } else { 0.3 } }).collect()
        })
    }

    #[test]
    fn key_needs_a_magic_mask_with_points() {
        let mut ids = SequentialIds::default();
        let cache = MagicTrackHealthCache::new(samples());
        let c = tracked_clip(&mut ids);
        assert!(cache.key(&c).is_some());
        let mut plain = c.clone();
        plain.set_masks(vec![]);
        assert_eq!(cache.key(&plain), None);
        let mut still = c;
        still.is_still = true;
        assert_eq!(cache.key(&still), None);
    }

    #[test]
    fn the_first_ask_queues_one_job_and_the_answer_is_served_from_memory() {
        let mut ids = SequentialIds::default();
        let mut cache = MagicTrackHealthCache::new(samples());
        let c = tracked_clip(&mut ids);
        assert_eq!(cache.weak_spans(&c), None);
        assert_eq!(cache.weak_spans(&c), None);
        assert!(cache.is_pending(&c));
        let jobs = cache.take_jobs();
        assert_eq!(jobs.len(), 1);
        let before = cache.version();
        for j in jobs {
            cache.finish(j.run());
        }
        assert!(!cache.is_pending(&c) && cache.version() > before);
        let spans = cache.weak_spans(&c).expect("served");
        assert!(spans.iter().any(|s| s.start <= 4.0 && s.end > 4.0));
        cache.forget();
        assert_eq!(cache.take_events(), vec![MagicTrackHealthEvent::Forgotten]);
        assert_eq!(cache.weak_spans(&c), None);
    }

    #[test]
    fn too_few_frames_give_no_answer_and_messages_read_well() {
        let mut ids = SequentialIds::default();
        let mut cache = MagicTrackHealthCache::new(Arc::new(|_| vec![HealthSample { pts: 0.0, area: 0.2 }]));
        let c = tracked_clip(&mut ids);
        cache.weak_spans(&c);
        for j in cache.take_jobs() {
            cache.finish(j.run());
        }
        assert_eq!(cache.weak_spans(&c), None); // asked again, not cached
        assert_eq!(MagicTrackHealthCache::message(WeakJump::Found(Time::ZERO)), None);
        assert_eq!(
            MagicTrackHealthCache::message(WeakJump::NoTrackedMask),
            Some("No tracked Magic mask in this sequence.")
        );
        assert_eq!(MagicTrackHealthCache::next_weak_start(&mut cache, Time::ZERO, None), WeakJump::NoTrackedMask);
    }
}
