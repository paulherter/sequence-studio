//! Safe wrappers over the C++ shim (`vendor/*.cpp`, built by build.rs): demuxer, video decoder, decoded frames and
//! whole-file audio decode. The only module of the crate with `unsafe` code; every block says why it holds.
//! Without an FFmpeg install the shim is a stub whose `open` calls fail (`AVAILABLE` is false).
#![allow(unsafe_code)]

mod ffi;

pub use ffi::Packet;
use sq_core_model::FieldOrder;
use sq_frame::buffer_pool::{BufferPool, PooledBytes};
use std::ffi::{CStr, CString, c_char, c_int};
use std::fmt;
use std::path::Path;
use std::ptr::{self, NonNull};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

/// FFmpeg was found at build time and the shim is linked.
pub const AVAILABLE: bool = cfg!(sq_ffmpeg);

/// `AVERROR(EINVAL)`.
const EINVAL: i32 = -22;
/// FFmpeg's `AVERROR_DECODER_NOT_FOUND` (`FFERRTAG(0xF8,'D','E','C')`).
pub const DECODER_NOT_FOUND: i32 = -1_128_613_112;

/// A failed shim call: FFmpeg's negative code and the text ("open: No such file or directory").
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShimError {
    pub code: i32,
    pub message: String,
}

impl ShimError {
    fn new(what: &str, code: i32, err: &[c_char]) -> ShimError {
        let text = c_string(err);
        let message = if text.is_empty() { format!("{what} failed ({code})") } else { format!("{what}: {text}") };
        ShimError { code, message }
    }

    fn failed(what: &str, code: i32) -> ShimError {
        ShimError { code, message: format!("{what} failed ({code})") }
    }
}

impl fmt::Display for ShimError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ShimError {}

const ERR_LEN: usize = 256;

/// Whether the FFmpeg libraries loaded at run time have the major versions this build was made against: `None` when
/// they do, or when no FFmpeg is linked; else what differs (`avcodec 62 built against, 61 loaded`).
pub fn version_mismatch() -> Option<String> {
    let mut err = [0 as c_char; ERR_LEN];
    // SAFETY: `err` is a writable buffer of `ERR_LEN` bytes; the shim writes at most that many, NUL-terminated.
    let rc = unsafe { ffi::sq_version_mismatch(err.as_mut_ptr(), ERR_LEN as c_int) };
    (rc != 0).then(|| c_string(&err))
}

fn c_path(path: &Path) -> Result<CString, ShimError> {
    let text = path.to_str().ok_or_else(|| ShimError::failed("path", EINVAL))?;
    CString::new(text).map_err(|_| ShimError::failed("path", EINVAL))
}

fn c_string(text: &[c_char]) -> String {
    let bytes: Vec<u8> = text.iter().take_while(|c| **c != 0).map(|c| *c as u8).collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

/// The facts of the best video stream.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VideoInfo {
    pub width: i32,
    pub height: i32,
    /// Stream time base.
    pub tb_num: i32,
    pub tb_den: i32,
    /// Average frame rate; 0/0 unknown.
    pub fr_num: i32,
    pub fr_den: i32,
    /// Clockwise degrees.
    pub rotation: i32,
    pub bit_depth: i32,
    /// FFmpeg codec name ("h264", "hevc", ...).
    pub codec: String,
    /// FFmpeg pixel format name ("yuv420p", ...).
    pub pix_fmt: String,
    /// AVColorPrimaries / AVColorTransferCharacteristic / AVColorSpace / AVColorRange values.
    pub color_primaries: i32,
    pub color_transfer: i32,
    pub color_matrix: i32,
    pub color_range: i32,
    /// AVFieldOrder (0 unknown, 1 progressive, 2 TT, 3 BB, 4 TB, 5 BT).
    pub field_order: i32,
    /// QuickTime Animation and other RLE codecs need it to pick their pixel format.
    pub bits_per_coded_sample: i32,
    /// The container's codec FourCC (ProRes tells its profile and bit depth by it).
    pub codec_tag: u32,
    /// Sample aspect ratio the file tags (0 = untagged).
    pub sar_num: i32,
    pub sar_den: i32,
    /// The Dolby Vision configuration record (`dvcC` / `dvvC` / `dvwC` payload layout), when the stream carries one.
    pub dolby_vision: Option<[u8; 5]>,
}

/// FFmpeg's `AVERROR_STREAM_NOT_FOUND`: the file has no stream of the wanted kind.
pub const STREAM_NOT_FOUND: i32 = -1_381_258_232;

/// How the first video packets of a file seek: its codec and which packets are sync samples.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SeekProbe {
    /// FFmpeg codec name ("h264", "prores", ...).
    pub codec: String,
    /// Sync flag of each packet read, in decode order.
    pub keys: Vec<bool>,
}

/// Reads the codec and the sync flags of up to `max_packets` video packets without indexing or decoding the file: a plain
/// mov/mp4 answers from its header alone, any other container reads about `max_bytes` of payload at most (never fewer
/// than 16 packets).
pub fn seek_probe(path: &Path, max_packets: usize, max_bytes: i64) -> Result<SeekProbe, ShimError> {
    let c = c_path(path)?;
    let cap = c_int::try_from(max_packets).map_err(|_| ShimError::failed("seek probe", EINVAL))?;
    let mut keys = vec![0u8; max_packets];
    let (mut codec, mut err) = ([0 as c_char; 32], [0 as c_char; ERR_LEN]);
    let mut count: c_int = 0;
    // SAFETY: `c` is NUL-terminated; `codec` and `err` are valid for their stated lengths, `keys` holds `cap` bytes and the
    // shim writes at most that many; `count` is valid for the call.
    let r = unsafe {
        ffi::seek_probe(ffi::SeekProbeArgs {
            path: c.as_ptr(),
            max_packets: cap,
            max_bytes,
            codec: codec.as_mut_ptr(),
            codec_len: codec.len() as c_int,
            keys: keys.as_mut_ptr(),
            count: &mut count,
            err: err.as_mut_ptr(),
            err_len: ERR_LEN as c_int,
        })
    };
    if r != 0 {
        return Err(ShimError::new("seek probe", r, &err));
    }
    keys.truncate(usize::try_from(count).unwrap_or(0).min(max_packets));
    Ok(SeekProbe { codec: c_string(&codec), keys: keys.into_iter().map(|k| k != 0).collect() })
}

/// A file opened for demuxing: every packet of the best video stream indexed, samples read by position.
pub struct Demux {
    raw: NonNull<ffi::Demux>,
}

// SAFETY: after open the packet table is never written; `sq_demux_read` takes the C++ object's mutex.
unsafe impl Send for Demux {}
// SAFETY: see above.
unsafe impl Sync for Demux {}

