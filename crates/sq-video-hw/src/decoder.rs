//! `VideoDecoding` over a direct VideoToolbox session. The `Demuxing` impl (FFmpeg) supplies compressed samples; each sample
//! is submitted with its decode ordinal as tag, so a delivered picture maps straight to its presentation index (no pts
//! reordering). Pictures become `GpuFrame`s: one wgpu texture per plane imported from the IOSurface, the CVPixelBuffer and
//! CVMetalTextures kept alive in `GpuFrame::keep` (design section 3).

use crate::codec::{Codec, PixelKind, StreamRange, color_space};
use crate::deinterlace::GpuDeinterlacer;
use crate::ffi::{Config, Failure, Importer, Output, Session, Stamp};
use crate::plan::{self, Cursor};
use sq_core_model::{FieldOrder, VideoTrackInfo};
use sq_core_time::{Id, Time};
use sq_frame::sqframe::{SQFrame, SQFrameColorSpace};
use sq_gpu::frames::{GpuFrame, GpuTexture};
use sq_gpu::gpu::Gpu;
use sq_gpu::layout::PixelFormat;
use sq_media::demuxing::{BoxFuture, DemuxedSample, Demuxing};
use sq_media::media_error::MediaError;
use sq_media::video_decoding::{DecodedFrame, FrameSink, StopCheck, VideoDecoding};
use std::collections::{BTreeMap, HashMap};
use std::ops::RangeInclusive;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// Frames in flight in the hardware decoder (G1: 8 was the best of 4 and 8).
const WINDOW: usize = 8;
/// Pictures past the requested range kept for the next call (forward playback).
const MAX_CARRY: usize = 8;
/// A decode that makes no progress for this long fails.
const STALL: Duration = Duration::from_secs(10);

struct State {
    session: Option<Session>,
    cursor: Option<Cursor>,
    /// Pictures decoded past the previous range, by presentation index.
    carry: HashMap<usize, DecodedFrame>,
    /// Bumped by every change, so a plan made before awaiting the demuxer is dropped when another call got in between.
    generation: u64,
    imported: u64,
    /// The session got samples since it was opened: its reference pictures are those of the old position.
    used: bool,
    /// The last picture decoded near the end of the file, with its presentation index: what frames after it hold when they
    /// never decode (`tail_hold_source`). Kept across calls, dropped by a call far from the end.
    tail: Option<(usize, DecodedFrame)>,
}

impl State {
    fn reset(&mut self) {
        self.cursor = None;
        self.carry.clear();
        self.generation += 1;
    }
}

struct Plan {
    from_ordinal: i64,
    flush: bool,
    generation: u64,
}

enum Fail {
    /// Another call changed the session while this one waited for samples: plan again.
    Stale,
    Media(MediaError),
}

impl From<MediaError> for Fail {
    fn from(e: MediaError) -> Fail {
        Fail::Media(e)
    }
}

fn media_error(f: Failure) -> MediaError {
    match f {
        Failure::Status(rc) => MediaError::DecodeFailed(rc),
        Failure::Unsupported(m) => MediaError::UnsupportedCodec(m),
    }
}

/// Hardware video decoder (H.264, HEVC 8/10-bit, ProRes 4:2:2) delivering `GpuFrame` pictures.
pub struct VtVideoDecoder {
    info: VideoTrackInfo,
    media: Id,
    demuxer: Arc<dyn Demuxing>,
    gpu: Arc<Gpu>,
    importer: Importer,
    codec: Codec,
    pixel: PixelKind,
    /// The stream flags full range (what VideoToolbox is asked for); `tag_full` is how the pictures are read.
    full: bool,
    tag_full: bool,
    extradata: Vec<u8>,
    color: SQFrameColorSpace,
    ordinals: Vec<usize>,
    /// The GPU pass of an interlaced item (`with_deinterlace`).
    deinterlace: Option<GpuDeinterlacer>,
    state: Mutex<State>,
}

