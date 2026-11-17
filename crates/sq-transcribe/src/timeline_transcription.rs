// Swift: TimelineTranscription.swift (the channel-map rendering is AVFoundation on the Mac and `unavailable` elsewhere; this
// port is the elsewhere path, see NOTES.md)
//! Transcript of a whole sequence.

use crate::transcript::{Transcript, TranscriptWord};
use crate::transcription_service::{CancelToken, Locale, TranscriptionError, TranscriptionService};
use sq_core_model::{AudioChannelMap, Clip, ClipSpeed, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time, TimeRange};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// What a transcript depends on: position, source range, speed and media of every audible clip, plus the frame duration.
/// A different layout means the stored sequence-time words no longer match the timeline.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Layout {
    entries: Vec<LayoutEntry>,
    frame_duration: Time,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct LayoutEntry {
    id: Id,
    media: Id,
    start: Time,
    source: TimeRange,
    speed: ClipSpeed,
}

/// Transcript of a whole sequence (Transcribe Sequence). Every audible audio clip is looked up by its media file;
/// each file is transcribed once (cached per call), and the words that fall inside a clip's used source range are mapped
/// to sequence time through the clip's position and speed. Words of all clips end up in one list sorted by time.
pub struct TimelineTranscription;

impl TimelineTranscription {
    /// Audio clips that are heard: audio tracks that are not muted (and, when any track is soloed, only soloed ones),
    /// enabled clips with media. Generators, stills, nested sequences and reversed or frame-held clips are left out
    /// (no usable word order).
    pub fn audible_clips(timeline: &Timeline) -> Vec<&Clip> {
        let audio: Vec<_> = timeline.tracks.iter().filter(|t| t.kind == TrackKind::Audio).collect();
        let any_solo = audio.iter().any(|t| t.is_solo);
        let mut clips: Vec<&Clip> = audio
            .iter()
            .filter(|t| !t.is_muted && (!any_solo || t.is_solo))
            .flat_map(|t| t.clips())
            .filter(|c| {
                c.is_enabled
                    && !c.is_generator()
                    && !c.is_nested()
                    && !c.reversed
                    && c.hold_frame.is_none()
                    && c.speed_keys.is_none()
            })
            .collect();
        clips.sort_by_key(|c| c.start);
        clips
    }

    /// The layout a transcript of `timeline` belongs to.
    pub fn layout(timeline: &Timeline) -> Layout {
        Layout {
            entries: Self::audible_clips(timeline)
                .iter()
                .map(|c| LayoutEntry { id: c.id, media: c.media, start: c.start, source: c.source, speed: c.speed })
                .collect(),
            frame_duration: timeline.format.frame_duration,
        }
    }

    /// Words of the clip's media (source time) that the clip plays, moved to sequence time. A word belongs to the clip when
    /// its midpoint lies inside the used source range; its ends are clamped to the clip.
    pub fn map_words(words: &[TranscriptWord], clip: &Clip, frame_duration: Time) -> Vec<TranscriptWord> {
        if clip.reversed || clip.hold_frame.is_some() {
            return Vec::new();
        }
        let src = clip.source;
        let span = clip.timeline();
        words
            .iter()
            .filter_map(|word| {
                let sum = word.range.start + word.range.end();
                let mid = Time::new(sum.value(), sum.timescale() * 2);
                if !(mid >= src.start && mid < src.end()) {
                    return None;
                }
                let a = clip
                    .timeline_time_for_source(word.range.start.max(src.start), frame_duration)
                    .max(span.start)
                    .min(span.end());
                let b = clip
                    .timeline_time_for_source(word.range.end().min(src.end()), frame_duration)
                    .max(a)
                    .min(span.end());
                let mut out = word.clone();
                out.range = TimeRange::from_end(a, b);
                Some(out)
            })
            .collect()
    }