impl Demux {
    /// Opens `path` and indexes the best video stream (reads the whole file once).
    pub fn open(path: &Path) -> Result<Demux, ShimError> {
        Demux::open_probing(path, false)
    }

    /// `open` with FFmpeg's complete stream probe, which decodes a picture; the reference the quick open is tested against.
    pub fn open_full_probe(path: &Path) -> Result<Demux, ShimError> {
        Demux::open_probing(path, true)
    }

    fn open_probing(path: &Path, full_probe: bool) -> Result<Demux, ShimError> {
        let _span = sq_os::trace::span_args("open", "demux open+index", || {
            format!("file={} full_probe={full_probe}", path.display())
        });
        let c = c_path(path)?;
        let mut raw = ptr::null_mut();
        let mut err = [0 as c_char; ERR_LEN];
        // SAFETY: `c` is NUL-terminated, `raw` and `err` are valid for the call, `err` has ERR_LEN bytes.
        let r = unsafe {
            ffi::sq_demux_open_with(c.as_ptr(), c_int::from(full_probe), &mut raw, err.as_mut_ptr(), ERR_LEN as c_int)
        };
        match NonNull::new(raw) {
            Some(raw) if r == 0 => Ok(Demux { raw }),
            _ => {
                let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                Err(ShimError::new(&format!("open {name}"), if r == 0 { -1 } else { r }, &err))
            }
        }
    }

    /// True when the packet index came from the container's index without reading the payload (a plain mov/mp4).
    pub fn index_without_payload(&self) -> bool {
        self.fast_paths() & 1 != 0
    }

    /// True when the stream facts came from the H.264 SPS and no picture was decoded to learn them.
    pub fn facts_from_sps(&self) -> bool {
        self.fast_paths() & 2 != 0
    }

    fn fast_paths(&self) -> c_int {
        // SAFETY: the handle is live.
        unsafe { ffi::sq_demux_fast_paths(self.raw.as_ptr()) }
    }

    /// Stream facts.
    pub fn info(&self) -> VideoInfo {
        let mut raw = std::mem::MaybeUninit::<ffi::VideoInfo>::zeroed();
        // SAFETY: the handle is live; the shim fills a zeroed (valid for every field) struct.
        let i = unsafe {
            ffi::sq_demux_info(self.raw.as_ptr(), raw.as_mut_ptr());
            raw.assume_init()
        };
        VideoInfo {
            width: i.width,
            height: i.height,
            tb_num: i.tb_num,
            tb_den: i.tb_den,
            fr_num: i.fr_num,
            fr_den: i.fr_den,
            rotation: i.rotation,
            bit_depth: i.bit_depth,
            codec: c_string(&i.codec),
            pix_fmt: c_string(&i.pix_fmt),
            color_primaries: i.color_primaries,
            color_transfer: i.color_transfer,
            color_matrix: i.color_matrix,
            color_range: i.color_range,
            field_order: i.field_order,
            bits_per_coded_sample: i.bits_per_coded_sample,
            codec_tag: i.codec_tag,
            sar_num: i.sar_num,
            sar_den: i.sar_den,
            dolby_vision: (i.has_dolby_vision != 0).then_some(i.dolby_vision),
        }
    }

    /// Every packet in decode order.
    pub fn packets(&self) -> &[Packet] {
        // SAFETY: the table lives as long as the handle and is never modified after open; count matches the table.
        unsafe {
            let n = usize::try_from(ffi::sq_demux_packet_count(self.raw.as_ptr())).unwrap_or(0);
            let p = ffi::sq_demux_packets(self.raw.as_ptr());
            if p.is_null() { &[] } else { std::slice::from_raw_parts(p, n) }
        }
    }

    /// Codec configuration record (avcC / hvcC); empty when the stream has none.
    pub fn extradata(&self) -> Vec<u8> {
        let mut size: c_int = 0;
        // SAFETY: the returned pointer is valid for `size` bytes while the handle lives; it is copied at once.
        unsafe {
            let p = ffi::sq_demux_extradata(self.raw.as_ptr(), &mut size);
            if p.is_null() {
                Vec::new()
            } else {
                std::slice::from_raw_parts(p, usize::try_from(size).unwrap_or(0)).to_vec()
            }
        }
    }

    /// The bytes of packet `ordinal` (decode order). Thread-safe.
    pub fn read(&self, ordinal: usize) -> Result<Vec<u8>, ShimError> {
        let size = self.packets().get(ordinal).map_or(0, |p| usize::try_from(p.size).unwrap_or(0));
        let mut data = vec![0u8; size];
        let o = c_int::try_from(ordinal).map_err(|_| ShimError::failed("read sample", EINVAL))?;
        // SAFETY: `data` holds `size` bytes and the shim copies at most `cap` = `size` bytes into it.
        let r = unsafe { ffi::sq_demux_read(self.raw.as_ptr(), o, data.as_mut_ptr(), size as c_int) };
        if r == 0 { Ok(data) } else { Err(ShimError::failed(&format!("read sample {ordinal}"), r)) }
    }
}

impl Drop for Demux {
    fn drop(&mut self) {
        // SAFETY: the handle came from `sq_demux_open` and is closed once.
        unsafe { ffi::sq_demux_close(self.raw.as_ptr()) }
    }
}

/// What a decoder is opened with.
pub struct DecoderConfig<'a> {
    pub codec: &'a str,
    pub extradata: &'a [u8],
    pub width: i32,
    pub height: i32,
    pub bits_per_coded_sample: i32,
    /// The container's codec FourCC; 0 = none.
    pub codec_tag: u32,
    pub tb_num: i32,
    pub tb_den: i32,
    /// D3D11VA decode (frames stay GPU textures); fails when the GPU cannot decode the stream.
    pub hardware: bool,
    /// Pool textures beyond the decoder's own references (hardware only).
    pub extra_hw_frames: i32,
    /// Threads of a software decoder; 0 = the share of the cores left by the software decoders already open
    /// (`software_thread_budget`).
    pub sw_threads: i32,
    /// `sw_threads` is a `ThreadPlan::Scrub` count: counted in the shared budget (`OPEN_BIG_THREADS`) like a budgeted decoder.
    pub scrub: bool,
}

/// One compressed picture to send, timing in stream ticks.
pub struct InputPacket<'a> {
    pub data: &'a [u8],
    pub pts: i64,
    pub dts: i64,
    pub duration: i64,
    pub key: bool,
}

/// Result of sending input.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Sent {
    Accepted,
    /// The decoder is full: receive frames, then send again.
    Full,
}

/// Result of asking for output.
pub enum Received {
    Frame(Frame),
    NeedsInput,
    Ended,
}

/// One video decoder (software, or D3D11VA).
pub struct Decoder {
    raw: NonNull<ffi::Decoder>,
    /// A software decoder: it counts in `OPEN_SOFTWARE` until dropped.
    software: bool,
    /// Threads this big software decoder adds to `OPEN_BIG_THREADS` (0 = not counted).
    big_threads: usize,
    /// A software decoder of a big picture: it counts in `OPEN_BIG_SOFTWARE` until dropped.
    big_software: bool,
}

