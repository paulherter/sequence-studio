//! The offline audio of an export: the playback feeder (`sq-playback`) mixes the sequence into a small ring, the same
//! mixer the Program monitor plays, so the file sounds like the preview.

use sq_core_model::{AudioChannelMap, Timeline};
use sq_core_time::Id;
use sq_export::core::timeline_audio::MixFeed;
use sq_media::media_error::MediaError;
use sq_media_ffmpeg::decode::FFmpegAudioSource;
use sq_playback::audio::{AudioFeeder, FeederHandle, Resolver, SAMPLE_RATE, WaveformSilences};
use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, OnceLock};

/// Frames per mix block (the playback value).
const BLOCK_FRAMES: usize = 1024;

/// The app's dialogue pause store (Swift `TimelineWaveforms.silences`): the waveform reads push into it
/// (`TimelineMedia`), playback asks it from the mix thread (unknown clips are analyzed on its own utility thread, never
/// on the UI or mix thread) and every export mixes through `for_export()` of the same store.
pub fn app_silences() -> &'static Arc<WaveformSilences> {
    static STORE: OnceLock<Arc<WaveformSilences>> = OnceLock::new();
    STORE.get_or_init(|| Arc::new(WaveformSilences::default()))
}

/// Drops the pauses of clips that left every sequence (Swift `WaveformSilences.prune`, on every timeline change).
pub fn prune_silences(store: &WaveformSilences, timelines: &[Timeline]) {
    let keep: std::collections::HashSet<Id> =
        timelines.iter().flat_map(|t| t.tracks.iter()).flat_map(|tr| tr.clips()).map(|c| c.id).collect();
    store.prune(&keep);
}

/// A feeder that renders blocks on demand into a queue of stereo frames.
pub struct FeederMix {
    feeder: AudioFeeder,
    handle: FeederHandle,
    ring: VecDeque<(f32, f32)>,
}

impl FeederMix {
    /// A mix of `timeline` (and the sequences nested in it); `paths` names the file of every media and `maps` the Audio
    /// Channels of the items that have one (a multi-track file mixes the channels the map names, as playback does).
    pub fn new(
        timeline: &Timeline,
        sequences: HashMap<Id, Timeline>,
        paths: HashMap<Id, PathBuf>,
        maps: HashMap<Id, AudioChannelMap>,
    ) -> FeederMix {
        let resolver: Resolver = Arc::new(move |id| {
            let path = paths.get(&id).ok_or(MediaError::Unreadable)?;
            Ok(Arc::from(FFmpegAudioSource::open_mapped(path, SAMPLE_RATE as i32, maps.get(&id))?))
        });
        FeederMix::with_resolver(timeline, sequences, resolver, app_silences())
    }

    /// Like [`FeederMix::new`] with the sources from `resolver` and the dialogue pauses from `silences` (read through
    /// its export view, so the answer never depends on background timing).
    pub fn with_resolver(
        timeline: &Timeline,
        sequences: HashMap<Id, Timeline>,
        resolver: Resolver,
        silences: &WaveformSilences,
    ) -> FeederMix {
        let feeder = AudioFeeder::new(timeline.clone(), BLOCK_FRAMES, resolver);
        let handle = feeder.handle();
        handle.set_dialogue_silences(Some(Arc::new(silences.for_export())));
        handle.set_timeline(timeline.clone(), Some(sequences));
        FeederMix { feeder, handle, ring: VecDeque::new() }
    }
}

impl MixFeed for FeederMix {
    fn seek(&mut self, frame: i64) {
        self.ring.clear();
        self.handle.seek(frame, false);
    }

    fn prime(&mut self) -> usize {
        self.fill(1);
        self.feeder.output_latency_samples()
    }

