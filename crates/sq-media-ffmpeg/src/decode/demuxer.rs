use super::color::{field_order_of, matrix_tag, primaries_tag, transfer_tag};
use super::error::media_error;
use super::timing::{FrameTable, PacketTiming, TimeBase};
use crate::shim::{Demux, Packet, VideoInfo};
use sq_core_model::VideoTrackInfo;
use sq_core_time::Time;
use sq_media::demuxing::{BoxFuture, DemuxedFormat, DemuxedSample, Demuxing, SampleReading};
use sq_media::media_error::MediaError;
use sq_media::sample_index::SampleIndex;
use std::collections::BTreeSet;
use std::ops::RangeInclusive;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::SystemTime;

/// What a sample reader needs; shared so a reader outlives the borrow of the demuxer.
struct Shared {
    demux: Demux,
    table: FrameTable,
}

impl Shared {
    fn sample(&self, ordinal: usize) -> Result<DemuxedSample, MediaError> {
        let data = self.demux.read(ordinal).map_err(|e| media_error(&e, ""))?;
        let p = self.demux.packets().get(ordinal).ok_or(MediaError::Truncated)?;
        let (pts, dts, duration) = self.table.sample_times(ordinal).ok_or(MediaError::Truncated)?;
        Ok(DemuxedSample { data, pts, dts, duration, is_sync: p.key != 0 })
    }
}

/// `Demuxing` over FFmpeg (any container FFmpeg reads): the best video stream, indexed once at open.
pub struct FFmpegDemuxer {
    shared: Arc<Shared>,
    format: DemuxedFormat,
    rotation: i64,
    raw: VideoInfo,
}

type SharedSlot = Arc<OnceLock<Result<Arc<FFmpegDemuxer>, MediaError>>>;
/// (path, file size, modified time) of an opened file, its slot, newest last.
type SharedKey = (PathBuf, u64, Option<SystemTime>);
static SHARED: Mutex<Vec<(SharedKey, SharedSlot)>> = Mutex::new(Vec::new());
const SHARED_SLOTS: usize = 8;
/// Every real open of a file in this process, in order ([`FFmpegDemuxer::opens_of`]).
static OPENED: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

impl FFmpegDemuxer {
    /// The one open of `path` the whole app shares: opening reads the packet index of the file (hundreds of ms for a
    /// 3 GB camera file), so the engine, the info probe and posters wait for one open instead of making their own.
    /// A file that changed (size or modified time) is opened again; a failed open is not remembered.
    pub fn open_shared(path: &Path) -> Result<Arc<FFmpegDemuxer>, MediaError> {
        let meta = std::fs::metadata(path).ok();
        let key: SharedKey =
            (path.to_path_buf(), meta.as_ref().map_or(0, |m| m.len()), meta.and_then(|m| m.modified().ok()));
        let slot = {
            let mut all = SHARED.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(i) = all.iter().position(|(k, _)| *k == key) {
                let hit = all.remove(i);
                all.push(hit);
            } else {
                // The same path with another size or time is stale.
                all.retain(|(k, _)| k.0 != key.0);
                if all.len() >= SHARED_SLOTS {
                    all.remove(0);
                }
                all.push((key.clone(), Arc::default()));
            }
            Arc::clone(&all[all.len() - 1].1)
        };
        // Concurrent callers of one file wait here for the single open; the lock above is not held meanwhile.
        let opened = slot.get_or_init(|| FFmpegDemuxer::open(path).map(Arc::new)).clone();
        if opened.is_err() {
            SHARED.lock().unwrap_or_else(PoisonError::into_inner).retain(|(_, s)| !Arc::ptr_eq(s, &slot));
        }
        opened
    }

    /// Opens `path` itself, without sharing; most callers want [`FFmpegDemuxer::open_shared`], which opens a file once for everyone.
    pub fn open(path: &Path) -> Result<FFmpegDemuxer, MediaError> {
        FFmpegDemuxer::open_with(path, Demux::open)
    }

    /// `open` with FFmpeg's complete stream probe, which decodes a picture: the reference the quick open of an H.264 camera
    /// clip (stream facts from the SPS) is tested against.
    pub fn open_full_probe(path: &Path) -> Result<FFmpegDemuxer, MediaError> {
        FFmpegDemuxer::open_with(path, Demux::open_full_probe)
    }