/// Threads of all open big software decoders. Frame threading keeps about `threads - 1` extra 4K pictures per decoder
/// (33 MB each for 4:2:2 10-bit); a project holds ~17 decoders, most of them parked.
static OPEN_BIG_THREADS: AtomicUsize = AtomicUsize::new(0);

/// Frame threads all open big decoders may hold together; a decoder opened past it gets the floor of 2.
const BIG_THREAD_POOL: usize = 12;

/// `threads` for a big decoder opening while `open_total` threads of big decoders are open: the pool's rest, never below 2.
pub fn cap_big_threads(threads: i32, open_total: usize) -> i32 {
    cap_big_threads_with(threads, open_total, big_floor())
}

fn cap_big_threads_with(threads: i32, open_total: usize, floor: i32) -> i32 {
    let rest = BIG_THREAD_POOL.saturating_sub(open_total) as i32;
    // The floor may exceed the pool, but not without end: past twice the pool a decoder gets 2 (20 open 4K decoders at 4
    // threads were ~2.6 GB of frame threads).
    let floor = if open_total >= BIG_THREAD_POOL * 2 { floor.min(2) } else { floor };
    threads.min(rest.max(floor))
}

/// Frame threads a big software decoder keeps at least, however many decoders are open: 4 on a machine that is not weak,
/// 2 on a weak one (`set_weak_machine`). Cause of the load drops (night 2026-11-23): the budget follows the OPEN order, so the
/// 4K H.264 clip that plays got 2 threads because 6 others were open, and a 30 ms/frame decode on 2 threads cannot hold 30 fps
/// once SMT siblings are busy. Memory: a frame thread holds one picture in flight (4K 4:2:2 10-bit about 33 MB), so 4 threads
/// cost about 130 MB per big decoder. `SQ_BIG_THREAD_FLOOR=2` (or 3, 4) overrides the rule for A/B.
/// shortcut: the floor is given to every big decoder at open, idle ones keep their threads (ffmpeg cannot change the count
/// of an open decoder); upgrade when an idle decoder can be re-opened small once its layer is not playing for a while.
fn big_floor() -> i32 {
    floor_for(
        std::env::var("SQ_BIG_THREAD_FLOOR").ok().and_then(|v| v.parse().ok()),
        WEAK_MACHINE.load(Ordering::Relaxed),
    )
}

fn floor_for(env: Option<i32>, weak: bool) -> i32 {
    env.map_or(if weak { 2 } else { 4 }, |v| v.clamp(2, 4))
}

/// The floor never asks for more threads than a third of the cores: three 4K layers play at once (a 6-core machine gets
/// 2 each, not 4 x 3 threads on 6 cores); 12 cores and up keep 4.
fn floor_for_cores(floor: i32, cores: usize) -> i32 {
    floor.min((cores / 3) as i32).max(2)
}

/// Set by the app at start from `MachineResources::is_weak_for_decode` (Intel, 8 GB or less, 4 cores or fewer).
static WEAK_MACHINE: AtomicBool = AtomicBool::new(false);

pub fn set_weak_machine(weak: bool) {
    WEAK_MACHINE.store(weak, Ordering::Relaxed);
}

/// Open software decoders (they share the machine's cores). Counted from open to drop, not only while inside a decode call:
/// decoders open at project load, when none decodes yet, so a count of running calls is always empty at open time.
static OPEN_SOFTWARE: AtomicUsize = AtomicUsize::new(0);

/// Open big (4K and up) software decoders, budgeted or not: the scrub plan wants to be the only one.
static OPEN_BIG_SOFTWARE: AtomicUsize = AtomicUsize::new(0);

/// Big software decoders inside a decode call right now (`BusyBig`). The scrub plan counts these, not the open ones: a real
/// project keeps a decoder open for every clip near the playhead (the same file twice on two lanes, cut-in warm-ups), idle
/// while one clip scrubs, and the open count denied `Scrub` for all of them (app trace 2026-11-27: open 2..6, plan always `Playback`).
static BUSY_BIG_SOFTWARE: AtomicUsize = AtomicUsize::new(0);

/// Marks the calling decode as running on a big software decoder until dropped (`BUSY_BIG_SOFTWARE`).
pub struct BusyBig(bool);

impl BusyBig {
    pub fn enter(big_software: bool) -> BusyBig {
        if big_software {
            BUSY_BIG_SOFTWARE.fetch_add(1, Ordering::Relaxed);
        }
        BusyBig(big_software)
    }
}

impl Drop for BusyBig {
    fn drop(&mut self) {
        if self.0 {
            BUSY_BIG_SOFTWARE.fetch_sub(1, Ordering::Relaxed);
        }
    }
}

/// How many threads a software decoder decodes with: what the shared budget gave it at open (`Playback`), or a fixed larger
/// count while the playhead scrubs and no other big decoder competes (`Scrub`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ThreadPlan {
    Playback,
    Scrub(i32),
}

/// Frame+slice threads of a lone big decoder while scrubbing. Measured on a 16-core PC, 4K H.264 jumps: 4 threads 245 / 355 ms
/// p50, 8 threads 156 / 218 ms, 16 threads 151 / 196 ms: the last doubling gains little and holds ~33 MB a thread.
const SCRUB_THREADS: usize = 8;

/// The plan for a decoder: `Scrub` only for a big software decoder while scrubbing, when it is the only big software
/// decoder at work (`open_big` = those decoding now, the caller included) (a layered project keeps the shared budget) and the machine is not weak; never more threads than cores.
pub fn thread_plan(scrubbing: bool, big_software: bool, open_big: usize, cores: usize, weak: bool) -> ThreadPlan {
    if !scrubbing || !big_software || open_big >= 2 || weak || cores < 4 {
        return ThreadPlan::Playback;
    }
    ThreadPlan::Scrub(cores.min(SCRUB_THREADS) as i32)
}

/// How long a decoder keeps a plan chosen while the playhead still scrubs, before the open decoder count may demote it.
pub const PLAN_DWELL: std::time::Duration = std::time::Duration::from_secs(1);

/// Whether the decoder may switch from `from` to `to` now: the end of a scrub (`scrubbing` false) always; while scrubbing
/// only `Playback` -> `Scrub`, and only after `PLAN_DWELL`. A `Scrub` decoder keeps its threads until the scrub ends: another
/// decoder working for a moment (a key strip fill, the same clip on a second lane) flipped it back to the shared budget, and
/// every flip reopened the decoder and restarted the GOP (app run 2026-11-27: 4 of 24 cold jumps 200 ms slower than before).
pub fn plan_switch_allowed(scrubbing: bool, from: ThreadPlan, to: ThreadPlan, since: std::time::Duration) -> bool {
    from != to && (!scrubbing || (since >= PLAN_DWELL && to != ThreadPlan::Playback))
}

