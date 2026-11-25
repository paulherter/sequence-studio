use super::color::frame_color;
use super::demuxer::FFmpegDemuxer;
use super::error::media_error;
use super::hardware::{
    DOWNLOAD_FAILURES_BEFORE_SOFTWARE, DecodePath, DownloadWatch, HARDWARE_API, HARDWARE_PATH, HOLDS_POOL,
    SessionGuard, acquire_hardware_session_for, big_enough_for_hardware, decode_path, hardware_hold_limit, pool_frames,
    supports_hardware_decode,
};
use super::timing::{DecodeCursor, DecodePlan};
use crate::shim::{Decoder, DecoderConfig, Frame, InputPacket, Received, Sent};
use sq_core_model::{FieldOrder, VideoTrackInfo};
use sq_core_time::{Id, Time};
use sq_frame::sqframe::{SQFrame, SQFrameColorSpace, SQFramePixelFormat, SQFrameStorage};
use sq_media::demuxing::{BoxFuture, Demuxing};
use sq_media::media_error::MediaError;
use sq_media::video_decoding::{DecodedFrame, FrameSink, StopCheck, VideoDecoding};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::ops::RangeInclusive;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, RwLock};

/// Frames handed out beyond the decoder's own reference pictures before the D3D11 texture pool runs dry.
// shortcut: a fixed pool headroom; upgrade to copying into the renderer's own textures when playback holds more.
pub const DEFAULT_EXTRA_HW_FRAMES: i32 = 16;

/// `DEFAULT_EXTRA_HW_FRAMES`, or `SQ_HW_EXTRA_FRAMES` (measurement knob: each pooled 4K surface is 12 MB of shared memory).
pub fn extra_hw_frames() -> i32 {
    std::env::var("SQ_HW_EXTRA_FRAMES").ok().and_then(|v| v.parse().ok()).unwrap_or_else(|| super::hardware::default_extra_hw_frames(super::hardware::tier_memory(), DEFAULT_EXTRA_HW_FRAMES))
}

/// Pictures decoded past the previous range (reorder delay) kept for the next call.
const MAX_CARRY: usize = 8;
/// Carry cap of a decoder state: a hardware pool shares its extra surfaces between the carry and the frames a call holds,
/// so a small pool (small machines) carries less ([`super::hardware::carry_limit`]); software decoders have no pool.
fn carry_cap(s: &State) -> usize {
    if s.hardware && HOLDS_POOL { super::hardware::carry_limit(s.extra_hw_frames, MAX_CARRY) } else { MAX_CARRY }
}
/// Threads of the throw-away software decoder (a one-off range, outside the shared thread budget).
const ONE_SHOT_THREADS: i32 = 2;

type FallbackHook = Arc<dyn Fn(&str) + Send + Sync>;
static FALLBACK_HOOK: RwLock<Option<FallbackHook>> = RwLock::new(None);

/// Sets the function called when a hardware decoder could not open or failed mid-stream and software took over (the
/// startup log), or when a software decode is retried.
pub fn set_fallback_hook(hook: Option<FallbackHook>) {
    *FALLBACK_HOOK.write().unwrap_or_else(PoisonError::into_inner) = hook;
}

fn on_fallback(message: &str) {
    if let Some(h) = FALLBACK_HOOK.read().unwrap_or_else(PoisonError::into_inner).as_ref() {
        h(message);
    }
}

struct State {
    decoder: Option<Decoder>,
    hardware: bool,
    cursor: Option<DecodeCursor>,
    /// Pictures decoded past the previous range (reorder delay), by presentation index.
    carry: HashMap<usize, DecodedFrame>,
    /// Whether the software decoder runs in preview mode right now (`set_preview`).
    preview: bool,
    /// The slot of the process-wide hardware session limit while the decoder is a hardware one.
    session: Option<SessionGuard<'static>>,
    /// Hardware frames the pool holds beyond the decoder's own references (the `extra_hw_frames` it was opened with).
    extra_hw_frames: i32,
    /// The last picture this file decoded near its end, with its presentation index: what frames after it hold when they
    /// never decode (`tail_hold_source`). Kept across calls (a continuing decode only sees the new pictures) and dropped
    /// by a call far from the end.
    tail: Option<(usize, DecodedFrame)>,
}