impl VtVideoDecoder {
    /// Opens a hardware session for the stream; fails (so the caller uses the FFmpeg route) when the codec, the layout or
    /// the machine's decoder does not fit. `info` is the demuxer's track info (its `bit_depth` and `chroma` pick the layout).
    pub fn new(
        demuxer: Arc<dyn Demuxing>,
        info: VideoTrackInfo,
        media: Id,
        gpu: Arc<Gpu>,
        range: StreamRange,
    ) -> Result<VtVideoDecoder, MediaError> {
        let format = demuxer.format_description().clone();
        let codec =
            Codec::from_name(&format.codec).ok_or_else(|| MediaError::UnsupportedCodec(format.codec.clone()))?;
        if !codec.accepts_extradata(&format.extradata) {
            return Err(MediaError::UnsupportedCodec(format!(
                "{} without a length-prefixed configuration record",
                format.codec
            )));
        }
        let pixel = PixelKind::for_stream(info.bit_depth, &info.chroma).ok_or_else(|| {
            MediaError::UnsupportedCodec(format!("{} {} {}-bit", format.codec, info.chroma, info.bit_depth))
        })?;
        if pixel.is_sixteen_bit() && !gpu.supports(PixelFormat::R16Unorm) {
            return Err(MediaError::UnsupportedCodec("16-bit normalized textures".to_string()));
        }
        let importer = Importer::new(gpu.device()).map_err(media_error)?;
        let decoder = VtVideoDecoder {
            color: color_space(&info),
            ordinals: plan::ordinal_map(demuxer.index()),
            info,
            media,
            demuxer,
            gpu,
            importer,
            codec,
            pixel,
            full: range.flagged_full,
            tag_full: range.read_full,
            extradata: format.extradata,
            deinterlace: None,
            state: Mutex::new(State {
                session: None,
                cursor: None,
                carry: HashMap::new(),
                generation: 0,
                imported: 0,
                used: false,
                tail: None,
            }),
        };
        // Open the session now: a machine without a hardware decoder for this stream fails here, not at the first frame.
        let session = decoder.open_session()?;
        decoder.lock().session = Some(session);
        Ok(decoder)
    }