    /// How many times `path` was really opened in this process (the shared open counts once). A file opened more than
    /// once at project open means a caller bypassed [`FFmpegDemuxer::open_shared`].
    pub fn opens_of(path: &Path) -> usize {
        OPENED.lock().unwrap_or_else(PoisonError::into_inner).iter().filter(|p| p.as_path() == path).count()
    }

    /// True when the stream facts came from the H.264 SPS and no picture was decoded to learn them.
    pub fn facts_from_sps(&self) -> bool {
        self.shared.demux.facts_from_sps()
    }

    /// True when the packet index came from the container's index and the open never read the (multi-GB) payload.
    pub fn index_without_payload(&self) -> bool {
        self.shared.demux.index_without_payload()
    }

    fn open_with(
        path: &Path,
        open: fn(&Path) -> Result<Demux, crate::shim::ShimError>,
    ) -> Result<FFmpegDemuxer, MediaError> {
        OPENED.lock().unwrap_or_else(PoisonError::into_inner).push(path.to_path_buf());
        let began = std::time::Instant::now();
        let demux = open(path).map_err(|e| media_error(&e, ""))?;
        sq_core_time::milestones::note(&format!(
            "demuxer opened {} on {} in {:.0} ms",
            path.file_name().map_or_else(String::new, |n| n.to_string_lossy().into_owned()),
            std::thread::current().name().unwrap_or("unnamed thread"),
            began.elapsed().as_secs_f64() * 1e3
        ));
        let raw = demux.info();
        let time_base = TimeBase::new(i64::from(raw.tb_num), i64::from(raw.tb_den)).ok_or(MediaError::Unreadable)?;
        let packets: Vec<_> = demux
            .packets()
            .iter()
            .map(|p| PacketTiming {
                pts: p.pts,
                dts: p.dts,
                duration: p.duration,
                is_key: p.key != 0,
                hidden: p.discard != 0,
            })
            .collect();
        let format = DemuxedFormat::new(&raw.codec, i64::from(raw.width), i64::from(raw.height), demux.extradata());
        let table = FrameTable::new(&packets, time_base);
        Ok(FFmpegDemuxer { shared: Arc::new(Shared { demux, table }), format, rotation: i64::from(raw.rotation), raw })
    }

    /// The stream facts as the shim reports them (pixel format name, color tag numbers, ...).
    pub fn raw(&self) -> &VideoInfo {
        &self.raw
    }

    pub fn table(&self) -> &FrameTable {
        &self.shared.table
    }

    pub fn packet_count(&self) -> usize {
        self.shared.demux.packets().len()
    }

    /// The raw timing of packet `ordinal` (stream ticks).
    pub fn packet(&self, ordinal: usize) -> Result<Packet, MediaError> {
        self.shared.demux.packets().get(ordinal).copied().ok_or(MediaError::Truncated)
    }

    /// The sample at decode ordinal `ordinal`.
    pub fn sample(&self, ordinal: usize) -> Result<DemuxedSample, MediaError> {
        self.shared.sample(ordinal)
    }

    /// The Dolby Vision configuration record of the video stream (the sample description atom's payload), if any.
    pub fn dolby_vision_record(&self) -> Option<[u8; 5]> {
        self.raw.dolby_vision
    }