impl State {
    /// Forget where the decoder was: the next call seeks.
    fn reset(&mut self) {
        self.cursor = None;
        self.carry.clear();
    }
}

/// `VideoDecoding` over FFmpeg: hardware decode on Windows (D3D11VA, frames stay D3D11 textures) and Linux (VA-API, frames
/// are copied to memory as they leave the decoder), software when the GPU cannot decode the stream, `hardware` is off or the
/// platform has no FFmpeg hardware decoder. Frame-accurate: a seek starts at the
/// GOP's sync sample and every decoded picture is matched to its frame by pts; forward playback continues without flushing.
pub struct FFmpegVideoDecoder {
    info: VideoTrackInfo,
    media: Id,
    demuxer: Arc<FFmpegDemuxer>,
    pixel_format: SQFramePixelFormat,
    color_space: SQFrameColorSpace,
    state: Mutex<State>,
    /// Mirror of `State.hardware` behind its own lock: a decode holds `state` for its whole run (up to a GOP, over a
    /// second backwards), and the main thread asks `is_hardware` on every pause (proxy lookup).
    hardware_flag: AtomicBool,
    /// The preview request (`set_preview`), applied by the next decode when the decoder is free.
    preview_flag: AtomicBool,
    /// Failed downloads of this stream's pictures in a row, and the request they raise: reopen in software at the next decode.
    downloads: DownloadWatch,
    software_flag: AtomicBool,
    /// Field order of an interlaced source whose frames leave the decoder progressive (`None`: as stored).
    deinterlace: Option<FieldOrder>,
}

/// The layout of a downloaded picture: NV12 for 8-bit sources, P010 for deeper ones, read as full or video range.
fn download_layout(bit_depth: i64, full_range: bool) -> SQFramePixelFormat {
    match (bit_depth > 8, full_range) {
        (true, true) => SQFramePixelFormat::P010FullRange,
        (true, false) => SQFramePixelFormat::P010,
        (false, true) => SQFramePixelFormat::Nv12FullRange,
        (false, false) => SQFramePixelFormat::Nv12,
    }
}

fn open_decoder(d: &FFmpegDemuxer, hardware: bool, extra_hw_frames: i32) -> Result<Decoder, MediaError> {
    open_decoder_threads(d, hardware, extra_hw_frames, 0)
}

/// `sw_threads` > 0 fixes a software decoder's threads (a throw-away decoder must not count in the shared budget).
fn open_decoder_threads(
    d: &FFmpegDemuxer,
    hardware: bool,
    extra_hw_frames: i32,
    sw_threads: i32,
) -> Result<Decoder, MediaError> {
    let raw = d.raw();
    let format = d.format_description();
    let cfg = DecoderConfig {
        codec: &format.codec,
        extradata: &format.extradata,
        width: raw.width,
        height: raw.height,
        bits_per_coded_sample: raw.bits_per_coded_sample,
        codec_tag: raw.codec_tag,
        tb_num: raw.tb_num,
        tb_den: raw.tb_den,
        hardware,
        extra_hw_frames,
        sw_threads,
    };
    let _span = sq_os::trace::span_args("open", "decoder open", || {
        format!("codec={} hw={hardware} {}x{}", format.codec, raw.width, raw.height)
    });
    Decoder::open(&cfg).map_err(|e| {
        on_fallback(&format!("decoder open failed: {e}"));
        media_error(&e, &format.codec)
    })
}

/// Pixels per second the stream asks of a decode engine (width x height x frame rate).
fn pixel_rate(info: &VideoTrackInfo) -> u64 {
    let d = info.nominal_frame_duration;
    let (ts, v) = (u64::try_from(d.timescale()).unwrap_or(0), u64::try_from(d.value()).unwrap_or(1).max(1));
    let fps = (ts + v / 2) / v;
    u64::try_from(info.width.max(0)).unwrap_or(0) * u64::try_from(info.height.max(0)).unwrap_or(0) * fps.max(1)
}

