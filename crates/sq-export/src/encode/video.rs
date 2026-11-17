//! H.264 / HEVC / ProRes video files with AAC or PCM audio.

use super::audio::AudioFeed;
use super::hdr_stage::{to_p010, to_p010_f16};
use super::pipeline::pump;
use super::pixels::pixels_of;
use crate::core::encoder_support::no_encoder_message;
use crate::core::{
    AudioSource, CancelToken, EncoderSpeed, ExportError, ExportSettings, FrameSource, HdrTransfer, LoudnessReport,
    VideoCodec, VideoProfile,
};
use sq_media_ffmpeg::encode::{ENCODER_NOT_FOUND, EncodeConfig, Encoder, H264Profile, PixelLayout, Tags};
use std::path::Path;

/// The H.264 profile the settings ask for; `Automatic` for HEVC and ProRes (their profiles are not this choice).
pub(super) fn h264_profile(c: VideoCodec, p: VideoProfile) -> H264Profile {
    match (c, p) {
        (VideoCodec::H264, VideoProfile::Baseline) => H264Profile::Baseline,
        (VideoCodec::H264, VideoProfile::Main) => H264Profile::Main,
        (VideoCodec::H264, VideoProfile::High) => H264Profile::High,
        _ => H264Profile::Automatic,
    }
}

/// The C config's ProRes value: 0 for H.264 / HEVC, else 1 + the `prores_ks` profile.
pub(super) fn prores_profile(c: VideoCodec) -> i32 {
    match c {
        VideoCodec::H264 | VideoCodec::Hevc => 0,
        VideoCodec::ProRes422Proxy => 1,
        VideoCodec::ProRes422LT => 2,
        VideoCodec::ProRes422 => 3,
        VideoCodec::ProRes422HQ => 4,
        VideoCodec::ProRes4444 => 5,
    }
}

pub(super) fn writer_error(e: sq_media_ffmpeg::shim::ShimError) -> ExportError {
    // FFmpeg reports a full disk as AVERROR(ENOSPC) = -28 on every platform; the queue then says "The disk is full".
    if e.code == -28 {
        return ExportError::DiskFull;
    }
    ExportError::WriterFailed(e.to_string())
}

/// The container tags of the file's metadata (title, comment with chapters, creation date); none without metadata.
pub(super) fn tags_of(settings: &ExportSettings) -> Tags {
    settings.metadata.as_ref().map_or_else(Tags::default, |m| {
        let (title, comment, creation_time) = m.container_tags();
        Tags { title, comment, creation_time }
    })
}

/// Audio samples per write: the muxer interleaves evenly when audio follows each picture.
const AUDIO_STEP: usize = 4096;

