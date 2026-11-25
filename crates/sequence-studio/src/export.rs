//! File > Export on the desktop: frames come from the same render thread as the Program monitor (a paused engine that
//! seeks to each frame), the FFmpeg encoder writes the file.
//!
//! A preset shape that differs from the sequence's is fitted unstretched on black bars (`export_scale.rs`, `fit_rect`). shortcut: the engine
//! renders one frame at a time; upgrade with a sized composite. The audio is the playback mixer run offline
//! (`sq-app-hosts` `export_audio.rs`).

use sq_app_hosts::export_audio::FeederMix;
use sq_app_hosts::{ExportSetup, ExportSnapshot};
use sq_audio_out::clock::{HostClock, PlaybackClock};
use sq_core_model::{FieldOrder, Timeline};
use sq_core_time::{Id, Time, TimeRange};
use sq_draw::RgbaImage;
use sq_export::core::error::ExportError;
use sq_export::core::queue::{ExportQueue, ExportSources};
use sq_export::core::settings::{ExportSettings, RangeSelection};
use sq_export::core::stems::Stem;
use sq_export::core::timeline_audio::{TimelineAudioSource, export_frame_count};
use sq_export::core::traits::{AudioSource, ExportEncoding, ExportFrame, FrameSource};
use sq_export::encode::FfmpegExportEncoder;
use sq_frame::sqframe::{SQFrame, SQFrameColorSpace, SQFramePixelFormat};
use sq_gpu::gpu::Gpu;
use sq_media::embedded_lut::EmbeddedMeta;
use sq_media::media_opener::MediaOpener;
use sq_media_ffmpeg::decode::MemoryFrame;
use sq_playback::engine::caption_plan::CaptionPlanner;
use sq_playback::engine::core::ProgramEngine;
use sq_playback::engine::handle::{EngineDeps, ProgramHandle};
use sq_playback::engine::media_source::DefaultOpener;
use sq_playback::engine::types::MediaRef;
use sq_playback::engine::{CaptionPreview, LayerRasters};
use sq_render::color::clip_pipeline::CachingLutProvider;
use sq_render::compositor::LayerColorResolver;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

/// How long one frame may take to decode and compose before the export gives up.
const FRAME_TIMEOUT: Duration = Duration::from_secs(20);

/// The queue with the FFmpeg encoder and the renderer of the app.
pub fn setup() -> ExportSetup {
    let encoder = Arc::new(FfmpegExportEncoder::new());
    ExportSetup {
        queue: Arc::new(ExportQueue::with_options(
            Arc::clone(&encoder) as Arc<dyn ExportEncoding>,
            Arc::new(sq_platform::free_bytes),
            sq_export::core::preflight::ExportPreflight::RUNNING_FLOOR_BYTES,
            Duration::from_secs(2),
        )),
        make_sources: Arc::new(sources),
        frame_pixels: Some(Arc::new(frame_pixels)),
        make_stem_audio: Some(Arc::new(stem_audio)),
        stem_encoder: Some(encoder),
    }
}

/// The offline mix of one stem: its timeline already mutes the other roles, so the same mixer as the full export gives
/// the file by role.
fn stem_audio(snapshot: &ExportSnapshot, stem: &Stem, range: TimeRange) -> Result<Box<dyn AudioSource>, ExportError> {
    let sequences: HashMap<Id, Timeline> = snapshot.timelines.iter().map(|t| (t.id, t.clone())).collect();
    let paths = snapshot.media.iter().map(|m| (m.id, PathBuf::from(&m.path))).collect();
    Ok(Box::new(TimelineAudioSource::new(
        FeederMix::new(&stem.timeline, sequences, paths, sq_app_hosts::export_audio::channel_maps(&snapshot.media)),
        2,
        range,
    )))
}

/// The RGBA pixels of a frame the engine rendered (`EngineFrames` wraps them in a `MemoryFrame`).
fn frame_pixels(frame: &ExportFrame) -> Option<RgbaImage> {
    let memory = frame.storage_as::<MemoryFrame>()?;
    if frame.pixel_format == SQFramePixelFormat::Nv12 {
        return Some(crate::export_yuv::nv12_to_rgba(&memory.bytes, frame.width, frame.height));
    }
    if frame.pixel_format != SQFramePixelFormat::Rgba8 {
        return None;
    }
    let row = frame.width * 4;
    let pixels = (0..frame.height)
        .map(|y| memory.bytes.get(y * memory.bytes_per_row..y * memory.bytes_per_row + row))
        .collect::<Option<Vec<_>>>()?
        .concat();
    Some(RgbaImage { width: frame.width, height: frame.height, pixels })
}

pub(crate) fn sources(
    snapshot: &ExportSnapshot,
    id: Id,
    settings: &ExportSettings,
) -> Result<ExportSources, ExportError> {
    sources_in(snapshot, id, settings, true)
}

/// `gpu_yuv`: an 8-bit 4:2:0 delivery reads back NV12 made on the GPU; `false` keeps RGBA frames (tests that read the pixels).
fn sources_in(
    snapshot: &ExportSnapshot,
    id: Id,
    settings: &ExportSettings,
    gpu_yuv: bool,
) -> Result<ExportSources, ExportError> {
    let timeline = snapshot
        .timelines
        .iter()
        .find(|t| t.id == id)
        .ok_or_else(|| ExportError::Other("The sequence is no longer in the project.".to_string()))?;
    let range = match settings.range {
        RangeSelection::EntireSequence => TimeRange::new(Time::ZERO, timeline.duration()),
        RangeSelection::InOut(r) => r,
    };
    let video = &settings.video;
    let source = EngineFrames::new(
        snapshot,
        timeline,
        range,
        video.frame_duration,
        (video.width, video.height),
        settings.captions == sq_export::core::settings::CaptionMode::BurnIn,
        settings.applied_hdr_delivery().is_some(),
        gpu_yuv && settings.source_pixel_format() == sq_export::core::settings::ExportPixelFormat::Yuv420v,
        snapshot.use_proxies_for_export,
    )
    .inspect_err(|e| crate::applog::info(&format!("export source for {id:?} failed: {e}")))?;
    let audio = settings.audio.enabled.then(|| {
        let sequences: HashMap<Id, Timeline> = snapshot.timelines.iter().map(|t| (t.id, t.clone())).collect();
        let paths = snapshot.media.iter().map(|m| (m.id, PathBuf::from(&m.path))).collect();
        let channels = usize::try_from(settings.audio.channels).unwrap_or(2).clamp(1, 2);
        Box::new(TimelineAudioSource::new(
            FeederMix::new(timeline, sequences, paths, sq_app_hosts::export_audio::channel_maps(&snapshot.media)),
            channels,
            range,
        )) as Box<dyn AudioSource>
    });
    Ok(ExportSources::new(Box::new(source), audio))
}

/// Preview render cache, the render step (Swift `RenderCacheSegmentWriter.write`): `range` of the sequence as a ProRes 422 LT
/// .mov at the sequence size, no audio, no caption burn-in, through the same engine frames as an export. The partial file is
/// removed on failure or cancel (the encoder does that).
// shortcut: not wired into the app yet (the render cache job comes with the cache UI); tests call it. Remove the allow then.
#[allow(dead_code)]
pub fn write_cache_segment(
    snapshot: &ExportSnapshot,
    timeline: &Timeline,
    range: TimeRange,
    url: &std::path::Path,
    cancel: &sq_export::core::error::CancelToken,
    progress: &mut dyn FnMut(f64),
) -> Result<(), ExportError> {
    let settings = sq_export::core::render_cache::segment_settings(&timeline.format, range);
    let mut src = sources(snapshot, timeline.id, &settings)?;
    FfmpegExportEncoder::new().export(src.video.as_mut(), None, &settings, url, cancel, progress)?;
    Ok(())
}