    /// Transcribes every audible clip's media once and merges the mapped words into one transcript in sequence time.
    /// `urls` resolves media IDs to files; clips whose media has no URL are skipped. Fails with `NoAudio` when nothing is
    /// audible. `channel_maps`: media whose clips play chosen channels are transcribed from those channels on the Mac; here
    /// such media fail with `Unavailable`.
    #[allow(clippy::too_many_arguments, reason = "the Swift signature, one value per parameter")]
    pub fn transcribe(
        timeline: &Timeline,
        urls: &BTreeMap<Id, PathBuf>,
        channel_maps: &BTreeMap<Id, AudioChannelMap>,
        expected_channels: &BTreeMap<Id, i64>,
        service: &dyn TranscriptionService,
        locale: &Locale,
        progress: &mut dyn FnMut(f64),
        cancel: &CancelToken,
        ids: &mut dyn IdSource,
    ) -> Result<Transcript, TranscriptionError> {
        let clips: Vec<&Clip> =
            Self::audible_clips(timeline).into_iter().filter(|c| urls.contains_key(&c.media)).collect();
        if clips.is_empty() {
            return Err(TranscriptionError::NoAudio);
        }
        let mut order: Vec<Id> = Vec::new();
        for c in &clips {
            if !order.contains(&c.media) {
                order.push(c.media);
            }
        }
        let mut per_media: BTreeMap<Id, Vec<TranscriptWord>> = BTreeMap::new();
        for (i, media) in order.iter().enumerate() {
            cancel.check()?;
            let Some(url) = urls.get(media) else { continue };
            let (base, count) = (i as f64, order.len() as f64);
            let t = Self::transcribe_one(
                url,
                channel_maps.get(media),
                expected_channels.get(media).copied(),
                service,
                locale,
                &mut |p| progress((base + p) / count),
                cancel,
                ids,
            )?;
            per_media.insert(*media, t.words);
        }
        let mut words: Vec<TranscriptWord> = Vec::new();
        // Clips that play the same recording at overlapping times (A1 + A2, overlapped clips) would give every word twice:
        // a word is dropped when an earlier clip of the same media already produced a word overlapping it in time.
        let mut kept: BTreeMap<Id, Vec<TimeRange>> = BTreeMap::new();
        for clip in &clips {
            let earlier = kept.entry(clip.media).or_default();
            let empty = Vec::new();
            let mapped =
                Self::map_words(per_media.get(&clip.media).unwrap_or(&empty), clip, timeline.format.frame_duration);
            let mine: Vec<TranscriptWord> = mapped
                .into_iter()
                .filter(|w| !earlier.iter().any(|k| k.start < w.range.end() && w.range.start < k.end()))
                .collect();
            earlier.extend(mine.iter().map(|w| w.range));
            words.extend(mine);
        }
        words.sort_by_key(|w| w.range.start);
        progress(1.0);
        Ok(Transcript::new(&locale.bcp47(), words))
    }