impl FFmpegVideoDecoder {
    /// A decoder over `demuxer`. `hardware`: try the GPU decoder (`HARDWARE_API`) when this is Windows or Linux and the
    /// stream suits the GPU.
    pub fn new(
        demuxer: Arc<FFmpegDemuxer>,
        media: Id,
        hardware: bool,
        extra_hw_frames: i32,
    ) -> Result<FFmpegVideoDecoder, MediaError> {
        let info = demuxer.track_info();
        let (color_space, full_range) = frame_color(demuxer.raw());
        let pixel_format = download_layout(info.bit_depth, full_range);
        // Streams no PC hardware decoder takes (4:2:2, 4:4:4, 10-bit H.264, ProRes...) open the software decoder at once.
        let gpu_can = supports_hardware_decode(&demuxer.format_description().codec, &demuxer.raw().pix_fmt);
        // SQ_FORCE_SW_DECODE=1 skips the GPU decoder (tests the software path; a tester whose GPU driver fails in it).
        let forced = std::env::var("SQ_FORCE_SW_DECODE").is_ok_and(|v| v == "1");
        // The Mac decodes in hardware through VideoToolbox directly (another crate); FFmpeg's hardware path is D3D11VA on
        // Windows and VA-API on Linux. VA-API surfaces are copied out at once, so a small pool is enough there.
        let mut decoder = None;
        let mut session = None;
        if hardware && HARDWARE_PATH && gpu_can && big_enough_for_hardware(info.width, info.height) && !forced {
            match acquire_hardware_session_for(pixel_rate(&info)) {
                None => on_fallback(&format!(
                    "hardware decoder limit reached; {} opens in software",
                    demuxer.format_description().codec
                )),
                Some(slot) => match open_decoder(&demuxer, true, pool_frames(extra_hw_frames)) {
                    Ok(d) => {
                        decoder = Some(d);
                        session = Some(slot);
                    }
                    Err(e) => on_fallback(&format!(
                        "{HARDWARE_API} open failed for {}: {e}; using software",
                        demuxer.format_description().codec
                    )),
                },
            }
        }
        let is_hardware = decoder.is_some();
        let decoder = match decoder {
            Some(d) => d,
            None => open_decoder(&demuxer, false, 0)?,
        };
        Ok(FFmpegVideoDecoder {
            info,
            media,
            pixel_format,
            color_space,
            state: Mutex::new(State {
                decoder: Some(decoder),
                hardware: is_hardware,
                cursor: None,
                carry: HashMap::new(),
                preview: false,
                session,
                extra_hw_frames: pool_frames(extra_hw_frames),
                tail: None,
            }),
            hardware_flag: AtomicBool::new(is_hardware),
            preview_flag: AtomicBool::new(false),
            downloads: DownloadWatch::default(),
            software_flag: AtomicBool::new(false),
            deinterlace: None,
            demuxer,
        })
    }

    /// Reads the pictures as `full` range whatever the file's flags say (a proxy's codes are the original's).
    pub fn with_full_range(mut self, full: bool) -> FFmpegVideoDecoder {
        self.pixel_format = download_layout(self.info.bit_depth, full);
        self
    }