/// Big software decoders decoding now, this one included (the plan's input; trace).
pub fn busy_big_software() -> usize {
    BUSY_BIG_SOFTWARE.load(Ordering::Relaxed)
}

/// The machine inputs of the plan (trace only).
pub fn plan_inputs() -> String {
    format!("cores {} weak {} busy_big {}", logical_cores(), WEAK_MACHINE.load(Ordering::Relaxed), busy_big_software())
}

/// `thread_plan` for this process: the open decoder count and the machine from the shim's own state.
pub fn current_thread_plan(scrubbing: bool, big_software: bool) -> ThreadPlan {
    thread_plan(
        scrubbing,
        big_software,
        BUSY_BIG_SOFTWARE.load(Ordering::Relaxed),
        logical_cores(),
        WEAK_MACHINE.load(Ordering::Relaxed),
    )
}

/// Open software decoders and the frame threads the big ones hold (for the memory trace).
pub fn open_software_decoders() -> (usize, usize) {
    (OPEN_SOFTWARE.load(Ordering::Relaxed), OPEN_BIG_THREADS.load(Ordering::Relaxed))
}

/// Takes `want` frame threads (capped by `cap_big_threads`) from `pool` in one step; two parallel opens never overshoot it.
fn reserve_big_threads(pool: &AtomicUsize, want: i32) -> i32 {
    let mut cur = pool.load(Ordering::Relaxed);
    loop {
        let t = cap_big_threads(want, cur);
        match pool.compare_exchange_weak(cur, cur + t.max(0) as usize, Ordering::Relaxed, Ordering::Relaxed) {
            Ok(_) => return t,
            Err(now) => cur = now,
        }
    }
}

/// Pictures of this many pixels and up (4K, also portrait) get frame threads on top of slice threads.
const BIG_PIXELS: i64 = 3_500_000;

/// Threads for one software decoder: the logical cores divided by the open software decoders (this one included), so a
/// layered project does not start 4 x 4 frame threads on 6 cores. A big picture keeps 2 to 4 (a jump stalls on 1), a small one
/// 1 to 2 slice threads.
/// shortcut: decoders opened earlier keep the count they got (a falling sequence in open order); upgrade when a decoder can be re-opened with a new budget.
pub fn software_thread_budget(width: i32, height: i32, cores: usize, open_software: usize) -> i32 {
    budget_with_floor(width, height, cores, open_software, big_floor())
}

fn budget_with_floor(width: i32, height: i32, cores: usize, open_software: usize, floor: i32) -> i32 {
    let share = (cores.max(1) / open_software.max(1)) as i32;
    // Never above the core count.
    if i64::from(width) * i64::from(height) >= BIG_PIXELS {
        share.clamp(floor_for_cores(floor, cores).min(cores.max(2) as i32), 4)
    } else {
        share.clamp(1, 2)
    }
}

fn logical_cores() -> usize {
    std::thread::available_parallelism().map_or(2, |n| n.get())
}

// SAFETY: a decoder is used by one thread at a time (all methods take &mut self or run under the owner's lock).
unsafe impl Send for Decoder {}

impl Decoder {
    pub fn open(cfg: &DecoderConfig<'_>) -> Result<Decoder, ShimError> {
        let codec = CString::new(cfg.codec).map_err(|_| ShimError::failed("codec name", EINVAL))?;
        let extra_len = c_int::try_from(cfg.extradata.len()).map_err(|_| ShimError::failed("extradata", EINVAL))?;
        let mut raw = ptr::null_mut();
        let mut err = [0 as c_char; ERR_LEN];
        let budgeted = !cfg.hardware && cfg.sw_threads <= 0;
        let big = i64::from(cfg.width) * i64::from(cfg.height) >= BIG_PIXELS;
        // Both counters are reserved before the open, so two parallel opens see each other; a failed open gives them back.
        let open_software = if cfg.hardware { 0 } else { OPEN_SOFTWARE.fetch_add(1, Ordering::Relaxed) + 1 };
        let threads = if cfg.hardware {
            0
        } else if budgeted {
            let t = software_thread_budget(cfg.width, cfg.height, logical_cores(), open_software);
            if big { reserve_big_threads(&OPEN_BIG_THREADS, t) } else { t }
        } else {
            cfg.sw_threads
        };
        // A scrub decoder's threads count in the budget (a second big decoder opening meanwhile sees them); other fixed-thread
        // decoders (throw-away `once`, posters) are transient and count nowhere, so they do not flip a scrub plan.
        let counted = budgeted || cfg.scrub;
        let big_threads = if counted && big { threads.max(0) as usize } else { 0 };
        if cfg.scrub && big {
            OPEN_BIG_THREADS.fetch_add(big_threads, Ordering::Relaxed);
        }
        let big_software = big && !cfg.hardware && counted;
        if big_software {
            OPEN_BIG_SOFTWARE.fetch_add(1, Ordering::Relaxed);
        }
        let give_back = || {
            if big_software {
                OPEN_BIG_SOFTWARE.fetch_sub(1, Ordering::Relaxed);
            }
            OPEN_BIG_THREADS.fetch_sub(big_threads, Ordering::Relaxed);
            if !cfg.hardware {
                OPEN_SOFTWARE.fetch_sub(1, Ordering::Relaxed);
            }
        };
        // SAFETY: all pointers are valid for the call; the shim copies the extradata and keeps no borrowed pointer.
        let r = unsafe {
            ffi::sq_dec_open(
                codec.as_ptr(),
                cfg.extradata.as_ptr(),
                extra_len,
                cfg.width,
                cfg.height,
                cfg.bits_per_coded_sample,
                cfg.codec_tag,
                cfg.tb_num,
                cfg.tb_den,
                c_int::from(cfg.hardware),
                cfg.extra_hw_frames,
                threads,
                &mut raw,
                err.as_mut_ptr(),
                ERR_LEN as c_int,
            )
        };
        match NonNull::new(raw) {
            Some(raw) if r == 0 => Ok(Decoder { raw, software: !cfg.hardware, big_threads, big_software }),
            _ => {
                give_back();
                Err(ShimError::new("decoder", if r == 0 { -1 } else { r }, &err))
            }
        }
    }

    /// "h264 (software)" / "h264 (d3d11va)".
    pub fn name(&self) -> String {
        // SAFETY: the name is a NUL-terminated array inside the live decoder object.
        unsafe {
            let p = ffi::sq_dec_name(self.raw.as_ptr());
            if p.is_null() { String::new() } else { CStr::from_ptr(p).to_string_lossy().into_owned() }
        }
    }