    /// One media file: from the file itself, or from the channels `map` names.
    // The service renders the map (`transcribe_mapped`): the FFmpeg audio sources off the Mac.
    #[allow(clippy::too_many_arguments, reason = "the Swift signature, one value per parameter")]
    fn transcribe_one(
        url: &Path,
        map: Option<&AudioChannelMap>,
        _expected_channels: Option<i64>,
        service: &dyn TranscriptionService,
        locale: &Locale,
        progress: &mut dyn FnMut(f64),
        cancel: &CancelToken,
        ids: &mut dyn IdSource,
    ) -> Result<Transcript, TranscriptionError> {
        service.transcribe_mapped(url, map, locale, progress, cancel, ids)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::test_support::{t, w};
    use sq_core_model::{SequenceFormat, SpeedKeys, Track};
    use sq_core_time::SequentialIds;
    use std::sync::Mutex;

    fn fd() -> Time {
        Time::new(1, 30)
    }

    fn aclip(media: Id, source: (i64, i64), start: i64, speed: ClipSpeed, enabled: bool) -> Clip {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1000);
        let id = Id::fixed(NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
        let mut c =
            Clip::new(id, "a", media, TrackKind::Audio, TimeRange::from_end(t(source.0), t(source.1)), t(start));
        c.media_duration = Some(t(60_000));
        c.speed = speed;
        c.is_enabled = enabled;
        c
    }

    fn clip(media: Id, source: (i64, i64), start: i64) -> Clip {
        aclip(media, source, start, ClipSpeed::NORMAL, true)
    }

    fn track(n: u64, kind: TrackKind, clips: Vec<Clip>) -> Track {
        let mut tr = Track::new(Id::fixed(n), kind);
        tr.set_clips(clips);
        tr
    }

    fn timeline(tracks: Vec<Track>) -> Timeline {
        Timeline::new(Id::fixed(1), "S", SequenceFormat::new(fd()), tracks)
    }

    fn texts(w: &[TranscriptWord]) -> Vec<&str> {
        w.iter().map(|w| w.text.as_str()).collect()
    }

    #[test]
    fn shifts_words_by_clip_position() {
        let c = clip(Id::fixed(1), (2000, 6000), 10_000);
        let out = TimelineTranscription::map_words(&[w("hallo", 2500, 3000), w("welt", 3000, 3500)], &c, fd());
        assert_eq!(texts(&out), ["hallo", "welt"]);
        assert!(out[0].range.start == t(10_500) && out[0].range.end() == t(11_000));
        assert_eq!(out[1].range.start, t(11_000));
    }

    #[test]
    fn drops_words_outside_the_used_source_range() {
        let c = clip(Id::fixed(1), (2000, 4000), 0);
        let out = TimelineTranscription::map_words(
            &[w("vor", 500, 1500), w("drin", 2500, 3000), w("nach", 4500, 5000)],
            &c,
            fd(),
        );
        assert_eq!(texts(&out), ["drin"]);
    }

    #[test]
    fn word_cut_by_clip_edge_is_clamped_or_dropped_by_midpoint() {
        let c = clip(Id::fixed(1), (2000, 4000), 1000);
        // 1800..2400: midpoint 2100 inside -> kept, start clamped to the clip start.
        // 3800..4800: midpoint 4300 outside -> dropped.
        let out = TimelineTranscription::map_words(&[w("a", 1800, 2400), w("b", 3800, 4800)], &c, fd());
        assert_eq!(texts(&out), ["a"]);
        assert!(out[0].range.start == t(1000) && out[0].range.end() == t(1400));
    }

    #[test]
    fn double_speed_halves_durations() {
        let c = aclip(Id::fixed(1), (0, 4000), 5000, ClipSpeed::new(2, 1), true);
        let out = TimelineTranscription::map_words(&[w("schnell", 1000, 2000)], &c, fd());
        assert!(out[0].range.start == t(5500) && out[0].range.end() == t(6000));
    }

    #[test]
    fn half_speed_doubles_durations() {
        let c = aclip(Id::fixed(1), (1000, 3000), 0, ClipSpeed::new(1, 2), true);
        let out = TimelineTranscription::map_words(&[w("langsam", 1000, 1500)], &c, fd());
        assert!(out[0].range.start == t(0) && out[0].range.end() == t(1000));
    }

    #[test]
    fn reversed_clip_yields_no_words() {
        let mut c = clip(Id::fixed(1), (0, 4000), 0);
        c.reversed = true;
        assert!(TimelineTranscription::map_words(&[w("x", 1000, 2000)], &c, fd()).is_empty());
    }

    #[test]
    fn audible_clips_honour_mute_solo_enabled_and_kind() {
        let m = Id::fixed(1);
        let a1 = track(10, TrackKind::Audio, vec![clip(m, (0, 1000), 0)]);
        let mut a2 = track(11, TrackKind::Audio, vec![clip(m, (0, 1000), 2000)]);
        a2.is_muted = true;
        let a3 = track(12, TrackKind::Audio, vec![aclip(m, (0, 1000), 4000, ClipSpeed::NORMAL, false)]);
        let v = track(
            13,
            TrackKind::Video,
            vec![Clip::new(Id::fixed(99), "v", m, TrackKind::Video, TimeRange::from_end(t(0), t(1000)), t(0))],
        );
        assert_eq!(TimelineTranscription::audible_clips(&timeline(vec![v, a1.clone(), a2.clone(), a3])).len(), 1);
        let mut solo = a2;
        solo.is_muted = false;
        solo.is_solo = true;
        let tl = timeline(vec![a1, solo]);
        let clips = TimelineTranscription::audible_clips(&tl);
        assert!(clips.len() == 1 && clips[0].start == t(2000));
    }

    struct FakeService {
        words: BTreeMap<PathBuf, Vec<TranscriptWord>>,
        calls: Mutex<usize>,
    }

    impl TranscriptionService for FakeService {
        fn transcribe(
            &self,
            url: &Path,
            locale: &Locale,
            progress: &mut dyn FnMut(f64),
            _cancel: &CancelToken,
            _ids: &mut dyn IdSource,
        ) -> Result<Transcript, TranscriptionError> {
            *self.calls.lock().unwrap() += 1;
            progress(1.0);
            Ok(Transcript::new(&locale.bcp47(), self.words.get(url).cloned().unwrap_or_default()))
        }
    }

    fn run(
        tl: &Timeline,
        urls: &BTreeMap<Id, PathBuf>,
        service: &FakeService,
    ) -> Result<Transcript, TranscriptionError> {
        TimelineTranscription::transcribe(
            tl,
            urls,
            &BTreeMap::new(),
            &BTreeMap::new(),
            service,
            &Locale::new("de-DE"),
            &mut |_| {},
            &CancelToken::new(),
            &mut SequentialIds::default(),
        )
    }

    #[test]
    fn three_clips_with_gaps_give_one_sorted_transcript() {
        let (m1, m2) = (Id::fixed(1), Id::fixed(2));
        let c1 = clip(m1, (0, 2000), 0);
        let c2 = clip(m2, (1000, 3000), 5000); // gap 2..5 s
        let c3 = clip(m1, (4000, 6000), 8000); // same media, later part
        let tl = timeline(vec![track(10, TrackKind::Audio, vec![c1, c2, c3])]);
        let (a, b) = (PathBuf::from("/a.wav"), PathBuf::from("/b.wav"));
        let service = FakeService {
            words: BTreeMap::from([
                (a.clone(), vec![w("eins", 500, 900), w("weg", 2500, 3000), w("drei", 4500, 5000)]),
                (b.clone(), vec![w("zwei", 1200, 1800)]),
            ]),
            calls: Mutex::new(0),
        };
        let tr = run(&tl, &BTreeMap::from([(m1, a), (m2, b)]), &service).unwrap();
        assert_eq!(texts(&tr.words), ["eins", "zwei", "drei"]);
        assert_eq!(tr.words[1].range.start, t(5200));
        assert_eq!(tr.words[2].range.start, t(8500));
        assert_eq!(*service.calls.lock().unwrap(), 2); // each source file once
        assert_eq!(tr.language, "de-DE");
    }

    #[test]
    fn overlapping_clips_of_same_media_give_no_duplicate_words() {
        let m = Id::fixed(1);
        let a = PathBuf::from("/a.wav");
        // A1 and A2 play the same recording at the same time.
        let tl = timeline(vec![
            track(10, TrackKind::Audio, vec![clip(m, (0, 4000), 0)]),
            track(11, TrackKind::Audio, vec![clip(m, (0, 4000), 0)]),
        ]);
        let service = FakeService {
            words: BTreeMap::from([(a.clone(), vec![w("eins", 500, 900), w("zwei", 1000, 1500)])]),
            calls: Mutex::new(0),
        };
        let tr = run(&tl, &BTreeMap::from([(m, a)]), &service).unwrap();
        assert_eq!(texts(&tr.words), ["eins", "zwei"]);
    }

    #[test]
    fn clips_with_speed_keys_are_not_audible() {
        let mut c = clip(Id::fixed(1), (0, 4000), 0);
        c.speed_keys = Some(SpeedKeys::constant(ClipSpeed::new(2, 1), false, c.source.duration, c.source.start));
        assert!(TimelineTranscription::audible_clips(&timeline(vec![track(10, TrackKind::Audio, vec![c])])).is_empty());
    }

    #[test]
    fn layout_changes_when_a_clip_is_trimmed_moved_or_retimed() {
        let base = clip(Id::fixed(1), (0, 4000), 0);
        let layout =
            |c: &Clip| TimelineTranscription::layout(&timeline(vec![track(10, TrackKind::Audio, vec![c.clone()])]));
        let l0 = layout(&base);
        let mut moved = base.clone();
        moved.start = t(1000);
        let mut trimmed = base.clone();
        trimmed.source = TimeRange::from_end(t(0), t(3000));
        let mut fast = base.clone();
        fast.speed = ClipSpeed::new(2, 1);
        for c in [moved, trimmed, fast] {
            assert_ne!(layout(&c), l0);
        }
        assert_eq!(layout(&base), l0);
    }

    #[test]
    fn no_audible_clips_fails_with_no_audio() {
        let tl = timeline(vec![track(10, TrackKind::Audio, vec![])]);
        let service = FakeService { words: BTreeMap::new(), calls: Mutex::new(0) };
        assert_eq!(run(&tl, &BTreeMap::new(), &service), Err(TranscriptionError::NoAudio));
    }
}
