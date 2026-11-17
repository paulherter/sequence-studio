//! Port of the portable parts of `SQMedia/Sources/SQMedia/WebM/WebMAudioSource.swift`.
//!
//! The Swift file decodes Opus and AAC through AVFoundation / AudioToolbox and resamples with `AVAudioConverter`; the
//! Windows build of the package leaves it out. Ported here: the packet decoders that are plain byte logic (PCM, the Opus
//! packet length, the AAC AudioSpecificConfig reader and `esds` writer) and the stereo mix-down. `WebMAudioSource` itself
//! (packet table, runs, resampling) and `OpusPacketDecoder` / `AACPacketDecoder` (system decoders) are not ported.

use crate::media_error::MediaError;

/// One packet-to-PCM codec of a WebM audio track (native sample rate, one array per channel).
pub trait WebMPacketDecoder {
    fn channels(&self) -> usize;
    fn sample_rate(&self) -> usize;
    /// Packets to feed before the wanted one after a seek, so the decoder state is warm.
    fn preroll_packets(&self) -> usize;
    fn decode(&mut self, packet: &[u8]) -> Vec<Vec<f32>>;
    fn reset(&mut self);
}

/// Opus through the system decoder (AudioToolbox) in Swift; only the packet length helper is portable.
pub enum OpusPacketDecoder {}

impl OpusPacketDecoder {
    /// Samples at 48 kHz in an Opus packet (RFC 6716 section 3.1), `None` when malformed.
    pub fn samples_in(p: &[u8]) -> Option<i64> {
        let toc = *p.first()?;
        let config = usize::from(toc >> 3);
        let frame_size: i64 = match config {
            0..=11 => [480, 960, 1920, 2880][config & 3],
            12..=15 => {
                if config & 1 == 0 {
                    480
                } else {
                    960
                }
            }
            _ => [120, 240, 480, 960][config & 3],
        };
        match toc & 3 {
            0 => Some(frame_size),
            1 | 2 => Some(frame_size * 2),
            _ => {
                if p.len() <= 1 {
                    return None;
                }
                Some(frame_size * i64::from(p[1] & 0x3F))
            }
        }
    }
}

/// Uncompressed PCM packets (Matroska A_PCM/INT/LIT, A_PCM/FLOAT/IEEE) to float, one array per channel.
pub struct PCMPacketDecoder {
    channels: usize,
    sample_rate: usize,
    bytes_per_sample: usize,
    is_float: bool,
}

impl PCMPacketDecoder {
    pub fn new(
        channels: usize,
        sample_rate: usize,
        bit_depth: usize,
        is_float: bool,
    ) -> Result<PCMPacketDecoder, MediaError> {
        let ok = if is_float { bit_depth == 32 } else { [16, 24, 32].contains(&bit_depth) };
        if !(1..=2).contains(&channels) || !ok || sample_rate == 0 {
            return Err(MediaError::UnsupportedCodec("PCM".to_string()));
        }
        Ok(PCMPacketDecoder { channels, sample_rate, bytes_per_sample: bit_depth / 8, is_float })
    }
}

impl WebMPacketDecoder for PCMPacketDecoder {
    fn channels(&self) -> usize {
        self.channels
    }
    fn sample_rate(&self) -> usize {
        self.sample_rate
    }
    fn preroll_packets(&self) -> usize {
        0
    }
    fn reset(&mut self) {}

    fn decode(&mut self, packet: &[u8]) -> Vec<Vec<f32>> {
        let frame = self.channels * self.bytes_per_sample;
        let n = packet.len() / frame;
        let mut out = vec![vec![0f32; n]; self.channels];
        let b = packet;
        for i in 0..n {
            for (c, channel) in out.iter_mut().enumerate() {
                let o = i * frame + c * self.bytes_per_sample;
                let u = |k: usize| u32::from(b[o + k]);
                channel[i] = if self.is_float {
                    f32::from_bits(u(0) | u(1) << 8 | u(2) << 16 | u(3) << 24)
                } else if self.bytes_per_sample == 2 {
                    f32::from(i16::from_le_bytes([b[o], b[o + 1]])) / 32768.0
                } else if self.bytes_per_sample == 3 {
                    ((u(0) << 8 | u(1) << 16 | u(2) << 24) as i32 >> 8) as f32 / 8_388_608.0
                } else {
                    (i32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]) as f32) / 2_147_483_648.0
                };
            }
        }
        out
    }
}

/// AAC-LC through the system decoder (AudioToolbox) in Swift; the AudioSpecificConfig helpers are portable.
pub enum AACPacketDecoder {}

impl AACPacketDecoder {
    pub const PREROLL_PACKETS: usize = 2;
    pub const FRAMES_PER_PACKET: usize = 1024;