    /// Track facts in the engine's terms (codec as the FFmpeg name, Rec. tags as FFmpeg's names).
    pub fn track_info(&self) -> VideoTrackInfo {
        let raw = &self.raw;
        let entries = self.index().entries();
        let nominal_frame_duration = if raw.fr_num > 0 && raw.fr_den > 0 {
            Time::new(i64::from(raw.fr_den), i64::from(raw.fr_num))
        } else {
            entries.first().map_or(Time::new(1, 30), |e| e.duration)
        };
        let durations: BTreeSet<Time> = entries.iter().map(|e| e.duration).filter(|d| *d > Time::ZERO).collect();
        let chroma = if raw.pix_fmt.contains("444") {
            "4:4:4"
        } else if raw.pix_fmt.contains("422") {
            "4:2:2"
        } else {
            "4:2:0"
        };
        VideoTrackInfo {
            width: i64::from(raw.width),
            height: i64::from(raw.height),
            codec: self.format.codec.clone(),
            bit_depth: i64::from(raw.bit_depth),
            chroma: chroma.to_string(),
            nominal_frame_duration,
            is_variable_frame_rate: durations.len() > 1,
            color_primaries: primaries_tag(raw.color_primaries).map(str::to_string),
            transfer: transfer_tag(raw.color_transfer).map(str::to_string),
            matrix: matrix_tag(raw.color_matrix).map(str::to_string),
            rotation: self.rotation,
            pixel_aspect: sq_media::pixel_aspect_tag::pixel_aspect(i64::from(raw.sar_num), i64::from(raw.sar_den)),
            pixel_aspect_override: None,
            field_order: field_order_of(raw.field_order),
            deinterlace_off: false,
        }
    }

    /// The first `prefix` bytes of `count` samples spread evenly over the file, first and last included: an integrity
    /// probe (a proxy whose writer was interrupted or overwritten holds frames that are not frames). `None` on a read error.
    pub fn sample_heads(&self, count: usize, prefix: usize) -> Option<Vec<Vec<u8>>> {
        let n = self.packet_count();
        if n == 0 {
            return None;
        }
        let picks: BTreeSet<usize> =
            (0..count.max(1)).map(|i| if count > 1 { i * (n - 1) / (count - 1) } else { 0 }).collect();
        picks.into_iter().map(|i| self.sample(i).ok().map(|s| s.data.into_iter().take(prefix).collect())).collect()
    }

    /// Highest decode ordinal among the frames of `range`.
    fn last_ordinal(&self, range: &RangeInclusive<usize>) -> i64 {
        let entries = self.index().entries();
        range.clone().filter_map(|i| entries.get(i)).map(|e| e.decode_ordinal).max().unwrap_or(0)
    }

    /// Reads samples `from...=through` in decode order.
    fn ordinal_reader(&self, from: i64, through: i64) -> OrdinalReader {
        let last = through.min(self.packet_count() as i64 - 1);
        OrdinalReader { shared: Arc::clone(&self.shared), next: from, last }
    }
}

impl Demuxing for FFmpegDemuxer {
    fn index(&self) -> &SampleIndex {
        &self.shared.table.index
    }

    fn format_description(&self) -> &DemuxedFormat {
        &self.format
    }

    fn rotation(&self) -> i64 {
        self.rotation
    }

    fn samples_for(&self, range: RangeInclusive<usize>) -> BoxFuture<'_, Result<Vec<DemuxedSample>, MediaError>> {
        Box::pin(async move {
            let mut reader =
                self.ordinal_reader(self.index().sync_decode_ordinal(*range.start()), self.last_ordinal(&range));
            (0..reader.count()).map(|_| reader.next()).collect()
        })
    }

    fn sample_reader(
        &self,
        range: RangeInclusive<usize>,
        from_decode_ordinal: i64,
    ) -> Result<Option<Box<dyn SampleReading>>, MediaError> {
        Ok(Some(Box::new(self.ordinal_reader(from_decode_ordinal, self.last_ordinal(&range)))))
    }
}

struct OrdinalReader {
    shared: Arc<Shared>,
    next: i64,
    last: i64,
}

impl SampleReading for OrdinalReader {
    fn count(&self) -> usize {
        usize::try_from(self.last - self.next + 1).unwrap_or(0)
    }