    fn fill(&mut self, max_blocks: usize) -> usize {
        let (mut l, mut r) = (vec![0.0f32; BLOCK_FRAMES], vec![0.0f32; BLOCK_FRAMES]);
        let mut blocks = 0;
        while blocks < max_blocks {
            let got = self.feeder.next_block(&mut l, &mut r);
            if got == 0 {
                break;
            }
            self.ring.extend(l.iter().zip(&r).take(got).map(|(a, b)| (*a, *b)));
            blocks += 1;
        }
        blocks
    }

    fn available_to_read(&self) -> usize {
        self.ring.len()
    }

    fn pop(&mut self, left: &mut [f32], right: &mut [f32]) {
        for (l, r) in left.iter_mut().zip(right.iter_mut()) {
            (*l, *r) = self.ring.pop_front().unwrap_or((0.0, 0.0));
        }
    }
}

/// The Audio Channels of every media of the project that has a map.
pub fn channel_maps(media: &[sq_core_model::MediaRef]) -> HashMap<Id, AudioChannelMap> {
    media.iter().filter_map(|m| Some((m.id, m.info.as_ref()?.audio.as_ref()?.channel_map.clone()?))).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_audio::ducking::Ducking;
    use sq_core_audio::live_ducking::{DialogueSilenceProvider, LiveDucking};
    use sq_core_model::{AudioTag, Clip, SequenceFormat, Track, TrackKind};
    use sq_core_time::{Time, TimeRange};
    use sq_media::memory_audio_source::MemoryAudioSource;
    use sq_media::waveform_data::WaveformData;

    const RATE: usize = 48_000;
    const SECONDS: usize = 12;

    fn id(n: u128) -> Id {
        Id::from_u128(n)
    }

    /// Silent dialogue (only the music is heard) over a constant 0.5 music bed.
    fn timeline() -> Timeline {
        let len = TimeRange::new(Time::ZERO, Time::new(SECONDS as i64, 1));
        let mk = |n: u128, media: Id, role| {
            let mut c = Clip::new(id(100 + n), "c", media, TrackKind::Audio, len, Time::ZERO);
            // The role comes from the clip's tag, so no role bus (its effects would bend the level) shapes the mix.
            c.audio_tag = Some(role);
            let mut t = Track::new(id(n), TrackKind::Audio);
            t.set_clips(vec![c]);
            t
        };
        Timeline::new(
            id(9999),
            "t",
            SequenceFormat::new(Time::new(1, 30)),
            vec![mk(1, id(1), AudioTag::Dialogue), mk(2, id(2), AudioTag::Music)],
        )
    }

    fn resolver() -> Resolver {
        Arc::new(|m| {
            let level = if m == id(1) { 0.0 } else { 0.5 };
            Ok(Arc::new(MemoryAudioSource::mono(vec![level; SECONDS * RATE])) as _)
        })
    }

    /// 10 ms buckets at level 0.5, silent from 5 s for 1 s.
    fn dialogue_waveform() -> WaveformData {
        let mut l0 = Vec::new();
        for i in 0..SECONDS * 100 {
            l0.extend(if (500..600).contains(&i) { [0.0, 0.0] } else { [-0.5, 0.5] });
        }
        WaveformData {
            sample_rate: 1000,
            channel_count: 1,
            total_frames: SECONDS * 1000,
            base_bucket_size: 10,
            levels: vec![l0],
        }
    }

    fn envelope(left: &[f32]) -> impl Fn(f64) -> f64 + '_ {
        // The music is 0.5 flat, so the mixed sample over 0.5 is the gain.
        move |t| f64::from(left[(t * RATE as f64) as usize]) / 0.5
    }

    /// The gain the timeline draws (`LiveDucking::curve` is built on `gain` over the same ranges) against the mixed samples.
    fn assert_matches_curve(left: &[f32], d: &LiveDucking, ranges: &[TimeRange]) {
        let heard = envelope(left);
        let mut worst = 0.0f64;
        let mut t = 0.5f64;
        while t < 11.0 {
            let drawn = f64::from(d.gain(Time::new((t * 20.0).round() as i64, 20), ranges));
            worst = worst.max((heard(t) - drawn).abs());
            t += 0.05;
        }
        assert!(worst < 0.02, "mixed envelope follows the drawn curve, worst gap {worst}");
        let floor = f64::from(d.floor_gain());
        assert!((heard(2.0) - floor).abs() < 0.02, "ducked under the speech: {}", heard(2.0));
        assert!(heard(5.5) > floor + 0.5, "recovered in the 1 s gap: {}", heard(5.5));
        assert!((heard(9.0) - floor).abs() < 0.02, "ducked again after the gap");
    }

    fn pull_all(next: &mut dyn FnMut(&mut [f32], &mut [f32]) -> usize) -> Vec<f32> {
        let (mut l, mut r) = (vec![0.0f32; BLOCK_FRAMES], vec![0.0f32; BLOCK_FRAMES]);
        let mut out = Vec::new();
        while out.len() < SECONDS * RATE {
            let n = next(&mut l, &mut r);
            if n == 0 {
                break;
            }
            out.extend_from_slice(&l[..n]);
        }
        out
    }

    #[test]
    fn playback_and_export_release_the_duck_in_a_dialogue_gap_like_the_drawn_curve() {
        let t = timeline();
        let d = LiveDucking::new(12.0, Ducking::DEFAULT_FADE);
        let silences = WaveformSilences::default();
        silences.set_waveform(Some(Arc::new(dialogue_waveform())), id(1));
        // The pauses the curve draws from (inline, like the export view).
        let ranges = LiveDucking::dialogue_ranges(&t, None, Some(&silences.for_export()));
        assert_eq!(ranges.len(), 2, "speech before and after the 1 s gap: {ranges:?}");

        // Export: the mix reads the pauses through `for_export` of the store.
        let mut mix = FeederMix::with_resolver(&t, HashMap::new(), resolver(), &silences);
        mix.handle.set_live_ducking(Some(d.clone()));
        mix.seek(0);
        let exported = pull_all(&mut |l, r| mix.feeder.next_block(l, r));
        assert_matches_curve(&exported, &d, &ranges);

        // Playback: the default store the engine holds; a clip not analyzed yet ducks whole, then the gap opens.
        let feeder = AudioFeeder::new(t.clone(), BLOCK_FRAMES, resolver());
        let handle = feeder.handle();
        handle.set_timeline(t.clone(), None);
        handle.set_live_ducking(Some(d.clone()));
        let shared: Arc<WaveformSilences> = Arc::new(WaveformSilences::default());
        handle.set_dialogue_silences(Some(Arc::clone(&shared) as _));
        shared.set_waveform(Some(Arc::new(dialogue_waveform())), id(1));
        let clip = t.tracks[0].clips()[0].clone();
        assert_eq!(shared.silences(&clip, 0.0), None, "never blocks: unknown until the utility thread is done");
        shared.wait_until_idle();
        assert!(shared.silences(&clip, 0.0).is_some());
        let mut feeder = feeder;
        handle.seek(0, false);
        let played = pull_all(&mut |l, r| feeder.next_block(l, r));
        assert_matches_curve(&played, &d, &ranges);
    }

    #[test]
    fn a_deleted_clip_loses_its_cached_pauses() {
        let t = timeline();
        let store = WaveformSilences::new(true);
        store.set_waveform(Some(Arc::new(dialogue_waveform())), id(1));
        let clip = t.tracks[0].clips()[0].clone();
        assert!(store.silences(&clip, 0.0).is_some());
        assert_eq!(store.cached_count(), 1);
        prune_silences(&store, std::slice::from_ref(&t));
        assert_eq!(store.cached_count(), 1, "a clip still on a timeline keeps its pauses");
        let mut gone = t.clone();
        gone.tracks[0].set_clips(Vec::new());
        prune_silences(&store, &[gone]);
        assert_eq!(store.cached_count(), 0);
    }
}