    /// Deinterlaces every picture on the GPU right after import (Swift `VTVideoDecoder(deinterlace:)`). Fails when the
    /// device cannot run the pass on this stream's plane formats, so the caller takes the FFmpeg route with its CPU pass.
    pub fn with_deinterlace(mut self, order: FieldOrder) -> Result<VtVideoDecoder, MediaError> {
        let layout = self.pixel.plane_layout();
        let pass = GpuDeinterlacer::new(Arc::clone(&self.gpu), order, layout).ok_or_else(|| {
            MediaError::UnsupportedCodec("the GPU cannot deinterlace this picture format".to_string())
        })?;
        self.deinterlace = Some(pass);
        Ok(self)
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn open_session(&self) -> Result<Session, MediaError> {
        let cfg = Config {
            codec: self.codec,
            width: i32::try_from(self.info.width).map_err(|_| MediaError::Unreadable)?,
            height: i32::try_from(self.info.height).map_err(|_| MediaError::Unreadable)?,
            extradata: &self.extradata,
            pixel: self.pixel,
            full: self.full,
        };
        Session::new(&cfg).map_err(media_error)
    }

    fn plan(&self, range: &RangeInclusive<usize>, step_back: bool) -> Result<Plan, MediaError> {
        let s = self.lock();
        if step_back {
            let from_ordinal = plan::step_back(self.demuxer.index(), *range.start()).ok_or(MediaError::Truncated)?;
            return Ok(Plan { from_ordinal, flush: true, generation: s.generation });
        }
        let carried = s.carry.keys().copied().collect();
        let (from_ordinal, flush) = plan::start(range, self.demuxer.index(), s.cursor, &carried);
        Ok(Plan { from_ordinal, flush, generation: s.generation })
    }

    async fn decode_async(
        &self,
        range: RangeInclusive<usize>,
        needed_from: Option<usize>,
        deliver: Option<&(dyn Fn(DecodedFrame) + Send + Sync)>,
        stop: Option<&(dyn Fn() -> bool + Send + Sync)>,
    ) -> Result<Vec<DecodedFrame>, MediaError> {
        let count = self.demuxer.index().count();
        let range = *range.start()..=(*range.end()).min(count.saturating_sub(1));
        if count == 0 || range.start() > range.end() {
            return Ok(Vec::new());
        }
        // Tries: the normal start, then (after any failure) one GOP earlier on a clean session.
        let mut step_back = false;
        let mut failed = false;
        loop {
            let plan = self.plan(&range, step_back)?;
            // Everything was sent already (the previous call ran to the last sample): only pictures are missing.
            let samples =
                match self.ordinals.get(usize::try_from(plan.from_ordinal).map_err(|_| MediaError::Truncated)?) {
                    Some(&first) => {
                        // The run must reach the highest decode ordinal of the whole wanted range plus lookahead. Starting
                        // it at `first` alone dropped the tail: at the clip end B-frames decode after their P (ordinal 88
                        // is frame 89, ordinal 89 is frame 88), so `89..=89` never sent ordinal 89 and frame 88 was lost.
                        let (start, end) = (first.min(*range.start()), plan::extended_end(*range.end(), count));
                        self.demuxer.samples_from(start..=end.max(start), plan.from_ordinal).await?
                    }
                    None => Vec::new(),
                };
            match self.execute(&range, needed_from, deliver, stop, &plan, &samples) {
                Ok(frames) => return Ok(frames),
                Err(Fail::Stale) => continue,
                Err(Fail::Media(e)) => {
                    if failed {
                        return Err(e);
                    }
                    failed = true;
                    step_back = matches!(e, MediaError::Truncated);
                    let mut s = self.lock();
                    s.reset();
                    if !step_back {
                        // A failed session is in an unknown state: start over on a new one.
                        s.session = None;
                    }
                }
            }
        }
    }

    fn execute(
        &self,
        range: &RangeInclusive<usize>,
        needed_from: Option<usize>,
        deliver: Option<&(dyn Fn(DecodedFrame) + Send + Sync)>,
        stop: Option<&(dyn Fn() -> bool + Send + Sync)>,
        plan: &Plan,
        samples: &[DemuxedSample],
    ) -> Result<Vec<DecodedFrame>, Fail> {
        let mut guard = self.lock();
        if guard.generation != plan.generation {
            return Err(Fail::Stale);
        }
        guard.generation += 1;
        if guard.session.is_none() {
            guard.cursor = None;
            guard.carry.clear();
            guard.session = Some(self.open_session()?);
        }
        let flush = plan.flush || guard.cursor.is_none();
        let origin = match guard.cursor {
            Some(c) if !flush => c.origin,
            _ => plan.from_ordinal,
        };
        let clean_start = samples.first().is_none_or(|s| self.codec.clears_references(&self.extradata, &s.data));
        if flush && guard.used && !clean_start {
            // A seek needs a decoder without the old position's reference pictures. Flushing a VideoToolbox session
            // only pushes out the pictures it holds: its reference list survives, and a non-IDR sync sample (H.264 open
            // GOP, HEVC CRA) does not clear it, so the GOP's P frames were predicted from stale pictures with the same
            // frame number (C2177: P80 from an earlier decode's P80 instead of I77). A new session has none (about 9 ms
            // at 4K on an M1 Max, so only when the start is no IDR picture, which clears them by itself).
            let fresh = self.open_session()?;
            retire(guard.session.replace(fresh));
            guard.used = false;
        } else if flush && guard.session.as_ref().is_some_and(|s| s.inflight() > 0) {
            // A seek while the old position's pictures are still in the hardware: `finish` below would wait for every one of
            // them (up to WINDOW pictures of 25 ms at 4K) only to throw them away. A fresh session (about 9 ms) starts
            // at once and the old one drains on its own thread.
            let fresh = self.open_session()?;
            retire(guard.session.replace(fresh));
            guard.used = false;
        }
        let State { session, cursor, carry, imported, used, tail, .. } = &mut *guard;
        if *range.end() + sq_media::video_decoding::TAIL_HOLD_FRAMES + 1 < self.demuxer.index().count() {
            *tail = None;
        }
        let Some(session) = session.as_ref() else { return Err(MediaError::DecodeFailed(-1).into()) };
        let mut batch: Vec<Output> = Vec::new();
        if flush {
            // Forget the old stream position: push out what the decoder holds and drop it (an IDR start then clears the
            // references; a reopened session holds nothing).
            session.finish();
            session.take(&mut batch);
            batch.clear();
            carry.clear();
        }
        let index = self.demuxer.index();
        let mut run = Run {
            decoder: self,
            range,
            wanted: plan::wanted(range, index, needed_from),
            results: BTreeMap::new(),
            carry,
            deliver,
            stop,
            stopped: false,
            imported,
            origin,
            last_decoded: tail.take(),
        };
        for i in run.carry.keys().copied().filter(|i| range.contains(i)).collect::<Vec<_>>() {
            if let Some(frame) = run.carry.remove(&i)
                && run.wanted.remove(&i)
            {
                run.results.insert(i, frame);
            }
        }
        run.carry.retain(|i, _| *i > *range.end());

        let (errors_before, _) = session.failures();
        let started = Instant::now();
        let (mut next, mut finished, mut settled) = (0usize, false, false);
        loop {
            session.take(&mut batch);
            for out in batch.drain(..) {
                run.route(out)?;
            }
            if run.stop_now() {
                break;
            }
            if run.wanted.is_empty() {
                break;
            }
            if started.elapsed() > STALL {
                *cursor = None;
                return Err(MediaError::DecodeFailed(-1).into());
            }
            if let Some(sample) = samples.get(next) {
                let ordinal = (plan.from_ordinal + next as i64) as usize;
                // A leading picture of the sync sample the session started at references the GOP before it, which the
                // session never saw: not sent at all (as the Swift decoder does). Sent, VideoToolbox built it on stale
                // references and later pictures of the GOP came out different too (C2177: P frames after a non-IDR I).
                if self.ordinals.get(ordinal).is_some_and(|&i| index.reference_start_ordinal(i) < origin) {
                    next += 1;
                    continue;
                }
                if session.inflight() >= WINDOW {
                    session.wait_output(Duration::from_millis(10));
                    continue;
                }
                let stamp = |t: Time| stamp_of(t);
                session
                    .submit(&sample.data, stamp(sample.pts), stamp(sample.dts), stamp(sample.duration), ordinal)
                    .map_err(media_error)?;
                *used = true;
                next += 1;
            } else if !finished {
                // Every sample is in: the hardware may still hold the last pictures for reordering.
                session.finish();
                finished = true;
            } else if settled {
                break;
            } else {
                settled = true;
            }
        }
        if run.stopped {
            // The caller dropped the rest: the session's position is unknown, the next call seeks.
            run.carry.clear();
            *tail = run.last_decoded.take();
            *cursor = None;
            return Ok(Vec::new());
        }
        // Every sample went in and the session settled: what is still missing at the end of the file never decodes.
        let sent_to_end = plan::extended_end(*range.end(), self.demuxer.index().count()) + 1 >= self.demuxer.index().count();
        let hold = if sent_to_end { run.hold_tail() } else { None };
        let Run { mut wanted, mut results, last_decoded, .. } = run;
        *tail = last_decoded;
        if let Some(held) = hold {
            let mut missing: Vec<usize> = wanted.drain().collect();
            missing.sort_unstable();
            for i in missing {
                let entry = index.entries()[i];
                let frame = held.held_at(entry.pts, entry.duration);
                match deliver {
                    Some(deliver) => deliver(frame),
                    None => {
                        results.insert(i, frame);
                    }
                }
            }
        }
        if !wanted.is_empty() {
            *cursor = None;
            let (errors, status) = session.failures();
            return Err(
                if errors > errors_before { MediaError::DecodeFailed(status) } else { MediaError::Truncated }.into()
            );
        }
        // After a forced flush the session's reorder state is unknown: the next call starts with a seek.
        *cursor = (!finished).then_some(Cursor {
            next_ordinal: plan.from_ordinal + next as i64,
            last_presented: *range.end(),
            origin,
        });
        Ok(results.into_values().collect())
    }
}

/// Drops a session whose pictures nobody wants any more on its own thread: the drop waits for the hardware to finish
/// them, and the decode that replaced the session must not wait with it.
fn retire(old: Option<Session>) {
    static RETIRING: crate::retire::Retiring = crate::retire::Retiring::new();
    let Some(old) = old else { return };
    // Past the cap (or when nothing is in flight) the drop is inline, as before.
    if old.inflight() == 0 || !RETIRING.try_begin() {
        return;
    }
    let spawned = std::thread::Builder::new().name("sq-vt-retire".into()).spawn(move || {
        drop(old);
        RETIRING.end();
    });
    if spawned.is_err() {
        RETIRING.end();
    }
}

/// `t` as a CoreMedia time; a timescale beyond 32 bits is brought down to 90 kHz.
fn stamp_of(t: Time) -> Stamp {
    match i32::try_from(t.timescale()) {
        Ok(timescale) => Stamp { value: t.value(), timescale },
        Err(_) => Stamp { value: Time::scaled_int(t, 90_000, 1).value() / t.timescale().max(1), timescale: 90_000 },
    }
}

/// One `execute` call: pictures still wanted, the ones to return, the ones to carry to the next call.
struct Run<'a> {
    decoder: &'a VtVideoDecoder,
    range: &'a RangeInclusive<usize>,
    wanted: std::collections::HashSet<usize>,
    results: BTreeMap<usize, DecodedFrame>,
    carry: &'a mut HashMap<usize, DecodedFrame>,
    deliver: Option<&'a (dyn Fn(DecodedFrame) + Send + Sync)>,
    /// Asked between pictures; once it said yes `stopped` stays set.
    stop: Option<&'a (dyn Fn() -> bool + Send + Sync)>,
    stopped: bool,
    imported: &'a mut u64,
    /// Ordinal the session started at: pictures that reference frames before it (an open GOP's leading pictures) are
    /// built on missing references and are dropped.
    origin: i64,
    /// The picture with the highest presentation index imported near the end of the file (`tail_hold_source`).
    last_decoded: Option<(usize, DecodedFrame)>,
}