    fn next(&mut self) -> Result<DemuxedSample, MediaError> {
        if self.next > self.last {
            return Err(MediaError::Truncated);
        }
        let ordinal = usize::try_from(self.next).map_err(|_| MediaError::Truncated)?;
        self.next += 1;
        self.shared.sample(ordinal)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;
    use std::time::Instant;

    fn tool(name: &str) -> Option<String> {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .iter()
            .map(|d| format!("{d}/{name}"))
            .find(|p| Path::new(p).exists())
    }

    /// A long-GOP mp4 with B-frames (many packets): the open reads the index, not the file, and agrees with ffprobe.
    #[test]
    fn a_long_mp4_opens_fast_and_matches_ffprobe_packets() {
        let (Some(ffmpeg), Some(ffprobe)) = (tool("ffmpeg"), tool("ffprobe")) else { return };
        if !crate::shim::AVAILABLE {
            return;
        }
        let dir = std::env::temp_dir().join(format!("sq-demux-long-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let file = dir.join("long.mp4");
        let made = Command::new(ffmpeg)
            .args(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=30:duration=1200"])
            .args(["-c:v", "libx264", "-preset", "ultrafast", "-bf", "2", "-g", "250", "-pix_fmt", "yuv420p"])
            .arg(&file)
            .status();
        if !made.is_ok_and(|s| s.success()) {
            eprintln!("skipped: this ffmpeg has no libx264 (LGPL build)");
            let _ = std::fs::remove_dir_all(&dir);
            return;
        }
        let began = Instant::now();
        let d = FFmpegDemuxer::open(&file).expect("open");
        let first = d.sample(0).expect("first sample");
        let took = began.elapsed();
        assert!(!first.data.is_empty());
        assert!(d.packet_count() >= 36_000, "{} packets", d.packet_count());
        assert!(took.as_secs_f64() < 1.0, "open + first sample took {took:?}");

        let out = Command::new(ffprobe)
            .args(["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts,dts,duration,size,pos,flags"])
            .args(["-of", "csv=p=0"])
            .arg(&file)
            .output()
            .expect("ffprobe");
        let text = String::from_utf8_lossy(&out.stdout);
        let rows: Vec<Vec<&str>> = text.lines().map(|l| l.split(',').collect()).collect();
        assert_eq!(rows.len(), d.packet_count());
        for (i, r) in rows.iter().enumerate().step_by(7) {
            let p = d.packet(i).unwrap();
            assert_eq!(r[0].parse::<i64>().ok(), Some(p.pts), "pts {i}");
            assert_eq!(r[1].parse::<i64>().ok(), Some(p.dts), "dts {i}");
            assert_eq!(r[2].parse::<i64>().ok(), Some(p.duration), "duration {i}");
            assert_eq!(r[3].parse::<i64>().ok(), Some(i64::from(p.size)), "size {i}");
            assert_eq!(r[4].parse::<i64>().ok(), Some(p.pos), "pos {i}");
            assert_eq!(r[5].starts_with('K'), p.key != 0, "key {i}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The quick open of an H.264 camera clip learns the pixel format, range and colour tags from the SPS instead of decoding
    /// a picture; it has to tell exactly what FFmpeg's complete probe tells, and give the same packet table. An interlaced
    /// stream needs a decoded picture for its field order, so it keeps the complete probe.
    #[test]
    fn the_sps_open_tells_what_the_complete_probe_tells() {
        let (Some(ffmpeg), Some(ffprobe)) = (tool("ffmpeg"), tool("ffprobe")) else { return };
        if !crate::shim::AVAILABLE {
            return;
        }
        let dir = std::env::temp_dir().join(format!("sq-demux-sps-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        // (name, x264 arguments, the SPS says enough)
        let kinds: [(&str, &[&str], bool); 7] = [
            ("anamorphic", &["-pix_fmt", "yuv420p", "-vf", "setsar=4/3"], true),
            ("limited", &["-pix_fmt", "yuv420p", "-bf", "2"], true),
            ("full-8bit", &["-pix_fmt", "yuvj420p", "-color_range", "pc"], true),
            ("deep-422-full", &["-pix_fmt", "yuv422p10le", "-color_range", "pc", "-g", "1"], true),
            (
                "tagged-709",
                &["-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"],
                true,
            ),
            (
                "tagged-2020-hlg",
                &[
                    "-pix_fmt",
                    "yuv420p10le",
                    "-colorspace",
                    "bt2020nc",
                    "-color_primaries",
                    "bt2020",
                    "-color_trc",
                    "arib-std-b67",
                    "-color_range",
                    "tv",
                ],
                true,
            ),
            ("interlaced", &["-pix_fmt", "yuv420p", "-x264-params", "tff=1"], false),
        ];
        let mut made_any = false;
        for (name, args, from_sps) in kinds {
            let file = dir.join(format!("{name}.mp4"));
            let made = Command::new(&ffmpeg)
                .args(["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25:duration=2"])
                .args(["-c:v", "libx264", "-preset", "ultrafast"])
                .args(args)
                .arg(&file)
                .status();
            if !made.is_ok_and(|s| s.success()) {
                eprintln!("skipped {name}: this ffmpeg cannot encode it");
                continue;
            }
            made_any = true;
            let fast = FFmpegDemuxer::open(&file).expect("quick open");
            let full = FFmpegDemuxer::open_full_probe(&file).expect("complete probe");
            assert!(fast.index_without_payload(), "{name}: the open read the payload to index a plain mp4");
            assert_eq!(fast.facts_from_sps(), from_sps, "{name}: the quick open used the SPS or not");
            assert!(!full.facts_from_sps(), "{name}: the complete probe never takes the SPS");
            assert_eq!(fast.raw(), full.raw(), "{name}: stream facts");
            // The packet table is what ffprobe reads from the real file (the full probe's first packets carry the parser's key
            // flags, the container's are the reference).
            let out = Command::new(&ffprobe)
                .args([
                    "-v",
                    "error",
                    "-select_streams",
                    "v:0",
                    "-show_entries",
                    "packet=pts,dts,duration,size,pos,flags",
                ])
                .args(["-of", "csv=p=0"])
                .arg(&file)
                .output()
                .expect("ffprobe");
            let text = String::from_utf8_lossy(&out.stdout);
            let rows: Vec<Vec<&str>> = text.lines().map(|l| l.split(',').collect()).collect();
            assert_eq!(rows.len(), fast.packet_count(), "{name}: packet count");
            assert_eq!(fast.packet_count(), full.packet_count(), "{name}: packet count of the complete probe");
            for (i, r) in rows.iter().enumerate() {
                let p = fast.packet(i).expect("packet");
                assert_eq!(r[0].parse::<i64>().ok(), Some(p.pts), "{name}: pts {i}");
                assert_eq!(r[1].parse::<i64>().ok(), Some(p.dts), "{name}: dts {i}");
                assert_eq!(r[2].parse::<i64>().ok(), Some(p.duration), "{name}: duration {i}");
                assert_eq!(r[3].parse::<i64>().ok(), Some(i64::from(p.size)), "{name}: size {i}");
                assert_eq!(r[4].parse::<i64>().ok(), Some(p.pos), "{name}: pos {i}");
                assert_eq!(r[5].starts_with('K'), p.key != 0, "{name}: key {i}");
            }
        }
        assert!(made_any, "no variant could be encoded");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Two opens of one file share one demuxer; a file that changed is opened again; a missing file stays an error.
    #[test]
    fn open_shared_reuses_one_open_until_the_file_changes() {
        let Some(ffmpeg) = tool("ffmpeg") else { return };
        if !crate::shim::AVAILABLE {
            return;
        }
        let dir = std::env::temp_dir().join(format!("sq-demux-shared-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let file = dir.join("a.mp4");
        let make = |secs: &str| {
            Command::new(&ffmpeg)
                .args([
                    "-v",
                    "error",
                    "-y",
                    "-f",
                    "lavfi",
                    "-i",
                    &format!("testsrc2=size=64x64:rate=30:duration={secs}"),
                ])
                .args(["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"])
                .arg(&file)
                .status()
                .is_ok_and(|s| s.success())
        };
        if !make("1") {
            eprintln!("skipped: this ffmpeg has no libx264 (LGPL build)");
            let _ = std::fs::remove_dir_all(&dir);
            return;
        }
        let a = FFmpegDemuxer::open_shared(&file).expect("first");
        let b = FFmpegDemuxer::open_shared(&file).expect("second");
        assert!(Arc::ptr_eq(&a, &b));
        assert!(make("2"));
        let c = FFmpegDemuxer::open_shared(&file).expect("after the change");
        assert!(!Arc::ptr_eq(&a, &c));
        assert!(c.packet_count() > a.packet_count());
        assert!(FFmpegDemuxer::open_shared(&dir.join("missing.mp4")).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