    pub fn send(&mut self, p: &InputPacket<'_>) -> Result<Sent, ShimError> {
        let size = c_int::try_from(p.data.len()).map_err(|_| ShimError::failed("send sample", EINVAL))?;
        // SAFETY: `data` is valid for `size` bytes; the shim copies it into its own packet.
        let r = unsafe {
            ffi::sq_dec_send(self.raw.as_ptr(), p.data.as_ptr(), size, p.pts, p.dts, p.duration, c_int::from(p.key))
        };
        Self::sent(r, "send sample")
    }

    /// Signals the end of the stream (the decoder then drains its buffered pictures).
    pub fn send_end(&mut self) -> Result<Sent, ShimError> {
        // SAFETY: a null packet is the shim's end-of-stream marker.
        let r = unsafe { ffi::sq_dec_send(self.raw.as_ptr(), ptr::null(), 0, 0, 0, 0, 0) };
        Self::sent(r, "drain")
    }

    fn sent(r: c_int, what: &str) -> Result<Sent, ShimError> {
        match r {
            0 => Ok(Sent::Accepted),
            1 => Ok(Sent::Full),
            _ => Err(ShimError::failed(what, r)),
        }
    }

    pub fn receive(&mut self) -> Result<Received, ShimError> {
        let mut out = ptr::null_mut();
        // SAFETY: `out` is valid for the call; on 0 it receives a frame we then own.
        let r = unsafe { ffi::sq_dec_receive(self.raw.as_ptr(), &mut out) };
        match (r, NonNull::new(out)) {
            (0, Some(raw)) => Ok(Received::Frame(Frame::adopt(raw))),
            (1, _) => Ok(Received::NeedsInput),
            (2, _) => Ok(Received::Ended),
            _ => Err(ShimError::failed("decode", if r == 0 { -1 } else { r })),
        }
    }

    /// Drops buffered pictures (before a seek).
    pub fn flush(&mut self) {
        // SAFETY: the handle is live.
        unsafe { ffi::sq_dec_flush(self.raw.as_ptr()) }
    }

    /// Preview decode for software decoders: no loop filter (faster, not exact). Flush after turning it off.
    pub fn set_fast(&mut self, on: bool) {
        // SAFETY: the handle is live.
        unsafe { ffi::sq_dec_set_fast(self.raw.as_ptr(), c_int::from(on)) }
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        OPEN_BIG_THREADS.fetch_sub(self.big_threads, Ordering::Relaxed);
        if self.big_software {
            OPEN_BIG_SOFTWARE.fetch_sub(1, Ordering::Relaxed);
        }
        if self.software {
            OPEN_SOFTWARE.fetch_sub(1, Ordering::Relaxed);
        }
        // SAFETY: the handle came from `sq_dec_open` and is closed once. Frames hold their own references.
        unsafe { ffi::sq_dec_close(self.raw.as_ptr()) }
    }
}

/// A reduced download: planes packed in the NV12 / P010 layout at the reduced size; `chroma_422` when the chroma plane keeps
/// the full height (P210 layout: a deep 4:2:2 source is not merged vertically, the GPU samples it as it is).
pub struct Reduced {
    pub chroma_422: bool,
    pub bytes: PooledBytes,
    pub width: i32,
    pub height: i32,
}

/// A reference to one decoded picture.
pub struct Frame {
    raw: NonNull<ffi::Frame>,
    pub width: i32,
    pub height: i32,
    pub hardware: bool,
    /// Array slice of the D3D11 texture (hardware frames).
    pub texture_index: i32,
    /// AVPixelFormat of the pixels (NV12, P010, YUV420P...).
    pub sw_format: i32,
    /// Best-effort pts in stream ticks.
    pub pts: i64,
    texture: usize,
    /// Field order this picture is deinterlaced with on download (`None`: as stored).
    deinterlace: Option<FieldOrder>,
}

// SAFETY: the AVFrame behind the handle is immutable after it left the decoder; downloads only read it.
unsafe impl Send for Frame {}
// SAFETY: see above.
unsafe impl Sync for Frame {}

impl Frame {
    fn adopt(raw: NonNull<ffi::Frame>) -> Frame {
        let mut info = std::mem::MaybeUninit::<ffi::FrameInfo>::zeroed();
        // SAFETY: the handle is live; the shim fills a zeroed struct (null texture pointer is valid).
        let i = unsafe {
            ffi::sq_frame_info(raw.as_ptr(), info.as_mut_ptr());
            info.assume_init()
        };
        Frame {
            raw,
            width: i.width,
            height: i.height,
            hardware: i.hardware != 0,
            texture_index: i.texture_index,
            sw_format: i.sw_format,
            pts: i.pts,
            texture: i.texture as usize,
            deinterlace: None,
        }
    }

    /// `ID3D11Texture2D*` of a hardware frame (0 for software frames); valid while this frame lives.
    pub fn d3d11_texture(&self) -> usize {
        self.texture
    }

    /// Pixels in NV12 (8 bit) or P010 (deeper) layout, planes packed. Blocking (a GPU copy for hardware frames).
    pub fn download(&self) -> Result<Vec<u8>, ShimError> {
        self.download_pooled().map(PooledBytes::into_vec)
    }

    /// [`Frame::download`] into a buffer of the shared pool: the picture's owner returns it by dropping it.
    pub fn download_pooled(&self) -> Result<PooledBytes, ShimError> {
        let bytes = self.download_stored()?;
        let Some(order) = self.deinterlace else { return Ok(bytes) };
        let (w, h) = (usize::try_from(self.width).unwrap_or(0), usize::try_from(self.height).unwrap_or(0));
        let wide = bytes.len() >= w * h * 3;
        let stride = if wide { w * 2 } else { w };
        // An odd width has a wider chroma row than luma row in the packed layout: left as stored.
        if w % 2 != 0 {
            return Ok(bytes);
        }
        Ok(sq_media::deinterlacer::deinterlace_biplanar_420(&bytes, w, h, stride, wide, order)
            .map_or(bytes, PooledBytes::from))
    }

    /// The deinterlaced picture of this frame from now on (`download`; the reduced path steps aside).
    pub fn set_deinterlace(&mut self, order: Option<FieldOrder>) {
        self.deinterlace = order;
    }

    fn download_stored(&self) -> Result<PooledBytes, ShimError> {
        let _span = sq_os::trace::span_args("xfer", "frame download", || {
            format!("{}x{} hw={}", self.width, self.height, self.texture != 0)
        });
        // SAFETY: handle live.
        let size = unsafe { ffi::sq_frame_download_size(self.raw.as_ptr()) };
        let len = usize::try_from(size).ok().filter(|n| *n > 0).ok_or_else(|| ShimError::failed("frame size", size))?;
        let mut out = BufferPool::shared().take(len);
        // SAFETY: `out` holds `size` bytes, passed as the capacity.
        let r = unsafe { ffi::sq_frame_download(self.raw.as_ptr(), out.as_mut_ptr(), size) };
        if r == 0 { Ok(out) } else { Err(ShimError::failed("frame download", r)) }
    }