/// One picture of sequence `id` at `at`, rendered by the export's engine (all effects, text and captions, like the
/// monitor and an export). `width` scales it (the height follows the sequence); the Edit API's capture and frame calls.
pub(crate) fn render_still(
    snapshot: &ExportSnapshot,
    id: Id,
    at: Time,
    width: Option<usize>,
) -> Result<RgbaImage, String> {
    let timeline = snapshot.timelines.iter().find(|t| t.id == id).ok_or("The sequence is no longer in the project.")?;
    let preset = sq_export::core::preset::ExportPreset::default_preset(Some(&timeline.format), None);
    let mut settings = preset.settings_matching(Some(&timeline.format));
    if let Some(w) = width.filter(|w| *w > 0) {
        let (vw, vh) = (settings.video.width.max(1), settings.video.height.max(1));
        let h = (w as i64 * vh / vw).max(1);
        (settings.video.width, settings.video.height) = (w as i64, h);
    }
    settings.range = RangeSelection::InOut(TimeRange::new(at, timeline.format.frame_duration));
    settings.captions = sq_export::core::settings::CaptionMode::BurnIn;
    let mut source = sources_in(snapshot, id, &settings, false).map_err(|e| e.to_string())?;
    let frame = source.video.frame(0).map_err(|e| e.to_string())?;
    frame_pixels(&frame).ok_or_else(|| "the frame has no 8-bit picture (HDR sequence?)".to_string())
}

/// The frames of one sequence, rendered by a paused engine of their own.
struct EngineFrames {
    handle: ProgramHandle,
    gpu: Arc<Gpu>,
    start: Time,
    frame_duration: Time,
    count: usize,
    size: (usize, usize),
    /// HDR delivery: frames are the half-float working composite (`Shown::linear`), not the 8-bit Rec.709 picture.
    hdr: bool,
    /// `SQ_EXPORT_TRACE=1`: summed ms of the render side (seek+compose wait, GPU readback, CPU resample).
    trace: std::cell::Cell<[f64; 3]>,
    /// RGB -> NV12 on the GPU (`export_yuv.rs`) for an 8-bit 4:2:0 delivery; `None` keeps the RGBA frames and the CPU swscale.
    yuv: Option<crate::export_yuv::YuvConverter>,
    /// The frame submitted ahead (index, readback in flight): two frames are in flight while the encoder works on the first.
    pending: Option<(usize, Pending)>,
    /// The index the next sequential call asks for; a jump (the export dialog's preview) does not prefetch.
    expected: usize,
}

/// Whether an export decodes in software: the VA-API copy of a decoded 4K picture to memory ran 20 ms (about 55 pictures/s, three copy
/// threads did not scale it), the software decoder 8 ms on 4 threads (2x the export speed, 8 cores+). Linux only: the Windows hardware decoder
/// hands out textures (no copy) and was not measured; the Mac decodes through VideoToolbox.
fn export_prefers_software() -> bool {
    cfg!(target_os = "linux")
        && std::env::var_os("SQ_EXPORT_HW_DECODE").is_none_or(|v| v != "1")
        && std::thread::available_parallelism().is_ok_and(|n| n.get() >= 8)
}

/// A frame whose readback was submitted and not yet waited for.
enum Pending {
    Gpu {
        ticket: sq_gpu::readback::ReadbackTicket,
        submitted: wgpu::SubmissionIndex,
        w: usize,
        h: usize,
        nv12: bool,
    },
    /// A gap on every video track: black at the export size.
    Black,
}

impl Drop for EngineFrames {
    fn drop(&mut self) {
        if std::env::var_os("SQ_EXPORT_TRACE").is_some() {
            let [w, r, s] = self.trace.get();
            eprintln!(
                "export-trace render side: {} frames, seek+compose {w:.0} ms, readback {r:.0} ms, resample {s:.0} ms",
                self.count
            );
            eprintln!("export-trace stages: {:?}", self.handle.query(|e| e.stats().report()).unwrap_or_default());
            // The engine's own timers (a paused engine books no rows): decode is summed over the lane threads, which overlap the render thread.
            let (dec, comp, n, gw, ph, idle, up) = sq_playback::engine::frame_trace::unbooked();
            let wanted = sq_playback::engine::frame_trace::wanted_pictures();
            for (m, n, ms) in sq_playback::engine::frame_trace::decode_by_media().iter().take(8) {
                eprintln!("export-trace lane media {m}: {n} pictures, {ms:.0} ms");
            }
            sq_playback::engine::frame_trace::set_enabled(false);
            eprintln!("export-trace pictures wanted by the composites: {wanted}");
            eprintln!(
                "export-trace engine: decode {dec:.0} ms (lanes), compose {comp:.0} ms in {n} composites, gpu_wait {gw:.0} ms, phases layers/draw/submit/poll {:.0}/{:.0}/{:.0}/{:.0}, idle {idle:.0} ms, upload {up:.0} ms",
                ph[0], ph[1], ph[2], ph[3]
            );
        }
    }
}

impl EngineFrames {
    #[allow(clippy::too_many_arguments)] // shortcut: seven plain inputs of one job, group them when an eighth comes
    fn new(
        snapshot: &ExportSnapshot,
        timeline: &Timeline,
        range: TimeRange,
        frame_duration: Time,
        size: (i64, i64),
        burn_captions: bool,
        hdr: bool,
        yuv420: bool,
        use_proxies: bool,
    ) -> Result<EngineFrames, ExportError> {
        let gpu = Gpu::new().map_err(|e| ExportError::Other(format!("No graphics device for the export: {e}")))?;
        crate::surface::limit_pool(&gpu);
        let fields: BTreeMap<Id, FieldOrder> = snapshot
            .media
            .iter()
            .filter_map(|m| Some((m.id, m.info.as_ref()?.video.as_ref()?.deinterlace_field_order()?)))
            .collect();
        let opener: Arc<dyn MediaOpener> = Arc::new(
            DefaultOpener::new(Some(Arc::clone(&gpu)))
                .with_software_ffmpeg(export_prefers_software())
                .with_deinterlace(Arc::new(move |id| fields.get(&id).copied())),
        );
        let opener = crate::proxy::export_opener(opener, use_proxies);
        let clock: Arc<dyn PlaybackClock> = Arc::new(HostClock::new());
        let mut deps = EngineDeps::new(opener, clock);
        deps.gpu = Some(Arc::clone(&gpu));
        // The same layers as the Program monitor: titles, shapes, Lottie and captions, and the clip grades.
        deps.rasters =
            Some(Arc::new(LayerRasters::with_lottie(sq_lottie::lottie_skia::LottieRendererSkia::renderer())));
        // Captions are burned in only when the export asks for it (Swift `CaptionBurnIn`); the monitor draws them the same way.
        // Gyroflow Stabilizers: each clip waits for its analysis, so the file is never written unstabilized.
        deps.gyro = Some(sq_app_hosts::gyroflow_host::hook(true));
        deps.planner = burn_captions.then(|| Arc::new(CaptionPreview) as Arc<dyn CaptionPlanner>);
        let infos: HashMap<Id, sq_core_model::MediaInfo> =
            snapshot.media.iter().filter_map(|m| Some((m.id, m.info.clone()?))).collect();
        let paths: HashMap<Id, String> = snapshot.media.iter().map(|m| (m.id, m.path.clone())).collect();
        let embedded = Box::new(move |id| {
            EmbeddedMeta::lut_in_clip(std::path::Path::new(paths.get(&id)?)).ok().flatten().map(|l| l.data)
        });
        let luts = CachingLutProvider::new(None, embedded, None);
        deps.color = Some(Arc::new(LayerColorResolver::with_hdr_output(
            Some(Arc::new(luts)),
            Arc::new(move |id| infos.get(&id).cloned()),
            hdr,
        )));
        if std::env::var_os("SQ_EXPORT_TRACE").is_some() {
            sq_playback::engine::frame_trace::set_enabled(true);
        }
        // Software decoding beats the GPU decoder for an export on a machine with cores to spare (`SQ_EXPORT_HW_DECODE=1` keeps it).
        let handle = ProgramEngine::spawn(deps);
        let used: BTreeSet<Id> =
            snapshot.timelines.iter().flat_map(|t| &t.tracks).flat_map(|tr| tr.clips()).map(|c| c.media).collect();
        let refs = snapshot
            .media
            .iter()
            .filter(|m| used.contains(&m.id))
            .map(|m| MediaRef { id: m.id, path: m.path.clone() })
            .collect();
        handle.set_media(refs);
        // The preset's size is made by the compositor's Present pass (bilinear in linear light on the GPU), so the frame is
        // read back once at its final size (`SQ_EXPORT_CPU_SCALE=1` keeps the old CPU path, for A/B runs). The half-float HDR picture still scales on the CPU (`export_scale.rs`).
        let target = (u32::try_from(size.0).unwrap_or(0), u32::try_from(size.1).unwrap_or(0));
        if !hdr
            && std::env::var_os("SQ_EXPORT_CPU_SCALE").is_none()
            && target.0 > 0
            && target.1 > 0
            && target != (timeline.format.width as u32, timeline.format.height as u32)
        {
            handle.set_output_size(Some(target));
        }
        let sequences: HashMap<Id, Timeline> = snapshot.timelines.iter().map(|t| (t.id, t.clone())).collect();
        handle.set_timeline(timeline.clone(), sequences);
        let (w, h) = (usize::try_from(size.0).unwrap_or(0), usize::try_from(size.1).unwrap_or(0));
        let yuv = (yuv420 && !hdr && std::env::var_os("SQ_EXPORT_CPU_YUV").is_none())
            .then(|| crate::export_yuv::YuvConverter::new(&gpu))
            .flatten();
        Ok(EngineFrames {
            handle,
            gpu,
            start: range.start,
            frame_duration,
            count: export_frame_count(range, frame_duration),
            size: (w, h),
            hdr,
            trace: std::cell::Cell::new([0.0; 3]),
            yuv,
            pending: None,
            expected: 0,
        })
    }