    /// Longest AudioSpecificConfig accepted: plain AAC-LC ones are 2 bytes; a program config element with a comment
    /// field (up to 255 bytes) and extensions stay far below this.
    pub const MAX_CONFIG_SIZE: usize = 4096;

    /// Sample rate and channel count from an AudioSpecificConfig; `None` for anything but plain AAC-LC mono / stereo (no
    /// SBR / PS, which double the output rate) or when the data is too short.
    pub fn parse_config(c: &[u8]) -> Option<(usize, usize)> {
        if c.len() < 2 || c.len() > Self::MAX_CONFIG_SIZE {
            return None;
        }
        let mut r = BitReader::new(c);
        const RATES: [usize; 13] =
            [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];
        let object_type = r.read(5)?;
        let freq_index = usize::try_from(r.read(4)?).ok()?;
        if object_type != 2 || freq_index >= RATES.len() {
            return None;
        }
        let chan = r.read(4)?;
        if (1..=2).contains(&chan) {
            return Some((RATES[freq_index], chan as usize));
        }
        // Channel configuration 0: the layout is in a program config element after the three GASpecificConfig flags.
        if chan != 0 || !r.skip(1) {
            return None;
        }
        let core = r.read(1)?;
        if !(core == 0 || r.skip(14)) || !r.skip(1) {
            return None;
        }
        let n = Self::pce_channels(&mut r)?;
        if (1..=2).contains(&n) { Some((RATES[freq_index], n as usize)) } else { None }
    }

    /// Channel count of a program config element (ISO 14496-3 table 4.2); `None` when the data ends early.
    pub fn pce_channels(r: &mut BitReader) -> Option<i64> {
        if !r.skip(4 + 2 + 4) {
            return None;
        }
        let front = r.read(4)?;
        let side = r.read(4)?;
        let back = r.read(4)?;
        let lfe = r.read(2)?;
        if !r.skip(3 + 4) {
            return None;
        }
        let mono = r.read(1)?;
        if mono == 1 && !r.skip(4) {
            return None;
        }
        let stereo = r.read(1)?;
        if stereo == 1 && !r.skip(4) {
            return None;
        }
        let matrix = r.read(1)?;
        if matrix == 1 && !r.skip(3) {
            return None;
        }
        let mut channels = lfe;
        for _ in 0..(front + side + back) {
            let cpe = r.read(1)?;
            if !r.skip(4) {
                return None;
            }
            channels += if cpe == 1 { 2 } else { 1 };
        }
        Some(channels)
    }