    /// Frames leave this decoder deinterlaced with `order` (the media item's setting; `None` keeps the stored fields).
    pub fn with_deinterlace(mut self, order: Option<FieldOrder>) -> FFmpegVideoDecoder {
        self.deinterlace = order;
        self
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// "h264 (software)" / "h264 (d3d11va)" / "h264 (vaapi)".
    pub fn decoder_name(&self) -> String {
        self.lock().decoder.as_ref().map_or_else(|| "none".to_string(), Decoder::name)
    }

    /// Preview mode for scrubbing: a software decoder skips the loop filter (about a third faster on 4K 10-bit H.264) and
    /// its pictures are not exact. Never blocks (a running decode applies it at its next call); a hardware decoder ignores it.
    /// Turning it off restarts the next decode from a keyframe, so the exact pictures do not build on drifted references.
    pub fn set_preview(&self, on: bool) {
        self.preview_flag.store(on, Ordering::Relaxed);
    }

    /// Decodes `range` on the calling thread (blocking), as `VideoDecoding::decode_deliver` does. `deliver` gets each
    /// frame of the range as soon as it is decoded; `is_stale` is asked once the decoder is free: when it says yes the
    /// request is dropped untouched (nothing delivered, the decoder stays where it was). A scrub queues one decode per
    /// window frame behind the one running; only the newest is still wanted when its turn comes.
    /// A hardware failure mid-stream reopens the software decoder and retries once.
    pub fn decode_blocking(
        &self,
        range: RangeInclusive<usize>,
        deliver: Option<&dyn Fn(DecodedFrame)>,
        is_stale: Option<&dyn Fn() -> bool>,
    ) -> Result<Vec<DecodedFrame>, MediaError> {
        self.decode_blocking_until(range, deliver, is_stale, None)
    }

    /// As `decode_blocking`; `stop` is asked between pictures: yes ends the decode early and drops the stream position.
    pub fn decode_blocking_until(
        &self,
        range: RangeInclusive<usize>,
        deliver: Option<&dyn Fn(DecodedFrame)>,
        is_stale: Option<&dyn Fn() -> bool>,
        stop: Option<&dyn Fn() -> bool>,
    ) -> Result<Vec<DecodedFrame>, MediaError> {
        let count = self.demuxer.index().count();
        let range = *range.start()..=(*range.end()).min(count.saturating_sub(1));
        if count == 0 || range.start() > range.end() {
            return Ok(Vec::new());
        }
        let waited = std::time::Instant::now();
        let mut s = self.lock();
        lock_wait_trace(waited.elapsed(), &range);
        sq_os::trace::since("decode", "decoder lock wait", waited, || {
            format!("media={} frames={}..{}", self.media, range.start(), range.end())
        });
        if is_stale.is_some_and(|stale| stale()) {
            return Ok(Vec::new());
        }
        let preview = self.preview_flag.load(Ordering::Relaxed);
        if preview != s.preview
            && let Some(d) = s.decoder.as_mut()
        {
            d.set_fast(preview);
            d.flush();
            s.preview = preview;
            s.reset();
        }
        let codec = self.demuxer.format_description().codec.as_str();
        if self.software_flag.swap(false, Ordering::Relaxed) && s.hardware {
            on_fallback(&format!("{HARDWARE_API} pictures could not be downloaded; reopening {codec} in software"));
            self.reopen_software(&mut s)?;
        }
        // A list wider than the hardware texture pool holds comes from a throw-away software decoder.
        let limit = hardware_hold_limit(s.extra_hw_frames, carry_cap(&s));
        if decode_path(s.hardware && HOLDS_POOL, deliver.is_some(), range.end() - range.start() + 1, limit)
            == DecodePath::OneShotSoftware
        {
            on_fallback(&format!(
                "{} frames of {codec} exceed the hardware pool; decoding this range in software",
                range.end() - range.start() + 1
            ));
            let mut once = State {
                decoder: Some(open_decoder_threads(&self.demuxer, false, 0, ONE_SHOT_THREADS)?),
                hardware: false,
                cursor: None,
                carry: HashMap::new(),
                preview: false,
                session: None,
                extra_hw_frames: 0,
                tail: None,
            };
            return self.decode_locked(&range, &mut once, None, None);
        }
        let error = match self.decode_locked(&range, &mut s, deliver, stop) {
            Ok(frames) => return Ok(frames),
            Err(e) => e,
        };
        if s.hardware {
            on_fallback(&format!("{HARDWARE_API} decode failed ({error}); reopening {codec} in software"));
            self.reopen_software(&mut s)?;
        } else {
            // A software decode that failed midstream leaves the decoder in an unknown state: start over from a fresh seek once.
            on_fallback(&format!("decode failed ({error}); retrying {codec} from a fresh start"));
            if let Some(d) = s.decoder.as_mut() {
                d.flush();
            }
        }
        s.reset();
        self.decode_locked(&range, &mut s, deliver, stop)
    }

    /// Replaces the hardware decoder by a software one and frees its session slot; the next decode seeks.
    fn reopen_software(&self, s: &mut State) -> Result<(), MediaError> {
        s.decoder = None;
        s.decoder = Some(open_decoder(&self.demuxer, false, 0)?);
        s.hardware = false;
        s.session = None;
        s.preview = false;
        self.hardware_flag.store(false, Ordering::Relaxed);
        s.reset();
        Ok(())
    }

    fn decode_locked(
        &self,
        range: &RangeInclusive<usize>,
        s: &mut State,
        deliver: Option<&dyn Fn(DecodedFrame)>,
        stop: Option<&dyn Fn() -> bool>,
    ) -> Result<Vec<DecodedFrame>, MediaError> {
        let carry_cap = carry_cap(s);
        let State { decoder, cursor, carry, tail, .. } = s;
        if *range.end() + sq_media::video_decoding::TAIL_HOLD_FRAMES + 1 < self.demuxer.index().count() {
            *tail = None;
        }
        let dec = decoder.as_mut().ok_or(MediaError::DecodeFailed(-1))?;
        let index = self.demuxer.index();
        let (mut ordinal, flush) = DecodePlan::start(range, index, *cursor, &carry.keys().copied().collect());
        let origin = match *cursor {
            Some(c) if !flush => c.origin,
            _ => ordinal,
        };
        let prev = *cursor;
        let _span = sq_os::trace::span_args("decode", if flush { "seek+decode" } else { "decode continue" }, || {
            format!(
                "clip={} frames={}..{} start_ordinal={ordinal} hw={} dec={:p} why={} prev_next={} prev_last={}",
                self.media,
                range.start(),
                range.end(),
                self.hardware_flag.load(Ordering::Relaxed),
                self,
                DecodePlan::seek_reason(range, index, prev, flush),
                prev.map_or(-1, |c| c.next_ordinal),
                prev.map_or(-1, |c| c.last_presented as i64),
            )
        });
        if flush {
            dec.flush();
            carry.clear();
        }
        let mut wanted = DecodePlan::wanted(range, index);
        let mut results = BTreeMap::new();
        for i in carry.keys().copied().filter(|i| range.contains(i)).collect::<Vec<_>>() {
            if let Some(f) = carry.remove(&i) {
                results.insert(i, f);
                wanted.remove(&i);
            }
        }
        carry.retain(|i, _| *i > *range.end());

        let mut run = Run {
            decoder: self,
            range,
            wanted,
            results,
            carry,
            carry_cap,
            deliver,
            origin,
            stop,
            stopped: false,
            origin_drops: 0,
            last_decoded: tail.take(),
        };
        let packets = self.demuxer.packet_count();
        let (mut sent_end, mut ended) = (false, false);
        // A damaged packet near the end of the file must not end the decode: what it never yields is held (`hold_tail`).
        let tail_zone = |ordinal: i64| {
            usize::try_from(ordinal).is_ok_and(|o| o + sq_media::video_decoding::TAIL_HOLD_FRAMES + 8 >= packets)
        };
        while !run.wanted.is_empty() && !ended {
            if run.stop_now() {
                break;
            }
            if let Some(next) = usize::try_from(ordinal).ok().filter(|o| *o < packets) {
                let sample = self.demuxer.sample(next)?;
                let p = self.demuxer.packet(next)?;
                let input =
                    InputPacket { data: &sample.data, pts: p.pts, dts: p.dts, duration: p.duration, key: p.key != 0 };
                let mut sent = match dec.send(&input) {
                    Ok(sent) => sent,
                    Err(_) if tail_zone(ordinal) => {
                        ordinal += 1;
                        continue;
                    }
                    Err(e) => return Err(media_error(&e, "")),
                };
                if sent == Sent::Full {
                    // Decoder full: take pictures out, then send again.
                    ended |= run.drain_tolerant(dec, tail_zone(ordinal), false)?;
                    sent = match dec.send(&input) {
                        Ok(sent) => sent,
                        Err(_) if tail_zone(ordinal) => {
                            ordinal += 1;
                            continue;
                        }
                        Err(e) => return Err(media_error(&e, "")),
                    };
                }
                if sent == Sent::Full {
                    return Err(MediaError::DecodeFailed(-11));
                }
                ordinal += 1;
            } else if !sent_end {
                // At the end of the file a failing flush is the end too: the damaged tail is held.
                if let Err(e) = dec.send_end() {
                    if !tail_zone(ordinal) {
                        return Err(media_error(&e, ""));
                    }
                    ended = true;
                }
                sent_end = true;
            } else {
                break;
            }
            ended |= run.drain_tolerant(dec, tail_zone(ordinal), sent_end)?;
        }
        if run.stopped {
            *tail = run.last_decoded.take();
            note_undelivered(self.media, range, run.wanted.len(), run.origin_drops, "cancel");
            // The caller dropped the rest: the stream position is unknown, the next call seeks.
            run.carry.clear();
            *cursor = None;
            dec.flush();
            return Ok(Vec::new());
        }
        let hold = sent_end.then(|| run.hold_tail()).flatten();
        let Run { mut wanted, mut results, origin_drops, last_decoded, .. } = run;
        *tail = last_decoded;
        // After end of stream the decoder needs a flush before new input: the next call seeks.
        *cursor = (!sent_end).then_some(DecodeCursor { next_ordinal: ordinal, last_presented: *range.end(), origin });
        if sent_end {
            dec.flush();
        }
        if let Some(held) = hold {
            // Run to the end of the file and the tail still did not decode: those frames show the last good picture.
            note_undelivered(self.media, range, wanted.len(), origin_drops, "held tail");
            let mut missing: Vec<usize> = wanted.drain().collect();
            missing.sort_unstable();
            for i in missing {
                let entry = self.demuxer.index().entries()[i];
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
            note_undelivered(
                self.media,
                range,
                wanted.len(),
                origin_drops,
                if origin_drops > 0 { "origin drop" } else { "truncated" },
            );
            return Err(MediaError::Truncated);
        }
        Ok(results.into_values().collect())
    }
}

/// One `decode_locked` call: the frames still wanted, the ones to return, the ones to carry to the next call.
struct Run<'a> {
    decoder: &'a FFmpegVideoDecoder,
    range: &'a RangeInclusive<usize>,
    wanted: HashSet<usize>,
    results: BTreeMap<usize, DecodedFrame>,
    carry: &'a mut HashMap<usize, DecodedFrame>,
    /// Most pictures kept for the next call (see [`carry_cap`]).
    carry_cap: usize,
    deliver: Option<&'a dyn Fn(DecodedFrame)>,
    /// Ordinal the decoder started at: pictures referencing frames before it (an open GOP's leading pictures; H.264 has
    /// no RASL flag, so FFmpeg hands them out) are built on missing references and are dropped.
    origin: i64,
    /// Asked between pictures; once it said yes `stopped` stays set.
    stop: Option<&'a dyn Fn() -> bool>,
    stopped: bool,
    /// Pictures of the range dropped because they reference frames before `origin` (trace only).
    origin_drops: usize,
    /// The picture with the highest presentation index this call decoded (range or not): what a tail that never
    /// decodes holds (`tail_hold_source`).
    last_decoded: Option<(usize, DecodedFrame)>,
}

/// Trace note (`SQ_TRACE_JSON` / milestones sink): a range ended with frames not delivered while the cursor still moves
/// to its end, so the next call believes those frames were served.
fn note_undelivered(
    media: impl std::fmt::Debug,
    range: &RangeInclusive<usize>,
    left: usize,
    origin_drops: usize,
    why: &str,
) {
    sq_core_time::milestones::note(&format!(
        "undelivered: media {media:?} frames {}..{} left {left} of {} origin_drops {origin_drops} reason {why}",
        range.start(),
        range.end(),
        range.end() - range.start() + 1
    ));
}

impl Run<'_> {
    /// The picture to show for wanted frames the decoder never produced, once it ran to the end of the file.
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