    fn bytes_per_pixel(&self) -> usize {
        if self.hdr { 8 } else { 4 }
    }

    /// The composite at `t` (RGBA8 Rec.709 code values, or half-float linear light for an HDR delivery, 8 bytes a pixel),
    /// once the engine shows the exact pictures of it; its readback is submitted, not waited for.
    fn submit(&self, t: Time) -> Result<Pending, ExportError> {
        let t_start = Instant::now();
        self.handle.seek(t);
        self.handle.sync();
        let end = Instant::now() + FRAME_TIMEOUT;
        loop {
            let at = self.handle.status().position;
            if let Some(shown) = self.handle.latest_shown().filter(|s| s.exact && s.position == at)
                && let Some(frame) = shown.frame.as_ref().and_then(|f| f.planes.first().map(|p| (p, f.size)))
            {
                let (w, h) = (frame.1.0 as usize, frame.1.1 as usize);
                // The working canvas is the compositor's one, so it holds this very composite like `frame` does.
                let texture = if self.hdr { shown.linear.as_ref().unwrap_or(frame.0) } else { frame.0 };
                let t_read = Instant::now();
                let pending = self.start_readback(texture, w, h)?;
                let mut tr = self.trace.get();
                tr[0] += (t_read - t_start).as_secs_f64() * 1e3;
                tr[1] += t_read.elapsed().as_secs_f64() * 1e3;
                self.trace.set(tr);
                return Ok(pending);
            }
            // A gap on every video track: the engine publishes an exact shown frame with no picture; the export writes black.
            if let Some(shown) = self.handle.latest_shown()
                && shown.exact
                && shown.position == at
                && shown.frame.is_none()
                && self.size.0 > 0
                && self.size.1 > 0
            {
                return Ok(Pending::Black);
            }
            if Instant::now() > end {
                let why = self.handle.status().last_error.unwrap_or_else(|| "a frame did not render in time".into());
                return Err(ExportError::Other(why));
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    /// Records and submits the readback of `texture`: the planes of NV12 when the GPU converts, else the RGBA texels.
    fn start_readback(&self, texture: &sq_gpu::frames::GpuTexture, w: usize, h: usize) -> Result<Pending, ExportError> {
        let other = |e: sq_gpu::gpu::GpuError| ExportError::Other(e.to_string());
        let mut commands = self.gpu.commands();
        let converted = self.yuv.as_ref().filter(|_| (w, h) == self.size).and_then(|c| c.convert(&self.gpu, texture));
        let (ticket, nv12) = match converted {
            Some((buffer, len)) => (commands.read_buffer(&buffer, len), true),
            None => (commands.read_texture(texture).map_err(other)?, false),
        };
        let submitted = self.gpu.submit(commands);
        Ok(Pending::Gpu { ticket, submitted, w, h, nv12 })
    }

    /// Waits for a submitted readback: (bytes, width, height, bytes are NV12).
    fn finish(&self, pending: Pending) -> Result<(Vec<u8>, usize, usize, bool), ExportError> {
        match pending {
            Pending::Black => Ok((black_frame(self.size, self.hdr), self.size.0, self.size.1, false)),
            Pending::Gpu { ticket, submitted, w, h, nv12 } => {
                let t_wait = Instant::now();
                let pixels = ticket.wait_after(&self.gpu, &submitted).map_err(|e| ExportError::Other(e.to_string()))?;
                let mut tr = self.trace.get();
                tr[1] += t_wait.elapsed().as_secs_f64() * 1e3;
                self.trace.set(tr);
                let expect = if nv12 { w * h * 3 / 2 } else { w * h * self.bytes_per_pixel() };
                if pixels.len() != expect {
                    return Err(ExportError::Other(format!(
                        "a frame read back {} bytes, expected {expect}",
                        pixels.len()
                    )));
                }
                Ok((pixels, w, h, nv12))
            }
        }
    }
}

/// An opaque black picture of `size`: RGBA8, or half-float RGBA (alpha 1.0 = 0x3C00) for an HDR delivery.
fn black_frame((w, h): (usize, usize), hdr: bool) -> Vec<u8> {
    if hdr {
        let pixel = [0, 0, 0, 0, 0, 0, 0x00, 0x3C];
        return pixel.iter().copied().cycle().take(w * h * 8).collect();
    }
    [0, 0, 0, 255].iter().copied().cycle().take(w * h * 4).collect()
}

impl FrameSource for EngineFrames {
    fn frame_count(&self) -> usize {
        self.count
    }

    fn frame_duration(&self) -> Time {
        self.frame_duration
    }

    fn frame(&mut self, index: usize) -> Result<ExportFrame, ExportError> {
        let t = self.start + self.frame_duration * index as i64;
        let at = |i: usize| self.start + self.frame_duration * i as i64;
        let pending = match self.pending.take() {
            Some((i, p)) if i == index => p,
            _ => self.submit(t).inspect_err(|e| {
                crate::applog::info(&format!("export frame {index} at {t:?} failed: {e}"));
            })?,
        };
        // Submit the next frame before waiting for this one, so the readback wait hides behind its compose (same frames, same order).
        // A failed look-ahead is dropped: the next call composes that frame again and reports the error itself.
        if index == self.expected && index + 1 < self.count {
            self.pending = self.submit(at(index + 1)).ok().map(|p| (index + 1, p));
        }
        self.expected = index + 1;
        let (pixels, w, h, nv12) = self.finish(pending).inspect_err(|e| {
            crate::applog::info(&format!("export frame {index} at {t:?} failed: {e}"));
        })?;
        if nv12 {
            let storage = Arc::new(MemoryFrame { bytes: pixels, bytes_per_row: w });
            return Ok(SQFrame::new(w, h, SQFramePixelFormat::Nv12, SQFrameColorSpace::Rec709, t, storage));
        }
        let (tw, th) = if self.size.0 == 0 || self.size.1 == 0 { (w, h) } else { self.size };
        let bpp = self.bytes_per_pixel();
        let t_scale = Instant::now();
        let bytes =
            if (w, h) == (tw, th) { pixels } else { crate::export_scale::resample(&pixels, bpp, (w, h), (tw, th)) };
        let mut tr = self.trace.get();
        tr[2] += t_scale.elapsed().as_secs_f64() * 1e3;
        self.trace.set(tr);
        let storage = Arc::new(MemoryFrame { bytes, bytes_per_row: tw * bpp });
        let (format, space) = if self.hdr {
            (SQFramePixelFormat::Rgba16f, SQFrameColorSpace::LinearRec709)
        } else {
            (SQFramePixelFormat::Rgba8, SQFrameColorSpace::Rec709)
        };
        Ok(SQFrame::new(tw, th, format, space, t, storage))
    }
}

#[cfg(test)]
pub(crate) mod tests {
    #[test]
    fn a_gap_frame_is_opaque_black_in_both_depths() {
        assert_eq!(super::black_frame((2, 1), false), vec![0, 0, 0, 255, 0, 0, 0, 255]);
        let hdr = super::black_frame((1, 2), true);
        assert_eq!(hdr.len(), 16);
        assert_eq!(&hdr[..8], &[0, 0, 0, 0, 0, 0, 0x00, 0x3C]);
    }

    use super::*;

    fn sources_rgba(
        snapshot: &ExportSnapshot,
        id: Id,
        settings: &ExportSettings,
    ) -> Result<ExportSources, ExportError> {
        sources_in(snapshot, id, settings, false)
    }
    use sq_core_model::{Clip, MediaFingerprint, SequenceFormat, Track, TrackKind};
    use sq_export::core::preset::ExportPreset;
    use sq_export::core::queue::{ExportJob, ExportJobState};
    use sq_export::core::settings::VideoCodec;

    #[test]
    fn the_preview_reads_the_rows_of_a_padded_frame() {
        // Two pixels per row, a 12-byte stride: the padding must not reach the picture.
        let bytes: Vec<u8> = (0..24).collect();
        let storage = Arc::new(MemoryFrame { bytes, bytes_per_row: 12 });
        let frame = SQFrame::new(2, 2, SQFramePixelFormat::Rgba8, SQFrameColorSpace::Rec709, Time::ZERO, storage);
        let image = frame_pixels(&frame).expect("a picture");
        assert_eq!(image.pixels, [0, 1, 2, 3, 4, 5, 6, 7, 12, 13, 14, 15, 16, 17, 18, 19]);
    }
    use std::path::{Path, PathBuf};

    /// A 1 s test clip from the `ffmpeg` command line, or `None` (the test then skips).
    pub(crate) fn ffmpeg_tool() -> Option<PathBuf> {
        if !sq_media_ffmpeg::shim::AVAILABLE {
            return None;
        }
        let bundled = std::env::var_os("SQ_FFMPEG").map(|r| PathBuf::from(r).join("bin").join("ffmpeg"));
        let tool =
            bundled.filter(|p| p.exists() || p.with_extension("exe").exists()).unwrap_or_else(|| "ffmpeg".into());
        std::process::Command::new(&tool).arg("-version").output().ok()?.status.success().then_some(tool)
    }

    pub(crate) fn make_clip(tool: &Path, dir: &Path) -> Option<PathBuf> {
        let path = dir.join("clip.mp4");
        let made = std::process::Command::new(tool)
            .args(["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=25:duration=1"])
            .args(["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1"])
            // mpeg4 and aac are built into every FFmpeg, the LGPL build of the PC has no libx264.
            .args(["-c:v", "mpeg4", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"])
            .arg(&path)
            .status()
            .ok()?;
        (made.success() && path.exists()).then_some(path)
    }

    /// A one second sequence of the test clip, and the clip's media.
    pub(crate) fn tiny_sequence(tool: &Path, dir: &Path) -> (Timeline, sq_core_model::MediaRef) {
        let clip_path = make_clip(tool, dir).expect("a test clip");
        let media = Id::from_u128(100);
        let reference =
            sq_core_model::MediaRef::new(media, "clip", &clip_path.to_string_lossy(), MediaFingerprint::new(1));
        let mut track = Track::new(Id::from_u128(900), TrackKind::Video);
        let source = TimeRange::new(Time::ZERO, Time::seconds(1));
        track.set_clips(vec![Clip::new(Id::from_u128(10), "c", media, TrackKind::Video, source, Time::ZERO)]);
        let mut sound = Track::new(Id::from_u128(901), TrackKind::Audio);
        sound.set_clips(vec![Clip::new(Id::from_u128(11), "a", media, TrackKind::Audio, source, Time::ZERO)]);
        let mut format = SequenceFormat::new(Time::new(1, 25));
        (format.width, format.height) = (320, 180);
        let timeline = Timeline::new(Id::from_u128(1), "tiny", format, vec![track, sound]);

        (timeline, reference)
    }

    #[test]
    fn render_still_gives_one_scaled_non_black_picture_of_a_sequence() {
        let dir = std::env::temp_dir().join(format!("sq-still-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let Some(tool) = ffmpeg_tool() else {
            eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
            return;
        };
        if Gpu::new().is_err() {
            eprintln!("skipped: no graphics device");
            return;
        }
        let (timeline, reference) = tiny_sequence(&tool, &dir);
        let snapshot = ExportSnapshot {
            timelines: vec![timeline].into(),
            media: vec![reference].into(),
            use_proxies_for_export: false,
        };
        let id = Id::from_u128(1);
        let full = render_still(&snapshot, id, Time::new(1, 2), None).expect("a frame");
        assert_eq!((full.width, full.height), (320, 180));
        assert!(full.pixels.chunks(4).any(|p| p[0] > 40 || p[1] > 40 || p[2] > 40), "the frame is black");
        let small = render_still(&snapshot, id, Time::new(1, 2), Some(160)).expect("a small frame");
        assert_eq!((small.width, small.height), (160, 90));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_tiny_project_exports_to_a_file_that_decodes() {
        let dir = std::env::temp_dir().join(format!("sq-export-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let Some(tool) = ffmpeg_tool() else {
            eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
            return;
        };
        if Gpu::new().is_err() {
            eprintln!("skipped: no graphics device");
            return;
        }
        let (timeline, reference) = tiny_sequence(&tool, &dir);
        let snapshot = ExportSnapshot {
            timelines: vec![timeline].into(),
            media: vec![reference].into(),
            use_proxies_for_export: false,
        };

        let mut settings = ExportPreset::all()
            .into_iter()
            .map(|p| p.settings())
            .find(|s| s.video.codec == VideoCodec::H264 && s.audio_only.is_none() && s.frame_output.is_none())
            .expect("an H.264 preset");
        (settings.video.width, settings.video.height) = (320, 180);
        settings.video.frame_duration = Time::new(1, 25);
        settings.video.hardware_encoding = false;

        let queue = ExportQueue::new(Arc::new(FfmpegExportEncoder::new()));
        let for_job = settings.clone();
        let job = ExportJob::new(
            Id::from_u128(7),
            "tiny",
            settings,
            dir.clone(),
            Arc::new(move || sources_rgba(&snapshot, Id::from_u128(1), &for_job)),
        );
        let id = queue.enqueue(job);
        queue.run_all();
        let status = queue.status(id).expect("the job is known");
        let ExportJobState::Done(file) = status.state else { panic!("export ended as {:?}", status.state) };
        assert!(std::fs::metadata(&file).is_ok_and(|m| m.len() > 1000), "no real file at {}", file.display());
        let decoded = std::process::Command::new(&tool)
            .args(["-v", "error", "-i"])
            .arg(&file)
            .args(["-f", "null", "-"])
            .output()
            .expect("run ffmpeg");
        assert!(
            decoded.status.success() && decoded.stderr.is_empty(),
            "the file does not decode: {:?}",
            decoded.stderr
        );
        assert_audible(&tool, &file);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The file has an audio stream of about one second whose samples are not silent.
    fn assert_audible(tool: &Path, file: &Path) {
        let out = std::process::Command::new(tool)
            .args(["-v", "error", "-i"])
            .arg(file)
            .args(["-map", "0:a:0", "-f", "f32le", "-ac", "1", "-ar", "48000", "-"])
            .output()
            .expect("run ffmpeg");
        assert!(out.status.success(), "no audio stream: {:?}", String::from_utf8_lossy(&out.stderr));
        let samples: Vec<f32> = out.stdout.as_chunks::<4>().0.iter().map(|b| f32::from_le_bytes(*b)).collect();
        let seconds = samples.len() as f64 / 48_000.0;
        assert!((0.9..1.15).contains(&seconds), "audio lasts {seconds} s");
        let peak = samples.iter().fold(0.0f32, |m, s| m.max(s.abs()));
        assert!(peak > 0.05, "the audio is silent (peak {peak})");
    }

    #[test]
    fn file_export_writes_the_file_from_the_sheet() {
        use sq_draw::{InputEvent, InputKey, InputModifiers};
        use sq_draw_shell::ShellFlow;
        let dir = std::env::temp_dir().join(format!("sq-export-ui-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let (Some(tool), true) = (ffmpeg_tool(), Gpu::new().is_ok()) else {
            eprintln!("skipped: no ffmpeg or no graphics device");
            return;
        };
        let (timeline, reference) = tiny_sequence(&tool, &dir);
        let project = sq_core_model::Project::new(Id::from_u128(2), "p", vec![reference], vec![timeline]);
        let file = dir.join("tiny.sqproj");
        let mut session =
            sq_editor_session::EditorSession::new(project, sq_editor_session::SessionDeps::headless(dir.clone()));
        session.save_as(&file).expect("save the test project");

        let (app, _picture) =
            crate::headless::build_in(&dir.join("support"), 1280, 800, 1.0, Some(&file), Path::new("/nonexistent"));
        let shot = |app: &sq_app_shell::Headless| app.with(|a| format!("{:?}", a.frame(1280, 800))).unwrap_or_default();
        let before = shot(&app);
        app.with(|a| a.emit_flow(ShellFlow::ShowExport));
        app.turn();
        assert_ne!(shot(&app), before, "File > Export shows no sheet");
        app.input(&InputEvent::KeyDown { key: InputKey::Enter, modifiers: InputModifiers::default() });
        let end = Instant::now() + Duration::from_secs(60);
        // The file exists while it is written; it is done once it can be probed.
        let found = || {
            let made = std::fs::read_dir(dir.join("Exports"))
                .ok()?
                .flatten()
                .find(|e| e.path().extension().is_some_and(|x| x == "mp4"))?;
            let probe = std::process::Command::new(&tool)
                .args(["-v", "error", "-i"])
                .arg(made.path())
                .args(["-f", "null", "-"])
                .output()
                .ok()?;
            (probe.status.success() && probe.stderr.is_empty()).then_some(made)
        };
        while found().is_none() && Instant::now() < end {
            std::thread::sleep(Duration::from_millis(50));
            app.turn();
        }
        let out = found().map(|e| e.path());
        let _ = out.as_ref().map(|p| eprintln!("exported {}", p.display()));
        assert!(out.as_ref().is_some_and(|p| std::fs::metadata(p).is_ok_and(|m| m.len() > 1000)), "no file written");
        let _ = std::fs::remove_dir_all(&dir);
    }

    const W_PX: usize = 320;
    const H_PX: usize = 180;

    /// Decoded RGB24 of frame `n` of `file` by the ffmpeg command line (limited range BT.709 to full range RGB).
    fn decode_frame(tool: &Path, file: &Path, n: usize) -> Vec<u8> {
        let out = std::process::Command::new(tool)
            .args(["-v", "error", "-i"])
            .arg(file)
            .args([
                "-vf",
                &format!(
                    "select=eq(n\\,{n}),scale=out_color_matrix=bt709:out_range=full:flags=accurate_rnd+full_chroma_int"
                ),
                "-frames:v",
                "1",
            ])
            .args(["-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
            .output()
            .expect("run ffmpeg");
        out.stdout
    }

    /// Frame side data (mastering display, content light level) of the first video frame.
    fn probe_side_data(file: &Path) -> String {
        let out = std::process::Command::new("ffprobe")
            .args(["-v", "error", "-select_streams", "v:0", "-read_intervals", "%+#1", "-show_frames", "-show_entries"])
            .arg("frame=side_data_list")
            .args(["-of", "default=nw=1"])
            .arg(file)
            .output()
            .expect("run ffprobe");
        let mut text = String::from_utf8_lossy(&out.stdout).to_string();
        // Some builds list the stream-level side data instead of the frame's.
        let st = std::process::Command::new("ffprobe")
            .args([
                "-v",
                "error",
                "-select_streams",
                "v:0",
                "-show_entries",
                "stream=side_data_list",
                "-of",
                "default=nw=1",
            ])
            .arg(file)
            .output()
            .expect("run ffprobe");
        text.push_str(&String::from_utf8_lossy(&st.stdout));
        text
    }

    fn probe(file: &Path, entries: &str) -> String {
        let out = std::process::Command::new("ffprobe")
            .args(["-v", "error", "-show_entries", entries, "-of", "default=nw=1"])
            .arg(file)
            .output()
            .expect("run ffprobe");
        String::from_utf8_lossy(&out.stdout).to_string()
    }

    /// Real export of a graded clip under a title to H.264 and HEVC (VideoToolbox first): the file's duration, rate, size and
    /// color tags, its audio, and one decoded frame against the Program render of the same time.
    #[test]
    fn a_titled_and_graded_sequence_exports_like_the_program_renders_it() {
        use sq_core_color::ClipGradeExt;
        use sq_core_model::{ClipColor, TrackKind as Kind};
        use sq_export::core::error::CancelToken;
        use sq_text::text_generator::TextGenerator;
        use sq_text::text_style::TextStyle;
        use sq_text::text_template::TextTemplate;
        let dir = std::env::temp_dir().join(format!("sq-export-real-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let (Some(tool), true) = (ffmpeg_tool(), Gpu::new().is_ok()) else {
            eprintln!("skipped: no ffmpeg or no graphics device");
            return;
        };
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        sq_text::portable_font_match::set_fonts_root(&root);
        let (mut timeline, reference) = tiny_sequence(&tool, &dir);
        let mut color = ClipColor::default();
        color.edit_effects(|fx| fx[0].basic.exposure = 0.6);
        let mut graded = timeline.tracks[0].clips()[0].clone();
        graded.set_color(&color, None, &mut sq_core_time::SequentialIds::default());
        timeline.tracks[0].set_clips(vec![graded]);
        let mut title = Clip::new(
            Id::from_u128(12),
            "t",
            Id::from_u128(12),
            Kind::Video,
            TimeRange::new(Time::ZERO, Time::seconds(1)),
            Time::ZERO,
        );
        let style = TextStyle { size: 40.0, ..TextStyle::default() };
        title.generator = TextGenerator::make_ref(&TextTemplate::new("Title", "HELLO", style), None).ok();
        let mut titles = Track::new(Id::from_u128(902), Kind::Video);
        titles.set_clips(vec![title]);
        timeline.tracks.push(titles);
        let snapshot = ExportSnapshot {
            timelines: vec![timeline.clone()].into(),
            media: vec![reference].into(),
            use_proxies_for_export: false,
        };
        let video = |hardware: bool, hevc: bool| {
            let mut s = ExportPreset::all()
                .into_iter()
                .map(|p| p.settings())
                .find(|s| s.video.codec == VideoCodec::H264 && s.audio_only.is_none() && s.frame_output.is_none())
                .expect("an H.264 preset");
            (s.video.width, s.video.height) = (320, 180);
            s.video.frame_duration = Time::new(1, 25);
            s.video.hardware_encoding = hardware;
            if hevc {
                s.video.codec = VideoCodec::Hevc;
            }
            s
        };
        let reference_frame = {
            let s = video(false, false);
            let mut frames = sources_rgba(&snapshot, timeline.id, &s).expect("sources");
            let f = frames.video.frame(10).expect("program frame");
            let m = f.storage_as::<MemoryFrame>().expect("pixels").bytes.clone();
            m.chunks(4).flat_map(|p| [p[0], p[1], p[2]]).collect::<Vec<u8>>()
        };
        for (name, hardware, hevc) in [("h264-vt", true, false), ("hevc-vt", true, true), ("h264-sw", false, false)] {
            let s = video(hardware, hevc);
            let file = dir.join(format!("{name}.mp4"));
            let encoder = FfmpegExportEncoder::new();
            let mut src = sources_rgba(&snapshot, timeline.id, &s).expect("sources");
            let audio = src.audio.as_mut().map(|a| &mut **a as &mut dyn AudioSource);
            let done = encoder.export(src.video.as_mut(), audio, &s, &file, &CancelToken::new(), &mut |_| {});
            if let Err(e) = done {
                eprintln!("{name}: not written ({e})");
                continue;
            }
            let v = probe(
                &file,
                "stream=codec_name,width,height,avg_frame_rate,nb_frames,color_range,color_space,color_transfer,color_primaries,duration",
            );
            eprintln!("{name} [{}]:\n{v}", encoder.last_video_encoder());
            assert!(v.contains("width=320") && v.contains("height=180") && v.contains("avg_frame_rate=25/1"), "{v}");
            assert!(
                v.contains("color_range=tv")
                    && v.contains("color_space=bt709")
                    && v.contains("color_transfer=bt709")
                    && v.contains("color_primaries=bt709"),
                "{v}"
            );
            assert!(v.contains("nb_frames=25"), "{v}");
            assert_audible(&tool, &file);
            let got = decode_frame(&tool, &file, 10);
            assert_eq!(got.len(), reference_frame.len(), "decoded frame size");
            let diffs: Vec<u32> = got.iter().zip(&reference_frame).map(|(a, b)| a.abs_diff(*b) as u32).collect();
            if let Some(d) = std::env::var_os("SQ_DUMP") {
                let d = PathBuf::from(d);
                let ppm = |b: &[u8]| [b"P6 320 180 255\n".as_slice(), b].concat();
                let _ = std::fs::write(d.join(format!("{name}-file.ppm")), ppm(&got));
                let _ = std::fs::write(d.join("program.ppm"), ppm(&reference_frame));
            }
            // Luma alone, and the mean color of 2x2 blocks (4:2:0 averages chroma over such blocks).
            let luma = |b: &[u8]| -> Vec<f64> {
                b.chunks(3)
                    .map(|p| 0.2126 * f64::from(p[0]) + 0.7152 * f64::from(p[1]) + 0.0722 * f64::from(p[2]))
                    .collect()
            };
            let (la, lb) = (luma(&got), luma(&reference_frame));
            let luma_mean = la.iter().zip(&lb).map(|(a, b)| (a - b).abs()).sum::<f64>() / la.len() as f64;
            let block = |b: &[u8]| -> Vec<f64> {
                let mut out = Vec::new();
                for by in (0..H_PX).step_by(2) {
                    for bx in (0..W_PX).step_by(2) {
                        for c in 0..3 {
                            let at = |dx: usize, dy: usize| f64::from(b[((by + dy) * W_PX + bx + dx) * 3 + c]);
                            out.push((at(0, 0) + at(1, 0) + at(0, 1) + at(1, 1)) / 4.0);
                        }
                    }
                }
                out
            };
            let (ba, bb) = (block(&got), block(&reference_frame));
            let block_mean = ba.iter().zip(&bb).map(|(a, b)| (a - b).abs()).sum::<f64>() / ba.len() as f64;
            let luma_bias = la.iter().zip(&lb).map(|(a, b)| a - b).sum::<f64>() / la.len() as f64;
            eprintln!(
                "{name}: luma-only mean {luma_mean:.2} (bias {luma_bias:+.2}), 2x2-block-averaged mean {block_mean:.2}"
            );
            let mean = diffs.iter().sum::<u32>() as f64 / diffs.len() as f64;
            let max = diffs.iter().max().copied().unwrap_or(0);
            eprintln!("{name}: frame 10 against the program render: mean {mean:.2}, max {max} of 255");
            // Like with like: a 4:2:0 file keeps luma per pixel and color per 2x2 block, so per-pixel RGB also counts the
            // chroma lost at the title's hard edges (max ~130, mean 2.75 on the Mac, 3.21 on the Windows hardware encoder).
            // The decode above is exact (accurate_rnd, full_chroma_int): swscale's default yuv to rgb step alone added a -1.3
            // luma bias on Windows (the encoders are exact, see `exported_patches_match_the_rec709_limited_range_matrix`).
            // Measured with it: Windows (AMD AMF) luma 0.46 (bias -0.03), blocks 2.29; HEVC when AMF cannot start and the
            // Media Foundation encoder takes over: luma 0.88, blocks 2.64 (HEVC spreads chroma wider than H.264).
            assert!(luma_mean <= 1.0, "{name}: luma difference {luma_mean}");
            // Mac libx264 measures 2.64; Windows Media Foundation (no AMD encoder) measures up to 2.7.
            assert!(block_mean <= 2.8, "{name}: 2x2 block difference {block_mean}");
            assert!(mean <= 4.0, "{name}: per-pixel RGB difference {mean}");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A camera file with four mono tracks exports the channels its Audio Channels map names (as playback plays them).
    #[test]
    fn the_export_mix_follows_the_audio_channel_map_of_a_multi_track_file() {
        use sq_export::core::timeline_audio::MixFeed;
        let dir = std::env::temp_dir().join(format!("sq-export-map-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let Some(tool) = ffmpeg_tool() else {
            eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
            return;
        };
        let src = dir.join("four-mono.mov");
        let mut cmd = std::process::Command::new(&tool);
        cmd.args(["-v", "error", "-y"]);
        for level in ["0.1", "0.2", "0.3", "0.4"] {
            cmd.args(["-f", "lavfi", "-i", &format!("aevalsrc={level}:s=48000:d=1")]);
        }
        cmd.args(["-map", "0", "-map", "1", "-map", "2", "-map", "3", "-c:a", "pcm_s16le"]).arg(&src);
        assert!(cmd.output().is_ok_and(|o| o.status.success()), "ffmpeg wrote no four-track file");
        let media = Id::from_u128(100);
        let mut sound = Track::new(Id::from_u128(901), TrackKind::Audio);
        let range = TimeRange::new(Time::ZERO, Time::seconds(1));
        sound.set_clips(vec![Clip::new(Id::from_u128(11), "a", media, TrackKind::Audio, range, Time::ZERO)]);
        let timeline = Timeline::new(Id::from_u128(1), "t", SequenceFormat::new(Time::new(1, 25)), vec![sound]);
        let mean = |maps: HashMap<Id, sq_core_model::AudioChannelMap>| {
            let paths = [(media, src.clone())].into_iter().collect();
            let mut mix = FeederMix::new(&timeline, HashMap::new(), paths, maps);
            mix.seek(0);
            mix.prime();
            mix.fill(8);
            let (mut l, mut r) = (vec![0f32; 4000], vec![0f32; 4000]);
            mix.pop(&mut l, &mut r);
            (l.iter().sum::<f32>() / 4000.0, r.iter().sum::<f32>() / 4000.0)
        };
        let map = sq_core_model::AudioChannelMap::stereo(1, 3).unwrap();
        let (l, r) = mean([(media, map)].into_iter().collect());
        eprintln!("mapped export mix: left {l:.3}, right {r:.3}");
        // Tracks 2 and 4 (0.2 and 0.4), each copied to its side at unity (a mono track plays duplicated, as Swift).
        assert!((l - 0.2).abs() < 0.02 && (r - 0.4).abs() < 0.02, "left {l} right {r}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Captions are burned into the exported picture only in the burn-in mode (Swift `CaptionBurnIn`).
    #[test]
    fn captions_are_burned_in_only_when_the_export_asks_for_it() {
        use sq_core_model::CaptionItem;
        use sq_export::core::settings::CaptionMode;
        let dir = std::env::temp_dir().join(format!("sq-export-cap-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let (Some(tool), true) = (ffmpeg_tool(), Gpu::new().is_ok()) else {
            eprintln!("skipped: no ffmpeg or no graphics device");
            return;
        };
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        sq_text::portable_font_match::set_fonts_root(&root);
        let (mut timeline, reference) = tiny_sequence(&tool, &dir);
        let item = CaptionItem {
            id: Id::from_u128(9),
            lines: vec!["HELLO WORLD".into()],
            range: TimeRange::new(Time::ZERO, Time::seconds(1)),
            style_ref: String::new(),
            animation_ref: String::new(),
            style_overridden: false,
            words: Vec::new(),
            position: None,
        };
        timeline.caption_tracks =
            vec![serde_json::from_value(serde_json::json!({"id": Id::from_u128(8), "items": [item]})).expect("track")];
        let snapshot = ExportSnapshot {
            timelines: vec![timeline.clone()].into(),
            media: vec![reference].into(),
            use_proxies_for_export: false,
        };
        let frame = |mode: CaptionMode| {
            let mut s = ExportSettings::default();
            (s.video.width, s.video.height) = (320, 180);
            s.video.frame_duration = Time::new(1, 25);
            s.captions = mode;
            let mut src = sources_rgba(&snapshot, timeline.id, &s).expect("sources");
            let f = src.video.frame(5).expect("frame");
            f.storage_as::<MemoryFrame>().expect("pixels").bytes.clone()
        };
        let (plain, burned) = (frame(CaptionMode::None), frame(CaptionMode::BurnIn));
        let changed = plain.chunks(4).zip(burned.chunks(4)).filter(|(a, b)| a != b).count();
        eprintln!("burn-in changed {changed} pixels");
        assert!(changed > 50, "burn-in changed only {changed} pixels");
        assert_eq!(plain, frame(CaptionMode::SidecarSrt), "a sidecar mode draws nothing into the picture");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A 1 s ProRes clip, 10-bit PQ Rec.2020, flat gray at Y' code 700 (PQ signal 0.726 = about 786 nit = 3.9x reference
    /// white, far above the SDR white code 573).
    fn make_pq_clip(tool: &Path, dir: &Path) -> Option<PathBuf> {
        let path = dir.join("pq.mov");
        let made = std::process::Command::new(tool)
            .args(["-y", "-v", "error", "-f", "lavfi", "-i"])
            .arg("color=c=black:s=320x180:r=25:d=1,format=yuv422p10le,geq=lum=700:cb=512:cr=512")
            .args(["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le"])
            .args(["-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc"])
            .arg(&path)
            .status()
            .ok()?;
        (made.success() && path.exists()).then_some(path)
    }

    /// The Y plane of frame `n` as 10-bit code values, decoded by the ffmpeg command line (no color conversion).
    fn decode_luma10(tool: &Path, file: &Path, n: usize) -> Vec<u16> {
        let out = std::process::Command::new(tool)
            .args(["-v", "error", "-i"])
            .arg(file)
            .args(["-vf", &format!("select=eq(n\\,{n}),extractplanes=y"), "-frames:v", "1"])
            .args(["-f", "rawvideo", "-pix_fmt", "gray10le", "-"])
            .output()
            .expect("run ffmpeg");
        out.stdout.chunks(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect()
    }

    /// An HDR delivery of a PQ clip keeps its highlights: the file's peak Y' code is far above SDR white (573 in PQ) and
    /// close to the source's 700. An SDR export of the same sequence still gets 8-bit Rec.709 frames.
    #[test]
    fn a_pq_clip_keeps_its_highlights_in_an_hdr_export() {
        use sq_core_model::{ColorSpaceID, MediaInfo};
        use sq_export::core::error::CancelToken;
        use sq_export::core::{HdrDelivery, HdrTransfer};
        let dir = std::env::temp_dir().join(format!("sq-export-hdr-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let (Some(tool), true) = (ffmpeg_tool(), Gpu::new().is_ok()) else {
            eprintln!("skipped: no ffmpeg or no graphics device");
            return;
        };
        let (timeline, mut reference) = tiny_sequence(&tool, &dir);
        let Some(pq) = make_pq_clip(&tool, &dir) else {
            eprintln!("skipped: this ffmpeg cannot write a 10-bit ProRes clip");
            return;
        };
        reference.path = pq.to_string_lossy().into_owned();
        reference.info = Some(MediaInfo {
            duration: Time::seconds(1),
            video: None,
            audio: None,
            detected_color_space: Some(ColorSpaceID::PqBT2020),
            embedded_lut_name: None,
            is_still: false,
            sound_probed: None,
            created: None,
            camera_model: None,
            shoot_probed: None,
        });
        let snapshot = ExportSnapshot {
            timelines: vec![timeline.clone()].into(),
            media: vec![reference].into(),
            use_proxies_for_export: false,
        };
        let mut s = ExportSettings::default();
        // AMF (the AMD hardware HEVC encoder) cannot initialize below 640x360 (AUDIT-MEDIA.md, w35).
        (s.video.width, s.video.height) = (640, 360);
        s.video.frame_duration = Time::new(1, 25);
        s.audio.enabled = false;
        // SDR: an 8-bit Rec.709 picture, unchanged path.
        let mut sdr_src = sources_rgba(&snapshot, timeline.id, &s).expect("sources");
        let sdr = sdr_src.video.frame(5).expect("frame");
        assert_eq!(sdr.pixel_format, SQFramePixelFormat::Rgba8);
        drop(sdr_src);
        // HDR delivery: the half-float composite, then the file.
        s.video.codec = sq_export::core::settings::VideoCodec::Hevc;
        s.video.hardware_encoding = true;
        s.hdr_delivery = Some(HdrDelivery::new(HdrTransfer::Pq, 1000.0, 400.0, 0.005));
        let mut src = sources_rgba(&snapshot, timeline.id, &s).expect("sources");
        let hdr = src.video.frame(5).expect("frame");
        assert_eq!(hdr.pixel_format, SQFramePixelFormat::Rgba16f);
        // Light above SDR white is in the frame: PQ code 700 (signal 0.726) is about 786 nit = 3.87 x reference white (a half float).
        let bytes = &hdr.storage_as::<MemoryFrame>().expect("pixels").bytes;
        let at = (180 * 640 + 320) * 8;
        let half = u16::from_le_bytes([bytes[at], bytes[at + 1]]);
        let value = f32::from_bits((u32::from((half >> 10) & 0x1F) + 112) << 23 | u32::from(half & 0x3FF) << 13);
        eprintln!("center red {value} x reference white");
        assert!((3.6..4.1).contains(&value), "linear light {value}, want about 3.87");
        let file = dir.join("hdr.mp4");
        let encoder = FfmpegExportEncoder::new();
        let done = encoder.export(src.video.as_mut(), None, &s, &file, &CancelToken::new(), &mut |_| {});
        if let Err(e) = done {
            // SQ_REQUIRE_HDR_FILE=1 (the PC run) turns a missing file into a failure.
            assert!(std::env::var_os("SQ_REQUIRE_HDR_FILE").is_none(), "HDR file not written: {e}");
            eprintln!("not written ({e})");
            return;
        }
        let v = probe(&file, "stream=codec_name,pix_fmt,color_transfer,color_primaries,color_space,nb_frames");
        eprintln!("[{}]\n{v}", encoder.last_video_encoder());
        assert!(v.contains("pix_fmt=yuv420p10le") && v.contains("color_transfer=smpte2084"), "{v}");
        assert!(v.contains("color_primaries=bt2020") && v.contains("color_space=bt2020nc"), "{v}");
        let side = probe_side_data(&file);
        eprintln!("side data: {side}");
        assert!(side.contains("Mastering display") && side.contains("Content light level"), "{side}");
        let y = decode_luma10(&tool, &file, 5);
        assert_eq!(y.len(), 640 * 360);
        let peak = y.iter().copied().max().unwrap_or(0);
        eprintln!("peak Y' code {peak} (source 700, SDR white 573)");
        assert!(peak > 650 && peak < 740, "peak code {peak}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_render_cache_segment_is_a_prores_lt_file_of_the_range() {
        let dir = std::env::temp_dir().join(format!("sq-export-seg-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let (Some(tool), true) = (ffmpeg_tool(), Gpu::new().is_ok()) else {
            eprintln!("skipped: no ffmpeg or no graphics device");
            return;
        };
        let (timeline, reference) = tiny_sequence(&tool, &dir);
        let snapshot = ExportSnapshot {
            timelines: vec![timeline.clone()].into(),
            media: vec![reference].into(),
            use_proxies_for_export: false,
        };
        let file = dir.join("segment.mov");
        let range = TimeRange::new(Time::new(5, 25), Time::new(10, 25));
        write_cache_segment(
            &snapshot,
            &timeline,
            range,
            &file,
            &sq_export::core::error::CancelToken::new(),
            &mut |_| {},
        )
        .expect("segment");
        let v = probe(&file, "stream=codec_name,profile,width,height,nb_frames");
        eprintln!("segment: {v}");
        assert!(v.contains("codec_name=prores") && v.contains("width=320") && v.contains("nb_frames=10"), "{v}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn stems_are_written_by_the_offline_mixer_one_file_per_role() {
        use sq_core_model::AudioTag;
        use sq_editor_session::{ExportDialogModel, SequenceItem};
        use sq_export::core::error::CancelToken;
        use sq_export::core::stems::StemPlan;
        let dir = std::env::temp_dir().join(format!("sq-stems-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let Some(tool) = ffmpeg_tool() else {
            eprintln!("skipped: no ffmpeg command or no linked FFmpeg shim");
            return;
        };
        let (mut timeline, reference) = tiny_sequence(&tool, &dir);
        timeline.tracks[1].audio_role = Some(AudioTag::Dialogue);
        let stems = StemPlan::stems(&timeline);
        assert_eq!(stems.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(), ["dialogue"]);
        let snapshot = ExportSnapshot {
            timelines: vec![timeline.clone()].into(),
            media: vec![reference].into(),
            use_proxies_for_export: false,
        };
        let shared = Arc::new(std::sync::Mutex::new(snapshot));
        let encoder = Arc::new(FfmpegExportEncoder::new());
        let item = SequenceItem::new(timeline.id, "tiny", timeline.duration());
        let mut model = ExportDialogModel::new(
            vec![item],
            None,
            Arc::new(|_| None),
            Arc::new(|_, _| Err(ExportError::Other("no video here".into()))),
            Box::new(sq_core_time::SequentialIds::default()),
        );
        model.set_stem_plans([(timeline.id, stems)].into_iter().collect());
        model.set_stem_audio(Some(Arc::new(move |_, stem, range| {
            let snap = shared.lock().expect("snapshot").clone();
            stem_audio(&snap, stem, range)
        })));
        model.set_stem_encoder(Some(encoder));
        assert!(model.can_export_stems());
        let request = model.begin_export_stems(&dir).expect("a stem export");
        model.finish_export_stems(request.run(&CancelToken::new()));
        assert_eq!(model.stem_status(), Some("1 stem files written."), "{:?}", model.stem_status());
        let wav = std::fs::read_dir(&dir)
            .expect("folder")
            .flatten()
            .map(|e| e.path())
            .find(|p| p.extension().is_some_and(|x| x == "wav"))
            .expect("a stem file");
        assert_audible(&tool, &wav);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A 7 s test source of flat colors, one second each.
    fn make_colors(tool: &Path, dir: &Path) -> Option<PathBuf> {
        let path = dir.join("colors.mp4");
        let mut cmd = std::process::Command::new(tool);
        cmd.args(["-y", "-v", "error"]);
        for c in ["red", "green", "yellow", "blue", "magenta", "cyan", "white"] {
            cmd.args(["-f", "lavfi", "-i", &format!("color=c={c}:s=320x180:r=25:d=1")]);
        }
        let made = cmd
            .args([
                "-filter_complex",
                "[0][1][2][3][4][5][6]concat=n=7:v=1:a=0",
                "-c:v",
                "mpeg4",
                "-pix_fmt",
                "yuv420p",
            ])
            .arg(&path)
            .status()
            .ok()?;
        (made.success() && path.exists()).then_some(path)
    }

    /// Three 1 s clips cut from one 3 s source, the middle one selected, the default transition applied (Shift+D); the frame
    /// at the middle of each cut as the export source renders it.
    fn dissolved_cut_frames() -> Option<[Vec<u8>; 2]> {
        dissolved_cut_frames_in(false)
    }

    /// `gpu_yuv`: the frames come as GPU-made NV12 and are read through the preview conversion.
    fn dissolved_cut_frames_in(gpu_yuv: bool) -> Option<[Vec<u8>; 2]> {
        use sq_core_model::Project;
        use sq_editor_session::{EditorSession, SessionDeps, TransitionDefaults, TransitionScope};
        // One folder per call: this runs in two tests at once, and a shared name had one test delete the other's source.
        static CALLS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let call = CALLS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("sq-export-dissolve-{}-{call}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let tool = ffmpeg_tool()?;
        Gpu::new().ok()?;
        let path = make_colors(&tool, &dir).expect("a color source");
        let media = Id::from_u128(100);
        let reference =
            sq_core_model::MediaRef::new(media, "colors", &path.to_string_lossy(), MediaFingerprint::new(1));
        let mut track = Track::new(Id::from_u128(900), TrackKind::Video);
        track.is_targeted = true;
        // Clips 1 s from second 0, 3 and 6 (red, blue, white): each side of a cut reads on into its own handle.
        let clips = (0..3i64)
            .map(|n| {
                let source = TimeRange::new(Time::seconds(n * 3), Time::seconds(1));
                let mut c =
                    Clip::new(Id::from_u128(10 + n as u128), "c", media, TrackKind::Video, source, Time::seconds(n));
                c.media_duration = Some(Time::seconds(7));
                c
            })
            .collect();
        track.set_clips(clips);
        let mut format = SequenceFormat::new(Time::new(1, 25));
        (format.width, format.height) = (320, 180);
        let timeline = Timeline::new(Id::from_u128(1), "dissolve", format, vec![track]);
        let project = Project::new(Id::from_u128(2), "p", Vec::new(), vec![timeline]);
        let mut session = EditorSession::new(project, SessionDeps::headless(dir.join("session")));
        session.select(std::collections::BTreeSet::from([Id::from_u128(11)]), std::collections::BTreeSet::new());
        let applied =
            session.apply_default_transitions(TransitionScope::Video, None, None, &TransitionDefaults::STANDARD);
        assert_eq!(applied, 2, "both cuts of the middle clip get the default transition");
        let timeline = session.active_timeline().expect("timeline").clone();
        let snapshot = ExportSnapshot {
            timelines: vec![timeline].into(),
            media: vec![reference].into(),
            use_proxies_for_export: false,
        };
        let mut settings = ExportPreset::all()
            .into_iter()
            .map(|p| p.settings())
            .find(|s| s.video.codec == VideoCodec::H264 && s.audio_only.is_none() && s.frame_output.is_none())
            .expect("an H.264 preset");
        (settings.video.width, settings.video.height) = (320, 180);
        settings.video.frame_duration = Time::new(1, 25);
        settings.audio.enabled = false;
        let mut src = sources_in(&snapshot, Id::from_u128(1), &settings, gpu_yuv).expect("sources").video;
        let mut at = |i: usize| {
            let f = src.frame(i).expect("frame");
            if gpu_yuv {
                assert_eq!(f.pixel_format, SQFramePixelFormat::Nv12, "the GPU delivers NV12");
                let image = frame_pixels(&f).expect("a picture");
                let o = (f.height / 2 * f.width + f.width / 2) * 4;
                return image.pixels[o..o + 3].to_vec();
            }
            let m = f.storage_as::<MemoryFrame>().expect("memory frame");
            let o = (f.height / 2 * f.width + f.width / 2) * 4;
            m.bytes[o..o + 3].to_vec()
        };
        let out = [at(25), at(50)];
        let _ = std::fs::remove_dir_all(&dir);
        Some(out)
    }

    #[test]
    fn a_default_dissolve_blends_at_both_cuts_of_the_middle_clip() {
        let Some([first, second]) = dissolved_cut_frames() else {
            eprintln!("skipped: no ffmpeg or no graphics device");
            return;
        };
        // Green into blue and magenta into white: the green channel is 0 or 255 (or the flat green) on a pure side, in between in a mix.
        let mixed = |p: &[u8]| (20..235).contains(&p[1]) && p[1] != 109;
        assert!(mixed(&first), "first cut {first:?} is a hard cut");
        assert!(mixed(&second), "second cut {second:?} is a hard cut");
    }

    #[test]
    fn the_gpu_nv12_frames_match_the_rgba_frames() {
        let (Some(rgba), Some(nv12)) = (dissolved_cut_frames_in(false), dissolved_cut_frames_in(true)) else {
            eprintln!("skipped: no ffmpeg or no graphics device");
            return;
        };
        for (a, b) in rgba.iter().zip(&nv12) {
            let worst = a.iter().zip(b).map(|(x, y)| x.abs_diff(*y)).max().unwrap_or(0);
            assert!(worst <= 6, "RGBA {a:?} against NV12 {b:?}");
        }
    }
}
