//! A streaming 16-bit PCM WAV writer: the header is written first and patched with the sizes on `finish`.

use std::fs::File;
use std::io::{self, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::Path;

/// Writes interleaved 16-bit samples of one fixed format.
pub struct WavWriter {
    out: BufWriter<File>,
    channels: u16,
    sample_rate: u32,
    frames: i64,
}

impl WavWriter {
    pub fn create(path: &Path, channels: u16, sample_rate: u32) -> io::Result<WavWriter> {
        let mut out = BufWriter::new(File::create(path)?);
        out.write_all(&[0; 44])?;
        Ok(WavWriter { out, channels, sample_rate, frames: 0 })
    }

    /// Appends interleaved samples.
    pub fn write_i16(&mut self, samples: &[i16]) -> io::Result<()> {
        for s in samples {
            self.out.write_all(&s.to_le_bytes())?;
        }
        self.frames += (samples.len() / usize::from(self.channels.max(1))) as i64;
        Ok(())
    }

    /// Appends interleaved float samples (-1...1), clipped.
    pub fn write_f32(&mut self, samples: &[f32]) -> io::Result<()> {
        for s in samples {
            self.out.write_all(&((s.clamp(-1.0, 1.0) * 32767.0).round() as i16).to_le_bytes())?;
        }
        self.frames += (samples.len() / usize::from(self.channels.max(1))) as i64;
        Ok(())
    }

    /// Patches the header and returns the number of frames written.
    pub fn finish(mut self) -> io::Result<i64> {
        let data = (self.frames * i64::from(self.channels) * 2) as u32;
        let block = self.channels * 2;
        let mut h = Vec::with_capacity(44);
        h.extend_from_slice(b"RIFF");
        h.extend_from_slice(&(36 + data).to_le_bytes());
        h.extend_from_slice(b"WAVEfmt ");
        h.extend_from_slice(&16u32.to_le_bytes());
        h.extend_from_slice(&1u16.to_le_bytes());
        h.extend_from_slice(&self.channels.to_le_bytes());
        h.extend_from_slice(&self.sample_rate.to_le_bytes());
        h.extend_from_slice(&(self.sample_rate * u32::from(block)).to_le_bytes());
        h.extend_from_slice(&block.to_le_bytes());
        h.extend_from_slice(&16u16.to_le_bytes());
        h.extend_from_slice(b"data");
        h.extend_from_slice(&data.to_le_bytes());
        self.out.seek(SeekFrom::Start(0))?;
        self.out.write_all(&h)?;
        self.out.flush()?;
        Ok(self.frames)
    }
}

/// The format and length of a PCM WAV file written by an engine: (sample rate, frames). Walks the chunks, so a file
/// from another writer (espeak-ng, WinRT) with extra chunks or a streamed (0 or 0xFFFFFFFF) data size is read too.
pub fn wav_frames(path: &Path) -> io::Result<(i32, i64)> {
    let bad = || io::Error::new(io::ErrorKind::InvalidData, "not a PCM WAV file");
    let mut bytes = Vec::new();
    File::open(path)?.read_to_end(&mut bytes)?;
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return Err(bad());
    }
    let (mut pos, mut format) = (12, None);
    while pos + 8 <= bytes.len() {
        let id = &bytes[pos..pos + 4];
        let size = u32::from_le_bytes([bytes[pos + 4], bytes[pos + 5], bytes[pos + 6], bytes[pos + 7]]) as usize;
        let body = pos + 8;
        if id == b"fmt " && body + 16 <= bytes.len() {
            let ch = u16::from_le_bytes([bytes[body + 2], bytes[body + 3]]);
            let rate = u32::from_le_bytes([bytes[body + 4], bytes[body + 5], bytes[body + 6], bytes[body + 7]]);
            let bits = u16::from_le_bytes([bytes[body + 14], bytes[body + 15]]);
            format = Some((rate as i32, usize::from(ch) * usize::from(bits / 8)));
        } else if id == b"data" {
            let (rate, frame_bytes) = format.ok_or_else(bad)?;
            let available = bytes.len() - body;
            let len = if size == 0 || size > available { available } else { size };
            return Ok((rate, (len / frame_bytes.max(1)) as i64));
        }
        pos = body + size + (size & 1);
    }
    Err(bad())
}