    /// MPEG-4 `esds` payload wrapping the AudioSpecificConfig (what Core Audio takes as the AAC magic cookie).
    pub fn esds(asc: &[u8]) -> Vec<u8> {
        let mut dsi = vec![0x05];
        dsi.extend(Self::descriptor_length(asc.len()));
        dsi.extend(asc);
        let mut dcd_body = vec![0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        dcd_body.extend(dsi);
        let mut dcd = vec![0x04];
        dcd.extend(Self::descriptor_length(dcd_body.len()));
        dcd.extend(dcd_body);
        let mut es_body = vec![0, 0, 0];
        es_body.extend(dcd);
        es_body.extend([0x06, 0x01, 0x02]);
        let mut out = vec![0, 0, 0, 0, 0x03];
        out.extend(Self::descriptor_length(es_body.len()));
        out.extend(es_body);
        out
    }

    /// MPEG-4 descriptor size: 7 bits per byte, high bit set on all but the last byte.
    pub fn descriptor_length(n: usize) -> Vec<u8> {
        let mut groups = vec![(n & 0x7F) as u8];
        let mut rest = n >> 7;
        while rest > 0 {
            groups.insert(0, (rest & 0x7F) as u8 | 0x80);
            rest >>= 7;
        }
        groups
    }
}

/// MSB-first bit reader that returns `None` instead of reading past the end.
pub struct BitReader<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> BitReader<'a> {
    pub fn new(bytes: &'a [u8]) -> BitReader<'a> {
        BitReader { bytes, pos: 0 }
    }

    pub fn read(&mut self, n: usize) -> Option<i64> {
        if self.pos + n > self.bytes.len() * 8 {
            return None;
        }
        let mut v: i64 = 0;
        for _ in 0..n {
            v = v << 1 | i64::from((self.bytes[self.pos >> 3] >> (7 - (self.pos & 7))) & 1);
            self.pos += 1;
        }
        Some(v)
    }

    pub fn skip(&mut self, n: usize) -> bool {
        self.read(n).is_some()
    }
}

/// 0.7071 (-3 dB) as the Swift literal; a division because clippy flags the literal as `FRAC_1_SQRT_2` (same f32).
const MIX_COEFFICIENT: f32 = 7071.0 / 10_000.0;

/// The audio of a WebM file as the mixer wants it.
pub enum WebMAudioSource {}

impl WebMAudioSource {
    /// Down/up-mix to stereo. Vorbis channel order: L, C, R, SL, SR, LFE (for 3...6 channels); Opus family 0 has 1 or 2.
    pub fn stereo(pcm: &[Vec<f32>]) -> (Vec<f32>, Vec<f32>) {
        match pcm.len() {
            0 => (Vec::new(), Vec::new()),
            1 => (pcm[0].clone(), pcm[0].clone()),
            2 => (pcm[0].clone(), pcm[1].clone()),
            count => {
                let n = pcm[0].len();
                let mut l = pcm[0].clone();
                let mut r = pcm[1].clone();
                let k = MIX_COEFFICIENT;
                if count == 3 {
                    // L C R
                    for i in 0..n {
                        l[i] = pcm[0][i] + k * pcm[1][i];
                        r[i] = pcm[2][i] + k * pcm[1][i];
                    }
                } else if count == 4 {
                    // L R SL SR
                    for i in 0..n {
                        l[i] = pcm[0][i] + k * pcm[2][i];
                        r[i] = pcm[1][i] + k * pcm[3][i];
                    }
                } else if count >= 6 {
                    // L C R SL SR LFE
                    for i in 0..n {
                        l[i] = (pcm[0][i] + k * pcm[1][i] + k * pcm[3][i]) * 0.6;
                        r[i] = (pcm[2][i] + k * pcm[1][i] + k * pcm[4][i]) * 0.6;
                    }
                }
                // Otherwise (5 channels) `l` and `r` already hold channels 0 and 1.
                (l, r)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn opus_packet_duration() {
        assert_eq!(OpusPacketDecoder::samples_in(&[0xFC, 0, 0]), Some(960)); // CELT 20 ms, one frame
        assert_eq!(OpusPacketDecoder::samples_in(&[0xFD, 0, 0]), Some(1920)); // two frames
        assert_eq!(OpusPacketDecoder::samples_in(&[0xFF, 3, 0]), Some(960 * 3)); // arbitrary count
        assert_eq!(OpusPacketDecoder::samples_in(&[]), None);
        assert_eq!(OpusPacketDecoder::samples_in(&[0xFF]), None);
    }

    #[test]
    fn pcm24_mono_decodes() {
        let mut dec = PCMPacketDecoder::new(1, 48_000, 24, false).unwrap();
        // +0.5 (0x400000) and -0.5 (0xC00000), little endian.
        assert_eq!(dec.decode(&[0x00, 0x00, 0x40, 0x00, 0x00, 0xC0]), vec![vec![0.5, -0.5]]);
    }

    #[test]
    fn pcm16_32_and_float_decode() {
        let mut d16 = PCMPacketDecoder::new(2, 48_000, 16, false).unwrap();
        assert_eq!(d16.decode(&[0x00, 0x40, 0x00, 0xC0, 0xFF]), vec![vec![0.5], vec![-0.5]]);
        let mut d32 = PCMPacketDecoder::new(1, 48_000, 32, false).unwrap();
        assert_eq!(d32.decode(&[0, 0, 0, 0x40]), vec![vec![0.5]]);
        let mut df = PCMPacketDecoder::new(1, 48_000, 32, true).unwrap();
        assert_eq!(df.decode(&0.25f32.to_le_bytes()), vec![vec![0.25]]);
    }

    #[test]
    fn unsupported_pcm_depth_is_reported() {
        assert_eq!(PCMPacketDecoder::new(2, 48_000, 8, false).err(), Some(MediaError::UnsupportedCodec("PCM".into())));
        assert!(PCMPacketDecoder::new(3, 48_000, 16, false).is_err());
        assert!(PCMPacketDecoder::new(1, 0, 16, false).is_err());
    }

    #[test]
    fn audio_specific_config_parsing() {
        // AAC-LC, 48 kHz, stereo = 0x11 0x90; 44.1 kHz mono = 0x12 0x08.
        assert_eq!(AACPacketDecoder::parse_config(&[0x11, 0x90]), Some((48_000, 2)));
        assert_eq!(AACPacketDecoder::parse_config(&[0x12, 0x08]), Some((44_100, 1)));
        // HE-AAC (object type 5) and 5.1 are not handled.
        assert_eq!(AACPacketDecoder::parse_config(&[0x2B, 0x92]), None);
        assert_eq!(AACPacketDecoder::parse_config(&[0x11, 0xB0]), None);
        assert_eq!(AACPacketDecoder::parse_config(&[0x11]), None);
    }

    /// AudioSpecificConfig with channel configuration 0: AAC-LC, 48 kHz, a program config element, comment bytes.
    fn pce_config(front: &[bool], comment: usize, core: bool) -> Vec<u8> {
        let mut bits: Vec<i64> = Vec::new();
        let mut put = |v: i64, n: u32| {
            for k in (0..n).rev() {
                bits.push(v >> k & 1);
            }
        };
        put(2, 5);
        put(3, 4);
        put(0, 4);
        put(0, 1);
        put(i64::from(core), 1); // type, rate, channel config 0, frameLength, dependsOnCoreCoder
        if core {
            put(0x155, 14); // coreCoderDelay
        }
        put(0, 1); // extensionFlag
        put(0, 4);
        put(1, 2);
        put(3, 4); // PCE tag, object type, rate index
        put(front.len() as i64, 4);
        put(0, 4);
        put(0, 4);
        put(0, 2);
        put(0, 3);
        put(0, 4);
        put(0, 1);
        put(0, 1);
        put(0, 1); // no mixdowns
        for &cpe in front {
            put(i64::from(cpe), 1);
            put(0, 4);
        }
        while !bits.len().is_multiple_of(8) {
            bits.push(0);
        }
        let mut out: Vec<u8> = bits.chunks(8).map(|c| c.iter().fold(0u8, |a, &b| a << 1 | b as u8)).collect();
        out.push(comment as u8);
        out.extend(vec![0x41; comment]);
        out
    }

    #[test]
    fn long_config_with_program_config_element_parses() {
        let stereo = pce_config(&[true], 200, false);
        assert!(stereo.len() > 64);
        assert_eq!(AACPacketDecoder::parse_config(&stereo), Some((48_000, 2)));
        assert_eq!(AACPacketDecoder::parse_config(&pce_config(&[false], 0, false)), Some((48_000, 1)));
        assert_eq!(AACPacketDecoder::parse_config(&pce_config(&[true, false, false], 0, false)), None); // 4 channels
    }

    #[test]
    fn config_with_core_coder_delay_parses() {
        let c = pce_config(&[true], 0, true);
        assert_eq!(AACPacketDecoder::parse_config(&c).map(|p| p.1), Some(2));
        for n in 2..5 {
            assert_eq!(AACPacketDecoder::parse_config(&c[..n]), None); // ends inside the 14 delay bits
        }
    }

    #[test]
    fn truncated_or_hostile_config_is_rejected() {
        let full = pce_config(&[true], 0, false);
        for n in 2..5 {
            assert_eq!(AACPacketDecoder::parse_config(&full[..n]), None);
        }
        assert_eq!(AACPacketDecoder::parse_config(&vec![0xFF; 100_000]), None);
        assert_eq!(AACPacketDecoder::parse_config(&[0x10, 0x00]), None); // channel config 0 and nothing after it
    }

    #[test]
    fn descriptor_lengths_are_variable_length() {
        assert_eq!(AACPacketDecoder::descriptor_length(5), vec![5]);
        assert_eq!(AACPacketDecoder::descriptor_length(127), vec![127]);
        assert_eq!(AACPacketDecoder::descriptor_length(128), vec![0x81, 0x00]);
        assert_eq!(AACPacketDecoder::descriptor_length(300), vec![0x82, 0x2C]);
        // 2-byte config: ES descriptor body 3 + (2+13+2+2) + 3 = 25 bytes.
        let e = AACPacketDecoder::esds(&[0x11, 0x90]);
        assert!(e.len() == 4 + 2 + 25 && e[4] == 0x03 && e[5] == 25);
    }

    #[test]
    fn stereo_mix_down() {
        let ch = |v: f32| vec![v, v];
        assert_eq!(WebMAudioSource::stereo(&[]), (vec![], vec![]));
        assert_eq!(WebMAudioSource::stereo(&[ch(1.0)]), (ch(1.0), ch(1.0)));
        assert_eq!(WebMAudioSource::stereo(&[ch(1.0), ch(2.0)]), (ch(1.0), ch(2.0)));
        let (l, r) = WebMAudioSource::stereo(&[ch(1.0), ch(1.0), ch(1.0)]);
        assert_eq!((l[0], r[0]), (1.0 + MIX_COEFFICIENT, 1.0 + MIX_COEFFICIENT));
        let (l, r) = WebMAudioSource::stereo(&[ch(1.0), ch(2.0), ch(3.0), ch(4.0)]);
        assert_eq!((l[0], r[0]), (1.0 + MIX_COEFFICIENT * 3.0, 2.0 + MIX_COEFFICIENT * 4.0));
        let (l, r) = WebMAudioSource::stereo(&[ch(1.0), ch(1.0), ch(1.0), ch(1.0), ch(1.0), ch(0.0)]);
        assert_eq!(
            (l[0], r[0]),
            ((1.0 + MIX_COEFFICIENT + MIX_COEFFICIENT) * 0.6, (1.0 + MIX_COEFFICIENT + MIX_COEFFICIENT) * 0.6)
        );
    }
}