    /// The decoded pixel format has an alpha channel: such pictures go through `download_rgba`.
    pub fn has_alpha(&self) -> bool {
        // SAFETY: handle live.
        unsafe { ffi::sq_frame_has_alpha(self.raw.as_ptr()) != 0 }
    }

    /// 8-bit RGBA, straight alpha, width * height * 4 bytes. Blocking.
    pub fn download_rgba(&self) -> Result<Vec<u8>, ShimError> {
        self.download_rgba_pooled().map(PooledBytes::into_vec)
    }

    /// [`Frame::download_rgba`] into a buffer of the shared pool.
    pub fn download_rgba_pooled(&self) -> Result<PooledBytes, ShimError> {
        let len = usize::try_from(self.width).unwrap_or(0) * usize::try_from(self.height).unwrap_or(0) * 4;
        let cap = c_int::try_from(len).map_err(|_| ShimError::failed("frame download", EINVAL))?;
        // swscale's SIMD writers may store a few bytes past the last line; the pad keeps those off the heap's bookkeeping.
        let mut out = BufferPool::shared().take(len + 64);
        // SAFETY: `out` holds `cap` bytes (plus the pad).
        let r = unsafe { ffi::sq_frame_download_rgba(self.raw.as_ptr(), out.as_mut_ptr(), cap) };
        out.truncate(len);
        if r == 0 { Ok(out) } else { Err(ShimError::failed("frame download", r)) }
    }

    /// The same layout box-reduced by `divisor` (1, 2, 4) on `threads` threads; `None` when this frame has no such path
    /// (use `download`).
    pub fn download_reduced(&self, divisor: i32, threads: i32) -> Result<Option<Reduced>, ShimError> {
        if self.deinterlace.is_some() {
            return Ok(None); // the fields need every line: full size, then the caller reduces
        }
        let (mut w, mut h) = (0, 0);
        // SAFETY: handle live, `w` and `h` valid for writes.
        let size = unsafe { ffi::sq_frame_download_reduced_size(self.raw.as_ptr(), divisor, &mut w, &mut h) };
        let Some(len) = usize::try_from(size).ok().filter(|n| *n > 0) else { return Ok(None) };
        let _span = sq_os::trace::span_args("xfer", "frame download reduced", || {
            format!("{}x{} div={divisor}", self.width, self.height)
        });
        let mut out = BufferPool::shared().take(len);
        // SAFETY: `out` holds `size` bytes, passed as the capacity.
        let r = unsafe { ffi::sq_frame_download_reduced(self.raw.as_ptr(), divisor, threads, out.as_mut_ptr(), size) };
        match r {
            0 => {
                // SAFETY: handle live.
                let chroma_422 = unsafe { ffi::sq_frame_reduced_422(self.raw.as_ptr()) } != 0;
                Ok(Some(Reduced { bytes: out, width: w, height: h, chroma_422 }))
            }
            1 => Ok(None),
            _ => Err(ShimError::failed("frame download", r)),
        }
    }
}

impl Drop for Frame {
    fn drop(&mut self) {
        // SAFETY: the frame was handed to us by `sq_dec_receive` and is freed once.
        unsafe { ffi::sq_frame_free(self.raw.as_ptr()) }
    }
}

/// A whole audio stream decoded to interleaved float.
pub struct AudioPcm {
    /// `channels` values per frame.
    pub samples: Vec<f32>,
    pub frames: i64,
    pub channels: i32,
    /// Channel count of the file itself.
    pub source_channels: i32,
}

/// Decodes the best audio stream of `path`, resampled to `rate` and `channels` (1 or 2).
pub fn decode_audio(path: &Path, rate: i32, channels: i32) -> Result<AudioPcm, ShimError> {
    decode_audio_track(path, rate, channels, None)
}

/// The channels of every audio track of `path` in file order (empty without sound).
pub fn audio_track_channels(path: &Path) -> Result<Vec<i64>, ShimError> {
    let c = c_path(path)?;
    let mut counts = [0 as c_int; 64];
    // SAFETY: `counts` holds the 64 entries passed as the capacity.
    let n = unsafe { ffi::sq_audio_track_channels(c.as_ptr(), counts.as_mut_ptr(), 64) };
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let n = usize::try_from(n).map_err(|_| ShimError::failed(&format!("audio tracks of {name}"), n))?;
    Ok(counts[..n.min(64)].iter().map(|c| i64::from(*c)).collect())
}

/// The sample rate of every audio track of `path` in file order (the order of `audio_track_channels`).
pub fn audio_track_rates(path: &Path) -> Result<Vec<i32>, ShimError> {
    let c = c_path(path)?;
    let mut rates = [0 as c_int; 64];
    // SAFETY: `rates` holds the 64 entries passed as the capacity.
    let n = unsafe { ffi::sq_audio_track_rates(c.as_ptr(), rates.as_mut_ptr(), 64) };
    let n = usize::try_from(n).map_err(|_| ShimError::failed("audio track rates", n))?;
    Ok(rates[..n.min(64)].to_vec())
}

/// Like `decode_audio` for audio track `ordinal` (0-based among the audio tracks; `None` = the best one).
pub fn decode_audio_track(
    path: &Path,
    rate: i32,
    channels: i32,
    ordinal: Option<usize>,
) -> Result<AudioPcm, ShimError> {
    let c = c_path(path)?;
    let ordinal = ordinal.map_or(-1, |o| c_int::try_from(o).unwrap_or(-1));
    let mut a = ffi::Audio { samples: ptr::null_mut(), frames: 0, channels: 0, sample_rate: 0, source_channels: 0 };
    let mut err = [0 as c_char; ERR_LEN];
    // SAFETY: valid pointers; on success `a.samples` points to `frames * channels` floats we copy and then free.
    unsafe {
        let r =
            ffi::sq_audio_decode_track(c.as_ptr(), rate, channels, ordinal, &mut a, err.as_mut_ptr(), ERR_LEN as c_int);
        if r != 0 {
            let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            return Err(ShimError::new(&format!("audio {name}"), r, &err));
        }
        let n = usize::try_from(a.frames).unwrap_or(0) * usize::try_from(a.channels).unwrap_or(0);
        let samples = if a.samples.is_null() { Vec::new() } else { std::slice::from_raw_parts(a.samples, n).to_vec() };
        ffi::sq_audio_free(&mut a);
        Ok(AudioPcm { samples, frames: a.frames, channels: a.channels, source_channels: a.source_channels })
    }
}

/// What the container says about the audio stream and length, read without decoding.
pub struct AudioProbe {
    /// Container duration in microseconds; `None` = unknown.
    pub duration_us: Option<i64>,
    /// Rate, channels and codec of the best audio stream; `None` = no sound.
    pub audio: Option<(i32, i32, String)>,
}

