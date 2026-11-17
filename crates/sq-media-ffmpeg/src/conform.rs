// Swift: VFRConform.swift (`VFRConform.conform`, there an AVAssetReader/Writer copy to ProRes 422)
//! "Conform to Constant Frame Rate": a variable-frame-rate file is decoded and written again as ProRes 422 at a constant
//! frame duration. Which source frame fills which output frame is `sq_media::vfr_conform::plan` (the Swift slot math):
//! frames go to the nearest slot, a slot taken by a later frame drops the earlier one, a gap repeats the frame before it.
//! The audio follows as 24-bit PCM: every usable audio track (one with channels) becomes its own PCM track with its own
//! sample rate and channel count, as Swift writes them (no mixing).

use crate::decode::{FFmpegDemuxer, FFmpegVideoDecoder};
use crate::encode::{EncodeConfig, Encoder, PixelLayout};
use crate::shim::{self, AudioReader};
use sq_core_time::{Id, Time};
use sq_media::demuxing::Demuxing;
use sq_media::vfr_conform::plan;
use std::path::Path;
use std::sync::Arc;

/// Frames decoded per call (the decoder keeps its own GOP state between calls).
const CHUNK: usize = 8;

/// Writes `destination` (a .mov) from `source` at the constant `frame_duration`. `progress` gets 0...1; `canceled` is asked
/// between frames and stops the job with `Err("Canceled.")` (the encoder drops the partial file).
pub fn conform_to_constant_frame_rate(
    source: &Path,
    destination: &Path,
    frame_duration: Time,
    progress: &dyn Fn(f64),
    canceled: &dyn Fn() -> bool,
) -> Result<(), String> {
    if frame_duration.value() <= 0
        || frame_duration.timescale() <= 0
        || frame_duration.timescale() > i64::from(i32::MAX)
    {
        return Err("The frame duration is not valid.".to_string());
    }
    let demuxer = FFmpegDemuxer::open_shared(source).map_err(|e| e.to_string())?;
    let info = demuxer.track_info();
    let raw = demuxer.raw();
    let entries = demuxer.index().entries().to_vec();
    let Some(last) = entries.last() else { return Err("The file has no video frames.".to_string()) };
    let end = last.pts + last.duration;
    let pts: Vec<Time> = entries.iter().map(|e| e.pts).collect();
    let slots = plan(&pts, end, frame_duration);
    let total: i64 = slots.iter().map(|r| r.end - r.start).sum::<i64>().max(1);

    let mut audio = open_audio_tracks(source);
    let cfg = EncodeConfig {
        path: destination.to_path_buf(),
        width: i32::try_from(info.width).map_err(|e| e.to_string())?,
        height: i32::try_from(info.height).map_err(|e| e.to_string())?,
        fps_num: i32::try_from(frame_duration.timescale()).map_err(|e| e.to_string())?,
        fps_den: i32::try_from(frame_duration.value()).map_err(|e| e.to_string())?,
        prores: 3,
        pcm_bits: 24,
        audio_rate: audio.first().map_or(0, |t| t.rate),
        audio_channels: audio.first().map_or(0, |t| t.channels),
        extra_audio: audio.iter().skip(1).map(|t| (t.rate, t.channels)).collect(),
        // Rotation and color tags travel with the picture (Swift copies the track transform and the format's tags).
        color_tags: (raw.color_primaries, raw.color_transfer, raw.color_matrix),
        rotation: info.rotation as i32,
        ..EncodeConfig::default()
    };
    let _ = std::fs::remove_file(destination);
    let mut enc = Encoder::open(&cfg).map_err(|e| e.to_string())?;
    let decoder =
        FFmpegVideoDecoder::new(Arc::clone(&demuxer), Id::from_u128(0), false, 0).map_err(|e| e.to_string())?;
    let deep = info.bit_depth > 8;
    let (layout, stride) = if deep { (PixelLayout::P010le, cfg.width * 2) } else { (PixelLayout::Nv12, cfg.width) };

    let mut written = 0i64;
    for from in (0..entries.len()).step_by(CHUNK) {
        let to = (from + CHUNK - 1).min(entries.len() - 1);
        let frames = decoder.decode_blocking(from..=to, None, None).map_err(|e| e.to_string())?;
        for (offset, frame) in frames.iter().enumerate() {
            if canceled() {
                return Err("Canceled.".to_string());
            }
            let storage =
                frame.frame.storage_as::<crate::decode::FFmpegFrame>().ok_or("The decoder gave no picture.")?;
            let bytes = storage.download().map_err(|e| e.to_string())?;
            for slot in slots[from + offset].clone() {
                enc.video(&bytes, layout, stride, slot).map_err(|e| e.to_string())?;
                written += 1;
                feed_audio(&mut enc, &mut audio, slot + 1, frame_duration)?;
            }
            progress(written as f64 / total as f64);
        }
    }
    feed_audio(&mut enc, &mut audio, i64::MAX, frame_duration)?;
    enc.finish().map_err(|e| e.to_string())?;
    progress(1.0);
    Ok(())
}

/// One audio track of the source being copied: streamed in its own rate and channel count.
struct AudioTrack {
    reader: AudioReader,
    rate: i32,
    channels: i32,
    /// Next frame to read.
    at: i64,
    done: bool,
}

/// Every usable audio track (one with channels and a rate) of `source`; a track that cannot be opened is left out.
fn open_audio_tracks(source: &Path) -> Vec<AudioTrack> {
    let counts = shim::audio_track_channels(source).unwrap_or_default();
    let rates = shim::audio_track_rates(source).unwrap_or_default();
    let mut out = Vec::new();
    for (ordinal, (channels, rate)) in counts.iter().zip(rates).enumerate() {
        let (Ok(channels), true) = (i32::try_from(*channels), rate > 0) else { continue };
        if channels <= 0 || out.len() >= 8 {
            continue;
        }
        if let Ok(reader) = AudioReader::open(source, rate, channels, Some(ordinal)) {
            out.push(AudioTrack { reader, rate, channels, at: 0, done: false });
        }
    }
    out
}

/// Gives every track the audio up to the end of video frame `slots` (or to its end); each track counts in its own rate.
fn feed_audio(enc: &mut Encoder, tracks: &mut [AudioTrack], slots: i64, frame_duration: Time) -> Result<(), String> {
    for (index, t) in tracks.iter_mut().enumerate() {
        let until = if slots == i64::MAX {
            i64::MAX
        } else {
            let n = i128::from(slots) * i128::from(frame_duration.value()) * i128::from(t.rate);
            (n / i128::from(frame_duration.timescale())) as i64
        };
        let ch = usize::try_from(t.channels).unwrap_or(1);
        while !t.done && t.at < until {
            let n = usize::try_from(until - t.at).unwrap_or(usize::MAX).min(8192);
            let mut buf = vec![0f32; n * ch];
            let got = t.reader.read(t.at, &mut buf).map_err(|e| e.to_string())?;
            if got == 0 {
                t.done = true;
                break;
            }
            enc.audio_track(index, &buf[..got * ch]).map_err(|e| e.to_string())?;
            t.at += got as i64;
        }
    }
    Ok(())
}