impl Run<'_> {
    /// The picture to show for wanted frames the session never produced, once it ran to the end of the file.
    fn hold_tail(&self) -> Option<DecodedFrame> {
        let count = self.decoder.demuxer.index().count();
        let source = sq_media::video_decoding::tail_hold_source(
            self.wanted.iter().copied(),
            count,
            self.last_decoded.as_ref().map(|(i, _)| *i),
        )?;
        self.last_decoded.as_ref().filter(|(i, _)| *i == source).map(|(_, f)| f.clone())
    }

    fn stop_now(&mut self) -> bool {
        self.stopped = self.stopped || self.stop.is_some_and(|s| s());
        self.stopped
    }

    fn route(&mut self, out: Output) -> Result<(), Fail> {
        if self.stop_now() {
            return Ok(()); // the picture is dropped unimported
        }
        let d = self.decoder;
        // A hidden sample (an edit list's preroll) is decoded for the pictures after it and is no frame of the clip.
        if d.demuxer.index().is_hidden_ordinal(out.tag) {
            return Ok(());
        }
        let Some(&index) = d.ordinals.get(out.tag) else { return Ok(()) };
        if d.demuxer.index().reference_start_ordinal(index) < self.origin {
            return Ok(());
        }
        let count = d.demuxer.index().count();
        let near_end = index + sq_media::video_decoding::TAIL_HOLD_FRAMES + 1 >= count;
        if self.range.contains(&index) {
            if !self.wanted.contains(&index) {
                return Ok(());
            }
            let frame = self.import(out, index)?;
            self.wanted.remove(&index);
            if near_end && self.last_decoded.as_ref().is_none_or(|(last, _)| *last < index) {
                self.last_decoded = Some((index, frame.clone()));
            }
            match self.deliver {
                Some(deliver) => deliver(frame),
                None => {
                    self.results.insert(index, frame);
                }
            }
        } else if near_end && index < *self.range.start() && self.last_decoded.as_ref().is_none_or(|(last, _)| *last < index) {
            // The picture before the range (decoded on the way from the GOP start): what the range holds when its own
            // frames never decode.
            self.last_decoded = Some((index, self.import(out, index)?));
        } else if index > *self.range.end() && self.carry.len() < MAX_CARRY && !self.carry.contains_key(&index) {
            let frame = self.import(out, index)?;
            self.carry.insert(index, frame);
        }
        Ok(())
    }

    fn import(&mut self, out: Output, index: usize) -> Result<DecodedFrame, Fail> {
        let d = self.decoder;
        let entry = d.demuxer.index().entries()[index];
        let imported = d.importer.import(out.buffer).map_err(media_error)?;
        *self.imported += 1;
        if self.imported.is_multiple_of(64) {
            d.importer.flush();
        }
        let (width, height) = imported.size;
        let mut gpu_frame = GpuFrame {
            planes: imported.planes.into_iter().map(GpuTexture::from_texture).collect(),
            layout: imported.kind.plane_layout(),
            size: imported.size,
            color: d.color,
            pts: entry.pts,
            keep: Some(Box::new(imported.keep)),
        };
        if let Some(pass) = &d.deinterlace {
            match pass.run(&gpu_frame) {
                Some(progressive) => gpu_frame = progressive,
                None => eprintln!("videotoolbox: the GPU deinterlace failed for one picture; it is shown woven"),
            }
        }
        let sq = SQFrame::new(
            width as usize,
            height as usize,
            imported.kind.pixel_format(d.tag_full),
            d.color,
            entry.pts,
            Arc::new(gpu_frame),
        );
        Ok(DecodedFrame::new(d.media, entry.duration, sq))
    }
}