/// Opens `path` and reads its stream headers only.
pub fn probe_audio(path: &Path) -> Result<AudioProbe, ShimError> {
    let c = c_path(path)?;
    // SAFETY: all-zero is a valid `Probe` (integers and char arrays); `sq_probe` zeroes it again anyway.
    let mut p: ffi::Probe = unsafe { std::mem::zeroed() };
    let mut err = [0 as c_char; ERR_LEN];
    // SAFETY: valid pointers for the call; the struct holds no pointers.
    let r = unsafe { ffi::sq_probe(c.as_ptr(), &mut p, err.as_mut_ptr(), ERR_LEN as c_int) };
    if r != 0 {
        return Err(ShimError::new("probe", r, &err));
    }
    Ok(AudioProbe {
        duration_us: (p.duration_us >= 0).then_some(p.duration_us),
        audio: (p.has_audio != 0).then(|| (p.audio_rate, p.audio_channels, c_string(&p.audio_codec))),
    })
}

/// A streaming audio reader: decodes on demand and keeps nothing but what the C++ side needs to continue.
pub struct AudioReader {
    raw: ptr::NonNull<ffi::AudioReader>,
    channels: usize,
    /// Frames from the container's duration; -1 = unknown.
    pub estimated_frames: i64,
    /// Channel count of the file itself.
    pub source_channels: i32,
}

// SAFETY: the C++ reader is used from one thread at a time (callers hold a mutex around every call).
unsafe impl Send for AudioReader {}

impl AudioReader {
    /// Opens audio track `ordinal` (`None` = the best one) as `channels` floats at `rate` (any count: the layout is the
    /// default one for it).
    pub fn open(path: &Path, rate: i32, channels: i32, ordinal: Option<usize>) -> Result<AudioReader, ShimError> {
        let c = c_path(path)?;
        let ordinal = ordinal.map_or(-1, |o| c_int::try_from(o).unwrap_or(-1));
        let (mut estimated, mut source) = (-1i64, 0 as c_int);
        let mut err = [0 as c_char; ERR_LEN];
        // SAFETY: valid pointers for the call; the handle is owned by the result and freed in `Drop`.
        let raw = unsafe {
            ffi::audio_reader_open(ffi::AudioReaderOpenArgs {
                path: c.as_ptr(),
                rate,
                channels,
                ordinal,
                estimated: &mut estimated,
                source_channels: &mut source,
                err: err.as_mut_ptr(),
                err_len: ERR_LEN as c_int,
            })
        };
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let raw = ptr::NonNull::new(raw).ok_or_else(|| ShimError::new(&format!("audio {name}"), -1, &err))?;
        Ok(AudioReader {
            raw,
            channels: usize::try_from(channels).unwrap_or(1),
            estimated_frames: estimated,
            source_channels: source,
        })
    }

    /// Fills `out` (interleaved, a multiple of `channels` long) with frames from `start`; returns the frames written.
    pub fn read(&mut self, start: i64, out: &mut [f32]) -> Result<usize, ShimError> {
        let frames = c_int::try_from(out.len() / self.channels).map_err(|_| ShimError::failed("audio read", EINVAL))?;
        // SAFETY: `out` holds `frames * channels` floats; the handle is live.
        let n = unsafe { ffi::sq_audio_reader_read(self.raw.as_ptr(), start, out.as_mut_ptr(), frames) };
        usize::try_from(n).map_err(|_| ShimError::failed("audio read", n))
    }

    /// The length in frames once the end of the stream was reached.
    pub fn end(&self) -> Option<i64> {
        // SAFETY: the handle is live.
        let n = unsafe { ffi::sq_audio_reader_end(self.raw.as_ptr()) };
        (n >= 0).then_some(n)
    }
}

impl Drop for AudioReader {
    fn drop(&mut self) {
        // SAFETY: the handle came from `sq_audio_reader_open` and is closed once.
        unsafe { ffi::sq_audio_reader_close(self.raw.as_ptr()) }
    }
}

/// The picture size of a still image file, read without decoding.
pub fn image_size(path: &Path) -> Result<(usize, usize), ShimError> {
    let c = c_path(path)?;
    let (mut w, mut h) = (0 as c_int, 0 as c_int);
    // SAFETY: valid pointers for the call.
    let r = unsafe { ffi::sq_image_size(c.as_ptr(), &mut w, &mut h) };
    if r != 0 || w <= 0 || h <= 0 {
        return Err(ShimError::failed("image size", if r != 0 { r } else { EINVAL }));
    }
    Ok((w as usize, h as usize))
}

/// The first picture of a still image file as straight 8-bit RGBA at its own size.
pub fn image_rgba(path: &Path, width: usize, height: usize) -> Result<Vec<u8>, ShimError> {
    let c = c_path(path)?;
    let mut buf = vec![0u8; width * height * 4];
    let cap = c_int::try_from(buf.len()).map_err(|_| ShimError::failed("image decode", EINVAL))?;
    // SAFETY: `buf` holds `cap` bytes.
    let r = unsafe { ffi::sq_image_decode_rgba(c.as_ptr(), buf.as_mut_ptr(), cap) };
    if r != 0 {
        return Err(ShimError::failed("image decode", r));
    }
    Ok(buf)
}

#[cfg(test)]
mod version_tests {
    #[test]
    fn the_loaded_libraries_are_the_ones_the_headers_describe() {
        // Built and run against one FFmpeg install: nothing differs. With no FFmpeg linked the check is vacuous.
        assert_eq!(super::version_mismatch(), None);
    }
}

#[cfg(test)]
mod thread_budget_tests {
    /// The share rule with the old floor of 2 (the floor itself is tested below).
    fn b(w: i32, h: i32, cores: usize, open: usize) -> i32 {
        super::budget_with_floor(w, h, cores, open, 2)
    }

    #[test]
    fn layered_4k_project_on_six_cores_stays_under_the_cores() {
        // 4 4K decoders decoding at once: each sees the ones before it, the total stays near the 6 cores, never 4 x 4.
        let threads: Vec<i32> = (1..=4).map(|open| b(3840, 2160, 6, open)).collect();
        assert_eq!(threads, vec![4, 3, 2, 2]);
        assert!(threads.iter().sum::<i32>() < 16);
    }

    #[test]
    fn single_big_decoder_gets_up_to_four() {
        assert_eq!(b(3840, 2160, 16, 1), 4);
        assert_eq!(b(3840, 2160, 32, 1), 4);
        assert_eq!(b(2160, 3840, 8, 1), 4);
    }

    #[test]
    fn big_decoder_never_below_two_small_never_below_one() {
        assert_eq!(b(3840, 2160, 6, 12), 2);
        assert_eq!(b(1920, 1080, 6, 12), 1);
        assert_eq!(b(1920, 1080, 16, 1), 2);
        assert_eq!(b(1920, 1080, 0, 0), 1);
    }