    /// [`Run::drain`], except that a decoder error inside the tail zone is no failure: the pictures it would have given are
    /// missing (and held); after the end was sent it counts as the end of the stream.
    fn drain_tolerant(&mut self, dec: &mut Decoder, in_tail: bool, sent_end: bool) -> Result<bool, MediaError> {
        match self.drain(dec) {
            Err(_) if in_tail => Ok(sent_end),
            other => other,
        }
    }

    /// Receives every picture the decoder has ready; true when the stream ended.
    fn drain(&mut self, dec: &mut Decoder) -> Result<bool, MediaError> {
        loop {
            if self.stop_now() {
                return Ok(true);
            }
            match dec.receive().map_err(|e| media_error(&e, ""))? {
                Received::Frame(frame) => self.take(frame),
                Received::NeedsInput => return Ok(false),
                Received::Ended => return Ok(true),
            }
        }
    }

    fn take(&mut self, frame: Frame) {
        let d = self.decoder;
        let Some(i) = d.demuxer.table().presentation_index(frame.pts) else { return };
        if d.demuxer.index().reference_start_ordinal(i) < self.origin {
            if self.range.contains(&i) && self.wanted.contains(&i) {
                self.origin_drops += 1;
            }
            return;
        }
        let entry = d.demuxer.index().entries()[i];
        let (w, h) = (usize::try_from(frame.width).unwrap_or(0), usize::try_from(frame.height).unwrap_or(0));
        let mut frame = frame;
        frame.set_deinterlace(d.deinterlace);
        let storage: Arc<dyn SQFrameStorage> = Arc::new(frame);
        let sq = SQFrame::new(w, h, d.pixel_format, d.color_space, entry.pts, storage);
        let decoded = DecodedFrame::new(d.media, entry.duration, sq);
        // Only near the end of the file: a picture held for nothing would keep a hardware surface out of the pool.
        let near_end = i + sq_media::video_decoding::TAIL_HOLD_FRAMES + 1 >= d.demuxer.index().count();
        if near_end && entry.duration > Time::ZERO && self.last_decoded.as_ref().is_none_or(|(last, _)| *last < i) {
            self.last_decoded = Some((i, decoded.clone()));
        }
        if self.range.contains(&i) {
            if !self.wanted.remove(&i) {
                return;
            }
            match self.deliver {
                Some(deliver) => deliver(decoded),
                None => {
                    self.results.insert(i, decoded);
                }
            }
        } else if i > *self.range.end() && self.carry.len() < self.carry_cap {
            self.carry.insert(i, decoded);
        }
    }
}