impl VideoDecoding for VtVideoDecoder {
    fn info(&self) -> &VideoTrackInfo {
        &self.info
    }

    fn is_hardware(&self) -> bool {
        true
    }

    fn decode(&self, range: RangeInclusive<usize>) -> BoxFuture<'_, Result<Vec<DecodedFrame>, MediaError>> {
        Box::pin(async move { self.decode_async(range, None, None, None).await })
    }

    fn decode_deliver(
        &self,
        range: RangeInclusive<usize>,
        deliver: FrameSink,
    ) -> BoxFuture<'_, Result<Vec<DecodedFrame>, MediaError>> {
        Box::pin(async move { self.decode_async(range, None, Some(&*deliver), None).await })
    }

    fn decode_needed_from(
        &self,
        range: RangeInclusive<usize>,
        needed_from: Option<usize>,
        deliver: FrameSink,
    ) -> BoxFuture<'_, Result<Vec<DecodedFrame>, MediaError>> {
        Box::pin(async move { self.decode_async(range, needed_from, Some(&*deliver), None).await })
    }

    fn decode_until(
        &self,
        range: RangeInclusive<usize>,
        needed_from: Option<usize>,
        deliver: FrameSink,
        stop: StopCheck,
    ) -> BoxFuture<'_, Result<Vec<DecodedFrame>, MediaError>> {
        Box::pin(async move { self.decode_async(range, needed_from, Some(&*deliver), Some(&*stop)).await })
    }

    fn invalidate(&self) {
        let mut s = self.lock();
        if let Some(session) = s.session.as_ref() {
            session.finish();
        }
        s.reset();
    }
}

impl VtVideoDecoder {
    /// The GPU the pictures live on.
    pub fn gpu(&self) -> &Arc<Gpu> {
        &self.gpu
    }
}