    #[test]
    fn many_open_big_decoders_share_a_thread_pool() {
        let c = |t, o| super::cap_big_threads_with(t, o, 2);
        assert_eq!(c(4, 0), 4);
        assert_eq!(c(4, 10), 2);
        assert_eq!(c(4, 11), 2);
        assert_eq!(c(4, 40), 2);
        // 17 decoders opening one after another stay near the pool plus the floor, not 17 x 4.
        let mut open = 0;
        for _ in 0..17 {
            open += c(4, open) as usize;
        }
        assert!(open <= 12 + 2 * 17, "{open}");
        assert!(open < 17 * 4);
    }

    #[test]
    fn a_lone_big_software_decoder_scrubs_on_more_threads_and_playback_keeps_the_budget() {
        use super::{ThreadPlan::*, thread_plan as p};
        assert_eq!(p(true, true, 1, 16, false), Scrub(8));
        assert_eq!(p(true, true, 1, 6, false), Scrub(6), "never more threads than cores");
        assert_eq!(p(false, true, 1, 16, false), Playback, "playing or paused: the shared budget");
        assert_eq!(p(true, true, 2, 16, false), Playback, "a second big decoder competes");
        assert_eq!(p(true, false, 1, 16, false), Playback, "hardware or small pictures");
        assert_eq!(p(true, true, 1, 16, true), Playback, "weak machine");
        assert_eq!(p(true, true, 1, 2, false), Playback, "2 cores");
    }

    #[test]
    fn only_big_software_decodes_at_work_count_for_the_scrub_plan() {
        use super::{BusyBig, ThreadPlan::Playback, busy_big_software, current_thread_plan};
        // Other tests may decode at the same time, so only bounds that hold whatever they do.
        let a = BusyBig::enter(true);
        let _small = BusyBig::enter(false);
        assert!(busy_big_software() >= 1);
        let b = BusyBig::enter(true);
        assert!(busy_big_software() >= 2);
        assert_eq!(current_thread_plan(true, true), Playback, "a second big decoder at work keeps the shared budget");
        drop((a, b));
    }

    #[test]
    fn a_plan_switch_while_scrubbing_waits_for_the_dwell_time() {
        use super::{PLAN_DWELL, ThreadPlan::*, plan_switch_allowed as ok};
        let short = PLAN_DWELL / 2;
        assert!(!ok(true, Scrub(8), Playback, short), "another decoder opened a moment ago");
        assert!(!ok(true, Scrub(8), Playback, PLAN_DWELL), "a scrub decoder keeps its threads until the scrub ends");
        assert!(!ok(true, Playback, Scrub(8), short));
        assert!(ok(true, Playback, Scrub(8), PLAN_DWELL));
        assert!(ok(false, Scrub(8), Playback, short), "the end of the scrub switches at once");
        assert!(!ok(true, Playback, Playback, PLAN_DWELL), "no change, no switch");
    }

    #[test]
    fn a_scrub_decoder_counts_in_the_big_decoder_budget_and_transient_ones_do_not() {
        // 8 scrub threads of the pool of 12 leave 4 for a second big decoder (it keeps its floor of 4 anyway).
        assert_eq!(super::cap_big_threads_with(4, 8, 2), 4);
        assert_eq!(super::cap_big_threads_with(4, 11, 2), 2, "pool nearly spent: the second decoder gets the floor");
    }

    #[test]
    fn a_floor_keeps_the_playing_big_decoder_at_four_threads_with_many_open() {
        use super::{budget_with_floor as f, cap_big_threads_with as c};
        assert_eq!(f(3840, 2160, 16, 7, 2), 2);
        assert_eq!(f(3840, 2160, 16, 7, 4), 4);
        assert_eq!(f(1920, 1080, 16, 7, 4), 2, "small pictures are not raised");
        assert_eq!(c(4, 40, 2), 2);
        assert_eq!(c(4, 20, 4), 4, "the pool is spent but the floor still gives 4");
    }

    #[test]
    fn the_floor_is_four_by_default_two_on_a_weak_machine_and_the_switch_wins() {
        use super::{budget_with_floor as f, floor_for};
        assert_eq!(floor_for(None, false), 4);
        assert_eq!(floor_for(None, true), 2, "4 cores / 8 GB: 7 open 4K decoders must not hold 4 threads each");
        assert_eq!(floor_for(Some(2), false), 2, "the switch turns the rule off");
        assert_eq!(floor_for(Some(9), true), 4);
        // 4-core machine: 7 open 4K decoders stay at the weak floor, never above the cores.
        assert_eq!(f(3840, 2160, 4, 7, floor_for(None, true)), 2);
        assert_eq!(f(3840, 2160, 3, 7, 4), 2, "a third of the cores, at least 2");
        // 16-core machine, 7 open: the playing decoder keeps 4.
        assert_eq!(f(3840, 2160, 16, 7, floor_for(None, false)), 4);
        // 6 cores, 3 playing 4K layers: 2 threads each (6 on 6 cores), not 4 each.
        assert_eq!(f(3840, 2160, 6, 7, floor_for(None, false)), 2);
        assert_eq!(f(3840, 2160, 8, 7, 4), 2);
        assert_eq!(f(3840, 2160, 12, 7, 4), 4);
        assert_eq!(super::cap_big_threads_with(4, 24, 4), 2, "past twice the pool the floor drops to 2");
        assert_eq!(super::cap_big_threads_with(4, 23, 4), 4);
    }

    #[test]
    fn open_order_without_any_send_gives_a_falling_sequence() {
        // Opening at project load: nothing decodes yet, the budget still falls with the number of open decoders.
        let threads: Vec<i32> = (1..=6).map(|open| b(3840, 2160, 6, open)).collect();
        assert_eq!(threads, vec![4, 3, 2, 2, 2, 2]);
    }

    #[test]
    fn parallel_big_opens_never_overshoot_the_pool() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let pool = AtomicUsize::new(0);
        let granted: i32 = std::thread::scope(|s| {
            let hs: Vec<_> = (0..8).map(|_| s.spawn(|| super::reserve_big_threads(&pool, 4))).collect();
            hs.into_iter().map(|h| h.join().unwrap()).sum()
        });
        // 3 x 4 fill the pool of 12, the rest get the floor (2 once twice the pool is spent): the same in any order.
        let mut open = 12;
        for _ in 0..5 {
            open += super::cap_big_threads(4, open) as usize;
        }
        assert_eq!(granted as usize, open);
        assert_eq!(pool.load(Ordering::Relaxed), granted as usize);
    }

    #[test]
    fn portrait_4k_counts_as_big() {
        assert_eq!(b(2160, 3840, 16, 4), 4);
        assert_eq!(b(1080, 1920, 16, 4), 2);
    }
}