/// Writes the video file; returns the loudness report and the name of the video encoder used.
pub(super) fn write(
    video: &mut dyn FrameSource,
    audio: Option<&mut dyn AudioSource>,
    settings: &ExportSettings,
    url: &Path,
    cancel: &CancelToken,
    progress: &mut dyn FnMut(f64),
) -> Result<(Option<LoudnessReport>, String), ExportError> {
    let v = &settings.video;
    if v.codec.is_pro_res() && !url.extension().is_some_and(|e| e.eq_ignore_ascii_case("mov")) {
        return Err(ExportError::WriterFailed("ProRes needs a .mov file".to_string()));
    }
    let audio = audio.filter(|_| settings.audio.enabled);
    if let Some(a) = audio.as_deref()
        && a.sample_rate() != settings.audio.sample_rate
    {
        // shortcut: no resampling here; the timeline audio source already renders at the export rate.
        return Err(ExportError::WriterFailed(format!(
            "audio at {} Hz, the export at {} Hz",
            a.sample_rate(),
            settings.audio.sample_rate
        )));
    }
    let fd = video.frame_duration();
    let channels = settings.audio.channels.clamp(1, 2) as usize;
    let rate = settings.audio.sample_rate;
    let (mut feed, report) = match audio {
        Some(a) => {
            let (f, r) = AudioFeed::new(a, &settings.audio, channels, cancel)?;
            (Some(f), r)
        }
        None => (None, None),
    };
    let (width, height) = (v.width as usize, v.height as usize);
    // HDR delivery (HEVC only): BT.2020 tags, MDCV / CLLI, and the output stage below in front of the encoder.
    let hdr = settings.applied_hdr_delivery();
    let cfg = EncodeConfig {
        path: url.to_path_buf(),
        hevc: v.codec == VideoCodec::Hevc,
        hardware: v.hardware_encoding,
        width: v.width as i32,
        height: v.height as i32,
        fps_num: fd.timescale() as i32,
        fps_den: fd.value() as i32,
        bitrate: v.bitrate.average_bits_per_second(),
        gop: v.keyframe_interval.max(1) as i32,
        b_frames: if v.allows_frame_reordering && h264_profile(v.codec, v.profile).allows_b_frames() { 2 } else { 0 },
        h264_profile: h264_profile(v.codec, v.profile),
        ten_bit: v.codec == VideoCodec::Hevc && (v.profile == VideoProfile::Main10 || hdr.is_some()),
        prores: prores_profile(v.codec),
        pcm_bits: if settings.audio.codec == crate::core::AudioCodec::Pcm {
            settings.audio.pcm_bit_depth as i32
        } else {
            0
        },
        audio_rate: rate as i32,
        audio_channels: if feed.is_some() { channels as i32 } else { 0 },
        audio_bitrate: settings.audio.bitrate,
        quality: v.constant_quality().unwrap_or(0.0),
        max_bitrate: v.bitrate.max_bits_per_second().unwrap_or(0),
        cbr: v.uses_constant_bitrate(),
        speed: match settings.encoder_speed() {
            EncoderSpeed::Quality => 0,
            EncoderSpeed::Balanced => 1,
            EncoderSpeed::Fast => 2,
        },
        tags: tags_of(settings),
        // AVCOL_PRI_BT2020 9, AVCOL_TRC_SMPTE2084 16 / AVCOL_TRC_ARIB_STD_B67 18, AVCOL_SPC_BT2020_NCL 9.
        color_tags: hdr.map_or((0, 0, 0), |h| (9, if h.transfer == HdrTransfer::Pq { 16 } else { 18 }, 9)),
        mdcv: hdr.map(|h| h.mastering_display_data()).unwrap_or_default(),
        cll: hdr.map(|h| h.content_light_level_data()).unwrap_or_default(),
        ..EncodeConfig::default()
    };
    let _ = std::fs::remove_file(url);
    let mut enc = Encoder::open(&cfg).map_err(|e| {
        let asked = matches!(v.codec, VideoCodec::H264 | VideoCodec::Hevc);
        if e.code == ENCODER_NOT_FOUND && asked {
            ExportError::NoEncoder(no_encoder_message(settings))
        } else {
            writer_error(e)
        }
    })?;
    let name = enc.video_name();
    // The proof that hardware encoding ran: the encoder that was opened (h264_amf, h264_mf, h264_videotoolbox, libx264, ...).
    sq_core_time::milestones::info(&format!(
        "export: video encoder {name} ({}x{}, hardware {})",
        cfg.width,
        cfg.height,
        if cfg.hardware { "allowed" } else { "off" }
    ));
    let total = video.frame_count();
    let mut written: i64 = 0;
    // An error or a cancel drops `enc`, which aborts and deletes the partial file.
    pump(video, cancel, |i, frame| {
        let px = pixels_of(&frame, i, width, height)?;
        if let Some(h) = hdr.filter(|_| px.layout == PixelLayout::Rgbaf16le) {
            // The engine's half-float working composite: highlights above SDR white reach the signal.
            let p010 = to_p010_f16(&px.bytes, px.stride, width, height, h.transfer);
            enc.video(&p010, PixelLayout::P010le, (width * 2) as i32, i as i64).map_err(writer_error)?;
        } else if let Some(h) = hdr {
            let bgr = match px.layout {
                PixelLayout::Bgra => true,
                PixelLayout::Rgba => false,
                other => {
                    return Err(ExportError::WriterFailed(format!("HDR delivery needs RGBA pictures, got {other:?}")));
                }
            };
            let p010 = to_p010(&px.bytes, px.stride, bgr, width, height, h.transfer);
            enc.video(&p010, PixelLayout::P010le, (width * 2) as i32, i as i64).map_err(writer_error)?;
        } else {
            enc.video(&px.bytes, px.layout, px.stride as i32, i as i64).map_err(writer_error)?;
        }
        if let Some(feed) = feed.as_mut() {
            // Audio up to the end of this frame. Past the source's end: silence.
            let (ts, fv) = (i128::from(fd.timescale()), i128::from(fd.value()));
            let end = ((i as i128 + 1) * fv * i128::from(rate) + ts / 2) / ts;
            while i128::from(written) < end {
                let want = (end - i128::from(written)).min(AUDIO_STEP as i128) as usize;
                let out = feed.read(want, false)?;
                enc.audio(&out).map_err(writer_error)?;
                written += (out.len() / channels) as i64;
            }
        }
        progress((i + 1) as f64 / total.max(1) as f64);
        Ok(())
    })?;
    enc.finish().map_err(writer_error)?;
    // The encoder is lossy: read the loudness and true peak back from the file.
    let report = report.map(|mut r| {
        r.verified = super::verify::measure_output_audio(url).ok().flatten();
        r
    });
    Ok((report, name))
}

#[cfg(test)]
mod writer_error_tests {
    use super::*;
    use sq_media_ffmpeg::shim::ShimError;

    #[test]
    fn a_full_disk_from_the_encoder_is_the_disk_full_error() {
        let full = ShimError { code: -28, message: "video encode frame 29 failed (-28)".into() };
        assert!(matches!(writer_error(full), ExportError::DiskFull));
        let other = ShimError { code: -5, message: "x".into() };
        assert!(matches!(writer_error(other), ExportError::WriterFailed(_)));
    }
}