/// `SQ_PLAY_TRACE`: how long a request waited for the decoder lock behind a running decode (over 1 ms).
fn lock_wait_trace(waited: std::time::Duration, range: &RangeInclusive<usize>) {
    static ON: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    if *ON.get_or_init(|| std::env::var_os("SQ_PLAY_TRACE").is_some()) && waited.as_millis() >= 1 {
        eprintln!("[play-trace] decoder lock wait {:.0} ms for frames {range:?}", waited.as_secs_f64() * 1e3);
    }
}

impl VideoDecoding for FFmpegVideoDecoder {
    fn info(&self) -> &VideoTrackInfo {
        &self.info
    }

    /// Never waits for a running decode.
    fn is_hardware(&self) -> bool {
        self.hardware_flag.load(Ordering::Relaxed)
    }

    fn report_download(&self, ok: bool) {
        if self.hardware_flag.load(Ordering::Relaxed) && self.downloads.report(ok, DOWNLOAD_FAILURES_BEFORE_SOFTWARE) {
            self.software_flag.store(true, Ordering::Relaxed);
        }
    }

    // shortcut: the futures decode synchronously on first poll (no await point), so dropping one does not stop a
    // running decode (Swift checked Task cancellation per sample); upgrade to a cancel flag when scrubbing needs it.
    fn decode(&self, range: RangeInclusive<usize>) -> BoxFuture<'_, Result<Vec<DecodedFrame>, MediaError>> {
        Box::pin(async move { self.decode_blocking(range, None, None) })
    }

    fn decode_deliver(
        &self,
        range: RangeInclusive<usize>,
        deliver: FrameSink,
    ) -> BoxFuture<'_, Result<Vec<DecodedFrame>, MediaError>> {
        Box::pin(async move { self.decode_blocking(range, Some(&*deliver), None) })
    }

    fn decode_until(
        &self,
        range: RangeInclusive<usize>,
        _needed_from: Option<usize>,
        deliver: FrameSink,
        stop: StopCheck,
    ) -> BoxFuture<'_, Result<Vec<DecodedFrame>, MediaError>> {
        Box::pin(async move { self.decode_blocking_until(range, Some(&*deliver), None, Some(&*stop)) })
    }

    fn invalidate(&self) {
        let mut s = self.lock();
        if let Some(d) = s.decoder.as_mut() {
            d.flush();
        }
        s.reset();
    }
}
