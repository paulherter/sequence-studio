//! Mac: `AVSpeechSynthesizer.write(_:toBufferCallback:)`, the same engine as the Swift `SpeechRenderer`. The buffers arrive
//! on a background queue and are written to a WAV file as they come; an empty buffer ends the utterance.

use crate::{Rendered, SpeechEngine, SpeechError, SpeechVoice, WavWriter, sort_voices};
use block2::RcBlock;
use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2_avf_audio::{
    AVAudioBuffer, AVAudioPCMBuffer, AVSpeechSynthesisVoice, AVSpeechSynthesisVoiceQuality, AVSpeechSynthesizer,
    AVSpeechUtterance,
};
use objc2_foundation::NSString;
use std::path::Path;
use std::ptr::NonNull;
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Swift `SpeechRenderer.render(timeout: 300)`.
const TIMEOUT: Duration = Duration::from_secs(300);

pub(crate) struct MacSpeech;

impl SpeechEngine for MacSpeech {
    fn voices(&self) -> Vec<SpeechVoice> {
        // SAFETY: plain class-method call; the voices are read on this thread only.
        let all = unsafe { AVSpeechSynthesisVoice::speechVoices() };
        let mut list: Vec<SpeechVoice> = all
            .iter()
            .map(|v| unsafe {
                SpeechVoice {
                    id: v.identifier().to_string(),
                    name: v.name().to_string(),
                    language: v.language().to_string(),
                    enhanced: v.quality() != AVSpeechSynthesisVoiceQuality::Default,
                }
            })
            .collect();
        sort_voices(&mut list, &crate::own_language());
        list
    }

    fn synthesize(&self, text: &str, voice_id: &str, rate: f64, out: &Path) -> Result<Rendered, SpeechError> {
        // SAFETY: all calls below are documented AVFoundation API on objects this function owns.
        unsafe {
            let voice = AVSpeechSynthesisVoice::voiceWithIdentifier(&NSString::from_str(voice_id))
                .ok_or(SpeechError::NoVoice)?;
            let utterance = AVSpeechUtterance::speechUtteranceWithString(&NSString::from_str(text));
            utterance.setVoice(Some(&voice));
            utterance.setRate(rate as f32);
            let (tx, rx) = channel();
            let job = Arc::new(Mutex::new(Job { out: out.to_path_buf(), file: None, rate: 0, tx: Some(tx) }));
            let sink = Arc::clone(&job);
            let block = RcBlock::new(move |buffer: NonNull<AVAudioBuffer>| {
                if let Ok(mut j) = sink.lock() {
                    j.handle(buffer);
                }
            });
            let synth = AVSpeechSynthesizer::new();
            synth.writeUtterance_toBufferCallback(&utterance, &*block as *const _ as *mut _);
            let result = rx.recv_timeout(TIMEOUT).unwrap_or(Err(SpeechError::TimedOut));
            synth.stopSpeakingAtBoundary(objc2_avf_audio::AVSpeechBoundary::Immediate);
            // The callback may still run once; this closes the file for good.
            if let Ok(mut j) = job.lock() {
                j.tx = None;
                j.file = None;
            }
            result
        }
    }
}

/// The file being written, owned by the buffer callback.
struct Job {
    out: std::path::PathBuf,
    file: Option<WavWriter>,
    rate: i32,
    tx: Option<Sender<Result<Rendered, SpeechError>>>,
}

impl Job {
    fn handle(&mut self, buffer: NonNull<AVAudioBuffer>) {
        let Some(tx) = self.tx.clone() else { return };
        // SAFETY: the buffer is valid for the duration of the callback.
        let any: &AnyObject = unsafe { &*buffer.as_ptr().cast::<AnyObject>() };
        let Some(pcm) = any.downcast_ref::<AVAudioPCMBuffer>() else { return };
        let frames = unsafe { pcm.frameLength() } as usize;
        if frames == 0 {
            let written = self.file.take().map(WavWriter::finish);
            let _ = tx.send(match written {
                Some(Ok(n)) if n > 0 => Ok(Rendered { frames: n, sample_rate: self.rate }),
                Some(Err(e)) => Err(SpeechError::Failed(e.to_string())),
                _ => Err(SpeechError::NoAudio),
            });
            self.tx = None;
            return;
        }
        if let Err(e) = self.write(pcm, frames) {
            self.file = None;
            let _ = tx.send(Err(e));
            self.tx = None;
        }
    }

    fn write(&mut self, pcm: &AVAudioPCMBuffer, frames: usize) -> Result<(), SpeechError> {
        let failed = |e: std::io::Error| SpeechError::Failed(e.to_string());
        // SAFETY: the channel pointers hold `frames` samples each while the callback runs.
        unsafe {
            let format: Retained<_> = pcm.format();
            let channels = format.channelCount() as usize;
            if self.file.is_none() {
                self.rate = format.sampleRate().round() as i32;
                self.file = Some(WavWriter::create(&self.out, channels as u16, self.rate as u32).map_err(failed)?);
            }
            let Some(file) = self.file.as_mut() else { return Ok(()) };
            let floats = pcm.floatChannelData();
            let shorts = pcm.int16ChannelData();
            // Non-interleaved data has one pointer per channel; interleaved data has one pointer with all channels.
            let plane = |c: usize| if format.isInterleaved() { 0 } else { c };
            let per = if format.isInterleaved() { frames * channels } else { frames };
            if !floats.is_null() {
                let planes: Vec<&[f32]> = (0..if format.isInterleaved() { 1 } else { channels })
                    .map(|c| std::slice::from_raw_parts((*floats.add(plane(c))).as_ptr(), per))
                    .collect();
                file.write_f32(&interleave(&planes, frames, channels, format.isInterleaved())).map_err(failed)
            } else if !shorts.is_null() {
                let planes: Vec<&[i16]> = (0..if format.isInterleaved() { 1 } else { channels })
                    .map(|c| std::slice::from_raw_parts((*shorts.add(plane(c))).as_ptr(), per))
                    .collect();
                file.write_i16(&interleave(&planes, frames, channels, format.isInterleaved())).map_err(failed)
            } else {
                Err(SpeechError::Failed("unsupported sample format".into()))
            }
        }
    }
}

/// One interleaved vector from the channel planes (or the single interleaved plane).
fn interleave<T: Copy>(planes: &[&[T]], frames: usize, channels: usize, already: bool) -> Vec<T> {
    if already {
        return planes.first().map(|p| p.to_vec()).unwrap_or_default();
    }
    (0..frames).flat_map(|i| (0..channels).map(move |c| planes[c][i])).collect()
}
